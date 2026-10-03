#!/system/bin/sh
# service.sh - starts the fps governor daemon and the display low-power fix.
# Runs as root at boot (KernelSU module lifecycle).
#
# The daemon MUST be detached from ksud's process group (setsid), otherwise
# ksud reaps the whole group after service.sh exits and the governor dies
# silently (boot log shows the exec but zero fps_gov lines). led_hal_root
# uses the same trick and survives every boot.

case "$0" in
    */*) MODDIR=${0%/*} ;;
    *)   MODDIR=. ;;
esac
case "$MODDIR" in
    /*) ;;
    *) MODDIR=$PWD/$MODDIR ;;
esac
# A pidfile/fifo left by a previous session must never get in the way of a
# fresh start: after a reboot the pid it holds usually belongs to a totally
# different process and the governor's dead-instant guard would have believed
# "already running". Make every boot a clean slate; the in-script guard still
# prevents double instances within one boot.
# The reply fifos are named per pid, so a killed caller leaves one behind.
# .fps_gov.mode is the state file of v1.5 and earlier: gone for good in v1.6,
# removed here once so it does not rot on disk.
rm -f "$MODDIR/.fps_gov.pid" "$MODDIR/.fps_gov.fifo" "$MODDIR/.fps_gov.mode" \
    "$MODDIR"/.fps_gov.ask.*
# displowpower.sh writes once but waits for the display driver first, so it is
# detached for the same reason the governor is: a wait in service.sh holds up
# the rest of the module lifecycle.
/data/adb/ksu/bin/busybox setsid sh "$MODDIR/displowpower.sh" >/dev/null 2>&1 &
/data/adb/ksu/bin/busybox setsid sh "$MODDIR/fps_governor.sh" >/dev/null 2>&1 &
