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

# Ensure logging to /tmp/puretest.log for troubleshooting
LOGFILE="/tmp/puretest.log"
exec > >(tee -a "$LOGFILE") 2>&1

DATADIR=/data
TESTSDIR="$DATADIR/tests"
RESULTSDIR="$DATADIR/results"
RUNS="${RUNS:-3}"            # number of timing repetitions
TIMEOUT="${TIMEOUT:-600}"    # seconds per run (busybox/coreutils timeout)
FLAGS="${FLAGS:--O2 -march=native}"
export TERM="${TERM:-linux}"

# ---------------------------------------------------------------- machine id
MACHINE=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
CPUS=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
CPU=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: *//' || echo unknown)
MEM=$(awk '/^MemTotal:/ {print int($2/1024)" MiB"}' /proc/meminfo 2>/dev/null || echo unknown)

log() { echo "[puretest] $*"; }

log "=========================================================="
log "PureTestImage Harness Starting"
log "Timestamp: $(date -u +'%Y-%m-%d %H:%M:%SZ' 2>/dev/null || date)"
log "Terminal : $(tty 2>/dev/null || echo 'non-tty')"
log "Machine  : $MACHINE | $CPUS cores ($CPU) | $MEM RAM"
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
# Wait for the DATADISK partition to appear (USB controllers can take a few
# seconds after kernel init) and mount it. If fstab/systemd already mounted
# it we just verify the mount point, no double-mount.
mount_exec() {
    # Already mounted (by fstab or a previous run)?
    if mountpoint -q "$DATADIR" 2>/dev/null; then
        log "DATADISK already mounted on $DATADIR"
        mkdir -p "$TESTSDIR" "$RESULTSDIR"
        return 0
    fi

    # Wait up to 10 seconds for the block device to appear
    log "Probing for partition labeled 'DATADISK' (up to 10s)..."
    local tries=0
    while [ "$tries" -lt 20 ]; do
        if blkid -L DATADISK >/dev/null 2>&1; then
            log "Found DATADISK device: $(blkid -L DATADISK 2>/dev/null)"
            break
        fi
        tries=$((tries + 1))
        sleep 0.5
    done

    mkdir -p "$DATADIR"
    if mount -L DATADISK "$DATADIR" 2>/dev/null; then
        log "DATADISK successfully mounted on $DATADIR"
    else
        log "WARNING: DATADISK partition not found; using RAM fallback /tmp/data"
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

# ------------------------------------------------------------------ compile
compile_test() { # $1 = test dir (path), $2 = workdir
    local srcdir="$1" work="$2"
    local flags="$FLAGS"
    rm -rf "$work"; mkdir -p "$work"

    # 1. Script test: if run.sh is provided, copy test assets and use it directly
    if [ -f "$srcdir/run.sh" ]; then
        cp -a "$srcdir"/* "$work/" 2>/dev/null || true
        chmod +x "$work/run.sh"
        echo "Script runner detected: run.sh" > "$work/build.log"
        log "using script test: run.sh"
        return 0
    fi

    # 2. Makefile test: if Makefile is provided, run make
    if [ -f "$srcdir/Makefile" ] || [ -f "$srcdir/makefile" ]; then
        cp -a "$srcdir"/* "$work/" 2>/dev/null || true
        log "building with Makefile"
        ( cd "$work" && make ) >"$work/build.log" 2>&1
        if [ -x "$work/test" ] || [ -x "$work/run" ]; then
            log "build OK"
            return 0
        else
            log "ERROR: make build failed (see build.log)"
            return 1
        fi
    fi

    # 3. Native C++ compilation
    if [ -f "$srcdir/build.flags" ]; then
        flags="$flags $(head -1 "$srcdir/build.flags")"
    fi

    if ! cp "$srcdir"/*.cpp "$work" 2>/dev/null; then :; fi
    if ! cp "$srcdir"/*.cc  "$work" 2>/dev/null; then :; fi
    if ! cp "$srcdir"/*.cxx "$work" 2>/dev/null; then :; fi

    cpp_count=$(ls "$work"/*.cpp "$work"/*.cc "$work"/*.cxx 2>/dev/null | wc -l)
    if [ "$cpp_count" -eq 0 ]; then
        log "ERROR: no C++ sources or run.sh in $srcdir"
        return 1
    fi

    log "compiling: g++ $flags ($cpp_count file(s))"
    # Collect only the source files that actually exist; passing an unexpanded
    # glob like '*.cc' when no .cc files are present would make g++ fail with
    # "no such file".
    srcs=$(ls "$work"/*.cpp "$work"/*.cc "$work"/*.cxx 2>/dev/null)
    # shellcheck disable=SC2086
    ( cd "$work" && g++ $flags -o ./test $srcs ) \
        >"$work/build.log" 2>&1
    [ -x "$work/test" ] || { log "ERROR: build failed (see build.log)"; return 1; }
    log "build OK"
    return 0
}

# --------------------------------------------------------------------- run
# Times a single execution of the test binary or script. /usr/bin/time -f prints
# "REAL USER SYS" (elapsed/user/system, seconds) to $work/.time and lets
# the command's exit status through. Returns: client status; sets TIMING.
run_once() { # $1 = workdir
    local work="$1"
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
        # shellcheck disable=SC2086
        set -- ${RUNARGS:-}
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
    return "$rc"
}

# ------------------------------------------------------------------ report
write_report() { # $1 = testname, $2 = resultdir
    cat > "$2/report.txt" <<EOF
Test       : $1
Machine    : $MACHINE
CPU        : $CPU
Cores      : $CPUS
Memory     : $MEM
Compiler   : $(g++ --version 2>/dev/null | head -1)
Flags      : $FLAGS
Timestamp  : $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
-- runs (real user sys seconds) --
$(cat "$2/times.txt")
EOF
    {
        printf '%s\t%s\t%s\t%s\t%s\t' \
            "$(date -u +%Y%m%d_%H%M%S)" "$MACHINE" "$CPU" "$CPUS" "$1"
        tr '\n' '\t' < "$2/times.txt"; echo
    } >> "$RESULTSDIR/summary.tsv"
    sync
}

run_test() { # $1 = test name
    have_test "$1" || { log "no such test: $1"; return 1; }
    local name="$1"
    local srcdir="$TESTSDIR/$name"
    local work="/tmp/w-$name"
    local now resdir
    now=$(date -u +%Y%m%d-%H%M%S 2>/dev/null || date +%s)
    resdir="$RESULTSDIR/$MACHINE/$name-$now"
    mkdir -p "$resdir"

    log "=== running test '$name' ==="
    compile_test "$srcdir" "$work" || return 1
    set_performance_mode

    RUNARGS=""
    [ -f "$srcdir/run.args" ] && RUNARGS=$(cat "$srcdir/run.args")
    export STDIN_FILE=""
    [ -f "$srcdir/run.stdin" ] && STDIN_FILE="$srcdir/run.stdin"

    : > "$resdir/times.txt"
    local i rc
    i=0
    while [ "$i" -lt "$RUNS" ]; do
        i=$((i+1))
        log "run $i/$RUNS"
        TIMING=""
        if run_once "$work"; then
            rc=0
        else
            rc=$?
        fi
        [ -n "$TIMING" ] && printf 'run_%s\t%s\texit=%s\n' "$i" "$TIMING" "$rc" \
            >> "$resdir/times.txt"
        [ "$rc" -ne 0 ] && log "WARNING: run $i exited $rc (124 = timeout)"
    done

    cp "$work/build.log" "$resdir/build.log" 2>/dev/null || true
    cp "$work/run.out"   "$resdir/run.out"   2>/dev/null || true
    cp "$work/run.err"   "$resdir/run.err"   2>/dev/null || true

    # Save results to out.txt in result dir and directly inside test folder
    cp "$work/run.out"   "$resdir/out.txt"   2>/dev/null || true
    cp "$work/run.out"   "$srcdir/out.txt"   2>/dev/null || true

    # Append results of each test into DATADISK root out.txt
    if [ -f "$work/run.out" ]; then
        {
            echo "================================================================================"
            echo "TEST      : $name"
            echo "MACHINE   : $MACHINE ($CPUS cores, $CPU)"
            echo "TIMESTAMP : $(date -u +'%Y-%m-%d %H:%M:%SZ' 2>/dev/null || date)"
            echo "--------------------------------------------------------------------------------"
            cat "$work/run.out"
            echo
        } >> "$DATADIR/out.txt" 2>/dev/null || true
    fi

    write_report "$name" "$resdir"
    sync
    log "=== done; report: ${resdir}/report.txt ==="
    log "=== results saved to: ${srcdir}/out.txt and ${DATADIR}/out.txt ==="
    return 0
}

run_all_tests() {
    log "=== running ALL available tests ==="
    local t
    for t in $(list_tests); do
        echo
        log ">>> Starting test suite: $t <<<"
        run_test "$t"
    done
    sync
    echo
    log "=== ALL tests completed ==="
}

# ------------------------------------------------------------------ test list
# Reads a list of test names from a file (e.g. AUTORUN, run_list.txt).
# Ignores '#' comments, blank lines, strips Windows CRLF, and handles space/comma separated names.
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
    for t in $items; do
        if [ "$t" = "ALL" ] || [ "$t" = "all" ]; then
            run_all_tests
        elif have_test "$t"; then
            echo
            log ">>> Starting test: $t <<<"
            run_test "$t"
        else
            log "WARNING: test '$t' listed in $file not found in $TESTSDIR"
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
        echo "PURETESTIMAGE  ($MACHINE | $CPUS cores | $MEM)"
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
        echo "  [a] Run ALL tests (batch mode)"
        echo "  [l] Run test list from run_list.txt / AUTORUN"
        echo "  [s] Drop to interactive root shell"
        echo "  [c] Clear screen"
        echo "  [q] Exit to shell"
        echo "  [r] Reboot machine"
        echo "  [p] Power off"
        echo "Or type a test name and press Enter."
        echo "----------------------------------------------------------"
        printf "puretest> "
        if ! read -r choice; then
            log "Notice: console input returned EOF; waiting 3s before retry..."
            sleep 3
            continue
        fi
        case "$choice" in
            a|A)
                run_all_tests
                echo
                printf "Press Enter to return to menu... "
                read -r _ 2>/dev/null || true
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
                echo
                /bin/bash -i || true
                ;;
            c|C)
                clear 2>/dev/null || true
                continue
                ;;
            r|R)
                echo "Rebooting system..."
                sync
                reboot
                return 0
                ;;
            p|P)
                echo "Powering off..."
                sync
                poweroff
                return 0
                ;;
            "")
                continue
                ;;
            *)
                run_test "$choice"
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
            log "AFTER_AUTORUN=reboot: rebooting machine..."
            reboot
            ;;
        menu)
            log "AFTER_AUTORUN=menu: returning to interactive menu..."
            menu
            ;;
        shell)
            log "AFTER_AUTORUN=shell: dropping to root shell..."
            /bin/bash -i || true
            ;;
        poweroff|*)
            log "AFTER_AUTORUN=poweroff: shutting down machine..."
            poweroff
            ;;
    esac
else
    menu
fi