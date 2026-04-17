#!/usr/bin/env bash
# Force-stop (and optionally delete) uEmu VirtualBox VMs.
#
# Usage:
#   ./kill-vms.sh                  # force-poweroff all workers (uemu-t*)
#   ./kill-vms.sh --all            # also poweroff the builder (uemu)
#   ./kill-vms.sh --destroy        # poweroff + unregister + delete disks (workers only)
#   ./kill-vms.sh --destroy --all  # nuke workers AND builder (keeps base box intact)
#
# This uses VBoxManage directly, so it works even when Vagrant's state file
# is out of sync with VirtualBox (e.g., after a crashed `vagrant up`).

set -uo pipefail

INCLUDE_BUILDER=0
DESTROY=0
for arg in "$@"; do
    case "$arg" in
        --all)     INCLUDE_BUILDER=1 ;;
        --destroy) DESTROY=1 ;;
        -h|--help)
            sed -n '2,11p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown flag: $arg" >&2
            exit 1
            ;;
    esac
done

# Build the list of VM names to act on.
if [[ "$INCLUDE_BUILDER" -eq 1 ]]; then
    PATTERN='^"(uemu|uemu-t[0-9]+)"'
else
    PATTERN='^"uemu-t[0-9]+"'
fi

mapfile -t VMS < <(VBoxManage list vms | grep -E "$PATTERN" | sed -E 's/^"([^"]+)".*/\1/')

if [[ "${#VMS[@]}" -eq 0 ]]; then
    echo "[kill-vms] No matching VMs found."
    exit 0
fi

echo "[kill-vms] Target VMs:"
printf '  - %s\n' "${VMS[@]}"

# Step 1: force poweroff anything that's running.
mapfile -t RUNNING < <(VBoxManage list runningvms | sed -E 's/^"([^"]+)".*/\1/')
for vm in "${VMS[@]}"; do
    if printf '%s\n' "${RUNNING[@]}" | grep -qx "$vm"; then
        echo "[kill-vms] Powering off: $vm"
        VBoxManage controlvm "$vm" poweroff >/dev/null 2>&1 || true
    fi
done

if [[ "$DESTROY" -eq 0 ]]; then
    echo "[kill-vms] Done (poweroff only). Use --destroy to also delete them."
    exit 0
fi

# Step 2: unregister + delete disks.
for vm in "${VMS[@]}"; do
    echo "[kill-vms] Deleting: $vm"
    VBoxManage unregistervm "$vm" --delete >/dev/null 2>&1 || \
        echo "  (already gone or failed to delete: $vm)"
done

# Step 3: clear Vagrant's state for the worker machines so the next
# `./up-workers.sh` run imports fresh.
if [[ -d .vagrant/machines ]]; then
    echo "[kill-vms] Clearing .vagrant/machines/t* state..."
    rm -rf .vagrant/machines/t[0-9]*
    if [[ "$INCLUDE_BUILDER" -eq 1 ]]; then
        rm -rf .vagrant/machines/default
    fi
fi

echo "[kill-vms] Done."
