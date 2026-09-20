locals {

  resource_group_name      = var.resource_group_name != null ? var.resource_group_name : (var.prefix != null ? "${var.prefix}-rg" : null)
  key_vault_name      = var.key_vault_name != null ? var.key_vault_name : (var.prefix != null ? "${var.prefix}-kv-sandbox" : null)
  eso_app_name = var.eso_app_name != null ? var.eso_app_name : (var.prefix != null ? "${var.prefix}-eso-app" : null)

  # If var.budget_start_date is explicitly passed, use it;
  # otherwise dynamically format current UTC timestamp to 1st of current month
  budget_start_date = var.budget_start_date != null ? var.budget_start_date : formatdate("YYYY-MM-01'T'00:00:00'Z'", timestamp())

  # Merge base managed tags with any custom tags passed by the clone
  common_tags = merge(
    {
      ManagedBy  = "Terraform"
      Repository = var.repository_name
    },
    var.custom_tags
  )

  tenant_id = data.azurerm_client_config.current.tenant_id
}

# Top-level data source lookup
data "azurerm_client_config" "current" {}
