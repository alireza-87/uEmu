#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
RUN_ROOT="${UEMU_VM_RUN_ROOT:-/home/vagrant/runs}"
HOST_NAME="$(hostname -s 2>/dev/null || hostname)"
RUN_DIR_DEFAULT="$RUN_ROOT/$HOST_NAME"
RUN_DIR=""

usage() {
    cat <<'EOF'
Usage:
  vm-uEmu.sh [--run-dir DIR] firmware config [uEmu-helper options...]

What it does:
  - sets uEmuDIR to the shared repo in /vagrant
  - generates launch/config files into a per-VM run directory
  - keeps s2e-last, AFL output, testcase, and relative KB files out of /vagrant

Defaults:
  run dir: /home/vagrant/runs/$HOSTNAME

Examples:
  ./vm-uEmu.sh firmware.bin uEmu.cfg
  ./vm-uEmu.sh firmware.bin uEmu.cfg -kb kb.txt
  ./vm-uEmu.sh --run-dir /tmp/my-run firmware.bin uEmu.cfg -kb kb.txt
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-dir)
            [[ $# -ge 2 ]] || { echo "missing value for --run-dir" >&2; exit 2; }
            RUN_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -lt 2 ]]; then
    usage >&2
    exit 2
fi

FIRMWARE="$1"
CONFIG="$2"
shift 2

RUN_DIR="${RUN_DIR:-$RUN_DIR_DEFAULT}"
mkdir -p "$RUN_DIR"

export uEmuDIR="${uEmuDIR:-$SCRIPT_DIR}"

python3 "$SCRIPT_DIR/uEmu-helper.py" "$FIRMWARE" "$CONFIG" -o "$RUN_DIR" "$@"

printf '\nRun directory: %s\n' "$RUN_DIR"
printf 'Start uEmu with: %s\n' "$RUN_DIR/launch-uEmu.sh"
if [[ -f "$RUN_DIR/launch-AFL.sh" ]]; then
    printf 'Start AFL with:  %s\n' "$RUN_DIR/launch-AFL.sh"
fi
