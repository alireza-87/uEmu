#!/bin/bash
# uEmu Docker entrypoint
# Supports KB extraction, fuzzing, and single testcase analysis.
#
# Usage:
#   docker run [docker-opts] uemu \
#       --elf   FIRMWARE.elf     (required, path inside /work)
#       --cfg   CONFIG.cfg       (required, path inside /work)
#       --kb    KB.dat           (optional – triggers fuzzing/analysis mode)
#       --seed  SEED_FILE        (optional – initial AFL seed; random 4 bytes if omitted)
#       --testcase  TC_FILE      (optional – single testcase; no AFL launched)
#       --workdir   /work        (optional – override mount point, default /work)
#       --debug                  (optional – verbose uEmu log)
#
# Multi-instance fuzzing example (bind each container to its own CPU set):
#   docker run --cpuset-cpus="0-3"  --device /dev/kvm  -v $(pwd)/run1:/work  uemu \
#       --elf firmware.elf --cfg firmware.cfg --kb firmware_KB.dat
#   docker run --cpuset-cpus="4-7"  --device /dev/kvm  -v $(pwd)/run2:/work  uemu \
#       --elf firmware.elf --cfg firmware.cfg --kb firmware_KB.dat
#
# NOTE: /dev/kvm is required (pass --device /dev/kvm to docker run).
# AFL system-tuning warnings can be silenced with:
#   -e AFL_SKIP_CPUFREQ=1  -e AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1

set -e

UEMU_TOOLS_DIR="${UEMU_TOOLS_DIR:-/uemu-tools}"
WORK_DIR="${WORK_DIR:-/work}"

# ── Argument parsing ──────────────────────────────────────────────────────────
ELF=""
CFG=""
KB=""
SEED=""
TESTCASE=""
DEBUG=""

usage() {
    grep '^#' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --elf|-e)       ELF="$2";       shift 2 ;;
        --cfg|-c)       CFG="$2";       shift 2 ;;
        --kb|-k)        KB="$2";        shift 2 ;;
        --seed|-s)      SEED="$2";      shift 2 ;;
        --testcase|-t)  TESTCASE="$2";  shift 2 ;;
        --workdir|-w)   WORK_DIR="$2";  shift 2 ;;
        --debug)        DEBUG="--debug"; shift  ;;
        -h|--help)      usage ;;
        *) echo "[entrypoint] Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$ELF" || -z "$CFG" ]]; then
    echo "[entrypoint] ERROR: --elf and --cfg are required."
    usage
fi

# ── Resolve paths relative to WORK_DIR ───────────────────────────────────────
# If user passes a bare filename we treat it as relative to /work.
abs_path() {
    local p="$1"
    [[ "$p" == /* ]] && echo "$p" || echo "$WORK_DIR/$p"
}

ELF_ABS="$(abs_path "$ELF")"
CFG_ABS="$(abs_path "$CFG")"
[[ -n "$KB"       ]] && KB_ABS="$(abs_path "$KB")"
[[ -n "$SEED"     ]] && SEED_ABS="$(abs_path "$SEED")"
[[ -n "$TESTCASE" ]] && TESTCASE_ABS="$(abs_path "$TESTCASE")"

# ── Validate inputs ───────────────────────────────────────────────────────────
[[ -f "$ELF_ABS" ]] || { echo "[entrypoint] ERROR: ELF not found: $ELF_ABS"; exit 1; }
[[ -f "$CFG_ABS" ]] || { echo "[entrypoint] ERROR: CFG not found: $CFG_ABS"; exit 1; }
[[ -n "$KB_ABS"       && ! -f "$KB_ABS"       ]] && { echo "[entrypoint] ERROR: KB not found: $KB_ABS";       exit 1; }
[[ -n "$SEED_ABS"     && ! -f "$SEED_ABS"     ]] && { echo "[entrypoint] ERROR: seed not found: $SEED_ABS";   exit 1; }
[[ -n "$TESTCASE_ABS" && ! -f "$TESTCASE_ABS" ]] && { echo "[entrypoint] ERROR: testcase not found: $TESTCASE_ABS"; exit 1; }

# ── Prepare working directory ─────────────────────────────────────────────────
cd "$WORK_DIR"

# uEmu-helper.py uses os.getcwd() to locate Jinja templates, so we copy them.
cp "$UEMU_TOOLS_DIR/launch-uEmu-template.sh"  .
cp "$UEMU_TOOLS_DIR/launch-AFL-template.sh"   .
cp "$UEMU_TOOLS_DIR/uEmu-config-template.lua" .
cp "$UEMU_TOOLS_DIR/library.lua"              .

# ── AFL system tuning (best-effort; host sysctl takes precedence) ─────────────
export AFL_SKIP_CPUFREQ="${AFL_SKIP_CPUFREQ:-1}"
export AFL_NO_AFFINITY="${AFL_NO_AFFINITY:-1}"
export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES="${AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES:-1}"
# S2E_MAX_PROCESSES is always 1 regardless of what the caller passes.
# Docker-level parallelism (one container per firmware) is the right model.
# Multi-process S2E inside a container degrades KB quality and causes premature
# fuzzer termination when the master node runs out of states.
export S2E_MAX_PROCESSES=1

# ── Build uEmu-helper.py argument list ───────────────────────────────────────
# firmware arg must be basename only — the helper embeds it into FUZZ_IN/OUT
# paths and the FIRMWARE variable. QEMU resolves it relative to /work (cwd).
# Config, KB, seed, testcase need absolute paths for the helper to find them.
HELPER_ARGS=("$(basename "$ELF_ABS")" "$CFG_ABS")
[[ -n "$KB_ABS"       ]] && HELPER_ARGS+=("-kb" "$KB_ABS")
[[ -n "$SEED_ABS"     ]] && HELPER_ARGS+=("-s"  "$(basename "$SEED_ABS")")
[[ -n "$TESTCASE_ABS" ]] && HELPER_ARGS+=("-t"  "$(basename "$TESTCASE_ABS")")
[[ -n "$DEBUG"        ]] && HELPER_ARGS+=("--debug")

echo "[entrypoint] Generating launch scripts..."
python3 "$UEMU_TOOLS_DIR/uEmu-helper.py" "${HELPER_ARGS[@]}"

# ── Launch ────────────────────────────────────────────────────────────────────
if [[ -n "$KB_ABS" && -z "$TESTCASE_ABS" ]]; then
    # Fuzzing mode: AFL feeds inputs, uEmu consumes them.
    echo "[entrypoint] Mode: FUZZING  (AFL + uEmu)"
    ./launch-AFL.sh &
    AFL_PID=$!
    trap 'kill "$AFL_PID" 2>/dev/null; wait "$AFL_PID" 2>/dev/null' EXIT
    ./launch-uEmu.sh
elif [[ -n "$TESTCASE_ABS" ]]; then
    # Single testcase analysis: uEmu only.
    echo "[entrypoint] Mode: TESTCASE ANALYSIS  (uEmu only)"
    ./launch-uEmu.sh
else
    # KB extraction: uEmu only.
    echo "[entrypoint] Mode: KB EXTRACTION  (uEmu only)"
    ./launch-uEmu.sh
fi
