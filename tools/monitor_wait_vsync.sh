#!/system/bin/sh
# monitor_wait_vsync.sh
# Watch drm_wait_vblank_ioctl successes/failures in real time.
#
# With the bug present (content detection on, dynamic fps on): bursts of
# -EINVAL (0xffffffea) appear whenever the kernel cycles drm_crtc_vblank_off.
# With the fix applied: only 0x0 returns, even under input swipes.
#
# Usage: adb root; adb push tools/monitor_wait_vsync.sh /data/local/tmp/
#        adb shell sh /data/local/tmp/monitor_wait_vsync.sh [seconds] [swipes]

DUR=${1:-4}
SWIPES=${2:-0}
TR=/sys/kernel/tracing

echo 0 > $TR/tracing_on
echo > $TR/kprobe_events
echo p:vw_e drm_wait_vblank_ioctl >> $TR/kprobe_events
echo r:vw_r drm_wait_vblank_ioctl \$retval >> $TR/kprobe_events
echo 1 > $TR/events/kprobes/enable
echo 1 > $TR/tracing_on

I=0
while [ "$I" -lt "$SWIPES" ]; do
    input swipe 540 1800 540 400 300
    sleep 1
    input swipe 540 400 540 1800 300
    sleep 1
    I=$((I+1))
done
sleep "$DUR"

echo 0 > $TR/tracing_on
echo "=== waitNextVsync failures (EINVAL):"
grep vw_r $TR/trace | grep -c ffffffea
echo "=== waitNextVsync successes:"
grep vw_r $TR/trace | grep -c 0x0$
echo > $TR/kprobe_events