# shark8-smartrefresh-gsi

KernelSU module and diagnostic kit that fixes visible screen tearing while
scrolling at 120Hz on the Blackview Shark 8 running an AOSP/PHH GSI over the
stock MTK vendor image, and replaces the broken dynamic-FPS with a clean
touch-driven 60/120 Hz governor.

The same two properties fix the tearing AND kill the stock dynamic FPS (they
are the same switch: the GSI's `persist.sys.phh.dynamic_fps` mirrors into
SF's content detection via `/system/etc/init/vndk.rc`). The governor brings
the power saving back without the tear churn.

Tested on: SHARK8RU0006472, AOSP GSI TP1A.220624.014 (user build) + KernelSU
0.9.4, vendor hwcomposer-2-3 (mtk_common).

## Root cause

The panel's vblank is alive and well (disp_aal0 IRQ ticks at exactly 120Hz,
`drmWaitVBlank` on `/dev/dri/card0` succeeds with real timestamps), but the
single "smart refresh" feature on this stack kept **re-applying the display
mode every ~200-400ms**: SurfaceFlinger's content detection
(`ro.surface_flinger.use_content_detection_for_refresh_rate`), fed at boot by
`persist.sys.phh.dynamic_fps` through `/system/etc/init/vndk.rc` -- the two
toggles are one switch split across two UIs.

Every mode re-application makes the kernel run
`drm_crtc_vblank_off` -> `..._vblank_on`. While the vblank is off, the vendor
HWC's `DrmModeResource::waitNextVsync` (a plain `drmWaitVBlank`, type
RELATIVE seq=1) fails instantly with -EINVAL. During those windows the HWC
presents/validates OVL layers with no anchor to the scanout, so a frame
submitted mid-window shows up as a tear line. With the churn running
continuously, scrolling hit such windows constantly.

### Evidence (kprobe trace of drm_wait_vblank_ioctl)

Before: bursts of `arg1=0xffffffea` (-22, EINVAL) every ~1s while vblank was
cycled by kernel threads `mtk_drm_disp_id`/`dis_ki` (drm_crtc_vblank_off) --
~40% of waits failed.

After (both props off): `0` failures, `21/21` successes under active swipes,
persistent across reboot.

## Fix

Exactly two properties, applied early enough for SurfaceFlinger to read them
at startup (module `system.prop`, injected by ksud before SF starts):

```
ro.surface_flinger.use_content_detection_for_refresh_rate=0
persist.sys.phh.dynamic_fps=0
```

Result: the panel stays locked at 120Hz, vblank never turns off, the HWC's
vsync wait always succeeds, SF locks to the real hardware clock, and tearing
is gone.

## FPS governor

With both props off the panel would be stuck at 120Hz forever. The module now
ships `fps_governor.sh` (started from `service.sh`), a tiny root daemon that
watches the raw touchscreen node (`fts_ts`, located via sysfs by name --
currently `/dev/input/event2`):

- a touch frame on `/dev/input/event2`  -> force 120 Hz
- while a finger is held down (`BTN_TOUCH=1` latch) -> keep 120 Hz, even if the
  finger stops moving and the idle timer expires. This makes "reading a list
  with a resting finger then flinging again" hit no 60->120 panel switch.
- finger up and no touch for `IDLE_S` seconds (default 6) -> drop to 60 Hz

The switch goes through the DisplayModeDirector user-settings votes:

```
settings put system min_refresh_rate 120  (or 60)
settings put system peak_refresh_rate 120  (or 60)
```

Verified behavior on this GSI:
- `60/60`  -> panel holds 60 Hz (values are NOT rewritten).
- `120/120` -> panel holds 120 Hz; the GSI normalizes the settings values to
  `Infinity`, which is harmless (the imposed mode sticks).
- The DMS `cmd display set-user-preferred-display-mode` path and a bare
  `settings put system refresh_rate_override` are dead on this stack; only
  the min+peak pair drives the panel.
- Values of `120` get rewritten to `Infinity` by the vendor fps normalization,
  which is why the governor always writes both min and peak.

Tuning: `setprop persist.sys.phh.fps_gov_idle <seconds>` before the daemon
starts. Logging to logcat is gated by `persist.sys.phh.fps_gov_log` (default
`1`; set `0` to disable). Logs are only written on rate transitions and
finger press/release -- never per motion frame -- so the hot path stays
clean.

Restart the governor manually (without reboot) after editing (kills the daemon
via its pidfile; the daemon's TERM handler also reaps the getevent child):

```
adb root
adb shell 'kill $(cat /data/adb/modules/shark8-smartrefresh/.fps_gov.pid)'
adb shell 'nohup sh /data/adb/modules/shark8-smartrefresh/fps_governor.sh &'
```

Do not use `pkill -f fps_governor.sh` from an interactive adb shell: the
pattern matches its own wrapper and kills the session. The daemon self-guards
against double starts via the pidfile.

### Startup robustness (v1.4)

The daemon died at startup after every reboot for a subtle reason: the
single-instance guard tested the pidfile pid with `kill -0` only. After a
reboot that pid is routinely reused by an unrelated daemon (on this device
`netd` took it), the guard saw "an instance is already running" and the
governor exited before doing anything - permanently, until the pidfile was
deleted by hand.

v1.4 fixes this three ways:

* the guard now validates `/proc/<pid>/cmdline` actually contains
  `fps_governor`; a stale pidfile entry for any other process is cleared and
  the daemon starts normally
* the pidfile (and fifo) are removed on every exit path (TERM/INT/HUP trap,
  getevent-death teardown), so a crashed instance cannot poison the next one
* `service.sh` removes stale pidfile/fifo at boot before starting, making
  every boot a clean start regardless of how the previous session ended

## Install

```
adb push module /data/adb/modules/shark8-smartrefresh
adb reboot
```

Remove with:
```
adb shell rm -rf /data/adb/modules/shark8-smartrefresh
adb reboot
```

## Verification

```
adb root
adb shell 'dumpsys SurfaceFlinger | grep ContentDetection'   # expect: false
adb shell getprop ro.surface_flinger.use_content_detection_for_refresh_rate  # 0
adb shell getprop persist.sys.phh.dynamic_fps                                # 0
adb shell sh /data/local/tmp/monitor_wait_vsync.sh 4 2       # expect 0 failures
```

The kprobe monitor prints the count of -EINVAL vs success results from the
HWC's waitNextVsync under synthetic swipes. Run it once with the fix removed
for the "before" picture (~40% EINVAL), then with the module for "after".
Push it first: `adb push tools/monitor_wait_vsync.sh /data/local/tmp/`.

Governor sanity (idle should settle at 60 Hz, then jump to 120 on touch):

```
adb shell getprop ro.surface_flinger.use_content_detection_for_refresh_rate  # 0
adb shell 'sleep 5; settings get system min_refresh_rate'   # 60 while idle
sendevent /dev/input/event2 3 47 0; sendevent /dev/input/event2 3 57 5
sendevent /dev/input/event2 3 53 540; sendevent /dev/input/event2 3 54 1200
sendevent /dev/input/event2 1 330 1; sendevent /dev/input/event2 0 0 0
adb shell 'sleep 2; settings get system min_refresh_rate'   # Infinity (=120)
adb shell logcat -d -s fps_gov:*                            # transitions logged
```

Note on synthetic events: the fts_ts vendor driver drops injected full press
frames (ABS_MT_TRACKING_ID set from userspace is rejected), but it does
deliver the release frame (`3 57 -1; 1 330 0; 0 0 0`) and BTN_TOUCH lines from
real fingers. So the `sendevent` press above still proves the governor reacts;
for a hands-free latch test inject only the release frame. Real-finger
validation: hold the screen still for > `IDLE_S` seconds -- the panel must
stay at 120 the whole time (`settings get system min_refresh_rate` -> Infinity)
and only drop to 60 after lifting, then `logcat` shows `finger down` / `finger
up` / `set rate to 60 Hz`.

## Scroll jank check (render health)

Verified that the remaining "small stutters" seen while slowly scanning a long
list (e.g. Developer Options) were the governor's 60->120 mode transitions --
not the firmware's renderer (`dumpsys gfxinfo` over angry 30s swipe loops,
10 swipes / 20 swipes):

```
at 60 Hz:  302 frames, 0.33% janky, 90th pct 18ms, 99th pct 19ms, 0 missed vsync
at 120 Hz: 861 frames, 0.12% janky, 90th pct 12ms, 99th pct 16ms, 0 missed vsync
```

Both rates are healthy; nothing else in the firmware shows up as broken. The
only perceivable micro-hitches were the panel mode switches, which are now
suppressed while a finger is on the screen (see governor behavior above). Any
remaining hitch is the deliberately rare 60->120 switch on the first fling
after settling into the 120Hz too-late-because-idle case -- a stock-like
trade-off, not a defect.

## Layout

```
module/                KernelSU module (installable as-is)
  module.prop
  system.prop          the two fix props, applied at boot
  service.sh           starts the fps governor at boot
  fps_governor.sh      touch-driven 60/120 Hz daemon
tools/
  vblank_probe.c       standalone drmWaitVBlank probe (NDK cross-compile)
  monitor_wait_vsync.sh  kprobe watcher for waitNextVsync success/failure
```

## Design notes

- Do not force `min_refresh_rate`/`peak_refresh_rate` as a one-shot static
  lock: on this GSI `120` values get rewritten to `Infinity` and the DMS
  does nothing for active use; the governor writes the pair per transition
  instead. (NB: a static 60Hz lock also does not remove the tear-on-mode-
  change windows from the stock churn, so the props must stay off.)
- Do not use `debug.sf.disable_hwc_overlays`: forcing full client composition
  does not help (the client target is presented through the same unsynced
  HWC path) and adds GPU load/stutter to animations.
- `vendor.debug.sf.sw_vsync_fps=120` (HWC software vsync mode) was tested and
  made animation jank worse; reverting to the default path is correct.
- The governor logs to `logcat -s fps_gov`; it self-guards against double
  start via a pidfile and aborts if the touchscreen node is missing.
- Leave both stock toggles alone: Phh Treble Settings `Dynamic FPS` and
  `Display -> Refresh rate -> Adaptive`. Either one re-enables the tear
  churn; the module resets the props to 0 on every boot anyway. The
  governor's switching is fully independent of both UIs.
- Touch-only is a deliberate choice: the "smart" SF content detector is the
  exact component that tears on this GSI, and app-level `setFrameRate` hints
  are not reachable from a module without framework edits. Touch-driven
  switching is the same signal Android itself worships (InputDispatcher
  touch_hint -> peak refresh rate), just without the dying detector.