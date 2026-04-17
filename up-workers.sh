#!/usr/bin/env bash
# Spin up worker VMs from the pre-built `uemu-prebuilt` box.
#
# Usage:
#   ./up-workers.sh                      # prompts for count / cpus / memory
#   ./up-workers.sh 21                   # 21 workers, 1 CPU each (default)
#   ./up-workers.sh 21 2                 # 21 workers, 2 CPUs each
#   ./up-workers.sh 21 1 4096            # 21 workers, 1 CPU, 4096 MB each
#
# Requires the base box to already exist. If not, run ./build-base-box.sh first.

set -euo pipefail

BOX_NAME="${UEMU_BASE_BOX_NAME:-uemu-prebuilt}"

if ! vagrant box list 2>/dev/null | awk '{print $1}' | grep -qx "$BOX_NAME"; then
    echo "ERROR: base box '$BOX_NAME' is not registered." >&2
    echo "Run ./build-base-box.sh first to build and register it." >&2
    exit 1
fi

prompt_with_default() {
    local message="$1" default="$2" reply
    read -r -p "$message [$default]: " reply </dev/tty || reply=""
    echo "${reply:-$default}"
}

COUNT="${1:-}"
CPUS="${2:-}"
MEMORY="${3:-}"

if [[ -z "$COUNT" ]]; then
    COUNT=$(prompt_with_default "Number of worker VMs" "21")
fi
if [[ -z "$CPUS" ]]; then
    CPUS=$(prompt_with_default "vCPUs per VM" "1")
fi
if [[ -z "$MEMORY" ]]; then
    MEMORY=$(prompt_with_default "Memory (MB) per VM" "4096")
fi

if ! [[ "$COUNT"  =~ ^[0-9]+$ && "$COUNT"  -ge 1 ]]; then echo "Invalid count: $COUNT"   >&2; exit 1; fi
if ! [[ "$CPUS"   =~ ^[0-9]+$ && "$CPUS"   -ge 1 ]]; then echo "Invalid cpus: $CPUS"     >&2; exit 1; fi
if ! [[ "$MEMORY" =~ ^[0-9]+$ && "$MEMORY" -ge 512 ]]; then echo "Invalid memory: $MEMORY" >&2; exit 1; fi

export UEMU_ROLE=worker
export UEMU_VM_COUNT="$COUNT"
export UEMU_VM_CPUS="$CPUS"
export UEMU_VM_MEMORY="$MEMORY"

echo "[up-workers] Spawning $COUNT VM(s): ${CPUS} CPU, ${MEMORY} MB each, from box '$BOX_NAME'"
exec vagrant up --provider=virtualbox
