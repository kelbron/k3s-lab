variable "environment" {
  description = "Target deployment profile (e.g., local, azure)"
  type        = string
}

variable "location" {
  description = "The Azure region to deploy resources into"
  type        = string
  default     = "East US"
}

variable "resource_group_name" {
  description = "The name of the homelab resource group"
  type        = string
}

variable "key_vault_name" {
  description = "The globally unique name of the Azure Key Vault"
  type        = string
}

variable "app_display_name" {
  description = "Display name for the Entra ID ESO App Registration"
  type        = string
}
