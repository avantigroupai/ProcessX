'use strict';
const fs = require('fs');
const path = require('path');
const { QF_CPU_THRESHOLD, RESTORE_COOLDOWN_MS } = require('./policy');

const STATE_FILE = process.env.PROCESSX_STATE || path.join(__dirname, '..', '.processx-state.json');

// pid -> { pid, comm, name, ts, origin }
const bgMap = new Map();
const hotStreak = new Map();
const restoreCooldown = new Map();
const config = { auto: false, cpuThreshold: QF_CPU_THRESHOLD };

let saveTimer = null;
let dirty = false;

function expireCooldowns(now = Date.now()) {
  for (const [pid, ts] of restoreCooldown) {
    if (now - ts > RESTORE_COOLDOWN_MS) restoreCooldown.delete(pid);
  }
}

function loadState() {
  try {
    const j = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    for (const a of j.bg || []) {
      if (a && Number.isInteger(a.pid) && a.pid > 0 && typeof a.comm === 'string') {
        bgMap.set(a.pid, a);
      }
    }
    if (j.config) {
      if (typeof j.config.auto === 'boolean') config.auto = j.config.auto;
      if (Number.isFinite(j.config.cpuThreshold)) config.cpuThreshold = j.config.cpuThreshold;
    }
  } catch { /* first run */ }
}

function writeStateSync() {
  try {
    const tmp = STATE_FILE + '.tmp';
    const data = JSON.stringify({ bg: [...bgMap.values()], config }, null, 2);
    fs.writeFileSync(tmp, data);
    fs.renameSync(tmp, STATE_FILE);
    dirty = false;
  } catch (e) {
    console.error('state save failed:', e.message);
    try { fs.unlinkSync(STATE_FILE + '.tmp'); } catch { /* ignore */ }
  }
}

/** Debounced atomic state write (coalesces bursts of throttle/restore). */
function saveState(immediate = false) {
  dirty = true;
  if (immediate) {
    if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; }
    writeStateSync();
    return;
  }
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    if (dirty) writeStateSync();
  }, 150);
}

function flushState() {
  if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; }
  if (dirty) writeStateSync();
}

module.exports = {
  STATE_FILE, bgMap, hotStreak, restoreCooldown, config,
  expireCooldowns, loadState, saveState, flushState,
};
