# ProcessX — QA iteration log

A QA loop was run against ProcessX: build an automated harness, then iterate
find → fix → re-verify until every check passes, across security, correctness,
performance, UI/UX, accessibility and responsive layout. Each iteration below
records what was found and what changed. Re-run everything with `node qa/qa.mjs`.

| # | Focus | Found | Fix / outcome |
|---|-------|-------|---------------|
| 1 | Baseline harness run | Server never validated the `Host` header → DNS-rebinding page could read `/api/snapshot` (process-list disclosure) and issue writes. Two harness artifacts (auto-injected `Content-Type`; EPIPE on oversized body). | Identified the real gap; separated it from harness bugs. |
| 2 | Server hardening | — | Added `badHost()` + centralized `Host` check on all `/api/*` routes; pinned static-file check to `PUBLIC_DIR + sep`. Fixed harness `req()` (opt-out CT, graceful reset handling). |
| 3–4 | Harness correctness | Two unit assertions used wrong expected values (`parentKey` lives on the internal model, not the public projection). | Corrected assertions → **131/131 green**. |
| 5 | Dark-theme contrast | QuickFast primary CTA: white on accent-blue = **3.64:1** (< AA 4.5). | Flagged; needed an accessible button token. |
| 6 | Light-theme contrast | **28** failures — `--muted` 3.4:1 (footers, headers, counts), status chips (warning **1.73:1**, good/active 3.27, critical), primary CTA 4.46. | Root-caused: hue tokens shared across themes break in opposite directions. |
| 7–9 | Contrast fix | — | Added `--btn`/`--btn-hover`, `--accent-strong`, and per-theme `--good-ink`/`--warn-ink`/`--crit-ink`; darkened light `--muted`. Verified via tint-aware measurement → **both themes AA** (light 4.94–7.53, dark 4.85–9.72). |
| 10 | Responsive (375 px) | Controls row overflowed the viewport (search collapsed to an icon, "Auto-tame" clipped); table columns cut off with no way to reach actions. | `.controls` `flex-wrap: wrap` + search flex-basis; `.card` horizontal scroll under 720 px. No more horizontal body scroll. |
| 11 | Keyboard / a11y | No explicit focus styling (relied on inconsistent UA default); search had only a placeholder; offline banner wasn't a live region. | Added `:focus-visible` ring (2 px accent-strong); `aria-label` on search; `role="alert"` on the offline banner. |
| 12 | UI action round-trip | — | Drove a real Slow → toast+Undo → Restore against a sacrificial process through the DOM; row flipped to "background" and back; server `slowed` returned to 0; real state file untouched. Search / sort / expand + `aria-expanded` verified. |
| 13 | Frontend performance | — | Full `render()` rebuild ≈ 8 ms; history buffers cap at 60; DOM capped at 80 rows; sparklines DPR-scaled. No growth or layout issues. |
| 14 | Lock-in + regression | — | Added a browser-free WCAG suite (computes ratios from CSS tokens) and a static-invariant suite (responsive/a11y/i18n). Full harness → **161/161 green**. Live server confirmed rejecting foreign `Host` (403). |

## Changes made

**`server.js`**
- `badHost()` + `Host`-header validation on every `/api/*` route (anti-DNS-rebinding, reads and writes).
- Static-file guard pinned to a real path boundary (`PUBLIC_DIR + path.sep`).
- `PROCESSX_STATE` env override so tests never touch the real state file.

**`public/style.css`**
- Accessible token set: `--btn`, `--btn-hover`, `--accent-strong`, `--good-ink`, `--warn-ink`, `--crit-ink`; darker light-mode `--muted`. Every text pair now clears WCAG AA in both themes.
- `.controls` wraps; table scrolls horizontally inside its card on narrow screens.
- `:focus-visible` ring for all interactive controls.

**`public/index.html`**
- `aria-label` on the filter input; `role="alert"` live region on the offline banner.

**`README.md`** — documented the Host/DNS-rebinding defense and the QA harness.

## Coverage / limits

- The harness targets the Node web app (`server.js` + `public/`), which is what
  `.claude/launch.json` runs. The native Swift menu-bar app under `swift/` has
  its own `--selftest` and is out of scope here.
- Contrast is checked at AA (4.5 normal / 3.0 large). Chip backgrounds are
  modelled as their translucent tint over the theme surface — the worst case.

---

# ProcessX's own CPU cost — profiling the native app

ProcessX's whole pitch is reducing CPU contention, so its own footprint is part
of the product claim. On a busy session it had been seen as the third-highest
CPU consumer on the machine. This section profiles the **native Swift app**
under `swift/` — previously out of scope above — and records what it cost, where
the cost was, and what changed.

Reproduce with `swift/.build/release/ProcessX --bench`, `--bench-live`,
`--bench-view`, and `qa/cpucost.sh <pid> <seconds> <label>`.

## How it was measured

`ps %cpu` is a decaying average and reported anything from 1.9% to 49% for the
same process, so every number here is a **cumulative-CPU-time delta**
(`ps -o time=` twice over a fixed wall-clock window) — that is what
`qa/cpucost.sh` does.

Three measurement traps had to be closed before any number meant anything:

| Trap | Effect | What it took |
|---|---|---|
| **Window occlusion** | A fully covered window stops redrawing. The moment a second window covered the running app it fell from 13.3% to 9.9% with no code change. | Measure one instance at a time, always frontmost and unobscured. |
| **E-core vs P-core billing** | On Apple Silicon CPU *time* is not a unit of work — the same build measured 57 ms and 178 ms per window pass depending on which cores it got. A benchmark launched from a shell inherits the shell's priority and lands on efficiency cores. | `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE)` in the benchmarks; `open -n` (not a shell launch) for live runs. |
| **Machine drift** | Load average moved between 9 and 25 during the session; single readings varied 3×. | Before/after builds measured **interleaved**, six 40 s rounds each, compared by median. |

## Baseline — the two suspects, separated

Measured on macOS 26.7, 8 cores (M3), ~870 processes, load average 9–25.

**Suspect 1 — sampling.** `--bench`, 25 iterations over 870 processes:

| Step | CPU per tick |
|---|---|
| `proc_listpids` (whole table) | 0.03 ms |
| `proc_pidinfo` PROC_PIDTASKALLINFO ×870 | 0.60 ms |
| `proc_pidpath` ×870 | 1.32 ms |
| **`Sampler.sample()` total** | **3.05 ms** |
| `Grouping.build()` | 11.04 ms |

At a 2 s tick that whole data layer is **~14 ms / 2 s = 0.7% of one core**.

**Suspect 2 — the view layer.** `--bench-live 30` runs the real `Monitor`, real
2 s timer, real sampling and grouping and publishing, with **no window and no
SwiftUI at all**: **1.15% of one core**. The same build with its window open and
frontmost: **~21% of one core** (median of six interleaved 40 s runs: 17.6, 18.2,
19.4, 22.7, 25.8, 29.3).

A `sample(1)` self-time profile of the main thread agrees to within a point:

| Bucket | % of samples | % of non-idle |
|---|---|---|
| idle (waiting for events) | 45.2% | — |
| SwiftUI attribute graph / display list | 28.2% | 51% |
| SwiftUI layout | 8.5% | 16% |
| conic-gradient rasterisation | 7.4% | 14% |
| other CoreGraphics | 3.0% | 5% |
| `Grouping.build` | 3.5% | 6% |
| libproc syscalls (`__proc_info`) | 1.2% | 2% |
| `Monitor.tick`, everything else | 0.7% | 1% |

**Verdict: ~90% of ProcessX's CPU was the view layer; ~9% was the model layer,
and only ~2% was the libproc walk the sampling hypothesis pointed at.**

## What the sampling hypothesis got wrong

The proposal was to cache `proc_pidpath` by pid, since a pid's path never
changes. Two reasons that was the wrong fix:

1. **The payoff isn't there.** `proc_pidpath` is 1.32 ms per tick — 0.065% of one
   core. Removing it entirely would not be visible next to a 21% reading.
2. **A pid's path *can* change.** `exec()` replaces the executable while keeping
   the pid, and pids are recycled. `Monitor.restore` compares `p.path` against
   the stored record precisely so a throttle is never lifted off a recycled pid;
   a stale cached path would poison that guard.

What *was* real in that area: the function allocated a fresh 4 KB `[CChar]` per
call — a thousand allocations per tick, costing more than the syscall. That is
now one reused scratch buffer, which is free and carries no correctness risk.

## Fixes

**1. The gauge rings' angular gradient — 14% of non-idle CPU.**
`RadialGauge` stroked its arc with an `AngularGradient`. CoreGraphics has no
hardware path for a conic gradient: it shades one in software with an `atan2f`
per pixel and re-shades on every change. `atan2f` was the single largest non-idle
leaf in the profile. Replaced with a top-to-bottom `LinearGradient`, which on a
circle agrees with the old ramp where it matters — `accent` at 12 o'clock,
`accent2` at 6, the midpoint at 3 and 9.

**2. The ring's 0.5 s ease — the single biggest item, ~14 points of one core.**
`.animation(.easeOut(duration: 0.5), value: progress)` on the trim made SwiftUI
rebuild the window's view graph and re-run `NSHostingView.layout` **once per
display frame** — roughly 10 ms each, thirty times per two-second tick, to move
an arc. Removing it alone took the app from 19.7% to 5.3%. Wrapping it in
`.drawingGroup()` instead changed nothing (17.6%): the cost is the graph pass,
not the rasterisation. The ring now steps, which is also the more honest reading
— the number inside it has always snapped, because the sample behind it is a
two-second average with nothing in between.

**3. `visibleGroups` was a computed property.** `MainWindow` reads it three times
per body pass (the "N apps" count, the empty check, the rows), so a filter plus a
sort over every group on the machine ran repeatedly to produce one answer. Now
recomputed exactly when its inputs change.

**4. `Model.isFront` and `Model.group(for:)` were linear scans.** `isFront` is
asked once per row per redraw *and once per process* in the auto-tame pass —
a quadratic walk over the process table every two seconds. Both are now
O(1) lookups off a precomputed set and key→index map.

**5. `Grouping.appName` ran a regex per ancestor per process.**
`path.range(of:options:.regularExpression)` recompiles an `NSRegularExpression`
on every call; `build()` called it thousands of times per tick, and ICU regex
matching showed up inside the sampling tick in the profile. Replaced with a
literal `.app/` search, plus a per-build memo since siblings share ancestors.
`Grouping.build()` went from **11.04 ms to 3.34 ms**.

**6. Rows observed the whole `Monitor`.** `Monitor` is a plain
`ObservableObject`, so every `@Published` change invalidates every observer, and
a tick changes eight of them. Sixty rows each held an `@ObservedObject`
subscription to reach a conclusion the parent had already reached. Rows now take
a plain reference; `MainWindow` does the observing.

**7. `ourThrottled` filtered a group's whole process list on every body
evaluation** — three times per row per redraw, and again inside the priority
sort's comparator. Now computed once per tick into `ProcGroup.throttledByUs`.

**8. `proc_pidpath`'s per-call 4 KB allocation** replaced with a reused buffer
(see above).

## A bug this work introduced, and the test that now catches it

Adding the key→index map broke the cap path: `Monitor.tick` sorts `model.groups`
*after* `Grouping.build` returns, so an index built inside `build` pointed every
key at the wrong group. `--selftest` caught it immediately — five failures in
`[cap via Monitor]`, where a cap was recorded against a different app than the
one the menu was opened on.

The fix makes the mistake unrepresentable: `Model.groups` rebuilds its index in
`didSet`, so any reordering re-indexes itself. A new check in `[grouping]` sorts
the model the way `tick` does and asserts the map still agrees with a linear
scan; it was confirmed to fail against the broken version.

## Result

| Measurement | Before | After |
|---|---|---|
| Window open and frontmost (median of 6 interleaved 40 s runs) | **21.1%** of one core | **7.6%** of one core |
| Quiet machine, best of those runs | 17.6% | **5.0%** |
| Model layer only, no view layer (`--bench-live`) | 1.15% | **0.61%** |
| One full window build + layout + draw (`--bench-view`) | ~0.9 ms per visible group | ~0.65 ms per visible group |
| `Sampler.sample()` per tick † | 3.05 ms | 2.41 ms |
| `Grouping.build()` per tick † | 11.04 ms | 2.83 ms |

† `--bench` figures are best-of-three on each side and were taken hours apart, so
the machine was not in the same state; treat them as the right order of magnitude
rather than a controlled comparison. The window-open rows above *are* controlled
— those runs were interleaved.

`--selftest` is green (123 checks) after every change.

**When these numbers were taken.** The interleaved window-open runs were measured
against `f1ddd58`. The branch was then rebased onto `e9eadfd`, which added
Chromium extension-process detection and a `RowName` type to the same rows. The
structural wins are unaffected — the ring no longer animates and the conic
gradient is gone, and those were 32 of the 21 points between them — but that
figure was taken before the row work landed, and the row work is not free.

**Re-measured on the merged tree.** Installed build 2026.0825.1448 (universal,
notarized), window open, 877 processes, load ~22–25, same CPU-time-delta method
as the 20.8% baseline: **7.0% and 7.2% of one core** over two independent 40 s
samples. So the row work upstream added did not eat the win: ~20.8% -> ~7.1%,
about 3x, with the window open and visible.

The headless controls on the same build, for the record: `--bench-live` puts the
model layer at **0.60% of one core** with no window at all, and `--bench` puts
`Sampler.sample()` at 3.28 ms and `Grouping.build()` at 2.87 ms per tick over 839
processes (`Grouping.build` was 11.04 ms before the byte-scan). The gap between
0.60% and 7.1% is the view layer, and it remains where any further work belongs.

`--bench-view` is the wrong instrument for re-checking this, and it is worth
saying why: `ImageRenderer` draws one static frame, so it cannot see the cost of
a view that re-lays-out thirty times a tick. It measures view *construction*,
which is what fixes 3–7 above address; the two large wins are invisible to it and
only show up in a live window.

## Second pass — not drawing a window nobody can see

The profile said the view layer was ~90% of the cost, and that the cost tracked
window visibility: covering the window took the app from 13.3% of a core to
9.9%. That 9.9% is the finding. AppKit stops the *rasterisation* of a covered
window and nothing else — the SwiftUI graph pass and `NSHostingView.layout` keep
running, drawing a window for nobody.

`Monitor` now stops publishing when neither the main window nor the menu popover
is on screen. Sampling, grouping, auto-tame and cap reconciliation are untouched;
the app has to keep deciding things whether or not anyone is watching. Only the
`@Published` assignments — the ones that invalidate the window — are gated.

Two consequences worth knowing:

- `model`, `throttled`, `caps` and the two histories are no longer `@Published`.
  `Monitor` is a plain `ObservableObject`, so *any* published assignment
  invalidates the window; there is no way to keep those five current for the
  app's own logic while staying quiet for the view.
- The menu-bar percentage moved to its own small observable object, so the glance
  stays live while the window is silent. It cannot live on `Monitor`: publishing
  it there would drag the window's view graph along behind it.

| Window 100% covered, interleaved at equal depth | CPU |
|---|---|
| before this change (`5e84182`) | 3.65%, 3.99% |
| after | 1.34%, 1.37% |

**~2.8x, and 1.36% is close to the model-layer floor** (`--bench-live` reads
0.61–0.81%). `--selftest` asserts the mechanism rather than the symptom: it
counts `objectWillChange` emissions, and a hidden tick now emits none where it
emitted four — while still refreshing the process table and the menu bar.

Also in this pass: the popover's four row types stopped holding their own
`@ObservedObject`, matching the window's rows.

**Limit.** `NSWindow.occlusionState` reports "not visible" only when a window is
*entirely* covered. A window with a corner showing pays full price.

## Limits — what is not fixed

- **The <5% target is met on a quiet machine, not on a busy one.** Final readings
  ranged 5.0%–13.7% across six runs. The spread is not noise in the measurement;
  it is the machine. Under load the app's work migrates to efficiency cores,
  where identical work bills more CPU-seconds, and a pointer resting over the
  table re-renders rows continuously.
- **The remaining cost is one window redraw per tick, ~50 ms of CPU.** That is
  inherent to rebuilding ~15 rich rows and four gauge cards in SwiftUI, and
  cutting it further needs the rows to take a small `Equatable` value instead of
  the whole `ProcGroup` (which carries every `ProcSample` in the group), so
  SwiftUI can skip subtrees that did not change. Not attempted here.
- **Ablation below the ~2× noise floor was not possible on this machine.**
  Removing the row tooltip, the cap menu, the glass button style and the Liquid
  Glass theme all produced differences smaller than the run-to-run spread. Those
  are unmeasured, not cleared.
- **Cost tracks window visibility.** A ProcessX whose window is covered by
  another window costs a fraction of one that is on top. Menu-bar-only operation
  is the cheap mode by a wide margin (0.61% vs 5–14%), which is worth saying in
  the README rather than leaving users to discover.
