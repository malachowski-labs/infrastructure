#!/usr/bin/env bash

set -euo pipefail

# --- Configuration ---
HCLOUD_TOKEN="${HCLOUD_TOKEN:-}"
KEEP_LAST="${KEEP_LAST:-2}" # how many snapshots per arch to keep

# --- Validation ---
if [[ -z "$HCLOUD_TOKEN" ]]; then
    echo "Error: HCLOUD_TOKEN environment variable is not set."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is required but not installed."
    exit 1
fi

# --- Helpers ---
hcloud_api() {
    local method="$1" path="$2"
    shift 2
    curl -sf -X "$method" \
        -H "Authorization: Bearer $HCLOUD_TOKEN" \
        -H "Content-Type: application/json" \
        "https://api.hetzner.cloud/v1/$path" \
        "$@"
}

# --- Main Logic ---
echo "==> [1/2] Fetching snapshots..."
SNAPSHOTS=$(hcloud_api GET "/images?type=snapshot&label_selector=microos-snapshot%3Dtrue&sort=created:desc")

TOTAL=$(echo "$SNAPSHOTS" | jq '.images | length')
echo "  Found ${TOTAL} snapshot(s) total."

if [[ "$TOTAL" -eq 0 ]]; then
    echo "  No snapshots to delete. Exiting."
    exit 0
fi

echo "==> [2/2] Deleting old snapshots..."
for ARCH in "x86" "arm64"; do
    echo "  --- arch=${ARCH} (keeping last ${KEEP_LAST}) ---"

    ARCH_SNAPSHOTS=$(echo "$SNAPSHOTS" | jq --arg arch "$ARCH" '
        [.images[] | select(.labels.arch == $arch)]
    ')

    ARCH_TOTAL=$(echo "$ARCH_SNAPSHOTS" | jq 'length')
    echo "    Found ${ARCH_TOTAL} snapshot(s) for arch=${ARCH}."

    if [[ "$ARCH_TOTAL" -le "$KEEP_LAST" ]]; then
        echo "    No snapshots to delete for arch=${ARCH}. Skipping."
        continue
    fi

    TO_DELETE=$(echo "$ARCH_SNAPSHOTS" | jq --argjson keep "$KEEP_LAST" '.[$keep:]')
    DELETE_COUNT=$(echo "$TO_DELETE" | jq 'length')

    echo "  Snapshots to keep:"
    echo "$ARCH_SNAPSHOTS" | jq --argjson keep "$KEEP_LAST" '
        .[:$keep] | "   [KEEP] id=\(.id) name=\(.description) created=\(.created)"
    '

    echo "  Snapshots to delete (${DELETE_COUNT}):"
    echo "$TO_DELETE" | jq '
        .[] | "   [DEL] id=\(.id) name=\(.description) created=\(.created)"
    '

    while IFS= read -r SNAP_ID; do
        echo "  Deleting snapshot ID=${SNAP_ID}..."
        hcloud_api DELETE "/images/${SNAP_ID}" && echo "    Deleted" || echo "  WARN: failed to delete snapshot ID=${SNAP_ID}" >&2
    done < <(echo "$TO_DELETE" | jq -r '.[].id')

    echo ""
done

echo "==> Done"
