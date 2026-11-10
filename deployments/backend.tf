# The backend settings for each deployment are in
# deployments/backends/<deployment>.azurerm.tfbackend. CI (.ci/scripts/tf.sh)
# and `task tf-switch` pass that file to `tofu init -backend-config=...`.
# How OpenTofu signs in (OIDC in CI, the Azure CLI on a laptop) is not in that
# file. It comes from the ARM_* variables that tf.sh exports.
terraform {
  backend "azurerm" {}
}
