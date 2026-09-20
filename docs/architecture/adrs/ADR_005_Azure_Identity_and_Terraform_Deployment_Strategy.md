# ADR 005: Azure Identity & Terraform Deployment Strategy

## Status
Active

## Context
During the provisioning of external cloud dependencies (e.g., Azure Key Vault, Microsoft Entra ID App Registrations) using Terraform to avoid Azure Portal "ClickOps" [2], several permission boundaries, tooling quirks, and security defaults were encountered. This document serves as a permanent reference for these configurations to prevent deployment blockers during future infrastructure runs.

## Summary of Findings

### 1. WSL Authentication & Azure Security Defaults
* **The Issue:** Elevating an internal Entra ID account (e.g., `alistair@`) to a highly privileged role like "Application Administrator" immediately triggers Azure's "Security Defaults," mandating interactive Multi-Factor Authentication (MFA). However, running `az login` inside WSL often fails to render the interactive browser prompt, resulting in a silent `AADSTS530035: Access has been blocked` error or a hanging device-code flow.
* **The Solution:** You must force WSL to launch a native Windows browser to handle the MFA hand-off. Before authenticating, export the direct path to your Windows browser in the WSL terminal:
  ```bash
  export BROWSER='/mnt/c/Program Files/Google/Chrome/Application/chrome.exe'
  az login --tenant "<tenant_id>"
  ```

### 2. Azure Permission Boundaries (Identity vs. Resource)
* **The Issue:** Azure operates on two strictly isolated permission planes: Entra ID (Directory Roles) and Azure Resource Manager (RBAC Roles).
* **The Finding**: Holding the `Contributor` role allows Terraform to build infrastructure (like the Key Vault), but Azure explicitly blocks Contributors from modifying access permissions.
* **The Solution**: To successfully execute an `azurerm_role_assignment` (e.g., granting the K3s Service Principal the "Key Vault Secrets User" role), the executing user must hold the **Role Based Access Control Administrator**, **User Access Administrator**, or **Owner** role at the subscription level to possess the required `Microsoft.Authorization/roleAssignments/write permission`.  **User Access Administrator** is recommended.

### 3. Terraform Provider Quirks (`azuread vs. azurerm`)
* **The Issue:** The Azure Active Directory (`azuread`) and Azure Resource Manager (`azurerm`) Terraform providers require different ID formats when referencing the exact same Service Principal.
* **The Finding:** `azuread_service_principal_password` expects the Service Principal `.id` value (the fully qualified Entra ID path, e.g. `/servicePrincipals/<uuid>`), while `azurerm_role_assignment` expects the Service Principal `.object_id` value (the raw 36-character UUID).
* **The Solution:** Use `.id` for `azuread` provider resources and `.object_id` for `azurerm` role assignments to avoid provider mismatch and failed deployments.

### 4. Terraform State Amnesia
* **The Issue:** Force-killing Terraform mid-execution (e.g., pressing Ctrl + C twice during a network stall) can corrupt or drop the local `terraform.tfstate` file.
* **The Finding:** If this happens, Terraform forgets what it has already built and will attempt to blindly recreate existing resources, leading to deployment crashes.
* **The Solution:** Never force-kill Terraform during resource creation. If state amnesia occurs, manually delete orphaned resources in the Azure Portal or use `terraform import` to sync the existing Azure Resource IDs back into the local state file.

### 5. Billing and Credit Visibility
* **The Issue:** The Global Administrator or Subscription Owner does not automatically have visibility into billing credits in the standard Azure Portal `Cost Management` blade due to Azure's strict financial scope separation.
* **The Finding:** For credits acquired via sponsorships, Visual Studio, or partner grants, balances are completely isolated from the main portal and must be checked at the dedicated external tracking site (`microsoftazuresponsorships.com`).
* **The Solution:** Use the dedicated external tracking site (`microsoftazuresponsorships.com`) instead of the standard Azure billing portal when reviewing sponsorship or grant credit balances.

### Section 6: Remote State Locking and Execution Strategy (HCP Terraform)

#### Context
Prior to this amendment, Terraform state for Azure cloud dependencies was maintained locally (`terraform.tfstate`). This introduced risks of state amnesia/corruption (if execution was interrupted) and lacked concurrent execution locks or centralized audit history. While evaluating remote backends, commercial B2B options (e.g., Spacelift) were rejected due to high entry costs ($20k+/yr enterprise focus, 14-day trial limits) and lack of a permanent free tier suitable for a homelab environment.

#### Decision
We will standardize on **HCP Terraform (Terraform Cloud)** under the **`kelbron`** organization using the **Free Tier** (permanent allocation supporting up to 500 managed resources and unlimited users).

1. **Workspace Architecture:**
   - Workspace Name: `k3s-lab-azure`
   - Organization: `kelbron` (aligned with GitHub Organization name for VCS integration)
2. **Execution Mode:**
   - **Local Execution Mode (`execution_mode = "local"`):** Terraform `plan` and `apply` operations execute on the local workstation CLI (where relative module paths like `../../modules/core` are accessible on disk), while state storage and state locking are offloaded to HCP Terraform.
3. **Backend Declaration:**
   - Isolated in `backend.tf` within the root Terraform module (`infrastructure/terraform/backend.tf`).

#### Code Pattern (`backend.tf`)
```hcl
terraform {
  required_version = ">= 1.5.0"

  cloud {
    organization = "kelbron"

    workspaces {
      name = "k3s-lab-azure"
    }
  }
}
```

#### Consequences & Benefits
- **Zero Cost & Generous Quota:** 500 managed resources easily covers the homelab footprint (<10 cloud resources) at $0/month.
- **State Protection:** Automatic remote state encryption, locking during applies, and full version history prevent local file loss or state corruption.
- **Local Module Compatibility:** Local CLI execution mode avoids remote runner relative path errors (`../../modules`) while maintaining cloud state integrity.

