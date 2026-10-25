# ~/.bashrc for PureTestImage root shell

export PAGER="less -R"
export EDITOR="nano"
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

alias ll='ls -lah'
alias cheatsheet="/usr/local/bin/cheatsheet"
alias help="/usr/local/bin/cheatsheet"
alias menu="/opt/puretest/runner.sh"

CURRENT_TTY=$(tty 2>/dev/null || echo unknown)

echo
echo "======================================================================"
echo "  PURETESTIMAGE ROOT ENVIRONMENT ($CURRENT_TTY)"
echo "======================================================================"
echo "  Harness status : $(systemctl is-active puretest 2>/dev/null || echo unknown)"
echo "  DATADISK mount : $(mountpoint -q /data 2>/dev/null && echo 'MOUNTED on /data' || echo 'NOT mounted (offline mode)')"
echo
echo "  Diagnostic & Control Commands:"
echo "    puretest-status   - View service status, /tmp/puretest.log, mount state"
echo "    puretest-log      - Follow live log (/tmp/puretest.log)"
echo "    puretest-run      - Launch runner menu directly in this shell"
echo "    puretest-restart  - Restart puretest.service"
echo "    puretest-mount    - Force re-mount DATADISK to /data"
echo "    cheatsheet        - Read operator cheatsheet (or 'help')"
echo "    menu              - Launch runner menu"
echo "======================================================================"
echo
