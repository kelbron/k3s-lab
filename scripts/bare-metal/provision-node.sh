#!/usr/bin/env bash
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

# 1. Primary operational inputs from positional arguments
TARGET_USER="${1:-sysop}"
STAGING_DIR="${2:-/tmp}"

# 2. System path overrides (leveraged for test sandbox isolation)
K3S_CONFIG_DIR="${K3S_CONFIG_DIR:-/etc/rancher/k3s}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"
APT_KEYRINGS_DIR="${APT_KEYRINGS_DIR:-/etc/apt/keyrings}"
APT_SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"

# load OS identifierenvironment variables
# shellcheck source=/dev/null
source "/etc/os-release"

install_docker_packages() {
    # Any failing command inside here immediately aborts the function
    # and causes it to return a non-zero exit code to the caller.
    # https://docs.docker.com/engine/install/debian/
    # 'concatenating' the commands with '&&' ensures that if any command fails, the subsequent commands are not executed.
    apt-get update &&
    apt-get install -y ca-certificates curl &&

    install -m 0755 -d "${APT_KEYRINGS_DIR}" &&

    curl -fsSL https://download.docker.com/linux/debian/gpg -o "${APT_KEYRINGS_DIR}/docker.asc" &&
    chmod a+r "${APT_KEYRINGS_DIR}/docker.asc" &&

    tee "${APT_SOURCES_DIR}/docker.sources" >/dev/null <<EOF &&
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: ${APT_KEYRINGS_DIR}/docker.asc
EOF
    apt-get update &&
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# Install Docker Engine if not present
if ! command -v docker >/dev/null 2>&1; then
    echo "--> Docker not found. Installing native Docker Engine and OS Dependencies..."
    if install_docker_packages; then
        echo "--> Docker installation completed successfully."
    else
        exit_code=$?
        echo "❌ Error: Docker installation failed." >&2
        rm -f "${APT_SOURCES_DIR}/docker.sources"
        exit "${exit_code}"
    fi
else
    echo "--> Docker is already installed."
fi

systemctl enable --now docker
docker info >/dev/null        # if docker did not start, this will fail and exit the script

# Add target user to the docker group
usermod -aG docker "${TARGET_USER}"

echo "=== Provisioning Cluster Node OS Security & Helper Scripts ==="

# 1. Create the administrative group & assign user
groupadd -f k3s-admin
usermod -aG k3s-admin "${TARGET_USER}"

# 2. Atomically create/update configuration directory ownership and mode
install -d -m 0775 -o root -g k3s-admin "${K3S_CONFIG_DIR}"

# 3. Verify staging dependencies exist before copying
if [ ! -f "${STAGING_DIR}/apply-k3s-node-config.sh" ] || [ ! -f "${STAGING_DIR}/common-lib.sh" ]; then
    echo "❌ Error: Required deployment files not found in '${STAGING_DIR}'." >&2
    [ ! -f "${STAGING_DIR}/apply-k3s-node-config.sh" ] && echo "  - Missing: ${STAGING_DIR}/apply-k3s-node-config.sh" >&2
    [ ! -f "${STAGING_DIR}/common-lib.sh" ] && echo "  - Missing: ${STAGING_DIR}/common-lib.sh" >&2
    exit 1
fi

install -d -m 0755 "${BIN_DIR}"
install -m 0755 "${STAGING_DIR}/apply-k3s-node-config.sh" "${BIN_DIR}/apply-k3s-node-config.sh"
install -m 0644 "${STAGING_DIR}/common-lib.sh" "${BIN_DIR}/common-lib.sh"

# 4. Enforce Least-Privilege Sudoers Rule with atomic validation & installation
install -d -m 0755 "${SUDOERS_DIR}"
tmp_sudoers="$(mktemp "${STAGING_DIR}/sudoers-k3s-admin.XXXXXX")"
trap 'rm -f "${tmp_sudoers}"' EXIT

echo "${TARGET_USER} ALL=(ALL) NOPASSWD: ${BIN_DIR}/apply-k3s-node-config.sh" > "${tmp_sudoers}"


visudo -c -f "${tmp_sudoers}"
install -m 0440 "${tmp_sudoers}" "${SUDOERS_DIR}/k3s-admin-safe"

echo "=== Node Provisioning Complete ==="
