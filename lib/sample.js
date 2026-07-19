'use strict';
const os = require('os');
const { run } = require('./util');
const { bgMap, hotStreak, saveState, config } = require('./state');
const { buildModel, appNameOf } = require('./model');
const { baseName } = require('./util');

const NCPU = os.cpus().length;

let cache = { ts: 0, snap: null, model: null };
let inflight = null;

const CACHE_MS = 900;
const FORCE_FLOOR_MS = 350;

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
  return best;
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

// GPU/mem refresh every 3rd sample to cut subprocess load (CPU/process every tick).
let sampleTick = 0;
let lastGpu = null;
let lastMem = null;

async function sampleAll() {
  sampleTick += 1;
  const refreshAux = sampleTick === 1 || sampleTick % 3 === 0;

  const [ps, argsMap, frontPid, gpu, mem] = await Promise.all([
    samplePs(),
    sampleArgs(),
    sampleFront(),
    refreshAux ? sampleGpu() : Promise.resolve(lastGpu),
    refreshAux ? sampleMem() : Promise.resolve(lastMem || {
      total: os.totalmem(), used: 0, pressure: 'normal', swapUsed: null,
    }),
  ]);
  if (refreshAux) {
    lastGpu = gpu;
    lastMem = mem;
  }

  const { ok: psOk, procs } = ps;

  if (!psOk && cache.snap) return cache;

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
  if (pruned) saveState(true);

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
    slowed: [...bgMap.values()].map((a) => ({
      pid: a.pid, name: a.name, ts: a.ts, origin: a.origin || 'manual',
    })),
    groups: model.groups,
  };
  cache = { ts: Date.now(), snap, model };
  return cache;
}

async function getSnapshot(force = false) {
  if (cache.snap && Date.now() - cache.ts < (force ? FORCE_FLOOR_MS : CACHE_MS)) return cache;
  if (inflight) return inflight;
  inflight = sampleAll();
  try { return await inflight; } finally { inflight = null; }
}

function invalidateCache() {
  cache.ts = 0;
}

function getCache() {
  return cache;
}

module.exports = { getSnapshot, invalidateCache, getCache, NCPU, samplePs };
