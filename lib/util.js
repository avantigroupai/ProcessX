'use strict';
const path = require('path');
const { execFile } = require('child_process');

function run(cmd, args, timeout = 5000) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout, maxBuffer: 32 * 1024 * 1024 },
      (err, stdout, stderr) => resolve({
        ok: !err,
        out: stdout || '',
        err: (stderr || (err && err.message) || '').trim(),
      }));
  });
}

function baseName(p) {
  return path.basename(p).replace(/^-/, '');
}

/** Run async work over items with a fixed concurrency pool. */
async function mapPool(items, concurrency, fn) {
  const results = new Array(items.length);
  let i = 0;
  async function worker() {
    while (i < items.length) {
      const idx = i++;
      results[idx] = await fn(items[idx], idx);
    }
  }
  const n = Math.min(concurrency, Math.max(1, items.length));
  await Promise.all(Array.from({ length: n }, () => worker()));
  return results;
}

module.exports = { run, baseName, mapPool };
