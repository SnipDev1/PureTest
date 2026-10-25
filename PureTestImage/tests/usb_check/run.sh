#!/usr/bin/env bash
#
# usb_check/run.sh - USB Bus, Port Speed & Hardware Downgrade Auditor
#
# Audits all connected USB controllers and devices on the test machine.
# Specifically detects if any USB 3.0/3.1/3.2 devices are plugged into
# USB 2.0 ports or negotiated at degraded speeds (e.g. 480 Mbps instead of 5 Gbps).
#
set -u

echo "======================================================================"
echo "                   USB HARDWARE & PORT AUDIT"
echo "======================================================================"

DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || date)
echo "Timestamp: $DATE"
echo

# 1. USB Controllers Check (PCI / sysfs)
echo "[1] USB HOST CONTROLLERS"
echo "----------------------------------------------------------------------"
if command -v lspci >/dev/null 2>&1; then
    lspci | grep -i usb | while read -r line; do
        echo "  [PCI] $line"
    done
else
    echo "  (lspci not available, scanning sysfs...)"
fi

# Also scan root hubs in sysfs
echo
echo "  Root Hubs detected in sysfs:"
for hub in /sys/bus/usb/devices/usb*; do
    [ -d "$hub" ] || continue
    hub_name=$(basename "$hub")
    hub_speed=$(cat "$hub/speed" 2>/dev/null || echo "unknown")
    hub_prod=$(cat "$hub/product" 2>/dev/null || echo "Root Hub")
    echo "  - $hub_name: $hub_prod (Max bus speed: ${hub_speed} Mbps)"
done
echo

# 2. Connected Devices & Negotiated Speed Audit
echo "[2] CONNECTED USB DEVICES & LINK SPEEDS"
echo "----------------------------------------------------------------------"

total_devices=0
usb3_ok=0
usb3_degraded=0
usb2_devices=0
legacy_devices=0

# Helper to format speed string
format_speed() {
    case "$1" in
        1.5)   echo "1.5 Mbps  (Low Speed - USB 1.0)" ;;
        12)    echo "12 Mbps   (Full Speed - USB 1.1)" ;;
        480)   echo "480 Mbps  (High Speed - USB 2.0)" ;;
        5000)  echo "5 Gbps    (SuperSpeed - USB 3.0 / 3.1 Gen 1)" ;;
        10000) echo "10 Gbps   (SuperSpeedPlus - USB 3.1 / 3.2 Gen 2)" ;;
        20000) echo "20 Gbps   (SuperSpeedPlus - USB 3.2 Gen 2x2)" ;;
        *)     echo "$1 Mbps" ;;
    esac
}

# Scan every USB device entry in /sys/bus/usb/devices/
for devpath in /sys/bus/usb/devices/*; do
    [ -d "$devpath" ] || continue
    
    # Skip interface subdirectories (which contain colons like 1-1:1.0)
    devname=$(basename "$devpath")
    if [[ "$devname" == *:* ]]; then
        continue
    fi
    
    # Must have idVendor (skip root hubs if they don't have idVendor or are virtual)
    [ -f "$devpath/idVendor" ] || continue
    
    vid=$(cat "$devpath/idVendor" 2>/dev/null || echo "----")
    pid=$(cat "$devpath/idProduct" 2>/dev/null || echo "----")
    
    # Exclude Linux Foundation root hubs (1d6b) from device list to focus on actual hardware
    if [ "$vid" = "1d6b" ]; then
        continue
    fi
    
    total_devices=$((total_devices + 1))
    
    mfr=$(cat "$devpath/manufacturer" 2>/dev/null || echo "Unknown Mfr")
    prod=$(cat "$devpath/product" 2>/dev/null || echo "USB Device")
    serial=$(cat "$devpath/serial" 2>/dev/null || echo "")
    speed=$(cat "$devpath/speed" 2>/dev/null || echo "unknown")
    bcd_usb=$(cat "$devpath/version" 2>/dev/null || cat "$devpath/bcdUSB" 2>/dev/null || echo "unknown")
    bcd_usb_clean=$(echo "$bcd_usb" | tr -d ' ')
    
    # Check device class
    dev_class=$(cat "$devpath/bDeviceClass" 2>/dev/null || echo "")
    is_storage=0
    if [ "$dev_class" = "08" ]; then
        is_storage=1
    else
        # Check interfaces for Mass Storage class (08)
        if grep -q "08" "$devpath"/*:*/bInterfaceClass 2>/dev/null; then
            is_storage=1
        fi
    fi

    # Speed & Downgrade Evaluation
    status_label="INFO"
    downgrade_detected=0
    
    # If device USB version is 3.x (bcdUSB >= 3.00)
    if [[ "$bcd_usb_clean" =~ ^3\. ]]; then
        if [ "$speed" = "5000" ] || [ "$speed" = "10000" ] || [ "$speed" = "20000" ]; then
            status_label="[PASS] SuperSpeed Active"
            usb3_ok=$((usb3_ok + 1))
        else
            status_label="[FAIL/DOWNGRADE] USB 3.x device limited to USB 2.0!"
            downgrade_detected=1
            usb3_degraded=$((usb3_degraded + 1))
        fi
    elif [[ "$bcd_usb_clean" =~ ^2\. ]]; then
        if [ "$speed" = "480" ]; then
            status_label="[PASS] USB 2.0 High-Speed"
            usb2_devices=$((usb2_devices + 1))
        else
            status_label="[INFO] USB 2.0 device at Full/Low speed"
            legacy_devices=$((legacy_devices + 1))
        fi
    else
        legacy_devices=$((legacy_devices + 1))
        status_label="[INFO] Legacy / Other ($bcd_usb_clean)"
    fi

    echo "Device #$total_devices: [$vid:$pid] $mfr - $prod"
    [ -n "$serial" ] && echo "  Serial       : $serial"
    echo "  Port/Bus     : $devname"
    echo "  Hardware Spec: USB $bcd_usb_clean $( [ "$is_storage" -eq 1 ] && echo "(Mass Storage Drive)" )"
    echo "  Negotiated   : $(format_speed "$speed")"
    echo "  Evaluation   : $status_label"
    
    if [ "$downgrade_detected" -eq 1 ]; then
        echo "  >>> ATTENTION: This device is capable of USB 3.x speeds (>= 5 Gbps),"
        echo "      but is operating at USB 2.0 speed ($speed Mbps)."
        echo "      Possible reasons: Plugged into black USB 2.0 port instead of blue/teal,"
        echo "      faulty cable missing high-speed lines, or dirty/damaged socket contacts."
    fi
    echo
done

if [ "$total_devices" -eq 0 ]; then
    echo "  No external USB devices detected."
    echo
fi

# 3. USB Topology Tree (if lsusb installed)
if command -v lsusb >/dev/null 2>&1; then
    echo "[3] USB TOPOLOGY TREE (lsusb -t)"
    echo "----------------------------------------------------------------------"
    lsusb -t 2>/dev/null || echo "  (lsusb -t failed)"
    echo
fi

# 4. Summary
echo "======================================================================"
echo "AUDIT SUMMARY"
echo "======================================================================"
echo "  Total External USB Devices : $total_devices"
echo "  USB 3.x (Operating at 5G+) : $usb3_ok"
echo "  USB 3.x (DOWNGRADED to 2.0): $usb3_degraded"
echo "  Native USB 2.0 Devices     : $usb2_devices"
echo "  Legacy (1.0/1.1) Devices   : $legacy_devices"
echo "----------------------------------------------------------------------"

if [ "$usb3_degraded" -gt 0 ]; then
    echo "RESULT: WARNING - $usb3_degraded USB 3.0 device(s) are running at degraded USB 2.0 speeds!"
else
    echo "RESULT: OK - No USB 3.0 speed degradation detected."
fi
echo "======================================================================"

exit 0
