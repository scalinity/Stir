-- voice_session_owners
--
-- P1-B / SA2-W4 (2026-04-23; revised 2026-04-23 post-review): binds a
-- minted voice session's `session_id` to the `canonical_user_key` that
-- authenticated the mint. `/v1/ai/voice-turn-usage` rejects posts under
-- a session_id that:
--   (a) does not have an owner row (missing mint or expired beyond
--       retention) — 403 ENT-VOICE-01.
--   (b) has an owner row for a DIFFERENT canonical_user_key (IDOR) —
--       403 ENT-VOICE-01.
--   (c) has an owner row that has been superseded (closed_at IS NOT NULL) —
--       403 AI-VOICE-01 with `reason: "session_closed"`. Distinct signal
--       so ops dashboards can split ownership failures (security) from
--       lifecycle failures (stale client).
--
-- Closure semantic: every new mint for the same canonical_user_key
-- UPDATE-closes any prior unclosed row BEFORE inserting the new one.
-- Gemini Live has no server-side logout; this makes "session was
-- superseded by a newer mint" a first-class queryable state instead of
-- implicit-via-retention.
--
-- Retention: rows > 2h old are purged by pg_cron. 2h covers Gemini's
-- 35-min hard mint deadline plus ample safety margin for dashboards
-- that want recent history.
--
-- RLS: explicit deny-all (FOR ALL USING (false)). Service role bypasses
-- as with other ops tables. Explicit rather than implicit so a
-- migration-diff reader sees the posture immediately.

-- ---------------------------------------------------------------------
-- Extensions (idempotent + dev-env-safe)
-- ---------------------------------------------------------------------
-- Supabase prod has pg_cron preinstalled. Dev/branch envs may not;
-- the IF NOT EXISTS makes this migration applicable across envs. A
-- further runtime guard on `pg_extension` (below) decides whether to
-- actually schedule the retention job.
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

-- ---------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS voice_session_owners (
  session_id         uuid PRIMARY KEY,
  canonical_user_key text NOT NULL,
  minted_at          timestamptz NOT NULL DEFAULT now(),
  closed_at          timestamptz NULL
);

CREATE INDEX IF NOT EXISTS voice_session_owners_user_key_idx
  ON voice_session_owners (canonical_user_key);

CREATE INDEX IF NOT EXISTS voice_session_owners_minted_at_idx
  ON voice_session_owners (minted_at);

-- UNIQUE partial index: at most one open row per user, enforced at
-- the DB layer. Prevents the race where two near-simultaneous mints
-- from the same user both UPDATE-close and both INSERT — the second
-- INSERT fails with unique_violation (SQLSTATE 23505), and the
-- handler retries (re-running the supersede UPDATE finds the
-- winner's row open and closes it, then INSERT succeeds).
-- Concurrent-mint case is structurally serialized this way without
-- requiring the handler to open an explicit transaction.
-- Also accelerates the supersede UPDATE predicate
-- (`WHERE canonical_user_key = $1 AND closed_at IS NULL`).
CREATE UNIQUE INDEX IF NOT EXISTS voice_session_owners_one_open_per_user_uniq
  ON voice_session_owners (canonical_user_key)
  WHERE closed_at IS NULL;

-- ---------------------------------------------------------------------
-- RLS: explicit deny-all
-- ---------------------------------------------------------------------
ALTER TABLE voice_session_owners ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "voice_session_owners_deny_all" ON voice_session_owners;
CREATE POLICY "voice_session_owners_deny_all"
  ON voice_session_owners
  FOR ALL
  TO authenticated, anon
  USING (false)
  WITH CHECK (false);

-- ---------------------------------------------------------------------
-- Retention cron (idempotent; dev-env safe)
-- ---------------------------------------------------------------------
-- Pattern matches 20260423000001 (notification_jobs retention): the
-- outer `IF EXISTS` tolerates first-run; the extension guard tolerates
-- a dev env where pg_cron isn't actually present even after the
-- CREATE EXTENSION above (self-hosted Postgres without the cron
-- bgworker, for example). Without the extension guard, the PERFORM
-- cron.schedule() call crashes on "schema cron does not exist".
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE NOTICE 'pg_cron extension not present; skipping voice_session_owners retention schedule';
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-voice-session-owners-retention') THEN
    PERFORM cron.unschedule('stir-voice-session-owners-retention');
  END IF;

  PERFORM cron.schedule(
    'stir-voice-session-owners-retention',
    '@hourly',
    $job$ DELETE FROM voice_session_owners WHERE minted_at < now() - interval '2 hours'; $job$
  );
END
$$;
