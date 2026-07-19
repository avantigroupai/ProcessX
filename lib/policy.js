'use strict';
const fs = require('fs');
const path = require('path');

const raw = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'policy.json'), 'utf8'));

const CRITICAL = new Set(raw.critical);
const MEDIA_SAFE = new RegExp(raw.mediaSafe, 'i');
const QF_PATTERNS = raw.quickFastPatterns.map((p) => new RegExp(p, 'i'));
const QF_CPU_THRESHOLD = raw.quickFastCpuThreshold;
const TERMINALS = new Set(raw.terminals);
const SHELLS = new Set(raw.shells);
const INTERPRETERS = new Set(raw.interpreters);
const AUTO_STREAK = raw.autoStreak;
const AUTO_INTERVAL = raw.autoIntervalMs;
const RESTORE_COOLDOWN_MS = raw.restoreCooldownMs;
const MAX_PIDS = raw.maxPidsPerRequest;
const ACTION_CONCURRENCY = raw.actionConcurrency;

/** Normalize and cap a client-supplied pid list. Drops NaN / non-positive / non-integer. */
function sanitizePids(input) {
  if (!Array.isArray(input)) return [];
  const out = [];
  const seen = new Set();
  for (const v of input) {
    const n = Number(v);
    if (!Number.isInteger(n) || n <= 0 || n > 0x7fffffff) continue;
    if (seen.has(n)) continue;
    seen.add(n);
    out.push(n);
    if (out.length >= MAX_PIDS) break;
  }
  return out;
}

/** Map raw taskpolicy / OS errors to safe client-facing reasons. */
function safeReason(rawErr, fallback = 'action failed') {
  if (!rawErr) return fallback;
  const s = String(rawErr).toLowerCase();
  if (/permission|not permitted|eperm|operation not permitted/.test(s)) return 'permission denied';
  if (/no such process|esrch|not found/.test(s)) return 'no longer running';
  if (/invalid|einval/.test(s)) return 'invalid process';
  return fallback;
}

module.exports = {
  CRITICAL, MEDIA_SAFE, QF_PATTERNS, QF_CPU_THRESHOLD,
  TERMINALS, SHELLS, INTERPRETERS,
  AUTO_STREAK, AUTO_INTERVAL, RESTORE_COOLDOWN_MS,
  MAX_PIDS, ACTION_CONCURRENCY,
  sanitizePids, safeReason,
  policyVersion: '1.0.0',
};
