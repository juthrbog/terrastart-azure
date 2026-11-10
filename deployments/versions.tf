# The OpenTofu version and the providers (with their versions) that this
# code needs. This file and terraform/versions.tf must match.
terraform {
  required_version = ">= 1.13.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
