output "resource_group_name" {
  description = "Name of the resource group."
  value       = azurerm_resource_group.this.name
}

output "container_app_name" {
  description = "Name of the Container App."
  value       = azurerm_container_app.this.name
}

output "container_app_fqdn" {
  description = "Public host name of the app's latest revision."
  value       = azurerm_container_app.this.latest_revision_fqdn
}

output "identity_id" {
  description = "Resource ID of the app's user-assigned managed identity."
  value       = azurerm_user_assigned_identity.app.id
}

output "key_vault_uri" {
  description = "URI of the Key Vault holding the app's secrets."
  value       = azurerm_key_vault.this.vault_uri
}
