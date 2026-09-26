#!/system/bin/sh
# service.sh - starts the fps governor daemon in the background.
# Runs as root at boot (KernelSU module lifecycle).
#
# The daemon MUST be detached from ksud's process group (setsid), otherwise
# ksud reaps the whole group after service.sh exits and the governor dies
# silently (boot log shows the exec but zero fps_gov lines). led_hal_root
# uses the same trick and survives every boot.

MODDIR=${0%/*}
# A pidfile/fifo left by a previous session must never get in the way of a
# fresh start: after a reboot the pid it holds usually belongs to a totally
# different process and the governor's dead-instant guard would have believed
# "already running". Make every boot a clean slate; the in-script guard still
# prevents double instances within one boot.
rm -f "$MODDIR/.fps_gov.pid" "$MODDIR/.fps_gov.fifo"
/data/adb/ksu/bin/busybox setsid sh "$MODDIR/fps_governor.sh" >/dev/null 2>&1 &
