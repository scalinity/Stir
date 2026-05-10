# CLAUDE-Constants.md — Stir Pre-filled Constants

Reference companion to `CLAUDE.md`. Holds the load-bearing constants, JSON shapes, code blocks, and aliasing/usage-counter semantics. CLAUDE.md points here.

## Gemini models and pricing

```swift
enum GeminiModel: String {
    case flash = "gemini-3-flash-preview"
    case flashLite = "gemini-3.1-flash-lite-preview"
    case flashLivePreview = "gemini-3.1-flash-live-preview"
}
```

Paid tier per 1M tokens (April 2026; re-checked 2026-05-08 against https://ai.google.dev/gemini-api/docs/pricing):

| Model | Text in | Audio in | Image in | Text out | Audio out | Cache |
| --- | --- | --- | --- | --- | --- | --- |
| flash | $0.50 | $1.00 | $0.50 | $3.00 | — | yes |
| flash-lite | $0.25 | $0.50 | $0.25 | $1.50 | — | yes |
| flash-live | $0.75 | $3.00 | $1.00 | $4.50 | $12.00 | **no** |

Live audio: **25 tokens/second** both directions.

## Cost model (device-measured April 2026; ADR 0014)

From 9+ turn sessions, N=4 refresh + pre-mint, 22% tool-call rate. Voice turn non-tool ~$0.008 (4,527 prompt + 124 audio out); tool-call ~$0.014 (8,822 + 150). Session 15 turns ~$0.13–0.16; 30 turns ~$0.27–0.32. Premium AI/mo target $1.89 (22.27% of $8.49 ARPU); 13×15-turn cap ~$1.69–$2.08. Pro AI/mo $3.69; 27-cap ~$3.51–$4.32. Free $0.075. Pantry scan single-image ~$0.005; multi-image (Pro 4-photo) ~$0.018–$0.024 at `maxOutputTokens=4096`. Retry-once disabled (SCA-36 W4) so schema-validation failure costs 1× → AI-02. `pantry_parse` unmetered per-user; bounded by `ip:pantry_parse_daily=100` (one IP ~$2.40/day at upper end). **If 95th-pct per-IP daily pantry-parse cost crosses $0.50, file ADR to revisit IP cap or add `user:pantry_parse_daily` at Pro.** Ranges assume 75/25–60/40 text:audio split.

**No caching on Live API** (ADR 0015): `cachedContentTokenCount = 0` across 50+ measured turns. Implicit caching that `generateContent` callers get does NOT fire on `BidiGenerateContent`. Don't assume non-zero caching savings on voice. Observability: `ai_request_log.prompt_cached_tokens`, PostHog `$ai_cache_read_input_tokens`; cap-reversal trigger in ADR 0015.

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

## Gemini Live session constants

```swift
enum LiveSessionLimits {
    static let maxSessionDurationSec       = 30 * 60   // Gemini hard limit
    static let idleDisconnectSec           = 15 * 60   // Gemini hard limit
    static let contextWindowTokens         = 131_072   // non-binding with refresh cadence
    static let refreshAtElapsedSec         = 10 * 60   // Stir policy
    static let refreshAtTurnCount          = 4         // ADR 0014
    static let refreshAtPromptTokenCount   = 10_000    // burst trigger; ADR 0014
    static let maxOutputTokens             = 400       // ADR 0010, baked into mint
    static let tokenSoftCapPerSession      = 40_000    // alert
    static let tokenHardCapPerSession      = 80_000    // force reset
    static let tokenMintOpenWindowSec      = 60        // new_session_expire_time offset
    static let tokenMintHardDeadlineSec    = 35 * 60   // expire_time offset
    static let tokenMintUses               = 1
    // Removed: pruneKeepLastNTurns — refresh IS pruning. ADR 0014.
}
```

## Endpoints

Supabase (`$SUPABASE_URL/functions/v1`):

```
POST /v1/session/bootstrap
GET  /v1/config/bootstrap
POST /v1/ai/pantry-parse
POST /v1/ai/dinner-solve
POST /v1/ai/realtime-session      # mints Gemini Live ephemeral token
POST /v1/ai/cook-turn             # text fallback for voice
POST /v1/ai/substitution          # also called from Live function-call round-trips
POST /v1/ai/recipe-import
POST /v1/ai/grocery-generate
POST /v1/push/register
POST /v1/revenuecat/webhook
POST /v1/ops/flag-output
*    /v1/ops/admin/*              # Supabase Auth admin role + RLS
```

Gemini (Edge Functions only; iOS only the Live WebSocket):

```
POST .../v1beta/models/gemini-3-flash-preview:generateContent
POST .../v1beta/models/gemini-3.1-flash-lite-preview:generateContent
POST .../v1alpha/auth_tokens                               # Live mint (v1alpha)
WSS  wss://.../v1alpha.GenerativeService.BidiGenerateContentConstrained?access_token=auth_tokens/<id>
```

## Error code matrix

User-visible messages in spec §6.

```swift
enum ErrorCode: String {
    case net01="NET-01"            // network unreachable (URLSession; no response)
    case internal01="INTERNAL-01"  // 500-class server error
    case ai01="AI-01", ai02="AI-02", ai03="AI-03"  // unavailable / low confidence / slow
    case aiVoice01="AI-VOICE-01"   // Live API down, text fallback active
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

## `/v1/config/bootstrap` response

```json
{ "entitlements":{...same as bootstrap}, "feature_flags":[...same],
  "prompts":[{ "feature_key":"dinner_solve", "version":"0.0.0", "provider_model":"gemini-3-flash-preview",
               "schema_hash":"", "is_default":true, "is_enabled":false }] }
```

`prompts` rich-object so iOS emits `prompt_version` telemetry without an extra lookup. `EntitlementService` stores entitlements + quotas in memory + Keychain (24h offline fallback). Every feature gate reads from `EntitlementService`.

## Feature flags

Client (PostHog): `paywall_variant`, `widget_nudge_enabled`, `leftovers_mode_enabled`.

Server (`feature_flags`): `prompt_version_override`, `recipe_import_async_threshold`, `priority_queue_pro_enabled`, `cook_voice_thinking_level` ∈ {minimal,low}, `cook_voice_default_on`, `voice_turn_detection_mode` ∈ {semantic_vad,server_vad} (consumed at mint), `disable_scan_parse`, `disable_cook_voice` / `disable_cook_realtime` (alias), `disable_imports`, `force_saved_meals_only`, `preference_memory_enabled` (SCA-44/ADR 0030; default true; when false dinner-solve renders `feedback_json` null even if iOS sent populated `feedback_summary`; failing-open on flag-read errors).

## Environment variables

Backend (Supabase Edge Function secrets):

```
GEMINI_API_KEY     # legacy-format key (AIzaSy..., 39 chars). AQ.xxx fails on auth_tokens (sharp-edge #18). Project MUST be paid tier (sharp-edge #17).
STIR_JWT_SECRET    # HS256 signer. Renamed from SUPABASE_JWT_SECRET — Supabase reserves SUPABASE_* and filters them from .env.
REVENUECAT_WEBHOOK_SECRET
APNS_AUTH_KEY_ID, APNS_AUTH_KEY_P8 (base64), APNS_TEAM_ID, APNS_BUNDLE_ID
POSTHOG_API_KEY, SENTRY_DSN
LOG_IP_SALT        # 32-byte hex, HMAC-SHA256 input for ipBucket(). Rotated monthly (docs/runbooks/ip-salt-rotation.md). Falls back to FNV-1a + warn if unset. MUST be set before first beta invite.
STIR_PGMQ_DISPATCH_SECRET  # 32-byte hex, shared with `app.stir_pgmq_dispatch_secret`. pgmq-dispatch rejects calls without matching `X-Stir-Cron-Secret`. MUST be set before exposing function publicly.
```

iOS (`Config.xcconfig`, gitignored; `.example` documents shape): `SUPABASE_URL`, `SUPABASE_ANON_KEY` (only for `/v1/session/bootstrap`, RLS-enforced), `REVENUECAT_PUBLIC_API_KEY`, `POSTHOG_PUBLIC_API_KEY`, `SENTRY_DSN_PUBLIC`. Never present anywhere: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY on iOS`.
