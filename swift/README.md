# ProcessX (Swift) — native macOS menu bar app

Live CPU in the menu bar; click for the process list, one-click deprioritize,
QuickFast, and the Auto-tame watchdog. No subprocesses, no HTTP server, no
dependencies.

## Build & install

```sh
./bundle.sh                      # -> build/ProcessX.app
cp -R build/ProcessX.app /Applications/
open /Applications/ProcessX.app
```

`bundle.sh` copies `AppIcon.icns` (the blue heartbeat mark) into the bundle. To
change the icon, edit `assets/make_icon.swift` and run `assets/build_icon.sh`,
which redraws every size with CoreGraphics and recompiles the `.icns`.

It's a windowed app with a Dock icon plus a menu-bar glance. Quit from the
window or the popover's Quit button. To uninstall, quit it and drag the app to
the Trash (settings live in `defaults delete local.processx`).

## Verify

```sh
swift run -c release ProcessX --selftest        # 30 checks, real syscalls
swift run -c release ProcessX --render out.png --dark   # rasterise the UI
```

`--selftest` exercises the real stack end-to-end: it spawns its own busy child
process, throttles it through the same code path a button click uses, and asserts
the *kernel* moved it to the background band and back. It also asserts the
sampler reads that child at ~100% of a core — the guard against the mach-ticks
bug described below.

## How it differs from the Node version (`../`)

| | Node version | This |
|---|---|---|
| Process table | `ps` subprocess + regex parsing | `proc_listpids` / `proc_pidinfo` |
| Throttle | `taskpolicy -b` subprocess | `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)` |
| Read throttle state | own bookkeeping only | `pti_priority` — the kernel's own view |
| Memory | `vm_stat` subprocess + parsing | `host_statistics64` |
| GPU | `ioreg` subprocess + regex | IOKit registry directly |
| Frontmost app | 2× `lsappinfo` subprocess | `NSWorkspace` |
| CPU% | `ps` decaying average | true interval delta of task time |
| Cost | ~8 subprocesses every 2s | 0 subprocesses |
| Attack surface | localhost HTTP server (needed a CSRF guard) | none |
| UI | browser tab + `node server.js` in a terminal | menu bar |

`taskpolicy`'s own man page says it "uses the `setiopolicy_np(3)` and
`setpriority(2)` APIs" — so the Node version was forking a process to make a call
we can make directly.

## Two traps worth knowing

**`pti_total_user`/`pti_total_system` are mach absolute time units, not
nanoseconds.** On Apple Silicon the timebase is 125/3, so treating ticks as ns
under-reports CPU by ~41× — auto-tame would never fire and the CPU tile would
read ~2% on a maxed machine. On Intel `numer == denom == 1`, so this bug is
invisible there. `Sampler.ticksToNanos` converts explicitly; the self-test asserts
a known-busy process reads ~100%.

**A low `pti_priority` does not mean *we* throttled it.** Browsers park their own
inactive tabs in the background band. Using the kernel band to label rows "slowed"
lights up dozens of processes nobody touched and offers Restore buttons that do
nothing. So: `ThrottleStore` (ours, with origin + identity) drives the labels and
actions; the kernel band is used only to show "bg (self)" and to detect drift when
something else lifts our throttle.

## Browser tabs

macOS does not expose which renderer PID serves which tab — that mapping lives
only inside the browser. So instead of guessing, expanding a scriptable browser
row (Chrome and Chromium siblings — Brave, Edge, Vivaldi, Opera — plus Safari)
asks the browser itself over Apple Events and lists its **real open tabs by
name**. Double-click a tab (or its **Jump** button) to switch to it. The first
time, macOS asks permission for ProcessX to control that browser; if you decline,
the row shows a one-click link to the Automation settings. Non-scriptable
browsers (e.g. Firefox) still expand to their renderer processes. See
`BrowserTabs.swift`.

## Safety

- Never touches: the frontmost app (including a CLI in the frontmost terminal),
  protected system processes, media/call apps (QuickFast + auto-tame only), other
  users' processes, or itself.
- Every throttle is recorded with its origin (manual / QuickFast / auto) so
  Restore only undoes our own work.
- Records are identity-guarded by executable path, so a recycled PID is never
  acted on.
- Auto-tame is **off** by default.
