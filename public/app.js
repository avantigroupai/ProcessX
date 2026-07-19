'use strict';
/* ProcessX front-end: polls /api/snapshot, renders tiles + grouped table,
 * and drives one-click reprioritization (taskpolicy background band). */

const APP_VERSION = '1.1.0';
const $ = (id) => document.getElementById(id);
const state = {
  snap: null,
  expanded: new Set(),
  sort: 'cpu',
  sortAsc: false,
  search: '',
  showSystem: false,
  cpuHist: [],
  gpuHist: [],
  freezeTable: false,
  configPending: false,
  busyKeys: new Set(), // row/action keys currently in flight
  lastInteract: Date.now(),
};

const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

const fmtPct = (v) => (v >= 100 ? Math.round(v) : v.toFixed(1));
function fmtBytes(b) {
  if (b == null) return '–';
  if (b >= 1024 ** 3) return (b / 1024 ** 3).toFixed(b >= 10 * 1024 ** 3 ? 1 : 2) + ' GB';
  if (b >= 1024 ** 2) return Math.round(b / 1024 ** 2) + ' MB';
  return Math.round(b / 1024) + ' KB';
}
function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
const icon = (name, cls = 'icon sm') => `<svg class="${cls}" aria-hidden="true"><use href="#i-${name}"/></svg>`;

function sevClass(pct) { return pct >= 85 ? 'crit' : pct >= 60 ? 'warn' : ''; }

function setMeter(el, pct) {
  el.className = 'meter ' + sevClass(pct);
  el.firstElementChild.style.width = Math.max(0, Math.min(100, pct)) + '%';
}

function drawSpark(canvas, hist, max = 100) {
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (!w || !h) return;
  canvas.width = w * dpr; canvas.height = h * dpr;
  const ctx = canvas.getContext('2d');
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, w, h);
  if (hist.length < 2) return;
  const css = getComputedStyle(document.documentElement);
  const accent = css.getPropertyValue('--accent').trim();
  const n = hist.length;
  const pts = hist.map((v, i) => [
    (i / (n - 1)) * (w - 2) + 1,
    h - 2 - (Math.min(max, v) / max) * (h - 5),
  ]);
  ctx.beginPath();
  ctx.moveTo(pts[0][0], h);
  for (const [x, y] of pts) ctx.lineTo(x, y);
  ctx.lineTo(pts[n - 1][0], h);
  ctx.closePath();
  ctx.globalAlpha = 0.1; ctx.fillStyle = accent; ctx.fill();
  ctx.globalAlpha = 1;
  ctx.beginPath();
  for (let i = 0; i < n; i++) i ? ctx.lineTo(pts[i][0], pts[i][1]) : ctx.moveTo(pts[i][0], pts[i][1]);
  ctx.strokeStyle = accent; ctx.lineWidth = 2; ctx.lineJoin = 'round'; ctx.lineCap = 'round';
  ctx.stroke();
}

// ------------------------------------------------------------------- toast
let toastTimer = null;
function toast(msg, undoFn) {
  const el = $('toast');
  el.replaceChildren();
  const span = document.createElement('span');
  span.textContent = msg;
  el.appendChild(span);
  if (undoFn) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = 'Undo';
    btn.id = 'toastUndo';
    btn.addEventListener('click', () => { hideToast(); undoFn(); });
    el.appendChild(btn);
  }
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(hideToast, undoFn ? 9000 : 4500);
}
function hideToast() { $('toast').classList.remove('show'); }

// --------------------------------------------------------------------- api
async function api(path, body) {
  const r = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body || {}),
  });
  if (r.status === 429) throw new Error('Too many actions — wait a moment');
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return r.json();
}

function actionKey(payload) {
  if (payload.group) return 'g:' + payload.group;
  if (payload.pids) return 'p:' + payload.pids.join(',');
  if (payload.all) return 'all';
  return 'x';
}

async function slow(payload, label) {
  const key = actionKey(payload);
  if (state.busyKeys.has(key)) return;
  state.busyKeys.add(key);
  render();
  try {
    const res = await api('/api/deprioritize', payload);
    if (res.applied.length) {
      toast(`${label} moved to background priority (${res.applied.length} process${res.applied.length > 1 ? 'es' : ''})`,
        () => restore(payload, label));
    } else if (res.errors.length) {
      toast(`Couldn't slow ${label}: ${res.errors[0].reason}`);
    } else {
      toast(`${label} is already backgrounded`);
    }
  } catch (e) { toast('Action failed: ' + e.message); }
  state.busyKeys.delete(key);
  refresh(true);
}

async function restore(payload, label) {
  const key = actionKey(payload);
  if (state.busyKeys.has(key)) return;
  state.busyKeys.add(key);
  render();
  try {
    const res = await api('/api/restore', payload);
    if (res.restored.length) toast(`${label} restored to normal priority`);
    else if (res.errors && res.errors.length) toast(`Restore failed: ${res.errors[0].reason}`);
  } catch (e) { toast('Action failed: ' + e.message); }
  state.busyKeys.delete(key);
  refresh(true);
}

async function quickfast() {
  const btn = $('quickfast');
  if (btn.disabled) return;
  btn.disabled = true;
  try {
    const res = await api('/api/quickfast', {});
    if (res.applied && res.applied.length) {
      const names = [...new Set(res.applied.map((a) => a.name))];
      const shown = names.slice(0, 4).join(', ') + (names.length > 4 ? ` +${names.length - 4} more` : '');
      const appliedPids = res.applied.map((a) => a.pid);
      toast(`QuickFast: slowed ${res.applied.length} background process${res.applied.length > 1 ? 'es' : ''} — ${shown}`,
        () => restore({ pids: appliedPids }, 'QuickFast changes'));
    } else {
      toast('QuickFast: nothing to slow down — no background hogs found');
    }
  } catch (e) { toast('QuickFast failed: ' + e.message); }
  btn.disabled = false;
  refresh(true);
}

function restoreAll() {
  const n = state.snap?.slowed?.length || 0;
  if (n === 0) return;
  if (n > 5 && !window.confirm(`Restore all ${n} slowed processes to normal priority?`)) return;
  restore({ all: true }, 'Everything');
}

// ------------------------------------------------------------------ render
function kindIcon(g) {
  if (g.kind === 'app') return icon('app', 'icon sm kind');
  if (g.kind === 'cli') return icon('term', 'icon sm kind');
  return icon('gear', 'icon sm kind');
}

function rowActions(g) {
  if (g.critical || !g.actionable) {
    return `<span class="protected" title="Protected — slowing this would hurt system stability">${icon('shield')}protected</span>`;
  }
  const busy = state.busyKeys.has('g:' + g.key);
  const bits = [];
  if (g.bgCount < g.count) {
    bits.push(`<button type="button" class="row-act" data-act="slow" data-group="${esc(g.key)}" data-label="${esc(g.name)}" ${busy ? 'disabled' : ''} title="Move to background priority (reversible)">${icon('slow')}${busy ? '…' : 'Slow down'}</button>`);
  }
  if (g.bgCount > 0) {
    bits.push(`<button type="button" class="row-act" data-act="restore" data-group="${esc(g.key)}" data-label="${esc(g.name)}" ${busy ? 'disabled' : ''} title="Restore normal priority">${icon('restore')}${busy ? '…' : 'Restore'}</button>`);
  }
  return bits.join(' ');
}

function childActions(p) {
  if (p.critical || !p.mine) {
    return `<span class="protected" title="Protected or not owned by you">${icon('shield')}</span>`;
  }
  const busy = state.busyKeys.has('p:' + p.pid);
  if (p.bg) {
    return `<button type="button" class="row-act" data-act="restore" data-pid="${p.pid}" data-label="${esc(p.label)}" ${busy ? 'disabled' : ''} title="Restore normal priority">${icon('restore')}${busy ? '…' : 'Restore'}</button>`;
  }
  return `<button type="button" class="row-act" data-act="slow" data-pid="${p.pid}" data-label="${esc(p.label)}" ${busy ? 'disabled' : ''} title="Move this process to background priority">${icon('slow')}${busy ? '…' : 'Slow down'}</button>`;
}

function cpuCell(cpu, ncpu) {
  const width = Math.min(100, cpu / ncpu);
  return `<span>${fmtPct(cpu)}%</span><span class="microbar ${sevClass(Math.min(100, cpu))}"><i style="width:${cpu > 0.5 ? Math.max(3, width) : 0}%"></i></span>`;
}

function updateSortIndicators() {
  document.querySelectorAll('.sort-ind').forEach((el) => {
    const key = el.dataset.for;
    if (key === state.sort) {
      el.textContent = state.sortAsc ? '↑' : '↓';
      el.parentElement?.classList.add('active');
    } else {
      el.textContent = '';
      el.parentElement?.classList.remove('active');
    }
  });
}

function setSort(key) {
  if (state.sort === key) state.sortAsc = !state.sortAsc;
  else {
    state.sort = key;
    state.sortAsc = key === 'name';
  }
  updateSortIndicators();
  render();
}

function render(passive = false) {
  const snap = state.snap;
  if (!snap) return;

  $('cpuVal').textContent = fmtPct(snap.cpu.totalPct);
  setMeter($('cpuMeter'), snap.cpu.totalPct);
  $('cpuFoot').textContent = `load ${snap.loadavg[0]} · ${snap.ncpu} cores · Σ ${Math.round(snap.cpu.sumPct)}% of ${snap.ncpu * 100}%`;
  drawSpark($('cpuSpark'), state.cpuHist);

  const gpu = snap.gpu.util;
  $('gpuVal').textContent = gpu == null ? 'n/a' : gpu;
  $('gpuPct').hidden = gpu == null;
  setMeter($('gpuMeter'), gpu == null ? 0 : gpu);
  drawSpark($('gpuSpark'), state.gpuHist);

  const memPct = (100 * snap.mem.used) / snap.mem.total;
  $('memVal').innerHTML = `${fmtBytes(snap.mem.used)}<small> / ${fmtBytes(snap.mem.total)}</small>`;
  setMeter($('memMeter'), memPct);
  const pr = snap.mem.pressure;
  const prChip = pr === 'normal'
    ? `<span class="chip good">${icon('check')}pressure normal</span>`
    : `<span class="chip ${pr === 'critical' ? 'critical' : 'warning'}">${icon('warn')}pressure ${pr}</span>`;
  $('memFoot').innerHTML = prChip + (snap.mem.swapUsed ? `<span>swap ${fmtBytes(snap.mem.swapUsed)}</span>` : '');

  $('slowVal').textContent = snap.slowed.length;
  $('slowFoot').textContent = snap.slowed.length
    ? [...new Set(snap.slowed.map((s) => s.name + (s.origin === 'auto' ? ' (auto)' : '')))].slice(0, 3).join(', ')
    : 'processes in the background band';

  if (snap.config && !state.configPending) {
    $('autoTame').checked = snap.config.auto;
    const thr = Math.round(snap.config.cpuThreshold);
    if (document.activeElement !== $('cpuThreshold')) {
      $('cpuThreshold').value = thr;
      $('cpuThresholdVal').textContent = thr + '%';
    }
  }
  const ra = $('restoreAll');
  ra.hidden = snap.slowed.length === 0;
  ra.querySelector('span').textContent = `Restore all (${snap.slowed.length})`;

  if (passive && state.freezeTable) return;
  updateSortIndicators();

  const q = state.search.trim().toLowerCase();
  let groups = snap.groups.filter((g) => g.cpu > 0.05 || g.mem > 20 * 1024 * 1024 || g.bgCount > 0 || q);
  if (!state.showSystem) groups = groups.filter((g) => !g.system);
  if (q) {
    groups = groups.filter((g) =>
      g.name.toLowerCase().includes(q) || g.procs.some((p) => p.label.toLowerCase().includes(q)));
  }

  const mul = state.sortAsc ? 1 : -1;
  groups.sort((a, b) => {
    if (state.sort === 'name') return mul * a.name.localeCompare(b.name);
    if (state.sort === 'mem') return mul * (a.mem - b.mem) || (b.cpu - a.cpu);
    return mul * (a.cpu - b.cpu) || (b.mem - a.mem);
  });

  const rows = [];
  for (const g of groups.slice(0, 80)) {
    const open = state.expanded.has(g.key);
    const badges = [
      g.active ? `<span class="chip active">active app</span>` : '',
      g.bgCount ? `<span class="chip slowed">${g.bgCount === g.count ? 'slowed' : g.bgCount + ' slowed'}</span>` : '',
    ].join('');
    const expandLabel = open ? `Collapse ${g.name}` : `Expand ${g.name}`;
    rows.push(`<tr class="grp ${open ? 'open' : ''}" data-key="${esc(g.key)}">
      <td class="name">
        <button type="button" class="twist ${g.count > 1 ? '' : 'leaf'}" data-toggle="${esc(g.key)}" aria-expanded="${open}" aria-label="${esc(expandLabel)}" title="${esc(expandLabel)}">${icon('chev')}</button>
        ${kindIcon(g)}
        <span class="pname">${esc(g.name)}</span>
        ${g.count > 1 ? `<span class="pcount">×${g.count}</span>` : ''}
        ${badges}
      </td>
      <td class="num">${cpuCell(g.cpu, snap.ncpu)}</td>
      <td class="num">${fmtBytes(g.mem)}</td>
      <td>${g.bgCount === g.count && g.count > 0 ? '<span class="chip slowed">background</span>' : g.bgCount > 0 ? '<span class="chip neutral">mixed</span>' : '<span class="dim">normal</span>'}</td>
      <td class="actions-cell">${rowActions(g)}</td>
    </tr>`);
    if (open) {
      for (const p of g.procs) {
        rows.push(`<tr class="child">
          <td class="name">${esc(p.label)} <span class="pid">${p.pid}</span>
            ${p.bg ? `<span class="chip slowed">${p.bgOrigin === 'auto' ? 'auto-slowed' : 'slowed'}</span>` : ''}
            ${p.nice !== 0 ? `<span class="chip neutral">nice ${p.nice}</span>` : ''}</td>
          <td class="num">${cpuCell(p.cpu, snap.ncpu)}</td>
          <td class="num">${fmtBytes(p.mem)}</td>
          <td></td>
          <td class="actions-cell">${childActions(p)}</td>
        </tr>`);
      }
      if (g.more > 0) rows.push(`<tr class="more"><td colspan="5">… ${g.more} more lightweight process${g.more > 1 ? 'es' : ''}</td></tr>`);
    }
  }
  $('rows').innerHTML = rows.length ? rows.join('') : '<tr><td colspan="5" class="empty">Nothing matches.</td></tr>';
}

// ------------------------------------------------------------------- wiring
document.addEventListener('click', (e) => {
  state.lastInteract = Date.now();
  const th = e.target.closest('[data-sort]');
  if (th) {
    setSort(th.dataset.sort);
    return;
  }
  const twist = e.target.closest('[data-toggle]');
  if (twist) {
    const k = twist.dataset.toggle;
    state.expanded.has(k) ? state.expanded.delete(k) : state.expanded.add(k);
    render();
    return;
  }
  const btn = e.target.closest('button[data-act]');
  if (!btn || btn.disabled) return;
  const payload = btn.dataset.group ? { group: btn.dataset.group } : { pids: [Number(btn.dataset.pid)] };
  if (btn.dataset.act === 'slow') slow(payload, btn.dataset.label);
  else restore(payload, btn.dataset.label);
});

$('quickfast').addEventListener('click', quickfast);
$('restoreAll').addEventListener('click', restoreAll);
$('search').addEventListener('input', (e) => {
  state.search = e.target.value;
  state.lastInteract = Date.now();
  render();
});
$('showSystem').addEventListener('change', (e) => {
  state.showSystem = e.target.checked;
  state.lastInteract = Date.now();
  render();
});

const tableCard = $('tableCard') || document.querySelector('.card');
let pointerOver = false;
let focusInside = false;
const syncFreeze = () => { state.freezeTable = pointerOver || focusInside; };
const armPointer = () => { if (!pointerOver) { pointerOver = true; syncFreeze(); } };
const release = () => { syncFreeze(); if (!state.freezeTable) render(); };
tableCard.addEventListener('pointerenter', armPointer);
tableCard.addEventListener('pointermove', armPointer);
tableCard.addEventListener('pointerdown', armPointer);
tableCard.addEventListener('pointerleave', () => { pointerOver = false; release(); });
tableCard.addEventListener('focusin', () => { focusInside = true; syncFreeze(); });
tableCard.addEventListener('focusout', (e) => {
  if (tableCard.contains(e.relatedTarget)) return;
  focusInside = false;
  release();
});

$('autoTame').addEventListener('change', async (e) => {
  const on = e.target.checked;
  state.configPending = true;
  state.lastInteract = Date.now();
  try {
    await api('/api/config', { auto: on });
    toast(on
      ? 'Auto-tame on: sustained background CPU hogs will be slowed automatically'
      : 'Auto-tame off (already-slowed processes stay slowed until restored)');
  } catch (err) {
    e.target.checked = !on;
    toast('Could not change setting: ' + err.message);
  } finally {
    state.configPending = false;
  }
  refresh(true);
});

let thrTimer = null;
$('cpuThreshold').addEventListener('input', (e) => {
  $('cpuThresholdVal').textContent = e.target.value + '%';
});
$('cpuThreshold').addEventListener('change', (e) => {
  const v = Number(e.target.value);
  state.configPending = true;
  state.lastInteract = Date.now();
  clearTimeout(thrTimer);
  thrTimer = setTimeout(async () => {
    try {
      await api('/api/config', { cpuThreshold: v });
      toast(`CPU threshold set to ${v}%`);
    } catch (err) {
      toast('Could not change threshold: ' + err.message);
    } finally {
      state.configPending = false;
    }
    refresh(true);
  }, 200);
});

// Keyboard shortcuts
document.addEventListener('keydown', (e) => {
  const tag = (e.target && e.target.tagName) || '';
  const typing = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || e.target?.isContentEditable;
  if (e.key === '/' && !typing) {
    e.preventDefault();
    $('search').focus();
    $('search').select();
    return;
  }
  if (typing && e.key !== 'Escape') return;
  if (e.key === 'Escape' && typing) {
    e.target.blur();
    return;
  }
  if ((e.key === 'q' || e.key === 'Q') && !e.metaKey && !e.ctrlKey && !typing) {
    e.preventDefault();
    quickfast();
  }
  if ((e.key === 'r' || e.key === 'R') && !e.metaKey && !e.ctrlKey && !typing) {
    e.preventDefault();
    restoreAll();
  }
});

// ------------------------------------------------------------------ polling
async function refresh(force = false, passive = false) {
  try {
    const r = await fetch('/api/snapshot' + (force ? '?f=1' : ''));
    if (!r.ok) throw new Error('HTTP ' + r.status);
    state.snap = await r.json();
    state.cpuHist.push(state.snap.cpu.totalPct);
    if (state.cpuHist.length > 60) state.cpuHist.shift();
    state.gpuHist.push(state.snap.gpu.util ?? 0);
    if (state.gpuHist.length > 60) state.gpuHist.shift();
    $('offline').classList.remove('show');
    render(passive);
  } catch {
    $('offline').classList.add('show');
  }
}

function pollInterval() {
  if (document.hidden) return 5000;
  if (Date.now() - state.lastInteract > 30000) return 4000;
  return 2000;
}

let pollTimer = null;
function schedulePoll() {
  clearTimeout(pollTimer);
  pollTimer = setTimeout(async () => {
    if (!document.hidden) await refresh(false, true);
    schedulePoll();
  }, pollInterval());
}

if ($('appVersion')) $('appVersion').textContent = 'v' + APP_VERSION;
if (reduceMotion) document.documentElement.classList.add('reduce-motion');

refresh();
schedulePoll();
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) refresh();
  schedulePoll();
});
document.addEventListener('pointerdown', () => { state.lastInteract = Date.now(); }, { passive: true });
