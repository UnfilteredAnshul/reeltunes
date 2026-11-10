// ReelTunes code backend.
//
// One Worker, one D1 database, one static dashboard.
//
//   POST /api/redeem              public  – validate a code, record the grant
//   GET  /api/admin/*             admin   – dashboard data (Bearer ADMIN_TOKEN)
//
// Rules that must not drift from lib/promo.dart:
//   • A code grants time, never a price.
//   • One redemption per code per device.
//   • Revoked / expired / exhausted codes fail before anything is granted.
//   • Redeeming never deletes or hides library content.

const CODE_TYPES = new Set(['pro_grant', 'pro_long', 'master']);
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const MAX_CODE_LENGTH = 24;
const MIN_CODE_LENGTH = 4;
const RATE_PER_HOUR = 5;
const RATE_PER_DAY = 20;
const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
const MONTHS = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === 'OPTIONS') return cors(new Response(null, { status: 204 }));

    try {
      if (path === '/api/health') {
        return json({ ok: true, service: 'reeltunes-codes' });
      }
      if (path === '/api/redeem') {
        if (request.method !== 'POST') return methodNotAllowed();
        return cors(await handleRedeem(request, env, ctx));
      }
      if (path.startsWith('/api/admin/')) {
        const denied = requireAdmin(request, env);
        if (denied) return cors(denied);
        return cors(await handleAdmin(request, env, path.slice('/api/admin/'.length), url));
      }
      return json({ ok: false, message: 'Not found' }, 404);
    } catch (error) {
      console.error('unhandled', error);
      return json(
        { ok: false, message: 'Something went wrong. Try again.' },
        500,
      );
    }
  },
};

// ---- redeem --------------------------------------------------------------

async function handleRedeem(request, env, ctx) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ ok: false, message: "That code isn't valid" }, 400);
  }

  const code = normalize(body?.code);
  const deviceId = String(body?.deviceId ?? '').trim();
  const installId = String(body?.installId ?? '').trim().slice(0, 128);

  if (!code || code.length < MIN_CODE_LENGTH || code.length > MAX_CODE_LENGTH) {
    return json({ ok: false, message: "That code isn't valid" }, 400);
  }
  if (!validId(deviceId)) {
    return json({ ok: false, message: "That code isn't valid" }, 400);
  }

  const now = Date.now();
  const [hourRow, dayRow] = await env.DB.batch([
    env.DB.prepare(
      'SELECT COUNT(*) AS n FROM redeem_attempts WHERE device_id = ? AND at >= ?',
    ).bind(deviceId, now - HOUR),
    env.DB.prepare(
      'SELECT COUNT(*) AS n FROM redeem_attempts WHERE device_id = ? AND at >= ?',
    ).bind(deviceId, now - DAY),
  ]);
  const hourCount = Number(hourRow.results?.[0]?.n ?? 0);
  const dayCount = Number(dayRow.results?.[0]?.n ?? 0);
  if (hourCount >= RATE_PER_HOUR || dayCount >= RATE_PER_DAY) {
    return json(
      { ok: false, message: 'Too many tries. Try again later.' },
      429,
    );
  }

  await env.DB.prepare(
    'INSERT INTO redeem_attempts (device_id, at) VALUES (?, ?)',
  ).bind(deviceId, now).run();
  if (Math.random() < 0.05) {
    ctx.waitUntil(
      env.DB.prepare('DELETE FROM redeem_attempts WHERE at < ?')
        .bind(now - 2 * DAY)
        .run()
        .catch(() => {}),
    );
  }

  const ip = request.headers.get('CF-Connecting-IP') ?? '';
  const ipHash = ip && env.IP_SALT ? await sha256(`${env.IP_SALT}:${ip}`) : null;

  // Master code: env secret, only allowlisted devices, never shipped in the app.
  const masterCode = normalize(env.MASTER_CODE ?? '');
  if (masterCode && code === masterCode) {
    const allowed = await env.DB.prepare(
      'SELECT device_id FROM master_devices WHERE device_id = ?',
    ).bind(deviceId).first();
    if (!allowed) {
      return json({ ok: false, message: "That code isn't valid" }, 403);
    }
    await recordRedemption(env, {
      code,
      deviceId,
      installId,
      ipHash,
      now,
      days: 0,
      lifetime: true,
      untilMs: null,
    });
    return json({
      ok: true,
      code,
      type: 'master',
      days: 0,
      lifetime: true,
      untilMs: null,
      message: 'Pro unlocked on this device',
    });
  }

  const row = await env.DB.prepare('SELECT * FROM codes WHERE code = ?')
    .bind(code)
    .first();
  if (!row) return json({ ok: false, message: "That code isn't valid" }, 404);
  if (Number(row.revoked) === 1) {
    return json({ ok: false, message: 'That code was switched off' }, 410);
  }
  if (row.starts_at && now < Number(row.starts_at)) {
    return json({ ok: false, message: 'That code is not active yet' }, 410);
  }
  if (row.expires_at && now > Number(row.expires_at)) {
    return json({ ok: false, message: 'That code has expired' }, 410);
  }
  if (Number(row.max_uses) > 0 && Number(row.uses) >= Number(row.max_uses)) {
    return json({ ok: false, message: 'That code is fully used' }, 410);
  }

  const already = await env.DB.prepare(
    'SELECT id FROM redemptions WHERE code = ? AND device_id = ?',
  ).bind(code, deviceId).first();
  if (already) {
    return json({ ok: false, message: 'Already used on this device' }, 409);
  }

  const lifetime = row.type === 'master';
  const days = lifetime ? 0 : Math.max(0, Number(row.grant_days) || 0);
  if (!lifetime && days <= 0) {
    return json({ ok: false, message: "That code isn't valid" }, 410);
  }

  const update = await env.DB.prepare(
    `UPDATE codes SET uses = uses + 1
      WHERE code = ? AND revoked = 0
        AND (max_uses = 0 OR uses < max_uses)
        AND (expires_at IS NULL OR expires_at >= ?)`,
  ).bind(code, now).run();
  if (!update.meta?.changes) {
    return json({ ok: false, message: 'That code is fully used' }, 410);
  }

  const untilMs = lifetime ? null : now + days * DAY;
  const insert = await recordRedemption(env, {
    code,
    deviceId,
    installId,
    ipHash,
    now,
    days,
    lifetime,
    untilMs,
  });
  if (!insert.ok) {
    // Put the use back; somebody else won the race for this device.
    await env.DB.prepare('UPDATE codes SET uses = uses - 1 WHERE code = ?')
      .bind(code)
      .run();
    return json({ ok: false, message: 'Already used on this device' }, 409);
  }

  return json({
    ok: true,
    code,
    type: row.type,
    days,
    lifetime,
    untilMs,
    message: lifetime
      ? 'Pro unlocked on this device'
      : `Pro until ${fmtDate(untilMs)}`,
  });
}

async function recordRedemption(env, r) {
  try {
    await env.DB.prepare(
      `INSERT INTO redemptions
        (id, code, device_id, install_id, redeemed_at, ip_hash,
         grant_days, lifetime, until_ms)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(
      crypto.randomUUID(),
      r.code,
      r.deviceId,
      r.installId,
      r.now,
      r.ipHash,
      r.days,
      r.lifetime ? 1 : 0,
      r.untilMs,
    ).run();
    return { ok: true };
  } catch (error) {
    if (String(error).toLowerCase().includes('unique')) return { ok: false };
    throw error;
  }
}

// ---- admin ---------------------------------------------------------------

async function handleAdmin(request, env, route, url) {
  if (!env.ADMIN_TOKEN) {
    return json({ ok: false, message: 'Admin token is not configured' }, 500);
  }

  if (route === 'session') {
    return json({ ok: true });
  }

  if (route === 'stats' && request.method === 'GET') {
    return json(await stats(env));
  }

  if (route === 'codes' && request.method === 'GET') {
    const q = normalizeLoose(url.searchParams.get('q') ?? '');
    const state = url.searchParams.get('state') ?? '';
    const rows = await env.DB.prepare(
      `SELECT c.*,
        (SELECT COUNT(*) FROM redemptions r
          WHERE r.code = c.code AND r.revoked = 0) AS redemption_count,
        (SELECT MAX(redeemed_at) FROM redemptions r
          WHERE r.code = c.code) AS last_redeemed_at
       FROM codes c
       ORDER BY c.created_at DESC
       LIMIT 500`,
    ).all();
    let codes = (rows.results ?? []).map(mapCode);
    if (q) codes = codes.filter((c) => c.code.includes(q));
    if (state) codes = codes.filter((c) => c.state === state);
    return json({ ok: true, codes });
  }

  if (route === 'codes' && request.method === 'POST') {
    return json(await createCode(request, env));
  }

  if (route === 'refreshed') {
    return json({ ok: true, at: Date.now() });
  }

  if (route.startsWith('codes/')) {
    const code = normalize(decodeURIComponent(route.slice('codes/'.length)));
    if (!code) return json({ ok: false, message: 'Missing code' }, 400);
    if (request.method === 'PATCH') return json(await patchCode(request, env, code));
    if (request.method === 'DELETE') return json(await deleteCode(env, code, url));
    return methodNotAllowed();
  }

  if (route === 'redemptions' && request.method === 'GET') {
    const code = normalize(url.searchParams.get('code') ?? '');
    const limit = Math.min(200, Math.max(1, Number(url.searchParams.get('limit')) || 50));
    const stmt = code
      ? env.DB.prepare(
          `SELECT * FROM redemptions WHERE code = ?
           ORDER BY redeemed_at DESC LIMIT ?`,
        ).bind(code, limit)
      : env.DB.prepare(
          'SELECT * FROM redemptions ORDER BY redeemed_at DESC LIMIT ?',
        ).bind(limit);
    const rows = await stmt.all();
    return json({ ok: true, redemptions: (rows.results ?? []).map(mapRedemption) });
  }

  if (route === 'revoke-all' && request.method === 'POST') {
    const result = await env.DB.prepare(
      "UPDATE codes SET revoked = 1 WHERE revoked = 0 AND type != 'master'",
    ).run();
    return json({ ok: true, changed: result.meta?.changes ?? 0 });
  }

  if (route === 'master-devices' && request.method === 'GET') {
    const rows = await env.DB.prepare(
      'SELECT * FROM master_devices ORDER BY added_at DESC',
    ).all();
    return json({ ok: true, devices: rows.results ?? [] });
  }

  if (route === 'master-devices' && request.method === 'POST') {
    return json(await addMasterDevice(request, env));
  }

  if (route.startsWith('master-devices/') && request.method === 'DELETE') {
    const id = decodeURIComponent(route.slice('master-devices/'.length));
    await env.DB.prepare('DELETE FROM master_devices WHERE id = ?').bind(id).run();
    return json({ ok: true });
  }

  return json({ ok: false, message: 'Not found' }, 404);
}

async function stats(env) {
  const now = Date.now();
  const row = await env.DB.prepare(
    `SELECT
      (SELECT COUNT(*) FROM codes) AS codes,
      (SELECT COUNT(*) FROM codes WHERE revoked = 0
        AND (expires_at IS NULL OR expires_at >= ?1)
        AND (max_uses = 0 OR uses < max_uses)) AS live,
      (SELECT COUNT(*) FROM redemptions) AS redemptions,
      (SELECT COUNT(*) FROM redemptions WHERE redeemed_at >= ?2) AS last_24h,
      (SELECT COUNT(*) FROM redemptions WHERE revoked = 0
        AND (lifetime = 1 OR until_ms > ?1)) AS active_grants,
      (SELECT COUNT(*) FROM master_devices) AS master_devices`,
  ).bind(now, now - DAY).first();
  return { ok: true, stats: mapStats(row) };
}

async function createCode(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return { ok: false, message: 'Invalid request' };
  }

  const type = String(body?.type ?? 'pro_grant');
  if (!CODE_TYPES.has(type)) {
    return { ok: false, message: 'Unknown code type' };
  }
  const days = Math.trunc(Number(body?.days) || 0);
  if (type !== 'master' && (days < 1 || days > 3650)) {
    return { ok: false, message: 'Grant must be 1–3650 days' };
  }
  const maxUses = Math.max(0, Math.trunc(Number(body?.maxUses) || 0));
  const validForDays = Math.max(0, Math.trunc(Number(body?.validForDays) || 0));
  const campaign = String(body?.campaign ?? '').trim().slice(0, 80);
  const notes = String(body?.notes ?? '').trim().slice(0, 300);
  const now = Date.now();

  let code = normalize(body?.code);
  if (code) {
    if (code.length < MIN_CODE_LENGTH || code.length > MAX_CODE_LENGTH) {
      return { ok: false, message: 'Code needs 4–24 characters' };
    }
    if (!/^[A-Z0-9]+$/.test(code)) {
      return { ok: false, message: 'Letters and numbers only' };
    }
  }

  const expiresAt = validForDays > 0 ? now + validForDays * DAY : null;

  for (let attempt = 0; attempt < 10; attempt++) {
    const candidate = code || randomCode();
    try {
      await env.DB.prepare(
        `INSERT INTO codes
          (code, type, grant_days, max_uses, uses, starts_at, expires_at,
           campaign, notes, revoked, created_at)
         VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, 0, ?)`,
      ).bind(
        candidate,
        type,
        type === 'master' ? 0 : days,
        maxUses,
        now,
        expiresAt,
        campaign,
        notes,
        now,
      ).run();
      const inserted = await env.DB.prepare('SELECT * FROM codes WHERE code = ?')
        .bind(candidate)
        .first();
      return { ok: true, code: candidate, row: mapCode(inserted) };
    } catch (error) {
      if (!String(error).toLowerCase().includes('unique')) throw error;
      if (code) return { ok: false, message: 'That code already exists' };
    }
  }
  return { ok: false, message: 'Could not generate a unique code' };
}

async function patchCode(request, env, code) {
  let body;
  try {
    body = await request.json();
  } catch {
    return { ok: false, message: 'Invalid request' };
  }
  const sets = [];
  const values = [];
  if (typeof body?.revoked === 'boolean') {
    sets.push('revoked = ?');
    values.push(body.revoked ? 1 : 0);
  }
  if (typeof body?.notes === 'string') {
    sets.push('notes = ?');
    values.push(body.notes.trim().slice(0, 300));
  }
  if (typeof body?.campaign === 'string') {
    sets.push('campaign = ?');
    values.push(body.campaign.trim().slice(0, 80));
  }
  if (body?.maxUses !== undefined) {
    sets.push('max_uses = ?');
    values.push(Math.max(0, Math.trunc(Number(body.maxUses) || 0)));
  }
  if (!sets.length) return { ok: false, message: 'Nothing to change' };
  values.push(code);
  const result = await env.DB.prepare(
    `UPDATE codes SET ${sets.join(', ')} WHERE code = ?`,
  ).bind(...values).run();
  if (!result.meta?.changes) return { ok: false, message: 'Code not found' };
  const row = await env.DB.prepare('SELECT * FROM codes WHERE code = ?')
    .bind(code)
    .first();
  return { ok: true, row: mapCode(row) };
}

async function deleteCode(env, code, url) {
  const force = url.searchParams.get('force') === '1';
  const used = await env.DB.prepare(
    'SELECT COUNT(*) AS n FROM redemptions WHERE code = ?',
  ).bind(code).first();
  if (Number(used?.n ?? 0) > 0 && !force) {
    return {
      ok: false,
      message: 'This code has redemptions. Revoke it instead, or force delete.',
    };
  }
  await env.DB.prepare('DELETE FROM redemptions WHERE code = ?').bind(code).run();
  await env.DB.prepare('DELETE FROM codes WHERE code = ?').bind(code).run();
  return { ok: true };
}

async function addMasterDevice(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return { ok: false, message: 'Invalid request' };
  }
  const deviceId = String(body?.deviceId ?? '').trim();
  if (!validId(deviceId)) return { ok: false, message: 'Invalid device ID' };
  const note = String(body?.note ?? '').trim().slice(0, 120);
  try {
    await env.DB.prepare(
      'INSERT INTO master_devices (id, device_id, note, added_at) VALUES (?, ?, ?, ?)',
    ).bind(crypto.randomUUID(), deviceId, note, Date.now()).run();
  } catch (error) {
    if (String(error).toLowerCase().includes('unique')) {
      return { ok: false, message: 'That device is already allowed' };
    }
    throw error;
  }
  return { ok: true };
}

// ---- mapping -------------------------------------------------------------

function mapCode(row) {
  if (!row) return null;
  const now = Date.now();
  const revoked = Number(row.revoked) === 1;
  const expired = row.expires_at != null && now > Number(row.expires_at);
  const exhausted = Number(row.max_uses) > 0 && Number(row.uses) >= Number(row.max_uses);
  return {
    code: row.code,
    type: row.type,
    days: Number(row.grant_days) || 0,
    maxUses: Number(row.max_uses) || 0,
    uses: Number(row.uses) || 0,
    expiresAtMs: row.expires_at == null ? null : Number(row.expires_at),
    campaign: row.campaign ?? '',
    notes: row.notes ?? '',
    revoked,
    createdAtMs: Number(row.created_at) || 0,
    redemptionCount: Number(row.redemption_count) || 0,
    lastRedeemedAtMs: row.last_redeemed_at == null
      ? null
      : Number(row.last_redeemed_at),
    state: revoked ? 'revoked' : expired ? 'expired' : exhausted ? 'used' : 'live',
  };
}

function mapRedemption(row) {
  return {
    id: row.id,
    code: row.code,
    deviceId: row.device_id,
    deviceShort: String(row.device_id ?? '').slice(0, 6),
    installId: row.install_id,
    redeemedAtMs: Number(row.redeemed_at) || 0,
    grantDays: Number(row.grant_days) || 0,
    lifetime: Number(row.lifetime) === 1,
    untilMs: row.until_ms == null ? null : Number(row.until_ms),
    revoked: Number(row.revoked) === 1,
  };
}

function mapStats(row) {
  return {
    codes: Number(row?.codes) || 0,
    live: Number(row?.live) || 0,
    redemptions: Number(row?.redemptions) || 0,
    last24h: Number(row?.last_24h) || 0,
    activeGrants: Number(row?.active_grants) || 0,
    masterDevices: Number(row?.master_devices) || 0,
  };
}

// ---- auth & helpers ------------------------------------------------------

function requireAdmin(request, env) {
  if (!env.ADMIN_TOKEN) {
    return json({ ok: false, message: 'Admin token is not configured' }, 500);
  }
  const header = request.headers.get('Authorization') ?? '';
  const bearer = header.toLowerCase().startsWith('bearer ')
    ? header.slice(7).trim()
    : '';
  const token = bearer || (request.headers.get('X-Admin-Token') ?? '').trim();
  if (!safeEqual(token, env.ADMIN_TOKEN)) {
    return json({ ok: false, message: 'Not authorised' }, 401);
  }
  return null;
}

function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i++) diff |= left[i] ^ right[i];
  return diff === 0;
}

function normalize(raw) {
  return String(raw ?? '')
    .toUpperCase()
    .replace(/[\s\-_]/g, '');
}

function normalizeLoose(raw) {
  return String(raw ?? '').toUpperCase().replace(/\s/g, '');
}

function validId(value) {
  return /^[A-Za-z0-9._:-]{8,128}$/.test(value);
}

function randomCode() {
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  let out = 'RT';
  for (const byte of bytes) out += ALPHABET[byte % ALPHABET.length];
  return out;
}

async function sha256(text) {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(text),
  );
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

function fmtDate(ms) {
  const d = new Date(ms);
  return `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`;
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  });
}

function cors(response) {
  const out = new Response(response.body, response);
  out.headers.set('access-control-allow-origin', '*');
  out.headers.set('access-control-allow-methods', 'GET, POST, PATCH, DELETE, OPTIONS');
  out.headers.set('access-control-allow-headers', 'Authorization, Content-Type, X-Admin-Token');
  out.headers.set('access-control-max-age', '86400');
  return out;
}

function methodNotAllowed() {
  return json({ ok: false, message: 'Method not allowed' }, 405);
}
