#!/usr/bin/env node
'use strict';
/*
 * ProcessX QA harness — zero-dependency, self-contained.
 *
 *   node qa/qa.mjs            # run every suite against a throwaway server
 *   node qa/qa.mjs --keep     # leave the test server running on exit (debug)
 *   node qa/qa.mjs --only=sec  # run only suites whose id starts with "sec"
 *
 * Spawns its own `node server.js` on a private port with an isolated state
 * file, so it never touches the user's real .processx-state.json or the running
 * dev preview. The end-to-end action test only ever throttles a sacrificial
 * child process this harness spawns itself — never a real user process.
 */

import { spawn, execFile } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import http from 'node:http';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';

const require = createRequire(import.meta.url);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const SERVER = path.join(ROOT, 'server.js');
const PORT = Number(process.env.QA_PORT || 4788);
const BASE = `http://127.0.0.1:${PORT}`;
const STATE = path.join(os.tmpdir(), `processx-qa-state-${process.pid}.json`);
const ARGS = new Set(process.argv.slice(2));
const KEEP = ARGS.has('--keep');
const ONLY = [...ARGS].find((a) => a.startsWith('--only='))?.slice(7) || '';

// --------------------------------------------------------------- test framework
let passN = 0, failN = 0, skipN = 0;
const failures = [];
let curSuite = '';

function suite(id, name) { curSuite = name; console.log(`\n\x1b[1m▸ ${name}\x1b[0m  \x1b[2m(${id})\x1b[0m`); }
function ok(name, extra = '') {
  passN++; console.log(`  \x1b[32m✓\x1b[0m ${name}${extra ? `  \x1b[2m${extra}\x1b[0m` : ''}`);
}
function bad(name, detail) {
  failN++; failures.push({ suite: curSuite, name, detail });
  console.log(`  \x1b[31m✗ ${name}\x1b[0m`);
  if (detail) console.log(`      \x1b[31m${String(detail).replace(/\n/g, '\n      ')}\x1b[0m`);
}
function skip(name, why) { skipN++; console.log(`  \x1b[33m∼\x1b[0m ${name}  \x1b[2m(skipped: ${why})\x1b[0m`); }
function check(cond, name, detail) { cond ? ok(name) : bad(name, detail); return !!cond; }
function eq(actual, expected, name) {
  const good = actual === expected;
  good ? ok(name, `= ${JSON.stringify(actual)}`) : bad(name, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  return good;
}

// ------------------------------------------------------------------- http helper
// Uses raw http so we can send header combinations fetch() forbids (Origin,
// Sec-Fetch-Site, Host, Content-Type on arbitrary requests).
function req(method, urlPath, { headers = {}, body = null, timeout = 8000, noAutoCT = false } = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlPath, BASE);
    const data = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const h = { ...headers };
    // Auto-add application/json only when the caller didn't opt out and didn't
    // set a content-type themselves — so the "genuinely no content-type" CSRF
    // case can be exercised faithfully.
    if (data != null && !noAutoCT && !Object.keys(h).some((k) => k.toLowerCase() === 'content-type')) h['Content-Type'] = 'application/json';
    if (data != null) h['Content-Length'] = Buffer.byteLength(data);
    let settled = false;
    const r = http.request({ host: '127.0.0.1', port: PORT, path: u.pathname + u.search, method, headers: h, timeout }, (res) => {
      let buf = '';
      res.on('data', (c) => (buf += c));
      res.on('end', () => {
        settled = true;
        let json = null; try { json = JSON.parse(buf); } catch { /* not json */ }
        resolve({ status: res.statusCode, headers: res.headers, text: buf, json });
      });
    });
    r.on('timeout', () => { r.destroy(new Error('request timeout')); });
    r.on('error', (e) => {
      // The server defends against oversized bodies by destroying the socket,
      // which surfaces client-side as EPIPE/ECONNRESET. That's a valid defense,
      // not a harness failure — resolve with a sentinel so callers can assert it.
      if (!settled && (e.code === 'EPIPE' || e.code === 'ECONNRESET')) {
        settled = true; return resolve({ status: 0, reset: true, headers: {}, text: '', json: null });
      }
      if (!settled) reject(e);
    });
    if (data != null) r.write(data);
    r.end();
  });
}
const sameOrigin = { Origin: BASE, 'Sec-Fetch-Site': 'same-origin', 'Content-Type': 'application/json' };
const run = (cmd, args) => new Promise((res) => execFile(cmd, args, { timeout: 5000 }, (e, o) => res({ ok: !e, out: o || '' })));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --------------------------------------------------------------------- lifecycle
let child = null;
function startServer() {
  return new Promise((resolve, reject) => {
    child = spawn('node', [SERVER], {
      cwd: ROOT,
      env: { ...process.env, PORT: String(PORT), PROCESSX_STATE: STATE },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let out = '';
    const onData = (c) => {
      out += c;
      if (/running at/i.test(out)) { child.stdout.off('data', onData); resolve(); }
    };
    child.stdout.on('data', onData);
    child.stderr.on('data', (c) => { if (process.env.QA_VERBOSE) process.stderr.write(c); });
    child.on('exit', (code) => { if (code && !stopping) reject(new Error(`server exited early (${code})`)); });
    setTimeout(() => reject(new Error('server did not start within 10s')), 10000);
  });
}
let stopping = false;
function stopServer() {
  stopping = true;
  if (child && !KEEP) child.kill('SIGKILL');
  try { fs.unlinkSync(STATE); } catch { /* ignore */ }
}

// ============================================================================ SUITES

async function suiteSmoke() {
  suite('smoke', 'Smoke & API contract');
  const snap = await req('GET', '/api/snapshot');
  check(snap.status === 200 && snap.json, 'GET /api/snapshot returns 200 + JSON', `status ${snap.status}`);
  const s = snap.json || {};
  check(typeof s.ts === 'number', 'snapshot.ts is a number');
  check(typeof s.ncpu === 'number' && s.ncpu > 0, 'snapshot.ncpu > 0', `ncpu=${s.ncpu}`);
  check(s.cpu && typeof s.cpu.totalPct === 'number' && s.cpu.totalPct >= 0 && s.cpu.totalPct <= 100, 'cpu.totalPct in [0,100]', `=${s.cpu?.totalPct}`);
  check(s.mem && s.mem.total > 0 && s.mem.used >= 0 && s.mem.used <= s.mem.total, 'mem.used within [0,total]');
  check(['normal', 'warning', 'critical'].includes(s.mem?.pressure), 'mem.pressure is a known level', `=${s.mem?.pressure}`);
  check(Array.isArray(s.groups) && s.groups.length > 0, 'groups is a non-empty array', `n=${s.groups?.length}`);
  check(Array.isArray(s.slowed), 'slowed is an array');
  check(s.gpu && ('util' in s.gpu), 'gpu.util present (may be null)');
  // Every group has the fields the UI reads.
  const g = (s.groups || [])[0] || {};
  const need = ['key', 'name', 'kind', 'cpu', 'mem', 'count', 'bgCount', 'procs', 'actionable', 'critical', 'system'];
  check(need.every((k) => k in g), 'group has all UI fields', `missing: ${need.filter((k) => !(k in g))}`);
  check(['app', 'cli', 'daemon'].includes(g.kind), 'group.kind is valid', `=${g.kind}`);
  // Config contract
  const cfg = await req('GET', '/api/config');
  check(cfg.status === 200 && typeof cfg.json?.auto === 'boolean' && typeof cfg.json?.cpuThreshold === 'number', 'GET /api/config shape');
  // Cache-Control on API
  check(/no-store/.test(snap.headers['cache-control'] || ''), 'API sets Cache-Control: no-store');
  // 404
  const nf = await req('GET', '/api/does-not-exist');
  eq(nf.status, 404, 'unknown path → 404');
  // Static index
  const idx = await req('GET', '/');
  check(idx.status === 200 && /ProcessX/.test(idx.text), 'GET / serves index.html');
  check(/text\/html/.test(idx.headers['content-type'] || ''), 'index served as text/html');
}

async function suiteCsrf() {
  suite('sec-csrf', 'Security — CSRF / cross-site write protection');
  // The matrix: only a request that looks same-origin AND is application/json passes.
  const cases = [
    { name: 'cross-site Sec-Fetch-Site blocked', h: { 'Sec-Fetch-Site': 'cross-site', 'Content-Type': 'application/json' }, blocked: true },
    { name: 'same-site (not same-origin) blocked', h: { 'Sec-Fetch-Site': 'same-site', 'Content-Type': 'application/json' }, blocked: true },
    { name: 'foreign Origin blocked', h: { Origin: 'https://evil.example', 'Content-Type': 'application/json' }, blocked: true },
    { name: 'non-JSON content-type blocked', h: { 'Sec-Fetch-Site': 'same-origin', 'Content-Type': 'text/plain' }, blocked: true },
    { name: 'form content-type blocked (simple-request CSRF)', h: { 'Sec-Fetch-Site': 'same-origin', 'Content-Type': 'application/x-www-form-urlencoded' }, blocked: true },
    { name: 'multipart content-type blocked', h: { 'Sec-Fetch-Site': 'same-origin', 'Content-Type': 'multipart/form-data' }, blocked: true },
    { name: 'no content-type header blocked', h: {}, noAutoCT: true, blocked: true },
    { name: 'malformed Origin blocked', h: { Origin: 'http://', 'Content-Type': 'application/json' }, blocked: true },
    { name: 'same-origin + json allowed', h: sameOrigin, blocked: false },
    { name: "Sec-Fetch-Site 'none' + json allowed", h: { 'Sec-Fetch-Site': 'none', 'Content-Type': 'application/json' }, blocked: false },
    { name: 'loopback Origin + json allowed', h: { Origin: `http://localhost:${PORT}`, 'Content-Type': 'application/json' }, blocked: false },
  ];
  for (const ep of ['/api/quickfast', '/api/deprioritize', '/api/restore', '/api/config']) {
    for (const c of cases) {
      // dry payloads only — never actually throttle anything here
      const body = ep === '/api/quickfast' ? { dry: true } : ep === '/api/config' ? {} : { pids: [] };
      const r = await req('POST', ep, { headers: c.h, body, noAutoCT: !!c.noAutoCT });
      const was = r.status === 403;
      if (was === c.blocked) ok(`${ep}: ${c.name}`, `→ ${r.status}`);
      else bad(`${ep}: ${c.name}`, `expected ${c.blocked ? 'BLOCK(403)' : 'ALLOW'}, got ${r.status}`);
    }
  }
}

async function suiteRebind() {
  suite('sec-rebind', 'Security — DNS rebinding / Host header');
  // A rebound attacker page (evil.com → 127.0.0.1) is same-origin to the browser,
  // so Sec-Fetch-Site:same-origin and no Origin header are sent. The only signal
  // that distinguishes it is the Host header carrying the attacker's domain.
  const attacker = { Host: 'evil.example', 'Sec-Fetch-Site': 'same-origin', 'Content-Type': 'application/json' };
  const rState = await req('POST', '/api/config', { headers: attacker, body: {} });
  check(rState.status === 403, 'POST with foreign Host header blocked (rebinding write)', `got ${rState.status}`);
  // GET /api/snapshot leaks the full process list; a rebound page can read it
  // (same-origin GET sends no Origin). Host validation must gate reads too.
  const rSnap = await req('GET', '/api/snapshot', { headers: { Host: 'evil.example' } });
  check(rSnap.status === 403, 'GET /api/snapshot with foreign Host header blocked (rebinding read)', `got ${rSnap.status}`);
  // Legitimate Host values must still work.
  for (const host of [`127.0.0.1:${PORT}`, `localhost:${PORT}`, `[::1]:${PORT}`]) {
    const r = await req('GET', '/api/snapshot', { headers: { Host: host } });
    check(r.status === 200, `legit Host ${host} allowed`, `got ${r.status}`);
  }
  // Missing Host (HTTP/1.0-style) — server's own poller and curl may omit it; allow.
  const noHost = await req('GET', '/api/snapshot', { headers: {} });
  check(noHost.status === 200, 'request with default Host allowed');
}

async function suiteTraversal() {
  suite('sec-static', 'Security — path traversal & static serving');
  const attacks = [
    '/../server.js', '/../../etc/passwd', '/..%2fserver.js', '/%2e%2e/server.js',
    '/....//server.js', '/public/../server.js', '/../.processx-state.json',
    '/..%5cserver.js', '/%2e%2e%2f%2e%2e%2fetc/passwd', '/./../../server.js',
  ];
  for (const a of attacks) {
    const r = await req('GET', a);
    const leaked = r.status === 200 && /taskpolicy|STATE_FILE|bgMap|module\.exports/.test(r.text);
    if (leaked) bad(`traversal blocked: ${a}`, `LEAKED server source (status ${r.status})`);
    else ok(`traversal blocked: ${a}`, `→ ${r.status}`);
  }
  // A legit nested asset still serves.
  const css = await req('GET', '/style.css');
  check(css.status === 200 && /text\/css/.test(css.headers['content-type'] || ''), 'style.css serves with css mime');
  const js = await req('GET', '/app.js');
  check(js.status === 200 && /javascript/.test(js.headers['content-type'] || ''), 'app.js serves with js mime');
  // Directory should not be served as a file.
  const dir = await req('GET', '/');
  check(dir.status === 200, 'root maps to index (not dir listing)');
}

async function suiteFuzz() {
  suite('fuzz', 'Input validation / fuzzing');
  // Oversized body must be rejected/handled, not OOM.
  const big = 'x'.repeat(2_000_000);
  const r1 = await req('POST', '/api/deprioritize', { headers: sameOrigin, body: `{"junk":"${big}"}` });
  // Either a clean 2xx/4xx, or a defensive socket close (reset) — both mean the
  // 1 MB body cap held and the server did not OOM or hang.
  check(r1.reset || [200, 400, 403, 413].includes(r1.status), 'oversized body capped without crash', `status ${r1.status}${r1.reset ? ' (socket reset)' : ''}`);
  // Malformed JSON → treated as empty, no crash.
  const r2 = await req('POST', '/api/deprioritize', { headers: sameOrigin, body: '{not json' });
  check(r2.status === 200 && Array.isArray(r2.json?.applied), 'malformed JSON → empty action, 200');
  // Wrong types for pids.
  for (const pids of ['not-an-array', 42, { a: 1 }, [null], ['abc'], [1.5], [-1], [0], [999999999]]) {
    const r = await req('POST', '/api/deprioritize', { headers: sameOrigin, body: { pids } });
    const goodShape = r.status === 200 && Array.isArray(r.json?.applied) && Array.isArray(r.json?.errors);
    check(goodShape, `deprioritize pids=${JSON.stringify(pids)} → safe 200`, `status ${r.status}`);
    // Must never actually apply for these junk inputs.
    if (goodShape && r.json.applied.length) bad(`no throttle for junk pids ${JSON.stringify(pids)}`, `applied ${JSON.stringify(r.json.applied)}`);
  }
  // config bounds
  for (const [val, expect] of [[4, 'reject'], [5, 'accept'], [100, 'accept'], [101, 'reject'], ['50', 'reject'], [NaN, 'reject'], [Infinity, 'reject']]) {
    const r = await req('POST', '/api/config', { headers: sameOrigin, body: { cpuThreshold: val } });
    const applied = r.json?.cpuThreshold === val;
    if (expect === 'accept') check(applied, `cpuThreshold ${JSON.stringify(val)} accepted`);
    else check(!applied, `cpuThreshold ${JSON.stringify(val)} rejected/clamped`, `now ${r.json?.cpuThreshold}`);
  }
  // restore all with nothing slowed → clean empty result
  const ra = await req('POST', '/api/restore', { headers: sameOrigin, body: { all: true } });
  check(ra.status === 200 && Array.isArray(ra.json?.restored), 'restore all (empty) → 200');
  // quickfast dry never mutates
  const before = (await req('GET', '/api/snapshot?f=1')).json.slowed.length;
  await req('POST', '/api/quickfast', { headers: sameOrigin, body: { dry: true } });
  const after = (await req('GET', '/api/snapshot?f=1')).json.slowed.length;
  eq(after, before, 'quickfast dry-run does not change slowed count');
}

async function suitePerf() {
  suite('perf', 'Performance');
  // Warm the cache.
  await req('GET', '/api/snapshot?f=1');
  // Cached snapshot latency (should be sub-ms served from memory).
  let t = process.hrtime.bigint();
  const N = 40;
  for (let i = 0; i < N; i++) await req('GET', '/api/snapshot');
  let ms = Number(process.hrtime.bigint() - t) / 1e6 / N;
  check(ms < 25, `cached GET /api/snapshot avg < 25ms`, `avg ${ms.toFixed(2)}ms`);
  // Forced sample latency (spawns subprocess fleet) — should still be reasonable.
  t = process.hrtime.bigint();
  const M = 5;
  for (let i = 0; i < M; i++) await req('GET', '/api/snapshot?f=1');
  ms = Number(process.hrtime.bigint() - t) / 1e6 / M;
  check(ms < 1500, `forced sample avg < 1500ms`, `avg ${ms.toFixed(2)}ms`);
  // Concurrency coalescing: 30 forced samples fired at once should not take
  // anywhere near 30× a single sample (they coalesce / floor).
  t = process.hrtime.bigint();
  await Promise.all(Array.from({ length: 30 }, () => req('GET', '/api/snapshot?f=1')));
  const burstMs = Number(process.hrtime.bigint() - t) / 1e6;
  check(burstMs < 3000, '30 concurrent forced samples coalesce (<3s total)', `${burstMs.toFixed(0)}ms`);
  // Payload size sanity.
  const snap = await req('GET', '/api/snapshot');
  check(snap.text.length < 512 * 1024, 'snapshot payload < 512KB', `${(snap.text.length / 1024).toFixed(1)}KB`);
}

async function suiteE2E() {
  suite('e2e', 'End-to-end action (sacrificial process)');
  if (os.platform() !== 'darwin') { skip('throttle/restore round-trip', 'not macOS'); return; }
  const tp = await run('/bin/sh', ['-c', 'command -v taskpolicy || echo none']);
  if (/none/.test(tp.out)) { skip('throttle/restore round-trip', 'taskpolicy unavailable'); return; }

  // Spawn a sacrificial busy child owned by us — this is the ONLY process the
  // harness ever throttles.
  const victim = spawn('node', ['-e', 'const t=Date.now();while(Date.now()-t<60000){Math.sqrt(Math.random())}'], { stdio: 'ignore' });
  const pid = victim.pid;
  try {
    await sleep(700); // let it show up in ps and start burning CPU
    // Slow it down.
    const slow = await req('POST', '/api/deprioritize', { headers: sameOrigin, body: { pids: [pid] } });
    const applied = (slow.json?.applied || []).some((a) => a.pid === pid);
    if (!check(applied, 'sacrificial pid moved to background band', JSON.stringify(slow.json))) { victim.kill('SIGKILL'); return; }
    // Snapshot reflects it as slowed.
    const snap = await req('GET', '/api/snapshot?f=1');
    check((snap.json.slowed || []).some((x) => x.pid === pid), 'snapshot lists it in slowed[]');
    // State file persisted with identity (comm).
    const st = JSON.parse(fs.readFileSync(STATE, 'utf8'));
    check((st.bg || []).some((b) => b.pid === pid && b.comm), 'state file persisted with comm identity');
    // Restore it.
    const rest = await req('POST', '/api/restore', { headers: sameOrigin, body: { pids: [pid] } });
    check((rest.json?.restored || []).some((r) => r.pid === pid), 'sacrificial pid restored');
    const snap2 = await req('GET', '/api/snapshot?f=1');
    check(!(snap2.json.slowed || []).some((x) => x.pid === pid), 'snapshot no longer lists it as slowed');
    const st2 = JSON.parse(fs.readFileSync(STATE, 'utf8'));
    check(!(st2.bg || []).some((b) => b.pid === pid), 'state file cleared the record');
    // Server must refuse to throttle itself.
    const selfPid = Number((await run('/bin/sh', ['-c', `lsof -ti tcp:${PORT} -sTCP:LISTEN | head -1`])).out.trim());
    if (selfPid) {
      const self = await req('POST', '/api/deprioritize', { headers: sameOrigin, body: { pids: [selfPid] } });
      const refused = (self.json?.errors || []).some((e) => e.pid === selfPid) && !(self.json?.applied || []).length;
      check(refused, 'server refuses to throttle ProcessX itself', JSON.stringify(self.json));
    } else skip('self-throttle guard', 'could not resolve listener pid');
  } finally {
    // Best-effort cleanup: restore then kill, so we never leave a throttled proc.
    await req('POST', '/api/restore', { headers: sameOrigin, body: { pids: [pid] } }).catch(() => {});
    try { victim.kill('SIGKILL'); } catch { /* already gone */ }
  }
}

async function suiteUnit() {
  suite('unit', 'Unit tests (module import)');
  let mod;
  try { mod = require(SERVER); } catch (e) { bad('require server.js as module', e.message); return; }
  check(typeof mod.buildModel === 'function', 'exports buildModel');
  const { buildModel, groupIsFront, MEDIA_SAFE, actionEligible, cliTitle, procLabel } = mod;

  // MEDIA_SAFE matches real media bundles, not lookalikes.
  const media = [
    ['/Applications/Music.app/Contents/MacOS/Music', true],
    ['/Applications/Spotify.app/Contents/MacOS/Spotify', true],
    ['/Applications/zoom.us.app/Contents/MacOS/aomhost', true],
    ['/Applications/Microsoft Teams.app/Contents/MacOS/Teams', true],
    ['/Users/me/Musicology.app/Contents/MacOS/Musicology', false],
    ['/Users/me/bin/spotifyd-clone', false],
    ['/Applications/VLC.app/Contents/MacOS/VLC', true],
    ['/usr/bin/node', false],
  ];
  for (const [comm, want] of media) {
    eq(MEDIA_SAFE.test(comm), want, `MEDIA_SAFE(${path.basename(comm)})`);
  }

  // actionEligible: media apps skipped only by QuickFast (manual:false), allowed manually.
  const myUid = process.getuid();
  const musicProc = { pid: 12345, comm: '/Applications/Music.app/Contents/MacOS/Music', uid: myUid };
  check(actionEligible(musicProc, { manual: false }) !== null, 'QuickFast skips Music (media-safe)');
  check(actionEligible(musicProc, { manual: true }) === null, 'manual slow of Music allowed');
  const critProc = { pid: 2, comm: 'WindowServer', uid: myUid };
  check(actionEligible(critProc, { manual: true }) !== null, 'WindowServer never eligible (even manual)');
  const otherUser = { pid: 3, comm: '/usr/bin/foo', uid: myUid + 99999 };
  check(actionEligible(otherUser, { manual: true }) !== null, 'other-user process not eligible');

  // buildModel: browser helper tree collapses into the app group (Activity-Monitor style).
  const procs = [
    { pid: 100, ppid: 1, uid: myUid, cpu: 1, rss: 1e8, nice: 0, comm: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' },
    { pid: 101, ppid: 100, uid: myUid, cpu: 50, rss: 2e8, nice: 0, comm: '/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)' },
    { pid: 102, ppid: 100, uid: myUid, cpu: 5, rss: 1e8, nice: 0, comm: '/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)' },
  ];
  const argsMap = new Map([[101, 'Google Chrome Helper (Renderer) --type=renderer']]);
  const model = buildModel(procs, argsMap, null);
  const chrome = model.groups.find((g) => g.name === 'Google Chrome');
  check(chrome && chrome.count === 3, 'Chrome + 2 helpers collapse into one group of 3', `count=${chrome?.count}`);
  check(chrome && Math.abs(chrome.cpu - 56) < 0.001, 'group CPU sums children', `cpu=${chrome?.cpu}`);

  // buildModel: terminal-hosted CLI surfaces as its own row, not buried in Terminal.
  const cliProcs = [
    { pid: 200, ppid: 1, uid: myUid, cpu: 0, rss: 1e7, nice: 0, comm: '/Applications/iTerm.app/Contents/MacOS/iTerm2' },
    { pid: 201, ppid: 200, uid: myUid, cpu: 0, rss: 1e7, nice: 0, comm: '/bin/zsh' },
    { pid: 202, ppid: 201, uid: myUid, cpu: 80, rss: 5e8, nice: 0, comm: 'node' },
  ];
  const cliArgs = new Map([[202, 'node /Users/me/.bin/claude serve']]);
  const cliModel = buildModel(cliProcs, cliArgs, null);
  const cli = cliModel.groups.find((g) => g.kind === 'cli');
  check(cli, 'terminal-hosted CLI becomes its own cli group', cliModel.groups.map((g) => g.name).join(','));
  // parentKey lives on the internal model (allGroups), which groupIsFront reads;
  // it is intentionally not projected into the public groups array.
  const cliInternal = cli && cliModel.allGroups.get(cli.key);
  check(cliInternal && cliInternal.parentKey === 'a:iTerm', 'cli group linked to host terminal via parentKey', `parentKey=${cliInternal?.parentKey}`);
  // Focusing the terminal counts as focusing the CLI.
  const cliModelFront = buildModel(cliProcs, cliArgs, 200);
  const cliKey = cliModelFront.groups.find((g) => g.kind === 'cli')?.key;
  check(groupIsFront(cliKey, cliModelFront), 'groupIsFront: focusing terminal focuses its CLI child');

  // procLabel enriches interpreter rows and tab renderers.
  check(/tab \/ page/.test(procLabel(procs[1], argsMap)), 'renderer labelled as tab/page');
  eq(cliTitle(cliProcs[2], cliArgs), 'node claude', 'cliTitle enriches "node claude"');

  // No self-parenting / infinite loop on a cyclic ppid table (guard test).
  const cyclic = [
    { pid: 300, ppid: 301, uid: myUid, cpu: 1, rss: 1e6, nice: 0, comm: 'a' },
    { pid: 301, ppid: 300, uid: myUid, cpu: 1, rss: 1e6, nice: 0, comm: 'b' },
  ];
  let looped = false;
  try { buildModel(cyclic, new Map(), null); } catch { looped = true; }
  check(!looped, 'buildModel survives a cyclic ppid table');
}

// ---- WCAG contrast, computed straight from the CSS tokens (no browser) -------
// Parses the light :root block and the dark @media override, then checks every
// text-on-tint pair the UI actually renders against AA (4.5 small / 3.0 large).
// This guards the accessibility work in CI without needing a headless browser.
function parseTokens(css) {
  const darkAt = css.indexOf('@media (prefers-color-scheme: dark)');
  const light = css.slice(0, darkAt);
  const dark = css.slice(darkAt);
  const grab = (block) => {
    const t = {};
    for (const m of block.matchAll(/(--[\w-]+):\s*(#[0-9a-fA-F]{6}|rgba?\([^)]+\))/g)) t[m[1]] = m[2];
    return t;
  };
  const lt = grab(light);
  const dk = { ...lt, ...grab(dark) }; // dark overrides light for shared tokens
  return { light: lt, dark: dk };
}
function toRGB(v) {
  if (v.startsWith('#')) return [1, 3, 5].map((i) => parseInt(v.slice(i, i + 2), 16));
  const p = v.match(/[\d.]+/g).map(Number);
  return p.slice(0, 3);
}
function relLum(rgb) {
  const f = rgb.map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
  return 0.2126 * f[0] + 0.7152 * f[1] + 0.0722 * f[2];
}
function contrast(fg, bg) { const a = relLum(fg), b = relLum(bg); const hi = Math.max(a, b), lo = Math.min(a, b); return (hi + 0.05) / (lo + 0.05); }
function over(fgHex, alpha, bgRGB) { const f = toRGB(fgHex); return f.map((c, i) => Math.round(c * alpha + bgRGB[i] * (1 - alpha))); }

function suiteContrast() {
  suite('a11y-contrast', 'Accessibility — WCAG AA contrast (from CSS tokens)');
  const css = fs.readFileSync(path.join(ROOT, 'public', 'style.css'), 'utf8');
  const T = parseTokens(css);
  const white = [255, 255, 255];
  for (const theme of ['light', 'dark']) {
    const t = T[theme];
    const bg = toRGB(theme === 'light' ? t['--page'] : t['--surface']);
    const pairs = [
      ['primary button', white, toRGB(t['--btn'])],
      ['button hover', white, toRGB(t['--btn-hover'])],
      ['slowed/background chip', toRGB(t['--accent-strong']), over(t['--accent'], theme === 'light' ? 0.10 : 0.12, bg)],
      ['good chip', toRGB(t['--good-ink']), over(t['--good'], 0.12, bg)],
      ['active chip', toRGB(t['--good-ink']), over(t['--good'], 0.11, bg)],
      ['warning chip', toRGB(t['--warn-ink']), over(t['--warning'], 0.16, bg)],
      ['critical chip', toRGB(t['--crit-ink']), over(t['--critical'], 0.15, bg)],
      ['neutral chip text', toRGB(t['--ink-2']), bg],
      ['muted text', toRGB(t['--muted']), bg],
      ['body ink', toRGB(t['--ink']), bg],
    ];
    for (const [name, fg, b] of pairs) {
      const r = contrast(fg, b);
      if (r >= 4.5) ok(`${theme}: ${name}`, `${r.toFixed(2)}:1`);
      else bad(`${theme}: ${name}`, `${r.toFixed(2)}:1 (< 4.5 AA)`);
    }
  }
}

// ---- Static invariants — guard the responsive & a11y fixes from regressing ---
function suiteStatic() {
  suite('static', 'Static invariants (responsive / a11y / i18n)');
  const css = fs.readFileSync(path.join(ROOT, 'public', 'style.css'), 'utf8');
  const html = fs.readFileSync(path.join(ROOT, 'public', 'index.html'), 'utf8');
  const appjs = fs.readFileSync(path.join(ROOT, 'public', 'app.js'), 'utf8');
  check(/\.controls\s*\{[^}]*flex-wrap:\s*wrap/.test(css), 'controls row wraps (no mobile overflow)');
  check(/@media\s*\(max-width:\s*720px\)[\s\S]*overflow-x:\s*auto/.test(css), 'table scrolls horizontally on narrow screens');
  check(/:focus-visible\s*\{[^}]*outline:/.test(css), 'keyboard focus-visible ring defined');
  check(/aria-label="Filter apps and processes"/.test(html), 'search input has an accessible label');
  check(/id="offline"[^>]*role="alert"/.test(html), 'offline banner is a live region');
  check(/role="status"/.test(html), 'toast is a status live region');
  // The XSS-escaping guard: user-controlled process labels flow through esc().
  check(/function esc\(/.test(appjs) && /innerHTML/.test(appjs), 'front-end escapes dynamic strings (esc)');
  // Swiss-German rule: never the ß character anywhere in shipped text.
  for (const [f, s] of [['style.css', css], ['index.html', html], ['app.js', appjs]]) {
    check(!s.includes('ß'), `${f} contains no ß (Swiss spelling)`);
  }
}

// ------------------------------------------------------------------------- driver
const SUITES = [
  ['smoke', suiteSmoke], ['sec-csrf', suiteCsrf], ['sec-rebind', suiteRebind],
  ['sec-static', suiteTraversal], ['fuzz', suiteFuzz], ['perf', suitePerf],
  ['e2e', suiteE2E], ['unit', suiteUnit], ['a11y-contrast', suiteContrast],
  ['static', suiteStatic],
];

(async () => {
  console.log(`\x1b[1mProcessX QA\x1b[0m  port=${PORT}  state=${path.basename(STATE)}`);
  try {
    await startServer();
  } catch (e) {
    console.error(`\x1b[31mCould not start server: ${e.message}\x1b[0m`);
    process.exit(2);
  }
  const t0 = Date.now();
  try {
    for (const [id, fn] of SUITES) {
      if (ONLY && !id.startsWith(ONLY)) continue;
      await fn();
    }
  } catch (e) {
    bad('harness crashed', e.stack || e.message);
  }
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  console.log(`\n\x1b[1m── Summary ──\x1b[0m  ${secs}s`);
  console.log(`  \x1b[32m${passN} passed\x1b[0m   ${failN ? `\x1b[31m${failN} failed\x1b[0m` : '0 failed'}   ${skipN} skipped`);
  if (failures.length) {
    console.log('\n\x1b[31mFailures:\x1b[0m');
    for (const f of failures) console.log(`  • [${f.suite}] ${f.name}${f.detail ? ` — ${f.detail}` : ''}`);
  }
  stopServer();
  process.exit(failN ? 1 : 0);
})();

process.on('SIGINT', () => { stopServer(); process.exit(130); });
process.on('exit', stopServer);
