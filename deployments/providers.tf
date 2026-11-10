provider "aws" {
  region = local.config.aws.region

  default_tags {
    tags = {
      Name          = "${local.config.name}-${local.config.deployment_id}"
      env           = local.config.env
      deployment_id = local.config.deployment_id
      service       = local.config.service
      owner         = local.config.owner
      managed_by    = local.config.managed_by
    }
  }
}

# Define any additional provider configs below, if needed. Be sure to include the same
# default tags as the AWS provider.
