module "core" {
  source = "../../modules/core"

  environment         = "azure"
  location            = "canadacentral"
  resource_group_name = "k3s-lab-test-rg"
  key_vault_name      = "k3s-lab-test-kv-sandbox"
  app_display_name    = "k3s-lab-test-eso-app"
}

resource "azurerm_consumption_budget_subscription" "sandbox" {
  name            = "sandbox-monthly-budget"
  subscription_id = "/subscriptions/466e45fb-c9d7-49b0-80fe-bd6f2ec762fc"
  amount          = 5
  time_grain      = "Monthly"

  time_period {
    start_date = "2026-09-01T00:00:00Z"
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    contact_emails = ["alsamwright@gmail.com"]
  }
}
