# Call your modules below.
# Pass in at least the module's part of var.config and a name.
# Pass location and tags to modules that make Azure resources, and set
# `tags = var.tags` on every resource that supports tags.

# module "<module_key>" {
#   source   = "./modules/<module_name>"
#   config   = var.config.<module_key>
#   name     = "${var.name}-${var.deployment_id}"
#   location = var.location
#   tags     = var.tags
# }
