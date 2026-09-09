# =============================================================================
# 📦 MODULE: K3s Lab
# =============================================================================

# =============================================================================
# DEFAULT WORKSPACE PARAMETERS (Fallback Defaults)
# =============================================================================
USE_PROFILES ?= true	## [Optional] Enable environment variable profile loading. Choices: [true, false]. Default: true
PROFILE ?= local		## [Optional] Target environment profile. Maps to any 'inventory/<name>.env' file. Default: local

# strip trailing whitespace immediately on startup
USE_PROFILES := $(strip $(USE_PROFILES))
PROFILE      := $(strip $(PROFILE))

# Define tools that are required by specific targets
OPTIONAL_TOOLS += terraform kubectl envsubst ssh bats

# =============================================================================
# ENVIRONMENT & PROFILE LOADER
# =============================================================================
ENV_FILE := inventory/$(PROFILE).env
SANITIZE_SCRIPT := ./scripts/workstation/sanitize-env.sh
BUILD_DIR := build
CLEAN_ENV := $(SECURE_TMP_DIR)/clean-$(PROFILE).env

# 🔌 Bypass profile loading for non-operational utility targets (speeds up help, clean, setup, and tests)
BYPASS_PROFILE_TARGETS := help clean clean-module-k3s test test-module-k3s setup setup-githooks check-workstation-tools

MAKECMDGOALS_OR_DEFAULT := $(or $(MAKECMDGOALS),$(.DEFAULT_GOAL))

ifeq ($(filter $(MAKECMDGOALS_OR_DEFAULT),$(BYPASS_PROFILE_TARGETS)),)
  ifeq ($(CI),true)
    # 🟢 CI/CD Mode: Inherit credentials and vars directly from runner environment
    $(info === CI/CD Mode: Inheriting environment variables from runner ===)
    # 🛡️ Bridge variable extraction safely: dump ONLY valueless key names to secure clean_env
    _prep_ci_env := $(shell env | sed -n -E 's/^([A-Za-z0-9_]+)=.+/\1=/p' > $(CLEAN_ENV))
  else ifeq ($(USE_PROFILES),true)
    # 💻 Profiles Enabled: Enforce loud fail-fast boundary if profile is missing
    ifeq ($(wildcard $(ENV_FILE)),)
      $(error ❌ ERROR: Profile configuration file not found at '$(ENV_FILE)'! Create it or set USE_PROFILES=false)
    else ifeq ($(wildcard $(SANITIZE_SCRIPT)),)
       $(error ❌ ERROR: Environment sanitizer script not found at '$(SANITIZE_SCRIPT)'! Create it or set USE_PROFILES=false)
    else
      # 💻 Local Workstation Mode: Clean, include, and export the selected profile file securely.
      $(info === Local Workstation Mode: Sanitizing and loading $(ENV_FILE) ===)
      $(info $(shell $(SANITIZE_SCRIPT) $(ENV_FILE) $(CLEAN_ENV)))
      include $(CLEAN_ENV)
      export  # ai-ignore: Necessary to propagate loaded configurations to envsubst templates during manifest generation
    endif
  endif
endif

# Centralized staging files in a secure, unprivileged directory
STAGE_kustomize-argocd := $(SECURE_TMP_DIR)/kustomize-argocd.yaml
STAGE_kustomize-argocd-core := $(SECURE_TMP_DIR)/kustomize-argocd-core.yaml
DAY0_LOCK := /etc/rancher/k3s/.day0_lock

# =============================================================================
# 🛠️ LOCAL HELPER FUNCTIONS AND INLINE EVALUATED VARIABLES
# =============================================================================
# Local stream-processing commands or configurations unique to this module.
# Evaluated strictly inside recipes to prevent parse-time latency.
EXTRACT_VARS := ./scripts/workstation/extract-manifest-vars.sh $(CLEAN_ENV)

# Stream-based Bounded Envsubst Macro
# Reads from stdin, extracts variables from the specified template file, and writes to stdout.
# If variables are found, it runs envsubst. If empty, it passes stdin straight through via cat.
# Wrapped in a subshell group ( ) to safely preserve stream buffers in pipelines.
# Usage: cat input.yaml | $(call safe_envsubst,template.yaml) > output.yaml
define safe_envsubst
$(if $(strip $(1)),\
    (VARS=$$( (if [ -f "$(1)" ]; then cat "$(1)"; else cat $(1); fi || true) | $(EXTRACT_VARS) ); \
    if [ -n "$$VARS" ]; then \
        envsubst "$$VARS"; \
    else \
        cat; \
    fi),\
cat\
)
endef

# =============================================================================
# ⚓ DYNAMIC TARGET DECLARATIONS (.PHONY & Double-Colon overrides)
# =============================================================================
# Safely appends this module's targets to the global build index.
.PHONY: day0-bare-metal platform-core gitops-apps \
		check-day0-lock write-day0-lock \
		provision-nodes deploy-ha-dns sync-azure-secrets apply-globals \
  		kustomize-argocd bootstrap-argocd \
		deploy-vaultwarden deploy-vw-backup \
		bundle test-module-k3s clean-module-k3s

# ==============================================================================
# 🚀 MACRO ENTRY POINTS (The platform lifecycle)
# ==============================================================================

# DAY 0: Bare Metal & Host OS Layer (Locked to run-once; override with FORCE=true)
day0-bare-metal: guard-setup check-day0-lock provision-nodes deploy-ha-dns write-day0-lock ## [Day 0] Provision bare-metal nodes and deploy HA DNS (Keepalived + Pi-hole)
	@echo "✅ [Day 0 Complete] Physical hosts provisioned and routing is stable."

# DAY 1: Platform Core & Control Plane (Gated by TDD Workstation Unit Tests)
platform-core: test sync-azure-secrets apply-globals bootstrap-argocd ## [Day 1] Bootstrap platform core (Secrets, Globals, Argo CD GitOps Controller)
	@echo "🚀 [Platform Core Complete] Secrets injected, global environments active, and GitOps controller live."

# DAY 2: GitOps Applications (Delegates all standard deployments to Argo CD)
gitops-apps: bootstrap-argocd ## [Day 2] Delegate all application deployments to Argo CD GitOps controller
	@echo "=== Day 2: Declarative GitOps Sync ==="
	@echo "Platform control handed off to Argo CD."
	@echo "To apply app updates (Vaultwarden, backup CronJobs, etc.), simply commit changes to Git."
	@echo "Argo CD will automatically heal drift and reconcile state in the cluster."

# ==============================================================================
# 🔒 DAY 0 PROTECTION CONTROLS (Run-Once Safety Guards)
# ==============================================================================

check-day0-lock: guard-setup ## Verify if the Day 0 bare-metal layer is already provisioned
ifeq ($(FORCE),true)
	@echo "⚠️ FORCE=true specified. Bypassing Day 0 run-once safety guards!"
else
	@echo "🔍 Checking if Day 0 bare-metal layer is already provisioned..."
	$(call require_tools,ssh)
	@if ssh -n -q -o BatchMode=yes "$(CONTROL_PLANE_IP)" "[ -f $(DAY0_LOCK) ]"; then \
		echo "❌ ERROR: Day 0 bare-metal setup has already been run on this cluster."; \
		echo "   To prevent accidental host network flushes or K3s control-plane corruption,"; \
		echo "   this target is locked."; \
		echo ""; \
		echo "   To override this lock and force execution, append FORCE=true:"; \
		echo "   make day0-bare-metal FORCE=true"; \
		echo ""; \
		exit 1; \
	fi
	@echo "✅ No prior Day 0 lock detected. Proceeding..."
endif

write-day0-lock: guard-setup
	@echo "🔒 Writing Day 0 run-once lock to control plane node..." ## Write the Day 0 lock file to the control plane node
	$(call require_tools,ssh)
	@ssh -n -q -o BatchMode=yes "$(CONTROL_PLANE_IP)" "sudo -n mkdir -p /etc/rancher/k3s && sudo -n touch $(DAY0_LOCK)"

# ==============================================================================
# ⚙️ DETAILED OPERATIONAL TARGETS
# ==============================================================================

kustomize-argocd: guard-setup ## Compile Kustomize AST and substitute environment variables
	@echo "=== Compiling and Verifying ArgoCD Kustomize build ==="
	$(call require_tools,envsubst kubectl)
	@if [ -z "$$(find manifests/base/argocd -name '*.yaml.template' -print -quit)" ]; then \
		echo "❌ ERROR: No manifest templates found in manifests/base/argocd/!" && exit 1; \
	fi
	@kubectl kustomize manifests/base/argocd/ | $(call safe_envsubst,manifests/base/argocd/*.yaml) \
	> $(STAGE_kustomize-argocd)
	@echo "✅ Kustomize validation succeeded! Rendered manifest cached at $(STAGE_kustomize-argocd)"

bootstrap-argocd: kustomize-argocd ## Deploy Argo CD controller in two-phase sync pass
	@echo "=== Deploying Argo CD (GitOps Controller) ==="
	@echo "=== Phase 1: Filtering & Deploying Argo CD Base (No Custom Kinds) ==="
#   Uses standard library Python to split and filter out custom kinds (Application, AppProject)
	$(call require_tools,python3 kubectl)
	$(call run_script,./scripts/workstation/filter_manifest.py $(STAGE_kustomize-argocd) $(STAGE_kustomize-argocd-core))
	kubectl apply --server-side --force-conflicts -f $(STAGE_kustomize-argocd-core)

	@echo "=== Waiting for Custom Resource Definitions to stabilize ==="
#   We block here until the API server officially establishes the Argo CD custom schemas.
	kubectl wait --for=condition=Established crd/applications.argoproj.io crd/appprojects.argoproj.io crd/applicationsets.argoproj.io --timeout=60s

	@echo "=== Phase 2: Applying Custom Resources ==="
#   Re-applies the complete manifest including the now-valid custom resources
	kubectl apply --server-side --force-conflicts -f $(STAGE_kustomize-argocd)
	@rm -f $(STAGE_kustomize-argocd-core)
	@echo "🚀 Argo CD successfully bootstrapped!"

provision-nodes: guard-setup ## Bootstrap K3s server and agent nodes over SSH
	@echo "=== Bootstrapping K3s Nodes ==="
	$(call require_tools,ssh envsubst)
	$(call run_script,./scripts/bare-metal/bootstrap.sh)

deploy-ha-dns: guard-setup ## Deploy Keepalived and Pi-hole for high-availability DNS routing
	@echo "=== Deploying High-Availability DNS ==="
	$(call require_tools,ssh)
	$(call run_script,./scripts/bare-metal/deploy-ha-dns.sh)

deploy-vaultwarden: guard-setup ## Deploy standalone Vaultwarden Docker container
	@echo "=== Deploying Standalone Vaultwarden ==="
	$(call require_tools,ssh)
	$(call run_script,./scripts/bare-metal/deploy-vaultwarden.sh)

sync-azure-secrets: guard-setup ## Sync Azure Key Vault credentials to K3s cluster
	@echo "=== Syncing Azure Key Vault Credentials to K3s ==="
	$(call require_tools,ssh)
	$(call run_script,./scripts/azure/sync-azure-secrets.sh)

apply-globals: guard-setup ## Inject homelab global environment ConfigMaps
	@echo "=== Injecting global configuration from environment variables ==="
	$(call require_tools,envsubst kubectl)
	@$(call safe_envsubst,manifests/base/globals/homelab-globals.yaml) \
	< manifests/base/globals/homelab-globals.yaml | kubectl apply -f -

deploy-vw-backup: guard-setup ## Deploy standalone Vaultwarden backup CronJob manifest
	@echo "=== Deploying Vaultwarden Backup CronJob ==="
	$(call require_tools,envsubst kubectl)
	@$(call safe_envsubst,manifests/apps/vaultwarden/vaultwarden-backup-cronjob.yaml) \
	< manifests/apps/vaultwarden/vaultwarden-backup-cronjob.yaml | kubectl apply -f -

bundle: guard-setup ## Bundle the active codebase into a single markdown for AI agent consumption
	@echo "=== Bundling codebase into a single markdown file ==="
	$(call run_script,./scripts/workstation/bundle-codebase.sh)

# ==============================================================================
# 🧪 MODULE TESTS
# ==============================================================================
TEST_MODULE_TARGETS += test-module-k3s

test-module-k3s: # run module specific tests that are not covered by the core python tests
	$(call require_tools, bats)
	$(call print_separator, Running K3s-lab module BATS tests$(if $(strip $(BATS_OPTS)), with options $(BATS_OPTS)))
	@bats $(BATS_OPTS) tests/
	@echo "✅ k3s-lab module tests complete."

# ==============================================================================
# 🧹 CLEANUP CONTROLS
# ==============================================================================
CLEAN_MODULE_TARGETS += clean-module-k3s

is_build_dir_safe = $(and \
	$(1),\
	$(filter-out . ..,$(1)),\
	$(if $(findstring ..,$(1)),,true),\
	$(filter-out ~%,$(1)),\
	$(if $(filter /%,$(1)),$(filter $(CURDIR)/%,$(1)),true),\
	$(filter-out $(CURDIR) $(CURDIR)/,$(1))\
)

# clean-module-k3s: # remove build folder. Parent clean runs clean_core first
# 	$(call print_separator,k3s-lab module )
# #   Only purge BUILD_DIR if it is a safe relative folder name
# 	$(if $(call is_build_dir_safe,$(BUILD_DIR)),\
# 		@rm -rf "$(BUILD_DIR)" && echo "✅ Purged local build directory: $(BUILD_DIR)",\
# 		@echo "⚠️ Skipped BUILD_DIR purge: Absolute path, home folder, or directory traversal detected"\
# 	)

clean-module-k3s: # remove build folder. Parent clean runs clean_core first
	$(call print_separator,k3s-lab module )
# 	Only purge BUILD_DIR if it is a safe relative folder name
	@if [ -n "$(call is_build_dir_safe,$(BUILD_DIR))" ]; then \
		rm -rf "$(BUILD_DIR)" && echo "✅ Purged local build directory: $(BUILD_DIR)"; \
	else \
		echo "⚠️ Skipped BUILD_DIR purge: Absolute path, home folder, or directory traversal detected"; \
	fi
