#!/usr/bin/env bats

# ==============================================================================
# Behavioral Contract Test Suite for Common Utility Library (common-lib.sh)
#
# Complies with:
# - ADR 015: Test-Driven Development (TDD) Standards
# - Verifies safe, predictable retry loops and stateful polling behaviors.
# ==============================================================================

setup() {
    TEST_DIR="$(cd "$BATS_TEST_DIRNAME" && pwd)"
    REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)" # this test in tests/lib

        # load the teardown helper
    load "${REPO_ROOT}/tests/support/test_helpers.bash"

    # 2. Define SCRIPT_DIR
    export SCRIPT_DIR="${REPO_ROOT}/scripts/lib"

    [ -d "$SCRIPT_DIR" ] || {
        echo "SETUP ERROR: SCRIPT_DIR not found at '$SCRIPT_DIR'" >&2
        return 1
    }

    export SCRIPT_UNDER_TEST="${SCRIPT_DIR}/common-lib.sh"

    [ -f "${SCRIPT_UNDER_TEST}" ] || {
        echo "SETUP ERROR: cannot find '$SCRIPT_UNDER_TEST'" >&2
        return 1
    }

    # Isolated workspace directory for state tracking
    export TEST_TEMP_DIR="$(mktemp -d -t k3s-common-lib-test.XXXXXX)"
    counter_init "$TEST_TEMP_DIR"   # initialize counter support to track number of attempts

    # Locate and source common-lib.sh
    source "${SCRIPT_UNDER_TEST}"

    # Fix HOME in test sandbox
    export HOME="/home/testuser"
}

teardown() {
    # the counter state is held in the test temp folder so we don't need to call counter_cleanup
    cleanup_test_dir "$TEST_TEMP_DIR"
}

# ==============================================================================
# STATEFUL RETRY & POLLING TESTS
# ==============================================================================

@test "library: wait_for_condition succeeds on first attempt" {
    local msg="succeed on first attempt"

    run wait_for_condition 3 0 "$msg" succeed_on_attempt 1

    [ "$status" -eq 0 ]
    [ "$(counter_get)" -eq 1 ]    # assert # tries

    # Assert line 1 header contains message
    [ "${lines[0]}" = "Waiting: $msg..." ]
    [ "$(printf "%s\n" "$output" | grep -c -F -e "Not ready yet. Retrying in 0s...")" -eq 0 ]
    [ "$(printf "%s\n" "$output" | grep -c -F -e "-> Success!")" -eq 1 ]
}


@test "library: wait_for_condition logs expected retries and success" {
    run wait_for_condition 5 0.05 "succeed on third attempt" succeed_on_attempt 3

    [ "$status" -eq 0 ]

    # 1. Verify line 1 header
    [ "${lines[0]}" = "Waiting: succeed on third attempt..." ]

    # Verify exact repeat counts using grep -c on $output
    [ "$(printf "%s\n" "$output" | grep -c -F -e "Not ready yet. Retrying in 0.05s...")" -eq 2 ]
    [ "$(printf "%s\n" "$output" | grep -c -F -e "-> Success!")" -eq 1 ]
}

@test "library: wait_for_condition fails when max attempts are exhausted" {
    local msg="run out retries"
    run wait_for_condition 4 0.1 "$msg" succeed_on_attempt never

    [ "$status" -ne 0 ]
    [ "$(counter_get)" -eq 4 ]
    # Assert line 1 header contains message
    [ "${lines[0]}" = "Waiting: $msg..." ]
    [ "$(printf "%s\n" "$output" | grep -c -F -e "Not ready yet")" -eq 4 ]
    [ "$(printf "%s\n" "$output" | grep -c -F -e "Error: Timed out waiting for $msg after 0.4 seconds.")" -eq 1 ]

}

@test "library: wait_for_condition propagates command pipeline exits correctly" {
    export STATE_FILE="$TEST_TEMP_DIR/pipeline_state.txt"
    echo "initial_payload" > "$STATE_FILE"

    # Define the condition check as a function
    check_pipeline_state() {
        # Check if "ready" exists in the state file
        if grep -q "ready" "$STATE_FILE"; then
            return 0
        fi

        # Mutate state on failure so next attempt passes
        echo "ready" >> "$STATE_FILE"
        return 1
    }
    export -f check_pipeline_state

    run wait_for_condition 3 0.05 "pipeline readiness check" check_pipeline_state

    # 1. Overall execution succeeded
    [ "$status" -eq 0 ]

    # 2. Assert retry telemetry: exactly 1 retry occurred before success
    [ "$(printf "%s\n" "$output" | grep -c -F -e "Not ready yet. Retrying in 0.05s...")" -eq 1 ]
    [ "$(printf "%s\n" "$output" | grep -c -F -e "-> Success!")" -eq 1 ]

    # 3. Assert side-effect: state file was mutated exactly as expected
    [ "$(grep -c "ready" "$STATE_FILE")" -eq 1 ]
}

# ==============================================================================
# NORMALIZE PATH VARS TESTS
# ==============================================================================

@test "normalize_path_vars: expands leading '~/' to '\$HOME/'" {
    export TEST_PATH="~/k3s-staging/config"
    normalize_path_vars TEST_PATH

    assert [ "$TEST_PATH" = "/home/testuser/k3s-staging/config" ]
}

@test "normalize_path_vars: expands bare '~' to '\$HOME'" {
    export TEST_PATH="~"
    normalize_path_vars TEST_PATH

    assert [ "$TEST_PATH" = "/home/testuser" ]
}

@test "normalize_path_vars: leaves absolute paths untouched" {
    export TEST_PATH="/tmp/k3s-staging"
    normalize_path_vars TEST_PATH

    assert [ "$TEST_PATH" = "/tmp/k3s-staging" ]
}

@test "normalize_path_vars: leaves relative paths without leading tilde untouched" {
    export TEST_PATH="k3s-staging/build"
    normalize_path_vars TEST_PATH

    assert [ "$TEST_PATH" = "k3s-staging/build" ]
}

@test "normalize_path_vars: handles tilde in middle of path without expanding" {
    export TEST_PATH="/var/backups/data~1/k3s"
    normalize_path_vars TEST_PATH

    assert [ "$TEST_PATH" = "/var/backups/data~1/k3s" ]
}

@test "normalize_path_vars: handles multiple variables in a single call" {
    export VAR_ONE="~/staging"
    export VAR_TWO="/opt/k3s"
    export VAR_THREE="~/backups/db"

    normalize_path_vars VAR_ONE VAR_TWO VAR_THREE

    assert [ "$VAR_ONE" = "/home/testuser/staging" ]
    assert [ "$VAR_TWO" = "/opt/k3s" ]
    assert [ "$VAR_THREE" = "/home/testuser/backups/db" ]
}

@test "normalize_path_vars: silently ignores unset variables without failing" {
    unset UNSET_VAR

    run normalize_path_vars UNSET_VAR
    assert_success
    assert [ -z "${UNSET_VAR+x}" ]
}

@test "normalize_path_vars: leaves empty variables empty without failing" {
    export EMPTY_VAR=""

    run normalize_path_vars EMPTY_VAR
    assert_success
    assert [ "$EMPTY_VAR" = "" ]
}
