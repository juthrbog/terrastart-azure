# The OpenTofu version and the providers (with their versions) that this
# code needs. This file and deployments/versions.tf must match.
terraform {
  required_version = ">= 1.13.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
