# CLAUDE.md — Stir

This file is your orientation pack for the Stir codebase. It exists so you don't have to rediscover the same facts every session. If a fact is in this file, trust it — the full spec (`Specs/Stir-Full-Spec.md`) and the Cook Mode research (`Specs/Stir-Cook-Mode-Architecture.md`) are the authoritative source, but this file is your working cache.

Daniel is the solo builder. He reads generated code at peer level. Don't simplify unless asked.

---

## The product in three sentences

Stir is an iPhone app for the exact weeknight moment: stand in the kitchen with ingredients, no plan, low energy. Scan → 3 dinners → cook with timers and (on Premium) hands-free voice. iOS 17+, SwiftUI, Gemini-only AI, Supabase operational backend, CloudKit for user content.

## Spec pointers

- **Full spec** (product truth): `Specs/Stir-Full-Spec.md`
- **Cook Mode research** (voice implementation reference): `Specs/Stir-Cook-Mode-Architecture.md`
- If this file disagrees with the spec, the spec wins. Flag the discrepancy so one of them gets updated.

## North-star constraints (invariants — never violate)

1. **Single AI vendor: Google Gemini.** No OpenAI, no Anthropic, no cross-vendor LLM fallback. The only models that touch production are `gemini-3-flash`, `gemini-3.1-flash-lite`, and `gemini-3.1-flash-live-preview`.
2. **No provider API keys in the iOS bundle, ever.** Cook Mode voice uses ephemeral session tokens minted server-side. The main Gemini API key lives in Supabase Edge Function secrets only.
3. **User content lives in CloudKit, not Supabase.** Supabase Postgres holds operational metadata only (quotas, entitlements, prompt versions, AI request logs). Pantry items, recipes, and cooking sessions sync via CloudKit private database. Don't mirror user content in Postgres.
4. **RLS on every ops table in Supabase.** All rows keyed on `canonical_user_key`. No exceptions, no "temporary" bypasses.
5. **Hard-rule validator runs on every substitution output,** regardless of invocation path (Substitution Sheet or Live session function call).
6. **Voice is Premium+ only.** Free tier gets unlimited tap-based Cook Mode, but the voice affordance triggers a hard paywall with `ENT-VOICE-01`.
7. **Live session context pruned to last 3 turns.** `session.update` with audio-item truncation after every step advance. This is the only cost control that works — Gemini Live doesn't support caching.
8. **Voice session `max_output_tokens: 150`.** Baked into the ephemeral-token mint config, not just client-side.

---

## Stack snapshot

| Layer | Choice |
| --- | --- |
| iOS minimum | 17.0 |
| Build tooling | Xcode 26+, iOS 26 SDK (Apple App Store rule as of April 28, 2026) |
| UI | SwiftUI, `@Observable` view models |
| Concurrency | Swift Concurrency (async/await, actors) |
| Persistence | Core Data + `NSPersistentCloudKitContainer` |
| Sync | CloudKit private database |
| Backend | Supabase (Postgres + Edge Functions + Auth + pgmq/pg_cron) |
| Payments | RevenueCat over StoreKit 2 |
| Analytics | PostHog |
| Errors | Sentry |
| Push | APNs direct |
| Text AI | `gemini-3-flash` (scan, solve, substitution, cook-turn fallback) |
| Cheap AI | `gemini-3.1-flash-lite` (recipe import normalize, grocery list) |
| Voice AI | `gemini-3.1-flash-live-preview` at `thinkingLevel: minimal` |
| On-device | Vision (OCR, barcode), Speech framework + AVSpeechSynthesizer (voice fallback only) |

---

## Pre-filled constants

### Gemini model strings and pricing

```swift
enum GeminiModel: String {
    case flash            = "gemini-3-flash"
    case flashLite        = "gemini-3.1-flash-lite"
    case flashLivePreview = "gemini-3.1-flash-live-preview"
}
```

Paid tier, per 1M tokens, April 2026:

| Model | Text in | Audio in | Image in | Text out | Audio out | Cache |
| --- | --- | --- | --- | --- | --- | --- |
| gemini-3-flash | $0.50 | $1.00 | $0.50 | $3.00 | — | supported |
| gemini-3.1-flash-lite | $0.25 | $0.50 | $0.25 | $1.50 | — | supported |
| gemini-3.1-flash-live-preview | $0.75 | $3.00 | $0.75 | $4.50 | $12.00 | **not supported** |

Audio tokens on Live: **25 tokens/second** both directions.

### Cost model (steady-state, post-pruning, spike-validated April 2026)

- Voice Cook turn: ~$0.00600 (125 new audio in + 825 carried audio in + ~200 AUDIO-mode overhead + 1000 text sys prompt in + 150 audio out)
- Voice Cook session (15 turns): ~$0.090
- Premium user AI / mo: **$1.89** (22.27% of $8.49 net ARPU)
- Pro user AI / mo: **$3.69** (40 voice sessions; Pro cap deliberately below Premium's 3x-ratio ceiling to protect against power-law usage drift)
- Free user AI / mo: **$0.075**

### StoreKit SKUs

```
stir.premium.monthly          $9.99/mo     no trial
stir.premium.annual.trial7    $69.99/yr    7-day free trial (PRIMARY paywall CTA)
stir.pro.monthly              $14.99/mo    no trial
stir.pro.annual               $139.99/yr   no trial
```

Subscription group: `stir.subscriptions`
Family Sharing: **off** on all SKUs.

### Apple fee rates

- Year 1 non-SMB: 70% proceeds (30% fee)
- Year 2+ non-SMB: 85% proceeds (15% fee)
- SMB Program: 85% from year 1 (check eligibility near launch)

### Tier entitlements (authoritative)

| Entitlement | Free | Premium | Pro |
| --- | --- | --- | --- |
| Dinner Solves / mo | 6 | 40 | 120 |
| Tap Cook Sessions | unlimited | unlimited | unlimited |
| Voice Cook Sessions / mo | **0** | 20 | 40 |
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

### Gemini Live session constants

```swift
enum LiveSessionLimits {
    static let maxSessionDurationSec       = 30 * 60   // Gemini hard limit
    static let idleDisconnectSec           = 15 * 60   // Gemini hard limit
    static let contextWindowTokens         = 131_072   // effectively non-binding with pruning
    static let refreshAtElapsedSec         = 10 * 60   // Stir policy
    static let refreshAtTurnCount          = 15        // Stir policy
    static let maxOutputTokens             = 150       // Stir policy, baked into token mint
    static let pruneKeepLastNTurns         = 3         // Stir policy, via session.update
    static let tokenSoftCapPerSession      = 40_000    // alert threshold
    static let tokenHardCapPerSession      = 80_000    // force session reset
    static let tokenMintOpenWindowSec      = 60        // new_session_expire_time offset
    static let tokenMintHardDeadlineSec    = 35 * 60   // expire_time offset
    static let tokenMintUses               = 1         // one session per token
}
```

### Endpoints

Supabase (all prefixed with `$SUPABASE_URL/functions/v1`):

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

Google Gemini (Edge Functions call these; iOS client never does directly except for the Live WebSocket):

```
POST https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash:generateContent
POST https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent
POST https://generativelanguage.googleapis.com/v1alpha/authTokens                 # Live session mint (v1alpha, not v1beta)
WSS  wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent
```

### Error code matrix

Keep error copy in sync with spec §6. User-visible messages live in the spec; codes live here.

```swift
enum ErrorCode: String {
    case net01       = "NET-01"         // network unreachable
    case ai01        = "AI-01"          // AI temporarily unavailable
    case ai02        = "AI-02"          // low confidence / needs review
    case ai03        = "AI-03"          // taking longer than expected
    case aiVoice01   = "AI-VOICE-01"    // Live API down, text fallback active
    case import01    = "IMPORT-01"      // recipe import parse failed
    case permCam01   = "PERM-CAM-01"    // camera denied
    case permMic01   = "PERM-MIC-01"    // microphone denied
    case permPhoto01 = "PERM-PHOTO-01"  // photos denied
    case permRem01   = "PERM-REM-01"    // reminders denied
    case sync01      = "SYNC-01"        // iCloud unavailable
    case rate01      = "RATE-01"        // quota exhausted
    case bill01      = "BILL-01"        // entitlement uncertain
    case pay01       = "PAY-01"         // purchase failed
    case entVoice01  = "ENT-VOICE-01"   // voice requires Premium+
    case val01       = "VAL-01"         // request body failed Zod validation (client bug)
    case auth01      = "AUTH-01"        // session missing/expired/malformed/signature_invalid
                                         // iOS auto-re-bootstraps silently; invisible unless retry also fails
}
```

### VAL-01 response shape (400)

Server returns:

```json
{
  "error": "VAL-01",
  "message": "Request body failed validation: 'installation_id' must be a UUID",
  "field_errors": [
    { "field": "installation_id", "issue": "Expected UUID, got 'abc123'" }
  ]
}
```

`message` is dev/Sentry-facing; `field_errors` is structured for iOS dashboards and tests. User-visible copy lives in iOS `ErrorPresenter`, not in the server response. Server logs VAL-01 at `warn` (not `error`) — every one is an iOS bug worth investigating, but error severity would drown the dashboard in client bugs.

iOS behavior: log to Sentry at `error` severity with full `field_errors`; show generic user copy; **do not retry** (same request will fail the same way); do not cache.

### AUTH-01 response shape (401)

Server returns:

```json
{
  "error": "AUTH-01",
  "message": "Session expired or missing",
  "reason": "expired" | "missing" | "malformed" | "signature_invalid"
}
```

`reason` is a typed enum with four distinct handling paths:

| `reason` | Cause | iOS action | Server log level |
| --- | --- | --- | --- |
| `missing` | No `Authorization` header | Silent re-bootstrap | `info` |
| `expired` | JWT valid but past `exp` | Silent re-bootstrap | `info` |
| `malformed` | Header present, invalid JWT structure | Re-bootstrap + Sentry error | `error` |
| `signature_invalid` | Structure valid, signature doesn't verify | Re-bootstrap + Sentry error + alert at threshold | `error` |

iOS silent-refresh pattern: clear cached JWT, re-bootstrap, retry original request **once**. If retry also 401s, surface NET-01 — never retry-storm. `reason` is a typed field on the thrown error, not parsed from `message`; log aggregators and Sentry alerts key off the typed field.

### Canonical user key

```
canonical_user_key = "ck:<userRecordName>"           // if CloudKit account available
                   | "install:<keychainInstallId>"   // fallback
```

When an `install:`-keyed user later gains CloudKit availability, **alias forward** in RevenueCat and `app_users.merged_into`. Never back-fill user content; always alias forward via the identity table.

### Aliasing when install:<id> gains CloudKit AND ck:<record> already has rows

Reinstall + same iCloud, or sign-out/sign-in mid-session, produces an install row and a ck row that both have data. Merge inside a single Postgres transaction with these rules per table:

| Table | Merge rule | Why |
| --- | --- | --- |
| `usage_counters` | **SUM** `used_count` per `(period_start, feature_key)` onto ck row; delete install rows | Blocks quota-reset abuse (sign in/out to refresh Dinner Solves) |
| `entitlement_snapshots` | **ck wins** (keep ck row, discard install row) | RevenueCat webhook is keyed on ck and is source of truth |
| `ai_request_log` | **UPDATE** `canonical_user_key` install→ck (don't delete) | Preserves cost-attribution history for the user |
| `device_installations` | **UPDATE** `canonical_user_key` install→ck | Device stays; just belongs to ck user now |
| `app_users` (install row) | SET `merged_into = ck`, `status = 'merged'`; **never hard-delete** | Audit trail for support |
| `app_users` (ck row) | Winning row; update `last_seen_at` | The survivor |

Three further rules:

1. **Don't clamp summed quotas to cap.** If install=5/6 and ck=4/6, sum to 9. Quota check `used_count >= cap_count` correctly locks out. Clamping would hand abusers a reset.
2. **RevenueCat re-alias runs AFTER the DB transaction commits,** not inside it. `Purchases.logIn(ck:<record>)` is an external call; its failure shouldn't roll back the DB merge. Retry via background job if the RC call fails.
3. **Merge runs synchronously in `/v1/session/bootstrap`,** not async. Bootstrap is rare (install + iCloud state change); 100ms latency is acceptable. Async risks a Dinner Solve request hitting un-merged counters and granting phantom quota.

Transaction failure twice in a row → return `VAL-01` with specific merge-failure detail in `message`, log to Sentry at `error`. Real bug, not user-retryable.

### `app_users.status` enum

Values: `active | merged | banned`. Implemented as native Postgres ENUM with a partial index on rows where status != 'active' (the vast majority are 'active'; partial index keeps the index tiny and fast).

State transitions (enforced in application code):

| From | To | Trigger |
| --- | --- | --- |
| `active` | `merged` | Identity alias-forward in `/v1/session/bootstrap` |
| `active` | `banned` | Admin action via `/v1/ops/admin/*` (step 8) |
| `merged` | — | **Terminal.** Un-merging isn't supported (can't un-sum counters cleanly) |
| `banned` | `active` | Manual admin unban via `/v1/ops/admin/*` |

Bootstrap behavior:
- `merged` row hit during lookup → follow `merged_into` chain one hop to the winning row. Nested merges are a bug.
- `banned` row → return 403 with `BILL-01` and halt.

Never soft-delete. Deletion is hard-delete per CCPA (spec §11).

### `entitlement_snapshots.billing_state` enum

Values: `none | active | trial | grace | cancelled_active | expired`. Native Postgres ENUM, partial index on rows where billing_state != 'none' (Free users are the hot path).

**Orthogonal to `tier`:** `tier` (free|premium|pro) tells you *what* they're entitled to; `billing_state` tells you *why* and what the app should show.

| Value | Meaning |
| --- | --- |
| `none` | Free tier, never purchased |
| `active` | Paid and current |
| `trial` | Intro offer in progress (Premium annual only) |
| `grace` | Apple billing retry in progress; user retains paid access; iOS shows BILL-01 banner |
| `cancelled_active` | User cancelled; access continues until period_end |
| `expired` | Paid access ended (distinct from `none` — eligible for win-back offers) |

RevenueCat webhook event → state mapping (implemented in step 5):

| Event | Transition |
| --- | --- |
| `INITIAL_PURCHASE` with intro offer | `none|expired` → `trial` |
| `INITIAL_PURCHASE` no intro offer | `none|expired` → `active` |
| `RENEWAL` | `trial|active|cancelled_active` → `active` |
| `CANCELLATION` | `active|trial` → `cancelled_active` |
| `UNCANCELLATION` | `cancelled_active` → `active` |
| `BILLING_ISSUE` | `active` → `grace` |
| `EXPIRATION` | `cancelled_active|grace|trial` → `expired` |
| `PRODUCT_CHANGE` | `active` → `active` (tier changes separately) |

Bootstrap entitlement resolution: `none|expired` → Free; `active|trial|grace|cancelled_active` → paid per `tier` column; `grace` additionally returns `show_billing_grace_banner: true`.

### `usage_counters` feature keys and period semantics

Metered keys (this table): `dinner_solve | voice_cook_session | recipe_import`. Native Postgres ENUM.

**Not in this table:**
- `remembered_pantry_items`: standing cap, not monthly. Enforced client-side against CloudKit count.
- `scan_parse`, `substitution`, `grocery_generate`, `cook_turn`: unmetered across tiers. Cost tracked in `ai_request_log`; this table is for quota enforcement only.

**`cap_count` is SNAPSHOTTED at row-creation** from the tier active at that moment. Mid-month tier upgrade does **not** refresh `cap_count` on existing period rows. Non-metered Premium entitlements (voice access, saved favorites, widgets) unlock immediately on tier change; metered quotas catch up next period. iOS paywall copy sets this expectation: "You'll get your full Premium Dinner Solves at your next monthly reset on <date>."

**Why snapshot, not refresh:** refresh-on-upgrade creates an abuse vector (upgrade mid-month to reset quota, downgrade after) and a race condition (webhook fan-out vs concurrent increments). Snapshot is atomic, predictable, and cleanly enforces a monthly boundary.

**Atomic quota check** (the reason cap_count lives in this table, not derived via JOIN):

```sql
UPDATE usage_counters
   SET used_count = used_count + 1,
       updated_at = now()
 WHERE canonical_user_key = $1
   AND period_start = $2
   AND feature_key = $3
   AND used_count < cap_count
RETURNING used_count, cap_count;
```

One round trip, no race, no join. Empty return = capped.

**`period_start` semantics:** uses the user's `app_users.created_at` month-day as the anchor. A user who joined on the 17th has monthly periods that start on the 17th. Simpler than calendar-month alignment (no mid-month cliff for new signups) and matches Apple's subscription renewal pattern.

### `/v1/session/bootstrap` response shape

```json
{
  "session_jwt": "<jwt, 24h TTL>",
  "canonical_user_key": "ck:<record>" | "install:<id>",
  "is_new_user": true | false,
  "entitlements": {
    "tier": "free" | "premium" | "pro",
    "billing_state": "none" | "active" | "trial" | "grace" | "cancelled_active" | "expired",
    "is_trial": true | false,
    "trial_expires_at": "2026-04-25T00:00:00Z" | null,
    "subscription_expires_at": "2027-04-18T00:00:00Z" | null,
    "voice_enabled": true | false,
    "show_billing_grace_banner": true | false,
    "quotas": [
      {
        "feature_key": "dinner_solve",
        "used_count": 3,
        "cap_count": 6,
        "period_start": "2026-04-17",
        "period_end": "2026-05-17"
      }
    ]
  },
  "feature_flags": { ... },
  "prompt_versions": { "<feature_key>": "<semver>", ... }
}
```

Key shape rules:

- `voice_enabled` is **SERVER-COMPUTED** (`tier IN ('premium','pro') AND billing_state IN ('active','trial','grace','cancelled_active')`), never derived on iOS. Single source of truth.
- `quotas` is an **array** (iterable, uniform rendering), not a keyed object.
- `period_end` is **always included**, never client-computed (mid-month transitions + anchor-day semantics make it non-trivial).
- Nested `entitlements` object (not flattened) so iOS can destructure cleanly as the bootstrap response grows.
- Trial/subscription timestamps are absolute UTC; iOS localizes for display.

iOS consumption: `EntitlementService` stores this in memory + Keychain. Every feature gate reads from `EntitlementService`, never directly from the response body.

### Feature flags

Client (PostHog):
- `paywall_variant`
- `widget_nudge_enabled`
- `leftovers_mode_enabled`
- `cook_voice_default_on`
- `voice_turn_detection_mode` ∈ {`semantic_vad`, `server_vad`}

Server (Supabase `feature_flags`):
- `prompt_version_override`
- `recipe_import_async_threshold`
- `priority_queue_pro_enabled`
- `cook_voice_thinking_level` ∈ {`minimal`, `low`}
- `disable_scan_parse`
- `disable_cook_voice` / `disable_cook_realtime` (alias)
- `disable_imports`
- `force_saved_meals_only`

### Expected environment variables

Backend (Supabase Edge Function secrets):

```
GEMINI_API_KEY                  # single key for all Gemini features, including Live mint
SUPABASE_JWT_SECRET             # HS256 signer for session JWTs
REVENUECAT_WEBHOOK_SECRET
APNS_AUTH_KEY_ID
APNS_AUTH_KEY_P8                # base64-encoded
APNS_TEAM_ID
APNS_BUNDLE_ID
POSTHOG_API_KEY
SENTRY_DSN
```

iOS (via `Config.xcconfig`, gitignored; `Config.xcconfig.example` documents shape):

```
SUPABASE_URL                    # public project API URL
SUPABASE_ANON_KEY               # public anon key, used only for /v1/session/bootstrap (RLS-enforced)
REVENUECAT_PUBLIC_API_KEY       # RevenueCat public SDK key
POSTHOG_PUBLIC_API_KEY          # PostHog public project key
SENTRY_DSN_PUBLIC               # Sentry public DSN
```

Never present anywhere:

```
OPENAI_API_KEY                  # not used
ANTHROPIC_API_KEY               # not used
GEMINI_API_KEY on iOS           # server-only
```

---

## Repo layout

```
Stir/                            # iOS app target
  App/                           # StirApp, RootCoordinator
  DesignSystem/                  # colors, typography, spacing, shared views
  Core/
    Models/                      # domain types (HouseholdProfile, PantryItem, ...)
    Repositories/                # Core Data access, sync wiring
    Services/                    # cross-feature logic (EntitlementService, QuotaService, AIDispatch)
    Utilities/
  Features/                      # one folder per screen cluster
    Onboarding/ Tonight/ Scan/ Solve/ CookMode/ Import/ Saved/ Settings/ Billing/
  Integrations/
    Camera/ Speech/ Vision/ Reminders/ CloudKit/ RevenueCat/ PostHog/ Sentry/
    GeminiLive/                  # WebSocket transport, audio pipeline, session state machine
  Extensions/
    ShareExtension/ Widgets/ AppIntents/
  Tests/
    Unit/ Integration/ UITests/

Backend/supabase/
  migrations/                    # SQL schema + RLS policies (canonical_user_key-keyed)
  functions/
    _shared/                     # auth verify, gemini client, hard-rule engine, validators
    session-bootstrap/
    config-bootstrap/
    ai-pantry-parse/
    ai-dinner-solve/
    ai-realtime-session/         # mints Gemini Live ephemeral token
    ai-cook-turn/                # text fallback for voice
    ai-substitution/             # also called from Live function-call round-trips
    ai-recipe-import/
    ai-grocery-generate/
    push-register/
    revenuecat-webhook/
    ops-flag-output/
    ops-admin/
  seed/                          # prompt_versions defaults, feature flag defaults

Specs/                           # product spec + research docs
  Stir-Full-Spec.md
  Stir-Cook-Mode-Architecture.md

docs/
  decisions/                     # ADRs for material architecture choices (includes rejected OpenAI path)
```

---

## AI pipeline map

| Feature | Endpoint | Model | Streaming | Guardrail |
| --- | --- | --- | --- | --- |
| Pantry scan parse | `/v1/ai/pantry-parse` | gemini-3-flash | no | schema + confidence threshold |
| Dinner solve | `/v1/ai/dinner-solve` | gemini-3-flash | yes (card-by-card) | hard-rule validator, retry on violation |
| Cook Mode voice turn | Live WS via `/v1/ai/realtime-session` token | gemini-3.1-flash-live-preview (minimal) | native bidi audio | system-prompt preamble, max_output_tokens, pruning |
| Cook Mode substitution (voice path) | Live function call → `/v1/ai/substitution` | gemini-3-flash | no | hard-rule validator (same engine as sheet) |
| Cook Mode Q&A fallback | `/v1/ai/cook-turn` | gemini-3-flash (text) | no | schema |
| Substitution (sheet) | `/v1/ai/substitution` | gemini-3-flash | no | hard-rule validator |
| Recipe import | `/v1/ai/recipe-import` | gemini-3.1-flash-lite | no | sanitize HTML, treat content as untrusted |
| Grocery generate | `/v1/ai/grocery-generate` | gemini-3.1-flash-lite | no | post-model dedupe |

---

## Gemini Live — the sharp-edges section

Everything here is where Gemini Live differs from OpenAI Realtime. Assume OpenAI-Realtime intuition until this section tells you otherwise.

1. **No caching.** Full stop. Every turn re-sends context at full audio-input rate. Pruning to last 3 turns after every step advance is mandatory. Skipping pruning means linear cost blowup that won't show up until a user has a long session.
2. **No first-class WebRTC.** WebSocket only, via `URLSessionWebSocketTask`. Cellular networks will occasionally stall due to TCP head-of-line blocking. Do not "just switch to WebRTC" — not supported.
3. **Preambles are NOT spontaneous, and our adherence-via-prompt assumption is UNVALIDATED.** Unlike `gpt-realtime`, Gemini doesn't naturally say "let me check" before tool calls. The system prompt asks the model to do so, but adherence under MINIMAL has not been benchmarked. **Mandatory belt-and-suspenders:** the iOS client plays a pre-recorded filler audio clip the instant a `toolCall` frame arrives, covering the ~2s backend round-trip deterministically. Do not rely on model-emitted preambles alone. Week-one spike must measure preamble-present rate — if <90%, disable model preambles via system prompt and rely solely on the client clip to avoid double-speak. Monitor `preamble_present_rate` telemetry only to validate model behavior over time, not as the UX-correctness metric.
4. **Preview status.** The Live API is preview-labeled. If Google changes the API shape or pricing, `disable_cook_realtime` is the kill switch — all Premium+ voice routes to the text-path fallback with `AI-VOICE-01` banner.
5. **Ephemeral tokens have two expiries.** `new_session_expire_time` = window to open the session (~60s). `expire_time` = hard deadline for the session itself (~35 min from mint). `uses: 1` = one session per token.
6. **Session refresh is silent by design.** 10 min or 15 turns, whichever first. Mint new token, open new WebSocket, close old one after new one's first response lands. If refresh fails → text fallback.
7. **Semantic VAD is the starting choice, server VAD the fallback.** Semantic VAD chunks on utterance completion and avoids false-triggering on ambient kitchen noise. If testing shows misfires, flip `voice_turn_detection_mode` to `server_vad`.
8. **`max_output_tokens: 150` is non-negotiable** for cost safety. Baked into the token mint's `generation_config`, not just client-side.
9. **Function response flow differs.** Gemini auto-continues after a `BidiGenerateContentToolResponse` frame. No explicit `response.create` needed (unlike OpenAI Realtime). Function responses are sent as `toolResponse` — not `clientContent` — carrying the matching `functionResponse.id`. If you find yourself writing `response.create` or wrapping a function result in `clientContent`, stop.
10. **Audio format.** PCM16 at 16kHz for input; base64-encoded in `realtimeInput.audio` frames. Server returns base64-encoded audio in `serverContent.modelTurn.parts[].inlineData`.
11. **`clientContent` is history-only on 3.1 Flash Live.** For in-session text injection (typed events like step advance, timer completion, substitution context), use `realtimeInput.text`. `clientContent` only seeds initial conversation history and requires `initial_history_in_client_content: true` in setup — Stir doesn't seed history, so Stir should not use `clientContent` at all.
12. **Tool calls are synchronous.** 3.1 Flash Live does not support async/parallel function calls. One tool call in flight at a time. Do not design flows that assume multiple substitutions or a substitution+timer concurrent invocation.
13. **Auth header is `Authorization: Token <value>`,** not `Bearer`. Easy to get wrong because the rest of the Google API ecosystem uses `Bearer`. Double-check before debugging 401s.
14. **Token mint endpoint is `/v1alpha/authTokens`, not `/v1beta`.** The WebSocket endpoint IS `/v1beta`. Do not assume consistency across the two — they intentionally live in different API versions for now.
15. **Undocumented ~200-token AUDIO-mode overhead per turn.** The April 2026 spike found that every Live turn with `response_modalities: [AUDIO]` charges ~200 extra audio-input tokens beyond the literal audio content — even on text-only input. This is not in the pricing docs but is reliably observed in `usageMetadata.prompt_tokens_details`. The cost model accounts for it. Don't be surprised; don't design flows assuming you can game it with text-only turns.
16. **Mint endpoint auth behavior is unresolved as of April 17 2026.** The spike's raw `POST /v1alpha/authTokens` with API-key auth returned opaque `400 INVALID_ARGUMENT` while every other Gemini endpoint accepted the same key. Most likely cause: OAuth / service-account auth required on this endpoint specifically, or the request body needs SDK-level shaping. **Re-validate from the Supabase Edge Function before building `/v1/ai/realtime-session`.** If mint still fails on API-key auth from the Edge Function: use OAuth with a service-account credential server-side (keeps key off the client either way), OR fall back to backend-proxied WebSocket (Edge Function holds the Gemini connection; +100–300ms TTFA cost). Either is acceptable — the key never reaches the client either way.

---

## Backend contracts

All `/v1/*` endpoints authenticate via session JWT from `/v1/session/bootstrap`. Admin `/v1/ops/*` uses Supabase Auth with admin role + RLS.

Shared behaviors across endpoints:
- 400 on request body validation failure → `{ error: "VAL-01", message, field_errors: [...] }`
- 401 on missing/expired/invalid session JWT → `{ error: "AUTH-01", message, reason: "missing|expired|malformed|signature_invalid" }`
- 403 on entitlement mismatch → `{ error: "ENT-VOICE-01" }` for voice, `{ error: "BILL-01" }` for general
- 429 on quota exhaustion → `{ error: "RATE-01" }`
- 502 on Gemini outage → `{ error: "AI-01" }`
- Every response body carries `{ error: CODE, message: string, ...structured_details }`. Never return a string-only error. Never return 4xx/5xx with no body.
- Idempotency via explicit request IDs (see spec §3 API table for which endpoints require which IDs)
- Every AI call logs to `ai_request_log` with `{ provider, model, input_tokens, output_tokens, cost_usd, latency_ms, thinking_level, prompt_version }`

Edge Function conventions:
- Deno runtime
- One function per `/v1/…` endpoint
- Shared helpers in `_shared/` (import via relative paths; no npm deps unless unavoidable)
- Secrets via `Deno.env.get(...)` — never hardcoded
- Validate session JWT first thing in every handler using the shared helper
- Zod schema validation at the boundary of every handler (before any DB access)

---

## Integration test DB strategy

Per-test unique IDs, no cleanup between tests. `supabase db reset` between CI runs.

- Test helpers generate fresh UUIDs for `installation_id` and CloudKit record names
- Test-scoped keys prefixed with `test:` (e.g., `install:test:<uuid>`) for local identification and quick cleanup via `DELETE ... WHERE canonical_user_key LIKE 'install:test:%' OR canonical_user_key LIKE 'ck:test:%'`
- Aggregate-style assertions (COUNT, SUM without WHERE) are **banned** in tests — always filter by test-scoped keys. Tests that need aggregates are probably testing the wrong layer.
- Service-role client is used **only** in test seed helpers; never in production code paths. Clearly labeled in helper files.
- RLS tests assert **empty result sets** (`length === 0`), **never** 403 status. RLS is a row filter, not an access check. A query with no matching rows returns `[]`, not an error.
- Don't use TRUNCATE-in-beforeEach: slower, and creates a class of "tests pass until someone adds a new table" bugs.
- Don't wrap tests in transaction rollbacks: RLS goes through PostgREST which doesn't expose transaction handles; splitting the test toolchain is worse than the isolation benefit.

---

## Data ownership boundary

| Lives in | Includes | Does NOT include |
| --- | --- | --- |
| CloudKit private DB | HouseholdProfile, DietaryRule, KitchenEquipment, PantryItem, MealSolveRequest, SuggestedDish, RecipePlan, RecipeIngredient, Step, RecipeImport, CookingSession, VoiceTurn, Timer, SubstitutionEvent, OutcomeFeedback, GroceryList, GroceryItem, MediaAsset | any operational or billing data |
| Supabase Postgres | app_users, device_installations, entitlement_snapshots, usage_counters, ai_request_log, prompt_versions, feature_flags, ops_flagged_outputs, audit_log, notification_jobs | any user-generated content |
| Bundled asset (JSON/SQLite) | IngredientCanonical (global ontology) | anything user-editable |

If you're about to write user content to Postgres: stop. That's always a bug unless it's an operational counter keyed on `canonical_user_key`.

---

## Billing model

- **RevenueCat is the entitlement source of truth.** Webhook fires → `entitlement_snapshots` updates → app pulls via `/v1/config/bootstrap` on next foreground.
- **Grace period:** 24h local cache of entitlements if RevenueCat is unreachable.
- **Trial state:** RevenueCat carries `is_trial` flag. Show trial-days-remaining in Settings and Plan & Billing. Push at 2 days remaining (opt-in, single send).
- **Intro offer eligibility:** Apple platform enforces one per Apple ID per subscription group. Not our enforcement problem.
- **Cohort math:** see spec §9. Pro annual year-1 margin is ~$4.13/mo after the April 2026 pricing bump and spike-validated cost model — flag before raising the voice cap or reducing Pro annual price below $139.99.
- **Paywall trigger moments:** `voice_affordance_tapped` on Free tier is the highest-intent trigger. Lead the paywall with `stir.premium.annual.trial7`, always.
- **Pro voice cap is 40 sessions/mo, not 60.** Earlier spec drafts used 60 and it yielded $0.01/mo year-1 Pro annual margin — fragile to any usage variance. Pro annual is priced at $139.99/yr (not $89.99 or the $119.99 intermediate) specifically because Pro users skew toward the cap and the realized average cost drifts toward the ceiling; the extra headroom also leaves room for founder-discount offer codes during beta without regressing below safe margin.

---

## Telemetry events

Canonical list. Do not invent new names without adding here **and** to spec §15.

```
app_opened, onboarding_started, onboarding_completed,
camera_permission_result, scan_started, scan_submitted, scan_parse_completed,
ingredient_corrected, constraints_set,
dinner_solve_requested, dinner_solve_completed, suggested_dish_selected,
cook_mode_started, cook_step_advanced, timer_started,
voice_affordance_tapped, cook_turn_submitted, cook_turn_resolved,
voice_session_token_snapshot, voice_session_refreshed,
substitution_requested, substitution_accepted,
cook_session_completed, meal_rated,
grocery_list_exported, favorite_saved,
recipe_import_started, recipe_import_completed,
paywall_viewed, trial_started, trial_reminder_sent,
purchase_started, purchase_completed, restore_purchases_tapped,
entitlement_state_changed, reactivation_notification_opened,
widget_added, shortcut_run,
ai_request_completed, ai_request_failed,
screen_error_shown, sync_state_changed
```

Anchors:
- `core_success_event`: scan → select → cook within 3 min → rate ≥4
- `voice_conversion_event`: voice_affordance_tapped(free) → paywall_viewed → trial_started → purchase_completed

---

## Verification flows

Commands will be wired up as the repo materializes. Expected shapes:

```bash
# iOS
xcodebuild test -scheme Stir -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
swiftformat --lint Stir/
swiftlint

# Backend
supabase db reset                 # apply migrations + seed fresh
supabase functions serve          # run all edge functions locally
deno test Backend/supabase/functions/

# AI evals
pnpm run eval:pantry-scan
pnpm run eval:dinner-solve
pnpm run eval:cook-turns          # must check preamble-present rate
pnpm run eval:substitutions       # must hit 100% hard-rule pass
pnpm run eval:recipe-import
pnpm run eval:grocery
```

**Rule of thumb:** when changing an AI feature, run its eval before committing. When changing a prompt, bump `prompt_versions.version` semver and set `rollout_pct` conservatively (start at 5%).

---

## Voice validation plan

The Gemini Live spike is split into a cheap half (API-shape drift check, immediately pre-step-6) and an expensive half (UX validation, in-app at step 6). The April 2026 full spike ran the expensive half already and produced `FINDINGS.md` outside this repo — the cheap half is still pending and runs **at step 6 start**, not at step 1 start.

### Cheap half — immediately pre-step-6, ~1 hour, terminal only

Goals: confirm nothing has drifted between the April 2026 spike findings and the Gemini API surface on the day step 6 begins.

1. `curl POST https://generativelanguage.googleapis.com/v1alpha/authTokens` with `model: "models/gemini-3.1-flash-live-preview"` and a minimal `liveConnectConstraints` block (the SDK-named field; verify the raw-REST equivalent against current docs before executing). Confirm 200 response with a `token` field. If the model string has been renamed or the endpoint path has moved, find out now.
2. Open a WebSocket to `wss://...BidiGenerateContent` with the returned token sent as `Authorization: Token <value>` (Gemini Live uses the `Token` scheme, not `Bearer`). Confirm the connection opens and the server sends a setup-complete frame.
3. Send a single PCM16 test audio frame via `realtimeInput.audio`. Confirm the server acknowledges without a protocol error.
4. Inspect the `usageMetadata` frame to confirm audio token metering is still 25 tokens/second both directions.
5. Verify pricing on [ai.google.dev/gemini-api/docs/pricing](https://ai.google.dev/gemini-api/docs/pricing) matches the numbers in this file ($0.75 text in, $3.00 audio in, $4.50 text out, $12.00 audio out per 1M tokens).
6. Re-test the mint endpoint with API-key auth from the Supabase Edge Function environment specifically (the April 2026 spike got `400 INVALID_ARGUMENT` against raw REST; the Edge Function environment may behave differently, or may need OAuth).
7. If any drift is found, update `Specs/Stir-Full-Spec.md` §12 and this file before proceeding to write Cook Mode code.

### Expensive half — in-app validation gate, start of build-step 6

Goals: validate that Gemini Live MINIMAL's real-world behavior on iOS matches the product assumptions before investing in Cook Mode voice polish.

Before step 6 moves from "wire up the audio pipeline" to "productionize the UX", the following must all measure within spec:

1. **TTFA on Wi-Fi, p95 <1.0s** across 20 representative turns. If p95 is 1.5s+, the Premium UX premise is wrong and the fallback-path pre-warm matters more than currently scoped.
2. **Preamble-present rate at MINIMAL ≥ 70%** across 50 tool-call invocations. If lower, disable model-emitted preambles entirely and rely on the client-side pre-recorded clip as the sole dead-air cover.
3. **Client-side pre-recorded filler fires within 150ms of `toolCall` frame arrival** and masks the 2s backend round-trip cleanly in 95%+ of substitution invocations.
4. **Pruning holds.** Run a scripted 20-turn session with `session.update` pruning after every step advance. Verify per-turn input token count from `usageMetadata` stays bounded at ~950 audio tokens and does not grow with session length.
5. **Session refresh is silent.** At the 10-minute / 15-turn boundary, the refresh handoff completes without user-perceptible gap.

If 1 or 4 fail materially, stop and escalate — those are architectural problems, not tuning problems. 2, 3, 5 can be tuned.

## Build order

1. Supabase project + migrations + `/v1/session/bootstrap` + `/v1/config/bootstrap`.
2. Core Data model + CloudKit container + HouseholdProfile + onboarding flow. No AI yet.
3. Scan + Solve with `gemini-3-flash`. Aha-moment slice. **Spec §13 IP-based rate limiting lands here, not earlier** — bootstrap rate limiting alone protects nothing until `/v1/ai/*` endpoints exist.
4. Saved meals + tap-based Cook Mode. Full Free-tier product.
5. RevenueCat wiring + paywall + entitlements (annual trial primary CTA).
6. Cook Mode voice (Premium+). **Cheap-half Gemini Live drift check runs first**, then in-app validation gate, before any UX polish. Productionize only after both clear.
7. Imports, widgets, shortcuts, leftovers.
8. Telemetry dashboards, ops console, Sentry.
9. Beta.

Each step should end in something demoable. Don't interleave.

**Risk inherent in this ordering:** steps 1–5 build toward Premium-tier economics that assume voice works. If the step-6 validation gate uncovers a fundamental Gemini Live problem (unlikely but possible), Free tier is unaffected but Premium's core promise needs a rework.

---

## Deferred

Tracked explicitly so nothing gets lost. Each item has an owner-step.

- **IP-based rate limiting on `/v1/session/bootstrap`** (spec §13): deferred from step 1 to step 3. Rationale: bootstrap rate limiting alone protects nothing until `/v1/ai/*` endpoints exist. Lands with `/v1/ai/dinner-solve` and shares infrastructure with `ai_request_log` for cost observability. Implementation sketch: Postgres `rate_limit_buckets` table, sliding window, 30 solves/day per IP across canonical keys. Supabase platform-layer rate limiting is the backstop in the meantime.
- **Gemini Live API drift re-check** (cheap-half spike): scheduled for start of step 6. Purpose is to catch API drift between the April 2026 full spike (already complete) and step-6 kickoff. Step 6 cannot start without it.
- **Mint endpoint auth unknown from April 2026 spike**: `POST /v1alpha/authTokens` returned `400 INVALID_ARGUMENT` on API-key auth in the spike environment. Re-test from the actual Supabase Edge Function at step 6. Fallbacks if it still fails: OAuth service-account auth, or backend-proxied WebSocket (both keep the Gemini key server-side).

---

## Working-with-Daniel rules

- Daniel is ex-MindFriend (747-file Swift codebase shipped in 30 days). Assume expert familiarity with iOS, Swift Concurrency, Core Data, CloudKit, Supabase, and AI infra.
- **Default to comprehensive.** Build the full thing — error handling, edge cases, typed Swift models, production-minded from step 1. Don't ask "MVP or comprehensive?" unless Daniel says "quick", "prototype", "sketch", or equivalent.
- **Log assumptions inline.** `// Assuming X because Y. Flag if wrong.` — not in a summary at the end.
- **Root-cause before patching.** When a fix isn't improving the diagnosis, stop and reframe from first principles. Don't iterate politely into a dead end.
- **Audit prior artifacts with the same rigor as new work.** If past-Claude got something wrong in the spec, or in generated code, say so directly. Prior outputs aren't ground truth.
- **Challenge bad calls.** One direct sentence beats three diplomatic paragraphs. If Daniel is wrong, explain why without softening.
- **Don't silently drop features.** If a planned feature turns out to be infeasible mid-build, stop and tell Daniel. Never make compilation pass by dropping scope.
- Daniel likes tables for comparisons, diagrams for systems, and prose only when it genuinely earns its place.

---

## What NOT to reopen

These are settled. Don't re-argue them unless Daniel explicitly asks.

- Single AI vendor (Google only; no OpenAI/Anthropic fallback).
- Supabase backend (not Cloudflare Workers, not Firebase, not custom Node).
- Core Data + CloudKit (not SwiftData).
- iOS 17 minimum (not 15, not 16, not 18).
- Voice = Premium+ (not free with quota, not lifetime free sessions).
- Annual trial is the primary paywall CTA (not monthly, not "upgrade to see Premium").
- `thinkingLevel: minimal` for voice (escalate to LOW only if eval fails).
- RevenueCat (not pure StoreKit 2).
- No mandatory login (not Sign in with Apple required).
- English / US-only launch (no i18n in v1).
- No desktop/web companion app.
- Zod for Edge Function request-body validation (not Valibot — Zod is the default unless a specific reason emerges).
- `usage_counters.cap_count` snapshot-at-creation, not refresh-on-tier-change.
- `app_users.status` and `entitlement_snapshots.billing_state` as native Postgres ENUMs with partial indexes.

If Daniel asks "should we switch to X?", engage with it. If you're independently considering a switch, don't — surface the question first.

## What NOT to do by default

These aren't restrictions on creativity — they're specific wrong paths that look right until they bite.

- Don't put any provider API key in the iOS bundle. Under any framing. Ephemeral tokens, server-side secrets, or manual entry — never bundled.
- Don't add cached-input pricing math to Gemini Live cost estimates. Not supported.
- Don't write user content to Supabase Postgres. User content is CloudKit-only.
- Don't use `response.create` or similar OpenAI-Realtime patterns in Gemini Live code — Gemini auto-continues after function responses.
- Don't send in-session text via `BidiGenerateContentClientContent` on 3.1 Flash Live. Use `realtimeInput.text`. `clientContent` is history-seeding only on this model.
- Don't send function responses via `clientContent`. Use `BidiGenerateContentToolResponse` carrying the matching `functionResponse.id`.
- Don't assume Gemini Live's `Authorization` uses `Bearer`. It's `Token`.
- Don't reference `gpt-realtime`, `GPT-5.4`, or OpenAI outside `docs/decisions/` as rejected-alternative context.
- Don't use `@FetchRequest` in new code — it doesn't play well with `@Observable`. Use a repository + observed view model.
- Don't hardcode entitlement checks against tier strings in view code. Always go through `EntitlementService`.
- Don't derive `voice_enabled` on iOS. It's server-computed in the bootstrap response.
- Don't use object-keyed `quotas` in API responses. Always an iterable array.
- Don't add new telemetry event names without updating spec §15 and this file.
- Don't invent new error codes. Use the matrix (NET-01, AI-01..03, AI-VOICE-01, IMPORT-01, PERM-*, SYNC-01, RATE-01, BILL-01, PAY-01, ENT-VOICE-01, VAL-01, AUTH-01). New codes require updating both this file and spec §6.
- Don't return 4xx/5xx with empty body or string-only error. Always `{ error: CODE, message, ...structured_details }`.
- Don't skip the hard-rule validator on substitution output because "the model is trustworthy on this one." Not optional.
- Don't use UIKit unless wrapping `AVCaptureVideoPreviewLayer` via `UIViewRepresentable`. SwiftUI-first, always.
- Don't add a second LLM provider as "insurance." The single-vendor decision is settled; revisit only if Gemini downtime exceeds 2x SLA for a quarter.
- Don't use aggregate assertions (COUNT, SUM without WHERE) in integration tests. Always filter by test-scoped keys.
- Don't use `beforeEach` TRUNCATE or transaction-rollback wrappers in tests. Per-test unique IDs + `supabase db reset` between CI runs.
- Don't assert HTTP 403 in RLS isolation tests. Assert empty result sets (`length === 0`). RLS is a row filter, not an access check.
- Don't hard-delete `app_users` rows. Mark `status = 'merged'` or `'banned'`. Deletion of user content is CCPA hard-delete; identity rows are the audit trail.
- Don't refresh `usage_counters.cap_count` on tier upgrade. Snapshot-at-creation is the rule. Non-metered entitlements (voice access, saved favorites) flip immediately; metered quotas catch up next period.

---

## When in doubt

1. Check the spec (`Specs/Stir-Full-Spec.md`).
2. Check the Cook Mode research doc for anything voice-related.
3. If the spec and this file disagree, the spec wins. Tell Daniel about the discrepancy so one gets updated.
4. If something is genuinely ambiguous, surface the decision to Daniel rather than picking silently.
5. If you're about to write code that violates a north-star constraint, stop. They aren't negotiable.
