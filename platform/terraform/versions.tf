terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
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

  backend "azurerm" {
    # Partial config — the rest (resource_group_name, storage_account_name,
    # container_name, key) is supplied via -backend-config at `terraform init`
    # (see bootstrap/README.md). Terraform backend blocks can't reference
    # variables, so this can't be filled in from terraform.tfvars.
  }
}

provider "azurerm" {
  features {}
}
