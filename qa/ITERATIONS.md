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
