# PureTestImage Shell Cheatsheet & Operator Guide

Welcome to the **PureTestImage** live environment. You have root access on this machine. This cheatsheet outlines essential commands for disk mounting, hardware diagnostics, and manual testing.

---

## 1. Quick Navigation

* **Return to Test Menu**:
  ```bash
  exit
  ```
  *(or manually relaunch: `/opt/puretest/runner.sh`)*
* **Key Directories**:
  * `/data` — The `DATADISK` partition on your USB flash drive (FAT32). Holds `tests/` and `results/`.
  * `/opt/puretest/` — PureTestImage harness scripts and documentation.
  * `/tmp` — Fast RAM-disk (tmpfs). Cleared on reboot.

---

## 2. Storage & Drive Management

### Finding Disks & Partitions
Before mounting any USB drive or internal SSD/HDD:
```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS
blkid
```

### Mounting a Flash Drive or Partition
1. Create a mount point directory:
   ```bash
   mkdir -p /mnt/usb
   ```
2. Mount the partition (replace `/dev/sdX1` with your device from `lsblk`):
   ```bash
   # FAT32 / exFAT USB flash drive:
   mount -t vfat -o iocharset=utf8 /dev/sdX1 /mnt/usb

   # ext4 Linux partition:
   mount /dev/sdX1 /mnt/usb

   # NTFS Windows partition (read-only safe mode):
   mount -t ntfs-3g -o ro /dev/sdX1 /mnt/usb
   ```

### Remounting DATADISK
If the primary USB partition wasn't mounted automatically on `/data`:
```bash
mount -L DATADISK /data
```

### Safely Unmounting (IMPORTANT)
**Always run `sync` before pulling out any USB stick** to prevent data loss or FAT32 filesystem corruption:
```bash
sync
umount /mnt/usb
```

---

## 3. Hardware Inspection & Diagnostics

### USB Diagnostics & Speed Checking
* **List connected USB devices**:
  ```bash
  lsusb
  ```
* **View USB port tree & negotiated speeds (480M vs 5000M/10000M)**:
  ```bash
  lsusb -t
  ```
* **Watch USB hotplug events in real time**:
  ```bash
  dmesg -w | grep -i usb
  ```
* **Run built-in USB downgrade auditor**:
  ```bash
  /data/tests/usb_check/run.sh
  ```

### CPU, Memory & PCI Diagnostics
* **CPU specs, topology, and SIMD instruction flags (AVX2, FMA, etc.)**:
  ```bash
  lscpu
  ```
* **Memory total and free RAM**:
  ```bash
  free -h
  cat /proc/meminfo | head -10
  ```
* **PCI controllers, Chipset, GPU, and xHCI controllers**:
  ```bash
  lspci
  lspci -v -s $(lspci | grep -i xhci | cut -d' ' -f1)
  ```

---

## 4. Manual Benchmark Compilation & Running

You can manually compile and benchmark custom C++ code right from this shell:

### Compile with Native CPU Optimizations
```bash
g++ -O2 -march=native -o /tmp/mytest /data/tests/bench_cpu/cpu.cpp
```

### Measure Execution Time Accurately
```bash
/usr/bin/time -v /tmp/mytest
```

### Run Custom Tests
You can run any test script directly:
```bash
bash /data/tests/usb_check/run.sh
```

---

## 5. Troubleshooting & Diagnostics

If anything goes wrong during boot or runtime, use these built-in helpers:

* **`puretest-status`**: Shows `systemctl status puretest`, tail of `/tmp/puretest.log`, and mount state of `/data`.
* **`puretest-log`**: Streams live logs from `/tmp/puretest.log` and systemd journal.
* **`puretest-run`**: Directly runs `/opt/puretest/runner.sh` in the current terminal.
* **`puretest-restart`**: Restarts the background `puretest.service`.
* **`puretest-mount`**: Force-mounts `DATADISK` to `/data`.
* **TTY Switching**:
  * `Alt+F1` (or `Ctrl+Alt+F1`): Main harness on TTY1.
  * `Alt+F2` (or `Ctrl+Alt+F2`): Emergency automatic root rescue console on TTY2.

---

## 6. System Power & Reboot

* **Safely turn off the machine**:
  ```bash
  sync && poweroff
  ```
* **Reboot the machine**:
  ```bash
  sync && reboot
  ```

---
*Tip: You can re-open this cheatsheet anytime by typing `cheatsheet` or `less /opt/puretest/CHEATSHEET.md`.*
