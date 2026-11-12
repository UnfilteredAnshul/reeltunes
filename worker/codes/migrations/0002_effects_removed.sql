-- "Remove effects" on the dashboard.
--
-- Adds the flag consulted by GET /api/grant. Installs that redeemed the code
-- clear their local Pro grant on the next launch/resume. Existing rows default
-- to 0, so nothing changes until the owner presses the button.
--
-- Apply with:
--   npx wrangler d1 execute reeltunes-codes --remote --file=worker/codes/migrations/0002_effects_removed.sql

ALTER TABLE codes ADD COLUMN effects_removed INTEGER NOT NULL DEFAULT 0;
