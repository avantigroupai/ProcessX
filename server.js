#!/usr/bin/env node
'use strict';
/*
 * ProcessX — macOS process & priority monitor (HTTP entrypoint).
 *
 * Implementation lives under lib/; policy constants in policy.json.
 * Zero npm dependencies. Binds 127.0.0.1 only.
 */

const http = require('http');
const path = require('path');

const PORT = Number(process.env.PORT || 4747);
const PUBLIC_DIR = path.join(__dirname, 'public');

const { MEDIA_SAFE, sanitizePids } = require('./lib/policy');
const { loadState, flushState, config, saveState } = require('./lib/state');
const { getSnapshot, NCPU } = require('./lib/sample');
const { buildModel, groupIsFront, procLabel, cliTitle } = require('./lib/model');
const {
  actionEligible, applyBackground, restorePids, groupPids, quickfast,
  syncAutoTimer, stopAutoTimer, withActionLock, takeRateToken,
} = require('./lib/actions');
const {
  send, sendBuffer, makeHostChecker, makeCrossSite, readBody,
  loadStaticCache, resolveStatic,
} = require('./lib/http');

const badHost = makeHostChecker(PORT);
const crossSite = makeCrossSite(PORT);
const staticCache = loadStaticCache(PUBLIC_DIR);

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  try {
    if (u.pathname.startsWith('/api/') && badHost(req)) {
      return send(res, 403, { error: 'invalid host header' });
    }

    if (u.pathname === '/api/snapshot') {
      const { snap } = await getSnapshot(u.searchParams.has('f'));
      return send(res, 200, snap);
    }

    if (u.pathname === '/api/quickfast' && req.method === 'POST') {
      if (crossSite(req)) return send(res, 403, { error: 'cross-site request blocked' });
      if (!takeRateToken()) return send(res, 429, { error: 'rate limited' });
      const body = await readBody(req);
      if (body.__tooLarge) return send(res, 413, { error: 'body too large' });
      const result = await withActionLock(() => quickfast(!!body.dry));
      return send(res, 200, result);
    }

    if (u.pathname === '/api/config') {
      if (req.method === 'POST') {
        if (crossSite(req)) return send(res, 403, { error: 'cross-site request blocked' });
        if (!takeRateToken()) return send(res, 429, { error: 'rate limited' });
        const body = await readBody(req);
        if (body.__tooLarge) return send(res, 413, { error: 'body too large' });
        if (typeof body.auto === 'boolean') config.auto = body.auto;
        if (Number.isFinite(body.cpuThreshold) && body.cpuThreshold >= 5 && body.cpuThreshold <= 100) {
          config.cpuThreshold = body.cpuThreshold;
        }
        syncAutoTimer();
        saveState(true);
      }
      return send(res, 200, { auto: config.auto, cpuThreshold: config.cpuThreshold });
    }

    if (u.pathname === '/api/deprioritize' && req.method === 'POST') {
      if (crossSite(req)) return send(res, 403, { error: 'cross-site request blocked' });
      if (!takeRateToken()) return send(res, 429, { error: 'rate limited' });
      const body = await readBody(req);
      if (body.__tooLarge) return send(res, 413, { error: 'body too large' });
      let pids = sanitizePids(body.pids);
      if (body.group) {
        const { model } = await getSnapshot(true);
        pids = sanitizePids(pids.concat(groupPids(model, String(body.group))));
      }
      const result = await withActionLock(() => applyBackground(pids, { manual: true }));
      return send(res, 200, result);
    }

    if (u.pathname === '/api/restore' && req.method === 'POST') {
      if (crossSite(req)) return send(res, 403, { error: 'cross-site request blocked' });
      if (!takeRateToken()) return send(res, 429, { error: 'rate limited' });
      const body = await readBody(req);
      if (body.__tooLarge) return send(res, 413, { error: 'body too large' });
      let pids = sanitizePids(body.pids);
      if (body.group) {
        const { model } = await getSnapshot(true);
        const { bgMap } = require('./lib/state');
        pids = sanitizePids(
          pids.concat(groupPids(model, String(body.group)).filter((pid) => bgMap.has(pid))),
        );
      }
      if (body.all) {
        const { bgMap } = require('./lib/state');
        pids = sanitizePids([...bgMap.keys()]);
      }
      const result = await withActionLock(() => restorePids(pids));
      return send(res, 200, result);
    }

    // Static files (memory cache + safe path resolve)
    const asset = resolveStatic(PUBLIC_DIR, u.pathname, staticCache);
    if (asset) {
      const isHtml = asset.type.includes('html');
      return sendBuffer(
        res, 200, asset.buf, asset.type,
        isHtml ? 'no-cache' : 'public, max-age=120',
      );
    }
    return send(res, 404, { error: 'not found' });
  } catch (e) {
    console.error(e);
    return send(res, 500, { error: 'internal error' });
  }
});

function shutdown(signal) {
  console.log(`\nProcessX shutting down (${signal})…`);
  stopAutoTimer();
  flushState();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1500).unref();
}

if (require.main === module) {
  loadState();
  syncAutoTimer();
  server.listen(PORT, '127.0.0.1', () => {
    console.log(
      `ProcessX running at http://localhost:${PORT}  (cores: ${NCPU}, uid: ${process.getuid()}, auto-tame: ${config.auto ? 'on' : 'off'})`,
    );
  });
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
} else {
  // Unit tests (require without starting the server).
  module.exports = {
    buildModel,
    groupIsFront,
    procLabel,
    cliTitle,
    MEDIA_SAFE,
    actionEligible,
  };
}
