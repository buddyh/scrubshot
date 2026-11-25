// The single-page UI served by `scrubshot serve`; self-contained, talks only to same-origin /api endpoints.
let webPageHTML = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>scrubshot</title>
<style>
:root {
  color-scheme: light dark;
  --bg: #f4f4f6;
  --panel: #ffffff;
  --panel2: #f9f9fb;
  --line: #d8d8de;
  --text: #1c1c1f;
  --muted: #6a6a72;
  --accent: #1768d6;
  --accent-soft: rgba(23, 104, 214, 0.12);
  --canvas: #2d2d30;
  --canvas-text: #c9c9cf;
  --ok: #1a7f37;
  --leak: #cf222e;
  --err: #b4500a;
  --warn: #8a6100;
  --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #161618;
    --panel: #1d1d20;
    --panel2: #222226;
    --line: #34343a;
    --text: #e6e6ea;
    --muted: #8e8e98;
    --accent: #5aa2ff;
    --accent-soft: rgba(90, 162, 255, 0.16);
    --canvas: #2a2a2d;
    --canvas-text: #b9b9c2;
    --ok: #4cc26a;
    --leak: #ff6b72;
    --err: #f0913f;
    --warn: #d9a63b;
  }
}
* { box-sizing: border-box; }
html, body { height: 100%; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font: 13px/1.4 -apple-system, "SF Pro Text", system-ui, "Segoe UI", sans-serif;
  display: flex;
  flex-direction: column;
  height: 100vh;
  overflow: hidden;
}
button {
  font: inherit;
  color: inherit;
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 5px;
  padding: 4px 10px;
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  line-height: 1.3;
}
button:hover:not(:disabled) { border-color: var(--muted); }
button:disabled { opacity: 0.45; cursor: default; }
button:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
button.primary:hover:not(:disabled) { filter: brightness(1.08); border-color: var(--accent); }
@media (prefers-color-scheme: dark) { button.primary { color: #0b1420; } }
.mono { font-family: var(--mono); font-size: 12px; }
.muted { color: var(--muted); }
svg.i { width: 14px; height: 14px; flex: none; }

/* header */
.top {
  display: flex; align-items: center; gap: 14px; flex-wrap: wrap;
  padding: 8px 12px; background: var(--panel); border-bottom: 1px solid var(--line);
}
.brand { font-weight: 650; letter-spacing: 0.01em; }
.brand small { font-weight: 400; color: var(--muted); margin-left: 6px; font-family: var(--mono); font-size: 11px; }
.ws { min-width: 0; flex: 1 1 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--muted); direction: rtl; text-align: left; }
.ws bdi { direction: ltr; }
.chip { color: var(--muted); font-size: 12px; white-space: nowrap; }
.busy { display: none; align-items: center; gap: 6px; color: var(--accent); font-size: 12px; }
.busy.on { display: inline-flex; }
.spin { width: 11px; height: 11px; border-radius: 50%; border: 2px solid var(--accent-soft); border-top-color: var(--accent); animation: spin 0.8s linear infinite; display: inline-block; }
@keyframes spin { to { transform: rotate(360deg); } }
.offline { color: var(--leak); font-size: 12px; display: none; }
.offline.on { display: inline; }
.banner { display: none; padding: 10px 14px; background: var(--warn); color: #fff; font-size: 14px; font-weight: 600; }
.banner.on { display: block; }
.banner small { display: block; font-weight: 400; opacity: 0.9; margin-top: 2px; }

/* layout */
.layout { flex: 1; min-height: 0; display: grid; grid-template-columns: 280px minmax(0, 1fr); }
.rail { min-height: 0; display: flex; flex-direction: column; background: var(--panel); border-right: 1px solid var(--line); }
.rail-head { display: flex; align-items: center; justify-content: space-between; padding: 8px 10px; border-bottom: 1px solid var(--line); }
.rail-head h2 { margin: 0; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
.rail-filter { padding: 6px 10px; border-bottom: 1px solid var(--line); }
.rail-filter input { width: 100%; font: inherit; color: inherit; background: var(--panel2); border: 1px solid var(--line); border-radius: 5px; padding: 4px 8px; }
.rail-filter input:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
.rail-list { flex: 1; min-height: 0; overflow: auto; }
.rail-foot { padding: 6px 10px; border-top: 1px solid var(--line); color: var(--muted); font-size: 11px; }
.rail-empty { padding: 18px 12px; color: var(--muted); line-height: 1.5; }
.row {
  display: grid; grid-template-columns: 52px minmax(0, 1fr); gap: 9px; align-items: center;
  padding: 7px 10px; border-bottom: 1px solid var(--line); cursor: pointer; border-left: 3px solid transparent;
}
.row:hover { background: var(--panel2); }
.row.sel { background: var(--accent-soft); border-left-color: var(--accent); }
.thumb { width: 52px; height: 36px; background: var(--canvas); border-radius: 3px; overflow: hidden; display: flex; align-items: center; justify-content: center; }
.thumb img { max-width: 100%; max-height: 100%; display: block; }
.rname { font-family: var(--mono); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rmeta { display: flex; align-items: center; gap: 8px; margin-top: 3px; font-size: 11px; color: var(--muted); }

.pill {
  display: inline-flex; align-items: center; gap: 5px; font-size: 10.5px; font-weight: 600;
  text-transform: uppercase; letter-spacing: 0.05em; padding: 1px 7px; border-radius: 9px;
  border: 1px solid var(--line); color: var(--muted); line-height: 1.5; white-space: nowrap;
}
.pill.new { color: var(--muted); }
.pill.queued { border-style: dashed; color: var(--text); }
.pill.running { color: var(--accent); border-color: var(--accent); }
.pill.running::before { content: ""; width: 6px; height: 6px; border-radius: 50%; background: var(--accent); animation: pulse 1.1s ease-in-out infinite; }
@keyframes pulse { 0%, 100% { opacity: 0.25; } 50% { opacity: 1; } }
.pill.ok { color: var(--ok); border-color: var(--ok); }
.pill.leak { color: #fff; background: var(--leak); border-color: var(--leak); }
.pill.error { color: var(--err); border-color: var(--err); background: rgba(180, 80, 10, 0.10); }
@media (prefers-color-scheme: dark) { .pill.leak { color: #1a0507; } }

/* main */
main { display: flex; flex-direction: column; min-width: 0; min-height: 0; }
.toolbar { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; padding: 6px 12px; background: var(--panel); border-bottom: 1px solid var(--line); }
.seg { display: inline-flex; border: 1px solid var(--line); border-radius: 5px; overflow: hidden; }
.seg button { border: 0; border-radius: 0; background: transparent; padding: 3px 10px; }
.seg button + button { border-left: 1px solid var(--line); }
.seg button.on { background: var(--accent-soft); color: var(--accent); font-weight: 600; }
.seg button:hover:not(:disabled) { border-color: var(--line); background: var(--panel2); }
.seg button.on:hover:not(:disabled) { background: var(--accent-soft); }
.tool-label { font-family: var(--mono); font-size: 12px; margin-right: auto; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 36ch; }
label.chk { display: inline-flex; align-items: center; gap: 5px; cursor: pointer; user-select: none; }
label.chk input { margin: 0; }
label.chk.off { opacity: 0.4; pointer-events: none; }

.stage { flex: 1; min-height: 160px; position: relative; background: var(--canvas); color: var(--canvas-text); overflow: hidden; }
.empty-main { height: 100%; display: flex; align-items: center; justify-content: center; text-align: center; padding: 24px; line-height: 1.6; }
.scroll { position: absolute; inset: 0; overflow: auto; }
.sbs { position: absolute; inset: 0; display: grid; grid-template-columns: 1fr 1fr; gap: 1px; background: #000; }
.pane { display: flex; flex-direction: column; min-width: 0; min-height: 0; background: var(--canvas); }
.pane-head { display: flex; align-items: center; gap: 8px; padding: 4px 10px; font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; background: rgba(0, 0, 0, 0.28); color: var(--canvas-text); flex: none; }
.pane-head .mono { text-transform: none; letter-spacing: 0; opacity: 0.8; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.tag-unsafe { background: #cf222e; color: #fff; font-weight: 700; padding: 0 6px; border-radius: 3px; letter-spacing: 0.05em; }
.pane-body { flex: 1; min-height: 0; overflow: auto; }
.pane-empty { height: 100%; display: flex; align-items: center; justify-content: center; text-align: center; padding: 20px; color: var(--canvas-text); opacity: 0.85; line-height: 1.6; }

.frame { position: relative; line-height: 0; }
.frame img { display: block; user-select: none; -webkit-user-drag: none; }
.frame.z-fit { width: 100%; }
.frame.z-fit img { width: 100%; height: auto; }
.frame.z-1, .frame.z-2 { width: max-content; }
.frame.z-2 img, .frame.up img { image-rendering: pixelated; }
.ov { position: absolute; inset: 0; pointer-events: none; }
.mk { position: absolute; pointer-events: auto; }
.mk.edit { outline: 1.5px dashed #3ddc97; background: rgba(61, 220, 151, 0.18); }
.mk.leak { outline: 2px solid #ff3b47; background: rgba(255, 59, 71, 0.25); }
.sp { position: absolute; pointer-events: auto; outline: 1px solid rgba(220, 220, 230, 0.55); outline-offset: 0; }
.sp.on { background: rgba(255, 255, 255, 0.22); outline-color: #fff; }
.ln { position: absolute; pointer-events: none; }
.ln.hit { outline: 2px solid #ffb020; outline-offset: 1px; background: rgba(255, 176, 32, 0.12); }

.slider { position: relative; }
.after-layer { position: absolute; inset: 0; }
.after-layer img { position: absolute; inset: 0; width: 100%; height: 100%; }
.handle { position: absolute; top: 0; bottom: 0; width: 0; pointer-events: none; }
.handle::before { content: ""; position: absolute; top: 0; bottom: 0; left: -1px; width: 2px; background: #fff; box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.45); }
.handle span { position: absolute; top: 50%; left: -13px; width: 26px; height: 26px; margin-top: -13px; border-radius: 50%; background: #fff; box-shadow: 0 1px 4px rgba(0, 0, 0, 0.5); display: flex; align-items: center; justify-content: center; color: #333; }
.slider-wrap { cursor: ew-resize; touch-action: none; }
.corner { position: absolute; top: 8px; padding: 1px 7px; font-size: 10.5px; text-transform: uppercase; letter-spacing: 0.06em; background: rgba(0, 0, 0, 0.6); color: #eee; border-radius: 3px; line-height: 1.6; pointer-events: none; }
.corner.l { left: 8px; }
.corner.r { right: 8px; }

.reading { position: absolute; top: 10px; left: 50%; transform: translateX(-50%); z-index: 4; background: rgba(0, 0, 0, 0.78); color: #fff; padding: 5px 12px; border-radius: 14px; display: flex; align-items: center; gap: 8px; font-size: 12px; pointer-events: none; }
.reading .spin { border-color: rgba(255, 255, 255, 0.25); border-top-color: #fff; }
.ocr-err { position: absolute; top: 10px; left: 50%; transform: translateX(-50%); z-index: 4; background: #7a1d12; color: #fff; padding: 5px 12px; border-radius: 6px; font-size: 12px; max-width: 80%; }

.tip { position: fixed; z-index: 50; pointer-events: none; background: #111; color: #f0f0f4; border: 1px solid #444; border-radius: 5px; padding: 6px 8px; font-size: 12px; max-width: 360px; line-height: 1.45; box-shadow: 0 4px 14px rgba(0, 0, 0, 0.4); display: none; }
.tip .t { font-family: var(--mono); word-break: break-word; }
.tip .k { color: #9a9aa6; }
.tip .m { margin-top: 4px; padding-top: 4px; border-top: 1px solid #3a3a40; }

/* details */
.details { flex: none; max-height: 40%; min-height: 0; overflow: auto; background: var(--panel); border-top: 1px solid var(--line); }
.dhead { position: sticky; top: 0; z-index: 2; background: var(--panel); display: flex; align-items: center; gap: 10px; padding: 7px 12px; border-bottom: 1px solid var(--line); }
.dhead .grow { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.dbody { padding: 8px 12px 14px; }
.dbody h3 { margin: 12px 0 5px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
.dbody h3:first-child { margin-top: 2px; }
table { border-collapse: collapse; width: 100%; font-size: 12px; }
th { text-align: left; font-weight: 600; color: var(--muted); font-size: 11px; padding: 3px 10px 3px 0; border-bottom: 1px solid var(--line); white-space: nowrap; }
td { padding: 3px 10px 3px 0; border-bottom: 1px solid var(--line); vertical-align: top; }
td.num, th.num { text-align: right; }
td.mono, td .mono { word-break: break-word; }
tr.skipped td { color: var(--muted); }
.arrow { color: var(--muted); margin: 0 5px; }
.note { padding: 6px 9px; border-radius: 4px; border: 1px solid var(--line); margin: 4px 0; font-size: 12px; word-break: break-word; }
.note.err { border-color: var(--err); color: var(--err); background: rgba(180, 80, 10, 0.08); }
.note.warn { border-color: var(--warn); color: var(--warn); }
.note.leak { border-color: var(--leak); color: var(--leak); }
.tablewrap { overflow-x: auto; }

.toasts { position: fixed; right: 12px; bottom: 12px; display: flex; flex-direction: column; gap: 6px; z-index: 60; max-width: min(420px, calc(100vw - 24px)); }
.toast { background: #2b1214; color: #ffd9db; border: 1px solid #7a2a30; border-radius: 6px; padding: 7px 11px; font-size: 12px; box-shadow: 0 4px 14px rgba(0, 0, 0, 0.35); word-break: break-word; }
.drop { position: fixed; inset: 0; z-index: 70; display: none; align-items: center; justify-content: center; background: rgba(20, 60, 130, 0.55); color: #fff; font-size: 18px; pointer-events: none; }
.drop.on { display: flex; }
.drop div { border: 2px dashed #fff; border-radius: 10px; padding: 28px 44px; background: rgba(0, 0, 0, 0.25); }

@media (max-width: 820px) {
  body { height: auto; min-height: 100vh; overflow: auto; }
  .layout { display: block; }
  .rail { border-right: 0; border-bottom: 1px solid var(--line); }
  .rail-list { display: flex; overflow-x: auto; overflow-y: hidden; }
  .row { min-width: 210px; border-bottom: 0; border-right: 1px solid var(--line); border-left: 0; border-top: 3px solid transparent; }
  .row.sel { border-left-color: transparent; border-top-color: var(--accent); }
  .rail-foot { display: none; }
  main { display: block; }
  .stage { height: 72vh; min-height: 320px; }
  .sbs { grid-template-columns: 1fr; grid-template-rows: 1fr 1fr; }
  .details { max-height: none; }
  .ws { order: 5; flex-basis: 100%; }
}
</style>
</head>
<body>
<header class="top">
  <div class="brand">scrubshot<small id="ver"></small></div>
  <div class="ws mono" id="ws" title=""><bdi></bdi></div>
  <span class="chip" id="rules"></span>
  <span class="busy" id="busy"><i class="spin"></i>Working</span>
  <span class="offline" id="offline">Server unreachable</span>
  <button class="primary" id="scrubNew" type="button"></button>
</header>
<div class="banner" id="banner" role="alert"></div>
<div class="layout">
  <aside class="rail">
    <div class="rail-head">
      <h2>Batch <span id="count"></span></h2>
      <button id="pick" type="button"></button>
      <input id="file" type="file" accept="image/*,.heic,.tif,.tiff" multiple hidden>
    </div>
    <div class="rail-filter"><input id="filter" type="search" placeholder="Filter by name or status" aria-label="Filter images" autocomplete="off"></div>
    <div class="rail-list" id="list"></div>
    <div class="rail-foot">j / k or arrow keys to move. Drop images anywhere to add.</div>
  </aside>
  <main>
    <div class="toolbar" id="toolbar">
      <div class="tool-label" id="tlabel"></div>
      <div class="seg" id="modes">
        <button type="button" data-mode="side">Side by side</button>
        <button type="button" data-mode="slider">Slider</button>
        <button type="button" data-mode="ocr">OCR</button>
      </div>
      <div class="seg" id="zooms">
        <button type="button" data-zoom="fit">Fit</button>
        <button type="button" data-zoom="1">1x</button>
        <button type="button" data-zoom="2">2x</button>
      </div>
      <label class="chk" id="editsLabel"><input type="checkbox" id="edits"> Show edits</label>
    </div>
    <div class="stage" id="stage"></div>
    <div class="details" id="details"></div>
  </main>
</div>
<div class="toasts" id="toasts"></div>
<div class="drop" id="drop"><div>Drop images to scrub</div></div>
<div class="tip" id="tip"></div>

<script>
(() => {
'use strict';

const $ = (s) => document.querySelector(s);
const enc = encodeURIComponent;

function h(tag, attrs, ...kids) {
  const e = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v == null || v === false) continue;
      if (k === 'class') e.className = v;
      else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
      else e.setAttribute(k, v === true ? '' : v);
    }
  }
  for (const c of kids.flat()) {
    if (c == null || c === false) continue;
    e.append(c);
  }
  return e;
}

const ICONS = {
  add: '<path d="M8 3v10M3 8h10"/>',
  play: '<path d="M4.5 3l8 5-8 5z"/>',
  redo: '<path d="M13 8a5 5 0 1 1-1.8-3.8M13 2.5V5h-2.5"/>',
  arrows: '<path d="M2 8h12M5 5L2 8l3 3M11 5l3 3-3 3"/>'
};
function icon(name) {
  const s = document.createElement('span');
  s.style.display = 'inline-flex';
  s.innerHTML = '<svg class="i" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">' + ICONS[name] + '</svg>';
  return s;
}

const store = {
  get(k, d) { try { const v = localStorage.getItem('scrubshot.' + k); return v == null ? d : v; } catch (e) { return d; } },
  set(k, v) { try { localStorage.setItem('scrubshot.' + k, v); } catch (e) { /* ignore */ } }
};

const S = {
  data: null,
  sel: null,
  mode: store.get('mode', 'side'),
  zoom: store.get('zoom', 'fit'),
  edits: store.get('edits', '1') === '1',
  slider: 50,
  filter: '',
  audits: new Map(),
  online: true
};
if (!['side', 'slider', 'ocr'].includes(S.mode)) S.mode = 'side';
if (!['fit', '1', '2'].includes(S.zoom)) S.zoom = 'fit';

/* ---------- api + toast ---------- */
const NOT_MODIFIED = Symbol('not modified');
async function api(path, opts) {
  const o = Object.assign({ cache: 'no-store' }, opts || {});
  o.headers = Object.assign({}, o.headers || {});
  if (o.method === 'POST') o.headers['X-Scrubshot'] = '1';
  const r = await fetch(path, o);
  if (r.status === 304) return NOT_MODIFIED;
  if (r.headers.get('etag')) api.etag = r.headers.get('etag').replace(/"/g, '');
  let body = null;
  if ((r.headers.get('content-type') || '').includes('json')) {
    try { body = await r.json(); } catch (e) { body = null; }
  }
  if (!r.ok) {
    const err = new Error((body && body.error) || (r.status + ' ' + r.statusText));
    err.status = r.status;
    throw err;
  }
  return body;
}
function toast(msg) {
  const t = h('div', { class: 'toast', role: 'alert' }, String(msg));
  $('#toasts').append(t);
  while ($('#toasts').children.length > 4) $('#toasts').firstChild.remove();
  setTimeout(() => t.remove(), 6000);
}

/* ---------- helpers ---------- */
const imgUrl = (name, v) => '/api/image?name=' + enc(name) + '&v=' + enc(v == null ? '' : v);
const thumbUrl = (name, v) => '/api/thumb?name=' + enc(name) + '&w=160&v=' + enc(v == null ? '' : v);
const items = () => (S.data && S.data.items) || [];
// Items the filter box lets through: every word must match the name or the status.
function visibleItems() {
  const words = S.filter.toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return items();
  return items().filter((i) => {
    const name = i.name.toLowerCase();
    return words.every((w) => name.includes(w) || i.status.startsWith(w));
  });
}
const current = () => items().find((i) => i.name === S.sel) || null;
const pct = (v, total) => (total ? (v / total * 100) : 0) + '%';
function boxStyle(b, W, H) {
  return 'left:' + pct(b.x, W) + ';top:' + pct(b.y, H) + ';width:' + pct(b.width, W) + ';height:' + pct(b.height, H);
}
function setBox(el, b, W, H) {
  el.style.left = pct(b.x, W); el.style.top = pct(b.y, H);
  el.style.width = pct(b.width, W); el.style.height = pct(b.height, H);
}
function replacedCount(it) {
  const r = it.report && it.report.replacements;
  return r ? r.filter((x) => !x.skipped).length : 0;
}
function afterOf(it) {
  if (it.status === 'leak' && it.unsafe) return { name: it.unsafe, unsafe: true };
  if (it.output) return { name: it.output, unsafe: false };
  if (it.unsafe) return { name: it.unsafe, unsafe: true };
  return null;
}
function fmtNum(n) {
  if (n == null || n === '') return '';
  if (typeof n !== 'number') return String(n);
  return Number.isInteger(n) ? String(n) : n.toFixed(2);
}
function pill(status) { return h('span', { class: 'pill ' + status }, status); }

/* ---------- header ---------- */
function renderHeader() {
  const d = S.data;
  $('#offline').classList.toggle('on', !S.online);
  if (!d) return;
  $('#ver').textContent = d.version ? 'v' + d.version : '';
  const ws = $('#ws');
  ws.title = d.workspace;
  ws.firstChild.textContent = d.workspace;
  const rc = d.rules && d.rules.count;
  const rs = $('#rules');
  rs.textContent = (rc == null ? 0 : rc) + (rc === 1 ? ' rule' : ' rules');
  rs.title = ((d.rules && d.rules.sources) || []).join('\n');
  $('#busy').classList.toggle('on', !!d.busy);
  const n = items().filter((i) => i.status === 'new').length;
  const b = $('#scrubNew');
  b.replaceChildren(icon('play'), 'Scrub new' + (n ? ' (' + n + ')' : ''));
  b.disabled = n === 0;
  const total = items().length, vis = visibleItems().length;
  $('#count').textContent = total ? '(' + (vis === total ? total : vis + ' of ' + total) + ')' : '';
}

/* ---------- rail ---------- */
const rows = new Map();
function makeRow(name) {
  const img = h('img', { alt: '', loading: 'lazy', draggable: 'false' });
  const el = h('div', { class: 'row', role: 'button', tabindex: '-1', 'data-name': name, onclick: () => select(name) },
    h('div', { class: 'thumb' }, img),
    h('div', { style: 'min-width:0' },
      h('div', { class: 'rname' }),
      h('div', { class: 'rmeta' }, h('span', { class: 'pill' }), h('span', { class: 'cnt' }))));
  return { el, img, v: null, sig: '' };
}
function renderRail() {
  const list = $('#list');
  const its = visibleItems();
  if (!its.length) {
    rows.clear();
    list.replaceChildren(h('div', { class: 'rail-empty' }, items().length
      ? 'No images match "' + S.filter + '".'
      : 'No images yet. Drop screenshots anywhere on this page, or add them to the workspace folder.'));
    return;
  }
  if (list.firstChild && list.firstChild.classList.contains('rail-empty')) list.replaceChildren();
  const seen = new Set();
  const ordered = [];
  for (const it of its) {
    seen.add(it.name);
    let r = rows.get(it.name);
    if (!r) { r = makeRow(it.name); rows.set(it.name, r); }
    const sig = [it.status, replacedCount(it), it.name === S.sel].join('|');
    if (sig !== r.sig) {
      r.sig = sig;
      r.el.classList.toggle('sel', it.name === S.sel);
      r.el.querySelector('.rname').textContent = it.name;
      r.el.title = it.name;
      const p = r.el.querySelector('.pill');
      p.className = 'pill ' + it.status;
      p.textContent = it.status;
      const c = r.el.querySelector('.cnt');
      const n = replacedCount(it);
      const lk = it.report && it.report.leaks ? it.report.leaks.length : 0;
      c.textContent = lk ? lk + ' leaked' : (it.report ? n + ' replaced' : '');
    }
    if (r.v !== it.updated) { r.v = it.updated; r.img.src = thumbUrl(it.name, it.updated); }
    ordered.push(r.el);
  }
  for (const [name, r] of rows) {
    if (!seen.has(name)) { r.el.remove(); rows.delete(name); }
  }
  const cur = Array.from(list.children);
  if (cur.length !== ordered.length || cur.some((e, i) => e !== ordered[i])) list.replaceChildren(...ordered);
}

$('#filter').addEventListener('input', (e) => {
  S.filter = e.target.value;
  $('#list').scrollTop = 0;
  renderHeader();
  renderRail();
});

function select(name) {
  if (S.sel === name) return;
  S.sel = name;
  renderRail();
  renderMain();
  const r = rows.get(name);
  if (r) r.el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
}
function move(d) {
  const its = visibleItems();
  if (!its.length) return;
  let i = its.findIndex((x) => x.name === S.sel);
  i = Math.max(0, Math.min(its.length - 1, (i < 0 ? 0 : i + d)));
  select(its[i].name);
}

/* ---------- audit ---------- */
function ensureAudit(it) {
  const a = S.audits.get(it.name);
  if (a && a.v === it.updated) return a;
  const entry = { v: it.updated, state: 'pending', data: null, err: null };
  S.audits.set(it.name, entry);
  api('/api/audit?name=' + enc(it.name))
    .then((d) => { entry.state = 'ok'; entry.data = d; })
    .catch((e) => { entry.state = 'err'; entry.err = e.message; })
    .finally(() => {
      if (S.audits.get(it.name) === entry && S.sel === it.name && S.mode === 'ocr') renderMain();
    });
  return entry;
}

/* ---------- tooltip ---------- */
const tip = $('#tip');
function showTip(e, nodes) {
  tip.replaceChildren(...nodes);
  tip.style.display = 'block';
  const pad = 14;
  let x = e.clientX + pad, y = e.clientY + pad;
  const w = tip.offsetWidth, hh = tip.offsetHeight;
  if (x + w > innerWidth - 4) x = Math.max(4, e.clientX - w - pad);
  if (y + hh > innerHeight - 4) y = Math.max(4, e.clientY - hh - pad);
  tip.style.left = x + 'px'; tip.style.top = y + 'px';
}
function hideTip() { tip.style.display = 'none'; }

/* ---------- frames ---------- */
function makeImg(url, onload) {
  const img = h('img', { src: url, alt: '', draggable: 'false' });
  img.addEventListener('load', () => {
    if (S.zoom === '2') img.style.width = img.naturalWidth * 2 + 'px';
    if (onload) onload(img);
  });
  return img;
}
function watchUp(frame, img) {
  if (S.zoom !== 'fit' || typeof ResizeObserver === 'undefined') return;
  new ResizeObserver(() => {
    frame.classList.toggle('up', !!img.naturalWidth && img.clientWidth > img.naturalWidth * 1.02);
  }).observe(frame);
}

function buildMarks(ov, it, W, H, showEdits) {
  ov.replaceChildren();
  const rep = (it.report && it.report.replacements) || [];
  if (showEdits) {
    for (const r of rep) {
      const f = r.render && r.render.fill;
      if (!f) continue;
      const m = h('div', { class: 'mk edit' });
      setBox(m, f, W, H);
      m.addEventListener('pointermove', (e) => showTip(e, [
        h('div', { class: 't' }, r.original, h('span', { class: 'k' }, '  ->  '), r.replacement),
        h('div', { class: 'k' }, (r.rule || 'rule') + (r.render.font ? ' / ' + r.render.font + ' ' + fmtNum(r.render.fontSize) : ''))
      ]));
      m.addEventListener('pointerleave', hideTip);
      ov.append(m);
    }
  }
  const leaks = (it.report && it.report.leaks) || [];
  for (const l of leaks) {
    if (!l.box) continue;
    const m = h('div', { class: 'mk leak' });
    setBox(m, l.box, W, H);
    m.addEventListener('pointermove', (e) => showTip(e, [
      h('div', { class: 't' }, l.text),
      h('div', { class: 'k' }, 'Leaked' + (l.rule ? ' / ' + l.rule : ''))
    ]));
    m.addEventListener('pointerleave', hideTip);
    ov.append(m);
  }
}

function buildAudit(ov, a, W, H) {
  ov.replaceChildren();
  const lines = a.lines || [];
  const spanEls = [];
  lines.forEach((ln, li) => {
    if (ln.matches && ln.matches.length && ln.box) {
      const l = h('div', { class: 'ln hit' });
      setBox(l, ln.box, W, H);
      ov.append(l);
    }
  });
  lines.forEach((ln, li) => {
    const spans = ln.spans && ln.spans.length ? ln.spans : (ln.box ? [{ text: ln.text, box: ln.box }] : []);
    for (const sp of spans) {
      if (!sp.box) continue;
      const el = h('div', { class: 'sp' });
      setBox(el, sp.box, W, H);
      el.addEventListener('pointerenter', () => el.classList.add('on'));
      el.addEventListener('pointermove', (e) => {
        const nodes = [h('div', { class: 't' }, sp.text)];
        if (sp.confidence != null) {
          const c = sp.confidence <= 1 ? Math.round(sp.confidence * 100) + '%' : String(sp.confidence);
          nodes.push(h('div', { class: 'k' }, 'confidence ' + c));
        }
        for (const m of ln.matches || []) {
          nodes.push(h('div', { class: 'm' },
            h('span', { class: 't' }, m.text), h('span', { class: 'k' }, '  ->  '), h('span', { class: 't' }, m.replacement),
            m.rule ? h('div', { class: 'k' }, m.rule) : null));
        }
        showTip(e, nodes);
      });
      el.addEventListener('pointerleave', () => { el.classList.remove('on'); hideTip(); });
      ov.append(el);
      spanEls.push(el);
    }
  });
}

function paneLabel(text, name, unsafe) {
  return h('div', { class: 'pane-head' }, text, unsafe ? h('span', { class: 'tag-unsafe' }, 'UNSAFE') : null, h('span', { class: 'mono' }, name || ''));
}
function emptyAfter(it) {
  let msg;
  if (it.status === 'new') msg = 'Not scrubbed yet. Use "Scrub new" or re-run this item.';
  else if (it.status === 'queued') msg = 'Queued. Waiting for the scrubber.';
  else if (it.status === 'running') msg = 'Scrubbing now.';
  else if (it.status === 'error') msg = 'Scrub failed. No output was written.' + ((it.error || (it.report && it.report.error)) ? '\n' + (it.error || it.report.error) : '');
  else msg = 'No output file found.';
  return h('div', { class: 'pane-empty', style: 'white-space:pre-wrap' }, msg);
}

function renderSide(it, stage) {
  const aft = afterOf(it);
  let syncing = false;
  const bodies = [];
  const mk = (label, name, unsafe, inner) => {
    const body = h('div', { class: 'pane-body' }, inner);
    bodies.push(body);
    return h('div', { class: 'pane' }, paneLabel(label, name, unsafe), body);
  };
  const bFrame = frameFor(it.name, it, false);
  const left = mk('Before', it.name, false, bFrame);
  let right;
  if (aft) right = mk('After', aft.name, aft.unsafe, frameFor(aft.name, it, true));
  else right = mk('After', '', false, emptyAfter(it));
  stage.append(h('div', { class: 'sbs' }, left, right));
  if (aft) {
    bodies.forEach((b, i) => b.addEventListener('scroll', () => {
      if (syncing) return;
      syncing = true;
      const o = bodies[1 - i];
      o.scrollLeft = b.scrollLeft; o.scrollTop = b.scrollTop;
      requestAnimationFrame(() => { syncing = false; });
    }));
  }
}

function frameFor(name, it, isAfter) {
  const ov = h('div', { class: 'ov' });
  const img = makeImg(imgUrl(name, it.updated), (im) => {
    if (isAfter) buildMarks(ov, it, im.naturalWidth, im.naturalHeight, S.edits);
  });
  const frame = h('div', { class: 'frame z-' + S.zoom }, img, ov);
  watchUp(frame, img);
  return frame;
}

function renderSlider(it, stage) {
  const aft = afterOf(it);
  const ov = h('div', { class: 'ov' });
  const before = makeImg(imgUrl(it.name, it.updated));
  const frame = h('div', { class: 'frame slider-wrap z-' + S.zoom }, before);
  watchUp(frame, before);
  if (aft) {
    const aimg = h('img', { src: imgUrl(aft.name, it.updated), alt: '', draggable: 'false' });
    const layer = h('div', { class: 'after-layer' }, aimg, ov);
    const handle = h('div', { class: 'handle' }, h('span', null, icon('arrows')));
    const apply = () => {
      layer.style.clipPath = 'inset(0 0 0 ' + S.slider + '%)';
      handle.style.left = S.slider + '%';
    };
    aimg.addEventListener('load', () => buildMarks(ov, it, aimg.naturalWidth, aimg.naturalHeight, S.edits));
    frame.append(layer, handle,
      h('div', { class: 'corner l' }, 'Before'),
      h('div', { class: 'corner r' }, aft.unsafe ? 'After (UNSAFE)' : 'After'));
    apply();
    let drag = false;
    const setPos = (e) => {
      const r = frame.getBoundingClientRect();
      S.slider = Math.max(0, Math.min(100, (e.clientX - r.left) / r.width * 100));
      apply();
    };
    frame.addEventListener('pointerdown', (e) => { drag = true; frame.setPointerCapture(e.pointerId); setPos(e); e.preventDefault(); });
    frame.addEventListener('pointermove', (e) => { if (drag) setPos(e); });
    frame.addEventListener('pointerup', () => { drag = false; });
    frame.addEventListener('pointercancel', () => { drag = false; });
    stage.append(h('div', { class: 'scroll' }, frame));
  } else {
    stage.append(h('div', { class: 'scroll' }, frame));
    stage.append(h('div', { class: 'ocr-err' }, 'No scrubbed image to compare. ' + (it.status === 'new' ? 'Not scrubbed yet.' : it.status)));
  }
}

function renderOcr(it, stage) {
  const a = ensureAudit(it);
  const ov = h('div', { class: 'ov' });
  const img = makeImg(imgUrl(it.name, it.updated), (im) => {
    if (a.state === 'ok') buildAudit(ov, a.data, a.data.width || im.naturalWidth, a.data.height || im.naturalHeight);
  });
  const frame = h('div', { class: 'frame z-' + S.zoom }, img, ov);
  watchUp(frame, img);
  if (a.state === 'ok' && img.complete && img.naturalWidth) buildAudit(ov, a.data, a.data.width || img.naturalWidth, a.data.height || img.naturalHeight);
  stage.append(h('div', { class: 'scroll' }, frame));
  if (a.state === 'pending') stage.append(h('div', { class: 'reading' }, h('i', { class: 'spin' }), 'Reading text...'));
  if (a.state === 'err') stage.append(h('div', { class: 'ocr-err' }, 'OCR failed: ' + a.err));
}

/* ---------- details ---------- */
function renderDetails(it) {
  const box = $('#details');
  const rep = it.report;
  const head = h('div', { class: 'dhead' },
    h('span', { class: 'mono grow', title: it.name }, it.name),
    pill(it.status),
    h('button', { type: 'button', id: 'rerun', onclick: () => rerun(it.name), disabled: it.status === 'queued' || it.status === 'running' },
      icon('redo'), it.status === 'new' ? 'Scrub' : 'Re-run'));
  const body = h('div', { class: 'dbody' });
  const err = it.error || (rep && rep.error);
  if (err) body.append(h('div', { class: 'note err' }, err));
  if (!rep) {
    body.append(h('div', { class: 'muted' }, it.status === 'new' ? 'No report yet. This image has not been scrubbed.' : 'No report available.'));
  } else {
    const leaks = rep.leaks || [];
    if (leaks.length) {
      body.append(h('h3', null, 'Leaks (' + leaks.length + ')'));
      body.append(h('div', { class: 'tablewrap' }, h('table', null,
        h('thead', null, h('tr', null, h('th', null, 'Text'), h('th', null, 'Rule'), h('th', { class: 'num' }, 'Line'), h('th', { class: 'num' }, 'OCR scale'))),
        h('tbody', null, leaks.map((l) => h('tr', null,
          h('td', { class: 'mono' }, l.text), h('td', null, l.rule || ''),
          h('td', { class: 'num' }, fmtNum(l.line)), h('td', { class: 'num' }, fmtNum(l.ocrScale))))))));
    }
    const reps = rep.replacements || [];
    body.append(h('h3', null, 'Replacements (' + reps.length + ')'));
    if (!reps.length) body.append(h('div', { class: 'muted' }, 'Nothing was replaced.'));
    else {
      body.append(h('div', { class: 'tablewrap' }, h('table', null,
        h('thead', null, h('tr', null,
          h('th', null, 'Original / replacement'), h('th', null, 'Rule'), h('th', null, 'Font'),
          h('th', { class: 'num' }, 'Size'), h('th', { class: 'num' }, 'Width delta'), h('th', { class: 'num' }, 'Fit error'), h('th', null, 'Notes'))),
        h('tbody', null, reps.map((r) => {
          const rd = r.render || {};
          const notes = [];
          if (r.skipped) notes.push('Skipped: ' + r.skipped);
          for (const w of rd.warnings || []) notes.push(w);
          return h('tr', { class: r.skipped ? 'skipped' : '' },
            h('td', { class: 'mono' }, r.original, h('span', { class: 'arrow' }, '->'), r.replacement),
            h('td', null, r.rule || ''),
            h('td', null, rd.font || ''),
            h('td', { class: 'num' }, fmtNum(rd.fontSize)),
            h('td', { class: 'num' }, fmtNum(rd.widthDelta)),
            h('td', { class: 'num' }, fmtNum(rd.fitError)),
            h('td', null, notes.join('; ')));
        })))));
    }
    const warns = rep.warnings || [];
    if (warns.length) {
      body.append(h('h3', null, 'Warnings'));
      for (const w of warns) body.append(h('div', { class: 'note warn' }, w));
    }
  }
  box.replaceChildren(head, body);
}

/* ---------- main ---------- */
let stageSig = '', detailSig = '';
function renderMain() {
  const it = current();
  const stage = $('#stage');
  const details = $('#details');
  document.querySelectorAll('#modes button').forEach((b) => b.classList.toggle('on', b.dataset.mode === S.mode));
  document.querySelectorAll('#zooms button').forEach((b) => b.classList.toggle('on', b.dataset.zoom === S.zoom));
  $('#edits').checked = S.edits;
  $('#editsLabel').classList.toggle('off', S.mode === 'ocr');
  if (!it) {
    $('#tlabel').textContent = '';
    if (stageSig !== 'none') {
      stageSig = 'none'; detailSig = 'none';
      hideTip();
      stage.replaceChildren(h('div', { class: 'empty-main' }, items().length ? 'Select an image.' : 'Drop screenshots here, or add images to the workspace folder.\nAgents can keep using the CLI in that folder; this page updates on its own.'));
      stage.firstChild.style.whiteSpace = 'pre-line';
      details.replaceChildren();
    }
    return;
  }
  $('#tlabel').textContent = it.name;
  $('#tlabel').title = it.name;
  const a = S.mode === 'ocr' ? ensureAudit(it) : null;
  const sSig = [it.name, it.updated, it.output, it.unsafe, it.status === 'leak', S.mode, S.zoom, S.edits, a ? a.state : ''].join('|');
  if (sSig !== stageSig) {
    stageSig = sSig;
    hideTip();
    stage.replaceChildren();
    if (S.mode === 'side') renderSide(it, stage);
    else if (S.mode === 'slider') renderSlider(it, stage);
    else renderOcr(it, stage);
  }
  const dSig = JSON.stringify([it.name, it.status, it.error, it.report, it.updated]);
  if (dSig !== detailSig) {
    detailSig = dSig;
    renderDetails(it);
  }
}

function renderAll() {
  renderHeader();
  renderRail();
  renderMain();
}

/* ---------- actions ---------- */
const CONFIRM_OVER = 20;
async function scrubNew() {
  const n = items().filter((i) => i.status === 'new').length;
  if (n > CONFIRM_OVER && !confirm('Scrub ' + n + ' screenshots? They run one at a time and each can take a few seconds.')) return;
  try { await api('/api/scrub', { method: 'POST' }); } catch (e) { toast(e.message); }
  poll();
}
async function rerun(name) {
  try { await api('/api/scrub?name=' + enc(name), { method: 'POST' }); } catch (e) { toast(e.message); }
  poll();
}
const IMG_RE = /\.(png|jpe?g|heic|tiff?|gif|bmp)$/i;
async function upload(files) {
  const list = Array.from(files).filter((f) => IMG_RE.test(f.name) || (f.type || '').startsWith('image/'));
  if (!list.length) { toast('No image files in that drop.'); return; }
  let last = null;
  for (const f of list) {
    try {
      const r = await api('/api/upload?name=' + enc(f.name), { method: 'POST', body: f, headers: { 'Content-Type': f.type || 'application/octet-stream' } });
      if (r && r.name) last = r.name;
    } catch (e) { toast(f.name + ': ' + e.message); }
  }
  if (last) S.sel = last;
  await poll();
}

/* ---------- polling ---------- */
function setBanner(msg) {
  const b = $('#banner');
  b.classList.toggle('on', !!msg);
  if (msg) b.replaceChildren(msg, h('small', null, 'Allow access when macOS asks. This page retries on its own.'));
  else b.replaceChildren();
}
let polling = false;
async function poll() {
  if (polling) return;
  polling = true;
  try {
    const d = await api('/api/state' + (S.etag ? '?since=' + enc(S.etag) : ''));
    S.online = true;
    setBanner('');
    if (d === NOT_MODIFIED) { renderHeader(); return; }
    S.etag = api.etag || null;
    S.data = d;
    if (!current()) S.sel = d.items && d.items.length ? d.items[0].name : null;
    renderAll();
  } catch (e) {
    if (e.status === 503) {
      // The server is up but cannot list the folder yet (macOS may be asking for access).
      S.online = true;
      setBanner(e.message);
      renderHeader();
      return;
    }
    setBanner('');
    if (S.online) toast('Server: ' + e.message);
    S.online = false;
    renderHeader();
  } finally {
    polling = false;
  }
}

/* ---------- wiring ---------- */
document.querySelectorAll('#modes button').forEach((b) => b.addEventListener('click', () => {
  S.mode = b.dataset.mode; store.set('mode', S.mode); renderMain();
}));
document.querySelectorAll('#zooms button').forEach((b) => b.addEventListener('click', () => {
  S.zoom = b.dataset.zoom; store.set('zoom', S.zoom); renderMain();
}));
$('#edits').addEventListener('change', (e) => { S.edits = e.target.checked; store.set('edits', S.edits ? '1' : '0'); renderMain(); });
$('#scrubNew').addEventListener('click', scrubNew);
$('#pick').replaceChildren(icon('add'), 'Add images');
$('#pick').addEventListener('click', () => $('#file').click());
$('#file').addEventListener('change', (e) => { const f = e.target.files; if (f && f.length) upload(f); e.target.value = ''; });

let dragDepth = 0;
const hasFiles = (e) => e.dataTransfer && Array.from(e.dataTransfer.types || []).includes('Files');
window.addEventListener('dragenter', (e) => { if (!hasFiles(e)) return; e.preventDefault(); dragDepth++; $('#drop').classList.add('on'); });
window.addEventListener('dragover', (e) => { if (hasFiles(e)) e.preventDefault(); });
window.addEventListener('dragleave', (e) => { if (!hasFiles(e)) return; dragDepth = Math.max(0, dragDepth - 1); if (!dragDepth) $('#drop').classList.remove('on'); });
window.addEventListener('drop', (e) => {
  if (!hasFiles(e)) return;
  e.preventDefault(); dragDepth = 0; $('#drop').classList.remove('on');
  upload(e.dataTransfer.files);
});

window.addEventListener('keydown', (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const t = e.target;
  if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable)) return;
  if (e.key === 'j' || e.key === 'ArrowDown') { e.preventDefault(); move(1); }
  else if (e.key === 'k' || e.key === 'ArrowUp') { e.preventDefault(); move(-1); }
});

renderMain();
renderHeader();
poll();
setInterval(() => { if (!document.hidden) poll(); }, 1500);
document.addEventListener('visibilitychange', () => { if (!document.hidden) poll(); });
})();
</script>
</body>
</html>
"""#
