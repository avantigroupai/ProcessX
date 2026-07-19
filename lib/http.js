'use strict';
const fs = require('fs');
const path = require('path');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.json': 'application/json',
  '.ico': 'image/x-icon',
};

// style-src needs 'unsafe-inline' so the UI can set meter/microbar widths via
// element.style / style attributes. This is a loopback-only app with no third-
// party scripts, so the residual risk is negligible; blocking it blanked every bar.
const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'X-Frame-Options': 'DENY',
  'Content-Security-Policy': [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "connect-src 'self'",
    "font-src 'self'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
  ].join('; '),
};

function send(res, code, body, type = 'application/json') {
  const data = type === 'application/json' ? JSON.stringify(body) : body;
  res.writeHead(code, {
    'Content-Type': type,
    'Cache-Control': type.startsWith('text/html') || type.includes('javascript') || type.includes('css')
      ? 'no-cache' : 'no-store',
    ...SECURITY_HEADERS,
  });
  res.end(data);
}

function sendBuffer(res, code, buf, type, cacheControl = 'public, max-age=60') {
  res.writeHead(code, {
    'Content-Type': type,
    'Cache-Control': cacheControl,
    'Content-Length': buf.length,
    ...SECURITY_HEADERS,
  });
  res.end(buf);
}

function makeHostChecker(port) {
  const OK_HOSTS = new Set([
    `localhost:${port}`, `127.0.0.1:${port}`, `[::1]:${port}`,
    'localhost', '127.0.0.1', '[::1]',
  ]);
  return function badHost(req) {
    const host = req.headers.host;
    if (!host) return false;
    return !OK_HOSTS.has(host.toLowerCase());
  };
}

function makeCrossSite(port) {
  return function crossSite(req) {
    const sfs = req.headers['sec-fetch-site'];
    if (sfs && sfs !== 'same-origin' && sfs !== 'none') return true;
    const origin = req.headers.origin;
    if (origin) {
      let host;
      try { host = new URL(origin).host; } catch { return true; }
      if (host !== `localhost:${port}` && host !== `127.0.0.1:${port}` && host !== `[::1]:${port}`) return true;
    }
    const ct = (req.headers['content-type'] || '').toLowerCase();
    if (!ct.startsWith('application/json')) return true;
    return false;
  };
}

function readBody(req) {
  return new Promise((resolve) => {
    let buf = '';
    let done = false;
    const finish = (v) => { if (!done) { done = true; resolve(v); } };
    req.on('data', (c) => {
      buf += c;
      if (buf.length > 1e6) { finish({ __tooLarge: true }); req.destroy(); }
    });
    req.on('end', () => {
      if (done) return;
      let v;
      try { v = JSON.parse(buf || '{}'); } catch { v = {}; }
      finish(v && typeof v === 'object' && !Array.isArray(v) ? v : {});
    });
    req.on('error', () => finish({}));
    req.on('aborted', () => finish({}));
  });
}

/** Load public/ into memory once for fast static serving. */
function loadStaticCache(publicDir) {
  const cache = new Map();
  function walk(dir, prefix = '') {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const ent of entries) {
      const rel = prefix + '/' + ent.name;
      const full = path.join(dir, ent.name);
      if (ent.isDirectory()) walk(full, rel);
      else if (ent.isFile()) {
        try {
          cache.set(rel === '/index.html' ? '/' : rel, {
            buf: fs.readFileSync(full),
            type: MIME[path.extname(ent.name)] || 'application/octet-stream',
            path: full,
          });
          if (rel === '/index.html') {
            cache.set('/index.html', cache.get('/'));
          }
        } catch { /* skip unreadable */ }
      }
    }
  }
  walk(publicDir);
  return cache;
}

function resolveStatic(publicDir, pathname, staticCache) {
  let file = pathname === '/' ? '/index.html' : pathname;
  // Strip query already done by URL parser; reject null bytes.
  if (file.includes('\0')) return null;
  file = path.posix.normalize(file);
  // Drop leading .. segments that survived normalize.
  if (file.includes('..')) return null;

  const key = file === '/index.html' ? '/' : file;
  if (staticCache && staticCache.has(key)) return staticCache.get(key);
  if (staticCache && staticCache.has(file)) return staticCache.get(file);

  // Fallback to disk (dev: files added after boot).
  const rel = file.replace(/^\//, '');
  const full = path.resolve(publicDir, rel);
  if (!full.startsWith(publicDir + path.sep) && full !== publicDir) return null;
  try {
    if (!fs.existsSync(full) || !fs.statSync(full).isFile()) return null;
    return {
      buf: fs.readFileSync(full),
      type: MIME[path.extname(full)] || 'application/octet-stream',
      path: full,
    };
  } catch {
    return null;
  }
}

module.exports = {
  MIME, SECURITY_HEADERS, send, sendBuffer,
  makeHostChecker, makeCrossSite, readBody,
  loadStaticCache, resolveStatic,
};
