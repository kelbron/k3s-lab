variable "prefix" {
  type        = string
  description = "Unique naming prefix for this deployment instance (e.g. k3s-lab-test)"
  default     = null
}

variable "resource_group_name" {
  type        = string
  default     = null
  description = "Explicit Resource Group name override"
}

variable "key_vault_name" {
  type        = string
  default     = null
  description = "Explicit Key Vault name override"
}

variable "eso_app_name" {
  type        = string
  default     = null
  description = "Explicit ESO App Registration display name override"
}

variable "subscription_id" {
  type        = string
  description = "Target Azure Subscription ID"
}

variable "location" {
  type        = string
  description = "Azure region for deployment"
  default     = "canadacentral"
}

variable "repository_name" {
  type        = string
  description = "Name of the Git repository driving this clone"
  default     = "k3s-lab"
}

variable "custom_tags" {
  type        = map(string)
  description = "Optional extra tags"
  default     = {}
}

variable "contact_email" {
  description = "Email address for budget alert notifications"
  type        = string
}

variable "budget_start_date" {
  type        = string
  description = "Start date for the subscription budget (must be 1st of the month in UTC)"
  default     = null
}
