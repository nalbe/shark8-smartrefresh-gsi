#!/system/bin/sh
# fps_governor.sh - custom touch-driven 60/120 Hz refresh-rate governor.
# Replaces the broken SurfaceFlinger content-detection dynamic FPS on the
# AOSP GSI (Blackview Shark 8 / MTK panel).
#
# Behavior:
#   touch activity on the touchscreen     -> force 120 Hz
#   finger held down (even without motion) keeps 120 Hz (BTN_TOUCH latch)
#   finger lifted and no touch for IDLE_S -> drop to 60 Hz
#
# The panel is switched through DMS user-setting votes (min/peak
# refresh_rate settings pair). Runs as a daemon started from service.sh.
#
# Tuning: setprop persist.sys.phh.fps_gov_idle <seconds> before start.
#         setprop persist.sys.phh.fps_gov_log 0 to disable logcat logging.

TOUCH_NAME=fts_ts
MODDIR=${0%/*}
PIDFILE=$MODDIR/.fps_gov.pid

IDLE_S=6
idle_prop=$(getprop persist.sys.phh.fps_gov_idle)
[ -n "$idle_prop" ] && IDLE_S=$idle_prop

log_enabled=$(getprop persist.sys.phh.fps_gov_log)
[ -z "$log_enabled" ] && log_enabled=1

logm() {
    [ "$log_enabled" = 1 ] || return 0
    /system/bin/log -p i -t fps_gov "$1"
}

# single-instance guard (worked when service.sh raced a manual start)
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    exit 0
fi
echo $$ > "$PIDFILE"

set_rate() {
    case "$1" in
        60)
            settings put system min_refresh_rate 60
            settings put system peak_refresh_rate 60
            ;;
        120)
            settings put system min_refresh_rate 120
            settings put system peak_refresh_rate 120
            ;;
    esac
    logm "set rate to $1 Hz"
}

wait_ready() {
    i=0
    while ! settings get system min_refresh_rate >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -ge 45 ]; then
            logm "settings service not ready after 90s, abort"
            return 1
        fi
        sleep 2
    done
    return 0
}

# Locate touchscreen by sysfs name (device index may vary across boots).
dev=""
for e in /sys/class/input/event*; do
    [ -f "$e/device/name" ] || continue
    if [ "$(cat "$e/device/name" 2>/dev/null)" = "$TOUCH_NAME" ]; then
        dev="/dev/input/${e##*/}"
        break
    fi
done

if [ -z "$dev" ]; then
    logm "touch device $TOUCH_NAME not found, abort"
    exit 1
fi
logm "touch device: $dev, idle timeout: ${IDLE_S}s"

wait_ready || exit 1

# FIFO bridging getevent (unbuffered writer) and the rate loop.
fifo="$MODDIR/.fps_gov.fifo"
rm -f "$fifo"
mkfifo "$fifo" 2>/dev/null || exit 1

getevent -t "$dev" >"$fifo" &
gepid=$!

cleanup() { kill "$gepid" 2>/dev/null; rm -f "$fifo"; exit 0; }
trap cleanup TERM INT

exec 3<"$fifo"

cur=120
down=0
# Boot state (settings normalized to Infinity) already means 120 Hz: no write.

while :; do
    if read -r -t "$IDLE_S" line <&3; then
        case "$line" in
            *'0001 014a 00000001'*)
                if [ "$down" != 1 ]; then down=1; logm "finger down"; fi ;;
            *'0001 014a 00000000'*)
                if [ "$down" != 0 ]; then down=0; logm "finger up"; fi ;;
        esac
        if [ "$cur" != 120 ]; then
            set_rate 120
            cur=120
        fi
    else
        if ! kill -0 "$gepid" 2>/dev/null; then
            logm "getevent died, exit"
            break
        fi
        # finger still down but silent: keep 120 so mid-scan pauses do not
        # trigger a 60->120 panel switch on the next fling
        [ "$down" = 1 ] && continue
        if [ "$cur" != 60 ]; then
            set_rate 60
            cur=60
        fi
    fi
done