'use strict';

const TOKEN_KEY = 'reeltunes_admin_token';
const POLL_MS = 15000;

const state = {
  token: localStorage.getItem(TOKEN_KEY) || '',
  codes: [],
  redemptions: [],
  stats: null,
  query: '',
  filter: '',
  timer: null,
  editingCode: null,
};

const $ = (id) => document.getElementById(id);

function esc(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function milestoneBadge(uses) {
  if (uses >= 100) return '<span class="milestone">100+</span>';
  if (uses >= 50) return '<span class="milestone">50</span>';
  if (uses >= 25) return '<span class="milestone">25</span>';
  return '';
}

async function api(path, options = {}) {
  const headers = { Authorization: `Bearer ${state.token}` };
  if (options.body !== undefined) headers['Content-Type'] = 'application/json';
  const res = await fetch(path, {
    method: options.method || 'GET',
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
  });
  let data = {};
  try {
    data = await res.json();
  } catch {
    data = { ok: false, message: 'Bad response from server' };
  }
  if (res.status === 401) {
    signOut('Token rejected. Sign in again.');
    throw new Error('unauthorised');
  }
  return data;
}

function showLogin(message = '') {
  $('app').classList.add('hidden');
  $('login').classList.remove('hidden');
  $('login-error').textContent = message;
  $('token').value = '';
  $('token').focus();
}

function showApp() {
  $('login').classList.add('hidden');
  $('app').classList.remove('hidden');
}

function signOut(message = '') {
  state.token = '';
  localStorage.removeItem(TOKEN_KEY);
  if (state.timer) clearInterval(state.timer);
  state.timer = null;
  showLogin(message);
}

async function login(token) {
  state.token = token;
  const res = await api('/api/admin/session');
  if (!res.ok) {
    state.token = '';
    showLogin(res.message || 'Token rejected');
    return;
  }
  localStorage.setItem(TOKEN_KEY, token);
  showApp();
  await load();
  if (state.timer) clearInterval(state.timer);
  state.timer = setInterval(() => {
    if (document.visibilityState === 'visible') load(true);
  }, POLL_MS);
}

async function load(quiet = false) {
  try {
    const [stats, codes, redemptions] = await Promise.all([
      api('/api/admin/stats'),
      api('/api/admin/codes'),
      api('/api/admin/redemptions?limit=50'),
    ]);
    state.stats = stats.stats || null;
    state.codes = codes.codes || [];
    state.redemptions = redemptions.redemptions || [];
    render();
    $('sync').textContent = `updated ${timeOfDay(Date.now())}`;
  } catch (error) {
    if (error.message !== 'unauthorised' && !quiet) {
      toast('Could not refresh. Check the connection.');
    }
  }
}

function render() {
  renderStats();
  renderCodes();
  renderRedemptions();
}

function renderStats() {
  const s = state.stats || {};
  const rows = [
    ['Live codes', s.live ?? 0],
    ['Redemptions', s.redemptions ?? 0],
    ['All codes', s.codes ?? 0],
    ['Active grants', s.activeGrants ?? 0],
  ];
  document.getElementById('stats').innerHTML = rows
    .map(
      ([label, value]) =>
        `<div class="stat"><div class="stat-value">${esc(value)}</div><div class="stat-label">${esc(label)}</div></div>`,
    )
    .join('');
}

function visibleCodes() {
  const q = state.query.trim().toUpperCase().replace(/\s/g, '');
  return state.codes.filter((c) => {
    if (q && !c.code.includes(q)) return false;
    if (state.filter && c.state !== state.filter) return false;
    return true;
  });
}

function fmtDate(ms) {
  if (!ms) return '—';
  return new Date(ms).toLocaleString();
}

function renderCodes() {
  const body = $('codes').querySelector('tbody');
  const codes = visibleCodes();
  $('codes-empty').classList.toggle('hidden', codes.length > 0);
  body.innerHTML = codes
    .map((c) => {
      const grant = c.type === 'master' ? 'Lifetime' : `${c.days} days`;
      const max = c.maxUses === 0 ? '∞' : c.maxUses;
      const mstone = c.uses > 0 ? milestoneBadge(c.uses) : '';
      const expires = c.expiresAtMs == null ? 'Never' : fmtDate(c.expiresAtMs);
      return `<tr>
        <td class="code">
          <div style="display:flex;align-items:baseline;gap:6px;">
            <span>${esc(c.code)}</span>
            ${mstone}
          </div>
        </td>
        <td>${esc(grant)}</td>
        <td style="font-variant-numeric: tabular-nums;">${esc(c.uses)} / ${esc(max)}</td>
        <td>${esc(expires)}</td>
        <td>${esc(c.campaign || '—')}</td>
        <td><span class="state ${esc(c.state)}">${esc(c.state)}</span></td>
        <td style="text-align:right;">
          <button class="btn-ghost small edit" data-code="${esc(c.code)}">Edit</button>
          <button class="btn-ghost small toggle" data-code="${esc(c.code)}" data-revoked="${c.revoked}">
            ${c.revoked ? 'Switch on' : 'Revoke'}
          </button>
          <button class="btn-ghost small delete" data-code="${esc(c.code)}" data-used="${c.redemptionCount}">Delete</button>
        </td>
      </tr>`;
    })
    .join('');
}

function renderRedemptions() {
  const body = $('redemptions').querySelector('tbody');
  $('redemptions-empty').classList.toggle('hidden', state.redemptions.length > 0);
  $('redemptions-title').textContent = `Recent redemptions`;
  $('clear-filter').classList.add('hidden');
  body.innerHTML = state.redemptions
    .map((r) => {
      const grant = r.lifetime ? 'Lifetime' : `${r.grantDays} days`;
      return `<tr>
        <td class="code">${esc(r.code)}</td>
        <td>${esc(r.deviceShort)}</td>
        <td>${esc(grant)}</td>
        <td>${esc(relative(r.redeemedAtMs))}</td>
      </tr>`;
    })
    .join('');
}

function relative(ms) {
  if (!ms) return '—';
  const diff = Date.now() - ms;
  if (diff < 60000) return 'just now';
  if (diff < 3600000) return `${Math.floor(diff / 60000)}m ago`;
  if (diff < 86400000) return `${Math.floor(diff / 3600000)}h ago`;
  if (diff < 7 * 86400000) return `${Math.floor(diff / 86400000)}d ago`;
  return new Date(ms).toLocaleDateString();
}

function timeOfDay(ms) {
  return new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

let toastTimer = null;
function toast(message) {
  const node = $('toast');
  node.textContent = message;
  node.classList.remove('hidden');
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => node.classList.add('hidden'), 2600);
}

// ---- actions -------------------------------------------------------------

async function toggleCode(code, revoked) {
  const res = await api(`/api/admin/codes/${encodeURIComponent(code)}`, {
    method: 'PATCH',
    body: { revoked: !revoked },
  });
  if (!res.ok) return toast(res.message || 'Could not update');
  toast(revoked ? `${code} switched on` : `${code} revoked`);
  await load(true);
}

async function deleteCode(code, used) {
  if (Number(used) > 0) {
    const ok = confirm(
      `${code} has redemptions. Delete it and its log entries permanently?`,
    );
    if (!ok) return;
  } else if (!confirm(`Delete ${code}?`)) {
    return;
  }
  const res = await api(
    `/api/admin/codes/${encodeURIComponent(code)}${Number(used) > 0 ? '?force=1' : ''}`,
    { method: 'DELETE' },
  );
  if (!res.ok) return toast(res.message || 'Could not delete');
  toast(`${code} deleted`);
  await load(true);
}

async function createCode(event) {
  event.preventDefault();
  const type = $('create-type').value;
  const body = {
    type,
    code: $('create-code').value,
    days: Number($('create-days').value) || 0,
    maxUses: Number($('create-max').value) || 0,
    validForDays: Number($('create-valid').value) || 0,
    campaign: $('create-campaign').value,
    notes: $('create-notes').value,
  };
  const res = await api('/api/admin/codes', { method: 'POST', body });
  if (!res.ok) {
    $('create-error').textContent = res.message || 'Could not create';
    return;
  }
  $('create-dialog').close();
  $('create-form').reset();
  $('create-days').value = '30';
  $('create-max').value = '0';
  $('create-valid').value = '0';
  $('create-error').textContent = '';
  toast(`Created ${res.code}`);
  await navigator.clipboard?.writeText(res.code).catch(() => {});
  await load(true);
}

// ---- edit dialog ---------------------------------------------------------

function openEdit(code) {
  const c = state.codes.find((x) => x.code === code);
  if (!c) return;
  state.editingCode = code;
  $('edit-code').value = c.code;
  $('edit-days').value = c.type === 'master' ? '' : c.days;
  $('edit-max').value = c.maxUses === 0 ? '' : c.maxUses;
  $('edit-expires').value = c.expiresAtMs == null ? '' : new Date(c.expiresAtMs).toISOString().slice(0, 16);
  $('edit-campaign').value = c.campaign || '';
  $('edit-notes').value = c.notes || '';
  $('edit-revoked').checked = c.revoked;
  $('edit-error').textContent = '';
  $('edit-dialog').showModal();
}

async function saveEdit(event) {
  event.preventDefault();
  if (!state.editingCode) return;
  const body = {};
  const daysVal = $('edit-days').value.trim();
  if (daysVal !== '') body.days = Math.max(0, Math.trunc(Number(daysVal) || 0));
  const maxVal = $('edit-max').value.trim();
  if (maxVal !== '') body.maxUses = Math.max(0, Math.trunc(Number(maxVal) || 0));
  const expVal = $('edit-expires').value.trim();
  body.expiresAtMs = expVal === '' ? null : new Date(expVal).getTime();
  body.campaign = $('edit-campaign').value.trim();
  body.notes = $('edit-notes').value.trim();
  body.revoked = $('edit-revoked').checked;

  const res = await api(`/api/admin/codes/${encodeURIComponent(state.editingCode)}`, {
    method: 'PATCH',
    body,
  });
  if (!res.ok) {
    $('edit-error').textContent = res.message || 'Could not save';
    return;
  }
  $('edit-dialog').close();
  state.editingCode = null;
  toast(`${state.editingCode} updated`);
  await load(true);
}

// ---- wiring --------------------------------------------------------------

$('login-form').addEventListener('submit', (event) => {
  event.preventDefault();
  const token = $('token').value.trim();
  if (token) login(token).catch(() => showLogin('Could not reach the server'));
});

$('signout').addEventListener('click', () => signOut());
$('refresh').addEventListener('click', () => load());
$('search').addEventListener('input', (event) => {
  state.query = event.target.value;
  renderCodes();
});
$('state').addEventListener('change', (event) => {
  state.filter = event.target.value;
  renderCodes();
});
$('new-code').addEventListener('click', () => {
  $('create-error').textContent = '';
  $('create-dialog').showModal();
});
$('create-cancel').addEventListener('click', () => $('create-dialog').close());
$('create-form').addEventListener('submit', createCode);

$('create-type').addEventListener('change', (event) => {
  const master = event.target.value === 'master';
  $('create-days').closest('label').style.opacity = master ? '0.45' : '1';
  $('create-days').disabled = master;
});

$('revoke-all').addEventListener('click', async () => {
  if (!confirm('Revoke every campaign code? Existing Pro time stays.')) return;
  const res = await api('/api/admin/revoke-all', { method: 'POST' });
  if (!res.ok) return toast(res.message || 'Could not revoke');
  toast(`Revoked ${res.changed} code${res.changed === 1 ? '' : 's'}`);
  await load(true);
});

$('codes').addEventListener('click', async (event) => {
  const target = event.target.closest('button');
  if (!target) return;
  const code = target.dataset.code;
  if (target.classList.contains('edit')) return openEdit(code);
  if (target.classList.contains('toggle')) return toggleCode(code, target.dataset.revoked === 'true');
  if (target.classList.contains('delete')) return deleteCode(code, target.dataset.used);
});

// edit dialog
$('edit-cancel').addEventListener('click', () => {
  $('edit-dialog').close();
  state.editingCode = null;
});
$('edit-form').addEventListener('submit', saveEdit);

// boot
if (state.token) {
  login(state.token).catch(() => showLogin('Could not reach the server'));
} else {
  showLogin();
}
