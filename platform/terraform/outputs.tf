resource "null_resource" "fetch_kubeconfig" {
  depends_on = [aws_eip.stampede]

  triggers = {
    instance_id = aws_instance.stampede.id
  }

  provisioner "local-exec" {
    # Without this, local-exec uses cmd.exe on Windows and the script below
    # fails. Run terraform from Git Bash on Windows: from PowerShell, "bash"
    # can resolve to WSL's, which has neither this path nor your SSH key.
    interpreter = ["bash", "-c"]

    # cloud-init takes a while after the instance reports running. Poll for
    # the .k3s-ready marker (touched last in cloud-init.yaml) instead of a
    # fixed sleep, then scp the kubeconfig down. The <=10 min readiness
    # budget is measured here: apply doesn't return until this succeeds or
    # the 40 x 15 s retries run out.
    command = <<-EOT
      set -e
      ip="${aws_eip.stampede.public_ip}"
      user="${local.ssh_user}"
      # Private key derived from the configured public key path, so a
      # non-default key works without ssh-agent.
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

output "public_ip" {
  description = "Elastic IP of the k3s node. Point the DuckDNS record at this."
  value       = aws_eip.stampede.public_ip
}

output "kubeconfig_path" {
  description = "Local path to the fetched kubeconfig. Its server is 127.0.0.1:6443 (k3s default); 6443 is closed in the security group, so tunnel it (ssh_command with -L 6443:localhost:6443) or run kubectl on the node."
  value       = "${path.module}/kubeconfig"
  depends_on  = [null_resource.fetch_kubeconfig]
}

output "ssh_command" {
  description = "SSH into the node, or add -L 6443:localhost:6443 to tunnel kubectl through it."
  value       = "ssh ${local.ssh_user}@${aws_eip.stampede.public_ip}"
}

output "backup_bucket" {
  description = "S3 bucket the postgres-backup CronJob writes to (substitute into postgres-backup-cronjob.yaml)."
  value       = aws_s3_bucket.backups.bucket
}

output "region" {
  description = "Region everything lives in (the backup CronJob needs it)."
  value       = var.region
}
