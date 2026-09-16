output "key_vault_id" {
  description = "The Azure Resource ID of the Key Vault"
  value       = azurerm_key_vault.vault.id
}

output "key_vault_uri" {
  description = "The URI of the Key Vault used for ESO authentication"
  value       = azurerm_key_vault.vault.vault_uri
}

output "client_id" {
  description = "The Client ID of the ESO Service Principal"
  value       = azuread_service_principal.k3s_eso_sp.client_id
}

output "client_secret" {
  description = "The Client Secret of the ESO Service Principal"
  value       = azuread_service_principal_password.k3s_eso_sp_password.value
  sensitive   = true
}

output "tenant_id" {
  description = "The Azure Tenant ID"
  value       = local.tenant_id
}
