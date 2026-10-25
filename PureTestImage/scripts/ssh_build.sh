#!/usr/bin/env bash
#
# ssh_build.sh - builds PureTestImage remotely over SSH from Linux/macOS.
#
# Usage:
#   ./scripts/ssh_build.sh
#   HOST=myserver.net ./scripts/ssh_build.sh
#   ./scripts/ssh_build.sh user@myserver.net:22
#
set -euo pipefail

# -----------------------------------------------------------------------------
# Terminal colors & logging helpers
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_GREEN='\033[32m'
    C_BLUE='\033[34m'
    C_YELLOW='\033[33m'
    C_RED='\033[31m'
    C_CYAN='\033[36m'
else
    C_RESET=''
    C_BOLD=''
    C_GREEN=''
    C_BLUE=''
    C_YELLOW=''
    C_RED=''
    C_CYAN=''
fi

log_info()  { echo -e "${C_BLUE}${C_BOLD}[*]${C_RESET} $*"; }
log_step()  { echo -e "\n${C_CYAN}${C_BOLD}=== $* ===${C_RESET}"; }
log_ok()    { echo -e "${C_GREEN}${C_BOLD}[✓]${C_RESET} $*"; }
log_warn()  { echo -e "${C_YELLOW}${C_BOLD}[!]${C_RESET} $*"; }
log_err()   { echo -e "${C_RED}${C_BOLD}[ERROR]${C_RESET} $*" >&2; }

# -----------------------------------------------------------------------------
# Locate paths
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/build.sh" ]; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [ -f "$SCRIPT_DIR/PureTestImage/scripts/build.sh" ]; then
    REPO_ROOT="$SCRIPT_DIR/PureTestImage"
    SCRIPT_DIR="$REPO_ROOT/scripts"
else
    REPO_ROOT="$(pwd)"
fi

# -----------------------------------------------------------------------------
# Configuration & Environment loading
# -----------------------------------------------------------------------------
REMOTE_USER="${REMOTE_USER:-ubuntu}"
HOST="${HOST:-192.168.1.100}"
PORT="${PORT:-22}"
REMOTE_DIR="${REMOTE_DIR:-~/PureTestImage}"
USE_CACHE="${USE_CACHE:-1}"

# Load config file if present (checks scripts/ and repo root)
CONFIG_FILE=""
for cfg in "$SCRIPT_DIR/ssh-build.env" "$SCRIPT_DIR/ssh_build.env" \
           "$REPO_ROOT/ssh-build.env" "$REPO_ROOT/ssh_build.env" \
           "$(pwd)/ssh-build.env" "$(pwd)/ssh_build.env"; do
    if [ -f "$cfg" ]; then
        CONFIG_FILE="$cfg"
        break
    fi
done

if [ -n "$CONFIG_FILE" ]; then
    log_info "Loading configuration from: $CONFIG_FILE"
    # shellcheck disable=SC1090
    set -a
    . "$CONFIG_FILE"
    set +a
fi

# Help message
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Usage: $0 [OPTIONS] [user@host[:port]]"
    echo
    echo "Builds PureTestImage remotely on an Ubuntu/Debian server over SSH,"
    echo "and downloads the resulting puretest.img."
    echo
    echo "Options:"
    echo "  -h, --help       Show this help message"
    echo "  --no-cache       Disable apt package cache on server (fresh download)"
    echo
    echo "Configuration:"
    echo "  Credentials can be loaded from scripts/ssh-build.env or passed as environment"
    echo "  variables (REMOTE_USER, HOST, PORT, REMOTE_DIR, USE_CACHE)."
    echo
    echo "Examples:"
    echo "  $0"
    echo "  $0 ubuntu@192.168.1.50"
    echo "  $0 ubuntu@192.168.1.50:2222"
    echo "  HOST=10.0.0.5 PORT=22 $0"
    exit 0
fi

# Support --no-cache
if [ "${1:-}" = "--no-cache" ]; then
    USE_CACHE=0
    shift || true
fi

# Support CLI argument override: user@host[:port]
if [ "${1:-}" != "" ] && [[ "${1:-}" != -* ]]; then
    target="$1"
    if [[ "$target" =~ ^([^@]+)@([^:]+)(:([0-9]+))?$ ]]; then
        REMOTE_USER="${BASH_REMATCH[1]}"
        HOST="${BASH_REMATCH[2]}"
        [ -n "${BASH_REMATCH[4]}" ] && PORT="${BASH_REMATCH[4]}"
    elif [[ "$target" =~ ^([^:]+)(:([0-9]+))?$ ]]; then
        HOST="${BASH_REMATCH[1]}"
        [ -n "${BASH_REMATCH[3]}" ] && PORT="${BASH_REMATCH[3]}"
    fi
    shift || true
fi

# Validate host configuration
if [ "$HOST" = "192.168.1.100" ] && [ -z "$CONFIG_FILE" ]; then
    log_warn "Default host '192.168.1.100' detected."
    echo -e "    To configure your server credentials:"
    echo -e "    1. Copy ${C_BOLD}scripts/ssh-build.env.example${C_RESET} to ${C_BOLD}scripts/ssh-build.env${C_RESET}"
    echo -e "    2. Edit your server IP, user and port in ${C_BOLD}scripts/ssh-build.env${C_RESET}"
    echo -e "    Or run: ${C_BOLD}./ssh_build.sh user@myserver.com:22${C_RESET}\n"
    if [ -t 0 ]; then
        read -r -p "Enter server host/IP (or press Ctrl+C to abort): " input_host
        if [ -n "$input_host" ]; then
            HOST="$input_host"
        else
            log_err "Server host is required."
            exit 1
        fi
    else
        log_err "Non-interactive shell: please configure HOST in scripts/ssh-build.env or pass user@host as argument."
        exit 1
    fi
fi

# Normalize REMOTE_DIR: strip leading ~/ so paths are evaluated relative to remote $HOME
ORIG_REMOTE_DIR="$REMOTE_DIR"
if [[ "$REMOTE_DIR" == "~/"* ]]; then
    REMOTE_DIR="${REMOTE_DIR#\~/}"
elif [ "$REMOTE_DIR" = "~" ]; then
    REMOTE_DIR="."
fi

SSH_CMD=(ssh -p "$PORT" -o ConnectTimeout=15 "$REMOTE_USER@$HOST")
SCP_CMD=(scp -P "$PORT" -o ConnectTimeout=15)

echo
echo -e "${C_BOLD}=== PureTestImage: Remote Build over SSH ===${C_RESET}"
echo -e "  Target Host : ${C_GREEN}$REMOTE_USER@$HOST:$PORT${C_RESET}"
echo -e "  Remote Dir  : ${C_GREEN}$ORIG_REMOTE_DIR${C_RESET}"
echo -e "  Package Cache: $([ "$USE_CACHE" = "1" ] && echo "Enabled (USE_CACHE=1)" || echo "Disabled (fresh download)")"
echo

# -----------------------------------------------------------------------------
# Step 0a: Verify SSH connectivity
# -----------------------------------------------------------------------------
log_info "[0/3] Checking SSH connection to $REMOTE_USER@$HOST:$PORT ..."
if ! "${SSH_CMD[@]}" -o BatchMode=yes "echo ok" >/dev/null 2>&1; then
    # Test if host is reachable with interactive prompt (e.g. password or key confirmation)
    if ! "${SSH_CMD[@]}" "echo ok" >/dev/null 2>&1; then
        log_err "Cannot connect to $REMOTE_USER@$HOST:$PORT"
        echo "      Check that the server is online, your SSH key/password is correct,"
        echo "      and port $PORT is open."
        exit 1
    fi
fi
log_ok "SSH connection OK"

# -----------------------------------------------------------------------------
# Step 0b: Check & configure passwordless sudo on remote server
# -----------------------------------------------------------------------------
log_info "Checking remote sudo access ..."
if ! "${SSH_CMD[@]}" -o BatchMode=yes "sudo -n true" >/dev/null 2>&1; then
    echo
    log_warn "Passwordless sudo is NOT configured for $REMOTE_USER on the server."
    echo "       Configuring it now via scripts/setup-sudo.sh (you will be asked for sudo password ONCE)..."
    echo
    "${SCP_CMD[@]}" "$SCRIPT_DIR/setup-sudo.sh" "$REMOTE_USER@$HOST:/tmp/setup-sudo.sh"
    ssh -t -p "$PORT" "$REMOTE_USER@$HOST" "bash /tmp/setup-sudo.sh; rm -f /tmp/setup-sudo.sh"
    
    # Verify sudo
    if ! "${SSH_CMD[@]}" -o BatchMode=yes "sudo -n true" >/dev/null 2>&1; then
        log_err "Passwordless sudo is still not working after setup."
        exit 1
    fi
fi
log_ok "Passwordless sudo access OK"

# -----------------------------------------------------------------------------
# Step 0c: Clean leftovers from previous aborted builds safely
# -----------------------------------------------------------------------------
"${SSH_CMD[@]}" "sudo bash -c 'for m in \$(findmnt -rn -o TARGET 2>/dev/null | grep \"/tmp/tmp\.\"); do umount -l \"\$m\" 2>/dev/null; done'; rm -rf './~' 2>/dev/null || true"

# -----------------------------------------------------------------------------
# Step 1: Sync sources to server
# -----------------------------------------------------------------------------
log_step "[1/3] Syncing sources to server"
"${SSH_CMD[@]}" "mkdir -p \"$REMOTE_DIR\""

if command -v rsync >/dev/null 2>&1; then
    log_info "Syncing via rsync..."
    rsync -avz --delete \
        -e "ssh -p $PORT" \
        --exclude='.git' \
        --exclude='.cache' \
        --exclude='output' \
        --exclude='*.img' \
        --exclude='*.tar.gz' \
        --exclude='*.obj' \
        --exclude='*.exe' \
        --exclude='*.env' \
        "$REPO_ROOT/" "$REMOTE_USER@$HOST:$REMOTE_DIR/"
else
    log_info "rsync not found locally; syncing via scp..."
    "${SSH_CMD[@]}" "rm -rf \"$REMOTE_DIR/board\" \"$REMOTE_DIR/scripts\" \"$REMOTE_DIR/tests\""
    "${SCP_CMD[@]}" -r \
        "$REPO_ROOT/scripts" \
        "$REPO_ROOT/board" \
        "$REPO_ROOT/tests" \
        "$REPO_ROOT/README.md" \
        "$REPO_ROOT/config.env" \
        "$REPO_ROOT/run_list.txt" \
        "$REMOTE_USER@$HOST:$REMOTE_DIR/"
fi
log_ok "Source synchronization complete"

# -----------------------------------------------------------------------------
# Step 2: Run remote build
# -----------------------------------------------------------------------------
log_step "[2/3] Running build.sh on remote server"
"${SSH_CMD[@]}" -t "cd \"$REMOTE_DIR\" && sudo USE_CACHE=\"$USE_CACHE\" bash scripts/build.sh"
log_ok "Remote build succeeded"

# -----------------------------------------------------------------------------
# Step 3: Download compressed archive & extract
# -----------------------------------------------------------------------------
log_step "[3/3] Downloading built image"
LOCAL_OUT="$REPO_ROOT/output"
mkdir -p "$LOCAL_OUT"

REMOTE_ARCHIVE="$REMOTE_DIR/output/puretest.img.tar.gz"
LOCAL_ARCHIVE="$LOCAL_OUT/puretest.img.tar.gz"

log_info "Downloading $REMOTE_ARCHIVE ..."
if command -v rsync >/dev/null 2>&1; then
    rsync -avz --progress -e "ssh -p $PORT" "$REMOTE_USER@$HOST:$REMOTE_ARCHIVE" "$LOCAL_ARCHIVE"
else
    "${SCP_CMD[@]}" "$REMOTE_USER@$HOST:$REMOTE_ARCHIVE" "$LOCAL_ARCHIVE"
fi

log_info "Extracting puretest.img from archive..."
if command -v pigz >/dev/null 2>&1; then
    tar -I pigz -xf "$LOCAL_ARCHIVE" -C "$LOCAL_OUT"
else
    tar -xzf "$LOCAL_ARCHIVE" -C "$LOCAL_OUT"
fi

RAW_IMG="$LOCAL_OUT/puretest.img"
if [ -f "$RAW_IMG" ]; then
    log_ok "Extracted: $RAW_IMG ($(du -h "$RAW_IMG" | cut -f1))"
else
    log_warn "puretest.img not found after extraction, check $LOCAL_ARCHIVE"
fi

# -----------------------------------------------------------------------------
# Done & Instructions
# -----------------------------------------------------------------------------
echo
echo -e "${C_GREEN}${C_BOLD}======================================================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}  BUILD & DOWNLOAD COMPLETE!${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}======================================================================${C_RESET}"
echo -e "  Raw Image   : ${C_BOLD}$RAW_IMG${C_RESET} ($(du -h "$RAW_IMG" 2>/dev/null | cut -f1 || echo '-'))"
echo -e "  Archive     : ${C_BOLD}$LOCAL_ARCHIVE${C_RESET} ($(du -h "$LOCAL_ARCHIVE" 2>/dev/null | cut -f1 || echo '-'))"
echo
echo -e "  ${C_BOLD}Flash to USB drive:${C_RESET}"
echo -e "    ${C_CYAN}sudo dd if=$RAW_IMG of=/dev/sdX bs=4M status=progress conv=fsync${C_RESET}"
echo -e "    ${C_YELLOW}(Double-check /dev/sdX carefully before running dd!)${C_RESET}"
echo -e "    ${C_CYAN}Windows: Rufus -> select puretest.img -> 'DD Image' mode${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}======================================================================${C_RESET}"
echo
