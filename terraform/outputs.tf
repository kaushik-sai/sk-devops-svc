output "resource_group_name" {
  description = "Name of the resource group."
  value       = module.service.resource_group_name
}

output "container_app_name" {
  description = "Name of the Container App."
  value       = module.service.container_app_name
}

output "container_app_fqdn" {
  description = "Public host name of the app's latest revision."
  value       = module.service.container_app_fqdn
}

output "identity_id" {
  description = "Resource ID of the app's user-assigned managed identity."
  value       = module.service.identity_id
}

output "key_vault_uri" {
  description = "URI of the Key Vault holding the app's secrets."
  value       = module.service.key_vault_uri
}
