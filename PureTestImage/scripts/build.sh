#!/usr/bin/env bash
#
# build.sh - builds PureTestImage from scratch on a Debian/Ubuntu host.
#
# Output:
#   output/puretest.img  (hybrid BIOS+UEFI bootable GPT raw disk image)
#
# Partition layout:
#   p1: 1MiB..2MiB   BIOS boot partition (for GRUB's core.img on GPT)
#   p2: 2MiB..66MiB  EFI System Partition (FAT32, mounted at /boot/efi)
#   p3: 66MiB..1.5G  Debian rootfs (ext4, LABEL=PUREROOT)
#   p4: 1.5G..end    Data partition (FAT32, LABEL=DATADISK, type Microsoft
#                    basic data so Windows auto-mounts it when plugged in)
#
# Requirements on host:
#   debootstrap rsync parted dosfstools e2fsprogs util-linux grub-pc-bin grub-efi-amd64-bin
#
# Usage:
#   sudo ./scripts/build.sh
#
set -euo pipefail
export LC_ALL=C
export LANG=C

# ------------------------------------------------------------------ setup
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/output"
IMG="$OUT/puretest.img"
TMP=$(mktemp -d)
LOOP=""

# ------------------------------------------------------------ knobs (env)
RELEASE="${RELEASE:-bookworm}"                 # Debian suite
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
IMG_SIZE="${IMG_SIZE:-2.6G}"                   # total image file size
ROOT_SIZE="${ROOT_SIZE:-1.5G}"                 # root partition size
ESP_SIZE="${ESP_SIZE:-64MiB}"                  # EFI System Partition size
ALIGN="1MiB"
ROOT_PASS="${ROOT_PASS:-puretest}"             # default root password: puretest
CUSTOM_PACKAGES="${CUSTOM_PACKAGES:-g++ make binutils time usbutils pciutils util-linux less nano firmware-linux-free firmware-realtek firmware-iwlwifi firmware-atheros firmware-misc-nonfree}"
USE_CACHE="${USE_CACHE:-1}"                    # 1 = cache debian .deb packages; 0 = fresh download
CACHE_DIR="${CACHE_DIR:-$REPO_ROOT/.cache}"
APT_CACHE="$CACHE_DIR/apt"

cleanup() {
    set +e
    # An aborted build can leave the chroot bind-mounts (/proc,/dev,/sys) up.
    # They MUST be unmounted before rm -rf, or rm chokes on the procfs/sysfs
    # entries ("cannot remove .../proc/<pid>/fd/...: Operation not permitted").
    for m in "$TMP/root/var/cache/apt/archives" \
             "$TMP/root/proc" "$TMP/root/sys" "$TMP/root/dev" \
             "$TMP/root-boot" "$TMP/esp" "$TMP/data-mnt"; do
        [ -d "$m" ] && umount "$m" 2>/dev/null
    done
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

step() { echo; echo "### $1"; }

need_root() {
    [ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo:  sudo ./scripts/build.sh" >&2; exit 1; }
}

need_cmd() {
    command -v "$1" >/dev/null || { echo "ERROR: missing host tool '$1'"; exit 1; }
}

need_root
for c in debootstrap rsync parted losetup mkfs.ext4 mkfs.vfat chroot grub-install; do
    need_cmd "$c"
done
mkdir -p "$TMP/root" "$OUT"

if [ "$USE_CACHE" = "1" ]; then
    mkdir -p "$APT_CACHE/partial"
    chmod -R 777 "$APT_CACHE"
    mkdir -p "$TMP/root/var/cache/apt/archives/partial"
    mount --bind "$APT_CACHE" "$TMP/root/var/cache/apt/archives"
    echo "  Package cache active: $APT_CACHE ($(ls -1 "$APT_CACHE"/*.deb 2>/dev/null | wc -l) deb(s) cached)"
fi

step "Debootstrap $RELEASE amd64 (minbase) — first run downloads ~100 MB"
debootstrap --arch=amd64 --variant=minbase --include=ca-certificates \
    "$RELEASE" "$TMP/root" "$MIRROR"

# ========================================================= 1. Debian install
step "Configure rootfs (kernel, g++, packages)"
mount --bind /dev  "$TMP/root/dev"
mount --bind /proc "$TMP/root/proc"
mount --bind /sys  "$TMP/root/sys"
cp /etc/resolv.conf "$TMP/root/etc/resolv.conf"

chroot "$TMP/root" /bin/bash -s <<EOF
    set -e
    export DEBIAN_FRONTEND=noninteractive
    echo 'APT::Install-Recommends "false";' > /etc/apt/apt.conf.d/99puretest
    # Enable contrib, non-free, and non-free-firmware for hardware drivers & firmware
    cat > /etc/apt/sources.list <<SOURCES
deb $MIRROR $RELEASE main contrib non-free non-free-firmware
deb $MIRROR ${RELEASE}-updates main contrib non-free non-free-firmware
SOURCES
    # Acquire::Retries cushions transient network failures (this image is
    # usually built over a flaky VPN/WAN link from Windows).
    apt-get -o Acquire::Retries=5 update
    # systemd-sysv is REQUIRED: it provides /sbin/init. debootstrap
    # --variant=minbase only installs Priority:required packages, and the init
    # system is Priority:important in bookworm -> without this explicit install
    # the rootfs has NO init at all and the kernel panics
    # ("Attempted to kill init! exitcode = 0x00000000").
    apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
        $CUSTOM_PACKAGES linux-image-amd64 kmod initramfs-tools systemd-sysv
    [ "$USE_CACHE" != "1" ] && apt-get clean
    # drop apt's downloaded package lists (~40-60 MB) — saves real space in the image
    rm -rf /var/lib/apt/lists/*
EOF

[ -n "$ROOT_PASS" ] && printf 'root:%s\n' "$ROOT_PASS" | chroot "$TMP/root" chpasswd
rm -f "$TMP/root/etc/resolv.conf"
umount "$TMP/root/sys"
umount "$TMP/root/proc"
umount "$TMP/root/dev"
if [ "$USE_CACHE" = "1" ]; then
    umount "$TMP/root/var/cache/apt/archives" 2>/dev/null || true
    rm -f "$TMP/root/var/cache/apt/archives/"*.deb 2>/dev/null || true
fi

# kernel + initramfs symlinks so grub.cfg can reference stable paths
chroot "$TMP/root" /bin/bash -c '
    cd /boot
    ln -sf $(ls vmlinuz-* | head -1) vmlinuz
    ln -sf $(ls initrd.img-* | head -1) initrd.img
'

step "Install overlay (harness, fstab, systemd unit, rescue tools)"
rsync -a "$REPO_ROOT/board/overlay/" "$TMP/root/"
chmod +x "$TMP/root/opt/puretest/runner.sh" 2>/dev/null || true
chmod +x "$TMP/root/usr/local/bin/"* 2>/dev/null || true

# Offline enable/mask, straight from the host (no running systemd needed).
systemctl --root="$TMP/root" enable puretest.service || true
systemctl --root="$TMP/root" mask getty@tty1.service || true

# Explicitly ensure target symlinks exist so units run unconditionally
mkdir -p "$TMP/root/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/puretest.service "$TMP/root/etc/systemd/system/multi-user.target.wants/puretest.service"
mkdir -p "$TMP/root/etc/systemd/system/getty.target.wants"
ln -sf /lib/systemd/system/getty@.service "$TMP/root/etc/systemd/system/getty.target.wants/getty@tty2.service"

# ================================================================ 2. image
step "Create $IMG_SIZE GPT image ($IMG)"
# truncate only accepts INTEGER sizes, so convert e.g. '2.6G' to bytes first
IMG_BYTES=$(LC_ALL=C numfmt --from=iec "${IMG_SIZE//,/.}" 2>/dev/null || true)
if [ -z "$IMG_BYTES" ] || [ "$IMG_BYTES" -le 0 ]; then
    IMG_BYTES=$(LC_ALL=C awk -v s="${IMG_SIZE//,/.}" '
        BEGIN {
            u = tolower(substr(s, length(s)));
            v = substr(s, 1, length(s)-1) + 0;
            if (u == "g") printf "%.0f", v * 1024 * 1024 * 1024;
            else if (u == "m") printf "%.0f", v * 1024 * 1024;
            else if (u == "k") printf "%.0f", v * 1024;
            else printf "%.0f", s + 0;
        }' 2>/dev/null || true)
fi
if [ -z "$IMG_BYTES" ] || [ "$IMG_BYTES" -le 0 ]; then
    echo "ERROR: cannot parse IMG_SIZE='$IMG_SIZE' (examples: 2.6G, 3G, 16G)" >&2
    exit 1
fi
# round UP to a 1MiB boundary: '2.6G' comes out of numfmt as 2791728743 bytes,
# which is NOT a multiple of 512 -> losetup warns "file does not end on a 512-byte
# sector boundary" and parted refuses to place the backup GPT table.
ALIGN_BYTES=$((1024 * 1024))
IMG_BYTES=$(( ((IMG_BYTES + ALIGN_BYTES - 1) / ALIGN_BYTES) * ALIGN_BYTES ))
truncate -s "$IMG_BYTES" "$IMG"

# =========================================================== 3. partition
step "Partition GPT (BIOS_boot, EFI, PUREROOT, DATADISK)"
parted -s "$IMG" mklabel gpt
parted -s "$IMG" mkpart BIOS_boot "$ALIGN" 2MiB
parted -s "$IMG" set 1 bios_grub on
parted -s "$IMG" mkpart EFI 2MiB "$ESP_SIZE"
parted -s "$IMG" set 2 boot on
parted -s "$IMG" set 2 esp on
parted -s "$IMG" mkpart root "$ESP_SIZE" "$ROOT_SIZE"
parted -s "$IMG" mkpart data "$ROOT_SIZE" 100%
# make data partition Windows-mountable: GPT type -> Microsoft basic data
# (Windows refuses FAT partitions whose GPT type is a Linux GUID)
parted -s "$IMG" set 4 msftdata on

LOOP=$(losetup -f --show -P "$IMG")
PART="$LOOP" # /dev/loopN ; partitions named loopNp1..p4

step "mkfs partitions"
mkfs.vfat -n EFIBOOT  "$PART"p2
mkfs.ext4 -F -L PUREROOT "$PART"p3
mkfs.vfat -n DATADISK "$PART"p4

step "Populate root, ESP and DATADISK"
mkdir -p "$TMP/root-boot" "$TMP/esp" "$TMP/data-mnt"
mount "$PART"p3 "$TMP/root-boot"
mount "$PART"p2 "$TMP/esp"
mount "$PART"p4 "$TMP/data-mnt"

# copy rootfs (excluding live device/fs mounts), preserve perms/ownership
( cd "$TMP/root" \
   && tar --exclude='./dev/*' --exclude='./proc/*' --exclude='./sys/*' \
          --exclude='./tmp/*' --exclude='./run/*' --exclude='./lost+found' \
          --exclude='./var/cache/apt/archives/*.deb' \
          -cf - . ) | ( cd "$TMP/root-boot" && tar -xf - )

# preload ready-made tests into DATADISK/tests (so the flash drive boots
# straight into a working menu — no need to write tests from Windows).
# NOTE: -rt, not -a: FAT32 has no owner/group (rsync -a would fail on chown)
if [ -d "$REPO_ROOT/tests" ]; then
    rsync -rt --no-o --no-g "$REPO_ROOT/tests/" "$TMP/data-mnt/tests/"
    echo "  preloaded $(find "$REPO_ROOT/tests" -maxdepth 1 -type d ! -name tests | wc -l) test folder(s) into DATADISK/tests"
fi

# Preload editable runner, config, test lists and documentation to DATADISK root
[ -f "$REPO_ROOT/board/overlay/opt/puretest/runner.sh" ] && cp "$REPO_ROOT/board/overlay/opt/puretest/runner.sh" "$TMP/data-mnt/runner.sh.template"
[ -f "$REPO_ROOT/config.env" ] && cp "$REPO_ROOT/config.env" "$TMP/data-mnt/config.env"
[ -f "$REPO_ROOT/run_list.txt" ] && cp "$REPO_ROOT/run_list.txt" "$TMP/data-mnt/run_list.txt.sample"
[ -f "$REPO_ROOT/tests/README.txt" ] && cp "$REPO_ROOT/tests/README.txt" "$TMP/data-mnt/README.txt"

umount "$TMP/data-mnt"

# ========================================================= 4. GRUB BIOS+UEFI
step "Install GRUB — BIOS (i386-pc, MBR+core.img into BIOS_boot part)"
grub-install --target=i386-pc \
    --boot-directory="$TMP/root-boot/boot" \
    --modules="part_gpt fat ext2 search search_label" \
    --force "$PART" || echo "WARN: BIOS grub-install failed (UEFI image still works)"

step "Install GRUB — UEFI (x86_64-efi, removable media into ESP)"
grub-install --target=x86_64-efi \
    --efi-directory="$TMP/esp" \
    --boot-directory="$TMP/root-boot/boot" \
    --modules="part_gpt fat ext2 search search_label" \
    --removable --no-nvram || { echo "ERROR: EFI grub-install failed"; exit 1; }

# grub-install writes its own grub.cfg with Ubuntu/Debian auto-detection
# cruft (searches for /.disk/info, etc.). Overwrite with ours everywhere.
# BIOS reads /boot/grub/grub.cfg on the root partition.
# UEFI removable reads grub.cfg NEXT TO bootx64.efi in the ESP.
cp "$REPO_ROOT/board/grub.cfg.in" "$TMP/root-boot/boot/grub/grub.cfg"
mkdir -p "$TMP/esp/EFI/BOOT"
cp "$REPO_ROOT/board/grub.cfg.in" "$TMP/esp/EFI/BOOT/grub.cfg"
# Also drop it into the ESP's /boot/grub/ in case the EFI binary's $prefix
# points there instead of to the root partition.
mkdir -p "$TMP/esp/boot/grub"
cp "$REPO_ROOT/board/grub.cfg.in" "$TMP/esp/boot/grub/grub.cfg"

sync
umount "$TMP/root-boot"
umount "$TMP/esp"
losetup -d "$LOOP"; LOOP=""

# ================================================================ 5. done
chown "${SUDO_USER:-$(whoami)}" "$IMG" 2>/dev/null || true

step "Compressing image to puretest.img.tar.gz (max compression: gzip -9)"
if command -v pigz >/dev/null 2>&1; then
    tar -I "pigz -9" -cf "$OUT/puretest.img.tar.gz" -C "$OUT" puretest.img
else
    GZIP="-9" tar -czf "$OUT/puretest.img.tar.gz" -C "$OUT" puretest.img
fi
chown "${SUDO_USER:-$(whoami)}" "$OUT/puretest.img.tar.gz" 2>/dev/null || true

step "DONE"
echo "  Raw Image : $IMG ($(du -h "$IMG" | cut -f1), GPT: BIOS/EFI/root/data)"
echo "  Archive   : $OUT/puretest.img.tar.gz ($(du -h "$OUT/puretest.img.tar.gz" | cut -f1))"
echo "  Write to a USB stick in RAW-DD mode:"
echo "    Windows: Rufus -> select $IMG -> 'DD image' mode  (or Etcher)"
echo "    Linux : sudo dd if=$IMG of=/dev/sdX bs=4M status=progress"
echo "  Tests are already inside DATADISK/tests; add more anytime —"
echo "  the layout is described in board/overlay/opt/puretest/README.txt."