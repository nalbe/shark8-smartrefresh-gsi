#!/system/bin/sh
# fps_ctl.sh - talk to the running fps governor.
#
#   fps_ctl.sh 60|120|adaptive   hold that rate until told otherwise
#   fps_ctl.sh status            what the governor thinks right now
#
# The request goes down the same pipe the touchscreen events come through and
# the answer comes back on a fifo of its own. Both halves are "<verb> <arg>
# <replypath>", so a command is confirmed rather than fired and forgotten.
# Nothing here can block: the reply fifo is ours and is held open read-write,
# so neither the open nor the read waits on the governor, and a governor that
# cannot answer in REPLY_S is reported as no answer instead of waited on.
#
# With no governor running there is nothing left to argue with the votes, so a
# rate is written straight to the settings; `adaptive` needs a chooser and is
# refused.

# MODDIR has to come out absolute, and that is not tidiness. Two traps:
#   ${0%/*} is a no-op on a $0 with no slash, so a bare `sh fps_ctl.sh 120`
#     from inside the module dir pointed MODDIR at the script name itself,
#     missed the pidfile, and wrote the votes straight past a live governor.
#   a relative reply path is meaningless to the receiver: the governor
#     resolves it against its own cwd, which is not ours, so the answer went
#     nowhere while the rate change still landed - applied, unreported.
case "$0" in
    */*) MODDIR=${0%/*} ;;
    *)   MODDIR=. ;;
esac
case "$MODDIR" in
    /*) ;;
    *) MODDIR=$PWD/$MODDIR ;;
esac
FIFO=$MODDIR/.fps_gov.fifo
PIDFILE=$MODDIR/.fps_gov.pid
REPLY_S=3

usage() {
    echo "usage: ${0##*/} adaptive|60|120|status" >&2
}

running() {
    p=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$p" ] && grep -q fps_governor "/proc/$p/cmdline" 2>/dev/null
}

# Send "<verb> <arg> -" down the pipe, print the answer.
ask() {
    reply=$MODDIR/.fps_gov.ask.$$
    mkfifo "$reply" 2>/dev/null || return 1
    exec 9<>"$reply"
    printf '%s %s %s\n' "$1" "$2" "$reply" > "$FIFO"
    read -r -t "$REPLY_S" line <&9
    exec 9>&-
    rm -f "$reply"
    [ -n "$line" ] || return 1
    echo "$line"
}

case "${1:-}" in
    adaptive|60|120)
        if running; then
            ask SET "$1" >/dev/null || {
                echo "no answer from the governor" >&2
                exit 1
            }
        elif [ "$1" = adaptive ]; then
            echo "no governor running to make this choice" >&2
            exit 1
        else
            settings put system min_refresh_rate "$1"
            settings put system peak_refresh_rate "$1"
        fi
        ;;
    status)
        if running; then
            ask GET - || {
                echo "no answer from the governor" >&2
                exit 1
            }
        else
            echo "mode=none votes=$(settings get system min_refresh_rate)/$(settings get system peak_refresh_rate)"
        fi
        ;;
    *)
        usage
        exit 2
        ;;
esac
exit 0
