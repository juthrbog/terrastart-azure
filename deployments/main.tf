locals {
  config = yamldecode(file("configs/${terraform.workspace}.yaml"))
}

module "main" {
  source = "../terraform"
  # Standard variables
  name          = local.config.name
  deployment_id = local.config.deployment_id
  config        = local.config.config

  # Metadata variables
  env     = local.config.env
  owner   = local.config.owner
  service = local.config.service

  # Pass in any additional variables below.
  # These must be defined in terraform/variables.tf
  # variable_name =

  # Set any additional providers below.
  providers = {
    aws = aws
  }
}

