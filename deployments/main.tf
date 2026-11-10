locals {
  config = yamldecode(file("configs/${terraform.workspace}.yaml"))

  # Tags for every resource in the deployment. The azurerm provider has no
  # default tags, so terraform/ gets them as var.tags and sets
  # `tags = var.tags` on each resource.
  tags = {
    Name          = "${local.config.name}-${local.config.deployment_id}"
    env           = local.config.env
    deployment_id = local.config.deployment_id
    service       = local.config.service
    owner         = local.config.owner
    managed_by    = local.config.managed_by
  }
}

module "main" {
  source = "../terraform"
  # Standard variables
  name          = local.config.name
  deployment_id = local.config.deployment_id
  config        = local.config.config

  # Azure variables
  location = local.config.azure.location
  tags     = local.tags

  # Metadata variables
  env     = local.config.env
  owner   = local.config.owner
  service = local.config.service

  # Pass in any additional variables below.
  # These must be defined in terraform/variables.tf
  # variable_name =

  # Set any additional providers below.
  providers = {
    azurerm = azurerm
  }
}
