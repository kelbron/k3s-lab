#!/usr/bin/env bash
set -euo pipefail

# Anchor paths to the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Define clean absolute paths for Terraform and manifest directories
TF_DIR="${1:-${TF_DIR:-${REPO_ROOT}/infrastructure/terraform}}"

if [ ! -d "${TF_DIR}" ]; then
    echo "❌ ERROR: Terraform directory '${TF_DIR}' does not exist!" >&2
    exit 1
fi

MANIFEST_DIR="${REPO_ROOT}/manifests/base/external-secrets"
MANIFEST_TEMPLATE="${MANIFEST_DIR}/cluster-secret-store.yaml"

echo "=== Syncing Azure Key Vault Credentials to K3s ==="
echo "  -> Terraform Directory : ${TF_DIR}"


# Extract all dynamic values from Terraform state
echo "Extracting data from Terraform..."
CLIENT_ID=$(terraform -chdir="${TF_DIR}" output -raw client_id)
CLIENT_SECRET=$(terraform -chdir="${TF_DIR}" output -raw client_secret)
KEY_VAULT_URI=$(terraform -chdir="${TF_DIR}" output -raw key_vault_uri)
TENANT_ID=$(terraform -chdir="${TF_DIR}" output -raw tenant_id)

# 🛡️ SAFETY CHECK: Prevent state pollution across environments
CURRENT_VAULT_URI=$(kubectl get clustersecretstore azure-backend -o jsonpath='{.spec.provider.azurekv.vaultUrl}' 2>/dev/null || true)

# Normalize URIs by stripping trailing slashes
CURRENT_VAULT_URI="${CURRENT_VAULT_URI%/}"
KEY_VAULT_URI="${KEY_VAULT_URI%/}"

if [ -n "${CURRENT_VAULT_URI}" ] && [ "${CURRENT_VAULT_URI}" != "${KEY_VAULT_URI}" ]; then
    echo "❌ ERROR: Key Vault URI mismatch detected!" >&2
    echo "   Active Cluster Vault : ${CURRENT_VAULT_URI}" >&2
    echo "   Terraform Output Vault: ${KEY_VAULT_URI}" >&2
    echo "Aborting sync to prevent overwriting cluster secrets." >&2
    exit 1
fi

export KEY_VAULT_URI TENANT_ID

# ensure external-secrets namespace exists
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -

# Inject into K3s idempotently (creates or updates the secret)
echo "Injecting credentials into the external-secrets namespace..."
kubectl create secret generic azure-kv-credentials \
    -n external-secrets \
    --from-literal=ClientID="${CLIENT_ID}" \
    --from-literal=ClientSecret="${CLIENT_SECRET}" \
    --dry-run=client -o yaml | kubectl apply -f -

# 2. Render and Apply the ClusterSecretStore Template
echo "Applying ClusterSecretStore using Terraform outputs..."

envsubst < "${MANIFEST_TEMPLATE}" | kubectl apply -f -

echo "Success! External Secrets Operator is fully wired to Azure."
