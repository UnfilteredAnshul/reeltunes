-- ReelTunes code backend (Cloudflare D1).
-- One database, one Worker: codes, redemptions, rate-limit attempts.
--
-- Apply with:
--   npx wrangler d1 execute reeltunes-codes --remote --file=worker/codes/schema.sql

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS codes (
  code         TEXT PRIMARY KEY,
  type         TEXT NOT NULL DEFAULT 'pro_grant',
  grant_days   INTEGER NOT NULL DEFAULT 0,
  max_uses     INTEGER NOT NULL DEFAULT 0,   -- 0 = unlimited
  uses         INTEGER NOT NULL DEFAULT 0,
  starts_at    INTEGER,
  expires_at   INTEGER,
  campaign     TEXT NOT NULL DEFAULT '',
  notes        TEXT NOT NULL DEFAULT '',
  revoked      INTEGER NOT NULL DEFAULT 0,
  created_at   INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_codes_campaign ON codes (campaign);
CREATE INDEX IF NOT EXISTS idx_codes_created ON codes (created_at DESC);

CREATE TABLE IF NOT EXISTS redemptions (
  id          TEXT PRIMARY KEY,
  code        TEXT NOT NULL,
  device_id   TEXT NOT NULL,
  install_id  TEXT NOT NULL DEFAULT '',
  redeemed_at INTEGER NOT NULL,
  ip_hash     TEXT,
  grant_days  INTEGER NOT NULL DEFAULT 0,
  lifetime    INTEGER NOT NULL DEFAULT 0,
  until_ms    INTEGER,
  revoked     INTEGER NOT NULL DEFAULT 0
);

-- One redemption per code per device. Reinstall does not reset it.
CREATE UNIQUE INDEX IF NOT EXISTS idx_redemption_code_device
  ON redemptions (code, device_id);
CREATE INDEX IF NOT EXISTS idx_redemptions_code
  ON redemptions (code, redeemed_at DESC);
CREATE INDEX IF NOT EXISTS idx_redemptions_device
  ON redemptions (device_id, redeemed_at DESC);

CREATE TABLE IF NOT EXISTS redeem_attempts (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id TEXT NOT NULL,
  at        INTEGER NOT NULL,
  ok        INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_attempts_device_at
  ON redeem_attempts (device_id, at);

-- Devices allowed to redeem MASTER_CODE for lifetime Pro.
CREATE TABLE IF NOT EXISTS master_devices (
  id        TEXT PRIMARY KEY,
  device_id TEXT NOT NULL UNIQUE,
  note      TEXT NOT NULL DEFAULT '',
  added_at  INTEGER NOT NULL
);
