# ProcessX

A macOS process & priority monitor with one-click reprioritization and a
**QuickFast** button that makes an overloaded Mac responsive again.

![ProcessX](https://img.shields.io/badge/macOS-taskpolicy-blue)

**Website:** <https://avantigroupai.github.io/processx-web/> ·
**Native menu-bar app:** [`swift/`](swift/) ·
**QA log:** [`qa/ITERATIONS.md`](qa/ITERATIONS.md)

Two builds share one policy engine: a native Swift menu-bar app (zero
subprocesses, reads the kernel directly) and the zero-dependency Node web app
documented below.

## Run it

```sh
node server.js          # -> http://localhost:4747
# or
npm start
npm test                # QA harness (CSRF, rebinding, fuzz, e2e, a11y)
```

No npm dependencies, no admin rights, nothing to install.

Policy constants (critical processes, media-safe list, QuickFast patterns, PID
caps) live in `policy.json` and are loaded by the Node server under `lib/`.

## What it does

- **Live monitor** — CPU, GPU (device utilization), memory + memory-pressure and
  swap, sampled every 2 s. Processes are grouped per app the way Activity
  Monitor does it (Chrome + its 100 helpers = one row), and terminal-hosted CLI
  sessions (e.g. a `claude` Code session) surface as their own top-level rows
  instead of hiding inside "Terminal".
- **Browser tabs** — expanding a browser row lists its renderer processes
  ("tab / page"), so one heavy tab can be slowed without touching the browser.
  (macOS does not expose tab *titles* per renderer without a debugging port, so
  rows are identified by renderer PID.)
- **One-click "Slow down"** — moves a process (or a whole app group) into
  macOS's background resource band via `taskpolicy -b -p PID`. The scheduler
  throttles its CPU, disk I/O and timers. **Fully reversible** with "Restore"
  (`taskpolicy -B`) — which is why ProcessX uses taskpolicy instead of `renice`
  (a nice value can never be lowered back without root).
- **QuickFast** — one click to make the system snappy: pushes background hogs
  into the low-priority band. Targets processes matching *claude / cowork /
  anthropic* (Claude Desktop, Claude Code, Cowork sessions) plus anything else
  using ≥ 25 % of a core in the background. It never touches:
  - the frontmost app (what you're actively using),
  - protected system processes (WindowServer, Finder, coreaudiod, …),
  - media / call apps (Music, Spotify, Zoom, Teams, FaceTime, …),
  - processes owned by other users,
  - ProcessX itself.
  Everything QuickFast does is listed in a toast and undone by **Restore all**.
- **Auto-tame (watchdog)** — optional setting ("Auto-tame background hogs").
  When ON, any *background* process that stays above the CPU threshold for
  ~8 s (3 consecutive ticks) is moved to the background band automatically —
  the classic case being an `ffmpeg` encode that should finish quietly on the
  efficiency cores instead of starving the UI. Bringing an auto-tamed app to
  the foreground restores it instantly (focus rescue), and a manually restored
  process gets a 10-minute cooldown so the watchdog never fights you. The same
  protected/media/foreground exclusions as QuickFast apply.
- **Hard CPU cap (native app only, opt-in)** — set from the speedometer menu on
  an app row: "Cap at 25% of a core" holds that app's whole process group under the
  number. This is the one action that *suspends*: macOS exposes no per-process
  CPU quota (`RLIMIT_CPU_USAGE_MONITOR` reports a breach, it can't hold a process
  under one), so a cap is duty-cycled `SIGSTOP`/`SIGCONT` with a closed loop that
  measures the group's real CPU each 200 ms period and adjusts the run window.
  Because a suspended app can't respond, it's gated harder than everything else:
  never the foreground app, never system, media or call apps, never terminals or
  shells, never a process something else already suspended, released instantly
  when you bring the app to the front, and shown behind a one-time explainer.
  Crash safety is three-layered — the pid list is written to disk *before* the
  first `SIGSTOP`, a signal handler resumes everything on any catchable fatal
  signal, and a detached guardian process (`ProcessX --cap-guardian`) waits on the
  app's exit via `kqueue` and resumes for it after a `SIGKILL`. Deliberately not
  in the Node build: an HTTP endpoint that can freeze applications is a worse idea
  than a menu item.
- **Quit / Force Quit (native app only)** — the power menu on a row, for when
  slowing something down isn't the answer. **Quit** asks: for an app that's
  `NSRunningApplication.terminate()`, the same request the Dock's Quit sends, so
  the app runs its own shutdown and can put a save prompt on screen (a bare
  `SIGTERM` would not — a Cocoa app has no handler for it, so "Quit" would just
  be Force Quit with a nicer label). Non-app processes get `SIGTERM`. **Force
  Quit** doesn't ask: `SIGKILL` to every process in the group, unsaved work
  included. Both confirm in an alert, and Return is unbound on the destructive
  one. A suspended process is resumed first (it can't answer a quit request while
  it isn't running) and a capped group has its cap released before being asked;
  because a request isn't an outcome, the status line checks back and says so if
  the app is still there. Refused for ProcessX itself, anything ProcessX is
  running inside, protected system processes and other users' work — but *not*
  for media/call apps, since the reason QuickFast skips those (it acts on its
  own) doesn't apply to a button you pressed. Deliberately not in the Node build,
  for the same reason as the cap: an HTTP endpoint that can kill applications is
  a worse idea than a menu item.
- **Persistence** — applied throttles are recorded in `.processx-state.json`
  (with the process's command path, so a reused PID is never mis-restored) and
  survive a server restart. Records for exited processes are pruned
  automatically.

## API

| Endpoint | Body | Effect |
|---|---|---|
| `GET /api/snapshot` | — | full system snapshot (`?f=1` forces a fresh sample) |
| `POST /api/quickfast` | `{ "dry": true? }` | apply (or preview) QuickFast |
| `POST /api/deprioritize` | `{ "pids": [..] }` or `{ "group": "a:Google Chrome" }` | background band |
| `POST /api/restore` | `{ "pids": [..] }`, `{ "group": .. }` or `{ "all": true }` | lift back out |
| `GET/POST /api/config` | `{ "auto": bool, "cpuThreshold": 5..100 }` | read / change settings |

## Security model

The server binds `127.0.0.1` only, but loopback is still reachable from any page
in your browser — so every state-changing `POST` is gated by an Origin /
`Sec-Fetch-Site` / `application/json` check (`crossSite()` in `lib/http.js`). That
blocks the CSRF vector where a malicious site silently throttles your processes.
Every `/api/*` route (reads included) also validates the `Host` header
(`badHost()`): a DNS-rebinding page — one that repoints its own domain at
`127.0.0.1` so the browser treats it as same-origin, defeating the Origin /
`Sec-Fetch-Site` check — still carries its own domain in `Host`, so it is
rejected before it can read your process list or issue an action. Forced samples
(`?f=1`) are rate-floored so a hostile loop can't burn CPU sampling. Mutating
POSTs are token-bucket rate-limited, PID lists are capped and sanitized, and
responses never echo raw OS stderr. Static responses send CSP, `nosniff`, and
`Referrer-Policy`. There is deliberately **no authentication**: ProcessX can only
affect processes you already own, which any local process running as you could
do by calling `taskpolicy` directly.

## Known limitations

- **PID reuse (TOCTOU):** between sampling and the `taskpolicy` call there is a
  millisecond-wide window where a PID could die and be recycled. Persisted
  records are identity-checked (stored `comm` vs live `comm`) on every sample,
  so a stale record is dropped rather than acted on — but the throttle itself is
  not transactional. In practice this requires PID wraparound inside that
  window.
- **GPU is system-wide**, not per process: macOS doesn't expose per-process GPU
  utilization without admin rights.
- **A cap can't hold a process below ~2 % of its unconstrained usage.** Every
  capped group keeps a sliver of each duty cycle so it is never frozen outright,
  which puts a floor under how low a cap can go. A capped app is also genuinely
  unresponsive while suspended — sockets can time out and timers drift — which is
  inherent to the technique, not a bug in this implementation.
- **Browser tabs are identified by renderer PID**, not page title — reading tab
  titles would require attaching to each browser's debug port.

## Tuning

QuickFast's name patterns and CPU threshold are constants at the top of
`server.js` (`QF_PATTERNS`, `QF_CPU_THRESHOLD`), as are the protected-process
(`CRITICAL`) and media-safe (`MEDIA_SAFE`) lists.

## QA

```sh
node qa/qa.mjs            # full suite (spawns an isolated throwaway server)
node qa/qa.mjs --only=sec # only the security suites
```

A zero-dependency harness ([`qa/qa.mjs`](qa/qa.mjs)) that spins up its own server
on a private port with an isolated state file (never touching your real
`.processx-state.json`) and runs ~160 checks across eight areas:

- **API contract** — snapshot / config shape, cache headers, 404s, static serving.
- **CSRF** — the full `Sec-Fetch-Site` / `Origin` / `Content-Type` matrix across
  every state-changing endpoint.
- **DNS rebinding** — foreign `Host` rejected on reads and writes; loopback allowed.
- **Path traversal** — encoded/`..`/backslash payloads can't escape `public/`.
- **Fuzzing** — junk pids, malformed JSON, oversized bodies, out-of-range config.
- **Performance** — cached/forced sample latency, concurrent-sample coalescing.
- **End-to-end** — spawns a *sacrificial* busy process, throttles and restores it
  through the real `taskpolicy` path, and asserts the state file and self-guard.
- **Accessibility** — WCAG AA contrast computed straight from the CSS tokens (both
  themes), plus responsive/a11y/i18n static invariants.

The E2E suite only ever throttles a process the harness spawns itself.
