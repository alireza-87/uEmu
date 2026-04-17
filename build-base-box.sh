#!/usr/bin/env bash
# Build the one-time "builder" VM with all CPUs, then package its compiled
# state into a reusable Vagrant box so worker VMs can boot pre-built.
#
# Usage:
#   ./build-base-box.sh                 # uses all host CPUs
#   UEMU_VM_CPUS=16 ./build-base-box.sh # cap CPUs
#
# After it finishes, spawn workers with:
#   UEMU_ROLE=worker UEMU_VM_COUNT=21 UEMU_VM_CPUS=1 vagrant up

set -euo pipefail

BOX_NAME="${UEMU_BASE_BOX_NAME:-uemu-prebuilt}"
BOX_FILE="${UEMU_BASE_BOX_FILE:-uemu-prebuilt.box}"
VM_NAME="uemu"  # matches configure_worker's name when UEMU_VM_COUNT=1

export UEMU_ROLE=builder
export UEMU_VM_COUNT="${UEMU_VM_COUNT:-1}"

if [[ "$UEMU_VM_COUNT" != "1" ]]; then
    echo "[build-base-box] ERROR: UEMU_VM_COUNT must be 1 for builder." >&2
    exit 1
fi

echo "[build-base-box] Stage 1/4: bringing up builder VM (this compiles uEmu)..."
vagrant up --provider=virtualbox

echo "[build-base-box] Stage 2/4: halting builder VM..."
vagrant halt

if [[ -f "$BOX_FILE" ]]; then
    echo "[build-base-box] Removing stale $BOX_FILE"
    rm -f "$BOX_FILE"
fi

echo "[build-base-box] Stage 3/4: packaging $VM_NAME -> $BOX_FILE ..."
vagrant package --base "$VM_NAME" --output "$BOX_FILE"

if vagrant box list 2>/dev/null | awk '{print $1}' | grep -qx "$BOX_NAME"; then
    echo "[build-base-box] Removing previously registered box '$BOX_NAME'"
    vagrant box remove -f "$BOX_NAME"
fi

echo "[build-base-box] Stage 4/4: registering $BOX_FILE as '$BOX_NAME' ..."
vagrant box add "$BOX_NAME" "$BOX_FILE"

cat <<EOF

[build-base-box] Done.

Next steps:
  # Spawn 21 lightweight workers from the pre-built box:
  UEMU_ROLE=worker UEMU_VM_COUNT=21 UEMU_VM_CPUS=1 vagrant up

Optional: reclaim disk by destroying the builder VM (the packaged box stays):
  vagrant destroy -f
EOF
