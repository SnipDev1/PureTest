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
    local gov="${1:-performance}"
    log "Configuring CPU governor to '$gov'..."
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$g" ] && echo "$gov" > "$g" 2>/dev/null || true
    done
    for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        [ -f "$epp" ] && echo "$gov" > "$epp" 2>/dev/null || true
    done
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
            if run_once "$work" "$i"; then
                if [ -n "$TIMING" ]; then
                    read -r r u s <<< "$TIMING"
                    t_real="$r"
                    t_user="$u"
                fi
            else
                log "WARNING: Run $i failed (exit $?)"
            fi

            cp "$work/run.out" "$all_resdir/$lvl/run_${i}.out" 2>/dev/null || true
            cp "$work/run.err" "$all_resdir/$lvl/run_${i}.err" 2>/dev/null || true

            {
                if [ "$RUNS" -gt 1 ]; then
                    echo "================================================================================"
                    echo "RUN $i/$RUNS [AO: $lvl]  (Real: ${t_real}s)"
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

run_test() { # $1 = test name, $2 = optional ao_level
    have_test "$1" || { log "no such test: $1"; return 1; }
    local name="$1"
    local req_ao="${2:-$AO_LEVEL}"

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
            echo "$found" | sed 's/^/  * /'
        else
            echo "  (no tests found in $TESTSDIR)"
        fi
        echo
        echo "Actions:"
        echo "  [a]  Run ALL tests (current AO: $AO_LEVEL)"
        echo "  [ao] Run test across ALL AO levels (O0..Ofast comparison matrix)"
        echo "  [o]  Change AO (Optimization) level [Current: $AO_LEVEL]"
        echo "  [l]  Run test list from run_list.txt / AUTORUN"
        echo "  [s]  Drop to interactive root shell"
        echo "  [c]  Clear screen"
        echo "  [q]  Exit to shell"
        echo "  [r]  Reboot machine"
        echo "  [p]  Power off"
        echo "Or type: <testname> [AO]  (e.g. 'bench_cpu', 'bench_cpu O3', 'bench_cpu all')"
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

                if [ "$cmd_test" = "ao" ] && [ -n "$cmd_ao" ]; then
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
                    echo "Type a test name, 'ao <testname>', or select an action [a/ao/o/l/s/c/q/r/p]."
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