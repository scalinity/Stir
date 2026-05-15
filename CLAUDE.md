# CLAUDE.md — Stir

Orientation pack. Trust as a working cache; full spec (`Specs/Stir-Full-Spec.md`) and Cook Mode research (`Specs/Stir-Cook-Mode-Architecture.md`) are authoritative. Daniel is the solo builder; reads generated code at peer level. Don't simplify unless asked.

## The product in three sentences

iPhone app for the weeknight moment: stand in the kitchen with ingredients, no plan, low energy. Scan → 3 dinners → cook with timers and (Premium) hands-free voice. iOS 17+, SwiftUI, Gemini-only AI, Supabase ops backend, CloudKit for user content.

## Spec pointers

- **Full spec**: `Specs/Stir-Full-Spec.md` · **Cook Mode research**: `Specs/Stir-Cook-Mode-Architecture.md` · **Design tokens**: `Specs/Design-System.md`
- **Pre-filled constants** (Swift enums, JSON shapes, SQL, env vars, billing/aliasing/quota semantics): `docs/CLAUDE-Constants.md`. Companion to this file — open before any work touching pricing, error wire shapes, identity aliasing, billing state, or quotas.
- **Mockups** (visual source of truth, 17 HTML prototypes): `stir-app-design/project/DesignMockups/` (`INDEX.md`). Read matching mockup before coding any unimplemented screen — pixel-truth for layout/typography/spacing/states. Tokens in `_shared/colors_and_type.css`; provenance `EXTRACTED_TOKENS.md`. NOT authoritative for product content.
- **ADRs** `docs/decisions/` · **Runbooks** `docs/runbooks/` · **Deferred work** `docs/deferred-work.md`
- Precedence: ADR > spec > this file > mockups (mockups override for tokens; if they disagree with `Design-System.md`, mockups win and §3/§4/§5/§6/§12 must be updated). Flag discrepancies.

## Decisions system

`docs/decisions/` is the architectural record. Read `docs/decisions/README.md` for full rules.

- **Create an ADR** for load-bearing choices, rejected alternatives, added/retired rules, or work deferred with a trigger. **Don't** for day-to-day implementation, bug fixes, or anything captured by code shape.
- Naming `NNNN-kebab-name.md`, sequential, never recycled. Statuses: `Proposed | Accepted | Deferred | Superseded by NNNN | Rejected`. Superseded keeps a forward link; rejected stays so ideas don't cycle back.
- Template `docs/decisions/TEMPLATE.md`. <5 min read. Check prior ADR before load-bearing choices; create ADR BEFORE/ALONGSIDE code; revert/amend on drift; update the index.

---

## North-star constraints (invariants — never violate)

1. **Single AI vendor: Google Gemini.** No OpenAI, no Anthropic, no cross-vendor fallback. Production: `gemini-3-flash-preview`, `gemini-3.1-flash-lite-preview`, `gemini-3.1-flash-live-preview`.
2. **No provider API keys in the iOS bundle, ever.** Cook Mode voice uses ephemeral session tokens minted server-side. Gemini API key lives in Supabase Edge Function secrets only.
3. **User content lives in CloudKit, not Supabase.** Postgres holds operational metadata only (quotas, entitlements, prompt versions, AI request logs).
4. **RLS on every ops table in Supabase.** All rows keyed on `canonical_user_key`. No exceptions, no bypasses.
5. **Hard-rule validator runs on every substitution output,** regardless of invocation path.
6. **Voice is Premium+ only.** Free → unlimited tap-based Cook Mode; voice affordance triggers `ENT-VOICE-01` paywall. Caps: free 0 / premium 13 / pro 27 sessions/month (ADR 0015). `effectiveVoiceEnabled()`'s `ENTITLEMENT_OVERRIDE_VOICE_FREE` env hatch is dev/staging only — production must keep it unset (verify `supabase secrets list --project-ref ktqajarcomzplnpbczfo` before any cap-related deploy). ADR 0008 Superseded.
7. **Live sessions cannot be pruned mid-session — `refreshSession()` IS pruning.** No mid-session truncation frame. Bound cost by silently minting a NEW ephemeral token with compact recap appended to systemInstruction and swapping the WS. Triggers: `turnCount - lastRefreshedAtTurn >= 10` OR `accum_prompt_tokens > 15_000` on a single turn. ADR 0014.
8. **Voice session `max_output_tokens: 400`** (ADR 0010). Baked into mint config. Invariant is "bounded cap exists" — value tunable. 400 ≈ 16s audio at 25 tok/s.

---

## Stack snapshot

| Layer | Choice |
| --- | --- |
| iOS | 17.0 min; Xcode 26+, iOS 26 SDK (Apple App Store rule as of 2026-04-28) |
| UI / Concurrency | SwiftUI, `@Observable` view models / async-await, actors |
| Persistence / Sync | Core Data + `NSPersistentCloudKitContainer` / CloudKit private DB |
| Backend | Supabase (Postgres + Edge Functions + Auth + pgmq/pg_cron) |
| Payments / Analytics / Errors / Push | RevenueCat over StoreKit 2 / PostHog / Sentry / APNs direct |
| Text AI | `gemini-3-flash-preview` (scan, solve, substitution, cook-turn fallback) |
| Cheap AI | `gemini-3.1-flash-lite-preview` (recipe import, grocery list) |
| Voice AI | `gemini-3.1-flash-live-preview` at `thinkingLevel: minimal` |
| On-device | Vision (OCR, barcode), Speech + AVSpeechSynthesizer (voice fallback only) |

---

## Pre-filled constants

**Full reference**: `docs/CLAUDE-Constants.md` — Swift enums (`GeminiModel`, `LiveSessionLimits`, `ErrorCode`), pricing table, cost model, StoreKit SKUs + Apple fees, tier entitlements table, endpoints (Supabase + Gemini), VAL-01/AUTH-01 JSON shapes + reason table, canonical user key, identity aliasing/merge transaction rules, `app_users.status` enum, `entitlement_snapshots.billing_state` enum + RevenueCat webhook → state mapping, `usage_counters` semantics + atomic quota SQL, `/v1/session/bootstrap` + `/v1/config/bootstrap` response shapes, feature flags (client + server), environment variables.

Quick highlights load-bearing for everyday work:

- Production models: `gemini-3-flash-preview` (text, scan/solve/sub/cook-fallback), `gemini-3.1-flash-lite-preview` (recipe import, grocery), `gemini-3.1-flash-live-preview` (voice, `thinkingLevel: minimal`). Live audio 25 tok/s both ways. **No caching on Live API** (ADR 0015).
- Voice caps: free 0 / premium 13 / pro 27 sessions per month (ADR 0015). `max_output_tokens: 400` baked into mint (ADR 0010).
- StoreKit SKUs: `stir.premium.monthly` $9.99 · `stir.premium.annual.trial7` $69.99 (no trial; `.trial7` suffix is historical, see SCA-294) · `stir.pro.monthly` $14.99 · `stir.pro.annual` $139.99 (PRIMARY paywall CTA, 7-day trial). Family Sharing off, group `stir.subscriptions`.
- Canonical user key: `ck:<userRecordName>` if CloudKit available, else `install:<keychainInstallId>`. Always alias forward.
- `usage_counters.cap_count` SNAPSHOTTED at row-creation; never refreshed on tier upgrade. Atomic check via `UPDATE ... WHERE used_count < cap_count RETURNING ...`.
- `voice_enabled` is SERVER-COMPUTED; `quotas` is an array (not keyed object) with `used`/`cap`/`period_end`.
- Backend secrets list (Supabase Edge Function): `GEMINI_API_KEY` (legacy AIzaSy... only — paid tier), `STIR_JWT_SECRET` (renamed from SUPABASE_JWT_SECRET, prefix is reserved), `REVENUECAT_WEBHOOK_SECRET`, APNs tuple, `POSTHOG_API_KEY`, `SENTRY_DSN`, `LOG_IP_SALT`, `STIR_PGMQ_DISPATCH_SECRET`. iOS: only public-side keys (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, RevenueCat/PostHog public, Sentry public). Never on iOS: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`.
- Error codes: NET-01, INTERNAL-01, AI-01..03, AI-VOICE-01, IMPORT-01, PERM-{CAM,MIC,PHOTO,REM}-01, SYNC-01, RATE-01, BILL-01, PAY-01, ENT-{VOICE,MULTI-IMAGE,LEFTOVERS}-01, VOICE-SESSION-01 (ADR 0017), VAL-01, AUTH-01 (typed `reason`), METHOD-NOT-ALLOWED-01.

Open `docs/CLAUDE-Constants.md` before any work that touches pricing, error wire shapes, identity aliasing, billing state, or quotas.

---

## Repo layout

```
Stir/                            # iOS app target
  App/                           # StirApp, RootCoordinator
  DesignSystem/                  # tokens + shared views
  Core/{Models,Repositories,Services}/  # domain types, sync, cross-feature (EntitlementService, QuotaService, AIDispatch)
  Features/                      # Onboarding/ Tonight/ Scan/ Solve/ CookMode/ Import/ Saved/ Settings/ Billing/
  Integrations/                  # Camera/ Speech/ Vision/ Reminders/ CloudKit/ RevenueCat/ PostHog/ Sentry/ GeminiLive/
  Extensions/                    # ShareExtension/ Widgets/ AppIntents/
  Tests/                         # Unit/ Integration/ UITests/

Backend/supabase/{migrations, functions/_shared, functions/<endpoint>, seed}/
Specs/, stir-app-design/, docs/{decisions,runbooks}/, docs/deferred-work.md
```

---

## AI pipeline map

| Feature | Endpoint | Model | Streaming | Guardrail |
| --- | --- | --- | --- | --- |
| Pantry scan parse | `/v1/ai/pantry-parse` | flash | no | schema + confidence threshold |
| Dinner solve | `/v1/ai/dinner-solve` | flash | yes (card-by-card) | hard-rule validator, retry. Optional on-device `feedback_summary` (ADR 0030); v2.0.0 prompt 5% canary via `pickStandardPrompt`, v1.0.0 default. |
| Cook voice turn | Live WS via `/v1/ai/realtime-session` | flash-live (minimal) | bidi audio | system prompt, max_output_tokens, refresh-bounded growth |
| Cook substitution (voice) | Live function call → `/v1/ai/substitution` | flash | no | hard-rule validator |
| Cook Q&A fallback | `/v1/ai/cook-turn` | flash (text) | no | schema |
| Substitution (sheet) | `/v1/ai/substitution` | flash | no | hard-rule validator |
| Recipe import | `/v1/ai/recipe-import` | flash-lite | no | sanitize HTML, treat content as untrusted |
| Grocery generate | `/v1/ai/grocery-generate` | flash-lite | no | post-model dedupe |

---

## Gemini Live — sharp edges

Where Gemini Live differs from OpenAI Realtime. Assume OpenAI-Realtime intuition until otherwise stated.

1. **No caching.** Every turn re-sends context at full audio-input rate. Refresh-bounded growth mandatory; skipping = linear cost blowup.
2. **No first-class WebRTC.** WebSocket only via `URLSessionWebSocketTask`. Cellular networks occasionally stall on TCP head-of-line blocking. Not supported — don't "switch to WebRTC".
3. **Preambles NOT spontaneous; adherence UNVALIDATED.** Unlike `gpt-realtime`, Gemini doesn't naturally say "let me check" before tool calls. **Belt-and-suspenders:** iOS plays a pre-recorded filler clip the instant a `toolCall` frame arrives, deterministically covering the ~2s round-trip. If `preamble_present_rate` <90%, disable model preambles and rely on client clip alone.
4. **Preview status.** If Google changes API shape/pricing, `disable_cook_realtime` routes Premium+ voice to text fallback with `AI-VOICE-01`.
5. **Two ephemeral-token expiries.** `new_session_expire_time` = window to open (~60s); `expire_time` = hard deadline (~35min); `uses: 1`.
6. **Session refresh silent.** 10 min or 15 turns. Mint new token, open new WS, close old after new one's first response. Failure → text fallback.
7. **Semantic VAD start; server VAD fallback.** Semantic chunks on utterance completion; avoids ambient kitchen noise misfires. Flip `voice_turn_detection_mode` if testing shows misfires.
8. **`max_output_tokens: 400`** (ADR 0010) baked into mint's `generation_config`. "Bounded cap exists" is the invariant.
9. **Function response flow differs.** Gemini auto-continues after `BidiGenerateContentToolResponse`. No `response.create`. Function responses via `toolResponse` carrying matching `functionResponse.id` — NOT `clientContent`.
10. **Audio format.** PCM16 16kHz input; base64 in `realtimeInput.audio`. Server returns base64 in `serverContent.modelTurn.parts[].inlineData`.
11. **`clientContent` is history-only on 3.1 Flash Live.** For in-session text injection (step advance, timer completion, substitution context), use `realtimeInput.text`. `clientContent` only seeds initial history (requires `initial_history_in_client_content: true`); Stir doesn't seed.
12. **Tool calls synchronous.** No async/parallel. One in flight at a time.
13. **Auth header `Authorization: Token <value>`** — NOT `Bearer`. Rest of Google API ecosystem uses Bearer; easy to get wrong.
14. **Mint endpoint `POST /v1alpha/auth_tokens`** (snake_case). WS for ephemeral tokens: `/v1alpha.GenerativeService.BidiGenerateContentConstrained?access_token=<name>` (NOT `/v1beta`). API-key path: `/v1beta.GenerativeService.BidiGenerateContent?key=<KEY>`. Docs: ai.google.dev/gemini-api/docs/live-api/get-started-websocket. **Body flat camelCase** (not wrapped in `{authToken:{...}}`): `{ expireTime, newSessionExpireTime, uses, bidiGenerateContentSetup: { model, generationConfig: { responseModalities, speechConfig, maxOutputTokens, thinkingConfig }, systemInstruction, tools, realtimeInputConfig: { automaticActivityDetection, turnCoverage } } }`. Verified against `googleapis/js-genai`.
15. **~200-token AUDIO-mode overhead per turn (undocumented).** Every Live turn with `response_modalities:[AUDIO]` charges ~200 extra audio-input tokens beyond literal audio — even on text-only input. Reliably observed in `usageMetadata.prompt_tokens_details`. Cost model accounts for it.
16. **Mint uses API-key auth** — same `GEMINI_API_KEY` as `generateContent`. Header `x-goog-api-key`. WS auth from iOS: returned `.name` (`auth_tokens/<id>`) → URL `?access_token=<name>`, no `Authorization`. ADR 0006 (OAuth) Rejected.
17. **Mint requires paid-tier billing on the GCP project** that owns the key. Free-tier returns `400 INVALID_ARGUMENT` indistinguishable from malformed body. `generateContent` and `models.list` work on free and mislead. Verify in aistudio.google.com/app/apikey.
18. **Mint rejects new-format API keys** (`AQ.xxx`, ~53 chars). Use legacy (`AIzaSy...`, 39 chars). `generateContent` accepts both — hidden failure mode.
19. **Ephemeral-token sessions still require client-sent `{"setup":{...}}` frame** as the first WS message after `open`. Mint-baked `bidiGenerateContentSetup` is an authorization *ceiling*; server does NOT auto-emit `setupComplete`. Backend pre-serializes the setup frame at mint time as `setup_frame_json`; iOS forwards verbatim via `LiveOutboundFrame.setup(payload:)`.
20. **Preview API drops load-bearing frames.** `gemini-3.1-flash-live-preview` can omit `turnComplete` or `setupComplete` (observed 2026-04-23: after `start_timer`, three `generationComplete` but no `turnComplete`; iOS pinned `.modelSpeaking` 35+s). **Defensive-by-default:** every `await` on a Gemini-initiated state transition (setupComplete, turnComplete, first audio chunk, pre-mint swap) MUST have client-side timeout + graceful recovery. `turnStuckWatchdog` in `RealtimeSession.swift` (8s threshold, armed on `.modelSpeaking`, rearmed on inbound audio, cancelled on transition out). On fire: synthesize `turnComplete`, persist VoiceTurn `resultType='error'/errorCode='turnComplete_timeout'`, emit `voice_turn_stuck_watchdog_fired`. Threshold: >5% of tool-call turns in 7-day window = revisit spec §18 vendor contingency. SpeechFallbackService has zero exposure. Revisit Live timeouts at GA.

---

## Backend contracts

All `/v1/*` authenticate via session JWT. Admin `/v1/ops/*` uses Supabase Auth admin role + RLS.

- 400 → `{error:"VAL-01", message, field_errors}`; 401 → `{error:"AUTH-01", message, reason}`
- 403 entitlement → `ENT-VOICE-01`/`ENT-LEFTOVERS-01`/`ENT-MULTI-IMAGE-01`/`BILL-01`; 429 → `RATE-01`; 502 Gemini → `AI-01`
- Every body `{error:CODE, message:string, ...structured}`. Never string-only error. Never empty 4xx/5xx.
- Idempotency via explicit request IDs (spec §3 API table). Every AI call logs to `ai_request_log`: `{provider, model, input_tokens, output_tokens, cost_usd, latency_ms, thinking_level, prompt_version}`.

Edge Function conventions: Deno runtime, one function per endpoint. Shared helpers in `_shared/` (relative imports; no npm deps unless unavoidable). Secrets via `Deno.env.get(...)`. Validate session JWT first via shared helper. Zod schema validation at handler boundary (before any DB access). **Every new `/v1/ai/*` (or any JWT-verifying) function MUST have `[functions.<name>] verify_jwt = false` in `Backend/supabase/config.toml`** — without it, Kong rejects every authenticated POST at platform layer with opaque 401 before handler runs (typed AUTH-01 reason never reaches client). Land in SAME PR as the function.

---

## Integration test DB strategy

Per-test unique IDs, no cleanup between tests. `supabase db reset` between CI runs.

- Test helpers generate fresh UUIDs for `installation_id` and CK record names. Test-scoped keys prefixed `test:`; cleanup via `DELETE ... WHERE canonical_user_key LIKE 'install:test:%' OR ... 'ck:test:%'`.
- Aggregate-style assertions (COUNT, SUM without WHERE) **banned** — always filter by test-scoped keys.
- Service-role client only in test seed helpers; never in production paths.
- RLS tests assert **empty result sets** (`length === 0`), **never** 403. RLS is a row filter, not an access check.
- No `beforeEach` TRUNCATE; no transaction-rollback wrappers (PostgREST doesn't expose transaction handles).

---

## Data ownership boundary

| Lives in | Includes | Does NOT include |
| --- | --- | --- |
| CloudKit private DB | HouseholdProfile, DietaryRule, KitchenEquipment, PantryItem, MealSolveRequest, SuggestedDish, RecipePlan, RecipeIngredient, Step, RecipeImport, CookingSession, VoiceTurn, Timer, SubstitutionEvent, OutcomeFeedback, GroceryList, GroceryItem, MediaAsset | any operational or billing data |
| Supabase Postgres | app_users, device_installations, entitlement_snapshots, usage_counters, ai_request_log, prompt_versions, feature_flags, ops_flagged_outputs, audit_log, notification_jobs | any user-generated content |
| Bundled asset (JSON/SQLite) | IngredientCanonical (global ontology) | anything user-editable |

About to write user content to Postgres? Stop — that's always a bug unless it's an operational counter keyed on `canonical_user_key`.

---

## Schema truth

**For column types, check the DB (`\d <table>`) or the latest `ALTER` — not the init migration.**

Retconned types (init migration COMMENTs and first-glance schema reading get these wrong):

| Column | Now | Migration |
| --- | --- | --- |
| `device_installations.installation_id` | UUID (was TEXT) | `20260418000022_tighten_column_constraints.sql` |
| `app_users.current_install_id` | UUID (was TEXT) | same |
| `ops_flagged_outputs.request_id` | TEXT (was UUID) | `20260424000002_request_id_text_consolidation.sql` — matches `ai_request_log.request_id` + accepts `'voice:<session>:<turn>'` |
| `audit_log.request_id` | TEXT (was UUID) | same |

`COALESCE(current_install_id, '')` or `... ILIKE '%' || v || '%'` against UUID raises `22P02 invalid input syntax for type uuid`. Cast `::TEXT` before COALESCE/concatenation.

New columns / uniqueness:

| Column/index | Purpose | Added |
| --- | --- | --- |
| `ai_request_log.session_id UUID` | voice session id; replaces `split_part(request_id,':',2)`; partial idx `idx_ai_request_log_voice_session` on `(feature_key, session_id, created_at DESC) WHERE feature_key='cook_mode_realtime'` | `20260424000003` |
| `UNIQUE(canonical_user_key_hash, request_id)` on `ops_flagged_outputs` | atomic dedup | `20260424000002` |
| `idx_app_users_last_seen_at` partial on `status='active'` | hot path for `stir_ops_list_users` + reactivation | `20260424000003` |
| `cost_anomalies` two-phase dispatch (`dispatched_at`, `sentry_request_id`, `confirmed_at`, `confirm_attempts`) | Sentry outage no longer silently loses alerts | `20260424000004` |

Column CHECK constraints:

| Column | Allowed | Constraint |
| --- | --- | --- |
| `device_installations.apns_environment` | `'production'` OR `'sandbox'` | `device_installations_apns_environment_check` |
| `ops_flagged_outputs.flag_reason` | `length(...) <= 500` | `ops_flagged_outputs_flag_reason_check` |
| `ops_flagged_outputs.context_snapshot_json` | `pg_column_size(...) <= 4096` | `..._context_snapshot_size_check` |
| `ops_flagged_outputs.canned_fallback_json` | `pg_column_size(...) <= 65536` | `..._canned_fallback_size_check` |

iOS `/v1/push/register` must send exactly `'production'` or `'sandbox'` — `'development'` rejected with VAL-01.

**Immutable-migration policy.** Once a migration applies anywhere, its file is immutable. Forward-only fixes via a new dated migration that supersedes via `CREATE OR REPLACE` / `ALTER TABLE`. Supersession documented in both files. Cosmetic fixes forbidden — file a new migration even for typos. Enforced by `scripts/git-hooks/pre-commit` (SCA-242) — any staged `M`/`D`/`R` on `Backend/supabase/migrations/*.sql` blocks the commit; override is `SKIP_PRECOMMIT_MIGRATION_CHECK=1 SKIP_PRECOMMIT_MIGRATION_REASON='SCA-NNN: …'` and is reserved for the security-fix exception below.

**Security-fix + correctness-fix exception.** A landed migration MAY be edited in place when its body is either (a) a live exposure surface (emits secret to log, drops permissions check, hard-codes credential) OR (b) a correctness fix that blocks fresh init (`supabase start` / `supabase db reset` aborts inside the migration on a fresh DB even though the migration was logged as applied on prod against a different prior state). Same constraints in both classes: (1) the active definition lives in a forward-dated migration OR in a later statement of the same migration that re-asserts the desired final state, so semantic intent is preserved; (2) the in-place edit replaces only the broken mechanism — never silently changes the migration's final-state semantics; (3) the original COMMENT names the leak literal or correctness bug, superseder filename (or in-file repair statement), and this exception; (4) commit message states the exception class. Examples: SCA-139 (`20260424000001` SENTRY_DSN log redaction — security class) · SCA-280 (`20260506000001` partial-unique-index INSERT order — correctness-blocks-fresh-init class) · SCA-282 (three same-second filename pairs on `2026-05-08` collided on `schema_migrations.version` PK; renamed `_000006/000007/000008_*` to `_000061/000071/000081_*` — correctness-blocks-fresh-init class. Rename is the in-place edit; bodies byte-identical).

---

## Billing model

- **RevenueCat is entitlement source of truth.** Webhook → `entitlement_snapshots` → app pulls via `/v1/config/bootstrap` on next foreground.
- **Grace period:** 24h local cache if RevenueCat unreachable.
- **Trial:** RevenueCat carries `is_trial`. Show days-remaining in Settings + Plan & Billing. Push at 2 days remaining (opt-in, single send).
- **Intro offer eligibility:** Apple platform enforces one per Apple ID per subscription group. Not our problem.
- **Cohort math:** spec §9. Pro annual year-1 margin ~$4.13/mo after April 2026 pricing — flag before raising voice cap or reducing Pro annual below $139.99.
- **Paywall trigger:** `voice_affordance_tapped` on Free is highest-intent moment. Lead with `stir.premium.annual.trial7`.
- **Voice caps:** Premium 13/mo, Pro 27/mo (ADR 0015; were 20 and 40/60). Pro annual $139.99 because Pro users skew toward the cap; headroom leaves room for founder-discount offer codes during beta.

---

## Telemetry events

Canonical list. Don't invent new names without updating spec §15 AND this file. Property contracts and rationale live in spec §15 — this is the index.

```
app_opened, onboarding_started, onboarding_completed,
camera_permission_result, scan_started, scan_submitted, scan_parse_completed,
ingredient_corrected, constraints_set,
dinner_solve_requested, dinner_solve_completed, suggested_dish_selected,
cook_mode_started, cook_step_advanced, timer_started,
voice_affordance_tapped, cook_turn_submitted, cook_turn_resolved,
voice_session_token_snapshot, voice_session_refreshed,
voice_quota_refund, voice_turn_stuck_watchdog_fired,
substitution_requested, substitution_accepted, voice_substitution_disambiguated, cook_session_completed,
meal_rated, meal_rating_skipped,
pantry_auto_consume_resolved, pantry_tombstone_reaper_ran, pantry_tier_downgrade_reconciled, grocery_list_exported, favorite_saved,
leftovers_dish_selected,
recipe_import_started, recipe_import_completed,
paywall_viewed, trial_started,
purchase_started, purchase_completed, restore_purchases_tapped,
entitlement_state_changed, reactivation_notification_opened,
leftovers_followup_{scheduled,fired,tapped,suppressed},
use_soon_{scheduled,fired,tapped,suppressed},
notification_schedule_rollback_failed, notification_history_decode_failed,
repeat_candidate_card_{shown,dismissed},
sample_showcase_{viewed,exited},
widget_nudge_{shown,dismissed},
app_users_bootstrapped, app_users_merged, deletion_request_submitted,
widget_added, shortcut_run,
ai_request_completed, ai_request_failed,
screen_error_shown, sync_state_changed,
tutorial_{started,step_advanced,completed,skipped}
```

Property notes (full contracts in spec §15):
- `scan_*.image_count` 1..4 (1=singular wire, 2..4=Pro multi-image via `images[]`). Wire field dropped from `PantryParseRequest` (SCA-36) — backend computes from `images?.length ?? 1`. Don't add it back.
- `scan_started.flash_mode` ∈ {off,on,auto}; persisted via `@AppStorage("com.scalinity.stir.scan.flashMode")`; wire 1:1 with `ScanFlashMode.rawValue`.
- `dinner_solve_requested`: `feedback_summary_present:bool`, `recent_meal_count:int` (un-capped total in tier window; `recent_meals[]` wire capped at 10).
- `voice_quota_refund`: server-emitted from `realtime-session/index.ts` at no_active_prompt + mint_failed/mint_unexpected_error sites. `{request_id, reason, upstream_status?}`. distinct_id = `hashCanonicalKey(canonical_user_key)`. Refund branches return BEFORE `logAIRequest()`, no `ai_request_log` join — find via PostHog Insight.
- `meal_rated`: `leftovers_handoff_offered`, `leftovers_handoff_taken` (Premium+ only — Free→paywall via `paywall_viewed.trigger=leftovers_gate`), `leftovers_eligible_free`. `meal_rating_skipped` does NOT carry these.
- `leftovers_dish_selected`: when Premium+ picks a dish from LeftoversRoot. Properties `rank` (1..3), `leftovers_items_count`, `prompt_version`, `source_recipe_plan_id`, `new_recipe_plan_id`.
- `pantry_tier_downgrade_reconciled` (SCA-99 / ADR 0035; effective-tier pair SCA-298): emitted from `EntitlementService.publishReconciliationOutcome` after every detected effective-tier downgrade reconciliation pass — including zero-archive passes. Properties `{previous_tier, new_tier, previous_effective_tier, new_effective_tier, archived_count, total_remembered_pre, total_remembered_post}`. Literal `previous_tier`/`new_tier` are the unmodified RC tiers; `previous_effective_tier`/`new_effective_tier` are the post-billing-state-demotion tiers from `effectiveTier` — Premium trial-expiry emits literal `(premium, premium)` but effective `(premium, free)`, and cohort dashboards must filter on the effective pair. `archived_count == 0` is valid (user was already below the new cap); banner only surfaces when `archived_count > 0`. SCA-298 W21: telemetry is suppressed when `ReconcileOutcome.handlerRan == false` (RootCoordinator dealloc / no-household short-circuit). Counts only — no item names per ADR 0009.
- `tutorial_*`: `tutorial_id` is snake_case `TutorialKey.rawValue` (tonight_tour, scan_capture, scan_review, dinner_options, dish_preview, cook_mode_tap, voice_mode, saved_meals, pantry_management, pantry_in_list_tour, pantry_in_list_tour_empty). `step_advanced` adds `from_step`/`to_step`. Lifecycle invariant: exactly one of {completed, skipped} per started. Disappear non-terminal — `suspend()` emits NO telemetry; tour re-arms when host re-appears. Funnel abandonment = `count(started) − count(completed) − count(skipped)`. No `reason` on `tutorial_skipped`.
- `use_soon_*` (SCA-64, hardened SCA-320): `use_soon_scheduled` carries `{fire_at}` ONLY — `item_display_name` was dropped per ADR 0009 (pantry labels are user content). The notification BODY still uses the display name (user-facing rendering is fine), but telemetry/OSLog/userInfo carry only the pantry item ID. `use_soon_suppressed.reason` ∈ `{weekly_cap, unactioned_streak, recent_session, no_candidate, no_displayable_candidate}` — `no_displayable_candidate` was added by SCA-320 so a missing/empty `displayName` triggers a clean suppression instead of the prior "Use an ingredient before it goes" generic-fallback notification body.
- `notification_schedule_rollback_failed` (SCA-309, expanded SCA-318/SCA-367/SCA-369): emitted from `NotificationSchedulerKit.addWithRollback` on TWO terminal-failure branches (SCA-369 split): (a) primary add throws AND rollback re-add throws (regression — user HAD a schedule and we lost it), (b) primary add throws AND no prior to restore (fresh-user first-schedule failure). Properties `{scheduler_id, identifier, error_reason, prior_existed}`. `scheduler_id` ∈ `{leftovers_followup, use_soon, reactivation}` (SCA-360 typed). `identifier` is the failing `UNNotificationRequest.identifier`. `error_reason` ∈ `{invalidContent, deniedByDevice, systemUnavailable, unknown}` — closed-vocab `RollbackErrorReason` enum (SCA-367, was raw OS-supplied `error_description` string). `prior_existed` (SCA-369) — `true` on regression branch, `false` on cold-start branch. Counts/closed-enum-strings/bools only — no user content per ADR 0009. Single-success branches do NOT emit. Adding a new scheduler that delegates to the kit is a wire-contract change — update `NotificationSchedulerKit.swift` callers, spec §15 clarification, and this list in the same commit.
- `notification_history_decode_failed` (SCA-374, expanded SCA-398): emitted from `NotificationHistoryStore.load()` when the persisted `[Entry]` blob fails JSONDecoder. A decode failure silently resets the rolling-cap state (returns `[]`), reopening the door to over-cap notifications until the next successful save. Pre-SCA-374 the failure only went to OSLog (invisible to PostHog dashboards) — an Entry-shape regression breaking every install would only surface from individual sysdiagnose captures. Properties `{state_key, error_reason}`. `state_key` ∈ `{stir.use_soon.history.v1, stir.leftovers_followup.history.v1}` — discriminates which scheduler's bucket regressed. `error_reason` ∈ `{dataCorrupted, keyNotFound, typeMismatch, valueNotFound, unknown}` — closed-vocab `HistoryDecodeErrorReason` enum (SCA-398, was raw OS-supplied `error_description` string mirroring the SCA-367 retirement on `notification_schedule_rollback_failed`). The blob carries fire dates + bools — no user content per ADR 0009 either way. OSLog warning at `Logger.notifications` level still fires alongside (carries the raw `localizedDescription` under `.private`).

**Ops surface events** (dotted form per ADR 0027):

```
ops_admin.users.{list_queried, detail_viewed, quota_reset, status_changed, force_reauth}
ops_admin.flagged_outputs.{created, resolved}
ops_admin.prompt_versions.rollout
ops_admin.feature_flags.updated
ops_admin.deletion_requests.{list_queried, approved}
```

`deletion_request_submitted` (SCA-61) is server-emitted from `users-delete-request` (distinct_id = canonical_user_key_hash), not iOS. Wired in `Backend/supabase/functions/ops-admin/index.ts` via `emitOpsEvent`. Schema: `docs/telemetry/canonical-properties.md` + ADR 0027.

Anchors:
- `core_success_event`: scan → select → cook within 3 min → rate ≥4
- `voice_conversion_event`: voice_affordance_tapped(free) → paywall_viewed → trial_started → purchase_completed

`paywall_viewed.trigger`: `dinner_solve_quota_exhausted`, `pantry_cap_reached`, `recipe_import_quota_exhausted`, `saved_favorites_gate`, `widgets_gate`, `leftovers_gate`, `multi_image_scan_gate`, `settings_upgrade`, `voice_affordance_tapped`, `voice_cook_quota_exhausted`. Mirrored 1:1 with `PaywallTrigger.telemetryValue`.

PostHog LLM Observability events (`$ai_generation`, `$ai_trace`) are SEPARATE from product events. Every AI call emits both an `ai_request_log` row AND a `$ai_generation` event; link is `$ai_span_id = ai_request_log.request_id`. Privacy: no `$ai_input` / `$ai_output_choices`, no user content, ever (ADR 0009).

---

## Verification flows

```bash
# iOS
xcodebuild test -scheme Stir -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
swiftformat --lint Stir/ ; swiftlint
# Backend
supabase db reset                 # migrations + seed fresh
supabase functions serve          # all edge functions locally
deno test Backend/supabase/functions/
# AI evals (run before committing AI changes)
pnpm run eval:pantry-scan
pnpm run eval:dinner-solve
pnpm run eval:cook-turns          # checks preamble-present rate
pnpm run eval:substitutions       # 100% hard-rule pass required
pnpm run eval:recipe-import
pnpm run eval:grocery
```

When changing a prompt, bump `prompt_versions.version` semver and start `rollout_pct` at 5%.

**Multi-commit verifies in a worktree** must reckon with `supabase start`'s edge-runtime mount being bound to the directory the stack was started in — tests POSTing to edge functions hit the main-checkout's handler code, not the worktree's. Decision tree + Path A skip-list workflow + Path B full-restart workflow + ideal-fix triggers in `docs/runbooks/isolated-worktree-verification.md`.

**Backend/supabase ergonomics** — `cd Backend/supabase` before any `supabase` CLI command (or pass `--workdir Backend/supabase`); running from repo root auto-generates a stray `supabase/` shadowing the real config. First-of-day step: `cp .env functions/.env` so the edge-runtime container can read secrets. Full reference + gotchas + local-vs-prod project ref discipline in `Backend/supabase/README.md`.

---

## Git workflow

**Rule:** every commit gets pushed to `origin/<branch>` in the same session, without asking. Pre-authorized. Solo dev — no PR gate. Amending and `--force-with-lease` to `main` are pre-authorized; both override user-level git rules. Plain `--force` (no lease) still needs explicit confirmation.

**Pre-push gate (SCA-181 + SCA-220):** `scripts/git-hooks/pre-push` runs `xcodebuild test` (~17s) and then `deno test --config Backend/supabase/functions/deno.json --allow-all Backend/supabase/tests/` (~30s) before every push, blocking on failure. The deno stage auto-skips with a loud warn when `localhost:54321` is unreachable (Supabase stack down) — `supabase start` first if you want it gated. Install via `./scripts/install-git-hooks.sh` once per clone. Overrides: `SKIP_PREPUSH_TESTS=1 SKIP_PREPUSH_REASON='…' git push` skips both stages; `SKIP_PREPUSH_DENO_TESTS=1 git push` skips only deno (iOS still runs). The gate that would have caught SCA-176 + SCA-177; the deno side closes the matching backend gap.

**Pre-commit gate (SCA-242 + SCA-89):** `scripts/git-hooks/pre-commit` runs two staged checks. Stage 1 (SCA-242) blocks any staged modification, deletion, or rename of `Backend/supabase/migrations/*.sql`; new dated migrations (`A` status) pass through. Stage 2 (SCA-89) invokes `scripts/pre-commit-checks/exhaustive-switch.py` to detect newly-added enum cases under `Stir/Core/` or `Stir/Shared/` and report any switch site that isn't exhaustive over the new case (and lacks `default:` / `@unknown default:`). Overrides: `SKIP_PRECOMMIT_MIGRATION_CHECK=1 SKIP_PRECOMMIT_MIGRATION_REASON='SCA-NNN: …'` (security-fix exception only); `SKIP_PRECOMMIT_EXHAUSTIVE_CHECK=1` (when xcodebuild's exhaustive check has already verified the change). xcodebuild remains the authoritative exhaustive-switch oracle — Stage 2 fails fast at commit time.

**Post-commit CI (SCA-60 / SCA-90):** `.github/workflows/ci.yml` runs on every `push: branches: [main]` (and on PRs to main): macOS-15 runner builds Stir on iPhone 17 Pro / iOS 26 + runs `StirTests`; ubuntu-24.04 runner runs Deno unit tests on `_shared/` plus `deno fmt --check` and `deno lint`. Edge-runtime / supabase-stack-dependent backend tests are intentionally not in CI (Docker on the runner is slow + flaky); run those locally before merging risky backend changes. Branch protection on `main` is **signal-not-block** — Daniel ships solo and sometimes pushes hotfixes around CI; the workflow surfaces failures via GitHub's default email-on-failed-action notification rather than gating the push. If the email gets noisy, swap to a Slack webhook step in the workflow.

---

## Linear issue workflow

**Rule:** every work item Daniel raises — bug, issue, feature request, even conversational — gets a Linear issue under the **Stir** project (Scalinity team, key `SCA`) **before** writing code. Pre-authorized; do not ask.

**Beta-tester feature asks DO NOT get Linear issues.** During the beta window the no-new-features invariant holds: log the ask to `docs/roadmap/v2.md` §1 (one line: date + anon tester ID + literal ask) and move on. Asks that recur across 3+ distinct testers are the signal to surface to Daniel — not the first ask, not the second.

Flow: (1) `mcp__linear-server__save_issue` with `team:"Scalinity"`, `project:"Stir"`, `assignee:"@scalinity"`, `state:"In Progress"`, populated repro/root cause/fix plan/files — before any edits. (2) Implement; run test/eval; verify repro gone. (3) `save_issue` `id:"SCA-N"`, `state:"Done"` the instant fix lands locally and tests pass. (4) Stage, commit (`fix(scope): subject (SCA-N)`), push.

**States**: `Backlog | Todo | In Progress | In Review | Done | Canceled | Duplicate`. Never leave `In Progress` across sessions. **Work item** = UI bug, crash, regression, copy/UX nit, design fidelity gap, perf complaint, missing feature, follow-up from review. Idea-stage brainstorming explicitly flagged "thinking out loud" / "don't act yet" is the only opt-out — confirm before skipping.

**Issue body must include:** repro, expected vs actual, root cause (if known), proposed fix with file:line refs, test plan, files-touched. Agent picking up should ship without re-investigating.

**Don't:** duplicate issues for same bug in one session; reopen Done (open new + link via `related`); create outside Stir without redirection.

---

## Deploy workflow — local and prod in lockstep

**Rule:** every change that lands locally must also land on Stir prod Supabase, in the same session, without asking. Pre-authorized.

**Prod project:** `ktqajarcomzplnpbczfo` ("Stir", West US Oregon). Shell exports `SUPABASE_URL=https://zfaucivtzfwnrijsbfug.supabase.co` — that's **MindFriend**, separate project. Always pin via `supabase link --project-ref ktqajarcomzplnpbczfo` before pushing. Confirm `supabase migration list` aligns local+remote.

| Local action | Prod follow-up (same session) |
| --- | --- |
| New migration applies cleanly via `supabase db reset` | `supabase db push` |
| `supabase functions serve --env-file .env` smoke tests pass | `supabase functions deploy <name>` per changed function |
| New secret referenced via `Deno.env.get` | `supabase secrets set <KEY>=<VALUE>` on prod **before** deploying the function that reads it |
| Prod DDL lands | `get_advisors` (security + performance) — fix WARN+ in follow-up migration same session; INFO `rls_enabled_no_policy` on `app_users`/`feature_flags`/`prompt_versions` is by-design deny-all, leave it |

**Auto-injected** in deployed Edge Functions (never set manually): `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_DB_URL`. **Set manually on prod** before first deploy: `STIR_JWT_SECRET` (= prod's `jwt_secret`); `GEMINI_API_KEY` (paid-tier).

**Never push to prod:** docs-only or iOS-only commits. Only schema + function changes trigger lockstep.

---

## Voice validation plan

April 2026 spike ran the **expensive half** (UX validation) producing `FINDINGS.md`. The **cheap half** (API drift check) still runs at step 6 start.

**Cheap half** (~1h, terminal): (1) `curl POST .../v1alpha/authTokens` → 200 + `token`; (2) WS open with `Authorization: Token`, confirm setup-complete; (3) PCM16 audio frame via `realtimeInput.audio`, no protocol error; (4) `usageMetadata` audio metering still 25 tok/sec both ways; (5) pricing on ai.google.dev/gemini-api/docs/pricing matches CLAUDE.md; (6) re-test mint with API-key auth from Edge Function environment; (7) on drift, update spec §12 + this file before writing Cook Mode code.

**Expensive half — in-app validation gate, start of step 6:**

1. **TTFA Wi-Fi split gate** on `cook_turn_resolved.result_type` (ADR 0012): TTFA(`normal`) p95 < **500 ms** AND TTFA(`tool_call`) p95 < **1500 ms** across 20 turns. Anchor: last pre-audio `inputTranscription` → first `modelTurn.parts[].inlineData` chunk. Revisit after 2 weeks beta if either at ≥80%.
2. **Preamble-present rate at MINIMAL ≥ 70%** across 50 tool-call invocations. Lower → disable model preambles, rely on client clip alone.
3. **Client-side filler fires within 150ms of `toolCall` arrival** and masks the 2s round-trip in 95%+ of substitutions.
4. **Refresh-bounded growth holds.** 30-turn scripted session: `refreshSession()` fires at turns 10/20/30. Per-turn prompt tokens grow linearly within each window (~6-7k fresh → ~13-15k at turn 10) and RESET to baseline after each refresh. Still growing past turn 10 without a refresh event → trigger broken. Refresh fires but tokens don't drop → recap/setupComplete misbehaving.
5. **Refresh is silent.** Mic mute window ≤ 5s; user speech during refresh dropped until mic forwarding restarts.

If 1 or 4 fail materially, stop and escalate — architectural, not tuning. 2/3/5 are tunable.

## Build order

1. Supabase project + migrations + `/v1/session/bootstrap` + `/v1/config/bootstrap`.
2. Core Data + CloudKit container + HouseholdProfile + onboarding. No AI yet.
3. Scan + Solve with `gemini-3-flash-preview`. Aha-moment slice. **Spec §13 IP-based rate limiting lands here.**
4. Saved meals + tap-based Cook Mode. Full Free-tier product.
5. RevenueCat + paywall + entitlements (annual trial primary CTA).
6. Cook Mode voice (Premium+). **Cheap-half drift check first**, then in-app validation gate, before any UX polish.
7. Imports, widgets, shortcuts, leftovers.
8. Telemetry dashboards, ops console, Sentry. **[Shipped 2026-05: ops console, ops dashboards, Sentry wiring, APNs iOS-side registration (SCA-316). Remaining: PostHog product-funnel queries (SCA-331).]**
9. Beta.

Each step ends in something demoable. Don't interleave. **Risk:** steps 1–5 build toward Premium-tier economics that assume voice works. If step-6 validation uncovers a fundamental Gemini Live problem, Free is unaffected but Premium's core promise needs rework.

---

## Deferred work

Tracked tech debt + triggered refactors live in `docs/deferred-work.md`. Read before assuming nothing is owed. Active categories: pre-launch chrome polish; v1.1/pre-public-launch backend; step-9 ops hardening; triggered-by-next-touch (RealtimeSession 3-part split, CookModeViewModel telemetry extraction, VoiceSessionDriver/State splits, Clock injection); build/CI hygiene; hard-pinned earlier deferrals (IP rate limiting, Gemini Live API drift re-check, mint endpoint auth re-test, CloudKit identity verification, ActivityKit Live Activity); test-correctness debt; documentation drift.

---

## Working-with-Daniel rules

- Daniel is ex-MindFriend (747-file Swift codebase shipped in 30 days). Assume expert familiarity with iOS, Swift Concurrency, Core Data, CloudKit, Supabase, AI infra.
- **Default to comprehensive.** Build the full thing — error handling, edge cases, typed Swift models, production-minded from step 1. Don't ask "MVP or comprehensive?" unless he says "quick", "prototype", "sketch", or equivalent.
- **Log assumptions inline.** `// Assuming X because Y. Flag if wrong.` — not in a summary at the end.
- **Root-cause before patching.** When a fix isn't improving the diagnosis, stop and reframe from first principles. Don't iterate politely into a dead end.
- **Audit prior artifacts with the same rigor as new work.** If past-Claude got something wrong in spec or code, say so directly. Prior outputs aren't ground truth.
- **Challenge bad calls.** One direct sentence beats three diplomatic paragraphs.
- **Don't silently drop features.** If a planned feature turns out infeasible mid-build, stop and tell Daniel. Never make compilation pass by dropping scope.
- **Run the existing tests in a test file before adding a new one.** Pre-existing red surfaces only after the new test compounds the diagnostic load — twice now: P1-N session had 4 red `realtime_session_test.ts` tests masked by `all_steps` schema drift; P1-O session had 7 red `voice_turn_usage_test.ts` tests masked by missing Premium-promote + `session_closed` assertion drift. Smoke the file first, fix the red, then add. Hook enforcement deferred to SCA-156 follow-up if the rule fails to stick.
- Tables for comparisons, diagrams for systems, prose only when it earns its place.

---

## Test seams (cheat sheet)

Reach for these BEFORE introducing a protocol abstraction or rewriting production code for testability. Each was discovered the hard way; documenting so the next agent skips the discovery cost.

- **PostHog telemetry capture** — `PostHogClient` exposes a DEBUG-only `init(testingOnly: Bool)` (`Stir/Integrations/PostHog/PostHogClient.swift:141`) that bypasses the production SDK wiring; `capture(_:properties:)` is non-final + internal. Subclass + override `capture` to assert on emitted events; **don't** introduce a `TelemetryProtocol` for this. Pattern in use: `SpyPostHogClient` in `StirTests/Unit/NotificationSchedulerKitTests.swift` (SCA-345). Compile gotcha: don't mark the subclass `@MainActor` — the override must match the parent's nonisolated context; use `@unchecked Sendable` + `NSLock` for the capture buffer instead.
- **Expiring-pantry-item fixture (UseSoonScheduler + anything reading `PantryItemRepository.fetchExpiringSoon`)** — canonical seed: `PersistenceController(inMemory: true)` viewContext + a `Household` + a `PantryItem` with `id = UUID()`, `typedMemoryState = .ephemeral`, `expiresAt = now + 24h`, `deletedAt = nil`. Predicate filter is `.ephemeral` + `deletedAt == nil` + `expiresAt in (now, now+48h]`. Same shape as `PantryTombstoneReaperTests.seed(...)`. `UseSoonScheduler`'s repo deps are concrete types, not protocols — wire the in-memory PC directly.
- **CK-verified canonical key over HTTP (`ck:<record>` instead of `install:<uuid>`)** — pass BOTH `cloudkit_user_record_name` AND `cloudkit_web_auth_token: STUB_CLOUDKIT_WEB_AUTH_TOKEN` (`Backend/supabase/tests/_helpers/factory.ts`) to `quickBootstrap`. With no `CLOUDKIT_API_TOKEN` in local `.env` the verifier hits the `verifier_unconfigured` carve-out (trust-mode) → record_name preserved → key resolves `ck:`. This is the only HTTP-level path to a verified-CK shape until the bootstrap accepts a `fetchImpl` DI override (deferred; tracked in `session_bootstrap_test.ts` header). All `ck:` alias-forward tests in `session_bootstrap_test.ts` remain `ignore: true` until that DI lands. SCA-349.

---

## What NOT to reopen / What NOT to do

**Settled (don't re-argue unless Daniel asks):** Google-only AI (no OpenAI/Anthropic fallback); Supabase backend (not Cloudflare Workers/Firebase/custom Node); Core Data + CloudKit (not SwiftData); iOS 17 minimum; Voice = Premium+; annual trial primary paywall CTA; `thinkingLevel: minimal` for voice (escalate to LOW only if eval fails); RevenueCat (not pure StoreKit 2); no mandatory login (not SIWA-required); English/US-only launch (no i18n v1); no desktop/web companion; Zod for Edge Function validation (not Valibot); `usage_counters.cap_count` snapshot-at-creation; `app_users.status` and `entitlement_snapshots.billing_state` as native Postgres ENUMs with partial indexes. If Daniel asks "should we switch to X?", engage. If independently considering a switch, surface the question first.

**Wrong paths that look right until they bite:**

- Don't put any provider API key in the iOS bundle, under any framing. Don't add cached-input pricing to Gemini Live cost estimates (not supported). Don't write user content to Supabase Postgres (CloudKit-only).
- Don't use `response.create` or OpenAI-Realtime patterns — Gemini auto-continues after function responses. Don't send in-session text via `BidiGenerateContentClientContent` on 3.1 Flash Live (use `realtimeInput.text`). Don't send function responses via `clientContent` (use `BidiGenerateContentToolResponse` with matching `functionResponse.id`). Don't assume `Authorization` uses `Bearer` — it's `Token`.
- Don't reference `gpt-realtime`, `GPT-5.4`, or OpenAI outside `docs/decisions/` as rejected-alternative context.
- Don't use `@FetchRequest` in new code (use Repository + observed view model). Don't hardcode entitlement tier strings in views — go through `EntitlementService`. Don't derive `voice_enabled` on iOS (server-computed). Don't use object-keyed `quotas` (always array).
- Don't add new telemetry event names **or new property values on existing events** without updating spec §15 and this file (e.g. new `result=busy` on `voice_affordance_tapped` is a wire-contract change). Don't invent new error codes — use the matrix; new codes require updating this file + spec §6. Don't return 4xx/5xx with empty body or string-only error.
- Don't skip the hard-rule validator on substitution output. Not optional.
- Don't use UIKit unless wrapping `AVCaptureVideoPreviewLayer` via `UIViewRepresentable` (SwiftUI-first). Don't add a second LLM provider as "insurance" — revisit only if Gemini downtime exceeds 2x SLA for a quarter.
- Don't use aggregate assertions (COUNT, SUM without WHERE) in integration tests. No `beforeEach` TRUNCATE or transaction-rollback wrappers. Don't assert HTTP 403 in RLS isolation tests (assert `length === 0`).
- Don't hard-delete `app_users` rows (mark `status='merged'` or `'banned'`). Don't refresh `usage_counters.cap_count` on tier upgrade.
- **Don't use Morph for semantic-tracked files.** `CLAUDE.md`, `Specs/*.md`, `docs/decisions/*.md` (ADRs), and `docs/decisions/TEMPLATE.md` are edited via native `Edit`/`Write` only — exact-string matching, verifiable per call. Morph has silently dropped subsections + introduced drift. Other code files use Morph per global tooling rule.

---

## When in doubt

1. Check the spec (`Specs/Stir-Full-Spec.md`).
2. Check the Cook Mode research doc for anything voice-related.
3. If spec and this file disagree, spec wins. Tell Daniel about the discrepancy.
4. If genuinely ambiguous, surface the decision rather than picking silently.
5. If about to write code that violates a north-star constraint, stop. They aren't negotiable.
