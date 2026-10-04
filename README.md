# shark8-smartrefresh-gsi

KernelSU module and diagnostic kit that fixes visible screen tearing while
scrolling at 120Hz on the Blackview Shark 8 running an AOSP/PHH GSI over the
stock MTK vendor image, and replaces the broken dynamic-FPS with a clean
touch-driven 60/120 Hz governor.

The tearing is a kernel-side bug: the MTK display low-power thread cycles
vblank off and on under the HWC's feet. `displowpower.sh` keeps that thread out
of the vblank path, and the governor brings the power saving back.

Tested on: SHARK8RU0006472, AOSP GSI TP1A.220624.014 (user build) + KernelSU
0.9.4, vendor hwcomposer-2-3 (mtk_common). Kernel 5.10.223-rama982-gki-v1.19.

## Root cause

`mtk_drm_idlemgr` (kernel threads `mtk_drm_disp_id` and `dis_ki`) decides the
display is idle and calls `drm_crtc_vblank_off`, then `drm_crtc_vblank_on`
about 20-25 ms later. The window is measured, not guessed: kprobes on both
functions plus on `drm_wait_vblank_ioctl` show the off/on pairs bracketing the
`waitNextVsync -1` failures one for one.

While the vblank is off, `drm_vblank_get` refuses new waiters with -EINVAL
(22), so the vendor HWC's `DrmModeResource::waitNextVsync` fails outright. The
HWC then presents with no anchor to the scanout, and a frame submitted inside
one of those windows shows up as a tear line.

The cycle is not tied to the refresh rate. Pinned 60, pinned 120 and adaptive
all cycle identically - roughly two to three off/on pairs per second at 120 Hz -
and all fail the same share of vsync waits. Nor is it SurfaceFlinger content
detection: that switch is off here and the cycle persists unchanged.

### Evidence

kprobe counts over 15 s windows, screen confirmed ON every second of the window.
`idletime` is the driver's own low-power threshold in frames; the stock value is
51, about 425 ms at 120 Hz, which is the period of the off/on cycle.

| `idletime` | `drm_crtc_vblank_off` | `drm_crtc_vblank_on` | `waitNextVsync -1` |
|---|---|---|---|
| 51 (stock) | 33, 34, 34, 41 | 33, 34, 34, 41 | 78, 87, 72, 53 |
| 5000 | 0, 0, 0, 0 | 0, 0, 0, 0 | 0, 0, 0, 0 |

Four reversals each way, and no window where the two disagree. Restoring 51
brings the failures straight back.

## Fix

`displowpower.sh` (run once per boot from `service.sh`) writes the display
low-power threshold:

```
/sys/kernel/debug/displowpower/idletime
```

Raised from the stock 51 to 5000 frames, `mtk_drm_idlemgr` never reaches its
idle decision while the panel is in use, so vblank stays up, the HWC's vsync
wait always succeeds, and tearing is gone.

The kernel keeps the value: it held for 120 s across a sleep/wake cycle and
governor rate changes without being rewritten, so this is a one-shot write and
not a watchdog. The panel still sleeps normally - `KEYCODE_SLEEP` still takes
`mScreenState` to OFF and back - because screen-off does not go through this
threshold.

Tuning: `setprop persist.sys.phh.disp_idletime <frames>` before the module
starts. Logging is gated by the same `persist.sys.phh.fps_gov_log` as the
governor.

### Why not from userspace

Holding a vblank reference from userspace would be the elegant fix, and it does
not work on this kernel:

* `DRM_VBLANK_FLAG_DONTBLOCK`, and any nonzero `flags` at all, is rejected with
  EBUSY, so a queued event cannot be armed.
* A blocking wait does not block. A kprobe on `drm_wait_vblank_ioctl` and
  `drm_vblank_get` counted 1,050,400 entries in 6 s (~175k/s) from a tight
  loop: the reference is taken and dropped within microseconds.

A/B over 15 s windows: baseline `off=21, fail=51`, with the hold running
`off=20, fail=52`. No effect. There is no module to patch either - the driver
is 3.5 MB of code linked into the kernel image (`/sys/module/mediatek_drm`
exists with no `parameters/`, and no `.ko` is on disk in `/vendor_dlkm`,
`/odm_dlkm` or `/vendor/lib/modules`). A debugfs threshold is the only lever
this stack offers.

### The two properties

```
ro.surface_flinger.use_content_detection_for_refresh_rate=0
persist.sys.phh.dynamic_fps=0
```

These are still set (`system.prop`). They kill the stock dynamic FPS and stop SF
from re-applying the display mode, which is worth having on its own, but they
are not what fixes the tearing: with both off, the vblank cycle measured above
was unchanged.

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

## Pinned rates (app control)

The daemon also takes a rate from outside, over the same fifo the touchscreen
events arrive on. `fps_ctl.sh` is that interface:

```
sh /data/adb/modules/shark8-smartrefresh/fps_ctl.sh 60
sh /data/adb/modules/shark8-smartrefresh/fps_ctl.sh 120
sh /data/adb/modules/shark8-smartrefresh/fps_ctl.sh adaptive
sh /data/adb/modules/shark8-smartrefresh/fps_ctl.sh status
```

- `adaptive` - the touch-driven switching above, nothing pinned.
- `60` / `120` - the panel is pinned and the loop stops writing to it entirely,
  which also means a pinned rate costs nothing while it is idle.
- `status` - `mode=... cur=... down=...`: the mode, the rate the daemon
  believes it reached, and whether a finger is on the glass right now.

Every one of those is answered before the command returns, a rate change
included. `fps_ctl.sh` writes into the fifo and reads the answer off a fifo of
its own, with a timeout: a change that did not land fails loudly instead of
being reported as done. With no daemon there is nobody to talk to, so the
script writes the votes itself for `60`/`120` and refuses `adaptive`, which
needs something choosing the rate.

The mode lives in the daemon and dies with it - a restart or a reboot comes
back `adaptive`. That is deliberate. A file left on disk is a mode nobody is
holding, and a UI showing `120` over a panel idling at 60 is lying. `status`
reports `mode=none` in that case and the app shows `stopped`.

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

### Startup robustness (v1.5)

v1.4 fixed the dead-on-boot guard. v1.5 removes the startup wait and the two
things that hid behind it:

* **no readiness probe.** There was a `while ! settings get ... ; sleep 2` loop
  that could idle for 90s before the daemon did anything. It guarded a case
  that does not need guarding: at boot the votes already read `Infinity`,
  i.e. 120, so in the default adaptive mode nothing is written at all. The
  check now lives in the write itself -- `go` only records the new rate after
  reading it back, so a write the provider refused is simply not latched and
  the next pass of the loop (at most `IDLE_S` later) tries again. Same
  self-healing, no waiting, and the log stays quiet because only a confirmed
  write is logged
* **a missing mode file reads as `adaptive`.** `mode_now` returned the raw
  file content, so with no `.fps_gov.mode` on disk it returned the empty
  string, which the idle pass compared against `mode=adaptive`, found
  different, and answered by calling `apply_mode` -- on every single pass,
  forever. The 60 Hz drop was below that branch and never ran, so a device
  where the app had never written a mode sat at 120 Hz permanently. The file
  is normalized to `adaptive` when it is absent or unreadable
* **`USR1` is trapped before anything can block.** The trap went in next to
  the loop while the pidfile had been written 90 lines earlier, so a `USR1`
  from the app during startup hit the default action of the signal and killed
  the daemon. It is installed immediately after the pidfile now

### Control channel (v1.6)

v1.5 asked for a rate with a file and a signal: `echo 60 > .fps_gov.mode`, then
`kill -USR1`. It worked, and it carried three problems that are not worth
keeping.

* **The writer could not tell whether it landed.** A file write plus a signal
  are both fire-and-forget. A `USR1` that lost a race left the mode file saying
  `60` and the panel at 120: two sources of truth, one of them a lie. (The
  v1.5 trap-before-pidfile fix was this same bug seen from the daemon's side.)
* **The state outlived the thing that owned it.** A reboot left
  `.fps_gov.mode` on disk, the daemon read it at startup and came up pinned, so
  a phone rebooted days later was still in a mode nobody had asked for since.
* **Three things to learn** where one will do: a file, a signal and a pidfile.

v1.6 is one fifo and a request/response. `SET <mode> <replypath>` and
`GET - <replypath>`, both answered `mode=... cur=... down=...` on the caller's
fifo. No file, no signal, no persisted mode.

The fifo has one reader, and three details make it behave:

* `getevent` writes it and the loop reads it, and the loop holds the read end
  open with `exec 3<"$fifo"`. A writer blocks on a fifo only while nobody is
  reading, so holding that end is what lets `fps_ctl.sh` hand over a command
  without waiting.
* It is opened **read-only**, not `<>`. Read-write would keep the write end open
  as well, and then a `getevent` that dies never closes it: the read below
  would then sit out a full `IDLE_S` on every pass instead of noticing at
  once. A read-only fd returns EOF the moment the last writer goes, which is
  what the `kill -0 $gepid` check behind it exists to act on.
* The reply fifo is opened `exec 9<>` by both sides, because with only one of
  them holding it the other blocks forever on the open. The daemon does it in a
  subshell: a failed redirection on `exec` is fatal in the calling shell, and
  the calling shell is the governor.
* A command is not a touch. The control branch `continue`s, so asking for
  status does not push the panel back to 120.

The cost is that the mode does not survive a restart, and `fps_ctl.sh` prices
that honestly rather than hiding it.

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
adb shell cat /sys/kernel/debug/displowpower/idletime                      # 5000
adb shell sh /data/local/tmp/monitor_wait_vsync.sh 4 2       # expect 0 failures
```

The node is the source of truth, and reading it is enough: `displowpower.sh`
writes it once at boot and the kernel keeps it, so if it reads `5000` the fix is
applied. The `idletime 51 -> 5000 frames` line it writes to `logcat -s
disp_idle` is a convenience only. The main ring buffer on this device is 256 KiB
and does not survive long, so on a device that has been up for a while the line
is usually already evicted and its absence means nothing. Read it within the
first few minutes after a reboot, or run `sh
/data/adb/modules/shark8-smartrefresh/displowpower.sh` to reproduce it.

The kprobe monitor prints the count of -EINVAL vs success results from the
HWC's waitNextVsync under synthetic swipes. Run it once with the fix removed
for the "before" picture (~40% EINVAL), then with the module for "after".
Push it first: `adb push tools/monitor_wait_vsync.sh /data/local/tmp/`.

Governor sanity (idle should settle at 60 Hz, then jump to 120 on touch):

```
adb shell getprop ro.surface_flinger.use_content_detection_for_refresh_rate  # 0
adb shell 'sleep 5; settings get system min_refresh_rate'   # 60 while idle
adb shell 'sh /data/adb/modules/shark8-smartrefresh/fps_ctl.sh status'
adb shell logcat -d -s fps_gov:*                            # transitions logged
```

Note on synthetic events: `sendevent` does not work on this device, and it
does not admit it. Every `write()` to an evdev node returns `EINVAL` - checked
for all nine event types on all six nodes, touchscreen and PMIC keys alike -
while toybox `sendevent` throws the write result away and exits 0. So an
injection appears to succeed and delivers nothing, and a control node filters
exactly as hard as the touch node does. (An earlier version of this file
claimed the `fts_ts` driver passed release frames through. It does not; nothing
gets through.) `input tap` is no help either, it injects at the InputDispatcher
and never reaches evdev.

The touch path is therefore verified by hand: hold the screen still for more
than `IDLE_S` seconds - the panel must stay at 120 the whole time
(`settings get system min_refresh_rate` -> `Infinity`) and only drop to 60 after
lifting. `logcat -d -s fps_gov` then shows `finger down`, then
`set rate to 60 Hz`, then `finger up`.

What the governor matches on is `0001 014a 00000001` (BTN_TOUCH down) and
`0001 014a 00000000` (up) as a suffix match, so it does not care whether the
line carries a device prefix. The format is not a guess: real `getevent -t`
output was captured on device and prints exactly `0001 014a 00000001`, and
BTN_TOUCH is `0x14a` under `EV_KEY` in the kernel ABI, so a touchscreen that
reports a finger reports it that way.

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
  system.prop          the two props, applied at boot
  service.sh           starts the low-power fix and the fps governor at boot
  displowpower.sh      raises /sys/kernel/debug/displowpower/idletime once
  fps_governor.sh      touch-driven 60/120 Hz daemon
  fps_ctl.sh           60 / 120 / adaptive / status over the governor's fifo
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