#!/usr/bin/env bats

setup() {
    TEST_DIR="$(cd "$BATS_TEST_DIRNAME" && pwd)"
    REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"        # Adjust '../..' if nested in test/unit/

    # 2. Define SCRIPT_DIR
    export SCRIPT_DIR="${REPO_ROOT}/scripts/bare-metal"

    [ -d "$SCRIPT_DIR" ] || {
        echo "SETUP ERROR: SCRIPT_DIR not found at '$SCRIPT_DIR'" >&2
        return 1
    }

    local source_script="${SCRIPT_DIR}/provision-node.sh"

    [ -f "${source_script}" ] || {
        echo "SETUP ERROR: Source script not found at '${source_script}'" >&2
        return 1
    }

    # Create an isolated temporary folder for scripts and for logging execution telemetry
    TEST_TEMP_DIR="$(mktemp -d -t k3s-provision-node-test.XXXXXX)"
    export TEST_TEMP_DIR

    # load the test helper functions
    load "${REPO_ROOT}/tests/support/test_helpers.bash"

    # Define sandboxed targets
    export STAGING_DIR="${TEST_TEMP_DIR}/tmp"
    export K3S_CONFIG_DIR="${TEST_TEMP_DIR}/etc/rancher/k3s"
    export BIN_DIR="${TEST_TEMP_DIR}/usr/local/bin"
    export SUDOERS_DIR="${TEST_TEMP_DIR}/etc/sudoers.d"
    export TARGET_USER="mock-sysop"

    telemetry_log_init "${TEST_TEMP_DIR}" telemetry.log

    mkdir -p "${STAGING_DIR}"

    # Stage default payloads in staging directory
    touch "${STAGING_DIR}/apply-k3s-node-config.sh"
    touch "${STAGING_DIR}/common-lib.sh"

    # Stage script under test into the test sandbox
    export SCRIPT_UNDER_TEST="${TEST_TEMP_DIR}/provision-node.sh"
    cp "${source_script}" "${SCRIPT_UNDER_TEST}"
    chmod +x "${SCRIPT_UNDER_TEST}"

    # Mock install: intercept privileged owner/group flags to prevent test failures on unprivileged runs,
    # record invocation arguments for assertion verification, and create files/dirs on disk.
    install() {
        local raw_cmd="install $*"

        # Fail fast if basic contract (at least src and dest) is broken
        if [ "$#" -lt 2 ]; then
            echo "TEST_HELPERS ERROR: spy_install expected at least src and dest, got: ${raw_cmd}" >&2
            return 1
        fi

        # Detect if this is a directory creation command (-d)
        local is_dir=false
        for arg in "$@"; do
            if [ "$arg" = "-d" ]; then
                is_dir=true
                break
            fi
        done

        # Extract src and dest based on mode
        local dest="${@: -1}"
        local src=""
        local opts=()

        if [ "$is_dir" = true ]; then
            # Directory mode: everything except the last argument is an option
            opts=("${@:1:$#-1}")
        else
            # File copy mode: expect at least 2 non-option targets
            if [ "$#" -lt 2 ]; then
                echo "TEST_HELPERS ERROR: spy_install expected at least src and dest, got: ${raw_cmd}" >&2
                return 1
            fi
            src="${@: -2:1}"
            opts=("${@:1:$#-2}")
        fi

        local sanitized_opts=()
        local owner=""
        local group=""

        # parse and remove owner and group to avoid root privilege issues during testing
        local i=0
        while [ "$i" -lt "${#opts[@]}" ]; do
            case "${opts[$i]}" in
                -o|--owner)
                    # Protect against unbound index if flag is at the very end
                    owner="${opts[$((i+1))]:-}"
                    i=$((i+2))
                    ;;
                --owner=*)
                    owner="${opts[$i]#*=}"
                    i=$((i+1))
                    ;;
                -g|--group)
                    group="${opts[$((i+1))]:-}"
                    i=$((i+2))
                    ;;
                --group=*)
                    group="${opts[$i]#*=}"
                    i=$((i+1))
                    ;;
                *)
                    sanitized_opts+=("${opts[$i]}")
                    i=$((i+1))
                    ;;
            esac
        done

        local details=""
        details="${owner:+owner:${owner}}${group:+,group:${group}}"
        details="${details#,}" # Clean up a leading comma if owner was empty but group exists

        local action="PUT"
        [ "$is_dir" = true ] && action="MKDIR"

        log_telemetry "INSTALL" "local" "$action" "$dest" "${src:--}" "${details:--}" "$raw_cmd"

        # Create a clean, single-line passthrough to the real install command
        # If $src is empty (directory mode), Bash expands it safely to nothing
        builtin command install "${sanitized_opts[@]}" ${src:+"$src"} "$dest"

    }

    # Mock id to simulate root user
    id() {
        if [ "${1:-}" = "-u" ]; then
            echo "0"
            return 0
        fi
        command id "$@"
    }

    apt-get() {
        local raw_cmd="apt-get $*"
        local exit_code="${MOCK_APT_GET_EXIT_CODE:-0}"
        local packages=()

        local verb="${1:-}"
        shift || true

        case "$verb" in
            update)
                exit_code=0         # not mocking update failures for now, but could be added later
                ;;

            install)
                for arg in "$@"; do
                    case "$arg" in
                        -*) ;; # Strip flags (-y, -q, etc.)
                        *) packages+=("$arg") ;;
                    esac
                done
                ;;
        esac

        log_telemetry "APT" "local" "${verb^^}" "${packages[*]:--}" "-" "-" "$raw_cmd"

        return "$exit_code"
    }

    groupadd() { return 0; }

    usermod() {
        local raw_cmd=""
        local append_flag="false"
        local target_groups=""
        local target_user=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -a)
                    append_flag="true"
                    shift
                    ;;
                -G|-aG)
                    # Handle both '-G docker' or squished '-aG docker' variants
                    if [[ "$1" == "-aG" ]]; then
                        append_flag="true"
                    fi
                    groups_flag="true"
                    target_groups="$2"
                    shift 2
                    ;;
                -*)
                    echo "Mock usermod: Unsupported option $1" >&2
                    return 1
                    ;;
                *)
                    # The final remaining argument is the username
                    target_user="$1"
                    shift
                    ;;
            esac
        done

        log_telemetry "USERMOD" "local" "GRANT" "$target_user" "$target_groups" "append:${append_flag}" "$raw_cmd"

        return 0;
    }

    command() {
        if [ "$1" = "-v" ] && [ "$2" = "docker" ]; then
            return 0
        fi
        builtin command "$@"
    }

    visudo() {
        return 0
    }

    docker() {
        if [ "$1" = "info" ]; then
            return 0
        fi
        builtin command docker "$@"
    }

    systemctl() {
        return 0
    }

    export -f install groupadd usermod visudo id apt-get command docker systemctl
    # mock running via sudo
    export SUDO_USER="bats-test-runner"
    export USER="root"
}

teardown() {
    log_test_execution "$TEST_TEMP_DIR"
    cleanup_test_dir "$TEST_TEMP_DIR"
}


# ==============================================================================
# INPUT & ARGUMENT VALIDATION
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


@test "validation: fails immediately if apt-get install fails during docker installation" {
    apt-get() {
        if [ "$1" = "install" ]; then
            echo "E: Failed to fetch" >&2
            return 100
        fi
        return 0
    }
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "docker" ]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f apt-get command

    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"

    assert_failure 100
    assert_output --partial "E: Failed to fetch"
}

assert_file_contains_between() {
    local target="$1"
    local start="$2"
    local end="$3"
    local file="$4"

    if [ ! -f "$file" ]; then
        echo "assert_file_contains_between failed: file not found '$file'" >&2
        return 1
    fi

    # Parse line numbers using awk in a single pass
    local result
    result=$(awk -v start="$start" -v end="$end" -v target="$target" '
        # Look for the start line
        start_line == 0 && $0 ~ start {
            start_line = NR
            next
        }
        # Once start is found, look for target before end
        start_line > 0 && target_line == 0 && $0 ~ target {
            target_line = NR
            next
        }
        # Once start is found, look for end line
        start_line > 0 && $0 ~ end {
            end_line = NR
            exit
        }
        END {
            print (start_line ? start_line : 0) ":" (target_line ? target_line : 0) ":" (end_line ? end_line : 0)
        }
    ' "$file")

    local s_line t_line e_line
    s_line=$(echo "$result" | cut -d: -f1)
    t_line=$(echo "$result" | cut -d: -f2)
    e_line=$(echo "$result" | cut -d: -f3)

    local expected_msg="Expected to find target '$target' between start '$start' and end '$end' in file '$file'."

    # Diagnostic checks
    if [ "$s_line" -eq 0 ]; then
        echo "ASSERTION FAILED: ${expected_msg}\n   Start line '$start' not found" >&2
        return 1
    fi

    if [ "$e_line" -eq 0 ]; then
        echo "ASSERTION FAILED: ${expected_msg}\n   End line '$end' not found after start line" >&2
        return 1
    fi

    if [ "$t_line" -eq 0 ] || [ "$t_line" -ge "$e_line" ]; then
        echo "ASSERTION FAILED: ${expected_msg}\n   Target line '$target' not found between start and end lines" >&2
        return 1
    fi
}

@test "validation: successfully installs docker when not present" {
    export APT_KEYRINGS_DIR="${TEST_TEMP_DIR}/etc/apt/keyrings"
    export APT_SOURCES_DIR="${TEST_TEMP_DIR}/etc/apt/sources.list.d"
    export MOCK_APT_GET_EXIT_CODE=0

    command() {
        if [ "$1" = "-v" ] && [ "$2" = "docker" ]; then
            return 1
        fi
        builtin command "$@"
    }
    curl() {
        local out_file=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -o|--output)
                    out_file="$2"
                    shift 2
                    ;;
                *)
                    shift
                    ;;
            esac
        done

        log_telemetry "CURL" "local" "FETCH" "${out_file:-}" "-" "-" "$*"

        if [ -n "$out_file" ]; then
            mkdir -p "$(dirname "$out_file")"
            echo "-----BEGIN PGP PUBLIC KEY BLOCK-----" > "$out_file"
            # Explicitly restrict permissions to simulate umask/curl private write
            chmod 0600 "$out_file"
            return 0
        fi
        return 1
    }
    export -f curl command

    mkdir -p "${APT_SOURCES_DIR}"  # create temporary apt sources folder

    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"

    echo "$output" >&3

    assert_success
    assert_output --partial "Docker installation completed successfully."
    assert_file_exists "${APT_KEYRINGS_DIR}/docker.asc"
    assert_file_exists "${APT_SOURCES_DIR}/docker.sources"
    assert [ "$(stat -c "%a" "${APT_KEYRINGS_DIR}")" = "755" ]
    assert [ "$(stat -c "%a" "${APT_KEYRINGS_DIR}/docker.asc")" = "644" ]
    assert_file_contains "^APT|local|INSTALL|ca-certificates curl|-|-|" "$TELEMETRY_LOG"
    assert_file_contains "^APT|local|INSTALL|docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin|-|-|" "$TELEMETRY_LOG"
    assert_file_contains_between "^CURL|local|FETCH|${APT_KEYRINGS_DIR}/docker.asc|-|-|"  "^APT|local|INSTALL|docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin|-|-|" "^APT|local|UPDATE|" "$TELEMETRY_LOG"
}

@test "validation: fails immediately if docker install fails due to curl failure" {
    export APT_KEYRINGS_DIR="${TEST_TEMP_DIR}/etc/apt/keyrings"
    export APT_SOURCES_DIR="${TEST_TEMP_DIR}/etc/apt/sources.list.d"

    command() {
        if [ "$1" = "-v" ] && [ "$2" = "docker" ]; then
            return 1
        fi
        builtin command "$@"
    }
    curl() {
        return 22
    }
    export -f curl command

    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"

    assert_failure
    assert_output --partial "Error: Docker installation failed."
}

@test "validation: fails immediately if systemctl enable docker now fails" {
    systemctl() {
        if ( [ "$1" = "enable" ] && [ "$2" = "--now" ] && [ "$3" = "docker" ] ); then
            log_telemetry "SYSTEMCTL" "local" "ENABLE" "docker" "-" "now:true" "$*"
            return 1
        fi
        return 0
    }
    export -f systemctl

    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"

    assert_failure
    assert_file_contains "^SYSTEMCTL|local|ENABLE|docker|-|now:true|" "$TELEMETRY_LOG"
}

@test "validation: fails immediately if docker info fails" {
    docker() {
        if [ "$1" = "info" ]; then
            log_telemetry "DOCKER" "local" "INFO" "-" "-" "-" "docker $*"
            return 1
        fi
        return 0
    }

    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"

    assert_failure
    assert_file_contains "^DOCKER|local|INFO|-|" "$TELEMETRY_LOG"
}

@test "validation: fails immediately if visudo detects invalid sudoers syntax" {
    visudo() {
        echo "visudo: >>> syntax error <<<" >&2
        return 1
    }
    export -f visudo

    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"

    assert_failure 1
    assert_output --partial "syntax error"
    assert [ ! -f "${SUDOERS_DIR}/k3s-admin-safe" ]
}

@test "validation: fails fast when apply-k3s-node-config.sh is missing from staging" {
    rm -f "${STAGING_DIR}/apply-k3s-node-config.sh"

    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"

    assert_failure 1
    assert_output --partial "Missing: ${STAGING_DIR}/apply-k3s-node-config.sh"
}

@test "validation: fails fast when common-lib.sh is missing from staging" {
    rm -f "${STAGING_DIR}/common-lib.sh"

    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"

    assert_failure 1
    assert_output --partial "Missing: ${STAGING_DIR}/common-lib.sh"
}

# --- Ownership, Mode, and Installation Verification ---
@test "behaviour: target user is added to the docker group" {
    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"
    assert_success
    assert_file_contains "^USERMOD|local|GRANT|${TARGET_USER}|docker|append:true|" "$TELEMETRY_LOG"
}

@test "behaviour: verifies k3s config directory ownership, group, and mode parameters" {
    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"

    assert_success
    assert_file_contains "^INSTALL|local|MKDIR|${K3S_CONFIG_DIR}|-|owner:root,group:k3s-admin|" "$TELEMETRY_LOG"
    assert_dir_exists "${K3S_CONFIG_DIR}"
    assert [ "$(stat -c "%a" "$K3S_CONFIG_DIR")" = "775" ]
}

@test "behaviour: verifies bin directory ownership, group, and mode parameters" {
    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"

    assert_success
    assert_file_contains "^INSTALL|local|MKDIR|${BIN_DIR}|-|-|" "$TELEMETRY_LOG"
    assert_dir_exists "${BIN_DIR}"
    assert [ "$(stat -c "%a" "$BIN_DIR")" = "755" ]
}

@test "behaviour: verifies sudoers directory ownership, group, and mode parameters" {
    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"

    assert_success
    assert_file_contains "^INSTALL|local|MKDIR|${SUDOERS_DIR}|-|-|" "$TELEMETRY_LOG"
    assert_dir_exists "${SUDOERS_DIR}"
    assert [ "$(stat -c "%a" "$SUDOERS_DIR")" = "755" ]
}

@test "behaviour: copies binary and library with exact file modes" {
    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"

    assert_success
    assert_file_exists "${BIN_DIR}/apply-k3s-node-config.sh"
    assert_file_exists "${BIN_DIR}/common-lib.sh"

    assert [ "$(stat -c "%a" "${BIN_DIR}/apply-k3s-node-config.sh")" = "755" ]
    assert [ "$(stat -c "%a" "${BIN_DIR}/common-lib.sh")" = "644" ]
}

@test "behaviour: enforces mode 0440 and valid syntax on sudoers rule" {
    run "${SCRIPT_UNDER_TEST}" "${TARGET_USER}" "${STAGING_DIR}"

    assert_success
    local sudo_file="${SUDOERS_DIR}/k3s-admin-safe"
    assert [ "$(stat -c "%a" "$sudo_file")" = "440" ]
    assert_file_contains "^${TARGET_USER}\s\+ALL=(ALL)\s\+NOPASSWD:\s\+${BIN_DIR}/apply-k3s-node-config.sh" "$sudo_file"
}
