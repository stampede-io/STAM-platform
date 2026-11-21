variable "region" {
  description = "AWS region. ap-south-1 (Mumbai) is the closest to the demo audience; us-east-1 is slightly cheaper."
  type        = string
  default     = "ap-south-1"
}

variable "instance_type" {
  description = "EC2 size. m6i.2xlarge = 8 vCPU / 32 GB at full CPU all the time (about $70 for a demo week). Not a burstable t3: under a sustained load test a t3 either throttles or bills surplus CPU credits."
  type        = string
  default     = "m6i.2xlarge"

  validation {
    # A t-family instance would also need a credit_specification, which
    # main.tf deliberately doesn't carry (ADR-0008).
    condition     = !startswith(var.instance_type, "t")
    error_message = "Use a non-burstable type (m6i, m7i, c6i...). Burstable t-types throttle or bill extra under load tests."
  }
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
  description = "Path to the SSH public key installed on the instance for the ubuntu user."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "budget_limit_usd" {
  description = "Monthly AWS Budget limit. Alerts fire at 50/80/100% of it. The demo week costs about $70, so $100 flags a forgotten destroy well before the $200 of credits is gone."
  type        = number
  default     = 100
}

variable "budget_email" {
  description = "Address the budget alerts are emailed to."
  type        = string
}
