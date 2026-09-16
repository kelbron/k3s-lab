module "core" {
  source = "../../modules/core"

  environment         = "local"
  location            = "canadacentral"
  resource_group_name = "rg-homelab-core"
  key_vault_name      = "kv-homelab-samjam"
  app_display_name    = "app-homelab-k3s-eso"
}

# State migration mappings (prevents resource destruction/recreation)
moved {
  from = azurerm_resource_group.homelab
  to   = module.core.azurerm_resource_group.homelab
}

moved {
  from = azurerm_key_vault.vault
  to   = module.core.azurerm_key_vault.vault
}

moved {
  from = azuread_application.k3s_eso
  to   = module.core.azuread_application.k3s_eso
}

moved {
  from = azuread_service_principal.k3s_eso_sp
  to   = module.core.azuread_service_principal.k3s_eso_sp
}

moved {
  from = azuread_service_principal_password.k3s_eso_sp_password
  to   = module.core.azuread_service_principal_password.k3s_eso_sp_password
}

moved {
  from = azurerm_role_assignment.eso_kv_secrets_user
  to   = module.core.azurerm_role_assignment.eso_kv_secrets_user
}
