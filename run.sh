#!/bin/bash
# uEmu Docker launcher — interactive menu
set -e

DOCKER_IMAGE="${UEMU_IMAGE:-uemu}"
UEMU_RUNTIME_LIB_PATH="${UEMU_RUNTIME_LIB_PATH:-/uemu/build/opt/lib}"
UEMU_HELPER_DIR="$(dirname "$(realpath "$0")")"

# ── helpers ───────────────────────────────────────────────────────────────────
red()   { echo -e "\033[1;31m$*\033[0m"; }
green() { echo -e "\033[1;32m$*\033[0m"; }
cyan()  { echo -e "\033[1;36m$*\033[0m"; }
bold()  { echo -e "\033[1m$*\033[0m"; }

ask() {
    # ask <var_name> <prompt> [default]
    local var="$1" prompt="$2" default="$3" val
    while true; do
        [[ -n "$default" ]] && echo -n "$prompt [$default]: " || echo -n "$prompt: "
        read -r val
        val="${val:-$default}"
        [[ -n "$val" ]] && { printf -v "$var" '%s' "$val"; return; }
        red "  Value required."
    done
}

ask_optional() {
    local var="$1" prompt="$2"
    echo -n "$prompt [leave blank to skip]: "
    read -r val
    printf -v "$var" '%s' "$val"
}

ask_file_in_dir() {
    # ask_file_in_dir <var_name> <dir> <glob> <label>
    local var="$1" dir="$2" glob="$3" label="$4"
    local -a found
    mapfile -t found < <(find "$dir" -maxdepth 1 -name "$glob" 2>/dev/null | sort)
    if [[ ${#found[@]} -eq 1 ]]; then
        printf -v "$var" '%s' "$(basename "${found[0]}")"
        echo "  Auto-detected $label: $(basename "${found[0]}")"
    elif [[ ${#found[@]} -gt 1 ]]; then
        echo "  Multiple ${label}s found:"
        for i in "${!found[@]}"; do
            echo "    $((i+1))) $(basename "${found[$i]}")"
        done
        local choice
        ask choice "  Pick number" "1"
        printf -v "$var" '%s' "$(basename "${found[$((choice-1))]}")"
    else
        red "  No $glob file found in $dir."
        local fname
        ask fname "  Enter $label filename manually"
        printf -v "$var" '%s' "$fname"
    fi
}

ask_file_recursive() {
    # ask_file_recursive <var_name> <dir> <glob> <label>
    local var="$1" dir="$2" glob="$3" label="$4"
    local -a found
    mapfile -t found < <(find "$dir" -name "$glob" 2>/dev/null | sort)
    if [[ ${#found[@]} -eq 1 ]]; then
        printf -v "$var" '%s' "$(realpath --relative-to="$dir" "${found[0]}")"
        echo "  Auto-detected $label: $(realpath --relative-to="$dir" "${found[0]}")"
    elif [[ ${#found[@]} -gt 1 ]]; then
        echo "  Multiple ${label}s found:"
        for i in "${!found[@]}"; do
            echo "    $((i+1))) $(realpath --relative-to="$dir" "${found[$i]}")"
        done
        local choice
        ask choice "  Pick number" "1"
        printf -v "$var" '%s' "$(realpath --relative-to="$dir" "${found[$((choice-1))]}")"
    else
        red "  No $glob file found under $dir."
        local fname
        ask fname "  Enter $label filename manually"
        printf -v "$var" '%s' "$fname"
    fi
}

check_kvm() {
    [[ -e /dev/kvm ]] || { red "WARNING: /dev/kvm not found — KVM will not be available."; }
}

build_core_flag() {
    # build_core_flag <var> <start_core> <num_cores>
    local var="$1" start="$2" count="$3"
    local end=$(( start + count - 1 ))
    printf -v "$var" '%s' "${start}-${end}"
}

run_container() {
    local cpuset="$1" workdir="$2" extra_args="$3"
    local cmd="docker run --rm -it"
    [[ -e /dev/kvm ]] && cmd+=" --device /dev/kvm"
    [[ -n "$cpuset" ]] && cmd+=" --cpuset-cpus=\"$cpuset\""
    cmd+=" --user \"$(id -u):$(id -g)\""
    cmd+=" -e \"LD_LIBRARY_PATH=$UEMU_RUNTIME_LIB_PATH\""
    cmd+=" -v \"$(realpath "$workdir"):/work\""
    cmd+=" -v \"$UEMU_HELPER_DIR/docker-entrypoint.sh:/usr/local/bin/docker-entrypoint.sh:ro\""
    cmd+=" -v \"$UEMU_HELPER_DIR/uEmu-helper.py:/uemu-tools/uEmu-helper.py:ro\""
    cmd+=" -v \"$UEMU_HELPER_DIR/launch-uEmu-template.sh:/uemu-tools/launch-uEmu-template.sh:ro\""
    cmd+=" -v \"$UEMU_HELPER_DIR/launch-AFL-template.sh:/uemu-tools/launch-AFL-template.sh:ro\""
    cmd+=" -v \"$UEMU_HELPER_DIR/uEmu-config-template.lua:/uemu-tools/uEmu-config-template.lua:ro\""
    cmd+=" -v \"$UEMU_HELPER_DIR/library.lua:/uemu-tools/library.lua:ro\""
    cmd+=" $DOCKER_IMAGE"
    cmd+=" $extra_args"
    echo
    cyan "Running: $cmd"
    echo
    eval "$cmd"
}

get_common_inputs() {
    # Sets: WORK_DIR, ELF_FILE, CFG_FILE, CORES
    ask WORK_DIR "Work directory (contains .elf and .cfg)"
    [[ -d "$WORK_DIR" ]] || { red "Directory not found: $WORK_DIR"; exit 1; }

    ask_file_in_dir ELF_FILE "$WORK_DIR" "*.elf" "ELF firmware"
    ask_file_in_dir CFG_FILE "$WORK_DIR" "*.cfg" "config file"

    ask CORES "Number of CPU cores to allocate" "4"
    ask START_CORE "Starting CPU core index" "0"
    build_core_flag CPUSET "$START_CORE" "$CORES"
}

# ── menu ──────────────────────────────────────────────────────────────────────
print_menu() {
    echo
    bold "╔══════════════════════════════════╗"
    bold "║         uEmu Docker Runner       ║"
    bold "╠══════════════════════════════════╣"
    echo  "║  1) KB Extraction                ║"
    echo  "║  2) Fuzzing                      ║"
    echo  "║  3) Single Testcase Analysis     ║"
    echo  "║  4) Multi-Firmware Parallel Fuzz ║"
    echo  "║  5) Clean Output Subdirs         ║"
    bold "╚══════════════════════════════════╝"
    echo
}

# ── mode 1: KB extraction ─────────────────────────────────────────────────────
mode_kb_extraction() {
    cyan "\n── KB Extraction ──"
    get_common_inputs

    local debug_flag=""
    echo -n "  Enable debug mode? (y/N): "
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] && debug_flag="--debug"

    local args="--elf $ELF_FILE --cfg $CFG_FILE $debug_flag"
    check_kvm
    run_container "$CPUSET" "$WORK_DIR" "$args"
}

# ── mode 2: fuzzing ───────────────────────────────────────────────────────────
mode_fuzzing() {
    cyan "\n── Fuzzing ──"
    get_common_inputs

    ask_file_recursive KB_FILE "$WORK_DIR" "*_KB.dat" "KB file"

    local seed_flag=""
    ask_optional SEED_FILE "Seed file (inside work dir)"
    [[ -n "$SEED_FILE" ]] && seed_flag="--seed $SEED_FILE"

    local args="--elf $ELF_FILE --cfg $CFG_FILE --kb $KB_FILE $seed_flag"
    check_kvm
    run_container "$CPUSET" "$WORK_DIR" "$args"
}

# ── mode 3: single testcase analysis ─────────────────────────────────────────
mode_testcase() {
    cyan "\n── Single Testcase Analysis ──"
    get_common_inputs

    ask_file_recursive KB_FILE "$WORK_DIR" "*_KB.dat" "KB file"
    ask_file_recursive TC_FILE "$WORK_DIR" "*" "testcase file"

    local args="--elf $ELF_FILE --cfg $CFG_FILE --kb $KB_FILE --testcase $TC_FILE"
    check_kvm
    run_container "$CPUSET" "$WORK_DIR" "$args"
}

# ── mode 4: multi-firmware parallel KB + fuzz ────────────────────────────────
# Scans input dir for ELF+CFG pairs, creates a subdir per firmware,
# runs KB extraction then fuzzer for each — all in parallel with cores divided.
mode_multi_firmware() {
    cyan "\n── Multi-Firmware Parallel KB + Fuzz ──"

    ask INPUT_DIR "Input directory containing .elf and .cfg files"
    [[ -d "$INPUT_DIR" ]] || { red "Directory not found: $INPUT_DIR"; exit 1; }

    # Collect ELF files and match with CFG by same basename
    local -a elfs=()
    local -a cfgs=()
    local -a names=()
    while IFS= read -r elf; do
        local name
        name="$(basename "$elf" .elf)"
        local cfg="$INPUT_DIR/${name}.cfg"
        if [[ -f "$cfg" ]]; then
            elfs+=("$(basename "$elf")")
            cfgs+=("${name}.cfg")
            names+=("$name")
        else
            red "  WARNING: no matching .cfg for $elf — skipping"
        fi
    done < <(find "$INPUT_DIR" -maxdepth 1 -name "*.elf" | sort)

    local count=${#names[@]}
    if [[ $count -eq 0 ]]; then
        red "No matched ELF+CFG pairs found in $INPUT_DIR"
        exit 1
    fi

    echo
    green "  Found $count firmware pair(s):"
    for n in "${names[@]}"; do echo "    • $n"; done
    echo

    ask TOTAL_CORES "Total CPU cores to divide between all instances" "$(nproc)"
    ask START_CORE  "Starting CPU core index" "0"

    local cores_each=$(( TOTAL_CORES / count ))
    if [[ $cores_each -lt 1 ]]; then
        red "Not enough cores ($TOTAL_CORES) for $count firmwares. Need at least $count."
        exit 1
    fi
    green "  → $cores_each core(s) per firmware (${count} × ${cores_each}, starting at core ${START_CORE})"

    ask_optional SEED_FILE "Optional seed file (same for all, filename inside each subdir)"

    check_kvm
    echo

    # Per-firmware pipeline: KB extraction (blocking) → fuzzer (detached)
    fw_pipeline() {
        # Disable set -e inside pipeline — uEmu exits non-zero on shutdown
        # even when KB extraction succeeds (LLVM stream flush). We use the
        # presence of the KB file as the real success criterion.
        set +e

        local idx="$1" elf="$2" cfg="$3" name="$4"
        local start=$(( START_CORE + idx * cores_each ))
        local cpuset="${start}-$(( start + cores_each - 1 ))"
        local subdir
        subdir="$(realpath "$INPUT_DIR")/${name}"

        mkdir -p "$subdir"
        cp -n "$(realpath "$INPUT_DIR")/$elf" "$subdir/" 2>/dev/null || true
        cp -n "$(realpath "$INPUT_DIR")/$cfg" "$subdir/" 2>/dev/null || true
        [[ -n "$SEED_FILE" && -f "$(realpath "$INPUT_DIR")/$SEED_FILE" ]] && \
            cp -n "$(realpath "$INPUT_DIR")/$SEED_FILE" "$subdir/" 2>/dev/null || true

        local kvm_flag=""
        [[ -e /dev/kvm ]] && kvm_flag="--device /dev/kvm"

        # ── Step 1: KB extraction (foreground, wait for completion) ──
        echo "[${name}] Starting KB extraction  cores=${cpuset}  S2E_MAX_PROCESSES=${cores_each}"
        docker run --rm \
            $kvm_flag \
            --cpuset-cpus="$cpuset" \
            --user "$(id -u):$(id -g)" \
            --name "uemu_kb_${name}" \
            -e LD_LIBRARY_PATH="$UEMU_RUNTIME_LIB_PATH" \
            -e S2E_MAX_PROCESSES="$cores_each" \
            -v "${subdir}:/work" \
            -v "$UEMU_HELPER_DIR/docker-entrypoint.sh:/usr/local/bin/docker-entrypoint.sh:ro" \
            -v "$UEMU_HELPER_DIR/uEmu-helper.py:/uemu-tools/uEmu-helper.py:ro" \
            -v "$UEMU_HELPER_DIR/launch-uEmu-template.sh:/uemu-tools/launch-uEmu-template.sh:ro" \
            -v "$UEMU_HELPER_DIR/launch-AFL-template.sh:/uemu-tools/launch-AFL-template.sh:ro" \
            -v "$UEMU_HELPER_DIR/uEmu-config-template.lua:/uemu-tools/uEmu-config-template.lua:ro" \
            -v "$UEMU_HELPER_DIR/library.lua:/uemu-tools/library.lua:ro" \
            "$DOCKER_IMAGE" \
            --elf "$elf" --cfg "$cfg"
        echo "[${name}] KB extraction finished (exit $?)"

        # ── Step 2: find generated KB file (success criterion) ──
        local kb_file
        kb_file="$(find "$subdir" -name "*_KB.dat" 2>/dev/null | sort | tail -1)"
        if [[ -z "$kb_file" ]]; then
            red "[${name}] ERROR: no KB file found after extraction — skipping fuzz"
            return 1
        fi
        green "[${name}] Found KB: $kb_file"
        # Copy KB to work dir root so the fuzzer container can find it at /work/
        cp "$kb_file" "$subdir/"
        kb_file="$(basename "$kb_file")"

        # ── Step 3: clean stale AFL output so afl-fuzz doesn't refuse to start ──
        rm -rf "$subdir/run/AFL"

        # ── Step 4: start fuzzer (detached) ──
        local seed_flag=""
        [[ -n "$SEED_FILE" ]] && seed_flag="--seed $SEED_FILE"

        echo "[${name}] Starting fuzzer  cores=${cpuset}  S2E_MAX_PROCESSES=${cores_each}"
        docker run --rm -d \
            $kvm_flag \
            --cpuset-cpus="$cpuset" \
            --user "$(id -u):$(id -g)" \
            --name "uemu_fuzz_${name}" \
            -e LD_LIBRARY_PATH="$UEMU_RUNTIME_LIB_PATH" \
            -e S2E_MAX_PROCESSES="$cores_each" \
            -v "${subdir}:/work" \
            -v "$UEMU_HELPER_DIR/docker-entrypoint.sh:/usr/local/bin/docker-entrypoint.sh:ro" \
            -v "$UEMU_HELPER_DIR/uEmu-helper.py:/uemu-tools/uEmu-helper.py:ro" \
            -v "$UEMU_HELPER_DIR/launch-uEmu-template.sh:/uemu-tools/launch-uEmu-template.sh:ro" \
            -v "$UEMU_HELPER_DIR/launch-AFL-template.sh:/uemu-tools/launch-AFL-template.sh:ro" \
            -v "$UEMU_HELPER_DIR/uEmu-config-template.lua:/uemu-tools/uEmu-config-template.lua:ro" \
            -v "$UEMU_HELPER_DIR/library.lua:/uemu-tools/library.lua:ro" \
            "$DOCKER_IMAGE" \
            --elf "$elf" --cfg "$cfg" --kb "$kb_file" $seed_flag
        green "[${name}] Fuzzer running as uemu_fuzz_${name}"
    }

    # Launch all pipelines in parallel
    local pids=()
    for (( i=0; i<count; i++ )); do
        fw_pipeline "$i" "${elfs[$i]}" "${cfgs[$i]}" "${names[$i]}" &
        pids+=($!)
    done

    # Wait for all KB extractions (fuzzers are detached)
    echo
    cyan "Waiting for all KB extractions to complete..."
    local failed=0
    for pid in "${pids[@]}"; do
        wait "$pid" || (( failed++ )) || true
    done

    echo
    if [[ $failed -eq 0 ]]; then
        green "All KB extractions done — fuzzers are running in background."
    else
        red "$failed pipeline(s) failed. Check output above."
    fi
    echo
    echo "  Logs:   docker logs uemu_fuzz_<name>"
    echo "  Stop:   docker stop uemu_fuzz_<name>"
    echo "  Output: ${INPUT_DIR}/<name>/"
}

# ── mode 5: clean output subdirs ─────────────────────────────────────────────
mode_clean() {
    cyan "\n── Clean Output Subdirs ──"

    ask CLEAN_DIR "Directory containing firmware subdirs to clean"
    [[ -d "$CLEAN_DIR" ]] || { red "Directory not found: $CLEAN_DIR"; exit 1; }

    # Find subdirs (not the input ELF/CFG files themselves)
    local -a subdirs=()
    while IFS= read -r d; do
        subdirs+=("$d")
    done < <(find "$CLEAN_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

    if [[ ${#subdirs[@]} -eq 0 ]]; then
        red "No subdirectories found in $CLEAN_DIR"
        exit 1
    fi

    echo
    green "  Found ${#subdirs[@]} subdir(s) to clean:"
    for d in "${subdirs[@]}"; do echo "    • $(basename "$d")"; done
    echo
    echo -n "  This will delete all generated files (s2e-out-*, AFL, launch scripts, KB files)."
    echo -n " Confirm? (y/N): "
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

    echo
    for subdir in "${subdirs[@]}"; do
        local name
        name="$(basename "$subdir")"
        # Stop any running containers for this firmware first
        docker stop "uemu_kb_${name}" "uemu_fuzz_${name}" 2>/dev/null || true
        sudo rm -rf "$subdir"
        green "  Cleaned: $name"
    done

    echo
    green "Done. Subdirs cleaned — ready for a fresh run."
}

# ── main ──────────────────────────────────────────────────────────────────────
print_menu
ask CHOICE "Select mode" "1"

case "$CHOICE" in
    1) mode_kb_extraction ;;
    2) mode_fuzzing ;;
    3) mode_testcase ;;
    4) mode_multi_firmware ;;
    5) mode_clean ;;
    *) red "Invalid choice: $CHOICE"; exit 1 ;;
esac
