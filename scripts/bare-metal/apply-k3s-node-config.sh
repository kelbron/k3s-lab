#!/usr/bin/env bash
# ==============================================================================
# Hardened Configuration Promotion & Dynamic Service Restart Controller
#
# Complies with:
# - ADR 011: Automation & Scripting Standards (Idempotence & Strict Error Handling)
# - CWE-200 / CWE-552: Secret Exposure prevention (Strict 0600 permissions)
# - CWE-377: Secure staging validation
# ==============================================================================
set -euo pipefail

# Assert script is executing with root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Error: This provisioning script must be run with root privileges (use sudo)." >&2
    exit 1
fi

if [ -z "${SUDO_USER:-}" ]; then
    echo "❌ Error: Direct root account execution is forbidden on this device." >&2
    echo "   You must log in as your personal account and use 'sudo'." >&2
    exit 1
fi

# Resolve directory containing the current script (handles symlinks and relative calls)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)"

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

# ⚙️ HELPER: Print error to stderr and exit
fail() {
    echo "❌ ERROR: $1" >&2
    exit 1
}

# ⚙️ HELPER: Print status info
info() {
    echo "--> $1"
}

LIB_FILE="${SCRIPT_DIR}/common-lib.sh"

# Validate existence and readability before sourcing
if [ ! -r "$LIB_FILE" ]; then
    fail "Required library not found or not readable at '${LIB_FILE}'."
fi

# shellcheck source=/dev/null
source "$LIB_FILE"

# ==============================================================================
# 🛡️ PHASE 1: INPUT VALIDATION & STAGING CONFIG PROMOTION
# ==============================================================================

# Expect the staging path as the first argument
# Force the calling script to declare exactly what file to promote
if [ -z "${1:-}" ]; then
    echo "Error: Missing required staging configuration file path argument." >&2
    echo "Usage: $0 /path/to/staging/config.yaml" >&2
    exit 1
fi
SRC_CONFIG="${1}"

# If path is relative, anchor it to the executing sudo user's home
if [[ "$SRC_CONFIG" != /* ]]; then
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    SRC_CONFIG="${USER_HOME}/${SRC_CONFIG}"
fi

info "Validating configuration file source: ${SRC_CONFIG}"
if [ ! -f "$SRC_CONFIG" ]; then
    fail "Configuration source file '${SRC_CONFIG}' does not exist or is not a regular file."
fi

if [ ! -r "$SRC_CONFIG" ]; then
    fail "Configuration file '${SRC_CONFIG}' is not readable."
fi
trap 'rm -f "$SRC_CONFIG"' EXIT # Ensure cleanup on exit

# Ensure target configuration directory exists securely (0750 for config directory is standard)
TARGET_DIR="${K3S_CONFIG_DIR:-/etc/rancher/k3s}"
if [ ! -d "$TARGET_DIR" ]; then
    info "Target directory '${TARGET_DIR}' does not exist. Creating secure directory..."
    # using mkdir -m -p gets past the race condition posed by mkdir -p, chmod -R but that only
    # changes the mode on the deepest folder. Using umask inverts the mode specification by applying a bitwise filter
    ( umask 027 && mkdir -p "$TARGET_DIR" )
fi

# Securely move and restrict permissions (CWE-200 / CWE-552 Compliance)
# Moving is atomic across the same filesystem. We apply permissions instantly.
info "Promoting configuration to ${TARGET_DIR}/config.yaml"
install -m 0600 -o root -g root "$SRC_CONFIG" "${TARGET_DIR}/config.yaml"

# Clean up the staging file immediately to prevent trailing secret exposures in /tmp
info "Purging staging file: ${SRC_CONFIG}"
rm -f "$SRC_CONFIG"

# ==============================================================================
# ☸️ PHASE 2: DYNAMIC SERVICE DETECTION & ASYNCHRONOUS RESTART
# ==============================================================================

info "Detecting installed K3s systemd services..."

# Check which unit files are registered in systemd dynamically
HAS_SERVER=false
HAS_AGENT=false

if systemctl cat k3s.service &>/dev/null; then
    HAS_SERVER=true
fi

if systemctl cat k3s-agent.service &>/dev/null; then
    HAS_AGENT=true
fi

# Determine service target based on role availability
SERVICE_NAME=""
if [ "$HAS_SERVER" = "true" ] && [ "$HAS_AGENT" = "true" ]; then
    # Hybrid node? Fallback to server if both exist, or let's default to server
    SERVICE_NAME="k3s"
elif [ "$HAS_SERVER" = "true" ]; then
    SERVICE_NAME="k3s"
elif [ "$HAS_AGENT" = "true" ]; then
    SERVICE_NAME="k3s-agent"
else
    # Neither service is present on disk yet
    fail "No registered K3s service (k3s.service or k3s-agent.service) was found on this node."
fi

info "Detected active runtime service mapping: ${SERVICE_NAME}.service"

# ==============================================================================
# 🚀 PHASE 3: NON-BLOCKING SERVICE RESTART (Bypasses SSH pseudo-TTY freezes)
# ==============================================================================

info "Executing asynchronous daemon-reload and systemd restart queue..."

# Force systemd to reload its configuration units
systemctl daemon-reload

# By using --no-block, systemctl registers the restart job in systemd's queue
# and exits immediately with code 0. It prints syntax/privilege errors synchronously
# to stderr if the action itself is invalid, but prevents SSH connection timeouts
# from hanging on flannel/cbr0 routing flushes.
if ! systemctl restart "$SERVICE_NAME" --no-block; then
    fail "Failed to queue the restart job for ${SERVICE_NAME}.service inside systemd."
fi

info "Restart of ${SERVICE_NAME}.service queued asynchronously. Polling functional readiness on node..."

# check that the configured node has restarted and is ready
check_node_readiness() {
    local output=""

    if [ "$SERVICE_NAME" = "k3s" ]; then
        # Server: Probe API server readiness
        if command -v k3s >/dev/null; then
            # k3s kubectl returns exit 0 and outputs "ok" on success
            output=$(k3s kubectl get --raw='/readyz' 2>&1) || return 1
            [ "$output" = "ok" ]
        else
            return 1
        fi
    else
        # Agent: Probe local Kubelet healthz endpoint
        output=$(curl -s --max-time 2 -f http://127.0.0.1:10248/healthz 2>&1) || return 1
        [ "$output" = "ok" ]
    fi
}

# Polling loop: Traps timeout cleanly and dumps logs before failing
if ! wait_for_condition 30 2 "${SERVICE_NAME} functional readiness" check_node_readiness; then
    echo "======================================================================" >&2
    echo "❌ DIAGNOSTIC LOG DUMP FOR ${SERVICE_NAME}.service" >&2
    echo "======================================================================" >&2
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager >&2 || true
    fail "Timed out waiting for ${SERVICE_NAME}.service to reach operational state."
fi

echo "✅ SUCCESS: K3s configuration applied and ${SERVICE_NAME}.service is functional!"
