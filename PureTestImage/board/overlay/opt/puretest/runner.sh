#!/bin/bash
#
# runner.sh - PureTestImage test harness.
#
# Runs after boot (puretest.service on tty1). Mounts the FAT32 DATADISK
# partition, lists the test folders on it, compiles a chosen C++ test with
# g++ ON THIS MACHINE, times it with /usr/bin/time (package 'time') and
# reports real/user/sys seconds.
#
# DATADISK layout:
#   tests/<name>/              one folder per test
#        *.cpp, *.cc, *.cxx    sources (compiled together)
#        build.flags           optional: extra g++ flags, one line
#        run.args              optional: extra arguments passed to the binary
#        run.stdin             optional: file piped to the binary's stdin
#   AUTORUN                    optional: test name -> boot, run once, poweroff
#
# Results go to DATADISK/results/<machine>/<test>-<timestamp>/ and are
# summarized in DATADISK/results/summary.tsv (+ printed on the console).
#
set -u

# Save original standard descriptors for direct interactive terminal access
exec 3>&1 4>&2 5<&0

# Ensure logging to /tmp/puretest.log for troubleshooting
LOGFILE="/tmp/puretest.log"
exec > >(tee -a "$LOGFILE") 2>&1

DATADIR=/data
TESTSDIR="$DATADIR/tests"
RESULTSDIR="$DATADIR/results"
RUNS="${RUNS:-3}"            # number of timing repetitions
TIMEOUT="${TIMEOUT:-600}"    # seconds per run (busybox/coreutils timeout)
AO_LEVEL="${AO_LEVEL:-O2}"   # Default AO level: O0, O1, O2, O3, Ofast, Os, all
FLAGS="${FLAGS:--O2 -march=native}"
CURRENT_TEST_FLAGS=""
export TERM="${TERM:-linux}"

# ---------------------------------------------------------------- machine id
# Read raw DMI product name and sanitize against FAT32-illegal characters (/\:*?"<>|)
RAW_MACHINE=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
MACHINE=$(echo "$RAW_MACHINE" | tr -c 'a-zA-Z0-9._-' '_' | sed 's/^_//; s/_$//')
[ -z "$MACHINE" ] && MACHINE="unknown"

CPUS=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
CPU=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: *//' || echo unknown)
MEM=$(awk '/^MemTotal:/ {print int($2/1024)" MiB"}' /proc/meminfo 2>/dev/null || echo unknown)

log() { echo "[puretest] $*"; }

log "=========================================================="
log "PureTestImage Harness Starting"
log "Timestamp: $(date -u +'%Y-%m-%d %H:%M:%SZ' 2>/dev/null || date)"
log "Terminal : $(tty 2>/dev/null || echo 'non-tty')"
log "Machine  : $MACHINE ($RAW_MACHINE) | $CPUS cores ($CPU) | $MEM RAM"
log "=========================================================="

# ----------------------------------------------------------- cpu governor
set_performance_mode() {
    local gov="${1:-${GOVERNOR:-performance}}"
    log "Configuring CPU governor to '$gov'..."
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$g" ] && echo "$gov" > "$g" 2>/dev/null || true
    done
    for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        [ -f "$epp" ] && echo "$gov" > "$epp" 2>/dev/null || true
    done

    # Ensure CPU boost is active for both AMD (CPB/PBO) and Intel (Turbo)
    if [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    fi
    for b in /sys/devices/system/cpu/cpu*/cpufreq/boost; do
        [ -f "$b" ] && echo 1 > "$b" 2>/dev/null || true
    done
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    fi

    # Apply via cpupower utility if available
    if command -v cpupower >/dev/null 2>&1; then
        cpupower frequency-set -g "$gov" >/dev/null 2>&1 || true
        cpupower set -b 0 >/dev/null 2>&1 || true
    fi
}
set_performance_mode

# ------------------------------------------------------------------- mount
# Wait for the DATADISK partition to appear and mount it cleanly (with auto-repair).
mount_exec() {
    local data_dev=""
    local tries=0
    while [ "$tries" -lt 20 ]; do
        data_dev=$(blkid -L DATADISK 2>/dev/null || true)
        [ -n "$data_dev" ] && break
        tries=$((tries + 1))
        sleep 0.5
    done

    # Already mounted (by fstab or a previous run)?
    if mountpoint -q "$DATADIR" 2>/dev/null; then
        if touch "$DATADIR/.rw_test" 2>/dev/null; then
            rm -f "$DATADIR/.rw_test"
            log "DATADISK already mounted rw on $DATADIR"
            mkdir -p "$TESTSDIR" "$RESULTSDIR"
            return 0
        else
            log "WARNING: DATADISK is mounted READ-ONLY! Attempting repair & remount..."
            umount -l "$DATADIR" 2>/dev/null || true
        fi
    fi

    if [ -n "$data_dev" ] && [ -b "$data_dev" ]; then
        log "Found DATADISK device: $data_dev. Repairing filesystem if dirty..."
        fsck.vfat -a -w "$data_dev" 2>/dev/null || dosfsck -a "$data_dev" 2>/dev/null || true
        mkdir -p "$DATADIR"
        if mount -o rw,noatime "$data_dev" "$DATADIR" 2>/dev/null; then
            log "DATADISK successfully mounted rw on $DATADIR"
        else
            log "WARNING: Mount failed for $data_dev; attempting mount by label..."
            mount -o rw,noatime -L DATADISK "$DATADIR" 2>/dev/null || true
        fi
    else
        log "WARNING: DATADISK device not found; using RAM fallback /tmp/data"
        DATADIR=/tmp/data
        TESTSDIR="$DATADIR/tests"
        RESULTSDIR="$DATADIR/results"
    fi
    mkdir -p "$TESTSDIR" "$RESULTSDIR"
}

# ---------------------------------------------------------------- detection
list_tests() {
    if [ -d "$TESTSDIR" ]; then
        # shellcheck disable=SC2012
        ls -d "$TESTSDIR"/*/ 2>/dev/null | sed "s|$TESTSDIR/||; s|/$||" || true
    fi
}

have_test() { # $1 = name
    [ -n "$1" ] && [ -d "$TESTSDIR/$1" ]
}

is_lab_test() { # $1 = test dir path or test name
    local dir="$1"
    if [ ! -d "$dir" ] && [ -d "$TESTSDIR/$1" ]; then
        dir="$TESTSDIR/$1"
    fi
    [ -d "$dir" ] && [ -f "$dir/base.cpp" ] && [ -f "$dir/opt.cpp" ] && [ -f "$dir/inputs.txt" ]
}

# ------------------------------------------------------------------ AO (Optimization)
get_ao_flags() { # $1 = AO level (O0, O1, O2, O3, Ofast, Os, default)
    local lvl="${1:-${AO_LEVEL:-O2}}"
    case "$lvl" in
        0|O0|o0|-O0)
            echo "-O0 -fno-builtin"
            ;;
        1|O1|o1|-O1)
            echo "-O1"
            ;;
        2|O2|o2|-O2)
            echo "-O2 -march=native"
            ;;
        3|O3|o3|-O3)
            echo "-O3 -march=native"
            ;;
        fast|Ofast|ofast|FAST|-Ofast)
            echo "-Ofast -march=native -flto"
            ;;
        s|Os|os|size|-Os)
            echo "-Os"
            ;;
        *)
            echo "$lvl"
            ;;
    esac
}

# ------------------------------------------------------------------ compile
compile_test() { # $1 = test dir (path), $2 = workdir, $3 = optional ao_level
    local srcdir="$1" work="$2"
    local ao_lvl="${3:-$AO_LEVEL}"
    local ao_flags
    ao_flags=$(get_ao_flags "$ao_lvl")

    rm -rf "$work"; mkdir -p "$work"

    # 1. Script test: if run.sh is provided, copy test assets and use it directly
    if [ -f "$srcdir/run.sh" ]; then
        cp -r "$srcdir"/. "$work/" 2>/dev/null || true
        chmod +x "$work/run.sh"
        echo "Script runner detected: run.sh (AO: $ao_lvl)" > "$work/build.log"
        log "using script test: run.sh (AO: $ao_lvl)"
        CURRENT_TEST_FLAGS="(script runner)"
        return 0
    fi

    # 2. Makefile test: if Makefile is provided, run make
    if [ -f "$srcdir/Makefile" ] || [ -f "$srcdir/makefile" ]; then
        cp -r "$srcdir"/. "$work/" 2>/dev/null || true
        log "building with Makefile (AO: $ao_lvl, flags: $ao_flags)"
        ( cd "$work" && make CXXFLAGS="$ao_flags" CFLAGS="$ao_flags" ) >"$work/build.log" 2>&1
        if [ -x "$work/test" ] || [ -x "$work/run" ]; then
            log "build OK"
            CURRENT_TEST_FLAGS="Makefile ($ao_flags)"
            return 0
        else
            log "ERROR: make build failed (see build.log)"
            return 1
        fi
    fi

    # 3. Native C++ compilation
    local custom_flags=""
    if [ -f "$srcdir/build.flags" ]; then
        custom_flags=$(head -1 "$srcdir/build.flags")
    fi

    # Strip existing -O... and -flto from test build.flags so requested AO level takes full precedence
    local clean_custom
    clean_custom=$(echo "$custom_flags" | sed -E 's/-O[0-9a-zA-Z]+//g; s/-flto//g; s/  */ /g; s/^ //; s/ $//')

    local final_flags="$clean_custom $ao_flags"
    # shellcheck disable=SC2086
    final_flags=$(echo $final_flags)

    # Copy all test assets (source code, headers, data files) into workdir
    cp -r "$srcdir"/. "$work/" 2>/dev/null || true

    local cpp_count
    cpp_count=$(ls "$work"/*.cpp "$work"/*.cc "$work"/*.cxx 2>/dev/null | wc -l)
    if [ "$cpp_count" -eq 0 ]; then
        log "ERROR: no C++ sources or run.sh in $srcdir"
        return 1
    fi

    log "compiling [AO: $ao_lvl]: g++ $final_flags ($cpp_count file(s))"
    local srcs
    srcs=$(ls "$work"/*.cpp "$work"/*.cc "$work"/*.cxx 2>/dev/null)
    # shellcheck disable=SC2086
    ( cd "$work" && g++ $final_flags -o ./test $srcs ) \
        >"$work/build.log" 2>&1
    if [ ! -x "$work/test" ]; then
        log "ERROR: build failed. Compiler output:"
        cat "$work/build.log" 2>/dev/null | tail -n 25 || true
        return 1
    fi
    log "build OK"
    CURRENT_TEST_FLAGS="$final_flags"
    return 0
}

# --------------------------------------------------------------------- run
# Times a single execution of the test binary or script. /usr/bin/time -f prints
# "REAL USER SYS" (elapsed/user/system, seconds) to $work/.time and lets
# the command's exit status through. Returns: client status; sets TIMING.
run_once() { # $1 = workdir, $2 = optional run_index
    local work="$1"
    local idx="${2:-}"
    rm -f "$work/.time" "$work/run.out" "$work/run.err"

    local exe="./test"
    if [ -x "$work/run.sh" ]; then
        exe="./run.sh"
    elif [ -x "$work/run" ]; then
        exe="./run"
    fi

    # build the command inside a subshell so we can set positional params cleanly
    (
        cd "$work"
        if [ -n "${RUNARGS:-}" ]; then
            eval "set -- $RUNARGS"
        else
            set --
        fi
        if [ -n "${STDIN_FILE:-}" ]; then
            /usr/bin/time -f "%e %U %S" -o "$work/.time" \
                timeout "$TIMEOUT" "$exe" "$@" < "$STDIN_FILE"
        else
            /usr/bin/time -f "%e %U %S" -o "$work/.time" \
                timeout "$TIMEOUT" "$exe" "$@"
        fi
    ) >"$work/run.out" 2>"$work/run.err"
    local rc=$?

    local real="-" user="-" sys="-"
    if [ -f "$work/.time" ]; then
        read -r real user sys < "$work/.time"
    fi
    TIMING="$real $user $sys"

    if [ -n "$idx" ]; then
        cp "$work/run.out" "$work/run_${idx}.out" 2>/dev/null || true
        cp "$work/run.err" "$work/run_${idx}.err" 2>/dev/null || true
    fi

    return "$rc"
}

# ------------------------------------------------------------------ report
write_report() { # $1 = testname, $2 = resultdir, $3 = ao_level, $4 = flags
    local clean_machine clean_cpu
    clean_machine=$(echo "$MACHINE" | tr '\t\r\n' ' ' | sed 's/  */ /g')
    clean_cpu=$(echo "$CPU" | tr '\t\r\n' ' ' | sed 's/  */ /g')
    local report_ao="${3:-$AO_LEVEL}"
    local report_flags="${4:-$FLAGS}"
    cat > "$2/report.txt" <<EOF
Test       : $1
Machine    : $clean_machine ($RAW_MACHINE)
CPU        : $clean_cpu
Cores      : $CPUS
Memory     : $MEM
Compiler   : $(g++ --version 2>/dev/null | head -1)
AO Level   : $report_ao
Flags      : $report_flags
Timestamp  : $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
-- runs (real user sys seconds) --
$(cat "$2/times.txt")
EOF
    {
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t' \
            "$(date -u +%Y%m%d_%H%M%S)" "$clean_machine" "$clean_cpu" "$CPUS" "$1" "$report_ao" "$report_flags"
        tr '\n' '\t' < "$2/times.txt"; echo
    } >> "$RESULTSDIR/summary.tsv"
    sync
}

# ----------------------------------------------------------- full AO benchmark
run_test_all_ao() { # $1 = test name
    local name="$1"
    have_test "$name" || { log "no such test: $name"; return 1; }

    local levels=("O0" "O1" "O2" "O3" "Ofast")
    local matrix_file="/tmp/ao_matrix_${name}.txt"
    local now
    now=$(date -u +%Y%m%d-%H%M%S 2>/dev/null || date +%s)
    local all_resdir="$RESULTSDIR/$MACHINE/${name}-AO_ALL-${now}"
    mkdir -p "$all_resdir"

    echo
    log "================================================================================"
    log ">>> Starting AO Benchmark Matrix for: $name (Levels: ${levels[*]}) <<<"
    log "================================================================================"

    local base_time="0"
    local lvl_real_list=""
    local lvl_user_list=""
    local lvl_flags_list=""

    for lvl in "${levels[@]}"; do
        echo
        log "--------------------------------------------------------"
        log "Running $name with AO Level: $lvl"
        log "--------------------------------------------------------"

        local srcdir="$TESTSDIR/$name"
        local work="/tmp/w-${name}-${lvl}"
        CURRENT_TEST_FLAGS=""

        if ! compile_test "$srcdir" "$work" "$lvl"; then
            log "ERROR: Compilation failed for $name at AO level $lvl"
            lvl_real_list="${lvl_real_list}${lvl}:FAIL\n"
            lvl_user_list="${lvl_user_list}${lvl}:FAIL\n"
            lvl_flags_list="${lvl_flags_list}${lvl}:COMPILE_ERROR\n"
            continue
        fi

        lvl_flags_list="${lvl_flags_list}${lvl}:${CURRENT_TEST_FLAGS}\n"

        RUNARGS=""
        [ -f "$srcdir/run.args" ] && RUNARGS=$(cat "$srcdir/run.args")
        export STDIN_FILE=""
        [ -f "$srcdir/run.stdin" ] && STDIN_FILE="$srcdir/run.stdin"
        export AO_LEVEL="$lvl"

        local t_real="-" t_user="-"
        local i=0
        mkdir -p "$all_resdir/$lvl"
        : > "$all_resdir/$lvl/run.out"
        : > "$all_resdir/$lvl/run.err"

        while [ "$i" -lt "$RUNS" ]; do
            i=$((i+1))
            TIMING=""
            log "run $i/$RUNS [AO: $lvl]"
            local cur_r="-" cur_u="-" cur_s="-"
            if run_once "$work" "$i"; then
                if [ -n "$TIMING" ]; then
                    read -r cur_r cur_u cur_s <<< "$TIMING"
                    if [ "$t_real" = "-" ]; then
                        t_real="$cur_r"
                        t_user="$cur_u"
                    else
                        local is_faster
                        is_faster=$(awk -v cur="$cur_r" -v best="$t_real" 'BEGIN { if (cur > 0 && (best <= 0 || cur < best)) print 1; else print 0 }' 2>/dev/null || echo 0)
                        if [ "$is_faster" -eq 1 ]; then
                            t_real="$cur_r"
                            t_user="$cur_u"
                        fi
                    fi
                fi
            else
                log "WARNING: Run $i failed (exit $?)"
            fi

            cp "$work/run.out" "$all_resdir/$lvl/run_${i}.out" 2>/dev/null || true
            cp "$work/run.err" "$all_resdir/$lvl/run_${i}.err" 2>/dev/null || true

            {
                if [ "$RUNS" -gt 1 ]; then
                    echo "================================================================================"
                    echo "RUN $i/$RUNS [AO: $lvl]  (Real: ${cur_r}s)"
                    echo "--------------------------------------------------------------------------------"
                fi
                cat "$work/run.out"
                echo
            } >> "$all_resdir/$lvl/run.out"

            if [ -s "$work/run.err" ]; then
                {
                    if [ "$RUNS" -gt 1 ]; then
                        echo "--- RUN $i/$RUNS ERRORS ---"
                    fi
                    cat "$work/run.err"
                    echo
                } >> "$all_resdir/$lvl/run.err"
            fi
        done

        lvl_real_list="${lvl_real_list}${lvl}:${t_real}\n"
        lvl_user_list="${lvl_user_list}${lvl}:${t_user}\n"

        if [ "$lvl" = "O0" ] && [ -n "$t_real" ] && [ "$t_real" != "-" ] && [ "$t_real" != "FAIL" ]; then
            base_time="$t_real"
        fi

        cp "$all_resdir/$lvl/run.out" "$all_resdir/$lvl/out.txt" 2>/dev/null || true
        cp "$all_resdir/$lvl/run.out" "$srcdir/out_${lvl}.txt" 2>/dev/null || true
        cp "$work/build.log" "$all_resdir/$lvl/build.log" 2>/dev/null || true
    done

    # Format and display summary matrix table
    {
        echo
        echo "===================================================================================================="
        echo "AO OPTIMIZATION BENCHMARK MATRIX: $name"
        echo "Machine   : $MACHINE ($CPUS cores, $CPU)"
        echo "Timestamp : $(date -u +'%Y-%m-%d %H:%M:%SZ' 2>/dev/null || date)"
        echo "----------------------------------------------------------------------------------------------------"
        printf "  %-8s | %-36s | %10s | %10s | %14s\n" "AO Level" "Compiler Flags" "Real Time" "User Time" "Speedup vs O0"
        echo "----------------------------------------------------------------------------------------------------"

        for lvl in "${levels[@]}"; do
            local r u fl speedup
            r=$(printf "%b" "$lvl_real_list" | grep "^${lvl}:" | head -1 | cut -d: -f2-)
            u=$(printf "%b" "$lvl_user_list" | grep "^${lvl}:" | head -1 | cut -d: -f2-)
            fl=$(printf "%b" "$lvl_flags_list" | grep "^${lvl}:" | head -1 | cut -d: -f2-)
            [ -z "$r" ] && r="-"
            [ -z "$u" ] && u="-"
            [ -z "$fl" ] && fl="-"
            [ ${#fl} -gt 36 ] && fl="${fl:0:33}..."
            speedup="-"

            if [ "$base_time" != "0" ] && [ "$r" != "-" ] && [ "$r" != "FAIL" ]; then
                speedup=$(awk -v b="$base_time" -v cur="$r" 'BEGIN { if (cur > 0) printf "%.2fx", b/cur; else print "-" }' 2>/dev/null || echo "-")
                [ "$lvl" = "O0" ] && speedup="1.00x (base)"
            fi

            printf "  %-8s | %-36s | %9ss | %9ss | %14s\n" "$lvl" "$fl" "$r" "$u" "$speedup"
        done
        echo "===================================================================================================="
        echo
    } | tee "$matrix_file"

    cp "$matrix_file" "$all_resdir/ao_matrix.txt" 2>/dev/null || true
    cp "$matrix_file" "$DATADIR/results/ao_matrix_${name}.txt" 2>/dev/null || true
    cat "$matrix_file" >> "$DATADIR/out.txt" 2>/dev/null || true

    log "Matrix saved to: $DATADIR/results/ao_matrix_${name}.txt and DATADISK/out.txt"
    return 0
}

# ----------------------------------------------------------- lab benchmark
run_lab_benchmark() { # $1 = test name
    local name="$1"
    have_test "$name" || { log "no such test: $name"; return 1; }
    local srcdir="$TESTSDIR/$name"
    is_lab_test "$srcdir" || { log "test '$name' is not a lab benchmark (requires base.cpp, opt.cpp, inputs.txt)"; return 1; }

    local now
    now=$(date -u +%Y%m%d-%H%M%S 2>/dev/null || date +%s)
    local lab_resdir="$RESULTSDIR/$MACHINE/${name}-lab-${now}"
    mkdir -p "$lab_resdir"

    echo
    log "================================================================================"
    log ">>> Starting Lab Architecture Benchmark for: $name <<<"
    log "================================================================================"

    # 1. Hardware Architecture Profile
    log "Generating hardware architecture profile..."
    if command -v puretest-hw >/dev/null 2>&1; then
        puretest-hw "$lab_resdir" >/dev/null 2>&1 || true
    elif [ -x "/usr/local/bin/puretest-hw" ]; then
        /usr/local/bin/puretest-hw "$lab_resdir" >/dev/null 2>&1 || true
    elif [ -f "$REPO_ROOT/board/overlay/usr/local/bin/puretest-hw" ]; then
        /bin/bash "$REPO_ROOT/board/overlay/usr/local/bin/puretest-hw" "$lab_resdir" >/dev/null 2>&1 || true
    fi

    if [ -f "$lab_resdir/machine_specs.tsv" ]; then
        mkdir -p "$DATADIR/results"
        cp "$lab_resdir/machine_specs.tsv" "$DATADIR/results/machine_specs_${MACHINE}.tsv" 2>/dev/null || true
        cp "$lab_resdir/machine_specs.tsv" "$DATADIR/results/machine_specs.tsv" 2>/dev/null || true
        cp "$lab_resdir/machine_specs.txt" "$DATADIR/results/machine_specs.txt" 2>/dev/null || true
    fi

    set_performance_mode

    # 2. Compile base.cpp and opt.cpp under O0, O1, O2
    local lab_levels=("O0" "O1" "O2")
    local custom_flags=""
    if [ -f "$srcdir/build.flags" ]; then
        custom_flags=$(head -1 "$srcdir/build.flags" | sed -E 's/-O[0-9a-zA-Z]+//g; s/-flto//g; s/  */ /g; s/^ //; s/ $//')
    fi

    for lvl in "${lab_levels[@]}"; do
        local ao_flags
        ao_flags=$(get_ao_flags "$lvl")
        local final_flags="-I/usr/local/include -I$srcdir $custom_flags $ao_flags"

        log "Compiling $name [$lvl]: g++ $final_flags"

        # base
        local work_base="/tmp/lab_${name}_base_${lvl}"
        rm -rf "$work_base" && mkdir -p "$work_base"
        cp -r "$srcdir"/. "$work_base/" 2>/dev/null || true
        # shellcheck disable=SC2086
        ( cd "$work_base" && g++ $final_flags -o "$work_base/bin" "$srcdir/base.cpp" ) > "$work_base/build.log" 2>&1
        if [ ! -x "$work_base/bin" ]; then
            log "ERROR: Compilation failed for base.cpp at $lvl"
            cat "$work_base/build.log" 2>/dev/null | tail -n 20
            return 1
        fi

        # opt
        local work_opt="/tmp/lab_${name}_opt_${lvl}"
        rm -rf "$work_opt" && mkdir -p "$work_opt"
        cp -r "$srcdir"/. "$work_opt/" 2>/dev/null || true
        # shellcheck disable=SC2086
        ( cd "$work_opt" && g++ $final_flags -o "$work_opt/bin" "$srcdir/opt.cpp" ) > "$work_opt/build.log" 2>&1
        if [ ! -x "$work_opt/bin" ]; then
            log "ERROR: Compilation failed for opt.cpp at $lvl"
            cat "$work_opt/build.log" 2>/dev/null | tail -n 20
            return 1
        fi
    done
    log "Compilation successful for all optimization levels."

    # 3. Read inputs from inputs.txt
    local inputs=()
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | sed 's/\r$//; s/[[:space:]]*#.*$//; /^[[:space:]]*$/d')
        [ -n "$line" ] && inputs+=("$line")
    done < "$srcdir/inputs.txt"

    if [ ${#inputs[@]} -eq 0 ]; then
        log "ERROR: No test inputs found in $srcdir/inputs.txt"
        return 1
    fi

    local max_base_n="${LAB_BASE_MAX_N:-1000000}"
    local base_timeout_hit=0

    local acc_rows=()
    local timing_rows_tsv=()
    local timing_rows_txt=()

    echo
    log "Executing test grid (${#inputs[@]} input cases)..."

    for inp in "${inputs[@]}"; do
        local cur_x cur_n has_x=1
        read -r cur_x cur_n <<< "$inp"
        if [ -z "$cur_n" ]; then
            cur_n="$cur_x"
            cur_x="-"
            has_x=0
            log "-> Case n=$cur_n"
        else
            log "-> Case x=$cur_x, n=$cur_n"
        fi

        local stdin_data
        if [ "$has_x" -eq 1 ]; then
            stdin_data=$(printf "%s\n%s\n" "$cur_x" "$cur_n")
        else
            stdin_data=$(printf "%s\n" "$cur_n")
        fi

        local val_base_acc="-"
        local val_opt_acc="-"
        local t_base_levels=()
        local t_opt_levels=()
        local gain_levels=()

        for lvl in "${lab_levels[@]}"; do
            local work_base="/tmp/lab_${name}_base_${lvl}"
            local work_opt="/tmp/lab_${name}_opt_${lvl}"

            # --- Base execution ---
            local t_b="-"
            local val_b="-"
            if [ "$base_timeout_hit" -eq 1 ] || [ "$cur_n" -gt "$max_base_n" ]; then
                t_b="-"
                val_b="-"
            else
                rm -f "$work_base/.time" "$work_base/run.out" "$work_base/run.err"
                printf "%s" "$stdin_data" | /usr/bin/time -f "%e" -o "$work_base/.time" timeout "$TIMEOUT" "$work_base/bin" > "$work_base/run.out" 2> "$work_base/run.err"
                local rc=$?
                if [ $rc -eq 124 ]; then
                    log "   [base $lvl] timed out on n=$cur_n; marking timeout and skipping future base runs"
                    base_timeout_hit=1
                    t_b="-"
                    val_b="-"
                elif [ $rc -ne 0 ]; then
                    log "   [base $lvl] exited with code $rc"
                    t_b="-"
                    val_b="-"
                else
                    local int_t
                    int_t=$(grep -i "Затраченное время:" "$work_base/run.out" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
                    if [ -n "$int_t" ]; then
                        t_b="$int_t"
                    else
                        t_b=$(cat "$work_base/.time" 2>/dev/null | tr -d ' \r\n')
                    fi
                    val_b=$(grep -oE '=\s*[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?' "$work_base/run.out" 2>/dev/null | tr -d '= ' | tail -1)
                    [ -z "$val_b" ] && val_b="-"
                fi
            fi

            # --- Opt execution ---
            local t_o="-"
            local val_o="-"
            rm -f "$work_opt/.time" "$work_opt/run.out" "$work_opt/run.err"
            printf "%s" "$stdin_data" | /usr/bin/time -f "%e" -o "$work_opt/.time" timeout "$TIMEOUT" "$work_opt/bin" > "$work_opt/run.out" 2> "$work_opt/run.err"
            local rc_opt=$?
            if [ $rc_opt -ne 0 ]; then
                log "   [opt $lvl] failed (exit $rc_opt)"
                t_o="-"
                val_o="-"
            else
                local int_t_opt
                int_t_opt=$(grep -i "Затраченное время:" "$work_opt/run.out" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
                if [ -n "$int_t_opt" ]; then
                    t_o="$int_t_opt"
                else
                    t_o=$(cat "$work_opt/.time" 2>/dev/null | tr -d ' \r\n')
                fi
                val_o=$(grep -oE '=\s*[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?' "$work_opt/run.out" 2>/dev/null | tr -d '= ' | tail -1)
                [ -z "$val_o" ] && val_o="-"
            fi

            # --- Gain % calculation ---
            local cur_gain="-"
            if [ "$t_b" != "-" ] && [ "$t_o" != "-" ]; then
                cur_gain=$(awk -v b="$t_b" -v opt="$t_o" 'BEGIN {
                    if (opt > 0) {
                        g = ((b - opt) / opt) * 100.0;
                        if (g >= 0) printf "+%.1f%%", g;
                        else printf "%.1f%%", g;
                    } else if (b == opt) {
                        print "0.0%";
                    } else {
                        print "-";
                    }
                }' 2>/dev/null || echo "-")
            fi

            t_base_levels+=("$t_b")
            t_opt_levels+=("$t_o")
            gain_levels+=("$cur_gain")

            # Capture accuracy values from O2 (or O1/O0 if O2 is missing)
            if [ "$lvl" = "O2" ] || [ "$val_opt_acc" = "-" ]; then
                val_opt_acc="$val_o"
                [ "$val_b" != "-" ] && val_base_acc="$val_b"
            fi
        done

        # Fallback for base accuracy value if O2 was skipped
        if [ "$val_base_acc" = "-" ] && [ "$val_b" != "-" ]; then
            val_base_acc="$val_b"
        fi

        # --- Reference Math Calculation ---
        local val_ref="-"
        if [ -f "$srcdir/ref.sh" ]; then
            val_ref=$(/bin/bash "$srcdir/ref.sh" "$cur_x" "$cur_n" 2>/dev/null || echo "-")
        elif [[ "$name" == *"pi"* ]]; then
            val_ref=$(awk 'BEGIN { printf "%.30f", 4.0 * atan2(1, 1) }' 2>/dev/null || echo "-")
        else
            val_ref=$(awk -v x="$cur_x" 'BEGIN { printf "%.30f", exp(x) }' 2>/dev/null || echo "-")
        fi

        # --- Absolute Error Calculation ---
        local err="-"
        if [ "$val_opt_acc" != "-" ] && [ "$val_ref" != "-" ]; then
            err=$(awk -v calc="$val_opt_acc" -v ref="$val_ref" 'BEGIN {
                diff = calc - ref;
                if (diff < 0) diff = -diff;
                printf "%.10e", diff;
            }' 2>/dev/null || echo "-")
        fi

        # Store for Table 1 (Accuracy)
        acc_rows+=("$cur_x	$cur_n	$val_base_acc	$val_opt_acc	$val_ref	$err")

        # Store for Table 2 (Timing)
        local tb0="${t_base_levels[0]:--}" to0="${t_opt_levels[0]:--}" g0="${gain_levels[0]:--}"
        local tb1="${t_base_levels[1]:--}" to1="${t_opt_levels[1]:--}" g1="${gain_levels[1]:--}"
        local tb2="${t_base_levels[2]:--}" to2="${t_opt_levels[2]:--}" g2="${gain_levels[2]:--}"

        timing_rows_tsv+=("$cur_x	$cur_n	$tb0	$to0	$g0	$tb1	$to1	$g1	$tb2	$to2	$g2")

        local txt_line
        txt_line=$(printf "%-8s | %-12s | %-11s | %-11s | %-11s | %-11s | %-11s | %-11s | %-11s | %-11s | %-11s" \
            "$cur_x" "$cur_n" \
            "${tb0}s" "${to0}s" "$g0" \
            "${tb1}s" "${to1}s" "$g1" \
            "${tb2}s" "${to2}s" "$g2" | sed 's/-s/-/g')
        timing_rows_txt+=("$txt_line")
    done

    # 4. Generate Accuracy Table (TSV and TXT)
    local acc_tsv="$lab_resdir/accuracy_table.tsv"
    local acc_txt="$lab_resdir/accuracy_table.txt"

    {
        printf "Значение x\tЗначение n\tбез алг. опт.\tс алг. опт.\tЭталон (калькулятор)\tПогрешность\n"
        for r in "${acc_rows[@]}"; do
            echo "$r"
        done
    } > "$acc_tsv"

    {
        echo "=================================================================================================================================================="
        echo "ТАБЛИЦА 1. ОЦЕНКА ТОЧНОСТИ ВЫЧИСЛЕНИЙ ДЛЯ ТЕСТА: $name"
        echo "Machine   : $MACHINE ($CPUS cores, $CPU)"
        echo "Timestamp : $(date -u +'%Y-%m-%d %H:%M:%SZ' 2>/dev/null || date)"
        echo "--------------------------------------------------------------------------------------------------------------------------------------------------"
        printf "%-10s | %-12s | %-32s | %-32s | %-32s | %-14s\n" "Значение x" "Значение n" "без алг. опт." "с алг. опт." "Эталон (калькулятор)" "Погрешность"
        echo "--------------------------------------------------------------------------------------------------------------------------------------------------"
        for r in "${acc_rows[@]}"; do
            IFS=$'\t' read -r ax an ab ao ar ae <<< "$r"
            printf "%-10s | %-12s | %-32s | %-32s | %-32s | %-14s\n" "$ax" "$an" "$ab" "$ao" "$ar" "$ae"
        done
        echo "=================================================================================================================================================="
    } > "$acc_txt"

    # 5. Generate Timing & Gain Table (TSV and TXT)
    local time_tsv="$lab_resdir/timing_table.tsv"
    local time_txt="$lab_resdir/timing_table.txt"

    {
        printf "Значение x\tЗначение n\tБез оптимизации (Od / O0)\t\t\tС оптимизацией по скорости (O1)\t\t\tС оптимизацией по скорости (O2)\n"
        printf "\t\tбез алг. опт.\tс алг. опт.\tвыигрыш, %%\tбез алг. опт.\tс алг. опт.\tвыигрыш, %%\tбез алг. опт.\tс алг. опт.\tвыигрыш, %%\n"
        for r in "${timing_rows_tsv[@]}"; do
            echo "$r"
        done
    } > "$time_tsv"

    {
        echo "=================================================================================================================================================================="
        echo "ТАБЛИЦА 2. ВРЕМЯ РАБОТЫ И ВЫИГРЫШ ОТ АЛГОРИТМИЧЕСКОЙ ОПТИМИЗАЦИИ: $name"
        echo "Machine   : $MACHINE ($CPUS cores, $CPU)"
        echo "Timestamp : $(date -u +'%Y-%m-%d %H:%M:%SZ' 2>/dev/null || date)"
        echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------"
        printf "%-8s | %-12s | %-37s | %-37s | %-37s\n" "x" "n" "Без оптимизации (Od / O0)" "С оптимизацией по скорости (O1)" "С оптимизацией по скорости (O2)"
        printf "%-8s | %-12s | %-11s | %-11s | %-11s | %-11s | %-11s | %-11s | %-11s | %-11s | %-11s\n" "" "" "без опт." "с опт." "выигрыш %" "без опт." "с опт." "выигрыш %" "без опт." "с опт." "выигрыш %"
        echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------"
        for line in "${timing_rows_txt[@]}"; do
            echo "$line"
        done
        echo "=================================================================================================================================================================="
    } > "$time_txt"

    # 6. Display to console and persist
    echo
    cat "$acc_txt"
    echo
    cat "$time_txt"
    echo

    mkdir -p "$DATADIR/results"
    cp "$acc_tsv" "$DATADIR/results/${name}_accuracy.tsv" 2>/dev/null || true
    cp "$acc_txt" "$DATADIR/results/${name}_accuracy.txt" 2>/dev/null || true
    cp "$time_tsv" "$DATADIR/results/${name}_timing.tsv" 2>/dev/null || true
    cp "$time_txt" "$DATADIR/results/${name}_timing.txt" 2>/dev/null || true

    {
        echo
        cat "$acc_txt"
        echo
        cat "$time_txt"
        echo
    } >> "$DATADIR/out.txt" 2>/dev/null || true

    sync
    log "[✓] Lab benchmark complete!"
    log "Word tables generated on DATADISK:"
    log "  1. Accuracy Table : $DATADIR/results/${name}_accuracy.tsv"
    log "  2. Timing Table   : $DATADIR/results/${name}_timing.tsv"
    log "  3. Hardware Specs : $DATADIR/results/machine_specs_${MACHINE}.tsv"
    log "  Tip: Open .tsv files and copy/paste directly into Microsoft Word for instant native tables."
    return 0
}

run_test() { # $1 = test name, $2 = optional ao_level
    have_test "$1" || { log "no such test: $1"; return 1; }
    local name="$1"
    local req_ao="${2:-$AO_LEVEL}"

    if is_lab_test "$TESTSDIR/$name"; then
        run_lab_benchmark "$name"
        return $?
    fi

    if [ "$req_ao" = "all" ] || [ "$req_ao" = "ALL" ]; then
        run_test_all_ao "$name"
        return $?
    fi

    local srcdir="$TESTSDIR/$name"
    local work="/tmp/w-$name"
    local now resdir
    now=$(date -u +%Y%m%d-%H%M%S 2>/dev/null || date +%s)
    resdir="$RESULTSDIR/$MACHINE/$name-$req_ao-$now"
    mkdir -p "$resdir"

    CURRENT_TEST_FLAGS=""
    log "=== running test '$name' [AO: $req_ao] ==="
    compile_test "$srcdir" "$work" "$req_ao" || return 1
    set_performance_mode

    RUNARGS=""
    [ -f "$srcdir/run.args" ] && RUNARGS=$(cat "$srcdir/run.args")
    export STDIN_FILE=""
    [ -f "$srcdir/run.stdin" ] && STDIN_FILE="$srcdir/run.stdin"
    export AO_LEVEL="$req_ao"

    : > "$resdir/times.txt"
    : > "$resdir/run.out"
    : > "$resdir/run.err"
    local i rc
    i=0
    while [ "$i" -lt "$RUNS" ]; do
        i=$((i+1))
        log "run $i/$RUNS [AO: $req_ao]"
        TIMING=""
        if run_once "$work" "$i"; then
            rc=0
        else
            rc=$?
        fi
        [ -n "$TIMING" ] && printf 'run_%s\t%s\texit=%s\n' "$i" "$TIMING" "$rc" \
            >> "$resdir/times.txt"
        [ "$rc" -ne 0 ] && log "WARNING: run $i exited $rc (124 = timeout)"

        # Save individual run outputs into resultdir
        cp "$work/run.out" "$resdir/run_${i}.out" 2>/dev/null || true
        cp "$work/run.err" "$resdir/run_${i}.err" 2>/dev/null || true

        # Append each run into combined run.out with header
        {
            if [ "$RUNS" -gt 1 ]; then
                echo "================================================================================"
                echo "RUN $i/$RUNS [AO: $req_ao]  (Real: ${TIMING%% *}s | Exit: $rc)"
                echo "--------------------------------------------------------------------------------"
            fi
            cat "$work/run.out"
            echo
        } >> "$resdir/run.out"

        if [ -s "$work/run.err" ]; then
            {
                if [ "$RUNS" -gt 1 ]; then
                    echo "--- RUN $i/$RUNS ERRORS ---"
                fi
                cat "$work/run.err"
                echo
            } >> "$resdir/run.err"
        fi
    done

    cp "$work/build.log" "$resdir/build.log" 2>/dev/null || true

    # Save full results of all runs to out.txt in result dir and test folder
    cp "$resdir/run.out" "$resdir/out.txt" 2>/dev/null || true
    cp "$resdir/run.out" "$srcdir/out.txt" 2>/dev/null || true
    [ -n "$req_ao" ] && cp "$resdir/run.out" "$srcdir/out_${req_ao}.txt" 2>/dev/null || true

    # Append results of all runs into DATADISK root out.txt
    if [ -s "$resdir/run.out" ]; then
        {
            echo "================================================================================"
            echo "TEST      : $name [AO: $req_ao]"
            echo "FLAGS     : ${CURRENT_TEST_FLAGS:-unknown}"
            echo "MACHINE   : $MACHINE ($CPUS cores, $CPU)"
            echo "TIMESTAMP : $(date -u +'%Y-%m-%d %H:%M:%SZ' 2>/dev/null || date)"
            echo "RUNS      : $RUNS"
            echo "--------------------------------------------------------------------------------"
            cat "$resdir/run.out"
            echo
        } >> "$DATADIR/out.txt" 2>/dev/null || true
    fi

    write_report "$name" "$resdir" "$req_ao" "${CURRENT_TEST_FLAGS:-$FLAGS}"
    sync
    log "=== done; report: ${resdir}/report.txt ==="
    log "=== results saved to: ${srcdir}/out.txt and ${DATADIR}/out.txt ==="
    return 0
}

run_all_tests() {
    local req_ao="${1:-$AO_LEVEL}"
    log "=== running ALL available tests [AO: $req_ao] ==="
    local t
    for t in $(list_tests); do
        echo
        log ">>> Starting test suite: $t <<<"
        run_test "$t" "$req_ao"
    done
    sync
    echo
    log "=== ALL tests completed [AO: $req_ao] ==="
}

# ------------------------------------------------------------------ test list
# Reads a list of test names from a file (e.g. AUTORUN, run_list.txt).
# Ignores '#' comments, blank lines, strips Windows CRLF, and handles space/comma separated names.
# Supports syntax: testname or testname:AO_LEVEL (e.g. bench_cpu:O0, bench_cpu:O3, bench_cpu:all)
get_test_list() { # $1 = file path
    local file="$1"
    [ -f "$file" ] || return 0
    sed 's/\r$//; s/[[:space:]]*#.*$//; /^[[:space:]]*$/d' "$file" | while IFS= read -r line; do
        for item in ${line//,/ }; do
            [ -n "$item" ] && echo "$item"
        done
    done
}

run_test_list() { # $1 = file path
    local file="$1"
    local items
    items=$(get_test_list "$file")
    if [ -z "$items" ]; then
        log "Notice: no valid test names found in $file"
        return 1
    fi
    log "=== Running test list from $(basename "$file") ==="
    for item in $items; do
        local t_name t_ao
        if [[ "$item" == *":"* ]]; then
            t_name="${item%%:*}"
            t_ao="${item#*:}"
        else
            t_name="$item"
            t_ao="$AO_LEVEL"
        fi

        if [ "$t_name" = "ALL" ] || [ "$t_name" = "all" ]; then
            run_all_tests "$t_ao"
        elif have_test "$t_name"; then
            echo
            log ">>> Starting test: $t_name [AO: $t_ao] <<<"
            run_test "$t_name" "$t_ao"
        else
            log "WARNING: test '$t_name' listed in $file not found in $TESTSDIR"
        fi
    done
    sync
    echo
    log "=== Test list completed ==="
    return 0
}

# -------------------------------------------------------------------- menu
menu() {
    # Suppress runtime kernel messages from printing over the console UI
    dmesg -n 1 2>/dev/null || true

    while true; do
        echo
        echo "=========================================================="
        echo "PURETESTIMAGE  ($MACHINE | $CPUS cores | AO: $AO_LEVEL)"
        echo "Available tests:"
        local found
        found=$(list_tests)
        if [ -n "$found" ]; then
            for t in $found; do
                if is_lab_test "$TESTSDIR/$t"; then
                    echo "  * $t  [lab benchmark (base vs opt)]"
                else
                    echo "  * $t"
                fi
            done
        else
            echo "  (no tests found in $TESTSDIR)"
        fi
        echo
        echo "Actions:"
        echo "  [a]   Run ALL tests (current AO: $AO_LEVEL)"
        echo "  [ao]  Run test across ALL AO levels (O0..Ofast comparison matrix)"
        echo "  [lab] Run Lab Benchmark (base.cpp vs opt.cpp comparison matrix for Word)"
        echo "  [hw]  Generate Hardware Architecture Profile (machine_specs.tsv)"
        echo "  [o]   Change AO (Optimization) level [Current: $AO_LEVEL]"
        echo "  [l]   Run test list from run_list.txt / AUTORUN"
        echo "  [s]   Drop to interactive root shell"
        echo "  [c]   Clear screen"
        echo "  [q]   Exit to shell"
        echo "  [r]   Reboot machine"
        echo "  [p]   Power off"
        echo "Or type: <testname> [AO]  (e.g. 'bench_cpu', 'lab lab1_exp', 'hw', 'ao bench_cpu')"
        echo "----------------------------------------------------------"
        printf "puretest [%s]> " "$AO_LEVEL"
        if ! read -r choice; then
            log "Notice: console input returned EOF; waiting 3s before retry..."
            sleep 3
            continue
        fi
        case "$choice" in
            a|A)
                run_all_tests "$AO_LEVEL"
                echo
                printf "Press Enter to return to menu... "
                read -r _ 2>/dev/null || true
                ;;
            ao|AO)
                echo
                echo "Available tests: $(list_tests | tr '\n' ' ')"
                printf "Enter test name for full AO comparison (or 'all'): "
                read -r ao_target
                if [ -n "$ao_target" ]; then
                    if [ "$ao_target" = "all" ] || [ "$ao_target" = "ALL" ]; then
                        for t in $(list_tests); do
                            run_test_all_ao "$t"
                        done
                    else
                        run_test_all_ao "$ao_target"
                    fi
                fi
                echo
                printf "Press Enter to return to menu... "
                read -r _ 2>/dev/null || true
                ;;
            lab|LAB)
                echo
                local lab_tests=()
                for t in $(list_tests); do
                    if is_lab_test "$TESTSDIR/$t"; then
                        lab_tests+=("$t")
                    fi
                done
                local def_lab="lab1_exp"
                if [ ${#lab_tests[@]} -gt 0 ]; then
                    def_lab="${lab_tests[0]}"
                    echo "Available lab benchmarks: ${lab_tests[*]}"
                else
                    echo "Available tests: $(list_tests | tr '\n' ' ')"
                fi
                printf "Enter lab test name [default: %s]: " "$def_lab"
                read -r lab_target
                [ -z "$lab_target" ] && lab_target="$def_lab"
                if [ -n "$lab_target" ]; then
                    run_lab_benchmark "$lab_target"
                fi
                echo
                printf "Press Enter to return to menu... "
                read -r _ 2>/dev/null || true
                ;;
            hw|HW)
                echo
                log "Collecting full hardware architecture profile..."
                mkdir -p "$DATADIR/results"
                if command -v puretest-hw >/dev/null 2>&1; then
                    puretest-hw "$DATADIR/results"
                elif [ -x "/usr/local/bin/puretest-hw" ]; then
                    /usr/local/bin/puretest-hw "$DATADIR/results"
                elif [ -f "$REPO_ROOT/board/overlay/usr/local/bin/puretest-hw" ]; then
                    /bin/bash "$REPO_ROOT/board/overlay/usr/local/bin/puretest-hw" "$DATADIR/results"
                fi
                if [ -f "$DATADIR/results/machine_specs.txt" ]; then
                    echo
                    cat "$DATADIR/results/machine_specs.txt"
                    echo
                    log "Hardware specs saved to: $DATADIR/results/machine_specs.tsv (Word-ready)"
                fi
                echo
                printf "Press Enter to return to menu... "
                read -r _ 2>/dev/null || true
                ;;
            o|O)
                echo
                echo "=========================================================="
                echo "             SELECT AO (OPTIMIZATION) LEVEL              "
                echo "=========================================================="
                echo "  [0] O0    : -O0 -fno-builtin  (No optimization, debug baseline)"
                echo "  [1] O1    : -O1               (Basic optimizations)"
                echo "  [2] O2    : -O2 -march=native (Standard - default)"
                echo "  [3] O3    : -O3 -march=native (Aggressive loop & vectorization)"
                echo "  [4] Ofast : -Ofast -march=native -flto (Maximum performance)"
                echo "  [5] Os    : -Os               (Optimize for binary size)"
                echo "  [a] ALL   : Run each test across ALL AO levels (O0..Ofast)"
                echo "  [c] Custom: Enter custom compiler flags directly"
                echo "----------------------------------------------------------"
                printf "Select level [0-5, a, c]: "
                read -r sel_opt
                case "$sel_opt" in
                    0) AO_LEVEL="O0";;
                    1) AO_LEVEL="O1";;
                    2) AO_LEVEL="O2";;
                    3) AO_LEVEL="O3";;
                    4|f|fast|Ofast) AO_LEVEL="Ofast";;
                    5|s|Os) AO_LEVEL="Os";;
                    a|A|all) AO_LEVEL="all";;
                    c|C)
                        printf "Enter custom flags: "
                        read -r custom_f
                        if [ -n "$custom_f" ]; then
                            AO_LEVEL="$custom_f"
                        fi
                        ;;
                    *) echo "Invalid choice, keeping AO_LEVEL=$AO_LEVEL";;
                esac
                log "AO Level set to: $AO_LEVEL"
                ;;
            l|L)
                local list_file=""
                for f in "$DATADIR/run_list.txt" "$DATADIR/AUTORUN" "$DATADIR/tests.txt"; do
                    if [ -f "$f" ]; then list_file="$f"; break; fi
                done
                if [ -n "$list_file" ]; then
                    run_test_list "$list_file"
                else
                    echo "Notice: no run_list.txt or AUTORUN found on DATADISK."
                    echo "Create DATADISK/run_list.txt with test names to use this option."
                fi
                echo
                printf "Press Enter to return to menu... "
                read -r _ 2>/dev/null || true
                ;;
            s|S|q|Q)
                echo "======================================================================"
                echo "                 PURETESTIMAGE - INTERACTIVE ROOT SHELL               "
                echo "======================================================================"
                echo " * DATADISK is mounted at: $DATADIR"
                echo " * Operator Cheatsheet & Guide: type 'cheatsheet' (or 'help')"
                echo "   or read: less /opt/puretest/CHEATSHEET.md"
                echo "   (covers drive mounting/unmounting, lsusb/lspci, manual compiling)"
                echo " * Troubleshooting tools: puretest-status, puretest-log, puretest-mount"
                echo " * To return to this menu at any time: type 'exit' or 'menu'"
                echo "======================================================================"
                /bin/bash -i >&3 2>&4 <&5 || true
                ;;
            c|C)
                clear 2>/dev/null || true
                continue
                ;;
            r|R)
                echo "Rebooting system..."
                sync
                reboot -f 2>/dev/null || systemctl reboot -ff 2>/dev/null || { echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true; echo b > /proc/sysrq-trigger 2>/dev/null || true; }
                return 0
                ;;
            p|P)
                echo "Powering off..."
                sync
                poweroff -f 2>/dev/null || systemctl poweroff -ff 2>/dev/null || { echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true; echo o > /proc/sysrq-trigger 2>/dev/null || true; }
                return 0
                ;;
            "")
                continue
                ;;
            *)
                local cmd_test cmd_ao
                read -r cmd_test cmd_ao <<< "$choice"

                if [ "$cmd_test" = "lab" ]; then
                    local lab_target="${cmd_ao:-lab1_exp}"
                    run_lab_benchmark "$lab_target"
                elif [ "$cmd_test" = "hw" ]; then
                    mkdir -p "$DATADIR/results"
                    puretest-hw "$DATADIR/results" 2>/dev/null || /usr/local/bin/puretest-hw "$DATADIR/results" 2>/dev/null || true
                    cat "$DATADIR/results/machine_specs.txt" 2>/dev/null || true
                elif [ "$cmd_test" = "ao" ] && [ -n "$cmd_ao" ]; then
                    if [ "$cmd_ao" = "all" ]; then
                        for t in $(list_tests); do run_test_all_ao "$t"; done
                    else
                        run_test_all_ao "$cmd_ao"
                    fi
                elif have_test "$cmd_test"; then
                    local target_ao="${cmd_ao:-$AO_LEVEL}"
                    run_test "$cmd_test" "$target_ao"
                else
                    echo "Unknown command or test: $choice"
                    echo "Type a test name, 'lab <testname>', 'ao <testname>', 'hw', or select an action [a/ao/lab/hw/o/l/s/c/q/r/p]."
                fi
                echo
                printf "Press Enter to return to menu... "
                read -r _ 2>/dev/null || true
                ;;
        esac
    done
}

# --------------------------------------------------------------------- main
mount_exec

# Diagnostic: show mount status and what's on DATADISK
log "DATADIR=$DATADIR mountpoint=$(mountpoint -q "$DATADIR" 2>/dev/null && echo YES || echo NO)"
log "TESTSDIR contents: $(ls "$TESTSDIR" 2>/dev/null | tr '\n' ' ' || echo '(empty or missing)')"

# 1. Allow full override of runner.sh directly from DATADISK (no image rebuild required)
if [ -f "$DATADIR/runner.sh" ] && [ "${PURETEST_RUNNER_OVERRIDDEN:-0}" -ne 1 ]; then
    log "Override runner detected at $DATADIR/runner.sh — transferring control to DATADISK runner..."
    export PURETEST_RUNNER_OVERRIDDEN=1
    exec /bin/bash "$DATADIR/runner.sh" "$@"
fi

# 2. Load runtime configuration from DATADISK if present
for cfg in "$DATADIR/config.env" "$DATADIR/puretest.conf"; do
    if [ -f "$cfg" ]; then
        log "Loading configuration from $cfg"
        # shellcheck disable=SC1090
        . "$cfg"
        break
    fi
done

# Re-apply CPU governor if customized in config.env
if [ -n "${GOVERNOR:-}" ] && [ "$GOVERNOR" != "performance" ]; then
    set_performance_mode "$GOVERNOR"
fi

# 3. Optional pre-run script on DATADISK
if [ -f "$DATADIR/scripts/pre_run.sh" ]; then
    log "Executing pre-run hook: $DATADIR/scripts/pre_run.sh"
    /bin/bash "$DATADIR/scripts/pre_run.sh" || log "WARNING: pre_run.sh returned non-zero"
fi

# 4. Check for AUTORUN or test list file on DATADISK
autorun_file=""
for f in "$DATADIR/AUTORUN" "$DATADIR/run_list.txt" "$DATADIR/tests.txt"; do
    if [ -f "$f" ]; then
        autorun_file="$f"
        break
    fi
done

if [ -n "$autorun_file" ]; then
    log "Found autorun file: $autorun_file"
    run_test_list "$autorun_file"

    # Optional post-run script on DATADISK
    if [ -f "$DATADIR/scripts/post_run.sh" ]; then
        log "Executing post-run hook: $DATADIR/scripts/post_run.sh"
        /bin/bash "$DATADIR/scripts/post_run.sh" || log "WARNING: post_run.sh returned non-zero"
    fi
    sync

    case "${AFTER_AUTORUN:-poweroff}" in
        reboot)
            if [ "$autorun_file" = "$DATADIR/AUTORUN" ]; then
                mv "$DATADIR/AUTORUN" "$DATADIR/AUTORUN.done" 2>/dev/null || true
                log "Notice: Renamed AUTORUN to AUTORUN.done to prevent infinite reboot loop"
            fi
            log "AFTER_AUTORUN=reboot: rebooting machine..."
            sync
            reboot -f 2>/dev/null || systemctl reboot -ff 2>/dev/null || { echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true; echo b > /proc/sysrq-trigger 2>/dev/null || true; }
            ;;
        menu)
            log "AFTER_AUTORUN=menu: returning to interactive menu..."
            menu
            ;;
        shell)
            log "AFTER_AUTORUN=shell: dropping to root shell..."
            /bin/bash -i >&3 2>&4 <&5 || true
            ;;
        poweroff|*)
            log "AFTER_AUTORUN=poweroff: shutting down machine..."
            sync
            poweroff -f 2>/dev/null || systemctl poweroff -ff 2>/dev/null || { echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true; echo o > /proc/sysrq-trigger 2>/dev/null || true; }
            ;;
    esac
else
    menu
fi