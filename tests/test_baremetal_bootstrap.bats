#!/usr/bin/env bats

# ==============================================================================
# 🧪 Bash Automated Testing System (BATS) - Behavioral Contract Test Suite
# ==============================================================================

# ⚙️ HELPER: Standard setup for every test case
setup() {
    TEST_DIR="$(cd "$BATS_TEST_DIRNAME" && pwd)"
    REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)" # Adjust '../..' if nested in test/unit/

    # 2. Define SCRIPT_DIR
    export SCRIPT_DIR="${REPO_ROOT}/scripts/bare-metal"

    [ -d "$SCRIPT_DIR" ] || {
        echo "SETUP ERROR: SCRIPT_DIR not found at '$SCRIPT_DIR'" >&2
        return 1
    }

    SCRIPT_UNDER_TEST="${SCRIPT_DIR}/bootstrap.sh"

    [ -f "${SCRIPT_UNDER_TEST}" ] || {
        echo "SETUP ERROR: cannot find '$SCRIPT_UNDER_TEST'" >&2
        return 1
    }

    # load the test helper functions
    load "${REPO_ROOT}/tests/support/test_helpers.bash"

    # Create an isolated temporary folder for bootstrap and for logging execution telemetry
    SECURE_TMP_DIR="$(mktemp -d -t k3s-bootstrap-test.XXXXXX)"
    HOME="${SECURE_TMP_DIR}/home/testuser"
    mkdir -p "$HOME"

    export SECURE_TMP_DIR HOME

    telemetry_log_init ${SECURE_TMP_DIR} telemetry.log

    # =============================================================================
    # MOCKS
    # =============================================================================

    MOCK_TOKEN="mock-secure-k3s-token-12345"

    _mock_kubectl_nodes_table() {
        local show_workers="${1:-false}"
        local not_ready_list="${2:-}"

        # Require CONTROL_PLANE_NODE explicitly. The script is designed to fail if it is not set
        if [ -z "${CONTROL_PLANE_NODE:-}" ]; then
            echo "TEST_HARNESS_ERROR: CONTROL_PLANE_NODE is unset or empty in mock table generator" >&2
            return 1
        fi

        printf "%-6s %-8s %-22s %-5s %s\n" "NAME" "STATUS" "ROLES" "AGE" "VERSION"

        # Control Plane is always registered
        local cp_status="Ready"
        if [[ "$not_ready_list" =~ (^|[[:space:]])"${CONTROL_PLANE_NODE}"([[:space:]]|$) ]]; then
            cp_status="NotReady"
        fi
        echo "${CONTROL_PLANE_NODE}   ${cp_status}    control-plane   10m   v1.31.0+k3s1"

        # Worker nodes ONLY when specifically required
        if [ "$show_workers" = "true" ]; then
            for entry in ${WORKER_NODES_CONFIG:-}; do
                local node="${entry%%:*}"
                [ -z "$node" ] && continue

                local status="Ready"
                # Output Workers if they have been provisioned / configured
                if [[ "$not_ready_list" =~ (^|[[:space:]])${node}([[:space:]]|$) ]]; then
                    status="NotReady"
                fi
                echo "${node}   ${status}   <none>          5m    v1.31.0+k3s1"
            done
        fi
    }

    # Define in-memory stubs for network commands.
    # Because BATS uses 'run', the subshell will inherit these exported functions natively!
    ssh() {
        # mock ssh requires strict formatting of ssh commands. If we need more
        # flexibility we can add bats-support, bats-assert and bats-mock git modules
        # ssh <options> <node> <cmd>
        local raw_host="${@: -2:1}"       # penultimate argument
        local node="${raw_host##*@}"      # strips <user>@ in the case of <user>@node
        local cmd=${@: -1}
        local raw_cmd="ssh $*"

        local action="EXEC"
        local target="-"
        local src="-"
        local details="-"

        local clean_cmd="${cmd#sudo }"    # strips leading sudo

        # install directory: install -d [-m mode] <dir>
        if [[ "$clean_cmd" =~ ^install[[:space:]]+.*-d ]]; then
            action="MKDIR"
            target="${clean_cmd##* }"
            if [[ "$clean_cmd" =~ -m[[:space:]]*([0-9]+) ]]; then
                details="mode:${BASH_REMATCH[1]}"
            else
                details="mode:default"
            fi

        # install file (PUT): install [-m mode] <src> <dest>
        elif [[ "$clean_cmd" =~ ^install[[:space:]]+ ]]; then
            action="PUT"
            target="${clean_cmd##* }"
            local -a tokens=($clean_cmd)
            src="${tokens[-2]}"
            if [[ "$clean_cmd" =~ -m[[:space:]]*([0-9]+) ]]; then
                details="mode:${BASH_REMATCH[1]}"
            else
                details="mode:default"
            fi

        # mkdir (MKDIR): mkdir [-m mode] -p <path>
        elif [[ "$clean_cmd" =~ ^mkdir[[:space:]]+ ]]; then
            action="MKDIR"
            target="${clean_cmd##* }"
            if [[ "$clean_cmd" =~ -m[[:space:]]*([0-9]+) ]]; then
                details="mode:${BASH_REMATCH[1]}"
            else
                details="mode:default"
            fi

        # cp (PUT): cp <flags> <src> <dest>
        elif [[ "$clean_cmd" =~ ^cp[[:space:]]+ ]]; then
            action="PUT"
            target="${clean_cmd##* }"
            local -a tokens=($clean_cmd)
            src="${tokens[-2]}"
            details="mode:default"

        # mv (MOVE): mv <flags> <src> <dest>
        elif [[ "$clean_cmd" =~ ^mv[[:space:]]+ ]]; then
            action="MOVE"
            target="${clean_cmd##* }"
            local -a tokens=($clean_cmd)
            src="${tokens[-2]}"
            details="-"

        # chmod: chmod <mode> <path>
        elif [[ "$clean_cmd" =~ ^chmod[[:space:]]+([0-9a-zA-Z,+=-]+)[[:space:]]+([^[:space:]]+) ]]; then
            action="CHMOD"
            details="mode:${BASH_REMATCH[1]}"
            target="${BASH_REMATCH[2]}"

        # apply-k3s-node-config.sh <config-file> (EXEC)
        elif [[ "$clean_cmd" =~ (/[^[:space:]]+/apply-k3s-node-config\.sh)[[:space:]]+['"']?([^'"']+)['"']? ]]; then
            action="EXEC"
            target="${BASH_REMATCH[1]}"   # script
            src="${BASH_REMATCH[2]}"      # payload
            details="sudo:$([[ "$cmd" =~ ^sudo ]] && echo "true" || echo "false")"

        # script runner: bash <script.sh>
        elif [[ "$clean_cmd" =~ (bash|sh)[[:space:]]+([^[:space:]]+\.sh) ]]; then
            action="EXEC"
            target="${BASH_REMATCH[2]}"
            local runner="${BASH_REMATCH[1]}"
            if [[ "$cmd" =~ ^sudo[[:space:]]+ ]]; then
                details="runner:${runner},sudo:true"
            else
                details="runner:${runner},sudo:false"
            fi
        # kubectl or k3s kubectl
        elif [[ "$clean_cmd" =~ (^|[[:space:]])(k3s[[:space:]]+)?kubectl ]]; then
                action="EXEC"
                target="kubectl"
                details="sudo:$([[ "$cmd" =~ ^sudo ]] && echo "true" || echo "false")"

        # probe / ping
        elif [[ "$clean_cmd" == "exit" ]]; then
            action="PROBE"
        else
            # Unclassified raw exec
            target="$clean_cmd"
        fi

       # log the processed command
        log_telemetry "SSH" "$node" "$action" "$target" "$src" "$details" "$raw_cmd"

        # Transport Failure Mock
        if [ "${MOCK_SSH_FAIL:-}" = "true" ] || [[ -n "${MOCK_SSH_FAIL:-}" && "$node" == "$MOCK_SSH_FAIL" ]]; then
            return 1
        fi

        # Token Extraction Mock
        if [[ "$*" == *"node-token"* ]]; then
            if [ "${MOCK_TOKEN_FAIL:-false}" = "true" ]; then
                return 1
            fi
            echo "mock-secure-k3s-token-12345" | tee "${SECURE_TMP_DIR}/captured_token.txt"
            return 0
        fi

        # Dynamic Pipeline Execution chains to other mocks
        # Runs the command pipeline (e.g. k3s kubectl get nodes | grep ...) natively
        if [ "$target" = "kubectl" ]; then
            MOCK_CURRENT_NODE="$node" MOCK_SSH_CURRENT_CMD="$cmd" eval "$clean_cmd"
            return $?
        fi

        # Default: Return success for all other remote stubs (mkdir, chmod, file operations, scripts)
        return 0
    }

    scp() {
        # mock scp requires strict formatting of scp commands. If we need more
        # flexibility we can add bats-support, bats-assert and bats-mock git modules
        # scp <options> <src> <dest>
        local dest="${@: -1}"
        local src="${@: -2:1}"
        local raw_cmd="scp $*"
        local node="unknown"

        if [[ "$dest" =~ ^([a-zA-Z0-9._-]+@)?([a-zA-Z0-9._-]+):(.+)$ ]]; then
            node="${BASH_REMATCH[2]}"
            dest="${BASH_REMATCH[3]}"

            # Resolve directory target suffix
            if [[ "$dest" =~ /$ ]]; then
                dest+="$(basename "$src")"
            fi

        fi

        log_telemetry "SCP" "$node" "PUT" "$dest" "$src" "mode:default" "$raw_cmd"
        return 0
    }


    kubectl() {
        local -a args=("$@")
        local subcommand="${args[0]:-}"
        local exit_code=0

        # The phase switches from control-plane (cp) phase to worker phase when the token has been extracted
        local current_phase="cp"
        if [ -f "${SECURE_TMP_DIR}/captured_token.txt" ]; then
            current_phase="cluster"
        fi

        # Phase-aware timeout matching
        case "${MOCK_KUBECTL_TIMEOUT:-}" in
            "true"|"all")
                exit_code=1
                ;;
            "cp")
                [ "$current_phase" = "cp" ] && exit_code=1
                ;;
            "cluster")
                [ "$current_phase" = "cluster" ] && exit_code=1
                ;;
        esac

        # Log kubectl invocation telemetry
        log_telemetry "KUBECTL" "${MOCK_CURRENT_NODE:-local}" "EXEC" "$subcommand" "-" "args:${*:2}" "kubectl $*"

        [ "$exit_code" -ne 0 ] && return "$exit_code"

        if [[ "$*" == *"get nodes"* ]]; then
            local show_workers="false"
            [ "$current_phase" = "cluster" ] && show_workers="true"
            _mock_kubectl_nodes_table "$show_workers" "${MOCK_NOT_READY_NODES:-}"
        fi

        return 0
    }

    # Invoked indirectly by the bootstrap script through the exported mock.
    k3s() {
        if [ "$1" = "kubectl" ]; then
            shift
            kubectl "$@"
            return $?
        fi
        return 0
    }

    sleep() {
        # No-op: eliminates wall-clock delay during retry loops
        log_telemetry "SLEEP" "local" "WAIT" "interval" "$1" "unit:seconds" "sleep $*"
        return 0
    }

    export -f _mock_kubectl_nodes_table ssh scp kubectl k3s sleep

    # Establish the production environment context
    export CONTROL_PLANE_NODE="kc01"
    export CONTROL_PLANE_IP="192.168.1.50"
    export WORKER_NODES_CONFIG="kc02:192.168.1.51"
}

# 🧹 HELPER: Clean up after every test case
teardown() {
    cleanup_test_dir "$SECURE_TMP_DIR"
}

# =============================================================================
# 📡 PARAMETERIZED TEST GENERATOR (JUnit 5 style)
# =============================================================================
test_malformed_worker_config() {
    local entry="$1"
    export WORKER_NODES_CONFIG="$entry"

    run "${SCRIPT_UNDER_TEST}"

    assert_failure
    assert_output --regexp "(FAILED|ERROR)"
}

generate_malformed_worker_config_tests() {
    local malformed_entries=(
        "kc02"                                              # Missing IP delimiter
        "kc02:"                                             # Empty IP address
        "kc02:abc"                                          # Non-numeric IP address format
        ":192.168.1.51"                                     # Missing hostname
        "w02:192.168.1.51:extra"                            # Too many colon segments
        "KC02:192.168.1.52 wc01:"                           # Missing IP in second entry
        "wc99:10.66.42.50 :10.66.42.50 kc02:192.168.0.1"    # Missing host in second entry of 3
        "kc03:192.168"                                      # Malformed IP
        "WN01:999.66.43.101"                                # invalid 1st octet
        "kc1:10.256.43.101"                                 # invalid 2nd octet
        "kc1:10.255.301.101"                                # invalid 3rd octet
        "kc1:10.25.43.357"                                  # invalid 4th octet
    )

    for entry in "${malformed_entries[@]}"; do
        # Register each entry as a distinct test case in the BATS execution queue
        bats_test_function --description "validation: fails fast for malformed worker record '$entry'" -- test_malformed_worker_config "$entry"
    done
}

generate_malformed_worker_config_tests

test_valid_worker_config() {
    local entry="$1"
    export WORKER_NODES_CONFIG="$entry"

    run "${SCRIPT_UNDER_TEST}"

    assert_success
}

generate_valid_worker_config_tests() {
    local valid_entries=(
        "kc02:10.66.42.25"
        "WN45:192.168.0.55"
        "kc02:10.66.42.25 WN45:192.168.0.55"
        "kc02:10.66.45.0  Wc23:192.168.1.255"
    )

    for entry in "${valid_entries[@]}"; do
        # Register each entry as a distinct test case in the BATS execution queue
        bats_test_function --description "validation: validates worker record '$entry'" -- test_valid_worker_config "$entry"
    done
}

generate_valid_worker_config_tests

test_failed_node_connection() {
    WORKER_NODES_CONFIG="kc09:192.168.1.51 xy03:192.168.1.52 kc04:192.168.1.53"

    local failed_node="$1"
    export MOCK_SSH_FAIL="$failed_node"

    run "${SCRIPT_UNDER_TEST}"

    echo "$output"

    assert_failure
    assert_output --regexp "(FAILED|ERROR)"
}

generate_failed_node_connection_tests() {
    for node in "kc01" "xy03" "kc09" "kc04"; do
        bats_test_function --description "connectivity: fails fast for unavailable node '$node'" -- test_failed_node_connection "$node"
    done
}

generate_failed_node_connection_tests

# ==============================================================================
# 📡 THE BEHAVIORAL CONTRACT TESTS
# ==============================================================================

@test "validation: fails fast when CONTROL_PLANE_NODE is missing" {
    unset CONTROL_PLANE_NODE

    run "${SCRIPT_UNDER_TEST}"

    assert_failure
    assert_output --regexp "(FAILED|ERROR)"
}

@test "validation: fails fast when WORKER_NODES_CONFIG is missing" {
    unset WORKER_NODES_CONFIG

    run "${SCRIPT_UNDER_TEST}"

    echo "$output"

    assert_failure
    assert_output --regexp "(FAILED|ERROR)"
}

@test "behaviour: provisions all cluster nodes with required scripts and root execution" {

    export CONTROL_PLANE_NODE="CP01"
    export CONTROL_PLANE_IP="10.66.42.100"
    export WORKER_NODES_CONFIG="WN01:10.66.43.50 WN05:10.66.43.55"

    local -a nodes=("CP01" "WN01" "WN05")

    run "${SCRIPT_UNDER_TEST}"

    assert_success

    for node in "${nodes[@]}"; do

        # Verify provision-node.sh was copied to /tmp on this node
        assert_file_contains "^SCP|${node}|PUT|/tmp/provision-node.sh|${SCRIPT_DIR}/provision-node.sh|" "$TELEMETRY_LOG"

        # Verify apply-k3s-node-config.sh was copied to /tmp on this node
        assert_file_contains "^SCP|${node}|PUT|/tmp/apply-k3s-node-config.sh|${SCRIPT_DIR}/apply-k3s-node-config.sh|" "$TELEMETRY_LOG"

        # Verify provision-node.sh was executed with bash
        assert_file_contains "^SSH|${node}|EXEC|/tmp/provision-node.sh|-|runner:bash,sudo:true|" "$TELEMETRY_LOG"
    done
}

@test "behaviour: deploys control plane configuration to the control plane node" {
    export STAGING_DIR="k3s-staging"

    run "${SCRIPT_UNDER_TEST}"

    assert_success

    # Verify remote staging directory creation with 700 mode
    assert_file_contains "^SSH|${CONTROL_PLANE_NODE}|MKDIR|${STAGING_DIR}|-|mode:700|" "$TELEMETRY_LOG"

    # 2. Verify control-plane configuration file transfer via SCP
    assert_file_contains "^SCP|${CONTROL_PLANE_NODE}|PUT|${STAGING_DIR}/config.yaml|${REPO_ROOT}/infrastructure/nodes/control-plane-config.yaml|" "$TELEMETRY_LOG"

    # 3. Verify configuration application script execution with control-plane role
    assert_file_contains "^SSH|${CONTROL_PLANE_NODE}|EXEC|"/usr/local/bin/apply-k3s-node-config.sh"|${STAGING_DIR}/config.yaml|sudo:true|" "$TELEMETRY_LOG"
}

@test "behaviour: fetches k3s node token from control plane node successfully" {
    export MOCK_TOKEN_FAIL="false"

    run "${SCRIPT_UNDER_TEST}"

    assert_success

    # verify the mock token was written to file
    assert [ "$(<"${SECURE_TMP_DIR}/captured_token.txt")" = "${MOCK_TOKEN}" ]

    # Verify the script output confirmed successful extraction
    assert_output --partial "Token extracted successfully."
}

@test "behaviour: aborts bootstrap if token extraction fails" {
    export MOCK_TOKEN_FAIL="true"
    run "${SCRIPT_UNDER_TEST}"
    assert_failure
}

@test "behaviour: deploys and configures all worker nodes with rendered templates" {
    # Arrange test inputs
    local -A test_workers=(
        ["WN01"]="10.66.43.50"
        ["WN05"]="10.66.43.55"
    )
    export CONTROL_PLANE_IP="10.66.43.10"
    export INTERFACE="eth0"
    export STAGING_DIR="k3s-staging"
    export WORKER_NODES_CONFIG="WN01:10.66.43.50 WN05:10.66.43.55"

    # Ensure template file exists for test harness
    local template_file="${REPO_ROOT}/core/k3s-config/worker-config.yaml.template"
    [ -f "$template_file" ] || {
        echo "SETUP ERROR: worker-config.yaml.template missing at '$template_file'" >&2
        return 1
    }

    # run the script
    run "${SCRIPT_UNDER_TEST}"
    assert_success

    # 3. Assert for each worker node
    for node in "${!test_workers[@]}"; do
        local worker_ip="${test_workers[$node]}"
        local rendered_config="${SECURE_TMP_DIR}/${node}-config.yaml"

        # File Existence & Content Substitution
        assert [ -f "$rendered_config" ]
        assert_file_contains "server: \"https://${CONTROL_PLANE_IP}:6443\"" "$rendered_config"
        assert_file_contains "token: \"${MOCK_TOKEN}\"" "$rendered_config"
        assert_file_contains "node-ip: \"${worker_ip}\"" "$rendered_config"
        assert_file_contains "flannel-iface: \"${INTERFACE}\"" "$rendered_config"

        # Ensure no raw unexpanded template placeholders remain
        refute grep -E '\$(CONTROL_PLANE_IP|K3S_TOKEN|WORKER_IP|INTERFACE)' "$rendered_config"

        # Telemetry - Directory creation
        assert_file_contains "^SSH|${node}|MKDIR|${STAGING_DIR}|-|mode:700|" "$TELEMETRY_LOG"

        # Telemetry - SCP config transfer
        assert_file_contains "^SCP|${node}|PUT|${STAGING_DIR}/config.yaml|${rendered_config}|" "$TELEMETRY_LOG"

        # Telemetry - Execution of apply script
        assert_file_contains "^SSH|${node}|EXEC|"/usr/local/bin/apply-k3s-node-config.sh"|${STAGING_DIR}/config.yaml|sudo:true|" "$TELEMETRY_LOG"
    done
}

@test "behaviour: control plane readiness fails when kubectl command times out" {
    export MOCK_KUBECTL_TIMEOUT="cp"

    run "${SCRIPT_UNDER_TEST}"
    assert_failure

    # 1. Telemetry confirms 12 execution attempts
    local poll_count
    poll_count=$(grep -c "^SSH|${CONTROL_PLANE_NODE}|EXEC|kubectl|-|.*|.*grep.*'Ready'" "$TELEMETRY_LOG" || true)
    assert [ "$poll_count" -eq 12 ]

    # 2. Output verifies exact retry progression and timeout error message
    local retry_msg_count
    retry_msg_count=$(grep -c -- "-> Not ready yet. Retrying in" <<< "$output" || true)
    assert [ "$retry_msg_count" -eq 12 ]

    assert_output --partial "Error: Timed out waiting for"
}

@test "behaviour: control plane readiness fails when control plane reports NotReady" {
    export MOCK_NOT_READY_NODES="${CONTROL_PLANE_NODE}"

    run "${SCRIPT_UNDER_TEST}"

    assert_failure

    # grep -q 'Ready' fails against 'NotReady' line if grep isn't checking subword,
    # or fails if strictly matching "^Ready"
    local poll_count
    poll_count=$(grep -c "^SSH|${CONTROL_PLANE_NODE}|EXEC|kubectl|-|.*|.*grep.*'Ready'" "$TELEMETRY_LOG" || true)
    # poll_count=$(grep -c "sudo k3s kubectl get nodes | grep -q 'Ready'" "$TELEMETRY_LOG" || true)
    assert [ "$poll_count" -eq 12 ]

    assert_output --partial "Error: Timed out waiting for"
}

@test "behaviour: cluster readiness fails when kubectl command times out" {
    export MOCK_KUBECTL_TIMEOUT="cluster"
    run "${SCRIPT_UNDER_TEST}"
    assert_failure

    # First targeted node in loop should fail all 15 attempts
    local retry_msg_count
    retry_msg_count=$(grep -c -- "-> Not ready yet. Retrying in" <<< "$output" || true)
    assert [ "$retry_msg_count" -eq 15 ]

    local poll_count
    poll_count=$(grep -c "^SSH|${CONTROL_PLANE_NODE}|EXEC|kubectl|-|.*|.*grep.*kc01" "$TELEMETRY_LOG" || true)
    assert [ "$poll_count" -eq 15 ]

    # Verify error message points to the specific node failure
    assert_output --partial "Error: Timed out waiting for Node kc01 to report as Ready"
}

@test "behaviour: cluster readiness fails when a specific worker node reports NotReady" {
    export WORKER_NODES_CONFIG="WN01:10.66.43.50 WN05:10.66.43.55"
    export MOCK_NOT_READY_NODES="WN05"

    run "${SCRIPT_UNDER_TEST}"

    assert_failure

    # kc01 and WN01 succeed immediately (2 success messages logged)
    local success_count
    success_count=$(grep -c -- "-> Success!" <<< "$output" || true)
    assert [ "$success_count" -eq 2 ]

    local poll_count
    poll_count=$(grep -c "^SSH|${CONTROL_PLANE_NODE}|EXEC|kubectl|-|.*|.*grep.*WN05" "$TELEMETRY_LOG" || true)
    assert [ "$poll_count" -eq 15 ]

    # WN05 fails all 15 attempts
    local retry_msg_count
    retry_msg_count=$(grep -c -- "-> Not ready yet. Retrying in" <<< "$output" || true)
    assert [ "$retry_msg_count" -eq 15 ]

    # 3. Verify specific timeout error for WN05
    assert_output --partial "Error: Timed out waiting for Node WN05 to report as Ready after 60 seconds."
}

@test "behaviour: control plane readiness succeeds when control plane reports Ready" {

    run "${SCRIPT_UNDER_TEST}"

    assert_success

    local first_k8s_call
    first_k8s_call=$(grep "^KUBECTL|" "$TELEMETRY_LOG" | head -n 1 || true)
    [[ "$first_k8s_call" =~ ^KUBECTL\|${CONTROL_PLANE_NODE}\|EXEC\|get\| ]]

    # Ensure output logs successful readiness
    assert_output --partial "Waiting: K3s control plane to be ready..."
    assert_output --partial "-> Success!"
}

@test "behaviour: cluster readiness succeeds when all nodes report Ready" {
    export CONTROL_PLANE_NODE="kc01"
    export WORKER_NODES_CONFIG="WN01:10.66.43.50 WN05:10.66.43.55"
    export MOCK_NOT_READY_NODES=

    local -a nodes=("kc01" "WN01" "WN05")

    run "${SCRIPT_UNDER_TEST}"

    assert_success

    # Verify each node had its readiness probed on the control plane using grep -d
    for node in "${nodes[@]}"; do
        local poll_count
        poll_count=$(grep -c "^SSH|${CONTROL_PLANE_NODE}|EXEC|kubectl|-|.*|.*grep.*${node}" "$TELEMETRY_LOG" || true)
        assert [ "$poll_count" -eq 1 ]
        assert_output --partial "Waiting: Node ${node} to report as Ready..."
    done

    # Ensure final cluster status table was printed
    assert_output --partial "Cluster is fully online. Final status and labels:"
}
