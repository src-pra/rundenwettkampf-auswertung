'use strict';

/* =========================================================
   Rundenwettkampf Auswertung (league match replay for shooting clubs)

   What it does
     Takes the league matches (Rundenwettkaempfe) from the DISAG OpticScore database, which server.ps1
     reads and hands over in the XML format of the DISAG result exports, and replays a match on a TV:
     every shooter in full screen shot by shot, an overview of all shooters in between, and the final
     result at the end.

   One page, two roles (same index.html and app.js)
     - Control page (index.html): pick the competition, start/pause, step through it.
     - TV display (index.html?display): has no controls and simply mirrors the control page.
     Started via Starten.cmd, the PowerShell server (server.ps1) serves both pages and passes
     the control page's state to the TV display (see "Two screens" further down).
     Without the server (index.html opened by double-click) there is no data source: the page only says so.

   Branding
     Nothing club specific is in the code. Club name, three colors and the logo come from one file
     (branding.json, handled by server.ps1, edited in the settings dialog); without it neutral defaults apply.

   Main data structures
     comp   = one competition, built by parseResult() from one <result> block:
              { name, date, time, key, sortKey, decimal, bestX, maxShots, finals, disciplines,
                teams: [{ name, shooters: [{ name, disk, rested, decimal,
                                             shots: [{ x, y, full, dec, value, series, order }] }] }] }
              x/y are in 1/100 mm from the target center, full = whole ring, dec = ring with tenths,
              value = the one that counts for this shooter (dec for rested, otherwise full).
              key identifies a comp (duplicates across files, sync with the TV), sortKey sorts newest first.
              buildFrames() adds shooterCount.
     frames = the fixed playback sequence built by buildFrames(): one entry per picture shown on
              the TV (full screen view of a shooter after n shots, or the overview).
     show   = the running playback: current comp, frames, frame index, timers, DOM references.

   Live data from DISAG JSON Live (only with the server)
     server.ps1 takes the JSON Live events of the OpticScore server from the UDP broadcast or the log file (selectable).
     The TV idle screen shows who is shooting at each range and their shot progress (renderRanges), the control page
     shows the connection status (setGateStatus).
     A shooter shows up with their first shot (sighting shots too); JSON Live has no login event.
     Data source, server, UDP port, log file and number of ranges are set in the settings dialog; the number of shots
     only comes from DISAG.

   Sections in this file (in order)
     Helpers & settings, Branding (incl. settings dialog), Reading the matches, Selection screen,
     TV display (geometry, drawing, frames, rendering, playback, overlays, controls), Two screens
     (sync with the server, Gate status, idle screen with the ranges, TV polling loop),
     Choosing the screen, Start.
   ========================================================= */

/* =========================================================
   Helpers & settings
   ========================================================= */
/* Program version, also in server.ps1 ($AppVersion) and Anleitung.html; make-release.ps1 checks they match */
const APP_VERSION = '1.0';
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
/* Escape text for use inside HTML templates */
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
/* Parse a number that may use a German decimal comma ("9,3"), 0 if invalid */
const num = v => { const n = parseFloat(String(v ?? '').replace(',', '.')); return Number.isFinite(n) ? n : 0; };
/* Format with one decimal and a German comma (9.3 -> "9,3") */
const fmtDec = v => v.toFixed(1).replace('.', ',');
/* Tenths only when scoring in tenths (rested), otherwise whole rings */
const fmtScore = (v, decimal) => (decimal ? fmtDec(v) : String(Math.round(v)));
const round1 = v => Math.round(v * 10) / 10;
/* Direct child elements with a given tag name (the export nests <team>, <shooter>, <series>, <shot>) */
const kids = (el, name) => [...el.children].filter(c => c.tagName.toLowerCase() === name);

/* index.html?display = TV display on screen 2, only mirrors the control page */
const DISPLAY = new URLSearchParams(location.search).has('display');
/* index.html?display&windowed = TV display runs as a normal window instead of full screen */
const DISPLAY_WINDOWED = new URLSearchParams(location.search).has('windowed');
const LINKED_DISPLAY = DISPLAY && location.protocol.startsWith('http');

/* shotGap: gap between the shots of a series, pause: pause before the first shot,
   after each series and at the end of a shooter, overview: duration of the overview (all in seconds) */
const SETTINGS_KEY = 'rwkAuswertung.timers';
const LEGACY_SETTINGS_KEY = 'svRwkTool.settings2';   // versions before 1.0
const DEFAULTS = { shotGap: 0.5, pause: 5, overview: 5 };
/* Timer settings of this browser, kept in localStorage */
const settings = (() => {
  try { return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(SETTINGS_KEY) || localStorage.getItem(LEGACY_SETTINGS_KEY)) }; }
  catch (e) { return { ...DEFAULTS }; }
})();
function saveSettings() {
  try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings)); } catch (e) { /* ignore */ }
}

/* Target dimensions in 1/100 mm (same unit as the x/y values in the export). ring(n) = outer radius of ring n. */
const DISKS = {
  lg: { ring: n => 25 + (10 - n) * 250, black: 4, pellet: 225 },   // air rifle
  lp: { ring: n => 575 + (10 - n) * 800, black: 7, pellet: 225 }   // air pistol
};

/* Rested shooting (Auflage, scored in tenths). The menu numbers of the shots (menuid "100_6") are the club's own
   menu points and differ from club to club, so the name of the menu point decides: server.ps1 adds it to every
   shooter (menu="Luftgewehr: Liga Auflage"). Without a menu name the match name decides ("... LGA", "LPA", "Auflage"). */
const isRested = (menuName, matchName) => (menuName ? /auflage/i.test(menuName) : /\b(LGA|LPA)\b|auflage/i.test(matchName || ''));
/* Hit color by whole rings, as DISAG does it: 10 red, 9 yellow, 8 and below green */
const ringClass = full => (full >= 10 ? 'r10' : full >= 9 ? 'r9' : 'r8');
/* Label shown to viewers, e.g. "LG", "LP" or "LG Auflage" */
const disciplineLabel = sh => `${sh.disk.toUpperCase()}${sh.rested ? ' Auflage' : ''}`;

/* =========================================================
   Branding: club name, logo and colors
   All of it lives in ONE file on this PC (branding.json, handled by server.ps1), so the control page and
   the TV display look the same and a club can export it and load it on another PC.
   Without that file (or without the server) the neutral defaults below apply.
   ========================================================= */
const SERVED = location.protocol.startsWith('http');
const DEFAULT_LOGO = 'assets/logo.png';
/* The three colors a club sets. Everything else follows from them: style.css mixes light/dark accent and
   the leading team color from the main color, panels and borders from background and text,
   and applyBranding picks a light or dark text color for the background. */
const BRAND_COLORS = [
  { key: 'accent', css: '--accent', label: 'Hauptfarbe', hint: 'Knöpfe, Rahmen, Teamnamen, führendes Team', def: '#4a90d9' },
  { key: 'second', css: '--second', label: 'Zweitfarbe', hint: 'Streifen unter dem Titel', def: '#e8b030' },
  { key: 'background', css: '--bg', label: 'Hintergrund', hint: 'Schrift, Flächen und Ränder passen sich an', def: '#101418' }
];
/* Valid color in #rrggbb form */
const isHex = v => /^#[0-9a-f]{6}$/i.test(v || '');
/* Color of a branding object, or the default when it has none */
const brandColor = (b, key) => (isHex(b.colors?.[key]) ? b.colors[key].toLowerCase() : BRAND_COLORS.find(c => c.key === key).def);
/* Logo types accepted for the logo (same list as in server.ps1) */
const LOGO_DATA_URL = /^data:image\/(png|jpeg|svg\+xml|webp|gif);base64,/;
let branding = { name: '', colors: {}, logo: false, rev: 0 };

/* Club logo from the server if the branding file has one, otherwise the bundled neutral logo */
const logoUrl = (b = branding) => (SERVED && b.logo ? `/api/branding/logo?v=${b.rev}` : DEFAULT_LOGO);

/* Light color: dark text on it, dark color: white text */
function textOn(hex) {
  const [r, g, b] = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map(c => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.25 ? '#151515' : '#ffffff';
}

/* Applies club name, logo and colors to every place on the page. The text color follows the background
   (light or dark), slightly tinted with the main color. Without a club name the name lines are hidden. */
function applyBranding(b, logoSrc = logoUrl(b)) {
  const root = document.documentElement.style;
  BRAND_COLORS.forEach(c => root.setProperty(c.css, brandColor(b, c.key)));
  const lightText = textOn(brandColor(b, 'background')) === '#ffffff';
  root.setProperty('--text', `color-mix(in srgb, ${lightText ? '#ffffff' : '#111111'} 88%, var(--accent))`);
  root.setProperty('--on-accent', textOn(brandColor(b, 'accent')));
  const name = (b.name || '').trim();
  $$('.club-name').forEach(el => { el.textContent = name; el.hidden = !name; });
  $$('img.club-logo').forEach(img => { if (img.getAttribute('src') !== logoSrc) img.src = logoSrc; });
  $('#favicon').href = logoSrc;
}

/* Fetches the stored branding from the server and applies it */
async function loadBranding() {
  if (!SERVED) return;
  try {
    branding = await getJson('/api/branding');
    applyBranding(branding);
  } catch (e) { /* server not reachable: keep the defaults */ }
}

/* ---------- Settings dialog ---------- */
/* Unsaved values of the dialog. logo: undefined = keep the saved one, '' = default logo, data URL = new logo */
let draft = null;   // { name, colors, logo }

function draftLogoSrc() {
  if (draft.logo === undefined) return logoUrl();
  return draft.logo || DEFAULT_LOGO;
}

/* Live preview of the unsaved values in the settings dialog */
function previewDraft() {
  applyBranding({ ...branding, name: draft.name, colors: draft.colors }, draftLogoSrc());
  $('#set-logo-preview').src = draftLogoSrc();
}

/* Hint or error line inside the settings dialog */
function setMsg(text, isError = false) {
  const m = $('#set-msg');
  m.textContent = text || '';
  m.hidden = !text;
  m.classList.toggle('err', isError);
}

/* Club name and color fields from the draft */
function fillBrandingFields() {
  $('#set-name').value = draft.name;
  $('#set-colors').innerHTML = BRAND_COLORS.map(c => `
    <label class="set-color" title="${esc(c.hint)}">
      <input type="color" data-color="${c.key}" value="${brandColor(draft, c.key)}">
      <span><b>${esc(c.label)}</b><small>${esc(c.hint)}</small></span>
    </label>`).join('');
}

/* Opens the settings dialog with a copy (draft) of the current branding */
function openSettings() {
  draft = { name: branding.name || '', colors: { ...branding.colors }, logo: undefined };
  fillBrandingFields();
  setMsg('');
  previewDraft();
  // Live data and database settings come from the server
  getJson('/api/gate').then(g => {
    $('#set-gate-enabled').checked = g.enabled;
    $(`input[name="set-gate-source"][value="${g.source}"]`).checked = true;
    showGateSource(g.source);
    $('#set-gate-host').value = g.host || '';
    $('#set-gate-port').value = g.port || '';
    $('#set-gate-file').value = g.file || '';
    $('#set-gate-ranges').value = g.rangeCount;
    $('#set-gate-rangelog').checked = !!g.rangeLog?.on;
    $('#set-gate-rangelog-folder').value = g.rangeLogFolder || '';
    $('#set-gate-rangelog-folder').placeholder = g.rangeLogDefault || 'C:\\Disag\\Daten\\RangesLog';
  }).catch(() => {});
  getJson('/api/oss/loglevel').then(showOssState).catch(() => showOssState(null));
  getJson('/api/league').then(l => {
    $('#set-league-show').checked = l.showToday;
    $('#set-league-file').value = l.file || '';
  }).catch(() => {});
  $('#settings').hidden = false;
  $('#set-name').focus();
}

/* Closes the dialog; revert = undo the live preview (Abbrechen/Esc) */
function closeSettings(revert) {
  draft = null;
  $('#settings').hidden = true;
  if (revert) applyBranding(branding);
}

/* Every file in the settings is chosen with the same Windows dialog, opened by the server (it needs the real
   path of the database and the log file, which a browser dialog never reveals). url = the pick API;
   the answer is that API's JSON, null if the dialog could not be opened (message shown). While it is open
   the buttons are disabled, because the server waits for the dialog. */
async function pickFile(url) {
  const buttons = $$('#settings .set-btn');
  buttons.forEach(b => { b.disabled = true; });
  try {
    const r = await postJson(url, {});
    if (r.error) setMsg(r.error, true);
    return r;
  } catch (e) {
    setMsg('Dateiauswahl konnte nicht geöffnet werden. Läuft das Programm noch (Starten.cmd)?', true);
    return null;
  } finally {
    buttons.forEach(b => { b.disabled = false; });
    showOssState(ossLog);   // the OpticScore button stays off if OpticScore is not set up here
  }
}

$('#settings-open').onclick = openSettings;
$('#set-cancel').onclick = () => closeSettings(true);
$('#settings').addEventListener('keydown', e => { if (e.key === 'Escape') closeSettings(true); });
$('#set-name').addEventListener('input', e => { draft.name = e.target.value; previewDraft(); });
$('#set-colors').addEventListener('input', e => {
  if (!e.target.matches('input[data-color]')) return;
  draft.colors[e.target.dataset.color] = e.target.value.toLowerCase();
  previewDraft();
});
/* "Logo wählen": the server checks type and size and hands the picture back as data URL */
$('#set-logo-pick').onclick = async () => {
  const r = await pickFile('/api/branding/logo/pick');
  if (!r?.logo || !draft) return;
  draft.logo = r.logo;
  setMsg('');
  previewDraft();
};
$('#set-logo-reset').onclick = () => {
  draft.logo = '';
  previewDraft();
};
/* Only resets the fields, nothing is stored until "Speichern" is clicked */
$('#set-reset').onclick = () => {
  draft.name = '';
  draft.colors = {};
  draft.logo = '';
  fillBrandingFields();
  setMsg('');
  previewDraft();
};

/* Branding file: "Exportieren" downloads the saved branding as one file */
$('#set-export').onclick = async () => {
  try {
    const r = await fetch('/api/branding/file', { cache: 'no-store' });
    const text = await r.text();
    if (!r.ok) throw new Error(JSON.parse(text).error);
    const club = (branding.name || 'Verein').replace(/[\\/:*?"<>|]+/g, '').trim() || 'Verein';
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
    a.download = `branding ${club}.json`;
    document.body.append(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 2000);
    setMsg('Das gespeicherte Branding liegt jetzt als Datei im Download-Ordner.');
  } catch (err) { setMsg(err.message || 'Export hat nicht geklappt.', true); }
};
/* "Laden" fills the dialog from a branding file; stored only with "Speichern" */
$('#set-import').onclick = async () => {
  const file = await pickFile('/api/branding/file/pick');
  if (!file?.file || !draft) return;
  try {
    const data = JSON.parse(file.text.replace(/^﻿/, ''));
    if (!data || typeof data !== 'object' || (data.format && data.format !== 'rwk-branding')) throw new Error('format');
    draft.name = String(data.name ?? '').slice(0, 80);
    draft.colors = {};
    BRAND_COLORS.forEach(c => { if (isHex(data.colors?.[c.key])) draft.colors[c.key] = data.colors[c.key].toLowerCase(); });
    draft.logo = typeof data.logo === 'string' && LOGO_DATA_URL.test(data.logo) ? data.logo : '';
    fillBrandingFields();
    previewDraft();
    setMsg(`Branding „${draft.name || file.file}“ geladen. Mit „Speichern“ übernehmen.`);
  } catch (err) { setMsg('Das ist keine gültige Branding-Datei.', true); }
};

/* Shows only the fields of the chosen JSON Live data source ("udp" or "file") */
function showGateSource(source) {
  $$('#set-gate-fields [data-gate-source]').forEach(el => { el.hidden = el.dataset.gateSource !== source; });
  $('#set-gate-fields').classList.toggle('set-gate-udp', source === 'udp');
}
$$('input[name="set-gate-source"]').forEach(radio => {
  radio.onchange = () => showGateSource(radio.value);
});
/* JSON Live log file and DISAG database: the dialog only fills the field, stored with "Speichern" */
$('#set-gate-pick').onclick = async () => {
  const r = await pickFile('/api/gate/file/pick');
  if (r?.file) $('#set-gate-file').value = r.file;
};
$('#set-league-pick').onclick = async () => {
  const r = await pickFile('/api/league/file/pick');
  if (r?.file) $('#set-league-file').value = r.file;
};
$('#set-gate-rangelog-pick').onclick = async () => {
  const r = await pickFile('/api/gate/rangelog/pick');
  if (r?.file) $('#set-gate-rangelog-folder').value = r.file;
};

/* Range logs of OpticScore in the registry: state line and the on/off button (applies at once) */
let ossLog = null;
function showOssState(o) {
  ossLog = o;
  const el = $('#set-oss-state');
  const btn = $('#set-oss-toggle');
  btn.disabled = !o || !o.found;
  btn.textContent = o?.on ? 'Stand-Protokoll ausschalten' : 'Stand-Protokoll einschalten';
  const restart = o?.needsRestart ? ' · OpticScore neu starten!' : '';
  el.textContent = !o ? 'Stand-Protokoll: unbekannt'
    : !o.found ? 'OpticScore auf diesem PC nicht gefunden (.reg-Datei nutzen)'
    : o.on ? `Stand-Protokoll: ein${restart}`
    : `Stand-Protokoll: aus${restart}`;
  el.className = `set-oss-state ${o?.on && !o.needsRestart ? 'ok' : o && (!o.found || o.needsRestart) ? 'bad' : ''}`;
}
$('#set-oss-toggle').onclick = async () => {
  const btn = $('#set-oss-toggle');
  btn.disabled = true;
  try {
    const r = await postJson('/api/oss/loglevel', { on: !ossLog?.on });
    showOssState(r);
    setMsg(r.error || (r.on
      ? 'Eingeschaltet. Jetzt OpticScore neu starten.'
      : 'Ausgeschaltet. Jetzt OpticScore neu starten.'), !!r.error);
  } catch (e) {
    setMsg('Das hat nicht geklappt. Läuft das Programm noch (Starten.cmd)?', true);
    btn.disabled = false;
  }
};

/* Stores branding, live data and database settings. Branding equal to the neutral defaults deletes the
   branding file instead of writing one. */
$('#set-save').onclick = async () => {
  const btn = $('#set-save');
  btn.disabled = true;
  try {
    const name = draft.name.trim();
    const colors = Object.fromEntries(BRAND_COLORS.map(c => [c.key, brandColor(draft, c.key)]));
    const allDefault = !name && draft.logo === '' && BRAND_COLORS.every(c => colors[c.key] === c.def);
    if (allDefault) {
      await postJson('/api/branding/reset', {});
    } else {
      const body = { name, colors };
      if (draft.logo !== undefined) body.logo = draft.logo;   // otherwise the server keeps the saved logo
      const saved = await postJson('/api/branding', body);
      if (saved.error) throw new Error(saved.error);
    }
    const gate = await postJson('/api/gate/config', {
      enabled: $('#set-gate-enabled').checked,
      source: $('input[name="set-gate-source"]:checked').value,
      host: $('#set-gate-host').value.trim(),
      port: $('#set-gate-port').value.trim(),
      file: $('#set-gate-file').value.trim(),
      rangeCount: Number($('#set-gate-ranges').value),
      rangeLog: $('#set-gate-rangelog').checked,
      rangeLogFolder: $('#set-gate-rangelog-folder').value.trim()
    });
    // A rejected input has no ranges; "error" alone is not enough, it can also be the live status
    if (!gate.ranges) throw new Error(gate.error);
    await postJson('/api/league/config', {
      showToday: $('#set-league-show').checked,
      file: $('#set-league-file').value.trim()
    });
    // The server has just read the database once: show its matches in the list
    refreshData();
    await loadBranding();
    closeSettings(false);
  } catch (e) {
    setMsg(e.message || 'Speichern hat nicht geklappt. Läuft das Programm noch (Starten.cmd)?', true);
  } finally {
    btn.disabled = false;
  }
};

/* =========================================================
   Reading the matches
   server.ps1 turns every match of the DISAG database into a <result> block in the XML format of the
   DISAG result exports (Build-LeagueXml), so the parser below works on that format.
   ========================================================= */
/* All <result> blocks of the server answer as comp objects. Each block is parsed on its own, so one broken
   match (odd characters in a shot from the database) cannot take the others down. */
function parseResults(text) {
  return (text.match(/<result[\s>][\s\S]*?<\/result>/gi) || []).map(parseResult);
}

/* Turns one <result> XML block into a comp object (structure: see top of file), null if it has no shots.
   Skips warm-up, invalid and placeholder shots, sorts shots by their number and works out
   per shooter the target type (lg/lp), rested or not, and whether tenths count. */
function parseResult(xml) {
  let doc = new DOMParser().parseFromString(xml, 'application/xml');
  if (doc.getElementsByTagName('parsererror').length) {
    // Not clean XML (e.g. HTML entities): parse as HTML, expanding <tag /> first
    const fixed = xml.replace(/<([a-zA-Z][\w-]*)([^<>]*?)\/>/g, '<$1$2></$1>');
    doc = new DOMParser().parseFromString(`<!doctype html><body>${fixed}</body>`, 'text/html');
  }
  const res = doc.getElementsByTagName('result')[0];
  if (!res) return null;

  const comp = {
    name: res.getAttribute('competitionsname') || 'Wettkampf',
    date: res.getAttribute('date') || '',
    time: ((res.getAttribute('printDateTime') || '').split(' ')[1] || '').slice(0, 5),
    bestX: parseInt(res.getAttribute('onlyXBestShootersPerTeam'), 10) || -1,
    // Tenths are always used for rested shooting, otherwise only if the export says so (see below)
    decimal: false,
    teams: []
  };
  const exportDecimal = res.getAttribute('showDecimalShots') === '1';

  for (const [ti, tEl] of kids(res, 'team').entries()) {
    const team = { name: (tEl.getAttribute('name') || '').trim() || `Team ${ti + 1}`, shooters: [] };
    for (const sEl of kids(tEl, 'shooter')) {
      // Reserve shooters (Ersatz, assessed="0") are left out completely
      if (/^(0|false)$/i.test((sEl.getAttribute('assessed') || '1').trim())) continue;
      const shotsEl = kids(sEl, 'shots')[0];
      if (!shotsEl) continue;
      const shots = [];
      let disk = 'lg';
      const rested = isRested(sEl.getAttribute('menu') || '', comp.name);
      kids(shotsEl, 'series')
        .sort((a, b) => num(a.getAttribute('id')) - num(b.getAttribute('id')))
        .forEach((se, si) => {
          kids(se, 'shot')
            .filter(s => s.getAttribute('iswarm') !== 'true'
              && s.getAttribute('isvalid') !== 'false'
              && (s.getAttribute('placeholder') || '').toLowerCase() !== 'true')
            .forEach((s, i) => {
              const d = (s.getAttribute('disktyp') || s.getAttribute('weaponstype') || '').toLowerCase();
              if (DISKS[d]) disk = d;
              shots.push({
                order: s.hasAttribute('shot') ? num(s.getAttribute('shot')) : si * 1000 + i,
                x: num(s.getAttribute('x')),
                y: num(s.getAttribute('y')),
                full: Math.round(num(s.getAttribute('full') ?? s.textContent)),
                dec: num(s.getAttribute('dec') || s.textContent),
                series: si,
                // Entered by hand in OpticScore (DISAG database): no real position, counted but not drawn
                nopos: s.getAttribute('nopos') === 'true'
              });
            });
        });
      if (!shots.length) continue;
      shots.sort((a, b) => a.order - b.order);
      const decimal = rested || exportDecimal;
      shots.forEach(s => { s.value = decimal ? s.dec : s.full; });
      if (decimal) comp.decimal = true;
      const name = `${sEl.getAttribute('firstname') || ''} ${sEl.getAttribute('lastname') || ''}`.trim()
        || `Schütze ${team.shooters.length + 1}`;
      // Number of shots of the discipline in OpticScore (0 = unknown), only to warn about missing shots
      const expected = Math.round(num(sEl.getAttribute('expectedShots')));
      team.shooters.push({ name, shots, disk, rested, decimal, expected });
    }
    if (team.shooters.length) comp.teams.push(team);
  }
  if (!comp.teams.length) return null;

  comp.disciplines = [...new Set(comp.teams.flatMap(t => t.shooters.map(disciplineLabel)))];
  comp.maxShots = Math.max(...comp.teams.flatMap(t => t.shooters.map(s => s.shots.length)));
  comp.finals = comp.teams.map(t => teamTotal(t, comp.maxShots, comp.bestX));
  comp.sortKey = comp.date.split('.').reverse().join('') + comp.time;
  comp.key = [comp.date, comp.name, ...comp.teams.map(t => t.name), ...comp.finals].join('|');
  return comp;
}

/* Total of a shooter after the first k shots */
const shooterTotal = (sh, k) => round1(sh.shots.slice(0, k).reduce((n, s) => n + s.value, 0));
/* Sum of shooter totals; with bestX > 0 only the best X shooters count */
const bestSum = (totals, bestX) =>
  round1((bestX > 0 ? [...totals].sort((a, b) => b - a).slice(0, bestX) : totals).reduce((n, v) => n + v, 0));
/* Number of shots of a team that count (warm-up shots are not read) */
const teamShots = team => team.shooters.reduce((n, s) => n + s.shots.length, 0);
/* Team total after the first k shots of every shooter */
const teamTotal = (team, k, bestX) => bestSum(team.shooters.map(sh => shooterTotal(sh, k)), bestX);

/* =========================================================
   Selection screen
   ========================================================= */
let competitions = [];

/* Selection screen layout: today's competitions on top, below a search field and the other (older or later)
   competitions in a fold-out section. Search text and fold-out state survive a re-read. */
let listSearch = '';
let listMoreOpen = false;

/* Today as in the match data: dd.mm.yyyy */
const todayText = () => new Date().toLocaleDateString('de-DE', { day: '2-digit', month: '2-digit', year: 'numeric' });

/* Everything the search looks at: name, date, teams, shooters, disciplines */
const searchText = c => [c.name, c.date, c.time, ...c.disciplines,
  ...c.teams.flatMap(t => [t.name, ...t.shooters.map(s => s.name)])].join(' ').toLowerCase();

/* Shooters with missing shots: [{ name, shots, expected }]. Used to warn on the card before the replay.
   expected = number of shots of the discipline in OpticScore; if that is unknown, the most shots any shooter
   of the same discipline has in this competition (then shots missing for everybody cannot be noticed). */
function shortShooters(c) {
  const all = c.teams.flatMap(t => t.shooters);
  const most = {};
  all.forEach(s => { const d = disciplineLabel(s); most[d] = Math.max(most[d] || 0, s.shots.length); });
  return all.map(s => ({ name: s.name, shots: s.shots.length, expected: s.expected || most[disciplineLabel(s)] }))
    .filter(s => s.shots < s.expected);
}

/* One competition card (deliberately without scores, so nothing is spoiled). Shows shooters and shots per
   team, so it can be checked before the replay that every shot was read. */
function compCard(c) {
  const short = shortShooters(c);
  return `<button class="comp" data-i="${competitions.indexOf(c)}">
      <span class="when">${esc(c.date)}${c.time ? ` · ${esc(c.time)} Uhr` : ''}</span>
      <span class="name">${esc(c.name)}</span>
      <span class="disc">${c.disciplines.map(d => `<span class="tag">${esc(d)}</span>`).join('')}</span>
      <span class="score">${c.teams.map(t => `
        <span>${esc(t.name)}</span>
        <span>${t.shooters.length} Schützen · ${teamShots(t)} Schuss</span>`).join('')}
      </span>
      ${short.length ? `<span class="short">⚠ Fehlende Schüsse: ${short.map(s => `${esc(s.name)} ${s.shots}/${s.expected}`).join(', ')}</span>` : ''}
    </button>`;
}

/* Cards or a notice for one group of competitions */
const compGrid = (list, emptyText) => (list.length ? `<div class="comp-grid">${list.map(compCard).join('')}</div>` : `<div class="notice">${emptyText}</div>`);

/* Draws the selection screen; called after reading and on every keystroke in the search field. The frame
   (heading, search field, fold-out) is built once and kept, so typing in the search field is not disturbed. */
function renderList() {
  const el = $('#list');
  if (league.error) {
    el.innerHTML = `<div class="notice err">Die DISAG-Datenbank konnte nicht gelesen werden: ${esc(league.error)}.
      Bitte in ⚙ Einstellungen die DISAG-Datenbank prüfen.</div>`;
    return;
  }
  if (!competitions.length) {
    el.innerHTML = '<div class="notice">In der DISAG-Datenbank ist noch kein Rundenwettkampf mit Schüssen. Nach dem Schießen auf ⟳ Wettkampf-Daten neu einlesen klicken.</div>';
    return;
  }
  const today = todayText();
  if (!$('.list-more', el)) {
    el.innerHTML = `
      <div class="list-head"><h2>Heute</h2><span class="hint">${esc(today)}</span></div>
      <div id="list-today"></div>
      <label class="list-search">
        <span aria-hidden="true">🔍</span>
        <input id="list-search" type="search" placeholder="Wettkampf suchen: Mannschaft, Schütze, Datum …" autocomplete="off">
      </label>
      <details class="list-more"><summary>Weitere Wettkämpfe <span class="hint"></span></summary><div id="list-others"></div></details>`;
    $('#list-search', el).value = listSearch;
    $('#list-search', el).addEventListener('input', e => { listSearch = e.target.value; renderList(); });
    $('.list-more', el).addEventListener('toggle', e => { if (!listSearch.trim()) listMoreOpen = e.target.open; });
  }
  const words = listSearch.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const hit = c => words.every(w => (c.search ??= searchText(c)).includes(w));
  const todays = competitions.filter(c => c.date === today && hit(c));
  const others = competitions.filter(c => c.date !== today && hit(c));
  const othersTotal = competitions.filter(c => c.date !== today).length;
  $('#list-today').innerHTML = compGrid(todays, words.length ? 'Heute passt kein Wettkampf zur Suche.' : 'Heute hat noch kein Wettkampf Schüsse. Nach dem Schießen auf ⟳ Wettkampf-Daten neu einlesen klicken.');
  $('.list-more .hint', el).textContent = words.length ? `${others.length} von ${othersTotal} passen` : `${othersTotal}, ältere und spätere, neueste zuerst`;
  $('.list-more', el).open = listMoreOpen || words.length > 0;   // searching always shows the matches
  $('#list-others').innerHTML = compGrid(others, words.length ? 'Kein weiterer Wettkampf passt zur Suche.' : 'Keine weiteren Wettkämpfe.');
  $$('.comp', el).forEach(b => { b.onclick = () => openShow(competitions[Number(b.dataset.i)]); });
}

/* ---------- Competitions from the DISAG database (only with Starten.cmd) ---------- */
/* Last answer about the DISAG database (see server.ps1): today's matches and how many matches have shots */
let league = { showToday: true, matches: [], count: 0 };
let dataBusy = false;

/* Loads every match of the last database reading with one request. They come as export XML, so they go
   through the parser for the DISAG result exports. Newest first, duplicates (same key) only once. */
async function loadCompetitions() {
  const seen = new Set();
  competitions = league.error || !league.count ? [] : parseResults(await fetch('/api/league/all', { cache: 'no-store' }).then(r => r.text()))
    .filter(c => c && !seen.has(c.key) && seen.add(c.key))
    .sort((a, b) => b.sortKey.localeCompare(a.sortKey));
  renderList();
}

/* Asks the server for the matches and shows them (guarded against parallel runs).
   withDatabase = read the DISAG database again first (only on "Neu einlesen", never on a timer). */
async function refreshData(withDatabase = false) {
  if (dataBusy) return;
  dataBusy = true;
  const btn = $('#data-reload');
  btn.disabled = true;
  try {
    if (withDatabase) $('#list').innerHTML = '<div class="notice">DISAG-Datenbank wird gelesen …</div>';
    league = await (withDatabase ? postJson('/api/league/refresh', {}) : getJson('/api/league'));
    setLeagueStatus(league);
    await loadCompetitions();
  } catch (e) {
    $('#list').innerHTML = '<div class="notice err">Die Wettkampf-Daten konnten nicht gelesen werden. Läuft das Programm noch (Starten.cmd)?</div>';
  } finally {
    dataBusy = false;
    btn.disabled = false;
  }
}

$('#data-reload').onclick = () => refreshData(true);

/* =========================================================
   TV display
   Flow: shooter 1 of team 1 in full screen, shot by shot (gap shotGap),
   a pause after each series, another pause in full screen at the end of the shooter,
   then the overview. Then shooter 1 of team 2, then shooter 2
   of team 1 and so on. After the last shooter the final result is shown.
   ========================================================= */
/* show = null on the selection and idle screen, otherwise:
     comp, frames, idx          competition, frame list, current frame index
     playing, timer, remaining, startedAt   playback state; remaining = ms left when paused
     anim, tickEnd, tickTotal   progress bar animation and its timing (also sent to the TV)
     refs, R                    DOM references of the overview cards, view radius per disk type
     single, singleKey          DOM references of the full screen view and which shooter it shows ("ti-si")
     overlay                    'start', 'final' or null
     mixed                      more than one discipline (labels at each shooter)
     finished                   final result was shown: winner marked green */
let show = null;

/* ---------- Display geometry ----------
   Like the DISAG BeamerView: real rings (0.5 mm ten dot on the air rifle target) and real 4.5 mm holes
   everywhere, so a hole touching a ring line looks exactly like the scoring.
   Full screen view: zoomed to the shots of the current series (seriesViewRadius).
   Overview cards: fixed view up to ring 5 during the replay, zoomed to all hits once a shooter is done. */
const VIEW_RING = 5;   // fixed view up to and including ring 5, reveals nothing about the worst shot
/* Overview view radius: ring 5 plus 40 % of a ring width as margin */
const viewRadius = disk => {
  const d = DISKS[disk];
  return d.ring(VIEW_RING) + (d.ring(VIEW_RING - 1) - d.ring(VIEW_RING)) * 0.4;
};

/* Once a shooter is evaluated, the target in the overview may zoom in on their hits */
function fitRadius(sh) {
  const d = DISKS[sh.disk];
  const p = overviewPellet(sh.disk);
  const far = Math.max(0, ...sh.shots.filter(s => !s.nopos).map(s => Math.hypot(s.x, s.y)));
  // outermost hit plus 10 % margin, but never tighter than ring 9 and never wider than the whole target
  return Math.min(d.ring(1) + p, Math.max(d.ring(9) + p, (far + p) * 1.1));
}

/* Full screen view, same rule as the DISAG BeamerView: the whole target before the first shot of a
   series, then zoomed to the shots of the current series so far: farthest shot + pellet radius
   + radius of ring 9 as margin. Only shots already shown count, so the zoom reveals nothing in advance. */
function seriesViewRadius(sh, count, from) {
  const d = DISKS[sh.disk];
  const shots = sh.shots.slice(from, count).filter(s => !s.nopos);
  if (!shots.length) return d.ring(1) + d.ring(9);
  const far = Math.max(...shots.map(s => Math.hypot(s.x, s.y)));
  return far + d.pellet + d.ring(9);
}

let clipSeq = 0;
/* SVG of an empty target (rings, numbers, ten dot) for view radius R.
   Hits are drawn later into the <g class="shots"> group, zooming scales <g class="zoom">. */
function targetSvg(disk, R) {
  const d = DISKS[disk];
  const ring = n => d.ring(n);
  const black = ring(d.black);
  const id = `clip${++clipSeq}`;
  const rings = [];
  const labels = [];
  for (let n = 1; n <= 10; n++) {
    const r = ring(n);
    const onBlack = r <= black;
    rings.push(`<circle r="${r}" fill="none" stroke="${onBlack ? '#e8e8e8' : '#222'}" stroke-width="1.2" vector-effect="non-scaling-stroke"/>`);
    if (n < 10) {
      const mid = (r + ring(n + 1)) / 2;
      const size = Math.min((r - ring(n + 1)) * 0.55, R * 0.11);
      if (mid < R * 0.93) {
        const col = mid <= black ? '#e8e8e8' : '#222';
        labels.push(`<text x="${-mid}" y="0" font-size="${size}" fill="${col}" text-anchor="middle" dominant-baseline="central">${n}</text>`);
        labels.push(`<text x="${mid}" y="0" font-size="${size}" fill="${col}" text-anchor="middle" dominant-baseline="central">${n}</text>`);
      }
    }
  }
  const ten = disk === 'lg' ? `<circle r="${ring(10)}" fill="#fff"/>` : '';
  const big = ring(1) * 2;   // background larger than any view so it never runs out while zooming
  return `<svg class="target" viewBox="${-R} ${-R} ${2 * R} ${2 * R}" aria-hidden="true">
    <defs><clipPath id="${id}"><circle r="${R}"/></clipPath></defs>
    <g clip-path="url(#${id})"><g class="zoom">
      <rect x="${-big}" y="${-big}" width="${2 * big}" height="${2 * big}" fill="#f2ecdc"/>
      <circle r="${black}" fill="#111"/>
      ${rings.join('')}${ten}${labels.join('')}
      <g class="shots"></g>
    </g></g>
    <circle r="${R}" fill="none" style="stroke: var(--accent)" stroke-width="3" vector-effect="non-scaling-stroke"/>
  </svg>`;
}

/* Switch a target (overview card or full screen view) to a new view, optionally as a short zoom.
   ref: { svg, shots, R } */
function setCardRadius(ref, disk, R, animate, dur = 900) {
  if (ref.R === R) return;
  const oldR = ref.R;
  const tmp = document.createElement('div');
  tmp.innerHTML = targetSvg(disk, R);
  const svg = tmp.firstElementChild;
  ref.svg.replaceWith(svg);
  ref.svg = svg;
  ref.shots = $('.shots', svg);
  ref.R = R;
  if (!animate || !oldR) return;
  const zoom = $('.zoom', svg);
  const from = R / oldR;
  const start = performance.now();
  const stepZoom = now => {
    const t = Math.min(1, (now - start) / dur);
    const e = 1 - Math.pow(1 - t, 3);
    zoom.setAttribute('transform', `scale(${from + (1 - from) * e})`);
    if (t < 1 && ref.svg === svg) requestAnimationFrame(stepZoom);
  };
  zoom.setAttribute('transform', `scale(${from})`);
  requestAnimationFrame(stepZoom);
}

/* Opacity of older shots, same scheme as the DISAG BeamerView (which fades to 0.25), but only slightly:
   the newest and the one before are fully visible,
   older ones fade towards SHOT_ALPHA_END (only in the full screen view, which shows one series) */
const SHOT_ALPHA_START = 1;
const SHOT_ALPHA_END = 0.7;

/* Overview cards show up to 40 shots on a small target. Real-size air rifle holes would merge into one
   blob there, so the overview draws them as large as pistol holes appear (real rings, small ten dot). */
const overviewPellet = disk => DISKS.lp.pellet * viewRadius(disk) / viewRadius('lp');

/* Draw hits (shot from to count) in the order they were shot: the newest is on top.
   Each hole has a grey border so overlapping holes stay apart. fade = older shots get more transparent.
   r = drawn hole radius, real size by default. */
function drawShots(g, sh, count, markNew, animate, from = 0, fade = false, r = DISKS[sh.disk].pellet) {
  const n = count - from;
  g.innerHTML = sh.shots.slice(from, count).map((s, j) => {
    const i = from + j;
    if (s.nopos) return '';      // no real position (entered by hand): only in the table and the totals
    const cx = s.x, cy = -s.y;   // y in the export points up
    const cls = `shot ${ringClass(s.full)}`;
    if (markNew && i === count - 1) {
      return `<circle class="${cls} shot-new" cx="${cx}" cy="${cy}" r="${r}" vector-effect="non-scaling-stroke"/>`
        + (animate ? `<circle class="${cls} shot-pulse" cx="${cx}" cy="${cy}" r="${r}" vector-effect="non-scaling-stroke"/>` : '');
    }
    // Same formula as the BeamerView: alpha = start - (start - end) / n * (count - (i + 2))
    const alpha = fade ? Math.max(SHOT_ALPHA_END, SHOT_ALPHA_START - (SHOT_ALPHA_START - SHOT_ALPHA_END) / n * (count - (i + 2))) : 1;
    return `<circle class="${cls}" cx="${cx}" cy="${cy}" r="${r}" vector-effect="non-scaling-stroke"${alpha < 1 ? ` opacity="${alpha.toFixed(2)}"` : ''}/>`;
  }).join('');
}

/* Series totals up to shot count, one pass over the shots (they are in shot order).
   done = every shot of that series is shown. Only series with a shown shot get an entry. */
function seriesSums(sh, count) {
  const sums = [];
  sh.shots.forEach((s, i) => {
    if (i < count) (sums[s.series] ??= { value: 0, done: true }).value += s.value;
    else if (sums[s.series]) sums[s.series].done = false;
  });
  return sums.map(x => ({ value: round1(x.value), done: x.done }));
}

/* Team total for a frame: revealed[ti][si] = shots of that shooter already shown */
const revealedTeamTotal = (comp, ti, revealed) =>
  bestSum(comp.teams[ti].shooters.map((sh, si) => shooterTotal(sh, revealed[ti][si])), comp.bestX);

/* Fixed sequence of all frames. wait: how long the frame stays ('shot', 'pause' or 'overview') */
function buildFrames(comp) {
  const order = [];
  const most = Math.max(...comp.teams.map(t => t.shooters.length));
  for (let si = 0; si < most; si++) comp.teams.forEach((t, ti) => { if (t.shooters[si]) order.push([ti, si]); });

  const revealed = comp.teams.map(t => t.shooters.map(() => 0));
  const snap = () => revealed.map(r => r.slice());
  const frames = [{ view: 'overview', focus: null, revealed: snap(), wait: null }];   // before the start
  order.forEach(([ti, si], n) => {
    const shots = comp.teams[ti].shooters[si].shots;
    const base = { focus: [ti, si], shooterNo: n + 1 };
    frames.push({ ...base, view: 'single', count: 0, revealed: snap(), wait: 'pause' });   // empty target so everyone sees who is up
    shots.forEach((s, k) => {
      revealed[ti][si] = k + 1;
      const seriesEnd = k === shots.length - 1 || shots[k + 1].series !== s.series;
      frames.push({ ...base, view: 'single', count: k + 1, revealed: snap(), wait: seriesEnd ? 'pause' : 'shot' });
    });
    frames.push({ ...base, view: 'overview', revealed: snap(), wait: 'overview' });
  });
  comp.shooterCount = order.length;
  return frames;
}

/* Starts the replay of a competition: builds the frames, the overview cards for all shooters
   and switches to the replay screen. Also used by the TV display when a new comp arrives. */
function openShow(comp) {
  stopTimer();
  const R = {};
  comp.teams.forEach(t => t.shooters.forEach(s => {
    R[s.disk] ??= viewRadius(s.disk);
  }));
  const cols = Math.max(...comp.teams.map(t => t.shooters.length));
  const mixed = comp.disciplines.length > 1;
  show = {
    comp, frames: buildFrames(comp), idx: 0, playing: false, timer: null, remaining: null, anim: null,
    R, refs: [], overlay: null, tickEnd: null, tickTotal: null, singleKey: null, mixed
  };

  $('#comp-name').textContent = comp.name;
  $('#comp-date').textContent = comp.date + (comp.time ? ` · ${comp.time} Uhr` : '') + (mixed ? '' : ` · ${comp.disciplines[0]}`);
  syncTimerInputs();

  $('#rows').innerHTML = comp.teams.map((t, ti) => `
    <section class="team-row" data-t="${ti}">
      <div class="team-head">
        <div class="team-name">${esc(t.name)}</div>
        <div class="team-total">0</div>
        <div class="team-sub">${t.shooters.length} Schützen${comp.bestX > 0 ? `, beste ${comp.bestX} zählen` : ''}
          · <span class="team-shots">0</span> / ${teamShots(t)} Schuss</div>
        <div class="lead-badge">führt</div>
      </div>
      <div class="cards" style="--cols:${cols}">
        ${t.shooters.map(s => `<div class="card">
          <div class="shooter-name">${esc(s.name)}${mixed ? ` <span class="tag">${esc(disciplineLabel(s))}</span>` : ''}</div>
          ${targetSvg(s.disk, R[s.disk])}
          <div class="stats"><span class="last"></span><span class="sum"><small>Ges.</small><b>0</b></span></div>
          <div class="series"></div>
        </div>`).join('')}
      </div>
    </section>`).join('');

  show.refs = comp.teams.map((t, ti) => {
    const row = $(`.team-row[data-t="${ti}"]`);
    return {
      row,
      total: $('.team-total', row),
      shots: $('.team-shots', row),
      cards: $$('.card', row).map((c, si) => ({
        card: c, svg: $('.target', c), R: R[t.shooters[si].disk],
        shots: $('.shots', c), last: $('.last', c), sum: $('.sum b', c), series: $('.series', c)
      }))
    };
  });

  $('#screen-select').hidden = true;
  $('#screen-idle').hidden = true;
  $('#screen-show').hidden = false;
  render(false);
  if (!DISPLAY) showStartOverlay();
}

/* Build the full screen view of a shooter (only when the shooter changes) */
function buildSingle(ti, si) {
  const { comp } = show;
  const team = comp.teams[ti];
  const sh = team.shooters[si];
  // Shots per series (series are numbered 0.. in shot order); the table has one row per series
  const perSeries = [];
  sh.shots.forEach(s => { perSeries[s.series] = (perSeries[s.series] || 0) + 1; });
  const widest = Math.max(...perSeries);
  $('#single').innerHTML = `
    <div class="single-target">${targetSvg(sh.disk, seriesViewRadius(sh, 0, 0))}</div>
    <div class="single-info">
      <div class="single-team">${esc(team.name)}</div>
      <div class="single-name">${esc(sh.name)}</div>
      <div class="single-disc"><span class="tag">${esc(disciplineLabel(sh))}</span></div>
      <div class="single-stats">
        <div class="single-last"></div>
        <div class="single-sum"><small>Gesamt</small><b>0</b></div>
      </div>
      <div class="single-grid" style="--per:${widest}">
        ${perSeries.map((n, i) => `<div class="sg-row" data-s="${i}">
          <span class="sg-label">S${i + 1}</span>
          ${'<span class="sg-cell"></span>'.repeat(n)}${'<span class="sg-cell sg-empty"></span>'.repeat(widest - n)}
          <span class="sg-sum"></span>
        </div>`).join('')}
      </div>
      <div class="single-score">${comp.teams.map((t, i) => `
        <div class="ss-team${i === ti ? ' active' : ''}"><span class="ss-name">${esc(t.name)}</span><b class="ss-total">0</b></div>`).join('')}
      </div>
    </div>`;
  show.single = {
    sh,
    svg: $('#single .target'),
    R: seriesViewRadius(sh, 0, 0),
    shots: $('#single .shots'),
    last: $('#single .single-last'),
    sum: $('#single .single-sum b'),
    rows: $$('#single .sg-row').map(r => ({ cells: $$('.sg-cell:not(.sg-empty)', r), sum: $('.sg-sum', r) })),
    totals: $$('#single .ss-total')
  };
}

/* Draws the current frame (show.idx): either the full screen view of one shooter or the
   overview of all shooters. animate = play the pop/pulse of a new shot and the zoom. */
function render(animate = true) {
  const { comp, frames, idx } = show;
  const f = frames[idx];
  $('#prog').style.width = `${(idx / (frames.length - 1)) * 100}%`;

  const totals = comp.teams.map((t, ti) => revealedTeamTotal(comp, ti, f.revealed));
  const best = Math.max(...totals);
  const leading = ti => idx > 0 && totals.filter(v => v === best).length === 1 && totals[ti] === best;
  // After the final result the leading team is marked green (winner) until stepping back
  if (idx !== frames.length - 1) show.finished = false;
  const won = ti => show.finished && leading(ti);

  if (f.view === 'single') {
    const [ti, si] = f.focus;
    const key = `${ti}-${si}`;
    if (show.singleKey !== key) { buildSingle(ti, si); show.singleKey = key; }
    const s = show.single;
    const k = f.count;
    $('#counter-label').textContent = 'Schuss';
    $('#cur').textContent = k;
    $('#max').textContent = s.sh.shots.length;

    // Only the current series on the target, the table on the right keeps all shots
    const cur = s.sh.shots[k - 1];
    const seriesStart = cur ? s.sh.shots.findIndex(x => x.series === cur.series) : 0;
    // Zoom like DISAG (short, so it keeps up with a 0.5 s shot gap), older shots of the series fade
    setCardRadius(s, s.sh.disk, seriesViewRadius(s.sh, k, seriesStart), animate, 350);
    drawShots(s.shots, s.sh, k, k > 0, animate, seriesStart, true);
    s.last.className = 'single-last';
    s.last.textContent = cur ? fmtScore(cur.value, s.sh.decimal) : '';
    if (cur) {
      s.last.classList.add(ringClass(cur.full));
      if (animate) { void s.last.offsetWidth; s.last.classList.add('flash'); }
    }
    s.sum.textContent = fmtScore(shooterTotal(s.sh, k), s.sh.decimal);

    // Shot table: series by series, value in hit color
    let n = 0;
    const sums = seriesSums(s.sh, k);
    s.rows.forEach((row, ri) => {
      row.cells.forEach(cell => {
        const shot = s.sh.shots[n];
        const shown = n < k;
        cell.textContent = shown ? fmtScore(shot.value, s.sh.decimal) : '';
        cell.className = `sg-cell${shown ? ` ${ringClass(shot.full)}` : ''}${shown && n === k - 1 ? ' cur' : ''}`;
        n++;
      });
      row.sum.textContent = sums[ri] ? fmtScore(sums[ri].value, s.sh.decimal) : '';
      row.sum.classList.toggle('done', !!sums[ri]?.done);
    });
    s.totals.forEach((el, i) => {
      el.textContent = fmtScore(totals[i], comp.decimal);
      el.parentElement.classList.toggle('leading', leading(i));
    });

    $('#rows').hidden = true;
    $('#single').hidden = false;
  } else {
    $('#counter-label').textContent = 'Schütze';
    $('#cur').textContent = f.shooterNo || 0;
    $('#max').textContent = comp.shooterCount;

    comp.teams.forEach((team, ti) => {
      team.shooters.forEach((sh, si) => {
        const ref = show.refs[ti].cards[si];
        const k = f.revealed[ti][si];
        // Fully evaluated shooters: zoom the target on their hits, otherwise fixed view up to ring 5
        const done = k > 0 && k === sh.shots.length;
        setCardRadius(ref, sh.disk, done ? fitRadius(sh) : show.R[sh.disk], animate);
        drawShots(ref.shots, sh, k, false, false, 0, false, overviewPellet(sh.disk));
        ref.last.className = 'last';
        // How many of this shooter's shots are revealed, e.g. 40/40
        ref.last.textContent = k === 0 ? '' : `${k}/${sh.shots.length}`;
        ref.last.classList.add('count');
        ref.sum.textContent = fmtScore(shooterTotal(sh, k), sh.decimal);
        ref.series.innerHTML = seriesSums(sh, k)
          .map(x => `<span class="${x.done ? 'done' : ''}">${fmtScore(x.value, sh.decimal)}</span>`).join(' · ');
        // No shooter is highlighted after the final result
        ref.card.classList.toggle('focus', !show.finished && !!f.focus && f.focus[0] === ti && f.focus[1] === si);
      });
      show.refs[ti].total.textContent = fmtScore(totals[ti], comp.decimal);
      // Shots shown so far of this team, out of all its shots ("87 / 160 Schuss")
      show.refs[ti].shots.textContent = f.revealed[ti].reduce((n, k) => n + k, 0);
      show.refs[ti].row.classList.toggle('leading', leading(ti) && !won(ti));
      show.refs[ti].row.classList.toggle('won', won(ti));
    });

    $('#single').hidden = true;
    $('#rows').hidden = false;
  }

  $('#b-play').textContent = show.playing ? '❚❚' : '▶';
  publishSoon();
}

/* ---------- Playback ---------- */
/* The three timers: label and hint for the start overlay, allowed range and rounding for the input fields */
const TIMERS = {
  shotGap: { label: 'Schuss', hint: 'Abstand zwischen den Schüssen einer Serie', min: 0.1, max: 10, step: 0.1 },
  pause: { label: 'Pause', hint: 'vor dem ersten Schuss, nach jeder Serie und am Ende eines Schützen', min: 1, max: 300, step: 1 },
  overview: { label: 'Übersicht', hint: 'Dauer der Übersicht mit allen Schützen', min: 1, max: 300, step: 1 }
};
/* A timer value kept inside its range and rounded to its step; the default for anything that is not a number */
function timerValue(key, v) {
  const t = TIMERS[key];
  const n = num(v) > 0 ? num(v) : DEFAULTS[key];
  return Number((Math.round(Math.min(t.max, Math.max(t.min, n)) / t.step) * t.step).toFixed(1));
}
/* How long a frame stays, from its wait type ('shot', 'overview' or 'pause') and the timer settings */
const waitMs = f => timerValue(f.wait === 'shot' ? 'shotGap' : f.wait, settings[f.wait === 'shot' ? 'shotGap' : f.wait]) * 1000;

/* Waits ms before the next frame and starts the progress bar (total = full length of the wait) */
function schedule(ms, total = ms) {
  clearTimeout(show.timer);
  show.remaining = ms;
  show.startedAt = performance.now();
  show.timer = setTimeout(onTick, ms);
  show.tickTotal = total;
  show.tickEnd = Date.now() + ms;
  applyTick({ end: show.tickEnd, total: show.tickTotal });
  publishSoon();
}

/* Progress bar to the next frame: running ({end}) or paused ({pausedAt}) */
function applyTick(t) {
  if (show.anim) { show.anim.cancel(); show.anim = null; }
  if (!t) return;
  show.anim = $('#tick').animate([{ transform: 'scaleX(0)' }, { transform: 'scaleX(1)' }], { duration: t.total, fill: 'forwards' });
  if (t.end) {
    show.anim.currentTime = Math.min(t.total, Math.max(0, t.total - (t.end - Date.now())));
  } else {
    show.anim.currentTime = t.pausedAt;
    show.anim.pause();
  }
}

/* Stops the pending frame change and the progress bar */
function stopTimer() {
  if (!show) return;
  clearTimeout(show.timer);
  show.timer = null;
  show.tickEnd = null;
  show.tickTotal = null;
  applyTick(null);
}

const lastIdx = () => show.frames.length - 1;

/* Timer fired: show the next frame. The last frame (overview after the last shooter) is not waited for:
   the final result appears right away, with the overview behind it. */
function onTick() {
  if (show.idx < lastIdx()) {
    show.idx++;
    render(true);
    if (show.idx < lastIdx()) {
      schedule(waitMs(show.frames[show.idx]));
      return;
    }
  }
  show.playing = false;
  stopTimer();
  render(false);
  renderFinalOverlay();
}

/* Start or resume playback; from the end it starts over */
function play() {
  if (!show) return;
  hideOverlay();
  if (show.idx >= lastIdx()) show.idx = 0;
  show.playing = true;
  if (show.idx === 0) onTick();
  else schedule(show.remaining ?? waitMs(show.frames[show.idx]), show.tickTotal ?? waitMs(show.frames[show.idx]));
  render(false);
}

/* Pause and remember the remaining wait time */
function pause() {
  if (!show || !show.playing) return;
  show.playing = false;
  clearTimeout(show.timer);
  show.remaining = Math.max(0, show.remaining - (performance.now() - show.startedAt));
  show.tickEnd = null;
  if (show.anim) show.anim.pause();
  render(false);
}

const togglePlay = () => (show.playing ? pause() : play());

/* Jump to frame i (arrow keys, buttons). Stepping beyond the end shows the final result. */
function stepTo(i) {
  const prev = show.idx;
  pause();
  stopTimer();
  show.remaining = null;
  show.idx = Math.max(0, Math.min(i, lastIdx()));
  hideOverlay();
  render(show.idx === prev + 1);
  if (i > lastIdx()) renderFinalOverlay();
}

/* Jump to the start of the previous or next shooter */
const isShooterStart = f => f.view === 'single' && f.count === 0;
function stepShooter(dir) {
  const fr = show.frames;
  let i = show.idx;
  if (dir > 0) {
    do i++; while (i < fr.length && !isShooterStart(fr[i]));
  } else {
    do i--; while (i > 0 && !isShooterStart(fr[i]));
  }
  stepTo(i);
}

/* Back to the first frame and play */
function restart() {
  stopTimer();
  show.playing = false;
  show.idx = 0;
  show.remaining = null;
  render(false);
  play();
}

/* ---------- Start and final overlay ---------- */
function hideOverlay() {
  $('#overlay').hidden = true;
  if (show) show.overlay = null;
  publishSoon();
}

/* Start overlay with competition, timer settings and the start button */
function showStartOverlay() {
  const c = show.comp;
  $('#overlay').innerHTML = `<div class="ov-box">
    <img class="ov-logo club-logo" src="${logoUrl()}" alt="">
    <h2>${esc(c.name)}</h2>
    <div class="ov-sub">${esc(c.date)} · ${c.teams.map(t => esc(t.name)).join(' gegen ')}</div>
    <div class="ov-settings">${Object.entries(TIMERS).map(([key, t]) => `
      <label title="${esc(t.hint)}">
        <span class="ov-set-label">${esc(t.label)}</span>
        <span class="ov-set-input"><input data-timer="${key}" type="number" min="${t.min}" max="${t.max}" step="${t.step}" value="${settings[key]}"> s</span>
        <small>${esc(t.hint)}</small>
      </label>`).join('')}
    </div>
    <button class="ov-btn" id="ov-start">▶ Auswertung starten</button>
    <div class="ov-hint">Leertaste: Start/Pause · ← →: Schritt zurück/vor · ↑ ↓: Schütze zurück/vor · Pos1: von vorn · F: Vollbild</div>
    <div class="ov-wait">Gleich geht's los …</div>
  </div>`;
  $('#overlay').hidden = false;
  show.overlay = 'start';
  $('#ov-start').onclick = play;
  if (!DISPLAY) $('#ov-start').focus();
  publishSoon();
}

/* Final result: winner, score, best shooter. Also marks the comp as finished (green winner). */
function renderFinalOverlay() {
  const c = show.comp;
  const finals = c.finals;
  const best = Math.max(...finals);
  const winners = finals.filter(v => v === best).length;
  const order = finals.map((v, i) => i).sort((a, b) => finals[b] - finals[a]);
  const topShooter = c.teams
    .flatMap(t => t.shooters
      .map(s => ({ name: s.name, team: t.name, decimal: s.decimal, total: shooterTotal(s, c.maxShots) })))
    .sort((a, b) => b.total - a.total)[0];

  $('#overlay').innerHTML = `<div class="ov-box">
    <img class="ov-logo club-logo" src="${logoUrl()}" alt="">
    <h2>${winners === 1 ? `🏆 ${esc(c.teams[order[0]].name)} gewinnt` : 'Unentschieden'}</h2>
    <div class="ov-score">${order.map(i => `<span class="${winners === 1 && i === order[0] ? 'win' : ''}">${fmtScore(finals[i], c.decimal)}</span>`).join(' : ')}</div>
    <div class="ov-line">${order.map(i => esc(c.teams[i].name)).join(' : ')}</div>
    <div class="ov-line ov-shots">${order.map(i => `${teamShots(c.teams[i])} Schuss`).join(' : ')}</div>
    ${topShooter ? `<div class="ov-line">Bester Schütze: <b>${esc(topShooter.name)}</b> (${fmtScore(topShooter.total, topShooter.decimal)}, ${esc(topShooter.team)})</div>` : ''}
    <button class="ov-btn" id="ov-close">Scheiben ansehen</button>
    <button class="ov-btn secondary" id="ov-again">Nochmal abspielen</button>
  </div>`;
  $('#overlay').hidden = false;
  show.overlay = 'final';
  show.finished = true;
  render(false);
  $('#ov-close').onclick = hideOverlay;
  $('#ov-again').onclick = restart;
  publishSoon();
}

/* ---------- Controls ---------- */
$('#b-play').onclick = () => togglePlay();
$('#b-next').onclick = () => stepTo(show.idx + 1);
$('#b-prev').onclick = () => stepTo(show.idx - 1);
$('#b-next-shooter').onclick = () => stepShooter(1);
$('#b-prev-shooter').onclick = () => stepShooter(-1);
$('#b-restart').onclick = () => restart();
$('#b-full').onclick = () => toggleFullscreen();
$('#b-back').onclick = () => {
  pause();
  stopTimer();
  if (document.fullscreenElement) document.exitFullscreen();
  hideOverlay();
  show = null;
  $('#screen-show').hidden = true;
  $('#screen-select').hidden = false;
  publishSoon();
  if (LINKED) renderList();   // the list only changes with "Neu einlesen" or "Speichern"
};
/* Timer settings exist in the bar and in the start overlay. All fields with data-timer
   are bound to the same setting and always show the same value. */
function setTimer(key, value) {
  settings[key] = timerValue(key, value);
  saveSettings();
  syncTimerInputs();
}
/* Shows the stored values in all timer fields */
function syncTimerInputs() {
  $$('input[data-timer]').forEach(inp => { inp.value = settings[inp.dataset.timer]; });
}
document.addEventListener('change', e => {
  if (e.target.matches('input[data-timer]')) setTimer(e.target.dataset.timer, e.target.value);
});

/* Browser full screen on/off (key F) */
function toggleFullscreen() {
  if (document.fullscreenElement) document.exitFullscreen();
  else document.documentElement.requestFullscreen().catch(() => {});
}

document.addEventListener('keydown', e => {
  if (DISPLAY) {
    if (e.key === 'f' || e.key === 'F') toggleFullscreen();
    // Edge kiosk mode swallows Esc: ask the server to reopen the display as a window
    else if (e.key === 'Escape' && !DISPLAY_WINDOWED && LINKED_DISPLAY) postJson('/api/display/window', {}).catch(() => {});
    return;
  }
  if (!show || $('#screen-show').hidden || e.target.matches('input')) return;
  if (e.key === ' ') { e.preventDefault(); togglePlay(); }
  else if (e.key === 'ArrowRight') stepTo(show.idx + 1);
  else if (e.key === 'ArrowLeft') stepTo(show.idx - 1);
  else if (e.key === 'ArrowDown' || e.key === 'PageDown') { e.preventDefault(); stepShooter(1); }
  else if (e.key === 'ArrowUp' || e.key === 'PageUp') { e.preventDefault(); stepShooter(-1); }
  else if (e.key === 'Home') restart();
  else if (e.key === 'f' || e.key === 'F') toggleFullscreen();
});

/* Hide the control bar and mouse cursor when the mouse rests for 3 seconds */
let idleTimer = null;
/* Mouse or key activity: show the bar again and restart the 3 second idle timer */
function wake() {
  document.body.classList.remove('idle');
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => { if (show && show.playing) document.body.classList.add('idle'); }, 3000);
}
['mousemove', 'mousedown', 'keydown'].forEach(ev => document.addEventListener(ev, wake));

/* =========================================================
   Two screens: control page (index.html) and TV display (index.html?display)
   Active when the page was opened via Starten.cmd (server.ps1).
   The control page posts its state to the server, the TV display polls it.
   ========================================================= */
let LINKED = false;
let pubTimer = null;
let pubCount = 0;
let sentCompKey = null;
let pubChain = Promise.resolve();

/* Small JSON helpers for the server API */
const postJson = (url, body) => fetch(url, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body)
}).then(r => r.json());
const getJson = url => fetch(url, { cache: 'no-store' }).then(r => r.json());
const sleep = ms => new Promise(r => setTimeout(r, ms));

/* Several changes in the same moment are merged into one update */
function publishSoon() {
  if (!LINKED || DISPLAY || pubTimer) return;
  pubTimer = setTimeout(() => {
    pubTimer = null;
    pubChain = pubChain.then(publishNow).catch(() => setTvStatus(-2));
  }, 0);
}

/* Sends the current state to the server: the comp itself only when it changed,
   then frame index, playing flag, overlay and progress bar timing. */
async function publishNow() {
  const st = { rev: `${Date.now()}-${++pubCount}`, compKey: null };
  if (show) {
    if (show.comp.key !== sentCompKey) {
      await postJson('/api/comp', show.comp);
      sentCompKey = show.comp.key;
    }
    Object.assign(st, {
      compKey: show.comp.key,
      idx: show.idx,
      playing: show.playing,
      overlay: show.overlay,
      tick: show.playing && show.tickEnd
        ? { end: show.tickEnd, total: show.tickTotal }
        : (show.tickTotal && show.remaining != null
          ? { pausedAt: Math.max(0, show.tickTotal - show.remaining), total: show.tickTotal }
          : null)
    });
  }
  const r = await postJson('/api/state', st);
  setTvStatus(r.displayAge);
}

/* age: ms since the TV display last polled, -1 = never, -2 = server gone */
function setTvStatus(age) {
  const ok = age >= 0 && age < 3000;
  const text = age === -2 ? '📺 Keine Verbindung zum Server, bitte Starten.cmd neu ausführen'
    : ok ? '📺 TV-Anzeige verbunden'
    : age === -1 ? '📺 TV-Anzeige noch nicht verbunden'
    : '📺 TV-Anzeige antwortet nicht';
  const s = $('#tv-status');
  s.textContent = text;
  s.className = `tv-status ${ok ? 'ok' : 'bad'}`;
  const b = $('#tv-badge');
  b.hidden = false;
  b.className = `tv-badge ${ok ? 'ok' : 'bad'}`;
  b.title = text;
}

/* ---------- Control page: DISAG JSON Live status ---------- */
/* Status line of the Gate connection on the control page */
function setGateStatus(g) {
  const el = $('#gate-status');
  el.hidden = !g.enabled;
  if (!g.enabled) return;
  const busy = g.ranges.filter(r => r.firstname || r.lastname).length;
  const useFile = g.source === 'file';
  // Broadcasts from another PC only: most likely the wrong server is set, so say where the data comes from
  const wrongServer = !useFile && g.connected && g.lastDataAge < 0 && g.ignoredFrom;
  const starting = useFile ? `Logdatei ${g.file} wird gesucht …` : `UDP-Port ${g.port} wird geöffnet …`;
  el.textContent = !g.connected ? `🎯 DISAG JSON Live: ${g.error || starting}`
    : wrongServer ? `🎯 DISAG JSON Live: keine Daten von ${g.host}, aber von ${g.ignoredFrom}. Server in ⚙ Einstellungen prüfen`
    : !useFile && g.lastDataAge < 0 ? `🎯 DISAG JSON Live: wartet auf Daten von ${g.host}:${g.port}`
    : `🎯 DISAG JSON Live: ${busy} von ${g.rangeCount} Ständen ${useFile ? 'heute ' : ''}belegt`;
  // Range logs of OpticScore (assignment before the first shot): say what is still missing
  const rl = g.rangeLog || {};
  const rangeLogProblem = !rl.on ? ''
    : rl.error ? `Stand-Protokoll: ${rl.error}`
    : rl.oss.found && !rl.oss.on ? 'Stand-Protokoll aus: in ⚙ Einstellungen einschalten'
    : rl.oss.needsRestart ? 'Stand-Protokoll: OpticScore neu starten'
    : '';
  if (rl.on) el.textContent += rangeLogProblem ? ` · ${rangeLogProblem}` : ' · Zuweisungen live';
  el.className = `gate-status ${g.connected && !wrongServer && !rangeLogProblem ? 'ok' : 'bad'}`;
}

/* ---------- Idle screen: who is shooting at which range (DISAG JSON Live) ---------- */
let rangesKey = null;           // what is currently drawn, to redraw only on changes
let lastRangeNames = {};        // range -> name, to highlight newly logged-in shooters

/* ---------- Today's Rundenwettkaempfe (DISAG database) ---------- */
/* Control page: one status line, e.g. "📅 Heute 20:00 Uhr: Team A gegen Team B" */
function setLeagueStatus(l) {
  const el = $('#league-status');
  el.hidden = false;
  // The database is only read at the start and on "⟳ Wettkampf-Daten neu einlesen", so the line also says when
  const list = l.matches.map(m => `${m.time} Uhr: ${m.team1 && m.team2 ? `${m.team1} gegen ${m.team2}` : m.name}`).join(' · ');
  const when = l.readAt ? ` (eingelesen ${l.readAt} Uhr)` : '';
  el.textContent = l.error ? `📅 DISAG-Datenbank: ${l.error}`
    : !l.readAt ? '📅 DISAG-Datenbank noch nicht eingelesen: ⟳ Wettkampf-Daten neu einlesen klicken'
    : l.matches.length ? `📅 Heute ${list}${when}` : `📅 Heute kein Rundenwettkampf in der DISAG-Datenbank${when}`;
  el.className = `gate-status ${l.error ? 'bad' : 'ok'}`;
}

/* TV idle screen: one card per match of today (never a result), up to 4 side by side, the two teams
   below each other. Hidden when switched off or no match today. */
let leagueKey = null;
function renderLeague(l) {
  const box = $('#idle-league');
  const matches = l && l.showToday && !l.error ? l.matches : [];
  box.hidden = !matches.length;
  $('#screen-idle').classList.toggle('with-league', matches.length > 0);
  $('#screen-idle').classList.toggle('league-many', matches.length > 4);
  const key = JSON.stringify(matches);
  if (key === leagueKey) return;
  leagueKey = key;
  box.style.setProperty('--league-cols', Math.min(4, Math.max(1, matches.length)));
  // One heading "Heute" above all cards, the cards themselves only show the teams (and discipline)
  box.innerHTML = '<h2 class="league-head">Heute</h2>' + matches.map(m => {
    const teams = m.team1 && m.team2
      ? `<b>${esc(m.team1)}</b><i>gegen</i><b>${esc(m.team2)}</b>`
      : `<b>${esc(m.name)}</b>`;
    const disc = [m.discipline, m.shots ? `${m.shots} Schuss` : ''].filter(Boolean).join(' · ');
    return `<div class="league-match">
      <span class="league-teams">${teams}</span>
      ${disc ? `<span class="league-disc">${esc(disc)}</span>` : ''}
    </div>`;
  }).join('');
}

/* Draws one tile per range on the TV idle screen: shooter name or "frei", plus shot progress.
   info = answer of /api/gate; hidden when the Gate is switched off. Redraws only when something changed. */
function renderRanges(info) {
  const box = $('#idle-ranges');
  const hint = $('#idle-gate');
  const on = !!info && info.enabled;
  box.hidden = !on;
  $('#screen-idle').classList.toggle('with-ranges', on);
  if (!on) { hint.hidden = true; rangesKey = null; return; }

  hint.hidden = info.connected;
  hint.textContent = 'Keine Live-Daten von der Schießanlage (DISAG JSON Live), neuer Versuch läuft …';

  const key = JSON.stringify([info.connected, info.ranges]);
  if (key === rangesKey) return;
  rangesKey = key;

  const n = info.ranges.length;
  box.style.setProperty('--range-cols', n <= 5 ? n : n <= 10 ? 5 : n <= 12 ? 6 : Math.min(8, Math.ceil(n / 2)));
  box.innerHTML = info.ranges.map(r => {
    const name = `${r.firstname} ${r.lastname}`.trim();
    const isNew = !!name && lastRangeNames[r.range] !== undefined && lastRangeNames[r.range] !== name;
    lastRangeNames[r.range] = name;
    const cls = ['range-tile', name ? '' : 'free', info.connected ? '' : 'unknown', isNew ? 'new' : ''].join(' ');
    // Shot progress: "Probe · 3 Schuss" while sighting runs, otherwise "Schuss 12 / 40" with a bar.
    // Without a total from the Gate (shotsTotal 0) only "Schuss 12", no bar.
    const pct = r.shotsTotal ? Math.min(100, Math.round((r.shots / r.shotsTotal) * 100)) : 0;
    // From the range logs: "fertig" at the end of the match, "zugewiesen" before the first shot
    const progress = r.finished
      ? '<span class="range-shots done">fertig</span>'
      : !r.sighting && !r.shots && !r.probeShots
      ? '<span class="range-shots">zugewiesen</span>'
      : r.sighting
      ? `<span class="range-shots probe">Probe · ${r.probeShots} Schuss</span>`
      : r.shotsTotal
        ? `<span class="range-shots${r.shots >= r.shotsTotal ? ' done' : ''}">Schuss <b>${r.shots}</b> / ${r.shotsTotal}</span>
           <span class="range-bar"><i style="width:${pct}%"></i></span>`
        : `<span class="range-shots">Schuss <b>${r.shots}</b></span>`;
    return `<div class="${cls}">
      <span class="range-no">Stand ${r.range}</span>
      ${name
        ? `<span class="range-first">${esc(r.firstname)}</span><span class="range-last">${esc(r.lastname)}</span>${progress}`
        : '<span class="range-last">frei</span>'}
    </div>`;
  }).join('');
}

/* ---------- TV page: fetch the state and mirror it ---------- */
/* Endless loop of the TV display: polls the state every 100 ms and applies it when its rev changed,
   the Gate ranges every second and the branding every 3 seconds. */
async function displayLoop() {
  let rev = null;
  let tick = 0;
  for (;;) {
    // Roughly every 3 seconds check whether name, logo or colors changed
    if (tick % 30 === 0) {
      getJson('/api/branding').then(b => { if (b.rev !== branding.rev) { branding = b; applyBranding(b); } }).catch(() => {});
    }
    // Every second: logged-in shooters for the idle screen
    if (tick % 10 === 0) {
      getJson('/api/gate').then(renderRanges).catch(() => {});
    }
    // Every 10 seconds: today's Rundenwettkaempfe (the server reads the database at most once a minute)
    if (tick % 100 === 0) {
      getJson('/api/league').then(renderLeague).catch(() => {});
    }
    tick++;
    try {
      const st = await getJson('/api/state?display=1');
      if (st.rev !== rev) {
        await applyState(st);
        rev = st.rev;
      }
      $('#idle-wait').textContent = "Gleich geht's los …";
    } catch (e) {
      $('#idle-wait').textContent = 'Keine Verbindung zum Steuer-PC …';
    }
    await sleep(100);   // short enough that no shot is missed even at a 0.5 s shot gap
  }
}

/* TV display: apply a state published by the control page (comp, frame, overlay, progress bar) */
async function applyState(st) {
  if (!st.compKey) {
    if (show) { stopTimer(); show = null; }
    $('#overlay').hidden = true;
    $('#screen-show').hidden = true;
    $('#screen-idle').hidden = false;
    return;
  }
  if (!show || show.comp.key !== st.compKey) {
    const comp = await getJson('/api/comp');
    if (!comp || comp.key !== st.compKey) throw new Error('Wettkampf noch nicht übertragen');
    openShow(comp);
  }
  const prev = show.idx;
  show.idx = Math.max(0, Math.min(st.idx ?? 0, show.frames.length - 1));
  show.playing = st.playing;
  if (show.idx !== prev) render(show.idx === prev + 1);
  applyTick(st.tick);
  if (st.overlay !== show.overlay) {
    if (st.overlay === 'start') showStartOverlay();
    else if (st.overlay === 'final') renderFinalOverlay();
    else hideOverlay();
  }
}

/* ---------- Choosing the screen for the TV display ---------- */
const screenLabel = s => `${s.number}: ${s.name || 'Bildschirm'} · ${s.width}×${s.height}`
  + (s.primary ? ' · Hauptbildschirm' : '');

/* Fills the screen list from the server, keeping the current or remembered choice */
async function loadScreens() {
  const sel = $('#tv-screen');
  try {
    const info = await getJson('/api/screens');
    const screens = [].concat(info.screens || []);
    const current = sel.value || info.selected;
    const fallback = (screens.find(s => !s.primary) || screens[0] || {}).id;
    sel.innerHTML = screens.map(s => `<option value="${esc(s.id)}">${esc(screenLabel(s))}</option>`).join('');
    sel.value = screens.some(s => s.id === current) ? current : fallback;
    sel.title = screens.length < 2
      ? 'Nur ein Bildschirm angeschlossen: die Anzeige öffnet sich als normales Fenster'
      : 'Auf welchem Bildschirm die Anzeige im Vollbild laufen soll';
  } catch (e) { /* server not reachable, the status already shows that */ }
}

/* ---------- Start ---------- */
/* Entry point: TV display starts its polling loop; the control page checks whether it runs
   behind the server (Starten.cmd) and then enables the competitions, TV and settings features. */
async function init() {
  $$('.app-version').forEach(el => { el.textContent = APP_VERSION; });
  applyBranding(branding);   // neutral defaults until the stored branding has arrived
  if (DISPLAY) {
    document.body.classList.add('display');
    $('#screen-select').hidden = true;
    $('#screen-idle').hidden = false;
    displayLoop();
    return;
  }
  // The competitions come from the DISAG database through server.ps1: without it there is nothing to show
  if (SERVED) { try { LINKED = !!(await getJson('/api/ping')).ok; } catch (e) { LINKED = false; } }
  if (!LINKED) {
    $('#list').innerHTML = `<div class="notice err">Das Programm läuft nicht. Bitte im Programmordner doppelt auf
      <b>Starten.cmd</b> klicken, dann öffnet sich diese Seite von selbst.</div>`;
    return;
  }

  $('#tv-panel').hidden = false;
  $('#data-panel').hidden = false;
  $('#settings-open').hidden = false;
  loadBranding();
  publishSoon();
  refreshData();
  setInterval(async () => {
    try { setTvStatus((await getJson('/api/status')).displayAge); } catch (e) { setTvStatus(-2); }
    try { setGateStatus(await getJson('/api/gate')); } catch (e) { /* server status line already shows that */ }
    // The database line only changes when "Wettkampf-Daten neu einlesen" or "Speichern" is clicked,
    // refreshData() updates it then; no need to ask every 2 seconds
  }, 2000);
  loadScreens();
  window.addEventListener('focus', loadScreens);   // newly connected screens show up when returning to the window
  $('#tv-identify').onclick = () => postJson('/api/screens/identify', {}).then(loadScreens).catch(() => setTvStatus(-2));
  $('#tv-open').onclick = () => postJson('/api/display/open', { screen: $('#tv-screen').value }).catch(() => setTvStatus(-2));
  $('#tv-quit').onclick = async () => {
    if (!confirm('Auswertung beenden? Die TV-Anzeige wird ebenfalls geschlossen.')) return;
    try { await postJson('/api/quit', {}); } catch (e) { /* server is already gone */ }
    document.body.innerHTML = '<div class="select-wrap"><h1>Beendet</h1><p class="sub">Dieses Fenster kann jetzt geschlossen werden.</p></div>';
  };
}
init();
