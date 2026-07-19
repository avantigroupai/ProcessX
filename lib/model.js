'use strict';
const { baseName } = require('./util');
const { CRITICAL, TERMINALS, SHELLS, INTERPRETERS } = require('./policy');
const { bgMap } = require('./state');

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
  const title = cliTitle(proc, argsMap);
  return title !== b ? title : b;
}

function buildModel(procs, argsMap, frontPid) {
  const byPid = new Map(procs.map((p) => [p.pid, p]));
  const groups = new Map();
  const MY_UID = process.getuid();

  const assign = (p, key, name, kind, rootPid, parentKey) => {
    let g = groups.get(key);
    if (!g) {
      g = {
        key, name, kind, rootPid, parentKey: parentKey || null,
        cpu: 0, mem: 0, count: 0, bgCount: 0,
        active: false, critical: CRITICAL.has(name), system: true, procs: [],
      };
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
    const chain = [p];
    let cur = p, guard = 0;
    while (guard++ < 40) {
      const parent = byPid.get(cur.ppid);
      if (!parent || parent.pid <= 1 || parent.pid === cur.pid) break;
      chain.push(parent);
      cur = parent;
    }
    let appIdx = -1;
    for (let i = chain.length - 1; i >= 0; i--) {
      if (appNameOf(chain[i].comm)) { appIdx = i; break; }
    }
    if (appIdx >= 0) {
      const appName = appNameOf(chain[appIdx].comm);
      if (TERMINALS.has(appName)) {
        let s = -1;
        for (let i = appIdx - 1; i >= 0; i--) {
          if (!SHELLS.has(baseName(chain[i].comm))) { s = i; break; }
        }
        if (s >= 0) {
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

function groupIsFront(groupKey, model) {
  if (!groupKey || !model.frontKey) return false;
  if (groupKey === model.frontKey) return true;
  const g = model.allGroups.get(groupKey);
  return !!(g && g.parentKey && g.parentKey === model.frontKey);
}

module.exports = {
  appNameOf, cliTitle, procLabel, buildModel, groupIsFront,
};
