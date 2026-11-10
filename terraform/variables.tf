# Standard variables
variable "name" {
  description = "The prefix to be added to all named resources in the deployment. It is the value of 'name' in the yaml config in deployments/configs/."
  type        = string
}

variable "deployment_id" {
  description = "The unique ID of the deployment. It is the value of 'deployment_id' in the yaml config in deployments/configs/."
  type        = string
}

variable "config" {
  description = "Configuration passed in from the yaml config in deployments/configs/."
  type        = any
}

# Azure variables
variable "location" {
  description = "The Azure region for the resources, e.g. eastus. It is the value of 'azure.location' in the yaml config in deployments/configs/. Set `location = var.location` on every resource that needs a region."
  type        = string
}

variable "tags" {
  description = "Tags for the resources in the deployment, built in deployments/main.tf. The azurerm provider has no default tags, so set `tags = var.tags` on every resource that supports tags."
  type        = map(string)
}

# Metadata variables, used for tagging and naming inside modules.
variable "env" {
  description = "Env value passed in from the yaml config in deployments/configs/."
  type        = string
}

variable "owner" {
  description = "Owner value passed in from the yaml config in deployments/configs/."
  type        = string
}

variable "service" {
  description = "Service value passed in from the yaml config in deployments/configs/."
  type        = string
}

# Define any additional variables you need below.
# These are values passed in from deployments/main.tf.

