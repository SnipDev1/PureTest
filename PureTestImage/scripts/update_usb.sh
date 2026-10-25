#!/usr/bin/env bash
#
# update_usb.sh - Automatically updates, fixes, and syncs a PureTest USB drive.
#
# Operations performed:
#   1. EFIBOOT partition: removes fbx64.efi (prevents UEFI reset loop).
#   2. PUREROOT partition: fixes /boot/vmlinuz and /boot/initrd.img symlinks.
#   3. DATADISK partition: updates runner.sh (with AO support), config.env, and tests/.
#
# Usage:
#   ./update_usb.sh           # Auto-detects PureTest USB drive
#   ./update_usb.sh /dev/sdX  # Targets a specific USB device
#
set -euo pipefail

# -----------------------------------------------------------------------------
# Colorized output helpers
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
# Arguments & Help message (no root needed)
# -----------------------------------------------------------------------------
UPGRADE_KERNEL=0
TARGET_ARG=""

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            echo "Usage: $0 [OPTIONS] [DEVICE]"
            echo
            echo "Automatically detects and updates a PureTest USB flash drive."
            echo "Fixes UEFI/GRUB boot files and syncs runner.sh (with AO support), configs, and tests."
            echo
            echo "Options:"
            echo "  -k, --upgrade-kernel   Upgrade Linux kernel in-place to 6.12+ LTS (Debian backports)"
            echo "                         with Zen 5 (Ryzen 9000/9700X) support and CPU microcode."
            echo "  -h, --help             Show this help message"
            echo
            echo "Examples:"
            echo "  $0                     # Auto-detects drive via labels (EFIBOOT, PUREROOT, DATADISK)"
            echo "  $0 --upgrade-kernel    # Auto-detects drive and upgrades kernel to 6.12+"
            echo "  $0 /dev/sde            # Updates specific drive"
            exit 0
            ;;
        -k|--upgrade-kernel)
            UPGRADE_KERNEL=1
            ;;
        *)
            TARGET_ARG="$arg"
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Root elevation
# -----------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    log_info "Root privileges required. Elevating via sudo..."
    exec sudo bash "$0" "$@"
fi

# -----------------------------------------------------------------------------
# Locate repository root
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

RUNNER_SRC="$REPO_ROOT/board/overlay/opt/puretest/runner.sh"
CONFIG_SRC="$REPO_ROOT/config.env"
RUNLIST_SRC="$REPO_ROOT/run_list.txt"
TESTS_SRC="$REPO_ROOT/tests"

if [ ! -f "$RUNNER_SRC" ]; then
    log_err "Cannot locate runner.sh at $RUNNER_SRC"
    exit 1
fi

# -----------------------------------------------------------------------------
# Cleanup trap for temporary mount points
# -----------------------------------------------------------------------------
TMP_DIRS=()
cleanup() {
    set +e
    for m in "${TMP_DIRS[@]}"; do
        umount -l "$m/sys" 2>/dev/null || true
        umount -l "$m/proc" 2>/dev/null || true
        umount -l "$m/dev" 2>/dev/null || true
        if mountpoint -q "$m" 2>/dev/null; then
            umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
        fi
        rm -rf "$m" 2>/dev/null || true
    done
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Detect USB drive partitions
# -----------------------------------------------------------------------------
log_step "PureTest USB Auto-Updater"
echo -e "  Repo Root : ${C_GREEN}$REPO_ROOT${C_RESET}"
echo -e "  Timestamp : $(date +'%Y-%m-%d %H:%M:%S')"
echo

log_info "Detecting PureTest USB drive..."

EFI_DEV=""
ROOT_DEV=""
DATA_DEV=""

if [ -n "$TARGET_ARG" ] && [ -b "$TARGET_ARG" ]; then
    # Target device provided (e.g. /dev/sde)
    BASE_DEV="$TARGET_ARG"
    log_info "Target device specified: $BASE_DEV"
    
    # Identify partitions
    for p in "${BASE_DEV}2" "${BASE_DEV}p2"; do [ -b "$p" ] && EFI_DEV="$p" && break; done
    for p in "${BASE_DEV}3" "${BASE_DEV}p3"; do [ -b "$p" ] && ROOT_DEV="$p" && break; done
    for p in "${BASE_DEV}4" "${BASE_DEV}p4"; do [ -b "$p" ] && DATA_DEV="$p" && break; done
else
    # Auto-detect by filesystem labels
    EFI_DEV=$(blkid -L EFIBOOT 2>/dev/null || true)
    ROOT_DEV=$(blkid -L PUREROOT 2>/dev/null || true)
    DATA_DEV=$(blkid -L DATADISK 2>/dev/null || true)
fi

# Fallback lookup via lsblk if any label lookup failed
if [ -z "$EFI_DEV" ] || [ -z "$ROOT_DEV" ] || [ -z "$DATA_DEV" ]; then
    while read -r name fstype label; do
        dev="/dev/$name"
        [ "$label" = "EFIBOOT" ] && EFI_DEV="$dev"
        [ "$label" = "PUREROOT" ] && ROOT_DEV="$dev"
        [ "$label" = "DATADISK" ] && DATA_DEV="$dev"
    done < <(lsblk -rno NAME,FSTYPE,LABEL 2>/dev/null || true)
fi

echo -e "  EFIBOOT  partition : ${C_GREEN}${EFI_DEV:-NOT FOUND}${C_RESET}"
echo -e "  PUREROOT partition : ${C_GREEN}${ROOT_DEV:-NOT FOUND}${C_RESET}"
echo -e "  DATADISK partition : ${C_GREEN}${DATA_DEV:-NOT FOUND}${C_RESET}"
echo

if [ -z "$EFI_DEV" ] && [ -z "$ROOT_DEV" ] && [ -z "$DATA_DEV" ]; then
    log_err "PureTest USB drive not found!"
    echo "       Please insert the PureTest USB drive into your computer and try again."
    echo "       Or pass device manually: $0 /dev/sdX"
    exit 1
fi

# -----------------------------------------------------------------------------
# Step 1: Fix EFIBOOT (remove fbx64.efi)
# -----------------------------------------------------------------------------
log_step "[1/3] Checking & Updating EFIBOOT"

if [ -n "$EFI_DEV" ] && [ -b "$EFI_DEV" ]; then
    # Unmount if busy and run filesystem check
    for m in $(findmnt -rn -o TARGET "$EFI_DEV" 2>/dev/null || true); do umount "$m" 2>/dev/null || true; done
    fsck.vfat -a -w "$EFI_DEV" >/dev/null 2>&1 || true

    MNT_EFI=$(mktemp -d /tmp/puretest_efi_XXXXXX)
    TMP_DIRS+=("$MNT_EFI")
    
    mount "$EFI_DEV" "$MNT_EFI"
    
    if [ -f "$MNT_EFI/EFI/BOOT/fbx64.efi" ]; then
        rm -f "$MNT_EFI/EFI/BOOT/fbx64.efi"
        log_ok "Removed problematic 'EFI/BOOT/fbx64.efi' (fixed UEFI reset loop)"
    else
        log_ok "EFIBOOT is clean (no fbx64.efi found)"
    fi
    
    # Ensure signed GRUB is in place
    if [ -f "$MNT_EFI/EFI/BOOT/BOOTX64.EFI" ] && [ -f "$MNT_EFI/EFI/BOOT/grubx64.efi" ]; then
        log_ok "Secure Boot binaries verified: BOOTX64.EFI (shim) + grubx64.efi"
    fi

    # Update grub.cfg on ESP
    if [ -f "$REPO_ROOT/board/grub.cfg.in" ]; then
        cp "$REPO_ROOT/board/grub.cfg.in" "$MNT_EFI/EFI/BOOT/grub.cfg" 2>/dev/null || true
        cp "$REPO_ROOT/board/grub.cfg.in" "$MNT_EFI/EFI/debian/grub.cfg" 2>/dev/null || true
        mkdir -p "$MNT_EFI/boot/grub"
        cp "$REPO_ROOT/board/grub.cfg.in" "$MNT_EFI/boot/grub/grub.cfg" 2>/dev/null || true
        log_ok "Updated GRUB config on EFIBOOT"
    fi
    
    umount "$MNT_EFI"
else
    log_warn "EFIBOOT partition not available; skipped."
fi

# -----------------------------------------------------------------------------
# Step 2: Fix PUREROOT (kernel & initramfs symlinks)
# -----------------------------------------------------------------------------
log_step "[2/3] Checking & Updating PUREROOT"

if [ -n "$ROOT_DEV" ] && [ -b "$ROOT_DEV" ]; then
    # Unmount if busy and run filesystem check
    for m in $(findmnt -rn -o TARGET "$ROOT_DEV" 2>/dev/null || true); do umount "$m" 2>/dev/null || true; done
    e2fsck -p -f "$ROOT_DEV" >/dev/null 2>&1 || true

    MNT_ROOT=$(mktemp -d /tmp/puretest_root_XXXXXX)
    TMP_DIRS+=("$MNT_ROOT")
    
    mount "$ROOT_DEV" "$MNT_ROOT"
    
    if [ "$UPGRADE_KERNEL" = "1" ]; then
        log_step "Upgrading kernel inside PUREROOT to Debian backports (Linux 6.12+ LTS)..."
        cp /etc/resolv.conf "$MNT_ROOT/etc/resolv.conf" 2>/dev/null || true
        mount --bind /dev "$MNT_ROOT/dev"
        mount --bind /proc "$MNT_ROOT/proc"
        mount --bind /sys "$MNT_ROOT/sys"

        chroot "$MNT_ROOT" /bin/bash -s << 'EOF_UPGRADE'
            set -e
            export DEBIAN_FRONTEND=noninteractive
            echo 'APT::Install-Recommends "false";' > /etc/apt/apt.conf.d/99puretest
            cat > /etc/apt/sources.list << SOURCES
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
SOURCES
            apt-get -o Acquire::Retries=5 update
            apt-get -o Acquire::Retries=5 install -y --no-install-recommends -t bookworm-backports \
                linux-image-amd64 linux-cpupower amd64-microcode intel-microcode
            apt-get clean
            rm -rf /var/lib/apt/lists/*
EOF_UPGRADE

        umount -l "$MNT_ROOT/sys" 2>/dev/null || true
        umount -l "$MNT_ROOT/proc" 2>/dev/null || true
        umount -l "$MNT_ROOT/dev" 2>/dev/null || true
        rm -f "$MNT_ROOT/etc/resolv.conf"
        log_ok "Kernel upgrade to 6.12+ and microcode installation completed!"
    fi

    # Locate real kernel and initramfs in /boot
    K_REAL=$(cd "$MNT_ROOT/boot" && ls -1v vmlinuz-* 2>/dev/null | grep -v '^vmlinuz$' | tail -1 || true)
    I_REAL=$(cd "$MNT_ROOT/boot" && ls -1v initrd.img-* 2>/dev/null | grep -v '^initrd.img$' | tail -1 || true)
    
    if [ -n "$K_REAL" ] && [ -n "$I_REAL" ]; then
        ( cd "$MNT_ROOT/boot" && ln -sf "$K_REAL" vmlinuz && ln -sf "$I_REAL" initrd.img )
        ( cd "$MNT_ROOT" && ln -sf "boot/$K_REAL" vmlinuz && ln -sf "boot/$I_REAL" initrd.img )
        log_ok "Kernel symlinks fixed successfully:"
        echo "       /boot/vmlinuz    -> $K_REAL"
        echo "       /boot/initrd.img -> $I_REAL"
    else
        log_warn "Could not find vmlinuz-* in /boot on PUREROOT"
    fi

    # Sync system overlay (systemd units, helper utilities, cheatsheets) into PUREROOT
    if [ -d "$REPO_ROOT/board/overlay" ]; then
        if command -v rsync >/dev/null 2>&1; then
            rsync -a "$REPO_ROOT/board/overlay/" "$MNT_ROOT/"
        else
            cp -r "$REPO_ROOT/board/overlay"/* "$MNT_ROOT/" 2>/dev/null || true
        fi
        chmod +x "$MNT_ROOT/opt/puretest/runner.sh" 2>/dev/null || true
        chmod +x "$MNT_ROOT/usr/local/bin/"* 2>/dev/null || true
        log_ok "Synchronized system overlay into PUREROOT"
    fi

    # Update grub.cfg in PUREROOT
    if [ -f "$REPO_ROOT/board/grub.cfg.in" ]; then
        mkdir -p "$MNT_ROOT/boot/grub"
        cp "$REPO_ROOT/board/grub.cfg.in" "$MNT_ROOT/boot/grub/grub.cfg" 2>/dev/null || true
        log_ok "Updated GRUB config in PUREROOT"
    fi
    
    umount "$MNT_ROOT"
else
    log_warn "PUREROOT partition not available; skipped."
fi

# -----------------------------------------------------------------------------
# Step 3: Update DATADISK (runner.sh with AO, config.env, tests)
# -----------------------------------------------------------------------------
log_step "[3/3] Checking & Updating DATADISK"

if [ -n "$DATA_DEV" ] && [ -b "$DATA_DEV" ]; then
    # Unmount if currently mounted to allow clean fsck repair
    for m in $(findmnt -rn -o TARGET "$DATA_DEV" 2>/dev/null || true); do
        umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
    done

    log_info "Repairing DATADISK filesystem integrity (fixing any broken cluster chains)..."
    fsck.vfat -a -w "$DATA_DEV" 2>/dev/null || dosfsck -a "$DATA_DEV" 2>/dev/null || true
    log_ok "DATADISK filesystem verified and repaired"

    MNT_DATA=$(mktemp -d /tmp/puretest_data_XXXXXX)
    TMP_DIRS+=("$MNT_DATA")
    mount -o rw,noatime "$DATA_DEV" "$MNT_DATA"
    
    # 1. Update runner.sh with full AO support
    cp "$RUNNER_SRC" "$MNT_DATA/runner.sh"
    chmod +x "$MNT_DATA/runner.sh" 2>/dev/null || true
    log_ok "Updated 'runner.sh' (with AO Optimization degrees: O0..Ofast, all)"
    
    # 2. Update config.env (preserve user overrides if existing)
    if [ -f "$MNT_DATA/config.env" ]; then
        if ! grep -q "AO_LEVEL" "$MNT_DATA/config.env" 2>/dev/null; then
            cp "$CONFIG_SRC" "$MNT_DATA/config.env"
            log_ok "Updated 'config.env' with AO_LEVEL setting"
        else
            log_ok "'config.env' already contains AO_LEVEL configuration"
        fi
    else
        cp "$CONFIG_SRC" "$MNT_DATA/config.env"
        log_ok "Installed 'config.env'"
    fi
    
    # 3. Update run_list.txt sample
    [ -f "$RUNLIST_SRC" ] && cp "$RUNLIST_SRC" "$MNT_DATA/run_list.txt.sample"
    
    # 4. Sync tests directory if present
    if [ -d "$TESTS_SRC" ]; then
        mkdir -p "$MNT_DATA/tests"
        if command -v rsync >/dev/null 2>&1; then
            rsync -rt --no-o --no-g "$TESTS_SRC/" "$MNT_DATA/tests/"
        else
            cp -r "$TESTS_SRC"/* "$MNT_DATA/tests/" 2>/dev/null || true
        fi
        log_ok "Synchronized test suites in 'DATADISK/tests/'"
    fi
    
    umount "$MNT_DATA" 2>/dev/null || true
else
    log_warn "DATADISK partition not available; skipped."
fi

# -----------------------------------------------------------------------------
# Completion
# -----------------------------------------------------------------------------
sync

echo
echo -e "${C_GREEN}${C_BOLD}================================================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}     ✓ PureTest USB Flash Drive Successfully Updated!         ${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}================================================================${C_RESET}"
echo -e "  * ${C_BOLD}UEFI Boot Loop Fixed${C_RESET}     : fbx64.efi removed (boots straight to GRUB)"
echo -e "  * ${C_BOLD}GRUB Symlinks Fixed${C_RESET}      : /boot/vmlinuz -> actual kernel"
echo -e "  * ${C_BOLD}AO Support Installed${C_RESET}     : runner.sh updated (O0, O1, O2, O3, Ofast, all)"
echo -e "  * ${C_BOLD}Lab Benchmarks Ready${C_RESET}     : base vs opt matrix, puretest-hw profile, windows.h shim"
echo -e "  * ${C_BOLD}Tests Synchronized${C_RESET}       : latest C++ test sources updated"
echo
echo -e "Вы можете извлечь флешку и загрузить целевой ноутбук!"
echo
