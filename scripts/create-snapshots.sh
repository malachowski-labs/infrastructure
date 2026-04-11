#!/usr/bin/env bash

set -euo pipefail

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

# ----- Validation ----

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
    curl -sf -X "$method" \
        -H "Authorization: Bearer $HCLOUD_TOKEN" \
        -H "Content-Type: application/json" \
        "https://api.hetzner.cloud/v1/$path" \
        "$@"
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
            "success") echo "Action $action_id completed successfully."; break ;;
            "error") echo "Action $action_id failed."; exit 1 ;;
            *) echo "Action $action_id is still in progress..."; sleep 5 ;;
        esac

        if [[ $(date +%s) -ge $deadline ]]; then
            echo "Error: Action $action_id did not complete within $((timeout / 60)) minutes."
             exit 1
         fi
    done
}

wait_for_ssh() {
    local ip="$1"
    echo "Waiting for SSH to become available at $ip..."
    until ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
        -o BatchMode=yes root@"$ip" true 2>/dev/null; do
        sleep 5
    done
    echo "SSH is now available at $ip."
}

run_remote() {
    local ip="$1" script="$2"
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s <<< "$script"
}

run_remote_disconnect_ok() {
    local ip="$1" script="$2"
    local rc=0

    if ssh -o StrictHostKeyChecking=no root@"$ip" bash -s <<< "$script"; then
        return 0
    fi

    rc=$?
    if [[ "$rc" -eq 255 ]]; then
        return 0
    fi

    return "$rc"
}

# ----- Main Logic -----

# Cleanup function to ensure server deletion on exit
cleanup() {
    if [[ -n "${SERVER_ID:-}" ]]; then
        echo "==> Cleaning up server $SERVER_ID..."
        hcloud_api DELETE "servers/${SERVER_ID}" || echo "Warning: Failed to delete server $SERVER_ID"
    fi
}

echo "==> [1/7] Creating server ($SERVER_TYPE, ARCH=$ARCH, Rescue=linux64)..."
CREATE_RESPONSE=$(hcloud_api POST "servers" -d "{
    \"name\": \"temp-microos-${ARCH}-$$\",
    \"server_type\": \"$SERVER_TYPE\",
    \"image\": \"ubuntu-22.04\",
    \"location\": \"fsn1\",
    \"rescue\": \"linux64\",
    \"start_after_create\": true
}")

SERVER_ID=$(echo "$CREATE_RESPONSE" | jq -r '.server.id')
SERVER_IP=$(echo "$CREATE_RESPONSE" | jq -r '.server.public_net.ipv4.ip')
ACTION_ID=$(echo "$CREATE_RESPONSE" | jq -r '.action.id')

# Set up cleanup trap now that we have a SERVER_ID
trap cleanup EXIT

echo "Server ID: $SERVER_ID, IP: $SERVER_IP"
wait_for_action "$ACTION_ID"

wait_for_ssh "$SERVER_IP"

echo "==> [2/7] Downloading MicroOS image..."
run_remote "$SERVER_IP" "wget --timeout=5 --waitretry=5 --tries=5 --retry-connrefused --inet4-only ${MICROOS_URL}"

echo "==> [3/7] Writing image to disk (Expect disconnection)..."
# shellcheck disable=SC2016
run_remote_disconnect_ok "$SERVER_IP" 'set -ex
    echo "MicroOS image loaded, writing to disk..."
    qemu-img convert -p -f qcow2 -O host_device $(ls -a | grep -ie '"'"'^opensuse.*microos.*qcow2$'"'"') /dev/sda
    echo "Image written to disk, rebooting..."
    sleep 1 && udevadm settle && reboot
'

sleep 5
wait_for_ssh "$SERVER_IP"

echo "==> [4/7] Installing packages (expect disconnect)..."
run_remote_disconnect_ok "$SERVER_IP" "set -ex
transactional-update --continue pkg install -y ${PACKAGES_STR}
transactional-update --continue shell <<-EOF
    setenforce 0
    rpm --import https://rpm.rancher.io/public.key
    zypper install -y https://github.com/k3s-io/k3s-selinux/releases/download/v1.6.stable.1/k3s-selinux-1.6-1.sle.noarch.rpm
    zypper addlock k3s-selinux
    restorecon -Rv /etc/selinux/targeted/policy
    restorecon -Rv /var/lib
    setenforce 1
EOF
echo \"Packages installed, rebooting...\"
sleep 1 && udevadm settle && reboot
"

sleep 5
wait_for_ssh "$SERVER_IP"

echo "==> [5/7] Cleaning up..."
run_remote "$SERVER_IP" 'set -ex
    rm -rf /etc/ssh/ssh_host_*
    echo "Make sure to use Network Manager"
    touch /etc/NetworkManager/NetworkManager.conf
    sleep 1 && udevadm settle
'

echo "==> [6/7] Creating snapshot..."
SNAPSHOT_RESPONSE=$(hcloud_api POST "servers/${SERVER_ID}/actions/create_image" -d "{
    \"description\": \"${SNAPSHOT_NAME}\",
    \"type\": \"snapshot\",
    \"labels\": {
        \"arch\": \"${ARCH}\",
        \"os\": \"microos\",
        \"k3s\": \"true\",
        \"microos-snapshot\": \"true\"
    }
}")

SNAPSHOT_ACTION_ID=$(echo "$SNAPSHOT_RESPONSE" | jq -r '.action.id')
wait_for_action "$SNAPSHOT_ACTION_ID"

SNAPSHOT_ID=$(echo "$SNAPSHOT_RESPONSE" | jq -r '.image.id')
echo "Snapshot created: ID=$SNAPSHOT_ID, Name=$SNAPSHOT_NAME"

echo "==> [7/7] Cleaning up server..."
trap - EXIT  # Disable trap since we're cleaning up manually
hcloud_api DELETE "servers/${SERVER_ID}"

echo "==> Done. Snapshot '${SNAPSHOT_NAME}' (ID: ${SNAPSHOT_ID}) is ready for use."
