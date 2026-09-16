locals {
  # Standard resource tags applied across all Azure resources in this module
  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Repository  = "k3s-lab"
  }

    tenant_id = data.azurerm_client_config.current.tenant_id
}

data "azurerm_client_config" "current" {}
