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
# Control: the same pipe that carries the touchscreen events carries the
# commands, so there is no state file, no signal and no poll. Both commands
# are "<verb> <arg> <replypath>" and both are answered, a SET included, so a
# writer knows its change landed instead of firing and hoping:
#   SET <adaptive|60|120> <path>   hold that rate, then answer on that fifo
#   GET -                   <path>   answer on that fifo
# The answer is "mode=... cur=... down=...". The mode lives here and dies with
# the process: a reboot comes back adaptive.
#
# Tuning: setprop persist.sys.phh.fps_gov_idle <seconds> before start.
#         setprop persist.sys.phh.fps_gov_log 0 to disable logcat logging.

TOUCH_NAME=fts_ts
# Absolute, and for the same two reasons as in fps_ctl.sh: ${0%/*} is a no-op
# on a $0 with no slash, and a relative MODDIR would put the pidfile and the
# fifo somewhere the boot cleanup and fps_ctl.sh never look, so the two would
# disagree about whether a governor is running.
case "$0" in
    */*) MODDIR=${0%/*} ;;
    *)   MODDIR=. ;;
esac
case "$MODDIR" in
    /*) ;;
    *) MODDIR=$PWD/$MODDIR ;;
esac
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

# True if $1 is a live process whose cmdline names this very script.
# A plain kill -0 guard is not enough: after a reboot the pid from a stale
# pidfile is routinely reused by an unrelated daemon (netd/system_server grab
# low pids first); the guard then believes an instance is already running and
# the governor exits at startup and never comes back until the pidfile is
# removed by hand. Check the cmdline instead of trusting the pid.
is_governor() {
    [ -r "/proc/$1/cmdline" ] || return 1
    grep -q "fps_governor" "/proc/$1/cmdline" 2>/dev/null
}

# single-instance guard, stale-pidfile safe
if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && is_governor "$pid"; then
        exit 0
    fi
    logm "stale pidfile cleared (pid ${pid:-?})"
    rm -f "$PIDFILE"
fi
echo $$ > "$PIDFILE"

# What we asked for vs what the system reports back: the GSI normalises 120
# into Infinity, so that is a confirmed 120, not a mismatch.
rate_is() {
    case "$2" in
        Infinity) [ "$1" = 120 ] ;;
        *) [ "$1" = "$2" ] ;;
    esac
}

# Drive the panel to $1. No-op when $cur already says so. A write the system
# did not take leaves $cur alone, which is the entire retry: the loop below
# comes back around on its own and tries again. No readiness probe, no waiting.
go() {
    [ "$cur" = "$1" ] && return 0
    settings put system min_refresh_rate "$1" || return 1
    settings put system peak_refresh_rate "$1" || return 1
    rate_is "$1" "$(settings get system min_refresh_rate)" || return 1
    cur=$1
    logm "set rate to $1 Hz"
    return 0
}

# Hold $1 until told otherwise, and remember it in the two variables the loop
# reads: $mode (what was asked for) and $forced (1 = the panel is pinned and
# the touch logic must keep its hands off it).
set_mode() {
    case "$1" in
        60|120) mode=$1; forced=1 ;;
        *)       mode=adaptive; forced=0 ;;
    esac
    if [ "$forced" = 1 ]; then
        go "$mode"
    else
        # Hand the panel back: 120 now, and the idle timer may drop it after.
        go 120
    fi
    logm "mode=$mode"
}

# Answer a GET on the fifo the caller created and is holding. Opened read-write
# so this cannot block, and in a subshell because a failed redirection on
# `exec` is fatal in the calling shell - which is the governor. A caller that
# already gave up costs one line in a buffer nobody reads.
answer() {
    [ -p "$1" ] || return 0
    (
        exec 9<>"$1"
        printf 'mode=%s cur=%s down=%s\n' "$mode" "$cur" "$down" >&9
    ) 2>/dev/null
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

# FIFO bridging getevent (unbuffered writer) and the rate loop. Holding the
# read end for as long as this process lives is what lets a command open the
# fifo for writing without waiting: a writer only blocks while nobody reads.
# Keep it read-only, so a dead getevent closes the write end and the read
# below returns at once instead of waiting out the idle timeout.
fifo="$MODDIR/.fps_gov.fifo"
rm -f "$fifo"
mkfifo "$fifo" 2>/dev/null || exit 1

getevent -t "$dev" >"$fifo" &
gepid=$!

cleanup() {
    kill "$gepid" 2>/dev/null
    rm -f "$fifo" "$PIDFILE"
    exit 0
}
trap cleanup TERM INT HUP

exec 3<"$fifo"

cur=120
mode=adaptive
forced=0
down=0
# When the touchscreen last said anything. Idling is a question about this
# clock, not about the read below. The same fifo carries the control channel,
# so one reader asking for status once a second - which is exactly what the
# gamemode app's screen does while it is open - was enough to keep `read -t`
# from ever timing out, and the panel sat at 120 with no finger on the glass
# for as long as that screen stayed open. $SECONDS is a shell builtin, so
# asking the time on the per-motion-line hot path costs no fork.
last_touch=$SECONDS
# Boot state (settings normalized to Infinity) already means 120, so this
# writes nothing; it is here for the log line and the one code path.
set_mode adaptive

while :; do
    read -r -t "$IDLE_S" line <&3
    got=$?
    if [ "$got" = 0 ]; then
        case "$line" in
            # "<verb> <arg> <replypath>", all three always present.
            SET\ *|GET\ *)
                ctl=${line%% *}
                rest=${line#* }
                if [ "$ctl" = SET ]; then set_mode "${rest%% *}"; fi
                answer "${rest#* }"
                # Deliberately neither a `continue` nor a last_touch update: a
                # command is not a touch, so it must not push the panel to 120
                # and must not count as activity either. The clock at the
                # bottom decides idling, so a caller can neither hold the panel
                # up by asking often nor bring it down by asking at all.
                ;;
            *)
                last_touch=$SECONDS
                case "$line" in
                    *'0001 014a 00000001'*)
                        if [ "$down" != 1 ]; then down=1; logm "finger down"; fi ;;
                    *'0001 014a 00000000'*)
                        if [ "$down" != 0 ]; then down=0; logm "finger up"; fi ;;
                esac
                [ "$forced" = 0 ] && go 120
                ;;
        esac
    elif ! kill -0 "$gepid" 2>/dev/null; then
        logm "getevent died, exit"
        break
    fi
    if [ "$forced" = 1 ]; then
        # a pinned rate owns the panel: no switching, no touching it
        go "$mode"
    elif [ "$down" = 0 ] && [ $((SECONDS - last_touch)) -ge "$IDLE_S" ]; then
        # finger still down but silent: keep 120 so mid-scan pauses do not
        # trigger a 60->120 panel switch on the next fling
        go 60
    fi
done

# getevent died: tear down cleanly (a leftover pidfile would poison the next
# start; the guard clears stale entries anyway, but stay tidy)
kill "$gepid" 2>/dev/null
rm -f "$fifo" "$PIDFILE"
logm "daemon exit (getevent died)"
