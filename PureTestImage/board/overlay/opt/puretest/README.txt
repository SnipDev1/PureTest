PureTestImage - how to add C++ tests to the stick
=================================================

After you write the image to a USB stick, Windows will show a new FAT32
drive named DATADISK. Put your tests there:

    DATADISK\
        tests\
            mytest\
                run.sh           <- OPTIONAL: bash script (if not compiling C++)
                bench.cpp        <- OR one or more .cpp/.cc/.cxx sources
                build.flags      <- OPTIONAL: extra g++ flags, single line
                run.args         <- OPTIONAL: extra command-line args
                run.stdin        <- OPTIONAL: file piped to the binary's stdin
        AUTORUN                  <- OPTIONAL: put test name (or 'ALL') here for
                                     unattended runs; powers off after finishing.

When you boot from the stick the menu shows available tests and actions:
  [a] Run ALL tests in sequence (batch mode)
  [s] Drop to interactive root shell (bash)
  [r] Reboot machine
  [p] Power off
  Or type a test name to run it individually.

If a test has run.sh, it executes directly. If it has C++ sources, it compiles
ON THIS MACHINE with:

    g++ -O2 -march=native [build.flags] -o test *.cpp *.cc *.cxx

then runs it RUNS times (default 3) under `timeout` (default 600 s) and
writes, to DATADISK\results\<machine>\<test>-<timestamp>\:

    report.txt    human-readable summary (machine, CPU, memory, timings)
    build.log     compiler output
    run.out       program stdout of the last run
    run.err       program stderr
    times.txt     per-run times

and appends a single line per test to DATADISK\results\summary.tsv.

Runtime knobs (edit /opt/puretest/runner.sh or export before running):
    RUNS=5 TIMEOUT=900 FLAGS="-O3 -march=native -ffast-math"

Tuning tips
-----------
- Timings come from GNU /usr/bin/time (real/user/sys, decimal seconds);
  repeat runs to smooth out noise.
- Close background load on the machine before benchmarking.
- If a test miscompiles with -march=native on the oldest machine you test
  on, drop to -march=x86-64-v2 in FLAGS.