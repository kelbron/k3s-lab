output "key_vault_id" {
  description = "The Azure Resource ID of the Key Vault"
  value       = module.core.key_vault_id
}

output "key_vault_uri" {
  description = "The URI of the Key Vault used for ESO authentication"
  value       = module.core.key_vault_uri
}

output "client_id" {
  description = "The Client ID of the ESO Service Principal"
  value       = module.core.client_id
}

output "client_secret" {
  description = "The Client Secret of the ESO Service Principal"
  value       = module.core.client_secret
  sensitive   = true
}

output "tenant_id" {
  description = "The Azure Tenant ID"
  value       = module.core.tenant_id
}
