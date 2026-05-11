-- SCA-322 — re-comment device_installations.notification_prefs_json
--
-- The original COMMENT in 20260419000018_device_installations_push_register.sql
-- referenced `{ import_completion, reactivation, trial_reminder }`. SCA-74
-- retired the trial_reminder feature on 2026-05-07; the immutable-migration
-- policy left the COMMENT pointing at a non-existent key. SCA-322 widens
-- the schema (Backend/_shared/validation.ts PushRegisterRequest) to cover
-- the remaining APNsCategory values (`cook_reminder`, `billing_grace`),
-- so this is the natural moment to refresh the column COMMENT.
--
-- Forward-only: the prior migration's COMMENT statement is intentionally
-- left in place per the immutable-migration policy. This file's COMMENT
-- supersedes it via Postgres's last-writer-wins COMMENT semantics.
--
-- New keys (all optional Bool; default semantics live in iOS
-- NotificationPreferencesStore where each pref defaults TRUE for opt-in
-- UX):
--   - import_completion : long-paste recipe-import completion push.
--   - reactivation      : 7-day no-cook reminder (LOCAL UNUserNotification,
--                         NOT an APNs send — but the opt-in flag is here
--                         so a single Settings UI feeds both code paths).
--   - cook_reminder     : reserved for the future cook_reminder template
--                         (no backend enqueue path today).
--   - billing_grace     : revenuecat-webhook BILLING_ISSUE push during
--                         Apple's grace window (SCA-77).

COMMENT ON COLUMN device_installations.notification_prefs_json IS
  'Per-category push opt-ins: { import_completion, reactivation, cook_reminder, billing_grace }. NULL = never registered; push scheduler treats NULL as deny.';
