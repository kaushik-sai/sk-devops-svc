# Fake values for the mocked azurerm provider, shared by dev and prod tests.
# Mocks never call Azure; these only need to look like real Azure values so
# the provider's validation passes and the tests can compare IDs.

mock_data "azurerm_client_config" {
  defaults = {
    tenant_id       = "00000000-0000-0000-0000-000000000000"
    subscription_id = "00000000-0000-0000-0000-000000000000"
  }
}

mock_resource "azurerm_user_assigned_identity" {
  defaults = {
    id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-test"
    principal_id = "11111111-1111-1111-1111-111111111111"
  }
}

mock_resource "azurerm_key_vault" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.KeyVault/vaults/kv-test"
  }
}

mock_resource "azurerm_key_vault_secret" {
  defaults = {
    versionless_id = "https://kv-test.vault.azure.net/secrets/db-password"
  }
}

mock_resource "azurerm_container_app_environment" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.App/managedEnvironments/cae-test"
  }
}
