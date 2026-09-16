resource "azurerm_resource_group" "homelab" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_key_vault" "vault" {
  name                        = var.key_vault_name
  location                    = azurerm_resource_group.homelab.location
  resource_group_name         = azurerm_resource_group.homelab.name
  enabled_for_disk_encryption = false
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false

  sku_name                   = "standard"
  rbac_authorization_enabled = true
}

resource "azuread_application" "k3s_eso" {
  display_name = var.app_display_name
}

resource "azuread_service_principal" "k3s_eso_sp" {
  client_id = azuread_application.k3s_eso.client_id
}

resource "azuread_service_principal_password" "k3s_eso_sp_password" {
  service_principal_id = azuread_service_principal.k3s_eso_sp.id
}

resource "azurerm_role_assignment" "eso_kv_secrets_user" {
  scope                = azurerm_key_vault.vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azuread_service_principal.k3s_eso_sp.object_id
}
