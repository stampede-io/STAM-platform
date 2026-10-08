resource "null_resource" "fetch_kubeconfig" {
  depends_on = [azurerm_linux_virtual_machine.stampede]

  triggers = {
    vm_id = azurerm_linux_virtual_machine.stampede.id
  }

  provisioner "local-exec" {
    # cloud-init takes a little while after the VM reports Running — poll
    # for the .k3s-ready marker (touched last in cloud-init.yaml) instead of
    # guessing a fixed sleep, then scp the kubeconfig down. AC2's "ready in
    # <=10 min" is measured from here: apply doesn't return until this
    # succeeds or the retry budget below is exhausted.
    command = <<-EOT
      set -e
      ip="${azurerm_public_ip.stampede.ip_address}"
      user="${var.admin_username}"
      # Derive the private key from the configured public key path rather
      # than trusting ssh-agent/default-identity discovery — ssh_public_key_path
      # has no fixed default, so a non-standard path here would otherwise
      # make this fetch fail even though the VM itself accepts the key fine.
      key="$(echo "${var.ssh_public_key_path}" | sed 's/\.pub$//')"
      for i in $(seq 1 40); do
        if ssh -i "$key" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "$user@$ip" test -f /home/$user/.k3s-ready 2>/dev/null; then
          scp -i "$key" -o StrictHostKeyChecking=accept-new "$user@$ip":/home/$user/.kube/config "${path.module}/kubeconfig"
          exit 0
        fi
        sleep 15
      done
      echo "Timed out waiting for k3s to become ready on $ip" >&2
      exit 1
    EOT
  }
}

output "vm_public_ip" {
  description = "Public IP of the k3s VM."
  value       = azurerm_public_ip.stampede.ip_address
}

output "kubeconfig_path" {
  description = "Local path to the fetched kubeconfig. Its server address is 127.0.0.1:6443 (k3s' own default) — 6443 is not open on the NSG, so kubectl needs an SSH tunnel (see ssh_command) to reach it remotely, or run kubectl directly on the VM over SSH."
  value       = "${path.module}/kubeconfig"
  depends_on  = [null_resource.fetch_kubeconfig]
}

output "ssh_command" {
  description = "SSH into the VM, or add -L 6443:localhost:6443 to tunnel kubectl through it."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.stampede.ip_address}"
}
