resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_resource_group" "stampede" {
  name     = "rg-stampede"
  location = var.location
}

# --- Networking ---------------------------------------------------------

resource "azurerm_virtual_network" "stampede" {
  name                = "vnet-stampede"
  address_space       = ["10.20.0.0/16"]
  location            = azurerm_resource_group.stampede.location
  resource_group_name = azurerm_resource_group.stampede.name
}

resource "azurerm_subnet" "stampede" {
  name                 = "subnet-stampede"
  resource_group_name  = azurerm_resource_group.stampede.name
  virtual_network_name = azurerm_virtual_network.stampede.name
  address_prefixes     = ["10.20.1.0/24"]
}

resource "azurerm_network_security_group" "stampede" {
  name                = "nsg-stampede"
  location            = azurerm_resource_group.stampede.location
  resource_group_name = azurerm_resource_group.stampede.name

  # 6443 (k3s API server) is deliberately absent — NSGs deny by default, and
  # it stays that way. kubectl access from off-box goes through the SSH
  # tunnel described in platform/docs/ (ssh_command output), never a direct
  # rule here. AC5: a port scan sees exactly 80, 443, 22 (from operator_ip).

  security_rule {
    name                       = "allow-http"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-https"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-ssh-operator-only"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.operator_ip
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "stampede" {
  subnet_id                 = azurerm_subnet.stampede.id
  network_security_group_id = azurerm_network_security_group.stampede.id
}

resource "azurerm_public_ip" "stampede" {
  name                = "pip-stampede"
  location            = azurerm_resource_group.stampede.location
  resource_group_name = azurerm_resource_group.stampede.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "stampede" {
  name                = "nic-stampede"
  location            = azurerm_resource_group.stampede.location
  resource_group_name = azurerm_resource_group.stampede.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.stampede.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.stampede.id
  }
}

# --- Compute -------------------------------------------------------------

resource "azurerm_linux_virtual_machine" "stampede" {
  name                = "vm-stampede"
  location            = azurerm_resource_group.stampede.location
  resource_group_name = azurerm_resource_group.stampede.name
  size                = "Standard_B2ms"
  admin_username      = var.admin_username
  network_interface_ids = [
    azurerm_network_interface.stampede.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  # Password auth stays off — SSH is key-only (AC5), and disabling this is
  # what actually enforces that at the VM level, not just the NSG rule.
  disable_password_authentication = true

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    admin_username = var.admin_username
  }))
}

# --- Storage ---------------------------------------------------------------

resource "azurerm_storage_account" "stampede" {
  name                     = "ststampede${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.stampede.name
  location                 = azurerm_resource_group.stampede.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  access_tier              = "Cool"
}
