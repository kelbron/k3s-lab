# 🛡️ k3s-lab: Enterprise-Aligned Homelab & Local-Only AI Platform

[![TDD Pipeline](https://img.shields.io/badge/TDD-BATS%20%2B%20Pytest-brightgreen)](#-test-driven-development-tdd--quality-gates)
[![GitOps](https://img.shields.io/badge/GitOps-Argo%20CD-blue)](#-automation--control-plane-boundaries)
[![IaC](https://img.shields.io/badge/IaC-Terraform%20(Azure%20%2B%20HCP)-purple)](#-declarative-cloud-infrastructure--regional-bindings)
[![Security](https://img.shields.io/badge/Zero%20Trust-Entra%20ID%20%2B%20ESO-orange)](#-zero-trust-identity--secrets-governance)

An enterprise-grade, bare-metal **Kubernetes (K3s)** cluster and automation toolchain designed under strict **Everything-as-Code (EaC)**, **Zero Trust**, and **Test-Driven Development (TDD)** principles. 

This repository serves as a live engineering environment to explore **AI-assisted software engineering**, automated pre-commit security governance, and the secure execution of **local-only, sovereign AI models (Ollama)**.

---

## 🌐 Repository Ecosystem & Governance Lineage

To maintain strict architectural consistency and prevent configuration drift, `k3s-lab` is part of a standardized multi-repo strategy:

* **Baseline Template Repository**: Instantiated from a standardized project template that establishes the Everything-as-Code directory layout, Makefile orchestration macros, and baseline TDD test harnesses.
* **Git Governance Framework (`git-governance`)**: Pre-commit security gates, ShellCheck static audits, repository boundary rules, and commit message ticket-linking standards are backed by a private **`git-governance`** policy repository, ensuring unified compliance across all internal projects.

---

## 🎯 Strategic Objectives

1. **Enterprise Mimesis on Bare-Metal**: Replicate cloud-native enterprise security patterns (inspired by Microsoft Azure and zero-trust standards) on minimal physical Dell OptiPlex hardware.
2. **AI-Driven Software Delivery Lifecycle**: Leverage agentic AI, automated pre-commit checks, and an in-repo AI PR review engine, and source-grounded context bundles to accelerate development while enforcing security gates.
3. **Local AI & Data Sovereignty Research**: Host **Ollama** locally for AI coding and research, providing a secure, isolated compute plane ensuring zero telemetry or private codebase data leaves the perimeter.

---

## 🏛️ Architectural Pillars & Security Controls

### 🔐 1. Zero Trust Identity & Ingress Routing
* **Identity Provider Integration**: User traffic is gated behind **Microsoft Entra ID (Azure CIAM)** and **Traefik ForwardAuth**, enforcing OIDC claim validation (`preferred_username`) and group-based RBAC (`Homelab-Cluster-Admins`) before traffic reaches internal workloads.
* **Automated Wildcard TLS**: Utilizes **cert-manager** integrated with the **deSEC DNS-01 ACME challenge webhook** to dynamically generate and auto-renew Let's Encrypt wildcard certificates (`*.samjam.dedyn.io`) without exposing internal service names.
* **Split-Horizon DNS & High Availability**: Internal DNS resolution is managed via dual **Pi-hole** containers running directly on host OS instances (bypassing K3s for break-glass availability) backed by a floating **Keepalived Virtual IP (VIP: 192.168.1.53)**.

### 🔑 2. Secrets Management & Plane Separation
To mitigate container compromise risks, secrets management is strictly segmented into two control planes:
* **Machine Secrets (System-to-System)**: API tokens, database passwords, and cloud credentials are store-encrypted in **Azure Key Vault (AKV)**. The **External Secrets Operator (ESO)** running in K3s authenticates via an Entra ID Service Principal, pulling secrets dynamically into ephemeral cluster memory.
* **Human Secrets (Break-Glass Recovery)**: Operational credentials (router access, host root logins) are managed in a standalone **Vaultwarden** instance on host `kc02`. A daily Kubernetes `CronJob` exports password-encrypted vault backups to local host storage and offsite S3 storage, enabling offline recovery via **KeePassXC** if the cluster goes down.

### 🇨🇦 3. Declarative Cloud Infrastructure & Regional Bindings
Managed strictly via **Terraform** and **HCP Terraform (Free Tier)** to eliminate Azure Portal "ClickOps":
* **Regional Isolation**: Primary cloud dependencies are explicitly bound to Azure's **Canada Central (`canadacentral`)** region.
* **Budget & Cost Governance**: Provisions an automated subscription consumption budget (`azurerm_consumption_budget_subscription`) capped at **\$5/month**, with email alerts triggered at 80% threshold.
* **Entra ID & Key Vault IaC**: Uses the `azuread` and `azurerm` providers to declaratively provision App Registrations (`k3s-eso-app`), Service Principals, Key Vaults, and RBAC role assignments (`Key Vault Secrets User`).
* **Agile Planning IaC**: Uses the `azuredevops` Terraform provider to declaratively map workspace settings, security access levels, and GitHub service connections for **Azure Boards**.

### 🤖 4. CI/CD Security Gates & Automated AI PR Reviews
All code pushes and pull requests undergo multi-layered automated inspection before reaching `main`:
* **Workstation Pre-Commit Hooks**: Enforced via `githooks/pre-commit` and Makefile routines:
  * `audit-shellcheck.sh`: Runs **ShellCheck** static analysis on all staged shell scripts.
  * `audit-repo-secrets.sh`: Scans for high-entropy strings, plain-text API tokens, and untracked `.env` files.
  * `audit-workspace-boundaries.sh`: Enforces **ADR 002** subfolder encapsulation (blocking prohibited flat-file Kubernetes manifests).
* **Automated AI PR Review Engine (`query_gemini_review.py`)**: An in-repo Python automation that extracts unified Git diffs (`pr_changes.diff`), parses modified file/line indices, enforces inline `ai-ignore` suppression rules, and queries Gemini API to post line-anchored security annotations (CWEs, command injections, credential leaks) directly onto GitHub PRs.

### 🧠 5. Grounded AI Context Pipeline & Knowledge Sync
To eliminate AI hallucinations and ensure AI-generated code strictly adheres to project ADRs:
* **Automated Codebase Snapshot (`bundle-codebase.sh`)**: A workstation git hook automatically triggers `bundle-codebase.sh` on commit, compiling all tracked scripts, Terraform definitions, and Kubernetes manifests into a single high-density context snapshot (`docs/planning/active-codebase.md`).
* **Live Google Drive Knowledge Sync**: The compiled snapshot and architecture documents (`docs/`) are auto-synced to Google Drive on commit to serve as live grounding sources for Gemini Notebook / NotebookLM.
* **Restricted Source Grounding**: NotebookLM is configured to restrict its reasoning exclusively to this source bundle, ensuring all AI-assisted architecture recommendations, code generation, and debugging are 100% grounded in verified project decision records.

### 🧪 6. Test-Driven Development (TDD)
Adhering to **ADR 015**, all automation scripts, Makefile targets, and manifest structures follow a strict TDD lifecycle:
* **BATS Behavioral Testing**: Bash scripts (`bootstrap.sh`, `apply-k3s-node-config.sh`) are tested against in-memory mocks (`spy_install`, `journalctl`, `ssh` telemetry) asserting fast failures on unprivileged execution or missing dependencies.
* **Pytest Harness**: Subprocess-driven integration tests validate path safety boundaries, temporary secure directories (`/tmp/ops-$(UID)-$(HASH)`), and environment variable extraction scripts.

### ⚙️ 7. Automation & Control Plane Boundaries
Automation responsibilities are cleanly divided into three isolated execution layers to eliminate tool collision:
1. **Bare Metal OS & Bootstrapping (Bash / Make)**: Physical Dell OptiPlex minimal Debian OS configuration, static IP bindings, and systemd daemon management.
2. **Modular Workstation Build Toolchain (`Makefile` / `.mk`)**:
   * Uses dynamic extension loading (`-include $(wildcard *.mk)`) to automatically import self-registering feature Makefiles without editing root code.
   * Extensions register custom test and cleanup hooks into `TEST_MODULE_TARGETS` and `CLEAN_MODULE_TARGETS`.
3. **Cloud Dependencies (Terraform / HCP)**: Azure Key Vault, Entra ID App Registrations, and RBAC role assignments managed via declarative HCL with remote state locking in **HCP Terraform**.
4. **Cluster Workloads (Argo CD / GitOps)**: Internal Kubernetes applications, CRDs, and ingress rules managed declaratively by Argo CD syncing the `manifests/` directory.

---

## 📐 Dual-Plane Agile SDLC (Azure Boards + GitHub)

Per **ADR 014**, work tracking uses a dual-plane architecture that connects **Azure Boards** (Product Plane) bidirectionally with **GitHub** (Code Plane) via the native Azure Boards GitHub App:

```text
  [ PRODUCT PLANE ]                         [ CODE PLANE ]
Azure Boards (Web GUI) ──[GitHub App Sync]──> GitHub Repository (Git / IDE)
 - Epics, Stories, Bugs                     - Conventional Branches (`feat/`, `fix/`)
 - Acceptance Criteria                      - pre-commit Quality Gates
 - Stakeholder Progress                     - `AB#<ID>` Traceability Hooks
Commits and PRs reference work items using AB#<ID> syntax (e.g., git commit -m "feat(security): enforce allowPrivilegeEscalation false AB#104"), automatically linking VCS events to Azure DevOps work items
.
📂 Directory Structure
k3s-lab/
├── core/k3s-config/      # Baseline K3s systemd unit files & templates
├── docs/                 # Architecture Reference Documents (ARDs) & runbooks
├── infrastructure/
│   ├── nodes/            # Node-specific K3s server/agent configs
│   └── terraform/        # Azure Key Vault, Entra ID & Azure DevOps IaC definitions
├── inventory/            # Environment profiles (local.env, local.tfvars, global.env etc not under version control)
├── manifests/
│   ├── apps/             # User workloads (Vaultwarden, Portainer)
│   └── base/             # Infrastructure manifests (cert-manager, external-dns, ESO, Argo CD) 
├── scripts/              # Idempotent execution scripts (bare-metal, azure, workstation)
│   ├── azure/            # Imperative secret sync scripts
│   ├── bare-metal/       # Physical Dell hardware & Debian node provisioning
│   └── workstation/      # Linter audits & AI PR review scripts (`query_gemini_review.py`)
├── tests/                # BATS behavioral tests & Python pytest harness
├── githooks/             # Workstation pre-commit / commit-msg security gates
└── Makefile              # Workstation entry point & task runner

🚀 Cluster Bootstrap Quickstart
# 1. Onboard local workstation environment (creates .venv, maps git hooks)
make setup
Checks that all required tools are available on the workstation, maps githooks and tags setup as complete

# 2. Run local test suite
make test

# 3. Clean secure temporary and build folders
make clean

# 4. Execute bare-metal node provisioning sequence
make day-0-bare-metal
Provisions kubernetes nodes, deploys redundant dns, creates and configures Azure Key Vault, Budget and Azure Board assets, adds a day 0 lock indicating that day 0 tasks are complete

#5. Deploy platform core and control plane
make platform-core
Syncs the secrets stored in Azure Key Vault with the k3s cluster, imports the global home lab configmap, deploys ArgoCD manifests

#6 Bootstrap Gitops to delegate all standard deployments to ArgoCD
make bootstrap-gitops



