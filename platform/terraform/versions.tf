terraform {
  # 1.10+ for the S3 backend's native lockfile (no DynamoDB table needed).
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  backend "s3" {
    # Partial config: bucket, key and region come from -backend-config at
    # `terraform init` (bootstrap/bootstrap-state.sh prints the exact
    # command). Backend blocks can't read variables.
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "stampede"
      Purpose = "demo"
    }
  }
}
