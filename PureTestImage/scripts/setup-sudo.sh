#!/bin/sh
# setup-sudo.sh - safely configures passwordless sudo for the current user.
# Called automatically by ssh-build.bat on first run.
set -e
U=$(whoami)
TMP_SUDO=$(mktemp)
echo "$U ALL=(ALL) NOPASSWD: ALL" > "$TMP_SUDO"
if sudo visudo -cf "$TMP_SUDO" >/dev/null 2>&1; then
    sudo install -m 0440 "$TMP_SUDO" "/etc/sudoers.d/99-puretest-$U"
    rm -f "$TMP_SUDO"
    echo "OK: passwordless sudo configured for $U"
else
    rm -f "$TMP_SUDO"
    echo "ERROR: visudo validation failed, aborted to protect system." >&2
    exit 1
fi

