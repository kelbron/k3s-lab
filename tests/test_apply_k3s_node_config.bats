#!/usr/bin/env bats

# ==============================================================================
# 🧪 Bash Automated Testing System (BATS) - Behavioral Contract Test Suite
# ==============================================================================

# ⚙️ HELPER: Standard setup for every test case
setup() {
    TEST_DIR="$(cd "$BATS_TEST_DIRNAME" && pwd)"
    REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)" # Adjust '../..' if nested in test/lib/

    # Define SCRIPT_DIR
    export SCRIPT_DIR="${REPO_ROOT}/scripts/bare-metal"
    local source_script="${SCRIPT_DIR}/apply-k3s-node-config.sh"

    [ -f "${source_script}" ] || {
        echo "SETUP ERROR: Source script not found at '${source_script}'" >&2
        return 1
    }

    # Load wait_for_condition from common library for mocking
    LIB_DIR="${REPO_ROOT}/scripts/lib"
    COMMON_LIB="${LIB_DIR}/common-lib.sh"

    [ -f "${COMMON_LIB}" ] || {
        echo "SETUP ERROR: common script library not found at '$COMMON_LIB'" >&2
        return 1
    }

    # Create an isolated temporary folder for scripts and for logging execution telemetry
    TEST_TEMP_DIR="$(mktemp -d -t k3s-apply-config-test.XXXXXX)"
    export TEST_TEMP_DIR

    # Stage both files side-by-side in the isolated test directory
    SCRIPT_UNDER_TEST="${TEST_TEMP_DIR}/apply-k3s-node-config.sh"
    cp "${source_script}" "${SCRIPT_UNDER_TEST}"
    cp "${COMMON_LIB}" "${TEST_TEMP_DIR}/common-lib.sh"

    chmod +x "${SCRIPT_UNDER_TEST}"

    # load the test helper functions
    load "${REPO_ROOT}/tests/support/test_helpers.bash"

    telemetry_log_init "${TEST_TEMP_DIR}" telemetry.log

    export STAGING_DIR="${TEST_TEMP_DIR}/k3s-staging"
    export K3S_CONFIG_DIR="${TEST_TEMP_DIR}/etc/rancher/k3s"

    # =============================================================================
    # MOCKS
    # =============================================================================

    # mock root user
    id() {
        if [ "${1:-}" = "-u" ]; then
            echo "0"
            return 0
        fi
        command id "$@"
    }

    getent() {
        if [ "$1" = "passwd" ] && [ "$2" = "${SUDO_USER:-}" ]; then
            echo "${SUDO_USER:-}:x:1000:1000:${SUDO_USER:-}:/home/${SUDO_USER:-}:/bin/bash"
            return 0
        fi
        command getent "$@"
    }

    # SPY mock for wait_for_condition - functions that are not built in require a different approach
    # mocking wait_for_condition is preferable to mocking sleep because it is decouples the implementation from the mock
    spy_fast_wait_for_condition() {
        local raw_cmd="wait_for_condition $*"
        local retries=$1
        local wait_time=$2
        local message=$3
        shift 3 # Remove the first 3 arguments so only the command remains in "$@"
        local cmd=("$@")

        local exit_code=0
        local payload="${cmd[*]}"   # * expand as single string where @ expands as separate args
        local details="retries:${retries},wait_time:${wait_time}"

        log_telemetry "WAIT_FOR_CONDITION" "local" "WAIT" "$message" "$payload" "$details" "$raw_cmd"

        # Delegate to original with zero delay
        __real_wait_for_condition "$retries" 0 "$message" "${cmd[@]}" || exit_code=$?

        return "$exit_code"
    }

    # Register the spy for the target library
    # This creates a __real_wait_for_condition alias that allows us to call the original function from the spy
    # It also registers an interceptor hook that ensures that source does no override the spy
    register_code_spy "common-lib.sh" "wait_for_condition" "spy_fast_wait_for_condition"

    curl() {
        echo "ok"
        return 0
    }

    journalctl() {
        local raw_cmd="journalctl $*"
        local unit="-"
        local lines="-"
        local no_pager="false"

        # Extract unit name if present (-u <val> or --unit <val>)
        [[ "$*" =~ (-u|--unit)[[:space:]=]+([^[:space:]]+) ]] && unit="${BASH_REMATCH[2]}"

        # Extract line count if present (-n <val> or --lines <val>)
        [[ "$*" =~ (-n|--lines)[[:space:]=]+([0-9]+) ]] && lines="${BASH_REMATCH[2]}"

        # Check for presence of --no-pager
        [[ "$*" =~ [[:space:]]--no-pager([[:space:]]|$) ]] && no_pager="true"



        log_telemetry "JOURNALCTL" "local" "EXEC" "$unit" "$lines" "no_pager:${no_pager}" "$raw_cmd"
        return 0
    }

    k3s() {
        echo "ok"
        return 0
    }

    install() {
        local raw_cmd="install $*"

        # Fail fast if basic contract (at least src and dest) is broken
        if [ "$#" -lt 2 ]; then
            echo "TEST_HELPERS ERROR: spy_install expected at least src and dest, got: ${raw_cmd}" >&2
            return 1
        fi

        # Extract src and dest directly from the end of the argument list
        local dest="${@: -1}"
        local src="${@: -2:1}"

        # Slice out all arguments prior to src and dest
        local opts=("${@:1:$#-2}")
        local sanitized_opts=()
        local owner=""
        local group=""

        # parse and remove owner and group to avoid root privilege issues during testing
        while [ "${#opts[@]}" -gt 0 ]; do
            case "${opts[0]}" in
                -o|--owner)
                    owner="${opts[1]}"
                    opts=("${opts[@]:2}")
                    ;;
                --owner=*)
                    owner="${opts[0]#*=}"
                    opts=("${opts[@]:1}")
                    ;;
                -g|--group)
                    group="${opts[1]}"
                    opts=("${opts[@]:2}")
                    ;;
                --group=*)
                    group="${opts[0]#*=}"
                    opts=("${opts[@]:1}")
                    ;;
                *)
                    sanitized_opts+=("${opts[0]}")
                    opts=("${opts[@]:1}")
                    ;;
            esac
        done

        local log_args=()
        [ -n "$owner" ] && log_args+=("owner:${owner}")
        [ -n "$group" ] && log_args+=("group:${group}")

        local details=""
        details=$(IFS=,; echo "${log_args[*]}")

        log_telemetry "INSTALL" "local" "PUT" "$dest" "$src" "$details" "$raw_cmd"

        # Delegate copy and permissions safely
        command install "${sanitized_opts[@]}" "$src" "$dest"
    }

    systemctl() {
        local verb="${1:-}"
        local service="${2:-}"

        case "$verb" in
            cat)
                case "$service" in
                    k3s.service)
                        if [ "${MOCK_ENABLE_K3S:-false}" = "true" ]; then
                            echo "# /lib/systemd/system/${service}"
                            echo "[Unit]"
                            echo "Description=Mock ${service}"
                            return 0
                        fi
                        ;;
                    k3s-agent.service)
                        if [ "${MOCK_ENABLE_K3S_AGENT:-false}" = "true" ]; then
                            echo "# /lib/systemd/system/${service}"
                            echo "[Unit]"
                            echo "Description=Mock ${service}"
                            return 0
                        fi
                        ;;
                esac

                echo "No files found for ${service}." >&2
                return 1
                ;;

            daemon-reload|restart)
                log_telemetry "SYSTEMCTL" "local" "EXEC" "${verb:--}" "${service:--}" "args:$*" "systemctl $*"
                return 0
                ;;
        esac

        # Exit 1 for all other verbs/invocations
        return 1

    }

    export -f install journalctl k3s curl getent id spy_fast_wait_for_condition systemctl

    export SUDO_USER="bats-test-runner"
    export USER="root"
    export MOCK_ENABLE_K3S=true
    export MOCK_ENABLE_K3S_AGENT=true

}

teardown() {
    log_test_execution "$TEST_TEMP_DIR"
    cleanup_test_dir "$TEST_TEMP_DIR"
}

# ==============================================================================
# 📡 THE BEHAVIORAL CONTRACT TESTS
# ==============================================================================

# ==============================================================================
# 🛡️ PHASE 1: INPUT & ARGUMENT VALIDATION
# ==============================================================================

@test "validation: fails fast if executed without root privileges" {
    # Mock id to simulate an unprivileged user (UID 1000)
    id() {
        if [ "$1" = "-u" ]; then
            echo "1000"
            return 0
        fi
        command id "$@"
    }
    export -f id

    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"

    assert_failure 1
    assert_output --partial "Error: This provisioning script must be run with root privileges (use sudo)"
}

@test "validation: fails fast if executed directly as root without sudo" {
    # Mock id to simulate an unprivileged user (UID 1000)
    SUDO_USER=""
    USER="root"

    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"

    assert_failure 1
    assert_output --partial "Direct root account execution is forbidden on this device."
}

@test "validation: fails fast when staging configuration argument is missing" {
    run "${SCRIPT_UNDER_TEST}"

    assert_failure
    assert_output --partial "Missing required staging configuration file path argument"
}

@test "validation: fails fast when staging file path does not exist" {
    local non_existent_file="${TEST_TEMP_DIR}/non_existent_config.yaml"

    run "${SCRIPT_UNDER_TEST}" "$non_existent_file"

    assert_failure
    assert_output --partial "does not exist or is not a regular file"
}

@test "validation: fails fast when staging file exists but is a directory" {
    local staging_dir_as_file="${TEST_TEMP_DIR}/staging_dir"
    mkdir -p "$staging_dir_as_file"

    run "${SCRIPT_UNDER_TEST}" "$staging_dir_as_file"

    assert_failure
    assert_output --partial "does not exist or is not a regular file"
}

@test "validation: fails fast when common-lib.sh does not exist" {
    local sandbox_repo="${TEST_TEMP_DIR}/broken_repo"
    mkdir -p "${sandbox_repo}/scripts/bare-metal"

    # Copy script under test to the fake repo
    cp "${SCRIPT_UNDER_TEST}" "${sandbox_repo}/scripts/bare-metal/apply-k3s-node-config.sh"

    local staging_file="${TEST_TEMP_DIR}/dummy.yaml"
    touch "$staging_file"

    run "${sandbox_repo}/scripts/bare-metal/apply-k3s-node-config.sh" "$staging_file"

    assert_failure
    assert_output --partial "Required library not found or not readable"
}

@test "validation: fails fast when common-lib.sh is not readable (chmod 000)" {
    if [ "$(id -u)" -eq 0 ]; then
        skip "Root user bypasses standard [ -r ] file permission checks"
    fi

    local sandbox_repo="${TEST_TEMP_DIR}/unreadable_repo"
    mkdir -p "${sandbox_repo}/scripts/bare-metal"
    mkdir -p "${sandbox_repo}/scripts/lib"

    local sandboxed_script="${sandbox_repo}/scripts/bare-metal/apply-k3s-node-config.sh"

    cp "${SCRIPT_UNDER_TEST}" "$sandboxed_script"

    # Create the library file but revoke all permissions
    touch "${sandbox_repo}/scripts/lib/common-lib.sh"
    chmod 000 "${sandbox_repo}/scripts/lib/common-lib.sh"

    local staging_file="${TEST_TEMP_DIR}/dummy.yaml"
    touch "$staging_file"

    run "$sandboxed_script" "$staging_file"

    assert_failure
    assert_output --partial "Required library not found or not readable"
}

@test "validation: staging file with relative path is anchored to the executing sudo user's home directory" {
    local staging_file="k3s-stage/config.yaml"
    export SUDO_USER="non-user"

    run "${SCRIPT_UNDER_TEST}" "$staging_file"

    assert_failure
    assert_output --partial "'/home/non-user/k3s-stage/config.yaml' does not exist or is not a regular file"
}

# ==============================================================================
# 🔍 PHASE 2: SERVICE DISCOVERY & RESOLUTION
# ==============================================================================

@test "validation: fails fast when neither k3s nor k3s-agent is registered in systemd" {
    # The function is invoked indirectly by the script under test via the exported function.
    export MOCK_ENABLE_K3S=false
    export MOCK_ENABLE_K3S_AGENT=false

    local staging_file="${TEST_TEMP_DIR}/staging.yaml"
    echo "token: test-token" > "$staging_file"

    run "${SCRIPT_UNDER_TEST}" "$staging_file"

    assert_failure
    assert_output --partial "No registered K3s service (k3s.service or k3s-agent.service) was found on this node"
}

@test "behaviour: detects k3s.service and binds to server runtime mode" {
    export MOCK_ENABLE_K3S=true
    export MOCK_ENABLE_K3S_AGENT=false

    local staging_file="${TEST_TEMP_DIR}/staging.yaml"
    echo "token: server-token" > "$staging_file"

    run "${SCRIPT_UNDER_TEST}" "$staging_file"

    assert_success
    assert_output --partial "Detected active runtime service mapping: k3s.service"
}

@test "behaviour: detects k3s-agent.service and binds to worker runtime mode" {
    export MOCK_ENABLE_K3S=false
    export MOCK_ENABLE_K3S_AGENT=true

    local staging_file="${TEST_TEMP_DIR}/staging.yaml"
    echo "token: agent-token" > "$staging_file"

    run "${SCRIPT_UNDER_TEST}" "$staging_file"

    assert_success
    assert_output --partial "Detected active runtime service mapping: k3s-agent.service"
}

# ==============================================================================
# 📦 PHASE 3: CONFIGURATION PROMOTION & PERMISSIONS
# ==============================================================================

@test "behaviour: creates target directory, moves file, and cleans staging file" {
    local staging_file="${TEST_TEMP_DIR}/staging.yaml"
    echo "cluster-cidr: 10.42.0.0/16" > "$staging_file"

    run "${SCRIPT_UNDER_TEST}" "$staging_file"

    assert_success
    assert_file_not_exists "$staging_file"
    assert_file_exists "${K3S_CONFIG_DIR}/config.yaml"
}

@test "behaviour: enforces 0600 file permissions and ownership on promoted config" {
    export -f systemctl

    local staging_file="${TEST_TEMP_DIR}/staging.yaml"
    echo "token: secret" > "$staging_file"

    run "${SCRIPT_UNDER_TEST}" "$staging_file"

    local target_file="${K3S_CONFIG_DIR}/config.yaml"

    assert_success
    assert_file_exists "$target_file"
    assert [ "$(stat -c "%a" "$target_file")" = "600" ]
    assert_file_contains "^INSTALL|local|PUT|${target_file}|${staging_file}|owner:root,group:root|" "$TELEMETRY_LOG"
}

# ==============================================================================
# ⚙️ PHASE 4: SYSTEMD LIFECYCLE EXECUTION
# ==============================================================================

@test "behaviour: reloads systemd daemon before restarting service" {
    systemctl() {
        log_telemetry "SYSTEMCTL" "local" "EXEC" "$1" "${2:--}" "args:$*" "systemctl $*"
        case "$1" in
            list-unit-files) echo "k3s.service enabled"; return 0 ;;
            daemon-reload|restart) return 0 ;;
        esac
        return 0
    }

    export -f systemctl

    local staging_file="${TEST_TEMP_DIR}/staging.yaml"
    echo "token: test" > "$staging_file"

    run "${SCRIPT_UNDER_TEST}" "$staging_file"

    assert_success
    assert_file_contains "^SYSTEMCTL|local|EXEC|daemon-reload|-|" "$TELEMETRY_LOG"
}

@test "behaviour: issues non-blocking restart to target service" {
    systemctl() {
        log_telemetry "SYSTEMCTL" "local" "EXEC" "$1" "${2:--}" "args:$*" "systemctl $*"
        case "$1" in
            list-unit-files) echo "k3s.service enabled"; return 0 ;;
            daemon-reload|restart) return 0 ;;
        esac
        return 0
    }

    export -f systemctl

    local staging_file="${TEST_TEMP_DIR}/staging.yaml"
    echo "token: test" > "$staging_file"

    run "${SCRIPT_UNDER_TEST}" "$staging_file"

    assert_success
    assert_file_contains "^SYSTEMCTL|local|EXEC|restart|k3s|args:restart k3s --no-block|" "$TELEMETRY_LOG"
}

# ==============================================================================
# 🩺 PHASE 5: READINESS PROBES (SPY VERIFICATION)
# ==============================================================================

@test "behaviour: invokes k3s server readiness probe (/readyz) with expected retry/delay contract" {
    systemctl() {
        case "$1" in
            list-unit-files) echo "k3s.service enabled"; return 0 ;;
            daemon-reload|restart) return 0 ;;
        esac
        return 0
    }

    k3s() {
        if [ "$1" = "kubectl" ] && [ "$2" = "get" ] && [ "$3" = "--raw=/readyz" ]; then
            echo "ok"
            return 0
        fi
        return 1
    }
    export -f systemctl k3s

    local staging_file="${TEST_TEMP_DIR}/staging.yaml"
    echo "token: server-probe" > "$staging_file"

    run "${SCRIPT_UNDER_TEST}" "$staging_file"

    assert_success
    assert_file_contains "^WAIT_FOR_CONDITION|local|WAIT|k3s functional readiness|check_node_readiness|retries:30,wait_time:2|" "$TELEMETRY_LOG"
}

@test "behaviour: invokes k3s-agent worker readiness probe (10248/healthz) with expected contract" {
    export MOCK_ENABLE_K3S=false
    export MOCK_ENABLE_K3S_AGENT=true
    
    curl() {
        if [[ "$*" =~ "10248/healthz" ]]; then
            echo "ok"
            return 0
        fi
        return 1
    }
    export -f systemctl curl

    local staging_file="${TEST_TEMP_DIR}/staging.yaml"
    echo "token: agent-probe" > "$staging_file"

    run "${SCRIPT_UNDER_TEST}" "$staging_file"

    assert_success
    assert_file_contains "^WAIT_FOR_CONDITION|local|WAIT|k3s-agent functional readiness|check_node_readiness|retries:30,wait_time:2|" "$TELEMETRY_LOG"
}

@test "behaviour: passes when readiness probe succeeds within retry limit" {
    local attempt_counter_file="${TEST_TEMP_DIR}/probe_attempts"
    echo "0" > "$attempt_counter_file"

    systemctl() {
        case "$1" in
            list-unit-files) echo "k3s.service enabled"; return 0 ;;
            daemon-reload|restart) return 0 ;;
        esac
        return 0
    }
    k3s() {
        local count
        count=$(cat "$attempt_counter_file")
        count=$((count + 1))
        echo "$count" > "$attempt_counter_file"

        # Fail initial 2 attempts, succeed on 3rd
        if [ "$count" -ge 3 ]; then
            echo "ok"
            return 0
        fi
        return 1
    }
    export -f systemctl k3s
    export attempt_counter_file

    local staging_file="${TEST_TEMP_DIR}/staging.yaml"
    echo "token: retry-test" > "$staging_file"

    run "${SCRIPT_UNDER_TEST}" "$staging_file"

    assert_success
    assert [ "$(cat "$attempt_counter_file")" -eq 3 ]
}

# ==============================================================================
# 🚨 PHASE 6: ERROR TRAPPING & DIAGNOSTICS
# ==============================================================================

@test "behaviour: dumps journalctl logs when readiness probe times out" {
    systemctl() {
        case "$1" in
            list-unit-files) echo "k3s.service enabled"; return 0 ;;
            daemon-reload|restart) return 0 ;;
        esac
        return 0
    }
    k3s() {
        return 1
    }
    export -f systemctl k3s

    local staging_file="${TEST_TEMP_DIR}/staging.yaml"
    echo "token: timeout-test" > "$staging_file"

    run "${SCRIPT_UNDER_TEST}" "$staging_file"

    assert_failure
    assert_output --partial "Timed out waiting for k3s.service to reach operational state"
    assert_file_contains "^JOURNALCTL|local|EXEC|k3s|50|no_pager:true|" "$TELEMETRY_LOG"
}

@test "behaviour: does not dump journalctl when readiness probe succeeds" {
    systemctl() {
        case "$1" in
            list-unit-files) echo "k3s.service enabled"; return 0 ;;
            daemon-reload|restart) return 0 ;;
        esac
        return 0
    }

    export -f systemctl

    local staging_file="${TEST_TEMP_DIR}/staging.yaml"
    echo "token: clean-run" > "$staging_file"

    run "${SCRIPT_UNDER_TEST}" "$staging_file"

    assert_success
    assert_file_not_contains "^JOURNALCTL|" "$TELEMETRY_LOG"
}
