-- Stir operational schema — device_installations additions for push-register
--
-- Step 7 adds two columns needed by /v1/push/register:
--   - apns_environment: 'production' | 'sandbox' (TestFlight + DEBUG).
--     APNs rejects prod-token sends to sandbox endpoint and vice-versa,
--     so the sender (step 8 push job) needs to know which gateway to use.
--   - notification_prefs_json: user-chosen opt-ins from Settings →
--     Notifications. Queried by push-scheduler to short-circuit sends
--     for users who disabled the category (trial reminders, etc.).
--
-- Existing `push_token` column carries the 64-hex-char APNs token
-- (spec §4 device_installations.push_token — not renamed).
--
-- notifications_enabled is the OS-level grant (UNUserNotificationCenter);
-- per-category toggles live in notification_prefs_json. Nullable JSONB
-- so rows that haven't registered yet read as NULL rather than {} — iOS
-- treats NULL as "never registered; ask before sending".

ALTER TABLE device_installations
  ADD COLUMN IF NOT EXISTS apns_environment TEXT
    CHECK (apns_environment IN ('production', 'sandbox')),
  ADD COLUMN IF NOT EXISTS notification_prefs_json JSONB;

COMMENT ON COLUMN device_installations.apns_environment IS
  'APNs environment gateway: production (App Store + TestFlight public) | sandbox (DEBUG builds). NULL until push-register called.';

COMMENT ON COLUMN device_installations.notification_prefs_json IS
  'Per-category push opt-ins: { import_completion, reactivation, trial_reminder }. NULL = never registered; push scheduler treats NULL as deny.';
