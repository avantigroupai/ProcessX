#!/usr/bin/env node
'use strict';
/*
 * ProcessX — macOS process & priority monitor.
 *
 * Zero-dependency Node server. Samples the system with `ps`, `ioreg`,
 * `vm_stat` and `sysctl`, and reprioritizes processes with `taskpolicy`:
 *   taskpolicy -b -p PID   -> move process into the background resource band
 *                             (CPU, I/O and timer throttled by the scheduler)
 *   taskpolicy -B -p PID   -> lift it back out
 * Unlike renice, this is fully reversible without admin rights.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFile } = require('child_process');

const PORT = Number(process.env.PORT || 4747);
const ROOT = __dirname;
const PUBLIC_DIR = path.join(ROOT, 'public');
const STATE_FILE = process.env.PROCESSX_STATE || path.join(ROOT, '.processx-state.json');
const NCPU = os.cpus().length;
const MY_UID = process.getuid();
const SELF_PIDS = new Set([process.pid, process.ppid]);

// Never touch these, even on explicit request — killing responsiveness of the
// window server or login session is the opposite of what this tool is for.
const CRITICAL = new Set([
  'launchd', 'kernel_task', 'WindowServer', 'loginwindow', 'Finder', 'Dock',
  'SystemUIServer', 'ControlCenter', 'NotificationCenter', 'Spotlight',
  'coreaudiod', 'bluetoothd', 'tccd', 'securityd', 'opendirectoryd',
  'distnoted', 'cfprefsd', 'runningboardd', 'watchdogd', 'logd', 'notifyd',
  'launchservicesd', 'hidd', 'powerd', 'configd', 'mDNSResponder', 'syslogd',
  'UserEventAgent', 'coreservicesd', 'iconservicesd', 'pboard', 'fontd',
  'diskarbitrationd', 'universalaccessd', 'backboardd',
]);

// QuickFast never throttles these (real-time audio/video would stutter). The
// name may appear as a bundle segment ("zoom.us.app/…/aomhost") — so it can be
// followed by ".app" as well as a slash, space, or end-of-string. Without the
// optional ".app" the encoder helpers inside these bundles would be throttled.
const MEDIA_SAFE = /(^|\/)(Music|Spotify|VLC|Podcasts|zoom\.us|FaceTime|Microsoft Teams|Webex|OBS|QuickTime Player|Photo Booth)(\.app)?(\/|$| )/i;

// QuickFast target heuristics.
const QF_PATTERNS = [/claude/i, /cowork/i, /anthropic/i];
const QF_CPU_THRESHOLD = 25; // % of one core, per process

const TERMINALS = new Set(['Terminal', 'iTerm2', 'iTerm', 'Warp', 'Alacritty',
  'kitty', 'WezTerm', 'wezterm-gui', 'Ghostty', 'Hyper', 'Tabby']);
const SHELLS = new Set(['zsh', 'bash', 'sh', 'fish', 'tcsh', 'csh', 'dash',
  'login', 'tmux', 'screen', 'script', 'nohup', 'env', 'caffeinate', 'sudo']);
const INTERPRETERS = new Set(['node', 'bun', 'deno', 'python', 'python3',
  'python2', 'ruby', 'perl', 'java', 'osascript']);

// ---------------------------------------------------------------- utilities

function run(cmd, args, timeout = 5000) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout, maxBuffer: 32 * 1024 * 1024 },
      (err, stdout, stderr) => resolve({ ok: !err, out: stdout || '', err: (stderr || (err && err.message) || '').trim() }));
  });
}

function baseName(p) { return path.basename(p).replace(/^-/, ''); }

// ------------------------------------------------------------- action state
// pid -> { pid, comm, name, ts, origin }  origin: 'manual' | 'quickfast' | 'auto'
let bgMap = new Map();
// Auto-tame: throttle a background process only after it has been hot for
// AUTO_STREAK consecutive ticks (~= AUTO_STREAK * AUTO_INTERVAL ms), so brief
// spikes are never punished. A restored pid gets a cooldown so auto mode
// doesn't fight the user.
const config = { auto: false, cpuThreshold: QF_CPU_THRESHOLD };
const AUTO_STREAK = 3;
const AUTO_INTERVAL = 2500;
const RESTORE_COOLDOWN_MS = 10 * 60 * 1000;
const hotStreak = new Map();      // pid -> consecutive hot ticks
const restoreCooldown = new Map(); // pid -> ts of manual restore
let autoTimer = null;
let autoBusy = false; // reentrancy guard for autoTick

// Expire cooldown records. Called from both autoTick and restorePids: autoTick
// returns early when auto-tame is off, so without the second caller the map
// would grow forever across a long session of manual restores.
function expireCooldowns(now = Date.now()) {
  for (const [pid, ts] of restoreCooldown) {
    if (now - ts > RESTORE_COOLDOWN_MS) restoreCooldown.delete(pid);
  }
}

function loadState() {
  try {
    const j = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    for (const a of j.bg || []) bgMap.set(a.pid, a);
    if (j.config) {
      if (typeof j.config.auto === 'boolean') config.auto = j.config.auto;
      if (Number.isFinite(j.config.cpuThreshold)) config.cpuThreshold = j.config.cpuThreshold;
    }
  } catch { /* first run */ }
}
function saveState() {
  try {
    fs.writeFileSync(STATE_FILE, JSON.stringify({ bg: [...bgMap.values()], config }, null, 2));
  } catch (e) { console.error('state save failed:', e.message); }
}

// ---------------------------------------------------------------- samplers

async function samplePs() {
  const r = await run('/bin/ps', ['-axwwo', 'pid=,ppid=,ruid=,pcpu=,rss=,nice=,comm=']);
  const procs = [];
  for (const line of r.out.split('\n')) {
    const m = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)\s+(\d+)\s+(-?\d+)\s+(.*)$/);
    if (!m) continue;
    procs.push({
      pid: +m[1], ppid: +m[2], uid: +m[3], cpu: +m[4],
      rss: +m[5] * 1024, nice: +m[6], comm: m[7].trim(),
    });
  }
  // ok = the command succeeded AND produced a plausible process table. A failed
  // or truncated ps must NOT be treated as "these processes are gone" — that
  // would wipe every slowed-process record while the OS throttle is still live.
  return { ok: r.ok && procs.length > 5, procs };
}

async function sampleArgs() {
  const r = await run('/bin/ps', ['-axwwo', 'pid=,args=']);
  const map = new Map();
  for (const line of r.out.split('\n')) {
    const m = line.match(/^\s*(\d+)\s+(.*)$/);
    if (m) map.set(+m[1], m[2]);
  }
  return map;
}

async function sampleGpu() {
  const r = await run('/usr/sbin/ioreg', ['-r', '-d', '1', '-c', 'IOAccelerator']);
  let best = null;
  for (const m of r.out.matchAll(/"Device Utilization %"=(\d+)/g)) {
    const v = +m[1];
    if (best === null || v > best) best = v;
  }
  return best; // null when unavailable
}

async function sampleMem() {
  const r = await run('/usr/bin/vm_stat');
  const page = +(r.out.match(/page size of (\d+)/) || [0, 16384])[1];
  const grab = (label) => +((r.out.match(new RegExp(label + ':\\s+(\\d+)')) || [0, 0])[1]);
  const used = (grab('Pages active') + grab('Pages wired down') +
    grab('Pages occupied by compressor')) * page;
  const total = os.totalmem();

  let pressure = 'normal';
  const p = await run('/usr/sbin/sysctl', ['-n', 'kern.memorystatus_vm_pressure_level']);
  const lvl = parseInt(p.out.trim(), 10);
  if (lvl === 2) pressure = 'warning';
  else if (lvl === 4) pressure = 'critical';
  else if (!p.ok || Number.isNaN(lvl)) {
    const freePct = 100 * (total - used) / total;
    pressure = freePct < 6 ? 'critical' : freePct < 14 ? 'warning' : 'normal';
  }

  let swapUsed = null;
  const s = await run('/usr/sbin/sysctl', ['-n', 'vm.swapusage']);
  const sm = s.out.match(/used = ([\d.]+)([MG])/);
  if (sm) swapUsed = +sm[1] * (sm[2] === 'G' ? 1024 ** 3 : 1024 ** 2);

  return { total, used, pressure, swapUsed };
}

async function sampleFront() {
  const asn = (await run('/usr/bin/lsappinfo', ['front'])).out.trim();
  if (!asn) return null;
  const info = await run('/usr/bin/lsappinfo', ['info', '-only', 'pid', asn]);
  const m = info.out.match(/"pid"\s*=\s*(\d+)/);
  return m ? +m[1] : null;
}

// ------------------------------------------------------------- group model

function appNameOf(comm) {
  const m = comm.match(/\/([^/]+)\.app\//);
  return m ? m[1] : null;
}

function cliTitle(proc, argsMap) {
  const args = argsMap.get(proc.pid) || proc.comm;
  const toks = args.split(/\s+/);
  const t0 = baseName(toks[0] || proc.comm);
  if (INTERPRETERS.has(t0) && toks[1] && !toks[1].startsWith('-')) {
    return t0 + ' ' + baseName(toks[1]);
  }
  return t0;
}

function procLabel(proc, argsMap) {
  const b = baseName(proc.comm);
  if (/com\.apple\.WebKit\.WebContent/.test(proc.comm)) return 'Web page (tab process)';
  if (/com\.apple\.WebKit\.GPU/.test(proc.comm)) return 'Browser GPU process';
  if (/com\.apple\.WebKit\.Networking/.test(proc.comm)) return 'Browser networking';
  const helper = b.match(/Helper \(([^)]+)\)$/);
  if (helper) {
    const args = argsMap.get(proc.pid) || '';
    if (helper[1] === 'Renderer') {
      return /--extension-process/.test(args) ? b + ' — extension' : b + ' — tab / page';
    }
    return b;
  }
  // For an interpreter running a script (comm basename "node", args "node
  // server.js"), show the enriched "node server.js" title. cliTitle returns the
  // comm basename unchanged for everything else, so this only fires when it
  // actually adds the script name.
  const title = cliTitle(proc, argsMap);
  return title !== b ? title : b;
}

function buildModel(procs, argsMap, frontPid) {
  const byPid = new Map(procs.map((p) => [p.pid, p]));
  const groups = new Map();

  const assign = (p, key, name, kind, rootPid, parentKey) => {
    let g = groups.get(key);
    if (!g) {
      g = { key, name, kind, rootPid, parentKey: parentKey || null,
            cpu: 0, mem: 0, count: 0, bgCount: 0,
            active: false, critical: CRITICAL.has(name), system: true, procs: [] };
      groups.set(key, g);
    }
    g.cpu += p.cpu;
    g.mem += p.rss;
    g.count += 1;
    if (bgMap.has(p.pid)) g.bgCount += 1;
    if (p.uid === MY_UID) g.system = false;
    if (p.pid === frontPid || p.ppid === frontPid) g.active = g.active || p.pid === frontPid;
    g.procs.push(p);
    p.groupKey = key;
  };

  for (const p of procs) {
    if (p.pid === 0) continue;
    // Ancestor chain from self up to (not including) launchd.
    const chain = [p];
    let cur = p, guard = 0;
    while (guard++ < 40) {
      const parent = byPid.get(cur.ppid);
      if (!parent || parent.pid <= 1 || parent.pid === cur.pid) break;
      chain.push(parent);
      cur = parent;
    }
    // The app bundle closest to launchd owns the whole tree (Activity Monitor
    // style): Chrome Helper (Renderer) -> Google Chrome, etc.
    let appIdx = -1;
    for (let i = chain.length - 1; i >= 0; i--) {
      if (appNameOf(chain[i].comm)) { appIdx = i; break; }
    }
    if (appIdx >= 0) {
      const appName = appNameOf(chain[appIdx].comm);
      if (TERMINALS.has(appName)) {
        // Terminal-hosted work: group by CLI session (first non-shell command
        // below the terminal), so "claude" isn't buried inside "Terminal".
        let s = -1;
        for (let i = appIdx - 1; i >= 0; i--) {
          if (!SHELLS.has(baseName(chain[i].comm))) { s = i; break; }
        }
        if (s >= 0) {
          // parentKey ties this CLI session to its host terminal app, so
          // focusing the terminal counts as focusing the CLI (see groupIsFront).
          assign(p, 'c:' + chain[s].pid, cliTitle(chain[s], argsMap), 'cli', chain[s].pid, 'a:' + appName);
          continue;
        }
      }
      assign(p, 'a:' + appName, appName, 'app', chain[appIdx].pid);
    } else {
      assign(p, 'd:' + baseName(p.comm), baseName(p.comm), 'daemon', p.pid);
    }
  }

  const frontProc = frontPid ? byPid.get(frontPid) : null;
  const frontKey = frontProc ? frontProc.groupKey : null;

  const out = [];
  for (const g of groups.values()) {
    g.active = g.key === frontKey;
    const detail = g.procs
      .slice()
      .sort((a, b) => b.cpu - a.cpu || b.rss - a.rss)
      .slice(0, 15)
      .map((p) => ({
        pid: p.pid,
        label: procLabel(p, argsMap),
        cpu: +p.cpu.toFixed(1),
        mem: p.rss,
        nice: p.nice,
        bg: bgMap.has(p.pid),
        bgOrigin: bgMap.has(p.pid) ? (bgMap.get(p.pid).origin || 'manual') : null,
        mine: p.uid === MY_UID,
        critical: CRITICAL.has(baseName(p.comm)),
      }));
    out.push({
      key: g.key, name: g.name, kind: g.kind, active: g.active,
      critical: g.critical, system: g.system,
      cpu: +g.cpu.toFixed(1), mem: g.mem, count: g.count, bgCount: g.bgCount,
      procs: detail, more: Math.max(0, g.count - detail.length),
      actionable: g.procs.some((p) => p.uid === MY_UID && !CRITICAL.has(baseName(p.comm))),
    });
  }
  return { groups: out, byPid, frontKey, allGroups: groups };
}

// A process counts as "in the foreground" if its group is the front group, or
// if it's a terminal-hosted CLI (group key c:<pid>) whose host terminal app is
// frontmost. Without the parentKey hop, a `claude`/`cowork` session — the very
// thing this tool targets — would never register as focused, because its group
// is c:<pid> while the frontmost app group is a:<Terminal>.
function groupIsFront(groupKey, model) {
  if (!groupKey || !model.frontKey) return false;
  if (groupKey === model.frontKey) return true;
  const g = model.allGroups.get(groupKey);
  return !!(g && g.parentKey && g.parentKey === model.frontKey);
}

// ---------------------------------------------------------------- snapshot

let cache = { ts: 0, snap: null, model: null };
let inflight = null; // shared sampling promise — coalesces concurrent samples

const CACHE_MS = 900;       // normal poll cache window
const FORCE_FLOOR_MS = 350; // minimum gap between *forced* samples

async function getSnapshot(force = false) {
  // Coalescing stops a concurrent burst from spawning N subprocess fleets, but
  // sequential hammering still costs a sample each — and GET /api/snapshot?f is
  // reachable from any page (no CSRF guard applies to a read-only GET). So
  // forced samples are floored too: a hostile loop can't out-sample our own
  // poll. Actions reset cache.ts to 0, so they always bypass the floor and see
  // fresh data.
  if (cache.snap && Date.now() - cache.ts < (force ? FORCE_FLOOR_MS : CACHE_MS)) return cache;
  if (inflight) return inflight;
  inflight = sampleAll();
  try { return await inflight; } finally { inflight = null; }
}

async function sampleAll() {
  const [ps, argsMap, gpu, mem, frontPid] = await Promise.all([
    samplePs(), sampleArgs(), sampleGpu(), sampleMem(), sampleFront(),
  ]);
  const { ok: psOk, procs } = ps;

  // If ps failed, keep serving the last good snapshot rather than a broken
  // empty one — and, crucially, don't run the prune below against an empty
  // table (which would forget every slowed process).
  if (!psOk && cache.snap) return cache;

  // Prune background records: drop a pid that is gone, OR whose live comm no
  // longer matches what we throttled (the pid was recycled to a different
  // process — treating it as still-slowed would wrongly exempt the newcomer
  // from taming and offer a bogus Restore). Only when ps is trustworthy.
  let pruned = false;
  if (psOk) {
    const live = new Map(procs.map((p) => [p.pid, p]));
    for (const [pid, rec] of [...bgMap]) {
      const lp = live.get(pid);
      if (!lp || lp.comm !== rec.comm) {
        bgMap.delete(pid);
        hotStreak.delete(pid);
        pruned = true;
      }
    }
  }
  if (pruned) saveState();

  const model = buildModel(procs, argsMap, frontPid);
  model.argsMap = argsMap;
  const sumCpu = procs.reduce((s, p) => s + p.cpu, 0);
  const frontProc = frontPid ? model.byPid.get(frontPid) : null;

  const snap = {
    ts: Date.now(),
    ncpu: NCPU,
    loadavg: os.loadavg().map((v) => +v.toFixed(2)),
    cpu: { totalPct: +Math.min(100, sumCpu / NCPU).toFixed(1), sumPct: +sumCpu.toFixed(1) },
    gpu: { util: gpu },
    mem,
    front: frontProc
      ? { pid: frontPid, name: appNameOf(frontProc.comm) || baseName(frontProc.comm) }
      : null,
    config: { auto: config.auto, cpuThreshold: config.cpuThreshold },
    slowed: [...bgMap.values()].map((a) => ({ pid: a.pid, name: a.name, ts: a.ts, origin: a.origin || 'manual' })),
    groups: model.groups,
  };
  cache = { ts: Date.now(), snap, model };
  return cache;
}

// ----------------------------------------------------------------- actions

function actionEligible(p, { manual }) {
  const b = baseName(p.comm);
  if (SELF_PIDS.has(p.pid)) return 'is the ProcessX server itself';
  if (p.uid !== MY_UID) return 'owned by another user (needs admin)';
  if (CRITICAL.has(b)) return 'protected system process';
  if (!manual && MEDIA_SAFE.test(p.comm)) return 'media/call app (skipped by QuickFast)';
  return null;
}

async function applyBackground(pids, { manual, origin = 'manual' }) {
  const { model } = await getSnapshot(true);
  const applied = [], errors = [];
  for (const pid of pids) {
    const p = model.byPid.get(pid);
    if (!p) { errors.push({ pid, reason: 'no longer running' }); continue; }
    if (bgMap.has(pid)) continue;
    const why = actionEligible(p, { manual });
    if (why) { errors.push({ pid, reason: why }); continue; }
    const r = await run('/usr/sbin/taskpolicy', ['-b', '-p', String(pid)]);
    if (r.ok) {
      const name = appNameOf(p.comm) || baseName(p.comm);
      bgMap.set(pid, { pid, comm: p.comm, name, ts: Date.now(), origin });
      applied.push({ pid, name });
    } else {
      errors.push({ pid, reason: r.err || 'taskpolicy failed' });
    }
  }
  if (applied.length) { saveState(); cache.ts = 0; }
  return { applied, errors };
}

async function restorePids(pids) {
  const { model } = await getSnapshot(true);
  const restored = [], errors = [];
  for (const pid of pids) {
    const rec = bgMap.get(pid);
    if (!rec) continue;
    const p = model.byPid.get(pid);
    if (!p || p.comm !== rec.comm) {
      // Process died (or pid was reused) — nothing to restore.
      bgMap.delete(pid);
      continue;
    }
    const r = await run('/usr/sbin/taskpolicy', ['-B', '-p', String(pid)]);
    if (r.ok) {
      bgMap.delete(pid);
      hotStreak.delete(pid);
      restoreCooldown.set(pid, Date.now());
      restored.push({ pid, name: rec.name });
    } else errors.push({ pid, reason: r.err || 'taskpolicy failed' });
  }
  expireCooldowns();
  saveState();
  cache.ts = 0;
  return { restored, errors };
}

function groupPids(model, key) {
  const g = model.allGroups.get(key);
  return g ? g.procs.map((p) => p.pid) : [];
}

async function quickfast(dry = false) {
  const { snap, model } = await getSnapshot(true);
  const seen = new Set();
  const targets = [];
  for (const [pid, p] of model.byPid) {
    if (seen.has(pid) || bgMap.has(pid)) continue;
    if (groupIsFront(p.groupKey, model)) continue; // never the app you're using
    if (actionEligible(p, { manual: false })) continue;
    const grp = model.allGroups.get(p.groupKey);
    const hay = p.comm + ' ' + (model.argsMap.get(pid) || '') + ' ' + (grp ? grp.name : '');
    const nameHit = QF_PATTERNS.some((re) => re.test(hay));
    const cpuHit = p.cpu >= config.cpuThreshold;
    if (!nameHit && !cpuHit) continue;
    // Name-matched processes are throttled outright; CPU-matched ones only
    // when they are actually working (avoid throttling idle name-misses).
    if (nameHit && p.cpu < 1 && !cpuHit) continue;
    seen.add(pid);
    targets.push({ pid, name: appNameOf(p.comm) || baseName(p.comm), cpu: p.cpu, why: nameHit ? 'background agent' : 'high CPU' });
  }
  targets.sort((a, b) => b.cpu - a.cpu);
  if (dry) return { dry: true, targets, front: snap.front };
  const { applied, errors } = await applyBackground(targets.map((t) => t.pid), { manual: false, origin: 'quickfast' });
  return { targets, applied, errors, front: snap.front };
}

// -------------------------------------------------------------- auto-tame
// When enabled, a background process that stays above the CPU threshold for
// AUTO_STREAK consecutive ticks is throttled automatically (like the ffmpeg
// case: a batch encode that should finish quietly on efficiency cores).
// Bringing an auto-tamed app to the foreground lifts it back out instantly.

async function autoTick() {
  // Reentrancy guard: under heavy load a sample can outlast AUTO_INTERVAL, and
  // two overlapping ticks could otherwise coalesce onto the SAME snapshot and
  // both count it toward the hot streak — taming after fewer real samples than
  // AUTO_STREAK promises.
  if (!config.auto || autoBusy) return;
  autoBusy = true;
  try {
    const { model } = await getSnapshot(true);

    // Focus rescue: user switched to an auto-tamed app -> restore it.
    const focusRestore = [];
    for (const rec of bgMap.values()) {
      if (rec.origin !== 'auto') continue;
      const p = model.byPid.get(rec.pid);
      if (p && p.comm === rec.comm && groupIsFront(p.groupKey, model)) focusRestore.push(rec.pid);
    }
    for (const pid of focusRestore) {
      const r = await run('/usr/sbin/taskpolicy', ['-B', '-p', String(pid)]);
      if (r.ok) { bgMap.delete(pid); hotStreak.delete(pid); }
    }
    if (focusRestore.length) { saveState(); cache.ts = 0; }

    // Streak accounting + throttling.
    const now = Date.now();
    const toTame = [];
    const seen = new Set();
    for (const [pid, p] of model.byPid) {
      seen.add(pid);
      const hot = p.cpu >= config.cpuThreshold &&
        !groupIsFront(p.groupKey, model) &&
        !bgMap.has(pid) &&
        !actionEligible(p, { manual: false }) &&
        !(restoreCooldown.has(pid) && now - restoreCooldown.get(pid) < RESTORE_COOLDOWN_MS);
      if (!hot) { hotStreak.delete(pid); continue; }
      const streak = (hotStreak.get(pid) || 0) + 1;
      hotStreak.set(pid, streak);
      if (streak >= AUTO_STREAK) toTame.push(pid);
    }
    for (const pid of [...hotStreak.keys()]) if (!seen.has(pid)) hotStreak.delete(pid);
    expireCooldowns(now);

    if (toTame.length) {
      const { applied } = await applyBackground(toTame, { manual: false, origin: 'auto' });
      for (const a of applied) {
        hotStreak.delete(a.pid);
        console.log(`auto-tame: ${a.name} (pid ${a.pid}) -> background band`);
      }
    }
  } catch (e) {
    console.error('auto-tame tick failed:', e.message);
  } finally {
    autoBusy = false;
  }
}

function syncAutoTimer() {
  if (config.auto && !autoTimer) autoTimer = setInterval(autoTick, AUTO_INTERVAL);
  if (!config.auto && autoTimer) { clearInterval(autoTimer); autoTimer = null; hotStreak.clear(); }
}

// ------------------------------------------------------------------ server

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.json': 'application/json',
};

function send(res, code, body, type = 'application/json') {
  const data = type === 'application/json' ? JSON.stringify(body) : body;
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(data);
}

// Anti–DNS-rebinding. Binding loopback stops off-box packets, but a page at
// http://evil.example:PORT whose DNS has been rebound to 127.0.0.1 reaches us
// *as same-origin from the browser's point of view* — so it sends no Origin and
// Sec-Fetch-Site: same-origin, sailing past crossSite(). The one header it can't
// forge is Host: it still carries the attacker's domain. Requiring Host to name
// loopback closes the rebinding vector for reads (GET /api/snapshot leaks the
// process list) and writes alike. A missing Host (HTTP/1.0, some CLI clients) is
// allowed — those can't originate from a browser rebinding attack.
const OK_HOSTS = new Set([
  `localhost:${PORT}`, `127.0.0.1:${PORT}`, `[::1]:${PORT}`,
  'localhost', '127.0.0.1', '[::1]',
]);
function badHost(req) {
  const host = req.headers.host;
  if (!host) return false;
  return !OK_HOSTS.has(host.toLowerCase());
}

// CSRF defense. The server binds loopback, but any web page in the user's
// browser can still reach localhost. Every state-changing POST must therefore
// prove it came from our own origin:
//   - Sec-Fetch-Site (sent by all modern browsers) must be same-origin/none.
//   - An Origin header, when present, must be our own loopback origin.
//   - Content-Type must be application/json — a cross-site "simple request"
//     (the header-less CSRF vector) can only send text/plain or form types and
//     an application/json request triggers a preflight we never approve.
function crossSite(req) {
  const sfs = req.headers['sec-fetch-site'];
  if (sfs && sfs !== 'same-origin' && sfs !== 'none') return true;
  const origin = req.headers.origin;
  if (origin) {
    let host;
    try { host = new URL(origin).host; } catch { return true; }
    if (host !== `localhost:${PORT}` && host !== `127.0.0.1:${PORT}` && host !== `[::1]:${PORT}`) return true;
  }
  const ct = (req.headers['content-type'] || '').toLowerCase();
  if (!ct.startsWith('application/json')) return true;
  return false;
}

function readBody(req) {
  return new Promise((resolve) => {
    let buf = '';
    let done = false;
    const finish = (v) => { if (!done) { done = true; resolve(v); } };
    req.on('data', (c) => { buf += c; if (buf.length > 1e6) { finish({}); req.destroy(); } });
    req.on('end', () => { let v; try { v = JSON.parse(buf || '{}'); } catch { v = {}; } finish(v && typeof v === 'object' ? v : {}); });
    req.on('error', () => finish({}));
    req.on('aborted', () => finish({}));
  });
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  try {
    // Reject rebound/foreign-Host requests to the API surface before any work.
    if (u.pathname.startsWith('/api/') && badHost(req)) {
      return send(res, 403, { error: 'invalid host header' });
    }
    if (u.pathname === '/api/snapshot') {
      const { snap } = await getSnapshot(u.searchParams.has('f'));
      return send(res, 200, snap);
    }
    if (u.pathname === '/api/quickfast' && req.method === 'POST') {
      if (crossSite(req)) return send(res, 403, { error: 'cross-site request blocked' });
      const body = await readBody(req);
      return send(res, 200, await quickfast(!!body.dry));
    }
    if (u.pathname === '/api/config') {
      if (req.method === 'POST') {
        if (crossSite(req)) return send(res, 403, { error: 'cross-site request blocked' });
        const body = await readBody(req);
        if (typeof body.auto === 'boolean') config.auto = body.auto;
        if (Number.isFinite(body.cpuThreshold) && body.cpuThreshold >= 5 && body.cpuThreshold <= 100) {
          config.cpuThreshold = body.cpuThreshold;
        }
        syncAutoTimer();
        saveState();
      }
      return send(res, 200, { auto: config.auto, cpuThreshold: config.cpuThreshold });
    }
    if (u.pathname === '/api/deprioritize' && req.method === 'POST') {
      if (crossSite(req)) return send(res, 403, { error: 'cross-site request blocked' });
      const body = await readBody(req);
      let pids = Array.isArray(body.pids) ? body.pids.map(Number) : [];
      if (body.group) {
        const { model } = await getSnapshot(true);
        pids = pids.concat(groupPids(model, String(body.group)));
      }
      return send(res, 200, await applyBackground(pids, { manual: true }));
    }
    if (u.pathname === '/api/restore' && req.method === 'POST') {
      if (crossSite(req)) return send(res, 403, { error: 'cross-site request blocked' });
      const body = await readBody(req);
      let pids = Array.isArray(body.pids) ? body.pids.map(Number) : [];
      if (body.group) {
        const { model } = await getSnapshot(true);
        pids = pids.concat(groupPids(model, String(body.group)).filter((pid) => bgMap.has(pid)));
      }
      if (body.all) pids = [...bgMap.keys()];
      return send(res, 200, await restorePids(pids));
    }

    // static files
    let file = u.pathname === '/' ? '/index.html' : u.pathname;
    file = path.normalize(file).replace(/^(\.\.[/\\])+/, '');
    const full = path.join(PUBLIC_DIR, file);
    // startsWith(PUBLIC_DIR + sep) — the bare prefix would also match a sibling
    // like "<root>/publicX", so pin the check to a real path boundary.
    if (full.startsWith(PUBLIC_DIR + path.sep) && fs.existsSync(full) && fs.statSync(full).isFile()) {
      return send(res, 200, fs.readFileSync(full), MIME[path.extname(full)] || 'application/octet-stream');
    }
    return send(res, 404, { error: 'not found' });
  } catch (e) {
    console.error(e);
    return send(res, 500, { error: e.message });
  }
});

if (require.main === module) {
  loadState();
  syncAutoTimer();
  server.listen(PORT, '127.0.0.1', () => {
    console.log(`ProcessX running at http://localhost:${PORT}  (cores: ${NCPU}, uid: ${MY_UID}, auto-tame: ${config.auto ? 'on' : 'off'})`);
  });
} else {
  // Exposed for unit tests (require without starting the server).
  module.exports = { buildModel, groupIsFront, procLabel, cliTitle, MEDIA_SAFE, actionEligible };
}
