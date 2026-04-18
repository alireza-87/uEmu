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
#       --run-dir  /work/run     (optional – generated files and runtime output)
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
RUN_DIR="${UEMU_RUN_DIR:-}"
UEMU_RUNTIME_LIB_PATH="${UEMU_RUNTIME_LIB_PATH:-/uemu/build/opt/lib}"
UEMU_FUZZ_MAX_RESTARTS="${UEMU_FUZZ_MAX_RESTARTS:-10}"
UEMU_FUZZ_RESTART_DELAY_SECS="${UEMU_FUZZ_RESTART_DELAY_SECS:-2}"
UEMU_FUZZ_QUICK_FAILURE_SECS="${UEMU_FUZZ_QUICK_FAILURE_SECS:-15}"
UEMU_FUZZ_MAX_QUICK_FAILURES="${UEMU_FUZZ_MAX_QUICK_FAILURES:-3}"
AFL_PID=""

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

cleanup() {
    local status=$?

    if [[ -n "$AFL_PID" ]] && kill -0 "$AFL_PID" 2>/dev/null; then
        kill "$AFL_PID" 2>/dev/null || true
        wait "$AFL_PID" 2>/dev/null || true
    fi

    return "$status"
}

run_uemu_supervised() {
    local restart_count=0
    local quick_failures=0

    while true; do
        local started_at status runtime

        if ! kill -0 "$AFL_PID" 2>/dev/null; then
            wait "$AFL_PID"
            return $?
        fi

        started_at="$(date +%s)"
        set +e
        "$RUN_DIR_ABS/launch-uEmu.sh"
        status=$?
        set -e
        runtime=$(( $(date +%s) - started_at ))

        if ! kill -0 "$AFL_PID" 2>/dev/null; then
            wait "$AFL_PID" 2>/dev/null || true
            return "$status"
        fi

        restart_count=$((restart_count + 1))
        if (( runtime < UEMU_FUZZ_QUICK_FAILURE_SECS )); then
            quick_failures=$((quick_failures + 1))
        else
            quick_failures=0
        fi

        echo "[entrypoint] uEmu exited with status ${status} after ${runtime}s; restarting (${restart_count}/${UEMU_FUZZ_MAX_RESTARTS}, quick failures ${quick_failures}/${UEMU_FUZZ_MAX_QUICK_FAILURES})"

        if (( restart_count > UEMU_FUZZ_MAX_RESTARTS )); then
            echo "[entrypoint] Restart limit reached; stopping container."
            return "$status"
        fi

        if (( quick_failures > UEMU_FUZZ_MAX_QUICK_FAILURES )); then
            echo "[entrypoint] Too many quick uEmu failures; stopping container."
            return "$status"
        fi

        sleep "$UEMU_FUZZ_RESTART_DELAY_SECS"
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --elf|-e)       ELF="$2";       shift 2 ;;
        --cfg|-c)       CFG="$2";       shift 2 ;;
        --kb|-k)        KB="$2";        shift 2 ;;
        --seed|-s)      SEED="$2";      shift 2 ;;
        --testcase|-t)  TESTCASE="$2";  shift 2 ;;
        --workdir|-w)   WORK_DIR="$2";  shift 2 ;;
        --run-dir|-r)   RUN_DIR="$2";   shift 2 ;;
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
if [[ -n "$RUN_DIR" ]]; then
    RUN_DIR_ABS="$(abs_path "$RUN_DIR")"
else
    RUN_DIR_ABS="$WORK_DIR/run"
fi

# ── Validate inputs ───────────────────────────────────────────────────────────
[[ -f "$ELF_ABS" ]] || { echo "[entrypoint] ERROR: ELF not found: $ELF_ABS"; exit 1; }
[[ -f "$CFG_ABS" ]] || { echo "[entrypoint] ERROR: CFG not found: $CFG_ABS"; exit 1; }
[[ -n "$KB_ABS"       && ! -f "$KB_ABS"       ]] && { echo "[entrypoint] ERROR: KB not found: $KB_ABS";       exit 1; }
[[ -n "$SEED_ABS"     && ! -f "$SEED_ABS"     ]] && { echo "[entrypoint] ERROR: seed not found: $SEED_ABS";   exit 1; }
[[ -n "$TESTCASE_ABS" && ! -f "$TESTCASE_ABS" ]] && { echo "[entrypoint] ERROR: testcase not found: $TESTCASE_ABS"; exit 1; }

# ── Prepare working directory ─────────────────────────────────────────────────
mkdir -p "$WORK_DIR"
mkdir -p "$RUN_DIR_ABS"
cd "$WORK_DIR"

# ── AFL system tuning (best-effort; host sysctl takes precedence) ─────────────
export AFL_SKIP_CPUFREQ="${AFL_SKIP_CPUFREQ:-1}"
export AFL_NO_AFFINITY="${AFL_NO_AFFINITY:-1}"
export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES="${AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES:-1}"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$UEMU_RUNTIME_LIB_PATH"
# S2E_MAX_PROCESSES is always 1 regardless of what the caller passes.
# Docker-level parallelism (one container per firmware) is the right model.
# Multi-process S2E inside a container degrades KB quality and causes premature
# fuzzer termination when the master node runs out of states.
export S2E_MAX_PROCESSES=1

# ── Build uEmu-helper.py argument list ───────────────────────────────────────
# Firmware, config, KB, seed, testcase are passed as absolute paths so the
# generated run directory can live anywhere under /work without path breakage.
HELPER_ARGS=("$ELF_ABS" "$CFG_ABS" "-o" "$RUN_DIR_ABS")
[[ -n "$KB_ABS"       ]] && HELPER_ARGS+=("-kb" "$KB_ABS")
[[ -n "$SEED_ABS"     ]] && HELPER_ARGS+=("-s"  "$SEED_ABS")
[[ -n "$TESTCASE_ABS" ]] && HELPER_ARGS+=("-t"  "$TESTCASE_ABS")
[[ -n "$DEBUG"        ]] && HELPER_ARGS+=("--debug")

echo "[entrypoint] Generating launch scripts..."
python3 "$UEMU_TOOLS_DIR/uEmu-helper.py" "${HELPER_ARGS[@]}"
echo "[entrypoint] Run directory: $RUN_DIR_ABS"

# ── Launch ────────────────────────────────────────────────────────────────────
if [[ -n "$KB_ABS" && -z "$TESTCASE_ABS" ]]; then
    # Fuzzing mode: AFL feeds inputs, uEmu consumes them.
    echo "[entrypoint] Mode: FUZZING  (AFL + uEmu)"
    trap cleanup EXIT
    trap 'exit 130' INT TERM
    "$RUN_DIR_ABS/launch-AFL.sh" &
    AFL_PID=$!
    run_uemu_supervised
elif [[ -n "$TESTCASE_ABS" ]]; then
    # Single testcase analysis: uEmu only.
    echo "[entrypoint] Mode: TESTCASE ANALYSIS  (uEmu only)"
    "$RUN_DIR_ABS/launch-uEmu.sh"
else
    # KB extraction: uEmu only.
    echo "[entrypoint] Mode: KB EXTRACTION  (uEmu only)"
    "$RUN_DIR_ABS/launch-uEmu.sh"
fi
