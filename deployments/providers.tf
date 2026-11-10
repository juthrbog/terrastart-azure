provider "azurerm" {
  features {}

  subscription_id = local.config.azure.subscription_id
  tenant_id       = local.config.azure.tenant_id

  # Do not register Azure resource providers (Microsoft.Compute and so on)
  # on each run. In azurerm 4.x the default registers a long list of them,
  # and the provider fails when the identity is not allowed to register one.
  # CI identities often do not have that right. Register the ones you need
  # once with `az provider register --namespace Microsoft.<Name>`. See
  # "Resource provider registration" in README.md.
  resource_provider_registrations = "none"

  # The client ID and the sign-in method (OIDC in CI, the Azure CLI on a
  # laptop) come from the ARM_* variables that .ci/scripts/tf.sh exports.
}

# Define any additional provider configs below, if needed. azurerm has no
# default tags, so pass local.tags (see main.tf) to the resources instead.
