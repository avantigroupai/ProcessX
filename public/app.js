'use strict';
/* ProcessX front-end: polls /api/snapshot, renders tiles + grouped table,
 * and drives one-click reprioritization (taskpolicy background band). */

const $ = (id) => document.getElementById(id);
const state = {
  snap: null,
  expanded: new Set(),
  sort: 'cpu',
  search: '',
  showSystem: false,
  cpuHist: [],
  gpuHist: [],
  offlineSince: 0,
  freezeTable: false,   // true while pointer/focus is over the table
  configPending: false, // true while a settings write is in flight
};

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
const icon = (name, cls = 'icon sm') => `<svg class="${cls}"><use href="#i-${name}"/></svg>`;

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
  // area wash (~10% opacity of the series hue)
  ctx.beginPath();
  ctx.moveTo(pts[0][0], h);
  for (const [x, y] of pts) ctx.lineTo(x, y);
  ctx.lineTo(pts[n - 1][0], h);
  ctx.closePath();
  ctx.globalAlpha = 0.1; ctx.fillStyle = accent; ctx.fill();
  ctx.globalAlpha = 1;
  // 2px line, round joins
  ctx.beginPath();
  for (let i = 0; i < n; i++) i ? ctx.lineTo(pts[i][0], pts[i][1]) : ctx.moveTo(pts[i][0], pts[i][1]);
  ctx.strokeStyle = accent; ctx.lineWidth = 2; ctx.lineJoin = 'round'; ctx.lineCap = 'round';
  ctx.stroke();
}

// ------------------------------------------------------------------- toast
let toastTimer = null;
function toast(msg, undoFn) {
  const el = $('toast');
  el.innerHTML = `<span>${msg}</span>` + (undoFn ? `<button id="toastUndo">Undo</button>` : '');
  if (undoFn) $('toastUndo').onclick = () => { hideToast(); undoFn(); };
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
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return r.json();
}

async function slow(payload, label) {
  try {
    const res = await api('/api/deprioritize', payload);
    if (res.applied.length) {
      toast(`${esc(label)} moved to background priority (${res.applied.length} process${res.applied.length > 1 ? 'es' : ''})`,
        () => restore(payload, label));
    } else if (res.errors.length) {
      toast(`Couldn't slow ${esc(label)}: ${esc(res.errors[0].reason)}`);
    } else {
      toast(`${esc(label)} is already backgrounded`);
    }
  } catch (e) { toast('Action failed: ' + esc(e.message)); }
  refresh(true);
}

async function restore(payload, label) {
  try {
    const res = await api('/api/restore', payload);
    if (res.restored.length) toast(`${esc(label)} restored to normal priority`);
    else if (res.errors && res.errors.length) toast(`Restore failed: ${esc(res.errors[0].reason)}`);
  } catch (e) { toast('Action failed: ' + esc(e.message)); }
  refresh(true);
}

async function quickfast() {
  const btn = $('quickfast');
  btn.disabled = true;
  try {
    const res = await api('/api/quickfast', {});
    if (res.applied.length) {
      const names = [...new Set(res.applied.map((a) => a.name))];
      const shown = names.slice(0, 4).join(', ') + (names.length > 4 ? ` +${names.length - 4} more` : '');
      // Undo restores exactly the pids QuickFast just slowed — not everything in
      // the background band (which may include manual or earlier throttles).
      const appliedPids = res.applied.map((a) => a.pid);
      toast(`QuickFast: slowed ${res.applied.length} background process${res.applied.length > 1 ? 'es' : ''} — ${esc(shown)}`,
        () => restore({ pids: appliedPids }, 'QuickFast changes'));
    } else {
      toast('QuickFast: nothing to slow down — no background hogs found');
    }
  } catch (e) { toast('QuickFast failed: ' + esc(e.message)); }
  btn.disabled = false;
  refresh(true);
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
  const bits = [];
  if (g.bgCount < g.count) {
    bits.push(`<button class="row-act" data-act="slow" data-group="${esc(g.key)}" data-label="${esc(g.name)}" title="Move to background priority (reversible)">${icon('slow')}Slow down</button>`);
  }
  if (g.bgCount > 0) {
    bits.push(`<button class="row-act" data-act="restore" data-group="${esc(g.key)}" data-label="${esc(g.name)}" title="Restore normal priority">${icon('restore')}Restore</button>`);
  }
  return bits.join(' ');
}

function childActions(p) {
  if (p.critical || !p.mine) {
    return `<span class="protected">${icon('shield')}</span>`;
  }
  if (p.bg) {
    return `<button class="row-act" data-act="restore" data-pid="${p.pid}" data-label="${esc(p.label)}" title="Restore normal priority">${icon('restore')}Restore</button>`;
  }
  return `<button class="row-act" data-act="slow" data-pid="${p.pid}" data-label="${esc(p.label)}" title="Move this process to background priority">${icon('slow')}Slow down</button>`;
}

function cpuCell(cpu, ncpu) {
  // bar width = share of total machine capacity; color = how hot per-core
  const width = Math.min(100, cpu / ncpu);
  return `<span>${fmtPct(cpu)}%</span><span class="microbar ${sevClass(Math.min(100, cpu))}"><i style="width:${cpu > 0.5 ? Math.max(3, width) : 0}%"></i></span>`;
}

function render(passive = false) {
  const snap = state.snap;
  if (!snap) return;

  // tiles
  $('cpuVal').textContent = fmtPct(snap.cpu.totalPct);
  setMeter($('cpuMeter'), snap.cpu.totalPct);
  $('cpuFoot').textContent = `load ${snap.loadavg[0]} · ${snap.ncpu} cores · Σ ${Math.round(snap.cpu.sumPct)}% of ${snap.ncpu * 100}%`;
  drawSpark($('cpuSpark'), state.cpuHist);

  const gpu = snap.gpu.util;
  $('gpuVal').textContent = gpu == null ? 'n/a' : gpu;
  $('gpuPct').hidden = gpu == null; // otherwise the tile reads "n/a%"
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
  // Don't fight an in-flight settings write. Keying this off activeElement
  // would break on WebKit, which doesn't focus a checkbox on click — a poll
  // landing mid-request would visually revert the user's toggle.
  if (snap.config && !state.configPending) {
    $('autoTame').checked = snap.config.auto;
  }
  const ra = $('restoreAll');
  ra.hidden = snap.slowed.length === 0;
  ra.querySelector('span').textContent = `Restore all (${snap.slowed.length})`;

  // table — tiles above always refresh; the rows do not rebuild on a passive
  // (poll-driven) tick while the pointer or keyboard focus is over the table.
  // Otherwise the 2s re-sort could move a row out from under a click and the
  // wrong process would be throttled. User actions (expand/search/sort) pass
  // passive=false and always rebuild.
  if (passive && state.freezeTable) return;
  const q = state.search.trim().toLowerCase();
  let groups = snap.groups.filter((g) => g.cpu > 0.05 || g.mem > 20 * 1024 * 1024 || g.bgCount > 0 || q);
  if (!state.showSystem) groups = groups.filter((g) => !g.system);
  if (q) {
    groups = groups.filter((g) =>
      g.name.toLowerCase().includes(q) || g.procs.some((p) => p.label.toLowerCase().includes(q)));
  }
  groups.sort((a, b) =>
    state.sort === 'name' ? a.name.localeCompare(b.name)
    : state.sort === 'mem' ? b.mem - a.mem
    : b.cpu - a.cpu || b.mem - a.mem);

  const rows = [];
  for (const g of groups.slice(0, 80)) {
    const open = state.expanded.has(g.key);
    const badges = [
      g.active ? `<span class="chip active">active app</span>` : '',
      g.bgCount ? `<span class="chip slowed">${g.bgCount === g.count ? 'slowed' : g.bgCount + ' slowed'}</span>` : '',
    ].join('');
    rows.push(`<tr class="grp ${open ? 'open' : ''}" data-key="${esc(g.key)}">
      <td class="name">
        <button class="twist ${g.count > 1 ? '' : 'leaf'}" data-toggle="${esc(g.key)}" aria-expanded="${open}" title="Show subprocesses">${icon('chev')}</button>
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
  const twist = e.target.closest('[data-toggle]');
  if (twist) {
    const k = twist.dataset.toggle;
    state.expanded.has(k) ? state.expanded.delete(k) : state.expanded.add(k);
    render();
    return;
  }
  const btn = e.target.closest('button[data-act]');
  if (!btn) return;
  const payload = btn.dataset.group ? { group: btn.dataset.group } : { pids: [Number(btn.dataset.pid)] };
  if (btn.dataset.act === 'slow') slow(payload, btn.dataset.label);
  else restore(payload, btn.dataset.label);
});

$('quickfast').addEventListener('click', quickfast);
$('restoreAll').addEventListener('click', () => restore({ all: true }, 'Everything'));
$('search').addEventListener('input', (e) => { state.search = e.target.value; render(); });
$('sort').addEventListener('change', (e) => { state.sort = e.target.value; render(); });
$('showSystem').addEventListener('change', (e) => { state.showSystem = e.target.checked; render(); });

// Freeze passive re-renders while the user is aiming at the table, then catch
// up on release — so background polls never shift a row out from under a click.
// Pointer and focus are tracked separately: with one shared flag, tabbing away
// while the pointer still rests on the table (or vice versa) would thaw and
// re-enable rebuilds mid-interaction. pointermove/pointerdown are armed too, so
// a pointer already resting over the table at load — which fires no
// pointerenter — still freezes before the click lands.
const tableCard = document.querySelector('.card');
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
  try {
    await api('/api/config', { auto: on });
    toast(on
      ? 'Auto-tame on: sustained background CPU hogs will be slowed automatically'
      : 'Auto-tame off (already-slowed processes stay slowed until restored)');
  } catch (err) {
    e.target.checked = !on;
    toast('Could not change setting: ' + esc(err.message));
  } finally {
    state.configPending = false;
  }
  refresh(true);
});

// ------------------------------------------------------------------ polling
// passive=true marks a poll-driven refresh, which defers to the freeze-on-hover
// guard in render(). Action-driven and first-paint refreshes pass passive=false
// so they always rebuild.
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

refresh();
setInterval(() => { if (!document.hidden) refresh(false, true); }, 2000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
