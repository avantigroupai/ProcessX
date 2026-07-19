'use strict';
const { run, baseName, mapPool } = require('./util');
const {
  CRITICAL, MEDIA_SAFE, QF_PATTERNS, ACTION_CONCURRENCY,
  AUTO_STREAK, AUTO_INTERVAL, RESTORE_COOLDOWN_MS, safeReason,
} = require('./policy');
const {
  bgMap, hotStreak, restoreCooldown, config,
  expireCooldowns, saveState,
} = require('./state');
const { appNameOf, groupIsFront } = require('./model');
const { getSnapshot, invalidateCache } = require('./sample');

const SELF_PIDS = new Set([process.pid, process.ppid]);
const MY_UID = process.getuid();

let autoTimer = null;
let autoBusy = false;
let actionBusy = false; // serialize user+auto mutations when needed
const actionQueue = [];

function actionEligible(p, { manual }) {
  const b = baseName(p.comm);
  if (SELF_PIDS.has(p.pid)) return 'is the ProcessX server itself';
  if (p.uid !== MY_UID) return 'owned by another user (needs admin)';
  if (CRITICAL.has(b)) return 'protected system process';
  if (!manual && MEDIA_SAFE.test(p.comm)) return 'media/call app (skipped by QuickFast)';
  return null;
}

/** Re-check process identity right before taskpolicy (TOCTOU mitigation). */
async function liveComm(pid) {
  const r = await run('/bin/ps', ['-p', String(pid), '-o', 'comm=']);
  if (!r.ok) return null;
  return r.out.trim() || null;
}

async function applyBackground(pids, { manual, origin = 'manual' }) {
  const { model } = await getSnapshot(true);
  const applied = [];
  const errors = [];

  await mapPool(pids, ACTION_CONCURRENCY, async (pid) => {
    const p = model.byPid.get(pid);
    if (!p) { errors.push({ pid, reason: 'no longer running' }); return; }
    if (bgMap.has(pid)) return;
    const why = actionEligible(p, { manual });
    if (why) { errors.push({ pid, reason: why }); return; }

    // Identity re-check immediately before throttle (TOCTOU).
    // ps -o comm= is often a short basename; sample may hold a full path.
    const live = await liveComm(pid);
    if (!live) { errors.push({ pid, reason: 'no longer running' }); return; }
    const liveBase = baseName(live);
    const sampleBase = baseName(p.comm);
    if (live !== p.comm && liveBase !== sampleBase && !p.comm.includes(liveBase) && !live.includes(sampleBase)) {
      errors.push({ pid, reason: 'process identity changed' });
      return;
    }

    const r = await run('/usr/sbin/taskpolicy', ['-b', '-p', String(pid)]);
    if (r.ok) {
      const name = appNameOf(p.comm) || baseName(p.comm);
      bgMap.set(pid, { pid, comm: p.comm, name, ts: Date.now(), origin });
      applied.push({ pid, name });
    } else {
      if (r.err) console.error(`taskpolicy -b pid=${pid}:`, r.err);
      errors.push({ pid, reason: safeReason(r.err, 'taskpolicy failed') });
    }
  });

  if (applied.length) {
    saveState(true); // flush immediately so persistence is durable across crash
    invalidateCache();
  }
  return { applied, errors };
}

async function restorePids(pids) {
  const { model } = await getSnapshot(true);
  const restored = [];
  const errors = [];

  await mapPool(pids, ACTION_CONCURRENCY, async (pid) => {
    const rec = bgMap.get(pid);
    if (!rec) return;
    const p = model.byPid.get(pid);
    if (!p || p.comm !== rec.comm) {
      bgMap.delete(pid);
      return;
    }
    const live = await liveComm(pid);
    if (!live) {
      bgMap.delete(pid);
      return;
    }
    const r = await run('/usr/sbin/taskpolicy', ['-B', '-p', String(pid)]);
    if (r.ok) {
      bgMap.delete(pid);
      hotStreak.delete(pid);
      restoreCooldown.set(pid, Date.now());
      restored.push({ pid, name: rec.name });
    } else {
      if (r.err) console.error(`taskpolicy -B pid=${pid}:`, r.err);
      errors.push({ pid, reason: safeReason(r.err, 'taskpolicy failed') });
    }
  });

  expireCooldowns();
  saveState(true);
  invalidateCache();
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
    if (groupIsFront(p.groupKey, model)) continue;
    if (actionEligible(p, { manual: false })) continue;
    const grp = model.allGroups.get(p.groupKey);
    const hay = p.comm + ' ' + (model.argsMap.get(pid) || '') + ' ' + (grp ? grp.name : '');
    const nameHit = QF_PATTERNS.some((re) => re.test(hay));
    const cpuHit = p.cpu >= config.cpuThreshold;
    if (!nameHit && !cpuHit) continue;
    if (nameHit && p.cpu < 1 && !cpuHit) continue;
    seen.add(pid);
    targets.push({
      pid,
      name: appNameOf(p.comm) || baseName(p.comm),
      cpu: p.cpu,
      why: nameHit ? 'background agent' : 'high CPU',
    });
  }
  targets.sort((a, b) => b.cpu - a.cpu);
  if (dry) return { dry: true, targets, front: snap.front };
  const { applied, errors } = await applyBackground(
    targets.map((t) => t.pid),
    { manual: false, origin: 'quickfast' },
  );
  return { targets, applied, errors, front: snap.front };
}

async function autoTick() {
  if (!config.auto || autoBusy) return;
  autoBusy = true;
  try {
    const { model } = await getSnapshot(true);

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
    if (focusRestore.length) { saveState(true); invalidateCache(); }

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
  if (!config.auto && autoTimer) {
    clearInterval(autoTimer);
    autoTimer = null;
    hotStreak.clear();
  }
}

function stopAutoTimer() {
  if (autoTimer) { clearInterval(autoTimer); autoTimer = null; }
}

/** Serialize mutating API actions so auto-tame and user clicks don't race. */
function withActionLock(fn) {
  return new Promise((resolve, reject) => {
    actionQueue.push({ fn, resolve, reject });
    drainActionQueue();
  });
}

async function drainActionQueue() {
  if (actionBusy) return;
  const next = actionQueue.shift();
  if (!next) return;
  actionBusy = true;
  try {
    next.resolve(await next.fn());
  } catch (e) {
    next.reject(e);
  } finally {
    actionBusy = false;
    if (actionQueue.length) drainActionQueue();
  }
}

// Simple token-bucket rate limit for mutating POSTs (per process).
// Sized so the QA suite (many safe fuzz POSTs) does not trip 429 under normal load.
const RATE_CAPACITY = 60;
const RATE_REFILL_PER_S = 20;
let rateTokens = RATE_CAPACITY;
let rateLast = Date.now();

function takeRateToken() {
  const now = Date.now();
  const elapsed = (now - rateLast) / 1000;
  rateLast = now;
  rateTokens = Math.min(RATE_CAPACITY, rateTokens + elapsed * RATE_REFILL_PER_S);
  if (rateTokens < 1) return false;
  rateTokens -= 1;
  return true;
}

module.exports = {
  actionEligible, applyBackground, restorePids, groupPids, quickfast,
  autoTick, syncAutoTimer, stopAutoTimer, withActionLock, takeRateToken,
  SELF_PIDS,
};
