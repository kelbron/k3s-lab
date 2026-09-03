#==================================================================================
# ALIAS / SPY SUPPORT
#==================================================================================

# ------------------------------------------------------------------------------
# Function Aliasing Primitive
# ------------------------------------------------------------------------------

# Clones an existing loaded function under a new alias name in memory.
# Usage: alias_function "original_name" "alias_name"
alias_function() {
    local source_func="$1"
    local target_func="${2:-__real_${source_func}}"

    if ! declare -f "$source_func" >/dev/null; then
        echo "TEST_HELPERS ERROR: Function '${source_func}' is not defined in current shell." >&2
        return 1
    fi

    # Read original function, rename header, and load into memory
    eval "$(declare -f "$source_func" | sed "1s/^${source_func}/${target_func}/")"
    export -f "${target_func?}"
}
export -f alias_function

# ------------------------------------------------------------------------------
# In-Memory Source Interceptor
# ------------------------------------------------------------------------------
__source_interception_hook() {
    # This function overrides source and is invoked indirectly by the test hook.
    # shellcheck disable=SC2329
    source() {
        local target="$1"
        shift

        # 1. Load the production library into the current shell
        builtin source "$target" "$@"

        # 2. Check if the sourced file matches our target library and function exists
        if [[ "$target" == *"${__INTERCEPT_TARGET_LIB:-}"* ]] && declare -f "${__INTERCEPT_TARGET_FUNC:-}" >/dev/null 2>&1; then

            # If in SPY mode (1), preserve the original implementation as __real_<func>
            if [ "${__INTERCEPT_IS_SPY:-0}" -eq 1 ]; then
                alias_function "$__INTERCEPT_TARGET_FUNC" "__real_${__INTERCEPT_TARGET_FUNC}"
            fi

            # Bind the target function name to the test's mock/spy implementation
            local mock_impl="${__INTERCEPT_CUSTOM_IMPL:-__mock_${__INTERCEPT_TARGET_FUNC}}"
            if declare -f "$mock_impl" >/dev/null 2>&1; then
                eval "$__INTERCEPT_TARGET_FUNC() { $mock_impl \"\$@\"; }"
            fi
        fi
    }
    # This function overrides . (dot) function as an alias for source
    # shellcheck source=/dev/null disable=SC2329
    .() {
        source "$@"
    }
}

# ------------------------------------------------------------------------------
# Registration Dispatcher
# ------------------------------------------------------------------------------
__register_code_interceptor() {
    local target_lib="$1"
    local target_func="$2"
    local custom_impl="$3"
    local is_spy="$4"

    if [ -z "$target_lib" ] || [ -z "$target_func" ]; then
        echo "TEST_HELPERS ERROR: Target library and function name must be provided." >&2
        return 1
    fi

    if [ "$(type -t "$target_func" 2>/dev/null)" = "builtin" ]; then
        echo "TEST_HELPERS ERROR: Cannot intercept Bash builtin '${target_func}'. Use standard function exports for builtins." >&2
        return 1
    fi

    export __INTERCEPT_TARGET_LIB="$target_lib"
    export __INTERCEPT_TARGET_FUNC="$target_func"
    export __INTERCEPT_CUSTOM_IMPL="$custom_impl"
    export __INTERCEPT_IS_SPY="$is_spy"

    local env_loader="${BATS_TEST_TMPDIR:-/dev/shm}/.bats_env_loader"
    {
        declare -f alias_function
        declare -f __source_interception_hook
        echo "__source_interception_hook"
    } > "$env_loader"
    export BASH_ENV="$env_loader"
}

# ------------------------------------------------------------------------------
# Public API: register_code_mock / register_code_spy
# ------------------------------------------------------------------------------
register_code_mock() {
    local target_lib="$1"
    local target_func="$2"
    local custom_mock="${3:-__mock_${target_func}}"

    __register_code_interceptor "$target_lib" "$target_func" "$custom_mock" 0
}

register_code_spy() {
    local target_lib="$1"
    local target_func="$2"
    local custom_spy="${3:-__spy_${target_func}}"

    __register_code_interceptor "$target_lib" "$target_func" "$custom_spy" 1
}

export -f register_code_mock register_code_spy

#==================================================================================
# COUNTER SUPPORT
#==================================================================================
counter_init() {
    local target_dir="${1:-${TEST_TEMP_DIR:-$(mktemp -d -t test_support.XXXXXX)}}"
    local telemetry_log_path
    telemetry_log_path="${target_dir%/}/counter_state_$(date +%s)_$$.txt"
    export TELEMETRY_LOG="$telemetry_log_path"
    echo "0" > "$TELEMETRY_LOG"
}

# Getter:
counter_get() {
    if [ -f "${TELEMETRY_LOG:-}" ]; then
        cat "$TELEMETRY_LOG"
    else
        echo "0"
    fi
}

# Destructor / Cleanup:
counter_cleanup() {
    if [ -n "${TELEMETRY_LOG:-}" ] && [ -f "$TELEMETRY_LOG" ]; then
        rm -f "$TELEMETRY_LOG"
        unset TELEMETRY_LOG
    fi
}

# Increments counter and succeeds only when target_attempt is reached.
# If target_attempt is never or false or target is > max_retries it will never succeed
succeed_on_attempt() {
    local target_attempt="$1"

    if [ -z "${TELEMETRY_LOG:-}" ] || [ ! -f "$TELEMETRY_LOG" ]; then
        echo "Error: TELEMETRY_LOG is not initialized. Call counter_init first." >&2
        return 2
    fi

    local count
    count=$(cat "$TELEMETRY_LOG")
    count=$((count + 1))
    echo "$count" > "$TELEMETRY_LOG"

    case "$target_attempt" in
        never|false)
            return 1
            ;;
        *)
            if [ "$count" -ge "$target_attempt" ]; then
                return 0
            fi
            return 1
            ;;
    esac
}
export -f counter_init counter_get counter_cleanup succeed_on_attempt

#==================================================================================
# TEARDOWN SUPPORT
#==================================================================================
log_test_execution() {
    local target_dir="${1:-}"
    local test_title="${BATS_TEST_DESCRIPTION:-$BATS_TEST_NAME}"

    # Always append execution output to a dedicated log in the test directory
    # optimally we should check whether the temp folder will be preserved before writing
    if [ -n "${target_dir:-}" ] && [ -d "$target_dir" ]; then
        {
            echo "============================================================"
            echo "TEST: ${test_title}"
            echo "EXIT STATUS: ${status:-0}"
            echo "--- OUTPUT ---"
            echo "${output:-<no output>}"
            echo ""
        } >> "$target_dir/test_execution.log"
    fi

    # Conditionally dump to FD 3 (console) only when DEBUG is enabled
    if [ "${DEBUG:-0}" = "1" ] || [ "${BATS_DEBUG:-0}" = "1" ]; then
        echo -e "\n[DEBUG: ${test_title}] (Status: ${status:-0})\n${output:-<no output>}" >&3
    fi
}

cleanup_test_dir() {
    local target_dir="${1:-}"
    local preserve_mode="${PRESERVE_TEST_DIR:-never}"

    # If no target directory is set or it doesn't exist, exit cleanly
    if [ -z "$target_dir" ] || [ ! -d "$target_dir" ]; then
        printf "[DEBUG] Folder to clean is not provided or is not a directory: %s\n" \
            "$target_dir" >&3
        return 0
    fi

    case "$preserve_mode" in
        # Always preserve regardless of outcome
        "true"|"all"|"always"|"1")
            printf "[DEBUG] Preserving test directory (mode: %s): %s\n" \
                "$preserve_mode" "$target_dir" >&3
            return 0
            ;;

        # Preserve only when the test fails
        "fail"|"failure"|"on-fail"|"on_fail")
            if [ "${BATS_TEST_COMPLETED:-0}" -ne 1 ]; then
                printf "[DEBUG] Test FAILED (%s). Preserved: %s\n" \
                    "${BATS_TEST_NAME:-unknown}" "$target_dir" >&3
                return 0
            fi
            ;;

        # Default / explicit cleanup
        "false"|"never"|"0"|*)
            ;;
    esac

    # Perform standard cleanup if preservation criteria weren't met
    rm -rf "$target_dir"
}
export -f cleanup_test_dir log_test_execution

#==================================================================================
# TELEMETRY SUPPORT
#==================================================================================

# ==============================================================================================
# TELEMETRY LOG SCHEMA
# Format: MOCK|NODE|ACTION|DEST_OR_TARGET|SRC_OR_PAYLOAD|MODE_OR_ARGS|RAW_COMMAND
# ==============================================================================================
# ACTION | MEANING                           | DEST_OR_TARGET       | SRC_OR_PAYLOAD       | MODE_OR_ARGS
# -------+-----------------------------------+----------------------+----------------------+------------------------------
# PUT    | File creation/copy (scp,cp,inst)  | Remote target path   | Source path          | mode:<val> | mode:default
# MOVE   | File relocation (mv)              | Remote target path   | Remote source path   | -
# MKDIR  | Directory creation (mkdir,inst -d)| Remote dir path      | -                    | mode:<val> | mode:default
# CHMOD  | Permission change (chmod)         | Remote path          | -                    | mode:<val>
# EXEC   | Script or apply-config run        | Remote script/target | Payload / Subcommand | role:<val> | runner:bash
# PROBE  | Ping / Connection check (exit)    | -                    | -                    | -
# ==============================================================================================

# usage: telemetry_log_init [folder] [file]
telemetry_log_init() {
    local target_dir="${1:-${TEST_TEMP_DIR:-$(mktemp -d -t test_support.XXXXXX)}}"
    local target_file="${2:-telemetry_$(date +%s%N)_$$.log}"

    mkdir -p "${target_dir}"
    export TELEMETRY_LOG="${target_dir%/}/${target_file}"
    touch "$TELEMETRY_LOG"
}

telemetry_log_cleanup() {
    if [ -n "${TELEMETRY_LOG:-}" ] && [ -f "$TELEMETRY_LOG" ]; then
        rm -f "$TELEMETRY_LOG"
        unset TELEMETRY_LOG
    fi
}

log_telemetry() {
    # Fail safely if log has not been initialized
    if [ -z "${TELEMETRY_LOG:-}" ]; then
        echo "TELEMETRY ERROR: log_telemetry called before telemetry_log_init" >&2
        return 1
    fi

    local type="${1:-}"
    local node="${2:-}"
    local action="${3:-}"
    local target="${4:-}"
    local src="${5:-}"
    local details="${6:-}"
    local raw_cmd="${7:-}"

    # Strips both single (') and double (") quotes safely
    node="${node//[\'\"]/}"
    action="${action//[\'\"]/}"
    target="${target//[\'\"]/}"
    src="${src//[\'\"]/}"
    details="${details//[\'\"]/}"

    # 🔒 The raw_cmd remains completely unmodified and retains its original script quotes!
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$type" "$node" "$action" "$target" "$src" "$details" "$raw_cmd" >> "$TELEMETRY_LOG"

}
export -f telemetry_log_init telemetry_log_cleanup log_telemetry

# ==============================================================================
# ASSERTION HELPERS (rather than adding BATS git submodules)
# ==============================================================================
# Usage: assert [ <expression> ] OR assert test <expression> OR assert [[ <expression> ]]
assert() {
    # If called without test/[/[[ wrapper, evaluate arguments directly with test
    if [ "$#" -eq 0 ]; then
        echo "ASSERTION FAILED: assert_true called with empty expression." >&2
        return 1
    fi

    if ! "$@"; then
        echo "ASSERTION FAILED: Expected expression to evaluate to TRUE (0)." >&2
        echo "Expression: $*" >&2
        return 1
    fi
}

# standard bats assert is refute for assert_false. Simply helps with ide highlighting
# Usage: refute [ <expression> ] OR refute test <expression> OR refute [[ <expression> ]]
refute() {
    if [ "$#" -eq 0 ]; then
        echo "ASSERTION FAILED: assert_false called with empty expression." >&2
        return 1
    fi

    if "$@"; then
        echo "ASSERTION FAILED: Expected expression to evaluate to FALSE (non-zero)." >&2
        echo "Expression: $*" >&2
        return 1
    fi
}

assert_success() {
    if [ "$status" -ne 0 ]; then
        echo "Expected command to succeed (exit status 0), but exited with status $status." >&2
        echo "--- Output ---" >&2
        echo "$output" >&2
        return 1
    fi
}

assert_failure() {
    local expected_status="${1:-}"
    if [ -n "$expected_status" ]; then
        if [ "$status" -ne "$expected_status" ]; then
            echo "Expected exit status $expected_status, but got $status." >&2
            echo "--- Output ---" >&2
            echo "$output" >&2
            return 1
        fi
    elif [ "$status" -eq 0 ]; then
        echo "Expected command to fail (exit status != 0), but exited with status 0." >&2
        echo "--- Output ---" >&2
        echo "$output" >&2
        return 1
    fi

    return 0
}

# Usage:
#   assert_output "exact string"
#   assert_output --partial "substring"
#   assert_output --regexp "(FAILED|ERROR)"
assert_output() {
    local mode="exact"
    case "${1:-}" in
        --partial|-p) mode="partial"; shift ;;
        --regexp|-e)  mode="regexp";  shift ;;
    esac

    local expected="$1"

    case "$mode" in
        partial)
            if [[ "${output:-}" != *"$expected"* ]]; then
                echo "ASSERTION FAILED: Output does not contain expected substring." >&2
                echo "Expected substring: '$expected'" >&2
                echo "--- Actual Output ---" >&2
                echo "${output:-<no output>}" >&2
                return 1
            fi
            ;;
        regexp)
            if [[ ! "${output:-}" =~ $expected ]]; then
                echo "ASSERTION FAILED: Output does not match expected regex." >&2
                echo "Expected regex: '$expected'" >&2
                echo "--- Actual Output ---" >&2
                echo "${output:-<no output>}" >&2
                return 1
            fi
            ;;
        exact)
            if [ "${output:-}" != "$expected" ]; then
                echo "ASSERTION FAILED: Output does not match expected exact string." >&2
                echo "Expected: '$expected'" >&2
                echo "--- Actual Output ---" >&2
                echo "${output:-<no output>}" >&2
                return 1
            fi
            ;;
    esac
}

# Usage:
#   refute_output "exact string"
#   refute_output --partial "ERROR"
#   refute_output --regexp "^(WARN|FATAL)"
refute_output() {
    local mode="exact"
    case "${1:-}" in
        --partial|-p) mode="partial"; shift ;;
        --regexp|-e)  mode="regexp";  shift ;;
    esac

    local unexpected="$1"

    case "$mode" in
        partial)
            if [[ "${output:-}" == *"$unexpected"* ]]; then
                echo "ASSERTION FAILED: Output contains prohibited substring." >&2
                echo "Prohibited substring: '$unexpected'" >&2
                echo "--- Actual Output ---" >&2
                echo "${output:-<no output>}" >&2
                return 1
            fi
            ;;
        regexp)
            if [[ "${output:-}" =~ $unexpected ]]; then
                echo "ASSERTION FAILED: Output matches prohibited regex." >&2
                echo "Prohibited regex: '$unexpected'" >&2
                echo "--- Actual Output ---" >&2
                echo "${output:-<no output>}" >&2
                return 1
            fi
            ;;
        exact)
            if [ "${output:-}" = "$unexpected" ]; then
                echo "ASSERTION FAILED: Output matches prohibited exact string." >&2
                echo "Prohibited: '$unexpected'" >&2
                echo "--- Actual Output ---" >&2
                echo "${output:-<no output>}" >&2
                return 1
            fi
            ;;
    esac
}

assert_file_exists() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "ASSERTION FAILED: Expected regular file does not exist: '$path'" >&2
        return 1
    fi
}

assert_file_not_exists() {
    local path="$1"
    if [ -e "$path" ]; then
        echo "ASSERTION FAILED: Expected file/path NOT to exist, but found: '$path'" >&2
        return 1
    fi
}

assert_dir_exists() {
    local path="$1"
    if [ ! -d "$path" ]; then
        echo "ASSERTION FAILED: Expected directory does not exist: '$path'" >&2
        return 1
    fi
}

assert_dir_not_exists() {
    local path="$1"
    if [ -d "$path" ]; then
        echo "ASSERTION FAILED: Expected directory NOT to exist, but found: '$path'" >&2
        return 1
    fi
}

assert_file_contains() {
    local pattern="$1"
    local file="$2"

    if [ ! -f "$file" ]; then
        echo "Assertion failed: File '$file' does not exist." >&2
        return 1
    fi

    if ! grep -q "$pattern" "$file"; then
        echo "Expected file '$file' to contain pattern: '$pattern'" >&2
        echo "--- File Contents ---" >&2
        cat "$file" >&2
        return 1
    fi
}

assert_file_not_contains() {
    local pattern="$1"
    local file="$2"

    if [ ! -f "$file" ]; then
        return 0
    fi

    if grep -q "$pattern" "$file"; then
        echo "Expected file '$file' NOT to contain pattern: '$pattern'" >&2
        echo "--- Matching Lines Found ---" >&2
        grep "$pattern" "$file" >&2
        return 1
    fi
}


export -f assert \
          refute \
          assert_success \
          assert_failure \
          assert_output \
          refute_output \
          assert_file_exists \
          assert_file_not_exists \
          assert_dir_exists \
          assert_dir_not_exists \
          assert_file_contains \
          assert_file_not_contains
