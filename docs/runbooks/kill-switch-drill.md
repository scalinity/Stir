# Runbook: kill-switch end-to-end drill

**Owner:** Daniel. Runs: monthly during beta, quarterly post-launch.

## Why this drill exists

Step 8 lands the ops console surface for flipping four kill switches. If we never exercise the full loop — flip in console, propagate via `/v1/config/bootstrap`, observe iOS degraded behavior — we've shipped an untested control surface and will discover issues the next time we NEED it (which is the worst time).

## The four kill switches

| Flag | iOS behavior when `value: true` |
| --- | --- |
| `disable_scan_parse` | Pantry scan path degrades to manual entry; users see no AI ingredients, add manually from the keyboard. Scan button remains visible; tapping it still opens the camera, but submission surfaces `AI-01`. |
| `disable_cook_realtime` | All Premium+ voice voice Cook Mode traffic falls back to Gemini text + AVSpeechSynthesizer with `AI-VOICE-01` banner visible at the top of Cook Mode. Voice mic affordance still taps; it routes to the fallback path. |
| `disable_imports` | Recipe import returns `IMPORT-01` with friendly "imports are temporarily unavailable" copy. Share extension shows the same error. |
| `force_saved_meals_only` | All AI generation is blocked. `AI-01` on every endpoint (scan, solve, cook, substitution, import, grocery). Saved meals + manual paths remain functional. Banner on Tonight Home. |

## Drill steps

For each flag (run on staging TestFlight build, NOT prod unless it's a real incident):

1. **Capture baseline** — take a screen recording of the flow under normal conditions (scan a photo / start voice Cook Mode / import a recipe / open Tonight Home).
2. **Flip the flag** via ops console → Feature Flags → `<flag name>` → set value=true → Save. The `audit_log` row writes automatically.
3. **Wait 30s** for iOS to pick up the change on the next `/v1/config/bootstrap` poll. (Cold app start picks up immediately.)
4. **Reproduce the flow** — verify the degraded behavior matches the expectation in the table above.
5. **Flip back** — set value=false, Save, wait 30s, verify normal behavior resumes.
6. **Verify audit log** — ops console → Audit Log (step 9) → two `feature_flags.updated` rows per drill (flip on + flip off), each with `actor_id` + `before`/`after` shape.

## Expected observability during the drill

- PostHog: `screen_error_shown` event fires with the expected error code (AI-01 / IMPORT-01 / AI-VOICE-01) each time the user triggers the flow.
- Sentry: NO errors during the drill — these are feature-disabled paths, not crashes. If Sentry fires, that's a bug in the degraded handling code.
- Supabase logs: the affected Edge Function either returns early with the feature-disabled response OR the iOS client respects the flag and never makes the call. Both paths are valid; the former is more defensive (server-authoritative).

## Failure modes to document

If the drill uncovers any of these, file a step-9 polish ticket:

- Flag flip doesn't propagate within 30s → config-bootstrap caching bug on iOS or a stale feature_flags row on prod.
- Degraded UI has bad copy / missing banner / crashes.
- Audit log row missing for the flip (serious — means the ops console dispatch didn't call writeAudit).
- kill switch `disable_*` ON and a user STILL makes a successful AI call → RACE between flip propagation + in-flight request, OR the handler isn't checking the flag. Check handler layer.

## Related

- Spec §13 "Feature flags + experimentation" names the four kill switches.
- ADR 0023 describes the audit_log write path for every admin mutation.
