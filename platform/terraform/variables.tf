variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus"
}

variable "operator_ip" {
  description = "Your own public IP (CIDR, e.g. 1.2.3.4/32) — the only address SSH (22) is opened to. Find yours with `curl -s https://api.ipify.org`."
  type        = string

  validation {
    condition     = can(cidrhost(var.operator_ip, 0))
    error_message = "operator_ip must be a CIDR, e.g. 1.2.3.4/32."
  }
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key installed on the VM for the admin user."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "admin_username" {
  description = "Admin username on the VM."
  type        = string
  default     = "stampede"
}
