#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# Create MicroOS snapshots for K3s on Hetzner Cloud
# Based on: https://github.com/KacperMalachowski/homelab/blob/main/packer/microos/hcloud/k3s.pkr.hcl
# =============================================================================

# ----- Configuration -----
HCLOUD_TOKEN="${HCLOUD_TOKEN:-}"
NAME_SUFFIX="${NAME_SUFFIX:-}"
ARCH="${ARCH:-x86}" # x86 | arm64

MICROOS_X86_URL="https://download.opensuse.org/tumbleweed/appliances/openSUSE-MicroOS.x86_64-ContainerHost-OpenStack-Cloud.qcow2"
MICROOS_ARM64_URL="https://download.opensuse.org/tumbleweed/appliances/openSUSE-MicroOS.aarch64-ContainerHost-OpenStack-Cloud.qcow2"

EXTRA_PACKAGES=()

NEEDED_PACKAGES=(
    restorecond
    policycoreutils
    policycoreutils-python-utils
    setools-console
    audit
    bind-utils
    wireguard-tools
    fuse
    open-iscsi
    nfs-client
    xfsprogs
    cryptsetup
    lvm2
    git
    cifs-utils
    bash-completion
    mtr
    tcpdump
    udica
    qemu-guest-agent
)

# ----- Validation -----

if [[ -z "$HCLOUD_TOKEN" ]]; then
    echo "Error: HCLOUD_TOKEN environment variable is not set."
    exit 1
fi

if [[ "$ARCH" != "x86" && "$ARCH" != "arm64" ]]; then
    echo "Error: ARCH environment variable must be either 'x86' or 'arm64'."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is required but not installed."
    exit 1
fi

# ----- Derived Values -----

if [[ "$ARCH" == "x86" ]]; then
    SERVER_TYPE="cx23"
    MICROOS_URL="$MICROOS_X86_URL"
    SNAPSHOT_NAME="microos-k3s-x86${NAME_SUFFIX:+-$NAME_SUFFIX}"
else
    SERVER_TYPE="cax11"
    MICROOS_URL="$MICROOS_ARM64_URL"
    SNAPSHOT_NAME="microos-k3s-arm64${NAME_SUFFIX:+-$NAME_SUFFIX}"
fi

PACKAGES_STR="${NEEDED_PACKAGES[*]} ${EXTRA_PACKAGES[*]}"

# ----- Helpers -----

hcloud_api() {
    local method="$1" path="$2"
    shift 2

    # Capture both body and HTTP status so we can show useful errors
    local response http_code body
    response=$(curl -sS -w '\n%{http_code}' -X "$method" \
        -H "Authorization: Bearer $HCLOUD_TOKEN" \
        -H "Content-Type: application/json" \
        "https://api.hetzner.cloud/v1/$path" \
        "$@" || true)

    http_code="${response##*$'\n'}"
    body="${response%$'\n'$http_code}"

    if [[ "$http_code" -ge 400 || "$http_code" -lt 200 ]]; then
        echo "Hetzner API error ($http_code) on $method $path:" >&2
        echo "$body" >&2
        exit 1
    fi

    echo "$body"
}

wait_for_action() {
    local action_id="$1"
    local timeout=$((10*60))
    local deadline=$(( $(date +%s) + timeout ))
    echo "Waiting for action $action_id to complete..."
    while true; do
        local status
        status=$(hcloud_api GET "actions/$action_id" | jq -r '.action.status')
        case "$status" in
            "success") echo "Action completed successfully."; break ;;
            "error") echo "Action failed."; exit 1 ;;
            *) sleep 5 ;;
        esac

        if [[ $(date +%s) -ge $deadline ]]; then
            echo "Error: Action did not complete within $((timeout / 60)) minutes."
            exit 1
        fi
    done
}

wait_for_ssh() {
    local ip="$1"
    echo "Waiting for SSH to become available at $ip..."
    local max_attempts=60
    local attempt=0

    until ssh -i "$TEMP_SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
        -o BatchMode=yes root@"$ip" true 2>/dev/null; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            echo "Error: SSH did not become available after $max_attempts attempts"
            exit 1
        fi
        sleep 5
    done
    echo "SSH is now available."
}

wait_for_ssh_down() {
    local ip="$1"
    echo "Waiting for SSH to go down at $ip..."
    local max_attempts=36
    local attempt=0

    while ssh -i "$TEMP_SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
        -o BatchMode=yes root@"$ip" true 2>/dev/null; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            echo "Error: SSH did not go down after reboot"
            exit 1
        fi
        sleep 5
    done

    echo "SSH is down."
}

wait_for_reboot_cycle() {
    local ip="$1"
    wait_for_ssh_down "$ip"
    wait_for_ssh "$ip"
}

run_remote() {
    local ip="$1" script="$2"
    ssh -i "$TEMP_SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=6 \
        root@"$ip" bash -s <<< "$script"
}

run_remote_disconnect_ok() {
    local ip="$1" script="$2"

    ssh -i "$TEMP_SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=6 \
        root@"$ip" bash -s <<< "$script"
    local rc=$?

    if [[ "$rc" -eq 0 ]]; then
        return 0
    fi

    # SSH exit code 255 means connection closed/reset - expected during reboot
    if [[ "$rc" -eq 255 ]]; then
        return 0
    fi

    return "$rc"
}

ensure_rescue_mode() {
    local ip="$1"
    echo "==> Verifying we are in Hetzner rescue environment..."
    run_remote "$ip" "
set -euo pipefail
ROOT_SRC=\$(findmnt -n -o SOURCE / || true)
echo Root filesystem source: \$ROOT_SRC
if [[ \$ROOT_SRC == /dev/sda* ]]; then
  echo 'Error: not in rescue mode (root on /dev/sda).' >&2
  cat /etc/os-release || true
  exit 1
fi
"
}

# ----- Main Logic -----

cleanup() {
    if [[ -n "${SERVER_ID:-}" ]]; then
        echo "==> Cleaning up server..."
        hcloud_api DELETE "servers/${SERVER_ID}" || echo "Warning: Failed to delete server"
    fi
    if [[ -n "${SSH_KEY_ID:-}" ]]; then
        echo "==> Cleaning up SSH key..."
        hcloud_api DELETE "ssh_keys/${SSH_KEY_ID}" || echo "Warning: Failed to delete SSH key"
    fi
    if [[ -n "${TEMP_SSH_KEY:-}" ]]; then
        rm -f "${TEMP_SSH_KEY}" "${TEMP_SSH_KEY}.pub" 2>/dev/null || true
    fi
}

trap cleanup EXIT

echo "==> [1/6] Creating temporary SSH key..."
TEMP_SSH_KEY="/tmp/temp-microos-${ARCH}-$(openssl rand -hex 6)"
ssh-keygen -t ed25519 -f "$TEMP_SSH_KEY" -N "" -C "temp-microos-${ARCH}-$$" >/dev/null
SSH_PUB_KEY=$(cat "${TEMP_SSH_KEY}.pub")

echo "==> [2/6] Uploading SSH key to Hetzner..."
SSH_KEY_RESPONSE=$(hcloud_api POST "ssh_keys" -d "{
    \"name\": \"temp-microos-${ARCH}-$$\",
    \"public_key\": \"${SSH_PUB_KEY}\"
}")
SSH_KEY_ID=$(echo "$SSH_KEY_RESPONSE" | jq -r '.ssh_key.id')
echo "SSH key ID: $SSH_KEY_ID"

echo "==> [3/6] Creating server ($SERVER_TYPE, $ARCH)..."
CREATE_RESPONSE=$(hcloud_api POST "servers" -d "{
    \"name\": \"temp-microos-${ARCH}-$$\",
    \"server_type\": \"$SERVER_TYPE\",
    \"image\": \"ubuntu-24.04\",
    \"location\": \"fsn1\",
    \"ssh_keys\": [${SSH_KEY_ID}],
    \"start_after_create\": false,
    \"public_net\": {
        \"enable_ipv4\": true,
        \"enable_ipv6\": false
    }
}")

SERVER_ID=$(echo "$CREATE_RESPONSE" | jq -r '.server.id')
SERVER_IP=$(echo "$CREATE_RESPONSE" | jq -r '.server.public_net.ipv4.ip')
ACTION_ID=$(echo "$CREATE_RESPONSE" | jq -r '.action.id')

echo "Server ID: $SERVER_ID"
echo "Server IP: $SERVER_IP"

wait_for_action "$ACTION_ID"

echo "==> [4/6] Enabling rescue mode (linux64)..."
RESCUE_RESPONSE=$(hcloud_api POST "servers/${SERVER_ID}/actions/enable_rescue" -d "{
    \"type\": \"linux64\",
    \"ssh_keys\": [${SSH_KEY_ID}]
}")
RESCUE_ACTION_ID=$(echo "$RESCUE_RESPONSE" | jq -r '.action.id')
wait_for_action "$RESCUE_ACTION_ID"

echo "==> Powering on server into rescue system..."
POWERON_RESPONSE=$(hcloud_api POST "servers/${SERVER_ID}/actions/poweron")
POWERON_ACTION_ID=$(echo "$POWERON_RESPONSE" | jq -r '.action.id')
wait_for_action "$POWERON_ACTION_ID"

wait_for_ssh "$SERVER_IP"
ensure_rescue_mode "$SERVER_IP"

echo "==> [4/6] Downloading and writing MicroOS image..."
echo "==> Disabling rescue mode for next boot..."
DISABLE_RESCUE_RESPONSE=$(hcloud_api POST "servers/${SERVER_ID}/actions/disable_rescue")
DISABLE_RESCUE_ACTION_ID=$(echo "$DISABLE_RESCUE_RESPONSE" | jq -r '.action.id')
wait_for_action "$DISABLE_RESCUE_ACTION_ID"

run_remote_disconnect_ok "$SERVER_IP" "
set -ex
echo 'Downloading MicroOS image...'
wget --timeout=5 --waitretry=5 --tries=5 --retry-connrefused --inet4-only '$MICROOS_URL'

echo 'Installing qemu-utils...'
apt-get update -qq
apt-get install -y -qq qemu-utils

echo 'Validating rescue environment...'
ROOT_SRC=\$(findmnt -n -o SOURCE / || true)
echo Root filesystem source: \$ROOT_SRC
if [[ \$ROOT_SRC == /dev/sda* ]]; then
  echo 'Error: root filesystem is on /dev/sda; refusing to overwrite disk outside rescue mode.' >&2
  cat /etc/os-release || true
  exit 1
fi

echo 'Converting and writing image to disk...'
qemu-img convert -p -t directsync -f qcow2 -O host_device \$(ls -1 | grep -E '^openSUSE.*MicroOS.*\.qcow2$') /dev/sda

echo 'Done. Rebooting into MicroOS...'
sleep 1 && udevadm settle && reboot
"

echo "Waiting for reboot to complete..."
wait_for_reboot_cycle "$SERVER_IP"

echo "==> [5/6] Installing packages and K3s SELinux..."
run_remote_disconnect_ok "$SERVER_IP" "
set -ex

if ! command -v transactional-update >/dev/null 2>&1; then
  echo 'Error: transactional-update not found; host may still be in rescue mode.' >&2
  cat /etc/os-release || true
  exit 1
fi

echo 'Installing packages via transactional-update...'
transactional-update --continue pkg install -y $PACKAGES_STR

transactional-update --continue shell <<'TRANSACTIONAL_EOF'
set -ex
setenforce 0
rpm --import https://rpm.rancher.io/public.key
zypper install -y https://github.com/k3s-io/k3s-selinux/releases/download/v1.6.stable.1/k3s-selinux-1.6-1.sle.noarch.rpm
zypper addlock k3s-selinux
restorecon -Rv /etc/selinux/targeted/policy
restorecon -Rv /var/lib
setenforce 1
TRANSACTIONAL_EOF

echo 'Packages installed. Rebooting...'
sleep 1
udevadm settle
reboot
"

echo "Waiting for reboot to complete..."
wait_for_reboot_cycle "$SERVER_IP"

echo "==> [6/6] Cleaning up and creating snapshot..."
run_remote "$SERVER_IP" "
set -ex
echo 'Cleaning up SSH host keys...'
rm -rf /etc/ssh/ssh_host_*

echo 'Ensuring NetworkManager is configured...'
mkdir -p /etc/NetworkManager
touch /etc/NetworkManager/NetworkManager.conf

udevadm settle
echo 'Cleanup complete.'
"

echo "Creating snapshot: $SNAPSHOT_NAME..."
SNAPSHOT_RESPONSE=$(hcloud_api POST "servers/${SERVER_ID}/actions/create_image" -d "{
    \"description\": \"${SNAPSHOT_NAME}\",
    \"type\": \"snapshot\",
    \"labels\": {
        \"arch\": \"${ARCH}\",
        \"os\": \"microos\",
        \"k3s\": \"true\",
        \"microos-snapshot\": \"yes\"
    }
}")

SNAPSHOT_ACTION_ID=$(echo "$SNAPSHOT_RESPONSE" | jq -r '.action.id')
wait_for_action "$SNAPSHOT_ACTION_ID"

SNAPSHOT_ID=$(echo "$SNAPSHOT_RESPONSE" | jq -r '.image.id')
echo ""
echo "=========================================="
echo "SUCCESS!"
echo "=========================================="
echo "Snapshot created: $SNAPSHOT_NAME"
echo "Snapshot ID: $SNAPSHOT_ID"
echo "Arch: $ARCH"
echo "=========================================="

# Cleanup trap will delete the server
