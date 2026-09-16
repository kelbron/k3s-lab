terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=5.0.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.9"
    }
  }
}

provider "azurerm" {
  # Prevent Terraform from attempting to register missing resource providers
  resource_provider_registrations = "none"

  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

# Add the Azure Active Directory (Entra ID) provider
provider "azuread" {}
