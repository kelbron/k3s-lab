#!/usr/bin/env bash
set -euo pipefail

# Inherit SECURE_TMP_DIR from parent Makefile, fallback to a safe local default if run standalone
if [ -z "${SECURE_TMP_DIR:-}" ]; then
    # Lightweight, portable single-line fallback for direct script executions
    WORKSPACE_HASH="$( (printf '%s' "$(pwd)" | sha256sum 2>/dev/null || printf '%s' "$(pwd)" | shasum -a 256 2>/dev/null || echo "default") | cut -c1-8 )"
    SECURE_TMP_DIR="/tmp/k3s-lab-$(id -u)-${WORKSPACE_HASH}"
fi

# Ensure the workspace directory is prepped and locked down (0700)
# using mkdir -m 700 -p "${SECURE_TMP_DIR}" gets past the race condition posed by mkdir -p, chmod -R but that only
# changes the mode on the deepest folder. Using umask inverts the mode specification by applying a bitwise filter
( umask 027 && mkdir -p "${SECURE_TMP_DIR}" )

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LIB_DIR="${REPO_ROOT}/scripts/lib"

# "Load the local common library"
# shellcheck source=/dev/null
source "${LIB_DIR}/common-lib.sh"

STAGING_DIR="${STAGING_DIR:-k3s-staging}" # path relative to user's home directory


echo "=== Validating and Parsing Node Inventory ==="
declare -a CLUSTER_NODES

# Validate and Register Control Plane
if [ -z "${CONTROL_PLANE_NODE:-}" ]; then
    echo "FAILED: CONTROL_PLANE_NODE is missing from the provided environment!"
    exit 1
fi

declare -A WORKER_NODES

# Validate and Parse Worker Nodes
if [ -z "${WORKER_NODES_CONFIG:-}" ]; then
    echo "FAILED: WORKER_NODES_CONFIG is missing from the provided environment!"
    exit 1
fi

for record in $WORKER_NODES_CONFIG; do
    IFS=':' read -r node ip extra <<< "$record"

    # FAIL EARLY: Check if the string was malformed (missing node or IP)
    if [ -z "${node:-}" ] || [ -z "${ip:-}" ] || [ -n "${extra:-}" ] || [[ ! "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        echo "FAILED: Malformed worker node record '$record'." >&2
        echo "Expected format 'hostname:IP' where IP is a valid IPv4 address." >&2
        exit 1
    fi

    for octet in "${BASH_REMATCH[@]:1}"; do
        if (( octet > 255 )); then
            echo "FAILED: Malformed worker node record '$record' (octet $octet out of range 0-255)." >&2
            exit 1
        fi
    done

    # Register the worker and dynamically build its config file name
    WORKER_NODES["$node"]="$ip"
done

# Create cluster node list
CLUSTER_NODES=("${CONTROL_PLANE_NODE}" "${!WORKER_NODES[@]}")

echo "=== K3s Lab Connectivity Check ==="
# Check Control Plane
echo -n "Testing SSH connection to ${CONTROL_PLANE_NODE}... "
if ssh -n -o BatchMode=yes -o ConnectTimeout=5 "${CONTROL_PLANE_NODE}" exit; then
    echo "Control plane connectivity verified."
else
    echo "FAILED: Cannot reach control plane node."
    exit 1
fi

for node in "${CLUSTER_NODES[@]}"; do
    echo -n "Testing SSH connection to ${node}... "
    if ssh -n -o BatchMode=yes -o ConnectTimeout=5 "${node}" exit; then
        echo "OK"
    else
        echo "FAILED"
        exit 1
    fi
done

echo ""
echo "=== Provisioning Remote Host Environments ==="
for node in "${CLUSTER_NODES[@]}"; do
    echo "--> Provisioning ${node}..."
    scp -o BatchMode=yes "${SCRIPT_DIR}/provision-node.sh" "${node}:/tmp/provision-node.sh"
    scp -o BatchMode=yes "${SCRIPT_DIR}/apply-k3s-node-config.sh" "${node}:/tmp/apply-k3s-node-config.sh"
    scp -o BatchMode=yes "${LIB_DIR}/common-lib.sh" "${node}:/tmp/common-lib.sh"
    ssh -n -o BatchMode=yes "${node}" "sudo bash /tmp/provision-node.sh"
done

echo ""
echo "=== Deploying Control Plane ($CONTROL_PLANE_NODE) ==="

# We don't need a secure staging directory for the control-plane but using one protects us if the config.yaml changes
echo "--> Creating secure static staging path on ${CONTROL_PLANE_NODE}..."
# mkdir -m 700 applies strict 700 permissions creating a secure folder
ssh -n -o BatchMode=yes "${CONTROL_PLANE_NODE}" "mkdir -m 700 -p '${STAGING_DIR}'"
scp -o BatchMode=yes "${REPO_ROOT}/infrastructure/nodes/control-plane-config.yaml" "${CONTROL_PLANE_NODE}:${STAGING_DIR}/config.yaml"
ssh -n -o BatchMode=yes "${CONTROL_PLANE_NODE}" "sudo /usr/local/bin/apply-k3s-node-config.sh '${STAGING_DIR}/config.yaml'"

wait_for_condition 12 5 "K3s control plane to be ready" ssh -n -o BatchMode=yes "${CONTROL_PLANE_NODE}" "sudo k3s kubectl get nodes | grep -qw 'Ready'"

echo "=== Extracting K3s Token ==="
# Fetch the token dynamically and export it to memory for the template renderer
K3S_TOKEN=$(ssh -n -o BatchMode=yes "${CONTROL_PLANE_NODE}" "sudo cat /var/lib/rancher/k3s/server/node-token")
export K3S_TOKEN
echo "Token extracted successfully."

echo ""
echo "=== Deploying Worker Nodes ==="
for node in "${!WORKER_NODES[@]}"; do
    export WORKER_IP="${WORKER_NODES[$node]}"

    echo "--> Rendering template and updating ${node} (worker node)..."
    # shellcheck disable=SC2016
    # Use envsubst to populate the YAML template with our active memory variables
    envsubst '$CONTROL_PLANE_IP $K3S_TOKEN $WORKER_IP $INTERFACE' \
        < "${REPO_ROOT}/core/k3s-config/worker-config.yaml.template" \
        > "${SECURE_TMP_DIR}/${node}-config.yaml"

    echo "--> Creating secure static staging path on ${node}..."
    # mktemp -d automatically applies strict 700 permissions on Linux
    ssh -n -o BatchMode=yes "${node}" "mkdir -m 700 -p '${STAGING_DIR}'"
    scp -o BatchMode=yes "${SECURE_TMP_DIR}/${node}-config.yaml" "${node}:${STAGING_DIR}/config.yaml"
    ssh -n -o BatchMode=yes "${node}" "sudo /usr/local/bin/apply-k3s-node-config.sh '${STAGING_DIR}/config.yaml'"

done

echo ""
echo "=== Node Bootstrap Complete ==="
echo "Verifying all registered nodes are Ready..."

# Loop through every node in the associative array
for target_node in "${CLUSTER_NODES[@]}"; do
    wait_for_condition 15 4 "Node ${target_node} to report as Ready" \
        ssh -n -o BatchMode=yes "${CONTROL_PLANE_NODE}" "sudo k3s kubectl get nodes | grep -E '^${target_node}[[:space:]]+Ready\b'"
done

echo ""
echo "Cluster is fully online. Final status and labels:"
ssh -n -o BatchMode=yes kc01 "sudo k3s kubectl get nodes --show-labels"



