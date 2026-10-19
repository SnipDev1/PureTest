#!/bin/sh
# setup-sudo.sh - configures passwordless sudo for the current user.
# Called automatically by ssh-build.bat on first run.
set -e
U=$(whoami)
echo "$U ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$U >/dev/null
sudo chmod 440 /etc/sudoers.d/$U
echo "OK: passwordless sudo configured for $U"
