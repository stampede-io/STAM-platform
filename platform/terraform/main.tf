# Demo cluster (ADR-0008): one EC2 instance running single-node k3s, in the
# account's default VPC. Built to be destroyed after the demo, so nothing
# here is HA and the backup bucket is force_destroy.

locals {
  ssh_user = "ubuntu" # Canonical's AMIs create this user; cloud-init uses it too
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

data "aws_vpc" "default" {
  default = true
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# --- Networking ---------------------------------------------------------

# 6443 (k3s API) is deliberately absent: security groups deny inbound by
# default. kubectl from off-box goes through the SSH tunnel (ssh_command
# output). A port scan sees exactly 80, 443, and 22 from operator_ip.
resource "aws_security_group" "stampede" {
  name        = "stampede"
  description = "k3s demo node: HTTP/HTTPS public, SSH operator only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP (Let's Encrypt HTTP-01 and the redirect to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from the operator only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.operator_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "stampede" {
  key_name   = "stampede-${random_string.suffix.result}"
  public_key = file(var.ssh_public_key_path)
}

# --- IAM: the backup CronJob's only credential ---------------------------

# The node's instance role, scoped to the backup bucket alone. The backup
# pod reaches it through IMDS, so no access key exists anywhere: not in a
# Secret, not in Terraform state.
resource "aws_iam_role" "node" {
  name = "stampede-node-${random_string.suffix.result}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "backup_bucket" {
  name = "backup-bucket-only"
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.backups.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.backups.arn
      },
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = aws_iam_role.node.name
  role = aws_iam_role.node.name
}

# --- Compute -------------------------------------------------------------

resource "aws_instance" "stampede" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.stampede.key_name
  vpc_security_group_ids = [aws_security_group.stampede.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  # IMDSv2 only. Hop limit 2 because a pod's request crosses one extra hop
  # (the CNI bridge) before reaching the instance; with 1 the backup pod
  # can't get the role's credentials.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 64
    encrypted   = true
  }

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    admin_username = local.ssh_user
  })

  tags = { Name = "stampede-k3s" }
}

# A stable address for the DuckDNS record; survives a stop/start.
resource "aws_eip" "stampede" {
  instance = aws_instance.stampede.id
  domain   = "vpc"
}

# --- Storage ---------------------------------------------------------------

resource "aws_s3_bucket" "backups" {
  bucket        = "stampede-backups-${random_string.suffix.result}"
  force_destroy = true # demo: `terraform destroy` must leave nothing behind
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# STAM-59 AC5: dumps older than 30 days delete themselves.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-backups-after-30-days"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

# --- Cost guard ----------------------------------------------------------

# include_credit = false: with credits counted, "actual cost" reads ~$0
# until the credits are gone, so the alert would only fire once the money
# is already real. This tracks gross spend against the credit balance.
resource "aws_budgets_budget" "stampede" {
  name         = "stampede-demo"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false
    include_refund = false
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_email]
    }
  }
}
