#!/system/bin/sh
# displowpower.sh - keep mtk_drm_idlemgr out of the vblank path.
# Runs once per boot from service.sh; the driver keeps the value afterwards.
#
# Tuning: setprop persist.sys.phh.disp_idletime <frames> before start.

IDLE_NODE=/sys/kernel/debug/displowpower/idletime
DEBUGFS=/sys/kernel/debug

IDLE_FRAMES=5000
idle_prop=$(getprop persist.sys.phh.disp_idletime)
[ -n "$idle_prop" ] && IDLE_FRAMES=$idle_prop

log_enabled=$(getprop persist.sys.phh.fps_gov_log)
[ -z "$log_enabled" ] && log_enabled=1

logm() {
    [ "$log_enabled" = 1 ] || return 0
    /system/bin/log -p i -t disp_idle "$1"
}

[ -d "$DEBUGFS/dri" ] || mount -t debugfs none "$DEBUGFS" 2>/dev/null

# the display driver registers the node later than this script runs
i=0
while [ ! -e "$IDLE_NODE" ]; do
    [ "$i" -ge 30 ] && { logm "no $IDLE_NODE after 30s, giving up"; exit 1; }
    sleep 1
    i=$((i + 1))
done

before=$(cat "$IDLE_NODE" 2>/dev/null)
echo "$IDLE_FRAMES" > "$IDLE_NODE" 2>/dev/null
after=$(cat "$IDLE_NODE" 2>/dev/null)

if [ "$after" = "$IDLE_FRAMES" ]; then
    logm "idletime $before -> $after frames"
else
    logm "idletime stuck at $after, wanted $IDLE_FRAMES"
fi