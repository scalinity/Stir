# CLAUDE-Constants.md — Stir Pre-filled Constants

Reference companion to `CLAUDE.md`. Holds the load-bearing constants, JSON shapes, code blocks, and aliasing/usage-counter semantics. CLAUDE.md points here.

## AI models and pricing

Text runs on Claude, voice on OpenAI Realtime, Gemini only as a text fallback (ADR 0038). Backend model enums (`Backend/supabase/functions/_shared/claude.ts`, `gemini.ts`, `realtime_mint.ts`):

```ts
enum ClaudeModel { Haiku = 'claude-haiku-5-5', Sonnet = 'claude-sonnet-5-5' }
enum GeminiModel { Flash = 'gemini-3-flash-preview', FlashLite = 'gemini-3.1-flash-lite' }  // text fallback only
enum OpenAIRealtimeModel { Mini = 'gpt-realtime-2.1-mini' }
```

Per-feature text models (`_shared/ai_text.ts`). The `AI_TEXT_PROVIDER` secret ∈ {`anthropic` (default), `gemini`} picks the column for **every** endpoint at once; there is no per-request cross-vendor fallback. An unrecognized value throws at the first call.

| `feature_key` | `anthropic` (default) | `gemini` |
| --- | --- | --- |
| `pantry_parse` | `claude-haiku-5-5` | `gemini-3-flash-preview` |
| `dinner_solve` | `claude-haiku-5-5` | `gemini-3-flash-preview` |
| `substitution` | `claude-sonnet-5-5` | `gemini-3-flash-preview` |
| `recipe_step_rewrite` | `claude-haiku-5-5` | `gemini-3-flash-preview` |
| `cook_turn` | `claude-haiku-5-5` | `gemini-3-flash-preview` |
| `recipe_import` | `claude-haiku-5-5` | `gemini-3.1-flash-lite` |
| `grocery_generate` | `claude-haiku-5-5` | `gemini-3.1-flash-lite` |

`claude-sonnet-5-5` is the escalation model: a feature moves to it only when the parity check shows Haiku failing (ADR 0038). Substitution runs on it: on `eval_substitutions_v1` with prompt v1.2.0 Sonnet passes 48/50 against Haiku's 42–43/50. Claude calls use the official SDK with structured output through `output_config.format` (`json_schema`), no forced `tool_choice`, no prefill, no sampling parameters, SDK retries off; `stop_reason` is checked for `refusal` and `max_tokens` before content is read. Images: JPEG, PNG or WebP.

Per 1M tokens, from `MODEL_PRICING` in `_shared/ai_request_log.ts` (sources and retrieval dates in ADR 0038):

| Model | Text in | Text in cached | Cache write | Audio in | Audio in cached | Image in | Text out | Audio out |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `claude-haiku-5-5` | $0.10 | $0.01 | $0.125 | — | — | $0.10 | $0.50 | — |
| `claude-sonnet-5-5` | $2.00 | $0.10 | $2.50 | — | — | $2.00 | $10.00 | — |
| `gemini-3-flash-preview` | $0.50 | $0.05 | — | $1.00 | — | $0.50 | $3.00 | — |
| `gemini-3.1-flash-lite` | $0.25 | $0.025 | — | $0.50 | — | $0.25 | $1.50 | — |
| `gpt-realtime-2.1-mini` | $0.60 | $0.06 | — | $10.00 | $0.30 | $0.80 | $2.40 | $20.00 |

Claude rates apply to prompts up to 100K tokens (Haiku 5.5 doubles above that; no Stir prompt approaches it). Realtime audio tokens: user audio **10 tokens/second**, model audio **20 tokens/second**. `gpt-realtime-2.1` (full; audio in $32, cached audio in $0.40, audio out $64) is the escalation path if mini misses tool calls in device testing; it is not wired up.

## Cost model (ADR 0038; caps and prices unchanged)

Voice Cook Session caps stay Free 0 / Premium 13 / Pro 27 (ADR 0015); SKU prices and margins are unchanged. Premium AI budget $1.89/mo, Pro $3.69/mo, Free $0.075/mo. Assumptions: 15 turns, 3 tool-call turns, 3,300-token static text prefix, 3.8 s user speech and 5.0 s model speech per turn, input transcription on.

| Voice option | 15-turn session, 90% cache hits | no caching | Premium 13 / Pro 27 per month (cached) |
| --- | ---: | ---: | --- |
| `gpt-realtime-2.1-mini` | $0.085 | $0.254 | $1.11 / $2.31 |
| `gpt-realtime-2.1` (escalation) | $0.294 | $0.944 | $3.82 / $7.93 |

Text rates are about 5× lower per token than Gemini Flash (Haiku 5.5 $0.10 / $0.50 vs $0.50 / $3.00 per 1M). Voice on mini stays inside the Premium and Pro AI budgets only while the cache hit rate holds; without caching, 13 sessions at $0.254 cost about $3.30/mo. OpenAI caches the conversation prefix automatically (best-effort) and a session refresh discards that cache, so the voice cache hit rate is the key voice cost signal. Promotional credits are held on both the Anthropic and OpenAI platforms; amounts and expiry dates are unknown, so these rates are what Stir pays once the credits run out.

Observability: per-turn `prompt_tokens_cached` (cached text) and optional `prompt_tokens_cached_audio` (cached audio) on `/v1/ai/voice-turn-usage`; `ai_request_log.prompt_cached_tokens` and PostHog `$ai_cache_read_input_tokens` carry cached text + cached audio. Cached text and cached audio are priced at their own cached rates.

Retry-once disabled (SCA-36 W4) so schema-validation failure costs 1× → AI-02. `pantry_parse` unmetered per-user; bounded by `ip:pantry_parse_daily=100`. **If 95th-pct per-IP daily pantry-parse cost crosses $0.50, file ADR to revisit IP cap or add `user:pantry_parse_daily` at Pro.**

## StoreKit SKUs

```
stir.premium.monthly          $9.99/mo     no trial
stir.premium.annual.trial7    $69.99/yr    no trial (`.trial7` suffix historical, see SCA-294)
stir.pro.monthly              $14.99/mo    no trial
stir.pro.annual               $139.99/yr   7-day free trial (PRIMARY paywall CTA, post-SCA-294)
```

Group `stir.subscriptions`. Family Sharing **off** all SKUs. **Apple fees:** Y1 non-SMB 30%; Y2+ 15%; SMB Program 15% from Y1 (check eligibility near launch).

## Tier entitlements (authoritative)

| Entitlement | Free | Premium | Pro |
| --- | --- | --- | --- |
| Dinner Solves / mo | 6 | 40 | 120 |
| Tap Cook Sessions | unlimited | unlimited | unlimited |
| Voice Cook Sessions / mo | **0** | **13** | **27** |
| Recipe Imports / mo | 2 | unlimited | unlimited |
| Remembered pantry items | 25 | 250 | 1000 |
| Cook Mode voice | no | yes | yes |
| Substitution Sheet (text) | yes | yes | yes |
| Saved favorites | no | yes | yes |
| Widgets | no | yes | yes |
| Shortcuts / App Intents | no | yes | yes |
| Leftovers mode | no | yes | yes |
| Multi-image scan | no | no | yes |
| Priority inference queue | no | no | yes |
| Preference memory window | 30 days | 90 days | 365 days |

**Preference memory** (ADR 0030): iOS `PreferenceMemoryService` reads `OutcomeFeedback` from CloudKit, projects bounded digest (≤600 prompt tokens), sends as `feedback_summary` on `/v1/ai/dinner-solve`. Server kill switch `feature_flags.preference_memory_enabled` (default true). Tier window enforced on iOS — out-of-window ratings never leave device.

## Realtime voice session constants

OpenAI Realtime, `gpt-realtime-2.1-mini` (ADR 0038). Backend session defaults attached to the mint (`_shared/realtime_mint.ts`):


ADR 0041 retains direct iOS-to-OpenAI voice. A client secret can open multiple upstream sessions until expiry, and connection configuration can override its attached defaults. The 400-token output cap is applied by the supported app; mint quotas do not enforce downstream connection count or spend. Quota-free continuations require a ready owned predecessor, matching cooking session, original charge proof, root age below two hours and predecessor age below 65 minutes; one pending successor is claimed atomically.

```ts
REALTIME_SECRET_TTL_SEC     = 120   // window in which the client secret can open a session
REALTIME_MAX_OUTPUT_TOKENS  = 400   // ADR 0010: session max_output_tokens
REALTIME_TRUNCATION = { type: 'retention_ratio', retention_ratio: 0.8,
                        token_limits: { post_instructions: 8000 } }
// OpenAI session maximum: 60 minutes. Mint call: 10 s timeout, SDK retries off.
// Session config: reasoning.effort ∈ {minimal, low} (flag cook_voice_thinking_level),
// output_modalities ['audio'], voice 'marin', PCM16 mono 24 kHz in and out,
// input noise_reduction far_field, input transcription 'gpt-transcribe',
// tool_choice 'auto', safety identifier = hashed canonical user key.
// Turn detection (flag voice_turn_detection_mode), both with create_response true and
// interrupt_response false (half-duplex mic gate, ADR 0011):
//   semantic_vad: eagerness 'auto'
//   server_vad:   threshold 0.6, prefix_padding_ms 300, silence_duration_ms 800
// Tools: substitution_check, start_timer, get_timer_status, pause_timer,
//        resume_timer, cancel_timer, restart_timer, set_step
```

Wire: `POST /v1/ai/realtime-session` → `{auth_token, expires_at, session_id, ws_url, prompt_version, setup_frame_json}`. `auth_token` is the `ek_` client secret from `POST https://api.openai.com/v1/realtime/client_secrets`; `ws_url` is `wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini`; iOS connects with `Authorization: Bearer <auth_token>`. `setup_frame_json` is a `session.update` frame carrying the truncation policy and is the first client message; the `session.updated` reply is the handshake ack. A tool result starts no response by itself: iOS sends `response.create` after `function_call_output`.

iOS (`Stir/Integrations/GeminiLive/RealtimeSession.swift`):

```swift
enum LiveSessionBudget {
    static let setupHandshakeSec: Double              = 5        // wait for session.updated
    static let turnCompleteSec: Double                = 30       // wait for response.done
    static let refreshAtSessionAgeSec: TimeInterval   = 55 * 60  // only proactive refresh trigger (ADR 0038)
    static let preMintAtSessionAgeSec: TimeInterval   = 54 * 60  // mint the next secret one minute ahead
    static let preMintStalenessSec: TimeInterval      = 90       // discard an older pre-minted secret
    static let clientSecretMinRemainingSec: TimeInterval = 15    // min time left on a secret to use it
    static let turnStuckWatchdogSec: TimeInterval     = 15       // .modelSpeaking with no audio
}
```

Server truncation bounds per-turn prompt growth, so there are no turn-count or prompt-token refresh triggers. Refresh runs only near the 60-minute session limit and for transport recovery, because a refresh opens a new session and discards the prompt cache.

## Endpoints

Supabase (`$SUPABASE_URL/functions/v1`):

```
POST /v1/session/bootstrap
GET  /v1/config/bootstrap
POST /v1/ai/pantry-parse
POST /v1/ai/dinner-solve
POST /v1/ai/realtime-session      # mints OpenAI Realtime client secret
POST /v1/ai/cook-turn             # text fallback for voice
POST /v1/ai/substitution          # also called from Realtime function-call round-trips
POST /v1/ai/recipe-step-rewrite   # SCA-432 — post-accept prose rewrite of current step
POST /v1/ai/recipe-import
POST /v1/ai/grocery-generate
POST /v1/push/register
POST /v1/revenuecat/webhook
POST /v1/ops/flag-output
*    /v1/ops/admin/*              # Supabase Auth admin role + RLS
```

Providers (Edge Functions only; iOS only opens the OpenAI Realtime WebSocket):

```
Anthropic Messages API via @anthropic-ai/sdk       # all text features (client.messages.create)
POST https://api.openai.com/v1/realtime/client_secrets          # Realtime mint (Edge Function)
WSS  wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini   # iOS, Authorization: Bearer <ek_ secret>
POST https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent       # fallback, AI_TEXT_PROVIDER=gemini
POST https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent        # fallback, AI_TEXT_PROVIDER=gemini
```

## Error code matrix

User-visible messages in spec §6.

```swift
enum ErrorCode: String {
    case net01="NET-01"            // network unreachable (URLSession; no response)
    case internal01="INTERNAL-01"  // 500-class server error
    case ai01="AI-01", ai02="AI-02", ai03="AI-03"  // unavailable / low confidence / slow
    case aiVoice01="AI-VOICE-01"   // realtime voice down (or disable_cook_realtime), text fallback active
    case import01="IMPORT-01"      // recipe import parse failed
    case permCam01="PERM-CAM-01", permMic01="PERM-MIC-01"
    case permPhoto01="PERM-PHOTO-01", permRem01="PERM-REM-01"
    case sync01="SYNC-01"          // iCloud unavailable
    case rate01="RATE-01"          // quota exhausted
    case bill01="BILL-01"          // entitlement uncertain
    case pay01="PAY-01"            // purchase failed
    case entVoice01="ENT-VOICE-01", entMultiImage01="ENT-MULTI-IMAGE-01", entLeftovers01="ENT-LEFTOVERS-01"
    case voiceSession01="VOICE-SESSION-01"
        // session_missing/owner_mismatch/session_closed(403)/lookup_failed(500). ADR 0017.
    case val01="VAL-01"            // request body failed Zod validation (client bug)
    case auth01="AUTH-01"
        // missing/expired/malformed/signature_invalid/user_stale/reauth_required.
        // First 5 → silent re-bootstrap; reauth_required → SIWA re-flow (ADR 0023).
    case methodNotAllowed01="METHOD-NOT-ALLOWED-01"  // 405, client bug, never user-visible
}
```

## VAL-01 (400) and AUTH-01 (401) shapes

```json
// VAL-01
{ "error":"VAL-01", "message":"Request body failed validation: 'installation_id' must be a UUID",
  "field_errors":[{ "field":"installation_id", "issue":"Expected UUID, got 'abc123'" }] }
// AUTH-01
{ "error":"AUTH-01", "message":"Session expired or missing",
  "reason":"expired"|"missing"|"malformed"|"signature_invalid"|"user_stale"|"reauth_required" }
```

VAL-01: `message` dev/Sentry-facing; `field_errors` structured for iOS dashboards/tests. iOS logs to Sentry `error` with full `field_errors`; shows generic copy via `ErrorPresenter`; **do not retry**; do not cache. Server logs `warn`.

AUTH-01:

| `reason` | Cause | iOS action | Server log |
| --- | --- | --- | --- |
| `missing` | No `Authorization` header | Silent re-bootstrap | `info` |
| `expired` | JWT past `exp` | Silent re-bootstrap | `info` |
| `malformed` | Invalid JWT structure | Re-bootstrap + Sentry error | `error` |
| `signature_invalid` | Signature doesn't verify | Re-bootstrap + Sentry + alert at threshold | `error` |
| `user_stale` | `canonical_user_key` doesn't resolve | Silent re-bootstrap | `info` |
| `reauth_required` | JWT.iat predates `app_users.reauth_required_at` | **SIWA re-flow** (rotate Keychain install_id, clear canonical key) | `info` |

Silent-refresh (all except `reauth_required`): clear cached JWT, re-bootstrap, retry **once**. If retry also 401s, surface NET-01 — never retry-storm. `reauth_required` → `ReAuthenticationIntent.forceReauth` → SIWA. `reason` is a typed field, not parsed from `message`.

## Canonical user key

```
canonical_user_key = "ck:<userRecordName>" | "install:<keychainInstallId>"  // ck if available, else fallback
```

When `install:` user gains CloudKit, **alias forward** in RevenueCat and `app_users.merged_into`. Never back-fill user content; always alias forward.

## Aliasing when install:<id> gains CloudKit AND ck:<record> has rows

Reinstall + same iCloud, or sign-out/sign-in mid-session, produces two rows with data. Merge in one Postgres transaction:

| Table | Merge rule |
| --- | --- |
| `usage_counters` | **SUM** `used_count` per `(period_start, feature_key)` onto ck row; delete install rows |
| `entitlement_snapshots` | **ck wins** (RevenueCat webhook keyed on ck) |
| `ai_request_log` | UPDATE `canonical_user_key` install→ck (preserves cost attribution) |
| `device_installations` | UPDATE install→ck |
| `app_users` (install) | SET `merged_into=ck`, `status='merged'`; **never hard-delete** |
| `app_users` (ck) | Winning row; update `last_seen_at` |

**Don't clamp summed quotas to cap** (install=5/6 + ck=4/6 → 9; clamping = abuse vector). **RevenueCat re-alias runs AFTER DB transaction commits** (external call failure shouldn't roll back; retry via background job). **Merge runs synchronously in `/v1/session/bootstrap`** — async risks phantom quota. Transaction failure twice → `VAL-01` with merge-failure detail in `message`, log Sentry `error`.

## `app_users.status`: `active | merged | banned` (native ENUM, partial idx where ≠ active)

| From | To | Trigger |
| --- | --- | --- |
| `active` | `merged` | Identity alias-forward in `/v1/session/bootstrap` |
| `active` | `banned` | Admin via `/v1/ops/admin/*` |
| `merged` | — | **Terminal** (can't un-sum counters) |
| `banned` | `active` | Manual admin unban |

Bootstrap: `merged` → follow `merged_into` one hop (nested = bug); `banned` → 403 + `BILL-01`. Never soft-delete; deletion is hard-delete per CCPA (spec §11).

## `entitlement_snapshots.billing_state`: `none | active | trial | grace | cancelled_active | expired`

Native ENUM, partial idx where ≠ none. **Orthogonal to `tier`:** tier says *what*; billing_state says *why* and what to show.

- `none` (free, never purchased) · `active` (paid, current) · `trial` (intro offer, Premium annual only)
- `grace` (Apple billing retry; user retains paid access; iOS shows BILL-01 banner)
- `cancelled_active` (cancelled; access until period_end) · `expired` (paid access ended, eligible for win-back; distinct from `none`)

RevenueCat webhook → state:

| Event | Transition |
| --- | --- |
| `INITIAL_PURCHASE` w/ intro | `none|expired` → `trial` |
| `INITIAL_PURCHASE` no intro | `none|expired` → `active` |
| `RENEWAL` | `trial|active|cancelled_active` → `active` |
| `CANCELLATION` | `active|trial` → `cancelled_active` |
| `UNCANCELLATION` | `cancelled_active` → `active` |
| `BILLING_ISSUE` | `active` → `grace` |
| `EXPIRATION` | `cancelled_active|grace|trial` → `expired` |
| `PRODUCT_CHANGE` | `active` → `active` (tier separately) |

Bootstrap: `none|expired` → Free; others → paid per `tier`; `grace` adds `billing_retry_banner: true`.

## `usage_counters` semantics

Metered (native ENUM): `dinner_solve | voice_cook_session | recipe_import`. Not metered: `remembered_pantry_items` (standing cap, client-enforced); `scan_parse`, `substitution`, `grocery_generate`, `cook_turn` (cost in `ai_request_log` only).

**`cap_count` SNAPSHOTTED at row-creation** from active tier. Mid-month upgrade does **not** refresh existing period rows. Non-metered Premium entitlements (voice access, favorites, widgets) unlock immediately; metered quotas catch up next period. Paywall copy: "You'll get full Premium Dinner Solves at your next monthly reset on <date>." Refresh-on-upgrade would create abuse vector and webhook/increment race; snapshot is atomic.

```sql
-- Atomic quota check (the reason cap_count lives here, not derived via JOIN)
UPDATE usage_counters SET used_count = used_count + 1, updated_at = now()
 WHERE canonical_user_key=$1 AND period_start=$2 AND feature_key=$3 AND used_count < cap_count
RETURNING used_count, cap_count;
```

One round trip, no race, no join. Empty return = capped. **`period_start`** uses `app_users.created_at` month-day as anchor (joined on the 17th → monthly periods start on the 17th). No mid-month cliff for new signups; matches Apple's renewal pattern.

## `/v1/session/bootstrap` response

```json
{
  "session_jwt": "<jwt, 24h TTL>",
  "canonical_user_key": "ck:<record>" | "install:<id>",
  "is_new_user": true | false,
  "entitlements": {
    "tier": "free"|"premium"|"pro",
    "billing_state": "none|active|trial|grace|cancelled_active|expired",
    "is_trial": true | false,
    "expires_at": "2027-04-18T00:00:00Z" | null,
    "voice_enabled": true | false,
    "billing_retry_banner": true | false,
    "quotas": [{ "feature_key":"dinner_solve", "used":3, "cap":6, "period_end":"2026-05-17" }]
  },
  "feature_flags": [{ "key":"disable_cook_realtime", "value":false, "is_enabled":true, "rollout_pct":100 }]
}
```

Shape rules:
- Bootstrap does NOT return `prompt_versions` (that's `/v1/config/bootstrap` only).
- `voice_enabled` is **SERVER-COMPUTED** (`tier IN ('premium','pro') AND billing_state IN ('active','trial','grace','cancelled_active')`), never iOS-derived.
- `quotas` is an **array** (iterable); fields `used`/`cap`/`period_end` (not `used_count`/`cap_count`/`period_start`); `period_end` always included, never client-computed.
- `feature_flags` array of metadata objects, not flat map.
- Single `expires_at` covers trial + subscription end; `is_trial` disambiguates. Nested `entitlements`. Timestamps absolute UTC; iOS localizes.

## Rate-limit scopes (`Backend/supabase/functions/_shared/rate_limiter.ts`)

Per-endpoint IP/user buckets. Add a new scope when adding a new endpoint; the policy lives next to the union in `rate_limiter.ts`.

```
ip:dinner_solve_daily               # 30/day
ip:pantry_parse_daily               # 100/day
ip:substitution_daily               # 50/day
ip:recipe_step_rewrite_daily        # 100/day — SCA-432; 2× upstream substitution cap with headroom for double-tap + same-step re-cook
ip:cook_turn_daily                  # 300/day
ip:bootstrap_hourly                 # 20/hour
ip:recipe_import_daily              # 40/day
ip:grocery_generate_daily           # 100/day
ip:push_register_hourly             # 20/hour
ip:voice_turn_usage_daily           # 2000/day
ip:realtime_session_daily           # see rate_limiter.ts
ip:ops_admin_hourly                 # see rate_limiter.ts
ip:users_delete_request_hourly      # see rate_limiter.ts
user:dinner_solve_hourly            # 10/hour
user:voice_turn_usage_hourly        # 500/hour
user:cook_turn_hourly               # see rate_limiter.ts
user:realtime_session_hourly        # see rate_limiter.ts
user:ops_admin_minutely             # see rate_limiter.ts
```

Default posture is **fail-CLOSED** on Postgres outage (SCA-380 hardening, observation 4429) — limiter glitch should never let an attacker burn the AI budget. Single documented exception: `recipe-step-rewrite` fails OPEN because the call is non-fatal mid-cook (substitution itself has already been accepted by the time we reach the rewrite call; dropping it just leaves stale prose on the step card). If a new endpoint wants the same exception, document it here.

## `ai_request_log.feature_key` enumeration

Every AI Edge Function logs its calls under a stable `feature_key`; this is what `ai_request_log` rows and PostHog `$ai_generation` events slice on for cost-per-feature dashboards.

```
pantry_parse
dinner_solve
substitution
recipe_step_rewrite      # SCA-432 — distinct from substitution so post-accept rewrite cost slices separately
cook_turn
recipe_import
grocery_generate
cook_mode_realtime       # voice-session mint + per-turn usage
```

Adding a new feature_key without updating this list is a wire-contract change — also update the AI pipeline map in `CLAUDE.md`.

## Prompt rollout convention (`prompt_versions`)

`prompt_versions` rows ship at `is_default=TRUE, is_enabled=TRUE`. First version of a new `feature_key` (`v1.0.0`) lands at `rollout_pct=100` because there's no prior version to A/B against — the new endpoint has zero traffic until iOS starts calling it. **Subsequent semver bumps follow the 5% canary convention** (`pickStandardPrompt` selects between `is_default` and the canary by `rollout_pct`). Example seed for both classes in `Backend/supabase/migrations/20260515210000_seed_prompt_versions_recipe_step_rewrite.sql` (v1.0.0 @ 100%) and the dinner-solve v2.0.0 canary noted in `CLAUDE.md` §AI pipeline map.

## `/v1/config/bootstrap` response

```json
{ "entitlements":{...same as bootstrap}, "feature_flags":[...same],
  "prompts":[{ "feature_key":"dinner_solve", "version":"0.0.0", "provider_model":"claude-haiku-5-5",
               "schema_hash":"", "is_default":true, "is_enabled":false }] }
```

`prompts` rich-object so iOS emits `prompt_version` telemetry without an extra lookup. `EntitlementService` stores entitlements + quotas in memory + Keychain (24h offline fallback). Every feature gate reads from `EntitlementService`.

## Feature flags

Client (PostHog): `paywall_variant`, `widget_nudge_enabled`, `leftovers_mode_enabled`.

Server (`feature_flags`): `prompt_version_override`, `recipe_import_async_threshold`, `priority_queue_pro_enabled`, `cook_voice_thinking_level` ∈ {minimal,low} (sets the OpenAI Realtime reasoning effort at mint), `cook_voice_default_on`, `voice_turn_detection_mode` ∈ {semantic_vad,server_vad} (selects OpenAI's semantic VAD or server VAD at mint), `disable_scan_parse`, `disable_cook_voice` / `disable_cook_realtime` (alias; routes voice to the C.3 on-device fallback with `AI-VOICE-01`), `disable_imports`, `force_saved_meals_only`, `preference_memory_enabled` (SCA-44/ADR 0030; default true; when false dinner-solve renders `feedback_json` null even if iOS sent populated `feedback_summary`; failing-open on flag-read errors).

## Environment variables

Backend (Supabase Edge Function secrets):

```
ANTHROPIC_API_KEY  # Claude text (all text features by default). Read via the official SDK in _shared/claude.ts.
OPENAI_API_KEY     # OpenAI Realtime client-secret mint (POST /v1/realtime/client_secrets). Never reaches iOS.
GEMINI_API_KEY     # Text fallback only; read only when AI_TEXT_PROVIDER=gemini.
AI_TEXT_PROVIDER   # OPTIONAL. 'anthropic' (default when unset) | 'gemini'. One selection for every text endpoint; no per-request fallback; any other value throws at the first call.
STIR_JWT_SECRET    # HS256 signer. Renamed from SUPABASE_JWT_SECRET — Supabase reserves SUPABASE_* and filters them from .env.
REVENUECAT_WEBHOOK_SECRET
APNS_AUTH_KEY_ID, APNS_AUTH_KEY_P8 (base64), APNS_TEAM_ID, APNS_BUNDLE_ID
POSTHOG_API_KEY, SENTRY_DSN
LOG_IP_SALT        # 32-byte hex, HMAC-SHA256 input for ipBucket(). Rotated monthly (docs/runbooks/ip-salt-rotation.md). Falls back to FNV-1a + warn if unset. MUST be set before first beta invite.
STIR_PGMQ_DISPATCH_SECRET  # 32-byte hex, shared with `app.stir_pgmq_dispatch_secret`. pgmq-dispatch rejects calls without matching `X-Stir-Cron-Secret`. MUST be set before exposing function publicly.
```

iOS (`Config.xcconfig`, gitignored; `.example` documents shape): `SUPABASE_URL`, `SUPABASE_ANON_KEY` (only for `/v1/session/bootstrap`, RLS-enforced), `REVENUECAT_PUBLIC_API_KEY`, `POSTHOG_PUBLIC_API_KEY`, `SENTRY_DSN_PUBLIC`. Never present on iOS: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`. iOS holds only the short-lived Realtime client secret (`ek_…`) returned by `/v1/ai/realtime-session`.
