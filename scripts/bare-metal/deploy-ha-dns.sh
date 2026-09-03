#!/usr/bin/env bash
set -euo pipefail

# Track all generated local temporary files for guaranteed cleanup on exit
declare -a WORKSTATION_TEMP_FILES=()

cleanup_temp_files() {
    if [ "${#WORKSTATION_TEMP_FILES[@]}" -gt 0 ]; then
        rm -f "${WORKSTATION_TEMP_FILES[@]}"
    fi
}

# Trap both standard exits and unexpected signal abortions
trap cleanup_temp_files EXIT
trap 'exit 1' INT TERM HUP

echo "=== Validating and Parsing HA Node Inventory ==="
declare -A HA_NODES

# Rebuild the associative array from the flat string in the node config environment variable
for record in $HA_NODES_CONFIG; do
    # Extract the three pieces of data separated by colons
    IFS=':' read -r node state priority <<< "$record"

    # Fail early if the string is malformed
    if [ -z "${node:-}" ] || [ -z "${state:-}" ] || [ -z "${priority:-}" ]; then
        echo "FAILED: Malformed HA node record '$record'. Expected format 'hostname:STATE:PRIORITY'."
        exit 1
    fi

    # Reconstruct the exact format your script originally used
    HA_NODES["$node"]="${state}:${priority}"
done

echo "=== Deploying High-Availability DNS (Keepalived + Pi-hole) ==="

for node in "${!HA_NODES[@]}"; do
    IFS=':' read -r state priority <<< "${HA_NODES[$node]}"
    echo "--> Provisioning ${node} as ${state} (Priority: ${priority})..."

    # 1. Install Keepalived on the host OS
    ssh -o BatchMode=yes "${node}" "sudo apt-get update && sudo apt-get install -y keepalived"

    # 2. Configure Keepalived for the Virtual IP (VIP)
    # ADR 011 Rule 3 Compliance: Stage config locally in a secure temp file first
    LOCAL_KEEPALIVED_CONF=$(mktemp)
    WORKSTATION_TEMP_FILES+=("$LOCAL_KEEPALIVED_CONF") # Register instantly

    cat <<EOF > "$LOCAL_KEEPALIVED_CONF"
vrrp_instance VI_CLUSTER_DNS {
    state ${state}
    interface ${INTERFACE}
    virtual_router_id 53
    priority ${priority}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass k3s_dns_ha
    }
    virtual_ipaddress {
        ${VIP}/24 dev ${INTERFACE}
    }
}
EOF

    # Copy the clean temp file to the target node's staging directory
    scp -o BatchMode=yes "$LOCAL_KEEPALIVED_CONF" "${node}:/tmp/keepalived.conf"

    # This could be removed as the cleanup_temp_files trap will trigger on exit
    rm -f "$LOCAL_KEEPALIVED_CONF"

    # Promote the configuration to its protected directory and secure permissions
    ssh -o BatchMode=yes "${node}" "sudo mkdir -p /etc/keepalived && sudo mv /tmp/keepalived.conf /etc/keepalived/keepalived.conf && sudo chmod 644 /etc/keepalived/keepalived.conf"


    # Restart and enable Keepalived
    ssh -o BatchMode=yes "${node}" "sudo systemctl restart keepalived && sudo systemctl enable keepalived"

    # 3. Deploy Standalone Pi-hole via Docker
    echo "    Spinning up Pi-hole container..."
    ssh -o BatchMode=yes "${node}" "sudo docker rm -f pihole || true"

    # We publish DNS (53) normally, but map the Web UI to 8053 so it doesn't conflict with Traefik Ingress
    ssh -o BatchMode=yes "${node}" "sudo docker run -d \\
        --name pihole \\
        --restart=unless-stopped \\
        -p 53:53/tcp -p 53:53/udp \\
        -p 8053:80/tcp \\
        -e TZ=\"America/Denver\" \\
        -e WEBPASSWORD=\"${PIHOLE_PW}\" \\
        -v /opt/pihole/etc-pihole:/etc/pihole \\
        -v /opt/pihole/etc-dnsmasq.d:/etc/dnsmasq.d \\
        pihole/pihole:latest >/dev/null"

    # 4. Inject Split-Horizon DNS configuration
    echo "    Applying Split-Horizon DNS rewrite for ${DOMAIN} -> ${VIP}..."
    # ADR 011 Rule 3 Compliance: Stage configuration locally
    LOCAL_PIHOLE_CONF=$(mktemp)
    WORKSTATION_TEMP_FILES+=("$LOCAL_PIHOLE_CONF") # Register instantly

    echo "address=/${DOMAIN}/${VIP}" > "$LOCAL_PIHOLE_CONF"

    # Copy safely to the remote unprivileged staging ground
    scp -o BatchMode=yes "$LOCAL_PIHOLE_CONF" "${node}:/tmp/99-k3s-cluster.conf"

    # This could be removed as the cleanup_temp_files trap will trigger on exit
    rm -f "$LOCAL_PIHOLE_CONF"

    # Promote with proper permissions and create directories if missing
    ssh -o BatchMode=yes "${node}" "sudo mkdir -p /opt/pihole/etc-dnsmasq.d \\
        && sudo mv /tmp/99-k3s-cluster.conf /opt/pihole/etc-dnsmasq.d/99-k3s-cluster.conf \\
        && sudo chmod 644 /opt/pihole/etc-dnsmasq.d/99-k3s-cluster.conf"

    # ADR 011 Rule 1 Compliance: Restart Pi-hole and allow stderr/stdout to flow cleanly
    ssh -o BatchMode=yes "${node}" "sudo docker restart pihole"

    echo "--> ${node} deployment successful."
    echo ""
done

echo "=== HA DNS Deployment Complete ==="
echo "Keepalived VIP: ${VIP} is now active."
echo "Pi-hole Web UIs accessible at: http://192.168.1.50:8053 and http://192.168.1.51:8053"
