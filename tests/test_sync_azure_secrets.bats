#!/usr/bin/env bats

# ==============================================================================
# 🧪 BATS Behavioral Contract Test Suite - Azure Secret Sync Safety
# Complies with ADR-015 (TDD Standards) & ADR-011 (Automation Standards)
# ==============================================================================

setup() {
    TEST_DIR="$(cd "$BATS_TEST_DIRNAME" && pwd)"
    REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

    export SCRIPT_DIR="${REPO_ROOT}/scripts/azure"

    [ -d "$SCRIPT_DIR" ] || {
        echo "SETUP ERROR: SCRIPT_DIR not found at '$SCRIPT_DIR'" >&2
        return 1
    }

    SCRIPT_UNDER_TEST="${SCRIPT_DIR}/sync-azure-secrets.sh"

    [ -f "${SCRIPT_UNDER_TEST}" ] || {
        echo "SETUP ERROR: cannot find '$SCRIPT_UNDER_TEST'" >&2
        return 1
    }

    load "${REPO_ROOT}/tests/support/test_helpers.bash"

    # Create an isolated temporary folder for test artifacts
    TEST_TEMP_DIR="$(mktemp -d -t k3s-sync-secrets-test.XXXXXX)"
    export TEST_TEMP_DIR

    telemetry_log_init ${TEST_TEMP_DIR} telemetry.log

    # Create mock terraform directory
    MOCK_TF_DIR="${TEST_TEMP_DIR}/tf-mock"
    mkdir -p "$MOCK_TF_DIR"
    # touch "${MOCK_TF_DIR}/main.tf"
    # touch "${MOCK_TF_DIR}/outputs.tf"
    export MOCK_TF_DIR

    # Create mock manifest directory and template
    MOCK_MANIFEST_DIR="${TEST_TEMP_DIR}/manifests/base/external-secrets"
    mkdir -p "$MOCK_MANIFEST_DIR"
    cat <<'EOF' > "${MOCK_MANIFEST_DIR}/cluster-secret-store.yaml"
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: azure-backend
spec:
  provider:
    azurekv:
      authType: ServicePrincipal
      vaultUrl: "${KEY_VAULT_URI}"
      tenantId: "${TENANT_ID}"
EOF


    # Mocks
    terraform() {
        local raw_cmd="terraform $*"
        local chdir="-"
        local subcommand="-"

        # Extract -chdir argument if present
        if [[ "$*" =~ -chdir=([^[:space:]]+) ]]; then
            chdir="${BASH_REMATCH[1]}"
        fi

        # Extract subcommand (first non-flag argument)
        for arg in "$@"; do
            if [[ "$arg" != -* ]]; then
                subcommand="$arg"
                break
            fi
        done

        # Schema: TYPE|NODE|ACTION|DEST_OR_TARGET|SRC_OR_PAYLOAD|MODE_OR_ARGS|RAW_COMMAND
        log_telemetry "TERRAFORM" "local" "EXEC" "$subcommand" "-" "chdir:${chdir}" "$raw_cmd"

        case "$*" in
            *client_id*) echo "mock-client-id-123" ;;
            *client_secret*) echo "mock-secret-456" ;;
            *key_vault_uri*) echo "${MOCK_TF_VAULT_URI}" ;;
            *tenant_id*) echo "mock-tenant-789" ;;
        esac
    }

    kubectl() {
        local raw_cmd="kubectl $*"
        local subcommand="${1:-}"

        # Schema: TYPE|NODE|ACTION|DEST_OR_TARGET|SRC_OR_PAYLOAD|MODE_OR_ARGS|RAW_COMMAND
        log_telemetry "KUBECTL" "local" "EXEC" "$subcommand" "-" "args:${*:2}" "$raw_cmd"


        if [[ "$*" == *"get clustersecretstore azure-backend"* ]]; then
            echo "${MOCK_CLUSTER_VAULT_URI}"
            return 0
        fi

        # Upstream dry-run producer (writes YAML into pipe)
        if [[ "$*" == *"create"* ]] && [[ "$*" == *"-o yaml"* ]]; then
            echo "apiVersion: v1; kind: Namespace; metadata: {name: external-secrets}"
            return 0
        fi

        # Downstream apply consumer (drains pipe to avoid SIGPIPE 141)
        if [[ "$*" == *"apply"* ]]; then
            cat > /dev/null 2>&1 || true
            return 0
        fi

            return 0
        }

    export -f terraform kubectl
}

teardown() {
    log_test_execution "$TEST_TEMP_DIR"
    cleanup_test_dir "$TEST_TEMP_DIR"
}

# ==============================================================================
# 🛡️ SAFETY GATE TESTS
# ==============================================================================

@test "validation: fails fast when terraform vault URI differs from active cluster vault URI" {
    export MOCK_TF_VAULT_URI="https://mock-sandbox-vault.vault.azure.net/"
    export MOCK_CLUSTER_VAULT_URI="https://mock-local-vault.vault.azure.net/"

    run "${SCRIPT_UNDER_TEST}" "$MOCK_TF_DIR"

    assert_failure
    assert_output --partial "Key Vault URI mismatch detected"
    assert_output --partial "Aborting sync to prevent overwriting cluster secrets"

    # validate terraform called with the correct chdir argument - should really check that every terraform call did
    assert_file_contains "^TERRAFORM|local|EXEC|output|-|chdir:${MOCK_TF_DIR}|" "$TELEMETRY_LOG"
    # cluster store state was checked before any create or apply side-effects occurred
    assert_file_contains "^KUBECTL|local|EXEC|get|-|args:clustersecretstore azure-backend" "$TELEMETRY_LOG"

    # execution halted immediately — no create or apply side-effects occurred
    assert_file_not_contains "^KUBECTL|local|EXEC|create|" "$TELEMETRY_LOG"
    assert_file_not_contains "^KUBECTL|local|EXEC|apply|" "$TELEMETRY_LOG"
}

@test "behaviour: succeeds when terraform vault URI matches active cluster vault URI" {
    export MOCK_TF_VAULT_URI="https://mock-local-vault.vault.azure.net/"
    export MOCK_CLUSTER_VAULT_URI="https://mock-local-vault.vault.azure.net/"

    run "${SCRIPT_UNDER_TEST}" "$MOCK_TF_DIR"

    assert_success
    assert_output --partial "Success! External Secrets Operator is fully wired"

    # validate terraform output called 4 times with the correct chdir argument
    local valid_tf_calls
    valid_tf_calls=$(grep -c "^TERRAFORM|local|EXEC|output|-|chdir:${MOCK_TF_DIR}|" "$TELEMETRY_LOG")

    local total_tf_calls
    total_tf_calls=$(grep -c "^TERRAFORM|" "$TELEMETRY_LOG" || true)

    # assert both: exactly 4 expected calls, and 0 stray/unanchored calls
    assert [ "$valid_tf_calls" -eq 4 ]
    assert [ "$total_tf_calls" -eq 4 ]

    # cluster store state was checked before any create or apply side-effects occurred
    assert_file_contains "^KUBECTL|local|EXEC|get|-|args:clustersecretstore azure-backend" "$TELEMETRY_LOG"

    # external-secrets namespace creation was queued
    assert_file_contains "^KUBECTL|local|EXEC|create|-|args:namespace external-secrets" "$TELEMETRY_LOG"
    # manifests were applied cleanly
    assert_file_contains "^KUBECTL|local|EXEC|apply|-|args:-f -|" "$TELEMETRY_LOG"

}
