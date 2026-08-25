# ProcessX (Swift) — native macOS menu bar app

Live CPU in the menu bar; click for the process list, one-click deprioritize,
QuickFast, the Auto-tame watchdog, and Quit / Force Quit. No subprocesses, no
HTTP server, no dependencies.

## Build & install

```sh
./bundle.sh                      # -> build/ProcessX.app + build/ProcessX-<version>-universal.zip
cp -R build/ProcessX.app /Applications/
open /Applications/ProcessX.app

ARCHES=arm64 ./bundle.sh         # fast local build, host arch only
NOTARIZE=no ./bundle.sh          # skip the Apple round-trip
```

Ship the zip `bundle.sh` produces — don't zip the app yourself. The notarization
ticket is stapled *into* the `.app`, so a zip made before stapling contains an
app with no ticket. That artifact still passes `spctl` on the machine that built
it (Gatekeeper just asks Apple over the network) and still shows "Apple cannot
check it for malicious software" to a user whose first launch is offline —
nothing about the zip looks wrong. `bundle.sh` therefore builds it after
stapling, then extracts it again and fails the build unless the extracted app
validates its own ticket.

`bundle.sh` builds **universal** (arm64 + x86_64) by default. macOS 26 is the
last release supporting Intel Macs and they are still in the supported set — an
arm64-only bundle fails to launch there, and notarization does not catch it.

Signing follows what a first launch actually sees. Ad-hoc is enough to run
locally but a *downloaded* ad-hoc bundle is refused outright; a Developer ID
signature alone still gets "Apple cannot check it for malicious software". Only
signed + notarized + stapled opens cleanly, so `bundle.sh` does all three
whenever a Developer ID certificate is present, then asserts the result with
`spctl --assess` — the string that matters is `source=Notarized Developer ID`.

Notarization credentials come from a `notarytool` keychain profile, created once:

```sh
xcrun notarytool store-credentials ProcessX-Notary \
  --apple-id you@example.com --team-id TEAMID
```

A profile is per Apple ID + team, **not** per app, so an existing profile for the
same team works as-is — `bundle.sh` probes for one rather than requiring a
particular name. Set `NOTARY_PROFILE` to pin it.

Two things that will otherwise cost you a release:

- **A stored profile is invisible to the `security` CLI.** Neither
  `security find-generic-password -s com.apple.gs.notary.tool` nor
  `security dump-keychain` can see it — notarytool keeps it in the
  data-protection keychain. Not finding it there is not evidence it is missing.
  `xcrun notarytool history --keychain-profile <name>` is the only reliable
  check, and is what the probe uses. (DiskX 1.0.2 shipped unnotarized on exactly
  this mistake, with a working profile present under a different name.)
- **A 403 "required agreement is missing or has expired" is an account
  problem, not a build problem.** Signing and pre-submission checks all pass
  first, so it looks like the artifact. Only the team's Account Holder can clear
  it, at developer.apple.com → Account → Agreements. The notary service then
  lags the account UI by a few minutes — don't re-diagnose during that window.

`bundle.sh` copies `AppIcon.icns` (the blue heartbeat mark) into the bundle. To
change the icon, edit `assets/make_icon.swift` and run `assets/build_icon.sh`,
which redraws every size with CoreGraphics and recompiles the `.icns`.

It's a windowed app with a Dock icon plus a menu-bar glance. Quit from the
window or the popover's Quit button. To uninstall, quit it and drag the app to
the Trash (settings live in `defaults delete dev.honato.processx`).

## Verify

```sh
swift run -c release ProcessX --selftest        # 101 checks, real syscalls
swift run -c release ProcessX --render out.png --dark   # rasterise the UI
```

`--selftest` exercises the real stack end-to-end: it spawns its own busy child
process, throttles it through the same code path a button click uses, and asserts
the *kernel* moved it to the background band and back. For the cap it runs a real
SIGSTOP/SIGCONT duty cycle, kills a stand-in parent to prove the guardian resumes
after a `SIGKILL`, and checks nothing is left suspended afterwards. Quit is
exercised the same way: its own children are ended by `SIGTERM`, one of them
suspended first (the capped-app case), and one that traps `SIGTERM` to prove
Force Quit is the rung that always works.

Checks that assert an **absolute CPU percentage** report `SKIP` rather than `FAIL`
when the machine has more than 1.5 runnable threads per core: a spinning child
cannot reach 100% of a core against a deep run queue, and the people most likely
to run `--selftest` are by definition on a Mac that is too busy. The skip line
prints what it measured, so a real regression is still visible. Mechanism checks
— does the duty cycle engage, does anything stay suspended, does the guardian
resume — are load-independent and always assert.

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
a known-busy process reads ~100% — a magnitude, not "> 0", because "> 0" would
have passed while being 41× wrong. That assertion is the one that has to stand
down on an oversubscribed machine, since the child cannot get a core to read.

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

### Naming a renderer

The renderer half of the row names what it honestly can, and nothing more.

* **Extensions are not tabs.** Chromium runs extensions in renderer processes
  with the same bundle name, and they were previously all labelled tabs — 13 of
  36 on a real Chrome. `--extension-process` in the launch arguments is the only
  thing that separates them (`ProcArgs.swift`, read once per process and cached
  against `pid + start time`, because pids are recycled).
* **"Above the background band" is not "on screen".** Chrome demotes a hidden
  tab's renderer lazily, so the band means *not parked*. Measured: 14 page
  renderers above the band against 4 tabs actually on screen.
* So the on-screen tab names are stated **once**, above the rows, where they
  claim nothing about any single one. A row prints a name only when the
  arithmetic leaves no choice — one tab on screen and one renderer above the
  band — a *maybe* when a single on-screen tab has several candidate renderers,
  and a shortlist only when the visible rows do not outnumber the on-screen
  tabs. `BrowserProcs.rowName` decides this, and `--selftest` pins every branch.

## Quit and Force Quit

The power menu on a row ends a process instead of slowing it — the one action
here with no way back, which is why it is two rungs and not one.

**Quit** asks. For anything macOS knows as an application that is
`NSRunningApplication.terminate()`, the same request the Dock's Quit sends, so
the app runs its own shutdown: a "Save changes?" sheet appears and the app
decides when to go. A signal would not do this — a Cocoa app has no `SIGTERM`
handler, so the default disposition just ends it, unsaved work and all, and
"Quit" would be a second Force Quit wearing a friendlier label. Non-app
processes (daemons, CLI sessions) do get `SIGTERM`, which is the same bargain
for them. Asking goes to the roots of the process tree, not to all 90 helpers:
an app shuts its own helpers down.

**Force Quit** doesn't ask — `SIGKILL`, every pid in the group, because a killed
parent has no chance to take its children with it. Unsaved work is gone. Return
is unbound on that alert so a stray keypress can't take it.

Three details that are the difference between working and looking like it works:

- A **suspended process never runs**, so it can neither see a `SIGTERM` nor
  answer a quit event. Quit sends `SIGCONT` first, and quitting a capped group
  releases its cap before asking — otherwise capped apps would silently ignore
  the button.
- **A request is not an outcome.** An app asked to quit may put up a save sheet,
  or refuse outright; both look exactly like a button that did nothing. The
  status line checks back a few seconds later and says which it was.
- **Identity is re-read immediately before signalling**, same guard as the cap:
  a sample is up to two seconds old, and killing the wrong process because a pid
  was recycled has no Restore afterwards.

Refused outright: ProcessX itself, anything ProcessX is running *inside* (the
terminal that launched it, and the shell under it — ending one of those takes us
down mid-action), protected system processes, and other users' processes. Media
and call apps are *not* refused: QuickFast skips them because it acts on its own,
and a button you pressed is a decision, not a surprise.

## Safety

- Never touches: the frontmost app (including a CLI in the frontmost terminal),
  protected system processes, media/call apps (QuickFast + auto-tame only), other
  users' processes, or itself.
- Every throttle is recorded with its origin (manual / QuickFast / auto) so
  Restore only undoes our own work.
- Records are identity-guarded by executable path, so a recycled PID is never
  acted on.
- Auto-tame is **off** by default.
- **Quit / Force Quit** never touch ProcessX, its own ancestors, protected
  system processes, or another user's work; Force Quit confirms in an alert
  where Return is unbound.
- The **hard CPU cap** is the one action that suspends, so it is gated harder
  than the rest: no override for media and call apps, no terminals or shells,
  nothing already suspended by something else, never the foreground group, and
  released the moment the app comes to the front. A cap survives nothing — the
  pid list is written to disk before the first `SIGSTOP`, a signal handler
  resumes on any catchable fatal signal, and a detached guardian process resumes
  after a `SIGKILL`.
