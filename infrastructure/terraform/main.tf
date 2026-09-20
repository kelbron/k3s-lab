# Top-level Azure Resources
resource "azurerm_resource_group" "homelab" {
  name     = local.resource_group_name
  location = var.location
}

resource "azurerm_key_vault" "vault" {
  name                        = local.key_vault_name
  location                    = azurerm_resource_group.homelab.location
  resource_group_name         = azurerm_resource_group.homelab.name
  enabled_for_disk_encryption = false
  tenant_id                   = local.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false

  sku_name                   = "standard"
  rbac_authorization_enabled = true
}

resource "azuread_application" "k3s_eso" {
  display_name = local.eso_app_name
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

resource "azurerm_consumption_budget_subscription" "sandbox" {
  name            = "${var.prefix}-monthly-budget"
  subscription_id = "/subscriptions/${var.subscription_id}"
  amount          = 5
  time_grain      = "Monthly"

  time_period {
    start_date = local.budget_start_date
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    contact_emails = [var.contact_email]
  }

  lifecycle {
    ignore_changes = [
      time_period,
    ]
  }

}
