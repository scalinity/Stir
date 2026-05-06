# CLAUDE.md — Stir

This file is your orientation pack. Trust it as a working cache; the full spec (`Specs/Stir-Full-Spec.md`) and Cook Mode research (`Specs/Stir-Cook-Mode-Architecture.md`) are authoritative.

Daniel is the solo builder. He reads generated code at peer level. Don't simplify unless asked.

---

## The product in three sentences

Stir is an iPhone app for the exact weeknight moment: stand in the kitchen with ingredients, no plan, low energy. Scan → 3 dinners → cook with timers and (on Premium) hands-free voice. iOS 17+, SwiftUI, Gemini-only AI, Supabase operational backend, CloudKit for user content.

## Spec pointers

- **Full spec** (product truth): `Specs/Stir-Full-Spec.md`
- **Cook Mode research**: `Specs/Stir-Cook-Mode-Architecture.md`
- **Design system tokens**: `Specs/Design-System.md`
- **Design mockups** (visual source of truth — 17 HTML prototypes for v1 screens): `stir-app-design/project/DesignMockups/` (see `INDEX.md`). **Read the matching mockup before coding any unimplemented screen** — pixel-truth for layout/typography/spacing/states. Shared CSS tokens in `_shared/colors_and_type.css`; Swift-token provenance in `EXTRACTED_TOKENS.md`. Mockups are NOT authoritative for product content (copy/pricing/tier) — spec wins there.
- **ADRs**: `docs/decisions/`
- **Ops runbooks**: `docs/runbooks/`
- **Deferred work / triggered refactors**: `docs/deferred-work.md`
- Precedence: ADR > spec > this file > mockups (for tokens, mockups override). If mockups disagree with `Design-System.md` on a token, mockups win and §3/§4/§5/§6/§12 of Design-System.md must be updated. Flag discrepancies.

## Decisions system

`docs/decisions/` holds the architectural record. Read `docs/decisions/README.md` for full rules. TL;DR:

- **Create an ADR** when a load-bearing choice is made, a reasonable alternative is rejected, a rule is added/retired, or work is explicitly deferred with a trigger to revisit.
- **Don't create** for day-to-day implementation choices, bug fixes, or anything captured by code shape.
- **Naming**: `NNNN-kebab-short-name.md`, sequential, never recycled/renumbered.
- **Statuses**: `Proposed | Accepted | Deferred | Superseded by NNNN | Rejected`. Superseded ADRs stay with a forward link; rejected ADRs stay so the same idea doesn't cycle back.
- **Template**: `docs/decisions/TEMPLATE.md`. Keep each ADR readable in <5 minutes.
- **Claude's responsibility**: check for prior ADR before load-bearing choices; create ADR BEFORE/ALONGSIDE code (never silently); revert or amend on drift; update the index in `docs/decisions/README.md`.

---

## North-star constraints (invariants — never violate)

1. **Single AI vendor: Google Gemini.** No OpenAI, no Anthropic, no cross-vendor LLM fallback. Production models: `gemini-3-flash-preview`, `gemini-3.1-flash-lite-preview`, `gemini-3.1-flash-live-preview`.
2. **No provider API keys in the iOS bundle, ever.** Cook Mode voice uses ephemeral session tokens minted server-side. The Gemini API key lives in Supabase Edge Function secrets only.
3. **User content lives in CloudKit, not Supabase.** Postgres holds operational metadata only (quotas, entitlements, prompt versions, AI request logs). Pantry/recipes/sessions sync via CloudKit private DB. Don't mirror user content in Postgres.
4. **RLS on every ops table in Supabase.** All rows keyed on `canonical_user_key`. No exceptions, no temporary bypasses.
5. **Hard-rule validator runs on every substitution output,** regardless of invocation path.
6. **Voice is Premium+ only.** Free tier gets unlimited tap-based Cook Mode; voice affordance triggers `ENT-VOICE-01` paywall. Caps: `free: 0`, `premium: 13`, `pro: 27` voice sessions/month (ADR 0015). `effectiveVoiceEnabled()`'s `ENTITLEMENT_OVERRIDE_VOICE_FREE` env hatch is dev/staging only — production must keep it unset (verify via `supabase secrets list --project-ref ktqajarcomzplnpbczfo` before any cap-related deploy). ADR 0008 is Superseded.
7. **Live sessions cannot be pruned mid-session — `refreshSession()` IS pruning.** Gemini Live's protocol has no mid-session truncation frame. Cost is bounded by silently minting a NEW ephemeral token with a compact recap appended to systemInstruction and swapping the WebSocket. Triggers: `turnCount - lastRefreshedAtTurn >= 10` OR `accum_prompt_tokens > 15_000` on a single turn. See ADR 0014.
8. **Voice session `max_output_tokens: 400`** (ADR 0010). Baked into the ephemeral-token mint config, not just client-side. The invariant is "bounded cap exists" — value is tunable. 400 tokens ≈ 16s of audio at 25 tok/s.

---

## Stack snapshot

| Layer | Choice |
| --- | --- |
| iOS minimum | 17.0 |
| Build tooling | Xcode 26+, iOS 26 SDK (Apple App Store rule as of 2026-04-28) |
| UI | SwiftUI, `@Observable` view models |
| Concurrency | Swift Concurrency (async/await, actors) |
| Persistence | Core Data + `NSPersistentCloudKitContainer` |
| Sync | CloudKit private database |
| Backend | Supabase (Postgres + Edge Functions + Auth + pgmq/pg_cron) |
| Payments | RevenueCat over StoreKit 2 |
| Analytics | PostHog |
| Errors | Sentry |
| Push | APNs direct |
| Text AI | `gemini-3-flash-preview` (scan, solve, substitution, cook-turn fallback) |
| Cheap AI | `gemini-3.1-flash-lite-preview` (recipe import normalize, grocery list) |
| Voice AI | `gemini-3.1-flash-live-preview` at `thinkingLevel: minimal` |
| On-device | Vision (OCR, barcode), Speech framework + AVSpeechSynthesizer (voice fallback only) |

---

## Pre-filled constants

### Gemini model strings and pricing

```swift
enum GeminiModel: String {
    case flash            = "gemini-3-flash-preview"
    case flashLite        = "gemini-3.1-flash-lite-preview"
    case flashLivePreview = "gemini-3.1-flash-live-preview"
}
```

Paid tier, per 1M tokens (April 2026):

| Model | Text in | Audio in | Image in | Text out | Audio out | Cache |
| --- | --- | --- | --- | --- | --- | --- |
| gemini-3-flash-preview | $0.50 | $1.00 | $0.50 | $3.00 | — | supported |
| gemini-3.1-flash-lite-preview | $0.25 | $0.50 | $0.25 | $1.50 | — | supported |
| gemini-3.1-flash-live-preview | $0.75 | $3.00 | $0.75 | $4.50 | $12.00 | **not supported** |

Audio tokens on Live: **25 tokens/second** both directions.

### Cost model (device-measured April 2026, post-step-6)

Measured from 9+ turn device sessions, cadence N=4 refresh + pre-mint, 22% tool-call rate. ADR 0014 has the breakdown.

- Voice Cook turn (non-tool, steady-state): **~$0.008** (4,527 prompt tokens + 124 audio out)
- Voice Cook turn (tool-call, double-pass): **~$0.014** (8,822 prompt tokens + 150 audio out)
- Voice session (15 turns, ~22% tool calls): **~$0.13–0.16**
- Voice session (30 turns): **~$0.27–0.32**
- Premium AI / mo target: **$1.89** (22.27% of $8.49 net ARPU); at **13-session × 15-turn cap: ~$1.69–$2.08**.
- Pro AI / mo target: **$3.69**; at **27-session cap: ~$3.51–$4.32**.
- Free AI / mo target: **$0.075** (no voice quota).
- Pantry scan (single-image): **~$0.005** (~258 image-input tokens + ~150 text-out tokens).
- Pantry scan (multi-image, Pro-only, 4-photo): **~$0.018–$0.024** (4× image-input + larger text-out at `maxOutputTokens=4096`). Retry-once intentionally disabled on multi-image (SCA-36 W4) so a schema-validation failure costs 1× rather than 2× — surfaces as AI-02 to the user. `pantry_parse` is unmetered per-user (CLAUDE.md §usage_counters); cost is bounded by `ip:pantry_parse_daily=100`. With multi-image at the upper end, a single IP can soak ~$2.40/day before being rate-limited. **If 95th-percentile per-IP daily pantry-parse cost crosses $0.50, file an ADR to revisit the IP cap or add a `user:pantry_parse_daily` policy at the Pro tier.**

Cost ranges assume 75/25–60/40 text:audio split; PostHog LLM Observability has the per-request breakdown.

**No caching on Live API** — permanent cost-model assumption per ADR 0015. `usageMetadata.cachedContentTokenCount = 0` consistently across 50+ measured device turns. The Gemini 2.5/3 Flash implicit-caching that `generateContent` callers get **does not fire** on `BidiGenerateContent` workloads. **Do NOT build cost-model scenarios, paywall economics, or margin projections that assume non-zero caching savings on voice turns.** Observability is live (`ai_request_log.prompt_cached_tokens`, PostHog `$ai_cache_read_input_tokens`); cap-reversal trigger query in ADR 0015.

### StoreKit SKUs

```
stir.premium.monthly          $9.99/mo     no trial
stir.premium.annual.trial7    $69.99/yr    7-day free trial (PRIMARY paywall CTA)
stir.pro.monthly              $14.99/mo    no trial
stir.pro.annual               $139.99/yr   no trial
```

Subscription group: `stir.subscriptions`. Family Sharing: **off** on all SKUs.

### Apple fee rates

- Year 1 non-SMB: 70% proceeds (30% fee)
- Year 2+ non-SMB: 85% proceeds (15% fee)
- SMB Program: 85% from year 1 (check eligibility near launch)

### Tier entitlements (authoritative)

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

**Preference memory window** is wired via ADR 0030. iOS `PreferenceMemoryService` reads `OutcomeFeedback` from CloudKit, projects into a bounded digest (≤600 prompt tokens), sends as `feedback_summary` on the `/v1/ai/dinner-solve` request body. Server-side kill switch: `feature_flags.preference_memory_enabled` (default true). Tier window is enforced on iOS only — out-of-window ratings never leave the device. North-star #3 holds.

### Gemini Live session constants

```swift
enum LiveSessionLimits {
    static let maxSessionDurationSec       = 30 * 60   // Gemini hard limit
    static let idleDisconnectSec           = 15 * 60   // Gemini hard limit
    static let contextWindowTokens         = 131_072   // effectively non-binding with refresh cadence
    static let refreshAtElapsedSec         = 10 * 60   // Stir policy
    static let refreshAtTurnCount          = 4         // Stir policy (ADR 0014)
    static let refreshAtPromptTokenCount   = 10_000    // Stir policy (burst trigger; ADR 0014)
    static let maxOutputTokens             = 400       // Stir policy, baked into token mint (ADR 0010)
    static let tokenSoftCapPerSession      = 40_000    // alert threshold
    static let tokenHardCapPerSession      = 80_000    // force session reset
    static let tokenMintOpenWindowSec      = 60        // new_session_expire_time offset
    static let tokenMintHardDeadlineSec    = 35 * 60   // expire_time offset
    static let tokenMintUses               = 1         // one session per token
    // Removed: pruneKeepLastNTurns — Live has no mid-session truncation; refresh IS pruning. ADR 0014.
}
```

### Endpoints

Supabase (prefix `$SUPABASE_URL/functions/v1`):

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

Google Gemini (Edge Functions only; iOS never calls directly except the Live WebSocket):

```
POST https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent
POST https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite-preview:generateContent
POST https://generativelanguage.googleapis.com/v1alpha/authTokens   # Live mint (v1alpha)
WSS  wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent
```

### Error code matrix

User-visible messages live in spec §6; codes here.

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
    case entMultiImage01 = "ENT-MULTI-IMAGE-01"  // multi-image scan requires Pro
    case entLeftovers01  = "ENT-LEFTOVERS-01"    // leftovers requires Premium+
    case voiceSession01  = "VOICE-SESSION-01"
        // session lifecycle: session_missing / owner_mismatch / session_closed (HTTP 403) /
        // lookup_failed (HTTP 500). ADR 0017. Distinct from ENT-VOICE-01 / AI-VOICE-01.
    case val01       = "VAL-01"         // request body failed Zod validation (client bug)
    case auth01      = "AUTH-01"
        // missing/expired/malformed/signature_invalid/user_stale/reauth_required.
        // First 5 → silent re-bootstrap; reauth_required → SIWA re-flow (ADR 0023).
    case methodNotAllowed01 = "METHOD-NOT-ALLOWED-01"  // 405, client bug, never user-visible
}
```

### VAL-01 response shape (400)

```json
{
  "error": "VAL-01",
  "message": "Request body failed validation: 'installation_id' must be a UUID",
  "field_errors": [
    { "field": "installation_id", "issue": "Expected UUID, got 'abc123'" }
  ]
}
```

`message` is dev/Sentry-facing; `field_errors` is structured for iOS dashboards/tests. User-visible copy lives in iOS `ErrorPresenter`. Server logs at `warn` (every one is a client bug worth investigating). iOS: log to Sentry at `error` with full `field_errors`; show generic copy; **do not retry**; do not cache.

### AUTH-01 response shape (401)

```json
{
  "error": "AUTH-01",
  "message": "Session expired or missing",
  "reason": "expired" | "missing" | "malformed" | "signature_invalid" | "user_stale" | "reauth_required"
}
```

| `reason` | Cause | iOS action | Server log |
| --- | --- | --- | --- |
| `missing` | No `Authorization` header | Silent re-bootstrap | `info` |
| `expired` | JWT past `exp` | Silent re-bootstrap | `info` |
| `malformed` | Invalid JWT structure | Re-bootstrap + Sentry error | `error` |
| `signature_invalid` | Signature doesn't verify | Re-bootstrap + Sentry error + alert at threshold | `error` |
| `user_stale` | `canonical_user_key` no longer resolves | Silent re-bootstrap | `info` |
| `reauth_required` | JWT.iat predates `app_users.reauth_required_at` | **SIWA re-flow** (rotate Keychain install_id, clear canonical key) — NOT silent retry | `info` |

iOS silent-refresh pattern (all reasons except `reauth_required`): clear cached JWT, re-bootstrap, retry **once**. If retry also 401s, surface NET-01 — never retry-storm. `reauth_required` maps to `ReAuthenticationIntent.forceReauth` → SIWA screen. `reason` is a typed field, not parsed from `message`.

### Canonical user key

```
canonical_user_key = "ck:<userRecordName>"           // if CloudKit account available
                   | "install:<keychainInstallId>"   // fallback
```

When an `install:`-keyed user later gains CloudKit, **alias forward** in RevenueCat and `app_users.merged_into`. Never back-fill user content; always alias forward via the identity table.

### Aliasing when install:<id> gains CloudKit AND ck:<record> already has rows

Reinstall + same iCloud, or sign-out/sign-in mid-session, produces two rows with data. Merge inside one Postgres transaction:

| Table | Merge rule | Why |
| --- | --- | --- |
| `usage_counters` | **SUM** `used_count` per `(period_start, feature_key)` onto ck row; delete install rows | Blocks quota-reset abuse |
| `entitlement_snapshots` | **ck wins** | RevenueCat webhook keyed on ck |
| `ai_request_log` | **UPDATE** `canonical_user_key` install→ck | Preserves cost attribution |
| `device_installations` | **UPDATE** install→ck | Device belongs to ck user now |
| `app_users` (install row) | SET `merged_into = ck`, `status = 'merged'`; **never hard-delete** | Audit trail |
| `app_users` (ck row) | Winning row; update `last_seen_at` | The survivor |

1. **Don't clamp summed quotas to cap.** install=5/6 + ck=4/6 → 9. Quota check `used_count >= cap_count` correctly locks out. Clamping = abuse vector.
2. **RevenueCat re-alias runs AFTER DB transaction commits.** External call's failure shouldn't roll back the merge. Retry via background job.
3. **Merge runs synchronously in `/v1/session/bootstrap`,** not async. 100ms latency acceptable; async risks phantom quota.

Transaction failure twice → return `VAL-01` with merge-failure detail in `message`, log Sentry `error`.

### `app_users.status` enum

Values: `active | merged | banned`. Native Postgres ENUM, partial index where status != 'active'.

| From | To | Trigger |
| --- | --- | --- |
| `active` | `merged` | Identity alias-forward in `/v1/session/bootstrap` |
| `active` | `banned` | Admin action via `/v1/ops/admin/*` |
| `merged` | — | **Terminal.** Un-merging not supported (can't un-sum counters cleanly) |
| `banned` | `active` | Manual admin unban |

Bootstrap: `merged` row → follow `merged_into` one hop (nested merges are a bug); `banned` → 403 + `BILL-01`. Never soft-delete; deletion is hard-delete per CCPA (spec §11).

### `entitlement_snapshots.billing_state` enum

Values: `none | active | trial | grace | cancelled_active | expired`. Native Postgres ENUM, partial index where state != 'none'.

**Orthogonal to `tier`:** `tier` says *what* they're entitled to; `billing_state` says *why* and what to show.

| Value | Meaning |
| --- | --- |
| `none` | Free tier, never purchased |
| `active` | Paid and current |
| `trial` | Intro offer in progress (Premium annual only) |
| `grace` | Apple billing retry in progress; user retains paid access; iOS shows BILL-01 banner |
| `cancelled_active` | Cancelled; access continues until period_end |
| `expired` | Paid access ended (eligible for win-back, distinct from `none`) |

RevenueCat webhook → state mapping:

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

Bootstrap resolution: `none|expired` → Free; `active|trial|grace|cancelled_active` → paid per `tier`; `grace` adds `billing_retry_banner: true`.

### `usage_counters` feature keys + period semantics

Metered keys: `dinner_solve | voice_cook_session | recipe_import` (native ENUM).

**Not metered here:**
- `remembered_pantry_items`: standing cap, not monthly. Enforced client-side against CloudKit count.
- `scan_parse`, `substitution`, `grocery_generate`, `cook_turn`: unmetered. Cost in `ai_request_log` only.

**`cap_count` is SNAPSHOTTED at row-creation** from the active tier. Mid-month upgrade does **not** refresh `cap_count` on existing period rows. Non-metered Premium entitlements (voice access, favorites, widgets) unlock immediately; metered quotas catch up next period. Paywall copy: "You'll get full Premium Dinner Solves at your next monthly reset on <date>."

**Why snapshot:** refresh-on-upgrade creates an abuse vector (upgrade mid-month to reset, downgrade after) and a race (webhook fan-out vs concurrent increments). Snapshot is atomic and predictable.

**Atomic quota check** (the reason cap_count lives in this table, not derived via JOIN):

```sql
UPDATE usage_counters
   SET used_count = used_count + 1, updated_at = now()
 WHERE canonical_user_key = $1
   AND period_start = $2
   AND feature_key = $3
   AND used_count < cap_count
RETURNING used_count, cap_count;
```

One round trip, no race, no join. Empty return = capped.

**`period_start` semantics:** uses `app_users.created_at` month-day as anchor. Joined on the 17th → monthly periods start on the 17th. No mid-month cliff for new signups; matches Apple's renewal pattern.

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
    "expires_at": "2027-04-18T00:00:00Z" | null,
    "voice_enabled": true | false,
    "billing_retry_banner": true | false,
    "quotas": [
      { "feature_key": "dinner_solve", "used": 3, "cap": 6, "period_end": "2026-05-17" }
    ]
  },
  "feature_flags": [
    { "key": "disable_cook_realtime", "value": false, "is_enabled": true, "rollout_pct": 100 }
  ]
}
```

**Bootstrap does NOT return `prompt_versions`** — that's `/v1/config/bootstrap` only.

Shape rules:

- `voice_enabled` is **SERVER-COMPUTED** (`tier IN ('premium','pro') AND billing_state IN ('active','trial','grace','cancelled_active')`), never derived on iOS.
- `quotas` is an **array** (iterable), not a keyed object. Fields are `used`/`cap`/`period_end` — not `used_count`/`cap_count`/`period_start`.
- `period_end` is **always included**, never client-computed.
- `feature_flags` is an **array of metadata objects** (`key`, `value`, `is_enabled`, `rollout_pct`) — not a flat map.
- Single `expires_at` covers trial + subscription end; `is_trial` disambiguates.
- Nested `entitlements` (not flattened).
- Timestamps absolute UTC; iOS localizes.

### `/v1/config/bootstrap` response shape

```json
{
  "entitlements": { ... same shape as bootstrap.entitlements ... },
  "feature_flags": [ ... same shape ... ],
  "prompts": [
    {
      "feature_key": "dinner_solve",
      "version": "0.0.0",
      "provider_model": "gemini-3-flash-preview",
      "schema_hash": "",
      "is_default": true,
      "is_enabled": false
    }
  ]
}
```

`prompts` is rich-object so iOS emits `prompt_version` telemetry without an extra lookup. iOS: `EntitlementService` stores entitlements + quotas in memory + Keychain (24h offline fallback). Every feature gate reads from `EntitlementService`.

### Feature flags

Client (PostHog): `paywall_variant`, `widget_nudge_enabled`, `leftovers_mode_enabled`.

Server (Supabase `feature_flags`):
- `prompt_version_override`
- `recipe_import_async_threshold`
- `priority_queue_pro_enabled`
- `cook_voice_thinking_level` ∈ {`minimal`, `low`}
- `cook_voice_default_on` — auto-engage first voice turn on Cook Mode entry
- `voice_turn_detection_mode` ∈ {`semantic_vad`, `server_vad`} — VAD profile, consumed at mint
- `disable_scan_parse`
- `disable_cook_voice` / `disable_cook_realtime` (alias)
- `disable_imports`
- `force_saved_meals_only`
- `preference_memory_enabled` — SCA-44 / ADR 0030. Default true. When false, dinner-solve renders `feedback_json` as null even when iOS sent a populated `feedback_summary` in the request body. Failing-open on flag-read errors.

### Expected environment variables

Backend (Supabase Edge Function secrets):

```
GEMINI_API_KEY     # legacy-format key (AIzaSy..., 39 chars). AQ.xxx fails on auth_tokens (sharp-edge #18). Project MUST be on paid tier (sharp-edge #17).
STIR_JWT_SECRET    # HS256 signer. Renamed from SUPABASE_JWT_SECRET — Supabase reserves SUPABASE_* and filters those secrets from .env.
REVENUECAT_WEBHOOK_SECRET
APNS_AUTH_KEY_ID
APNS_AUTH_KEY_P8   # base64-encoded
APNS_TEAM_ID
APNS_BUNDLE_ID
POSTHOG_API_KEY
SENTRY_DSN
LOG_IP_SALT        # 32-byte hex, HMAC-SHA256 input for ipBucket(). Rotated monthly (docs/runbooks/ip-salt-rotation.md). If unset: falls back to FNV-1a + once-per-isolate stderr warning. MUST be set before first beta invite.
STIR_PGMQ_DISPATCH_SECRET  # 32-byte hex, shared with `app.stir_pgmq_dispatch_secret` Postgres setting. pgmq-dispatch rejects calls without matching `X-Stir-Cron-Secret` header. If unset: function accepts unauthenticated calls + once-per-isolate warn. MUST be set before exposing the function to a public URL (i.e., before beta).
```

iOS (`Config.xcconfig`, gitignored; `Config.xcconfig.example` documents shape):

```
SUPABASE_URL
SUPABASE_ANON_KEY              # used only for /v1/session/bootstrap (RLS-enforced)
REVENUECAT_PUBLIC_API_KEY
POSTHOG_PUBLIC_API_KEY
SENTRY_DSN_PUBLIC
```

Never present anywhere: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY on iOS`.

---

## Repo layout

```
Stir/                            # iOS app target
  App/                           # StirApp, RootCoordinator
  DesignSystem/                  # tokens + shared views
  Core/Models/                   # domain types
  Core/Repositories/             # Core Data + sync
  Core/Services/                 # cross-feature (EntitlementService, QuotaService, AIDispatch)
  Features/                      # Onboarding/ Tonight/ Scan/ Solve/ CookMode/ Import/ Saved/ Settings/ Billing/
  Integrations/                  # Camera/ Speech/ Vision/ Reminders/ CloudKit/ RevenueCat/ PostHog/ Sentry/ GeminiLive/
  Extensions/                    # ShareExtension/ Widgets/ AppIntents/
  Tests/                         # Unit/ Integration/ UITests/

Backend/supabase/
  migrations/                    # SQL schema + RLS (canonical_user_key-keyed)
  functions/_shared/             # auth verify, gemini client, hard-rule engine, validators
  functions/<endpoint>/          # one folder per /v1/... endpoint
  seed/                          # prompt_versions defaults, feature flag defaults

Specs/                           # product spec + research + design system
stir-app-design/                 # design handoff bundle (visual source of truth — see INDEX.md)
docs/decisions/                  # ADRs (includes rejected paths)
docs/runbooks/                   # operational procedures
docs/deferred-work.md            # tracked tech debt + triggered refactors
```

---

## AI pipeline map

| Feature | Endpoint | Model | Streaming | Guardrail |
| --- | --- | --- | --- | --- |
| Pantry scan parse | `/v1/ai/pantry-parse` | gemini-3-flash-preview | no | schema + confidence threshold |
| Dinner solve | `/v1/ai/dinner-solve` | gemini-3-flash-preview | yes (card-by-card) | hard-rule validator, retry on violation. Consumes optional on-device `feedback_summary` digest (ADR 0030); v2.0.0 prompt at 5% canary via `pickStandardPrompt`, v1.0.0 default. |
| Cook Mode voice turn | Live WS via `/v1/ai/realtime-session` token | gemini-3.1-flash-live-preview (minimal) | native bidi audio | system prompt, max_output_tokens, refresh-bounded growth |
| Cook Mode substitution (voice path) | Live function call → `/v1/ai/substitution` | gemini-3-flash-preview | no | hard-rule validator (same engine) |
| Cook Mode Q&A fallback | `/v1/ai/cook-turn` | gemini-3-flash-preview (text) | no | schema |
| Substitution (sheet) | `/v1/ai/substitution` | gemini-3-flash-preview | no | hard-rule validator |
| Recipe import | `/v1/ai/recipe-import` | gemini-3.1-flash-lite-preview | no | sanitize HTML, treat content as untrusted |
| Grocery generate | `/v1/ai/grocery-generate` | gemini-3.1-flash-lite-preview | no | post-model dedupe |

---

## Gemini Live — the sharp-edges section

Where Gemini Live differs from OpenAI Realtime. Assume OpenAI-Realtime intuition until this section says otherwise.

1. **No caching.** Every turn re-sends context at full audio-input rate. Pruning to last 3 turns after every step advance is mandatory. Skipping = linear cost blowup.
2. **No first-class WebRTC.** WebSocket only, via `URLSessionWebSocketTask`. Cellular networks occasionally stall on TCP head-of-line blocking. Don't "switch to WebRTC" — not supported.
3. **Preambles are NOT spontaneous, and adherence is UNVALIDATED.** Unlike `gpt-realtime`, Gemini doesn't naturally say "let me check" before tool calls. The system prompt asks for it but adherence under MINIMAL is unbenchmarked. **Belt-and-suspenders required:** iOS plays a pre-recorded filler clip the instant a `toolCall` frame arrives, covering the ~2s round-trip deterministically. If `preamble_present_rate` <90%, disable model preambles via system prompt and rely on the client clip alone.
4. **Preview status.** If Google changes API shape or pricing, `disable_cook_realtime` routes all Premium+ voice to text fallback with `AI-VOICE-01` banner.
5. **Ephemeral tokens have two expiries.** `new_session_expire_time` = window to open (~60s). `expire_time` = hard deadline (~35 min from mint). `uses: 1`.
6. **Session refresh is silent by design.** 10 min or 15 turns, whichever first. Mint new token, open new WebSocket, close old after new one's first response lands. Refresh failure → text fallback.
7. **Semantic VAD is the starting choice, server VAD the fallback.** Semantic chunks on utterance completion; avoids ambient kitchen noise misfires. Flip `voice_turn_detection_mode` if testing shows misfires.
8. **`max_output_tokens: 400`** (ADR 0010). Baked into the mint's `generation_config`. Invariant is "bounded cap exists" — value tunable.
9. **Function response flow differs.** Gemini auto-continues after `BidiGenerateContentToolResponse`. No `response.create` (unlike OpenAI Realtime). Function responses go via `toolResponse` carrying matching `functionResponse.id` — NOT `clientContent`.
10. **Audio format.** PCM16 at 16kHz input; base64-encoded in `realtimeInput.audio`. Server returns base64 in `serverContent.modelTurn.parts[].inlineData`.
11. **`clientContent` is history-only on 3.1 Flash Live.** For in-session text injection (step advance, timer completion, substitution context), use `realtimeInput.text`. `clientContent` only seeds initial history (requires `initial_history_in_client_content: true`); Stir doesn't seed history, so don't use `clientContent`.
12. **Tool calls are synchronous.** No async/parallel function calls. One in flight at a time. Don't design flows assuming concurrent substitution+timer.
13. **Auth header is `Authorization: Token <value>`,** not `Bearer`. Easy to get wrong because the rest of Google's API ecosystem uses `Bearer`.
14. **Token mint endpoint is `POST /v1alpha/auth_tokens`** (snake_case). WebSocket for ephemeral tokens is `/v1alpha.GenerativeService.BidiGenerateContentConstrained?access_token=<name>` (NOT `/v1beta`). API-key path uses `/v1beta.GenerativeService.BidiGenerateContent?key=<KEY>`. Official docs: https://ai.google.dev/gemini-api/docs/live-api/get-started-websocket#authentication-with-ephemeral-tokens. **Request body is flat camelCase** (not snake_case, not wrapped in `{ authToken: {...} }`): `{ expireTime, newSessionExpireTime, uses, bidiGenerateContentSetup: { model, generationConfig: { responseModalities, speechConfig, maxOutputTokens, thinkingConfig }, systemInstruction, tools, realtimeInputConfig: { automaticActivityDetection, turnCoverage } } }`. Verified against `googleapis/js-genai`.
15. **Undocumented ~200-token AUDIO-mode overhead per turn.** Every Live turn with `response_modalities: [AUDIO]` charges ~200 extra audio-input tokens beyond literal audio — even on text-only input. Reliably observed in `usageMetadata.prompt_tokens_details`. Cost model accounts for it.
16. **Mint uses API-key auth** — same `GEMINI_API_KEY` that serves `generateContent`. No OAuth needed once #17 + #18 are satisfied. Mint header: `x-goog-api-key: <GEMINI_API_KEY>`. WebSocket auth from iOS: returned `.name` (e.g. `auth_tokens/<id>`) goes in URL as `?access_token=<name>` — no `Authorization` header. ADR 0006 (OAuth path) is Rejected.
17. **Mint requires paid-tier billing on the GCP project that owns the key.** Free-tier returns `400 INVALID_ARGUMENT` with no billing-specific detail — indistinguishable from a malformed body. `generateContent` and `models.list` work on free tier and mislead. Verify in https://aistudio.google.com/app/apikey: billing account attached AND explicitly on paid tier (separate things).
18. **Mint rejects new-format API keys** (`AQ.xxx`, ~53 chars). Use legacy-format (`AIzaSy...`, 39 chars). `generateContent` accepts both — hidden failure mode. Google forum thread 141133; fix timeline unknown.
19. **Ephemeral-token sessions still require a client-sent `{"setup": {...}}` frame** as the first WS message after `open`. The mint-baked `bidiGenerateContentSetup` is an authorization *ceiling*; server does NOT auto-emit `setupComplete`. Symptom of missing the frame: `setupComplete` never arrives, `awaitSetupComplete` timeout fires. Stir backend pre-serializes the exact setup frame at mint time and returns it as `setup_frame_json`; iOS forwards verbatim via `LiveOutboundFrame.setup(payload:)`.
20. **Preview API drops load-bearing frames.** `gemini-3.1-flash-live-preview` can omit `turnComplete` or `setupComplete` without warning. Observed (2026-04-23): after `start_timer`, three generation passes emitted `generationComplete` each but no `turnComplete`; iOS state machine pinned in `.modelSpeaking` 35+s. **Defensive-by-default:** every `await` on a Gemini-initiated state transition (setupComplete, turnComplete, first audio chunk, pre-mint swap) MUST have a client-side timeout + graceful recovery. `turnStuckWatchdog` in `RealtimeSession.swift` (8s threshold, armed on `.modelSpeaking`, rearmed on inbound audio, cancelled on transition out). On fire: synthesize `turnComplete`, persist VoiceTurn `resultType='error'/errorCode='turnComplete_timeout'`, emit `voice_turn_stuck_watchdog_fired`. Threshold: >5% of tool-call turns in 7-day window = revisit spec §18 vendor contingency. SpeechFallbackService (HTTP + AVSpeechSynthesizer) has zero exposure to this class. Revisit Live-path timeouts when the model moves to GA.

---

## Backend contracts

All `/v1/*` authenticate via session JWT from `/v1/session/bootstrap`. Admin `/v1/ops/*` uses Supabase Auth admin role + RLS.

Shared behaviors:
- 400 → `{ error: "VAL-01", message, field_errors }`
- 401 → `{ error: "AUTH-01", message, reason: "missing|expired|malformed|signature_invalid|user_stale|reauth_required" }`
- 403 entitlement → `ENT-VOICE-01` / `ENT-LEFTOVERS-01` / `ENT-MULTI-IMAGE-01` / `BILL-01`
- 429 quota → `RATE-01`
- 502 Gemini outage → `AI-01`
- Every body: `{ error: CODE, message: string, ...structured }`. Never string-only error. Never empty 4xx/5xx body.
- Idempotency via explicit request IDs (spec §3 API table)
- Every AI call logs to `ai_request_log` with `{ provider, model, input_tokens, output_tokens, cost_usd, latency_ms, thinking_level, prompt_version }`

Edge Function conventions:
- Deno runtime, one function per `/v1/...` endpoint
- Shared helpers in `_shared/` (relative imports; no npm deps unless unavoidable)
- Secrets via `Deno.env.get(...)` — never hardcoded
- Validate session JWT first via shared helper
- Zod schema validation at handler boundary (before any DB access)
- **Every new `/v1/ai/*` (or any JWT-verifying) function MUST have `[functions.<name>] verify_jwt = false` in `Backend/supabase/config.toml`.** Without it, Kong rejects every authenticated POST at the platform layer with an opaque 401 before the handler runs — typed AUTH-01 reason never reaches the client. Land in the SAME PR as the function.

---

## Integration test DB strategy

Per-test unique IDs, no cleanup between tests. `supabase db reset` between CI runs.

- Test helpers generate fresh UUIDs for `installation_id` and CK record names
- Test-scoped keys prefixed `test:` (e.g., `install:test:<uuid>`); cleanup via `DELETE ... WHERE canonical_user_key LIKE 'install:test:%' OR canonical_user_key LIKE 'ck:test:%'`
- Aggregate-style assertions (COUNT, SUM without WHERE) are **banned** — always filter by test-scoped keys
- Service-role client is used **only** in test seed helpers; never in production code paths
- RLS tests assert **empty result sets** (`length === 0`), **never** 403. RLS is a row filter, not an access check
- Don't use `beforeEach` TRUNCATE: slow, and creates "tests pass until someone adds a new table" bugs
- Don't wrap tests in transaction rollbacks: PostgREST doesn't expose transaction handles

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

Notes on DB column types/constraints that init migration COMMENTs and first-glance schema reading get wrong. Rule: **for column types, check the DB (`\d <table>`) or the latest `ALTER` — not the init migration.**

### Retconned column types

| Column | Now | Changed in |
| --- | --- | --- |
| `device_installations.installation_id` | UUID (was TEXT) | `20260418000022_tighten_column_constraints.sql` |
| `app_users.current_install_id` | UUID (was TEXT) | same migration |
| `ops_flagged_outputs.request_id` | TEXT (was UUID) | `20260424000002_request_id_text_consolidation.sql` — matches `ai_request_log.request_id` + accepts `'voice:<session>:<turn>'` shape |
| `audit_log.request_id` | TEXT (was UUID) | same migration |

`COALESCE(current_install_id, '')` or `... ILIKE '%' || v || '%'` against UUID raises `22P02 invalid input syntax for type uuid`. Cast `::TEXT` before COALESCE/concatenation.

### New columns / uniqueness

| Column/index | Purpose | Added in |
| --- | --- | --- |
| `ai_request_log.session_id UUID` | voice session id; replaces `split_part(request_id,':',2)`; partial index `idx_ai_request_log_voice_session` on `(feature_key, session_id, created_at DESC) WHERE feature_key='cook_mode_realtime'` | `20260424000003_performance_indexes_and_session_id.sql` |
| `UNIQUE(canonical_user_key_hash, request_id)` on `ops_flagged_outputs` | atomic dedup | `20260424000002` |
| `idx_app_users_last_seen_at` partial on `status='active'` | hot path for `stir_ops_list_users` + reactivation | `20260424000003` |
| `cost_anomalies` two-phase dispatch: `dispatched_at`, `sentry_request_id`, `confirmed_at`, `confirm_attempts` | Sentry outage no longer silently loses alerts | `20260424000004` |

### Column-value CHECK constraints worth knowing

| Column | Allowed values | Enforced by |
| --- | --- | --- |
| `device_installations.apns_environment` | `'production'` OR `'sandbox'` | `device_installations_apns_environment_check` |
| `ops_flagged_outputs.flag_reason` | `length(...) <= 500` | `ops_flagged_outputs_flag_reason_check` |
| `ops_flagged_outputs.context_snapshot_json` | `pg_column_size(...) <= 4096` | `ops_flagged_outputs_context_snapshot_size_check` |
| `ops_flagged_outputs.canned_fallback_json` | `pg_column_size(...) <= 65536` | `ops_flagged_outputs_canned_fallback_size_check` |

iOS `/v1/push/register` must send exactly `'production'` or `'sandbox'` — `'development'` is rejected with VAL-01 (Zod ideally, DB CHECK as last line).

---

## Billing model

- **RevenueCat is entitlement source of truth.** Webhook → `entitlement_snapshots` updates → app pulls via `/v1/config/bootstrap` on next foreground.
- **Grace period:** 24h local cache if RevenueCat is unreachable.
- **Trial state:** RevenueCat carries `is_trial`. Show days-remaining in Settings + Plan & Billing. Push at 2 days remaining (opt-in, single send).
- **Intro offer eligibility:** Apple platform enforces one per Apple ID per subscription group. Not our problem.
- **Cohort math:** spec §9. Pro annual year-1 margin is ~$4.13/mo after April 2026 pricing — flag before raising the voice cap or reducing Pro annual below $139.99.
- **Paywall trigger:** `voice_affordance_tapped` on Free is the highest-intent moment. Lead with `stir.premium.annual.trial7`, always.
- **Pro voice cap = 27/mo** (ADR 0015; was 40, was 60). Pro annual $139.99 specifically because Pro users skew toward the cap; the headroom also leaves room for founder-discount offer codes during beta.
- **Premium voice cap = 13/mo** (ADR 0015; was 20).

---

## Telemetry events

Canonical list. Don't invent new names without updating spec §15 AND this file.

```
app_opened, onboarding_started, onboarding_completed,
camera_permission_result, scan_started, scan_submitted, scan_parse_completed,
# SCA-35: scan_submitted + scan_parse_completed carry `image_count` (1..4).
# 1 = singular wire path (Free/Premium/Pro single-photo); 2..4 = Pro
# multi-image scan via `images[]` plural payload. See spec §15.
# SCA-36 W8/W16: the `image_count` *wire* field was dropped from
# `PantryParseRequest` (iOS DTO + Zod). The `image_count` *telemetry
# property* on these events stays (1..4 — derived from `images.count`
# or 1 for singular). Backend computes the count from `images?.length
# ?? 1`; do NOT add a wire field "to be safe" — the redundancy was
# the bug.
ingredient_corrected, constraints_set,
# SCA-44: dinner_solve_requested gains `feedback_summary_present: bool` +
# `recent_meal_count: int` (ADR 0030). True iff iOS sent a non-nil
# preference-memory digest (depends on rated meals existing inside the
# tier window — Free 30d / Premium 90d / Pro 365d). recent_meal_count is
# the un-capped total in the window (recent_meals[] on the wire is
# capped at 10). See spec §15 dinner_solve_requested clarification.
dinner_solve_requested, dinner_solve_completed, suggested_dish_selected,
cook_mode_started, cook_step_advanced, timer_started,
voice_affordance_tapped, cook_turn_submitted, cook_turn_resolved,
voice_session_token_snapshot, voice_session_refreshed,
voice_turn_stuck_watchdog_fired,
substitution_requested, substitution_accepted,
cook_session_completed, meal_rated, meal_rating_skipped,
pantry_auto_consume_resolved,
grocery_list_exported, favorite_saved,
recipe_import_started, recipe_import_completed,
paywall_viewed, trial_started, trial_reminder_sent,
purchase_started, purchase_completed, restore_purchases_tapped,
entitlement_state_changed, reactivation_notification_opened,
widget_added, shortcut_run,
ai_request_completed, ai_request_failed,
screen_error_shown, sync_state_changed,

# SCA-5 / 5b / 12 / 13 / 14 / 19 / 28 / 30 — in-app tutorials. SCA-19
# replaced the coach-mark/spotlight system with full-screen animated
# walkthroughs; SCA-28 promoted lifecycle scaffolding into
# `TutorialFlowHost` and split the variant-aware pantry tour into two
# files; SCA-30 added the missing Saved tab tutorial. All events
# carry `tutorial_id` (snake_case TutorialKey.rawValue: tonight_tour
# [4 steps], scan_capture [3], scan_review [3], dinner_options [2],
# dish_preview [2], cook_mode_tap [3], voice_mode [2], saved_meals [3],
# pantry_management [2], pantry_in_list_tour [3 — populated],
# pantry_in_list_tour_empty [2 — empty]). step_advanced
# adds `from_step` + `to_step` (snake_case step IDs; variant-prefixed
# `populated_*`/`empty_*` keep PantryInList cohorts split under their
# distinct TutorialKey rawValues). Lifecycle invariant:
# exactly one of {completed, skipped} per started. **Disappear is
# non-terminal** — suspend() emits NO telemetry; tour re-arms when
# host re-appears. Backgrounding/app-kill mid-tour without explicit
# resolution is a third state — funnel queries compute abandonment as
# count(started) − count(completed) − count(skipped). No `reason`
# property on tutorial_skipped (earlier drafts proposed
# "navigated_away"; SCA-17 reverted to keep the lifecycle invariant
# clean).
tutorial_started, tutorial_step_advanced, tutorial_completed, tutorial_skipped
```

**Ops surface events** (dotted form per ADR 0027 — new surfaces use `<surface>.<noun>.<verb_or_state>`; spec §15 events grandfathered flat):

```
ops_admin.users.list_queried, ops_admin.users.detail_viewed,
ops_admin.users.quota_reset, ops_admin.users.status_changed,
ops_admin.users.force_reauth,
ops_admin.flagged_outputs.resolved,
ops_admin.prompt_versions.rollout,
ops_admin.feature_flags.updated
```

Wired in `Backend/supabase/functions/ops-admin/index.ts`. Property contract via `emitOpsEvent` helper. Schema: `docs/telemetry/canonical-properties.md` + ADR 0027.

Anchors:
- `core_success_event`: scan → select → cook within 3 min → rate ≥4
- `voice_conversion_event`: voice_affordance_tapped(free) → paywall_viewed → trial_started → purchase_completed

`paywall_viewed.trigger` values: `dinner_solve_quota_exhausted`, `pantry_cap_reached`, `recipe_import_quota_exhausted`, `saved_favorites_gate`, `widgets_gate`, `leftovers_gate`, `multi_image_scan_gate`, `settings_upgrade`, `voice_affordance_tapped`, `voice_cook_quota_exhausted`. Mirrored 1:1 with `PaywallTrigger.telemetryValue` (iOS); enumerated also in spec §15 paywall_viewed.trigger clarification.

PostHog LLM Observability events (`$ai_generation`, `$ai_trace`) are SEPARATE from product events — they feed PostHog's LLM Analytics dashboards. Every AI call emits both an `ai_request_log` row AND a `$ai_generation` event; link is `$ai_span_id = ai_request_log.request_id`. Spec §15 has property tables. Privacy: no `$ai_input` / `$ai_output_choices`, no user content, ever (ADR 0009).

---

## Verification flows

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

When changing an AI feature, run its eval before committing. When changing a prompt, bump `prompt_versions.version` semver and set `rollout_pct` conservatively (start at 5%).

---

## Git workflow

**Rule:** every commit gets pushed to `origin/<branch>` in the same session, without asking. Pre-authorized. Solo dev — no PR gate. Amending and `--force-with-lease` to `main` are also pre-authorized; both override the user-level git rules for this project. Plain `--force` (no lease) still needs explicit confirmation — `--force-with-lease` is the safe default because it refuses to overwrite if the remote has new commits.

---

## Linear issue workflow

**Rule:** every time Daniel raises a bug, issue, feature request, or any work item against the app — even if mentioned conversationally — open a Linear issue under the **Stir** project (Scalinity team, key `SCA`) **before** writing code. Pre-authorized; do not ask.

| Step | What | When |
| --- | --- | --- |
| 1 | `mcp__linear-server__save_issue` with `team: "Scalinity"`, `project: "Stir"`, `assignee: "@scalinity"`, `state: "In Progress"`, populated repro / root cause / fix plan / files | At the moment the work item is identified — before any edits |
| 2 | Implement the fix; run the relevant test/eval; verify the original repro is gone | Same session |
| 3 | `mcp__linear-server__save_issue` with `id: "SCA-N"`, `state: "Done"` | The instant the fix lands locally and tests pass |
| 4 | Stage the changed files, commit (Conventional Commits — `fix(scope): subject (SCA-N)` or `feat(scope): …`), and **push to `origin/<branch>`** | Same session, after marking the issue Done |

**State vocabulary** (from `mcp__linear-server__list_issue_statuses` for Scalinity): `Backlog | Todo | In Progress | In Review | Done | Canceled | Duplicate`. Use `In Progress` while working, `Done` when the change is merged + pushed. Never leave an issue in `In Progress` across sessions — either flip it to `Done`, downgrade to `Todo`, or cancel.

**What counts as a "work item":** UI bug, crash, regression, copy/UX nit, design fidelity gap, perf complaint, missing feature, follow-up triggered by review feedback, anything Daniel describes with "this is broken / this should / can we add". Idea-stage brainstorming that explicitly says "thinking out loud" or "don't act on this yet" is the only opt-out — confirm before skipping issue creation.

**Issue body must include:** repro steps, expected vs actual, root cause (if known), proposed fix with file:line references, test plan, files-touched list. The agent that picks this up should be able to ship without re-investigating.

**Don't:** open duplicate issues for the same bug in one session; reopen Done issues (open a new one and link it via `related`); create issues in any project other than Stir without explicit redirection.

---

## Deploy workflow — local and prod in lockstep

**Rule:** every change that lands locally must also land on Stir prod Supabase, in the same session, without asking. Pre-authorized.

**Prod project:** `ktqajarcomzplnpbczfo` ("Stir", West US Oregon). The shell exports `SUPABASE_URL=https://zfaucivtzfwnrijsbfug.supabase.co` — that's **MindFriend**, a separate project. Always pin via `supabase link --project-ref ktqajarcomzplnpbczfo` before pushing. Confirm `supabase migration list` aligns local+remote before any push.

| Local action | Prod follow-up (same session) |
| --- | --- |
| New migration applies cleanly via `supabase db reset` | `supabase db push` |
| `supabase functions serve --env-file .env` passes smoke tests | `supabase functions deploy <name>` for each changed function |
| New secret referenced via `Deno.env.get` | `supabase secrets set <KEY>=<VALUE>` on prod **before** deploying the function that reads it |
| Prod DDL lands | `get_advisors` (security + performance) — fix WARN+ in a follow-up migration same session; INFO-level `rls_enabled_no_policy` on `app_users`/`feature_flags`/`prompt_versions` is by-design deny-all, leave it |

**Auto-injected in deployed Edge Functions** (never set manually): `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_DB_URL`. Supabase reserves the `SUPABASE_` prefix and filters it from `.env`.

**Must be set manually on prod** before first function deploy: `STIR_JWT_SECRET` (= prod project's `jwt_secret`); `GEMINI_API_KEY` (paid-tier).

**Never push to prod:** docs-only or iOS-only commits. Only schema + function changes trigger lockstep.

---

## Voice validation plan

The Gemini Live spike has two halves. The April 2026 full spike ran the **expensive half** (UX validation) and produced `FINDINGS.md` outside this repo. The **cheap half** (API drift check) still runs at step 6 start.

### Cheap half — pre-step-6, ~1 hour, terminal only

Confirm nothing has drifted between April 2026 spike findings and the API surface on step-6 day:

1. `curl POST .../v1alpha/authTokens` — confirm 200 + `token` field.
2. Open WS to `wss://...BidiGenerateContent`, token via `Authorization: Token <value>`. Confirm setup-complete arrives.
3. Send PCM16 test audio frame via `realtimeInput.audio`. Confirm no protocol error.
4. Verify `usageMetadata` audio metering still 25 tok/sec both directions.
5. Verify pricing on https://ai.google.dev/gemini-api/docs/pricing matches CLAUDE.md.
6. Re-test mint with API-key auth from the actual Edge Function environment (April spike got `400 INVALID_ARGUMENT` against raw REST).
7. If drift found, update `Specs/Stir-Full-Spec.md` §12 + this file before writing Cook Mode code.

### Expensive half — in-app validation gate, start of step 6

Before step 6 moves from "wire audio pipeline" to "productionize UX", all must measure within spec:

1. **TTFA on Wi-Fi — split gate** on `cook_turn_resolved.result_type` (ADR 0012): TTFA(`normal`) p95 < **500 ms** AND TTFA(`tool_call`) p95 < **1500 ms** across 20 turns. Anchor: last pre-audio `inputTranscription` → first `modelTurn.parts[].inlineData` chunk. Provisional thresholds — revisit after 2 weeks of beta if either at ≥80% of gate.
2. **Preamble-present rate at MINIMAL ≥ 70%** across 50 tool-call invocations. If lower, disable model preambles entirely; rely on client-side clip alone.
3. **Client-side filler fires within 150ms of `toolCall` frame arrival** and masks the 2s round-trip cleanly in 95%+ of substitutions.
4. **Refresh-bounded growth holds.** 30-turn scripted device session: `refreshSession()` fires at turns 10/20/30 (`live_session_refresh_complete`). Per-turn prompt tokens grow linearly within each window (~6-7k fresh → ~13-15k at turn 10) and RESET to baseline immediately after each refresh. If tokens keep growing past turn 10 without a refresh event, trigger is broken. If refreshes fire but tokens don't drop to baseline, recap path or setupComplete handshake is misbehaving.
5. **Session refresh is silent.** Mic mute window ≤ 5s. User speech during refresh is dropped until mic forwarding restarts.

If 1 or 4 fail materially, stop and escalate — architectural problems, not tuning. 2/3/5 are tunable.

## Build order

1. Supabase project + migrations + `/v1/session/bootstrap` + `/v1/config/bootstrap`.
2. Core Data + CloudKit container + HouseholdProfile + onboarding. No AI yet.
3. Scan + Solve with `gemini-3-flash-preview`. Aha-moment slice. **Spec §13 IP-based rate limiting lands here, not earlier.**
4. Saved meals + tap-based Cook Mode. Full Free-tier product.
5. RevenueCat + paywall + entitlements (annual trial primary CTA).
6. Cook Mode voice (Premium+). **Cheap-half drift check first**, then in-app validation gate, before any UX polish.
7. Imports, widgets, shortcuts, leftovers.
8. Telemetry dashboards, ops console, Sentry.
9. Beta.

Each step ends in something demoable. Don't interleave.

**Risk:** steps 1–5 build toward Premium-tier economics that assume voice works. If step-6 validation uncovers a fundamental Gemini Live problem, Free tier is unaffected but Premium's core promise needs rework.

---

## Deferred work

Tracked tech debt + triggered refactors live in `docs/deferred-work.md`. Read that file before assuming nothing is owed.

Active categories:

- **Pre-launch chrome polish** — Cook Mode top-bar mockup divergence, Tonight `Other options` placeholder, Settings dead-code (TrialReminderScheduler).
- **v1.1 / pre-public-launch backend** — retention crons, in-app CCPA deletion flow, Sentry tag deprecation rotation.
- **Step 9 / ops hardening** — TanStack Query for ops SPA, ops SPA test harness, per-admin rate limit, HTTPErrorHandler refactor, SQL session_id rewrite, runaway_session detector, canned_fallback schema registry, APNs test mock, source-IP HMAC, voice-path mock transport.
- **Triggered-by-next-touch** — RealtimeSession 3-part split (LOC trigger tripped at 3622), CookModeViewModel telemetry extraction (>1915 LOC), VoiceSessionDriver delegate collapse, VoiceSessionState path split, Clock injection.
- **Build/CI hygiene** — exhaustive-switch precommit check, post-commit build verification, pre-push xcodebuild + deno test hook, CFBundleShortVersionString MARKETING_VERSION drift.
- **Hard-pinned earlier deferrals** — IP rate limiting (step 3), Gemini Live API drift re-check (step 6 cheap-half), Mint endpoint auth re-test (step 6), CloudKit identity verification (step 6+), ActivityKit Live Activity (step 7).
- **Test-correctness debt** — voice_turn_usage_test ENT-VOICE-01→VOICE-SESSION-01 migration, pre-mint exact-boundary, is_refresh=false direct pin, suspected flakes retained for re-recurrence.
- **Documentation drift** — PostHogClient $ai_trace doc-comment, Spec §6 sync gap (METHOD-NOT-ALLOWED-01), error envelope drift protection.

---

## Working-with-Daniel rules

- Daniel is ex-MindFriend (747-file Swift codebase shipped in 30 days). Assume expert familiarity with iOS, Swift Concurrency, Core Data, CloudKit, Supabase, AI infra.
- **Default to comprehensive.** Build the full thing — error handling, edge cases, typed Swift models, production-minded from step 1. Don't ask "MVP or comprehensive?" unless he says "quick", "prototype", "sketch", or equivalent.
- **Log assumptions inline.** `// Assuming X because Y. Flag if wrong.` — not in a summary at the end.
- **Root-cause before patching.** When a fix isn't improving the diagnosis, stop and reframe from first principles. Don't iterate politely into a dead end.
- **Audit prior artifacts with the same rigor as new work.** If past-Claude got something wrong in the spec or generated code, say so directly. Prior outputs aren't ground truth.
- **Challenge bad calls.** One direct sentence beats three diplomatic paragraphs.
- **Don't silently drop features.** If a planned feature turns out infeasible mid-build, stop and tell Daniel. Never make compilation pass by dropping scope.
- Tables for comparisons, diagrams for systems, prose only when it earns its place.

---

## What NOT to reopen

Settled. Don't re-argue unless Daniel explicitly asks.

- Single AI vendor (Google only; no OpenAI/Anthropic fallback).
- Supabase backend (not Cloudflare Workers, not Firebase, not custom Node).
- Core Data + CloudKit (not SwiftData).
- iOS 17 minimum (not 15, not 16, not 18).
- Voice = Premium+ (not free with quota, not lifetime free sessions).
- Annual trial is the primary paywall CTA (not monthly).
- `thinkingLevel: minimal` for voice (escalate to LOW only if eval fails).
- RevenueCat (not pure StoreKit 2).
- No mandatory login (not Sign in with Apple required).
- English / US-only launch (no i18n in v1).
- No desktop/web companion app.
- Zod for Edge Function request-body validation (not Valibot).
- `usage_counters.cap_count` snapshot-at-creation, not refresh-on-tier-change.
- `app_users.status` and `entitlement_snapshots.billing_state` as native Postgres ENUMs with partial indexes.

If Daniel asks "should we switch to X?", engage. If you're independently considering a switch, surface the question first.

## What NOT to do by default

Specific wrong paths that look right until they bite.

- Don't put any provider API key in the iOS bundle. Under any framing.
- Don't add cached-input pricing math to Gemini Live cost estimates. Not supported.
- Don't write user content to Supabase Postgres. CloudKit-only.
- Don't use `response.create` or OpenAI-Realtime patterns in Gemini Live code — Gemini auto-continues after function responses.
- Don't send in-session text via `BidiGenerateContentClientContent` on 3.1 Flash Live. Use `realtimeInput.text`.
- Don't send function responses via `clientContent`. Use `BidiGenerateContentToolResponse` carrying matching `functionResponse.id`.
- Don't assume Gemini Live's `Authorization` uses `Bearer`. It's `Token`.
- Don't reference `gpt-realtime`, `GPT-5.4`, or OpenAI outside `docs/decisions/` as rejected-alternative context.
- Don't use `@FetchRequest` in new code — doesn't play well with `@Observable`. Repository + observed view model.
- Don't hardcode entitlement checks against tier strings in views. Always go through `EntitlementService`.
- Don't derive `voice_enabled` on iOS. Server-computed.
- Don't use object-keyed `quotas` in API responses. Always an array.
- Don't add new telemetry event names **or new property values on existing events** without updating spec §15 and this file. A new `result=busy` on `voice_affordance_tapped` is a wire-contract change.
- Don't invent new error codes. Use the matrix. New codes require updating both this file and spec §6.
- Don't return 4xx/5xx with empty body or string-only error.
- Don't skip the hard-rule validator on substitution output. Not optional.
- Don't use UIKit unless wrapping `AVCaptureVideoPreviewLayer` via `UIViewRepresentable`. SwiftUI-first.
- Don't add a second LLM provider as "insurance." Single-vendor is settled; revisit only if Gemini downtime exceeds 2x SLA for a quarter.
- Don't use aggregate assertions (COUNT, SUM without WHERE) in integration tests.
- Don't use `beforeEach` TRUNCATE or transaction-rollback wrappers in tests.
- Don't assert HTTP 403 in RLS isolation tests. Assert empty result sets (`length === 0`).
- Don't hard-delete `app_users` rows. Mark `status = 'merged'` or `'banned'`.
- Don't refresh `usage_counters.cap_count` on tier upgrade. Snapshot-at-creation is the rule.
- **Don't use Morph for semantic-tracked files.** `CLAUDE.md`, `Specs/*.md`, `docs/decisions/*.md` (ADRs), and `docs/decisions/TEMPLATE.md` are edited via native `Edit`/`Write` only — exact-string matching, verifiable per call. Morph has silently dropped subsections + introduced extra-asterisk drift on these files. Other code files (Backend/Stir source) continue to use Morph per the global tooling rule.

---

## When in doubt

1. Check the spec (`Specs/Stir-Full-Spec.md`).
2. Check the Cook Mode research doc for anything voice-related.
3. If the spec and this file disagree, the spec wins. Tell Daniel about the discrepancy so one gets updated.
4. If something is genuinely ambiguous, surface the decision rather than picking silently.
5. If you're about to write code that violates a north-star constraint, stop. They aren't negotiable.
