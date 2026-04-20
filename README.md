# Stir

### AI-Powered Weeknight Dinner Copilot with Hands-Free Cook Mode

![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange?logo=swift&logoColor=white)
![iOS 17+](https://img.shields.io/badge/iOS-17+-blue?logo=apple&logoColor=white)
![Gemini](https://img.shields.io/badge/Gemini-3%20Flash%20%2B%20Live-4285F4?logo=google&logoColor=white)
![Supabase](https://img.shields.io/badge/Supabase-Backend-3FCF8E?logo=supabase&logoColor=white)
![CloudKit](https://img.shields.io/badge/CloudKit-User%20Content-white?logo=icloud&logoColor=black)
![RevenueCat](https://img.shields.io/badge/RevenueCat-StoreKit%202-ff5a5f)
![Core Data](https://img.shields.io/badge/Core%20Data-Local%20First-purple?logo=apple&logoColor=white)
![CoreML](https://img.shields.io/badge/Vision-On--Device%20OCR-purple?logo=apple&logoColor=white)

**Stir** turns a quick kitchen scan into dinner. Point the camera at a fridge, pantry, or counter; Stir parses ingredients with a multimodal vision model, surfaces three ranked dinners that respect household dietary rules, and guides the cook through the recipe with auto-scheduling timers, live substitutions, and — on Premium — a hands-free voice assistant streaming over Gemini Live. The voice stack avoids the usual "dead air during tool calls" failure mode with a dual pre-recorded filler + prompted preamble pattern, runs at ~$0.09 per voice Cook Session after aggressive context pruning, and falls back to a local STT→text→TTS path if the Live API is unavailable — all while keeping every provider API key server-side behind ephemeral session tokens.

Stir is built solo, iOS-only, on a deliberately narrow stack (SwiftUI + Core Data + CloudKit for user content, Supabase Postgres + Deno Edge Functions for operations, Google Gemini as the single AI vendor).

---

## Table of Contents

- [Motivation](#motivation)
- [AI Systems](#ai-systems)
- [Product Design Foundations](#product-design-foundations)
- [Safety & Correctness](#safety--correctness)
- [Architecture](#architecture)
- [Technical Highlights](#technical-highlights)
- [Tech Stack](#tech-stack)
- [Project Scale](#project-scale)
- [Development](#development)
- [Roadmap](#roadmap)

---

## Motivation

Weeknight dinner is a decision-and-execution problem, not a recipe-discovery problem. The home cook already has ingredients; what they lack is a plan and the mental energy to assemble one. Recipe sites optimize for browsing, not for answering "what can I actually make right now, given what's in my fridge and the twenty minutes I have?"

Stir treats that exact moment — tired, hands full, decision fatigue high — as the product. Scan → three viable dinners → cook with guidance, all in under three minutes from app open. The novelty isn't another AI chatbot; it's collapsing the food-planning loop from 15 minutes of scrolling down to a single decision, with the mid-cook failure modes (out of an ingredient, broken equipment, dietary constraint) handled in the flow rather than kicking the user back to the browser.

The technical thesis: modern multimodal LLMs are finally good enough to parse a messy kitchen photo into structured ingredients, and realtime voice APIs are finally fast enough to answer "how much butter?" at kitchen-range latency. The engineering work is connecting those capabilities to a product that respects the constraints of the environment — wet hands, dim lighting, dietary restrictions that cannot be wrong — and doing so at unit economics that survive Free tier usage without blowing up on voice.

---

## AI Systems

### Gemini Live Cook Mode (Voice)

Hands-free voice assistance during cooking, streaming over a direct iOS↔Gemini WebSocket with server-minted ephemeral auth tokens. Premium+ entitlement only.

- **Model:** `gemini-3.1-flash-live-preview` at `thinkingLevel: minimal` — optimized for lowest time-to-first-audio (250–500ms production TTFA)
- **Transport:** WebSocket via native `URLSessionWebSocketTask` — no third-party SDK, no WebRTC dependency. PCM16 at 16kHz in, base64-encoded streamed audio out via `AVAudioEngine`
- **Turn detection:** Semantic VAD (primary) with server VAD fallback via `voice_turn_detection_mode` feature flag — semantic VAD avoids misfiring on ambient kitchen noise (sizzle, running water, exhaust fan)
- **Ephemeral tokens:** Every Cook Session mints a fresh single-use token via `POST /v1alpha/authTokens` from the Supabase Edge Function. The main `GEMINI_API_KEY` never leaves server-side; the iOS client never sees a long-lived provider credential
- **Session refresh:** Silent handoff every ~10 minutes or ~15 turns — new token minted, new WebSocket opened, old closed after first response lands. Protects against the 30-minute hard session limit and keeps per-turn context bounded

### Aggressive Context Pruning (the defining cost-control lever)

Gemini Live **does not support prompt caching**. Every turn re-bills accumulated context at full audio-input rate (25 tokens/second), so long sessions would linearly inflate cost per turn.

The mitigation is explicit: after every step advance, the client emits `session.update` events that truncate audio items older than the last 3 turns. This caps steady-state per-turn input context at ~950 audio tokens regardless of session length, making a 15-turn Cook Session cost ~$0.09 in steady state. Combined with a hard `max_output_tokens: 150` baked into the ephemeral token's `generation_config`, voice cost is predictable and bounded.

```
Per turn (post-prune steady state):
  New user audio input      125 tokens × $3/1M   = $0.000375
  Carried context (3 turns) 825 tokens × $3/1M   = $0.002475
  System prompt (text)      1000 tokens × $0.75/1M = $0.000750
  AUDIO-mode overhead       ~200 tokens × $3/1M   = $0.000600
  Assistant audio output    150 tokens × $12/1M   = $0.001800
                                                   ≈ $0.006 per turn
```

Token counts are continuously verified via the `usageMetadata` frames the server emits with every response; a `voice_session_token_snapshot` telemetry event fires every 5 turns, and an alert fires if per-session p95 token count exceeds 50K (the signal that pruning has regressed).

### Tool Call Preambles + Client-Side Pre-Recorded Filler

Mid-session substitutions ("I'm out of butter") trigger a function call that round-trips through Supabase to Gemini 3 Flash for the actual reasoning (~2s p95). Without mitigation, that round-trip is dead air — the user asks, hears silence, then eventually gets the answer.

The mitigation is dual:

1. **Prompted preamble**: system prompt instructs the model to speak a short neutral filler ("Let me check", "One moment") *before* emitting the function call. Preamble-present rate is continuously monitored; if it drops below 90% in production, a kill switch disables model preambles and the client-side clip below becomes the sole dead-air cover
2. **Client-side pre-recorded clip**: iOS plays one of three pre-recorded filler audio clips within 150ms of a `toolCall` frame arriving, independent of any model-emitted preamble. This deterministically covers the backend round-trip in 95%+ of substitution invocations

The belt-and-suspenders approach trades a small amount of occasional overlap (user hears a half-second of the pre-recorded clip, then the model's own filler, then the substantive answer) for a zero-dead-air guarantee. Testing validated this is preferable to gambling on model spontaneity at `thinkingLevel: minimal`.

### Multimodal Pantry Scan

Single-shot kitchen photo → structured ingredient list with per-item confidence.

- **Model:** `gemini-3-flash-preview` for vision + structured JSON output
- **On-device prep:** Vision framework for OCR (recipe imports) and barcode detection (pantry staples). Image compression at JPEG q=0.85 / max 1600px long edge → 200–400KB base64 payloads
- **Confidence-band UI:** Each parsed ingredient shows up as a chip styled by confidence band (confirmed / needs review / likely staple / low confidence). Users fix obvious misses in one tap before the dinner solve runs
- **Magic-byte verification:** Base64 images posted to the backend get a magic-byte sniff + claimed/actual MIME cross-check — closes a narrow OCR-based prompt-injection channel where a client could send SVG/PDF bytes with `image/png` mime claim

### Dinner Solve with Progressive Streaming

The "aha moment" — three ranked dinners streamed card-by-card over ~2 seconds.

- **Model:** `gemini-3-flash-preview`
- **Output shape:** Three options with title, total time, "why it fits" rationale, missing-item count, fit label (fastest / least waste / best fit)
- **Streaming UX:** Server-Sent Events emit one dish at a time with 150ms spacing, so the client fills card-by-card rather than showing a single 2-second spinner
- **Hard-rule pre-filter:** Household's dietary rules (allergies, vegan/vegetarian, equipment blocklist) enforced *outside* the model. Any violation in the model's output triggers a retry with an amplified prompt; second violation collapses to a safety card
- **Per-slot retry bounded at 1:** Worst case is 1 initial + 3 per-slot retries = 4 Gemini calls per solve. All token counts aggregate into a single `ai_request_log` row for cost attribution

### Substitution Engine with Hard-Rule Validator

Mid-cook "I'm out of X" handled with the same deterministic safety net whether triggered from the tap UI or via a voice function call.

- **Model:** `gemini-3-flash-preview` (text) — never the voice model, which only routes requests
- **Hard-rule validator:** Keyword-based allergen + dietary + equipment scan on every model response. If the suggestion contains peanuts for a peanut-allergic household, the server returns a canned safety card (no accept button) regardless of what the model claimed
- **False-positive aware:** Plain substring matches falsely flag compound plant names (eggplant, butternut, buckwheat). Safety-critical allergens use substring; coarse diets use word-boundary matching
- **Idempotency scoping:** Cache keyed on `(canonical_user_key, sub_event_id)` — a leaked `sub_event_id` cannot be replayed by another user. Enforced at schema level via composite primary key

### Recipe Import with Untrusted-Content Treatment

Share-sheet URLs, screenshots, and pasted text normalized into structured recipes.

- **Model:** `gemini-3.1-flash-lite-preview` — the cheap lane, sufficient for normalization tasks
- **Untrusted-by-default:** Imported recipes are treated as potentially adversarial content. Instructions never execute as model instructions. Prompt template wraps imported text in `<<<USER_DATA_START>>>`/`<<<USER_DATA_END>>>` markers with side-channel guidance that the model must not follow instructions inside markers
- **Failure mode:** Parse failure lands in an edit screen, never directly in Cook Mode. Users can correct OCR errors before the recipe reaches the solve pipeline

---

## Product Design Foundations

Stir's design system optimizes for one job: a tired home cook, in a kitchen with wet hands and dim lighting, getting dinner decided in 2 minutes and guided for 30. Five principles, prioritized when they conflict:

| Principle | Application |
|---|---|
| **Legibility under distraction** | Dynamic Type through XXXL never crops the primary CTA; tap targets ≥44pt; WCAG 2.2 AA contrast on every token pair; Cook Mode step text is the one place body goes to `body.lg` 17pt |
| **One decision per screen** | Dinner Options asks "which one?" only — no upsell inline, no portion tweaks, no nested settings. Secondary actions go in overflow |
| **Confident but not slick** | No glassy gradients, no parallax hero shots of truffle shavings. Warm off-white paper palette, ember accent, New York Semibold for display type. The feeling is a trusted sous-chef, not a Michelin Instagram reel |
| **AI is infrastructure, not spectacle** | No sparkle emojis, no "✨ AI-powered" badges, no confetti on scan parse. When the model does something well, the *result* is what's celebrated, not the process |
| **Accessibility is a first-class constraint** | VoiceOver, Dynamic Type, Reduce Motion, color-independent semantics designed in from step 1. Not a polish pass |

**Forbidden moves:**
- No photo-heavy recipe cards (recipes are structured data, photos are nice-to-have)
- No chrome-heavy tab bars with 5 destinations (v1 is three: Tonight, Saved, Settings)
- No modal stack deeper than 2
- No animations longer than 300ms
- No emoji in product copy (one-off exception: 1★–5★ feedback ratings)

Design tokens live in `Stir/DesignSystem/Tokens/` (Colors, Typography, Spacing, Radius, Icons) — every view references tokens, zero raw hex codes or magic point sizes. The canonical mockup set lives in `stir-app-design/project/DesignMockups/` with an `EXTRACTED_TOKENS.md` audit trail mapping each mockup CSS variable to its SwiftUI token.

---

## Safety & Correctness

### Deterministic Hard-Rule Validator

Every substitution output — whether from the tap-triggered Substitution Sheet or from a voice-session function call — passes through the same deterministic keyword-based validator before reaching the user. The validator runs outside the model and cannot be prompted away.

- **Allergens** (substring match, deliberately false-positive-tolerant for safety): peanut, tree nuts, shellfish, dairy, gluten grains (wheat/barley/rye), soy, sesame, egg
- **Diets** (word-boundary match, false-positive-avoidant): vegetarian, vegan, pescatarian, gluten-free. The gluten-free list carries only the actual gluten grains plus soy sauce and seitan — never generic "flour" or "noodle" (which would false-positive on buckwheat flour, rice noodles, almond flour)
- **Equipment implications** (keyword-based): sous vide, pressure cooker, stand mixer flagged so recipes don't silently require equipment the household doesn't have
- **Failure path:** Validator rejection triggers a retry with an amplified prompt carrying a PII-free violation summary (`allergens=peanut; diets=gluten-free`); second failure returns a canned safety card with no Accept button

### Prompt Injection Defense

- **Imported recipes always untrusted**: instructions in recipe text never execute as LLM instructions. Renderer wraps flagged fields in `<<<USER_DATA_START>>>`/`<<<USER_DATA_END>>>` markers and injects system-prompt guidance to ignore instructions inside markers
- **Delimiter scrubbing**: user content has injection markers stripped before template interpolation
- **Hard-rule validator as primary output defense**: even if prompt-level defenses fail, the deterministic keyword scan catches allergen-bearing outputs

### Server-Side Credential Isolation

- **Zero provider API keys in the iOS bundle** — not Gemini, not RevenueCat's secret, not PostHog's personal API token, nothing. Only public keys (RevenueCat public SDK key, PostHog public project key, Sentry public DSN) ship in `Config.xcconfig`, which is gitignored
- **Ephemeral session tokens only**: Gemini Live sessions authenticate with server-minted single-use tokens (`uses: 1`, `expire_time: ~35 min`, `new_session_expire_time: ~60s`) rather than long-lived provider credentials. The main `GEMINI_API_KEY` lives exclusively in Supabase Edge Function secrets
- **JWT HS256 sessions** between iOS and Supabase, rotated every 24h, with typed `AuthReason` (missing / expired / malformed / signature_invalid / user_stale) for differentiated client handling

### Row Level Security Everywhere

All operational Postgres tables enforce user-level isolation at the database level, keyed on `canonical_user_key` via `auth.jwt() ->> 'canonical_user_key'`:

- `usage_counters`, `entitlement_snapshots`, `ai_request_log`, `device_installations` — SELECT-only for authenticated role, writes via service role
- `app_users`, `feature_flags`, `prompt_versions`, `processed_webhook_events`, `webhook_log` — RLS enabled with no authenticated-role policies (default-deny)
- All SECURITY DEFINER RPCs pin `search_path = public, pg_temp` and `REVOKE EXECUTE FROM PUBLIC` / `GRANT TO service_role` only — closes a CVE-class gap where authenticated JWT holders could invoke RPCs via PostgREST `/rpc` and bypass RLS

### Idempotency Scoping

AI response cache keyed on `(canonical_user_key, request_id)` — a leaked `client_request_id` / `sub_event_id` / `solve_request_id` in telemetry or screenshots cannot be replayed by another user. Composite primary key enforced at schema level; every read/write helper takes user key as a required parameter.

### Rate Limiting

- **Sliding-window rate limiter** in Postgres with `pg_advisory_xact_lock` serialization. Policies hardcoded (session-bootstrap 20/hr/IP, dinner-solve 30/day/IP, substitution 50/day/IP)
- **X-Forwarded-For posture**: private-IP skip in the production rate limiter handles Supabase's local Kong gateway without needing a test-env flag; rightmost XFF entry trusted (not leftmost, which is client-controlled)

### Webhook Verification

- **RevenueCat webhook:** constant-time shared-secret comparison of a 32+ character token (per ADR 0003), 10-minute freshness window on `event_timestamp_ms`, 64 KiB body size cap, `processed_webhook_events` PK-dedupe on `event.id` inside an atomic RPC transaction — replay attacks fail even if the secret leaks
- **Advisory-locked alias forward:** `pg_advisory_xact_lock(42, hashtext(install_key))` at the top of `stir_alias_forward` serializes concurrent bootstrap + webhook merge paths for the same user, closing a phantom double-merge race

### Single-Vendor Posture

Stir runs on **Google Gemini only** — no cross-vendor LLM fallback. Rationale: Gemini's paid SLA is 99.9% (~8.7 hours/year expected downtime); the operational tax of maintaining a second vendor (dual keys, dual rate limits, dual legal disclosures, dual eval runs, dual Edge Function branches) exceeds the insurance value at v1 scale. If the Gemini Live API is unavailable specifically, Cook Mode voice silently falls back to a local `Speech` framework STT → `gemini-3-flash-preview` text → `AVSpeechSynthesizer` TTS path with an `AI-VOICE-01` banner. If all of Gemini is down, saved meals + cached plans + local timers + manual substitution remain functional.

---

## Architecture

```
                    ┌──────────────────────────────────────┐
                    │         iOS Client (SwiftUI)          │
                    │                                       │
                    │  9 Feature Modules                     │
                    │  14 Core Data Entities (CloudKit)      │
                    │  Vision (OCR, Barcode, Pantry Scan)    │
                    │  AVAudioEngine (Live PCM16 streaming)  │
                    │  UserNotifications (Cook timers)       │
                    │  @Observable + @MainActor services     │
                    │  RevenueCat SDK (StoreKit 2 underneath)│
                    └────────┬───────────────────┬─────────┘
                             │                   │
                   HTTPS / WSS           WSS direct (voice only)
                             │                   │
        ┌────────────────────▼───┐     ┌────────▼────────────────┐
        │   Supabase Platform     │     │   Gemini Live API        │
        │                          │     │                          │
        │  Auth (JWT HS256, 24h)   │     │  gemini-3.1-flash-live-  │
        │  PostgreSQL + RLS        │     │    preview @ MINIMAL     │
        │  37 migrations, 14 tables│     │  Ephemeral auth tokens   │
        │  8 Edge Functions (Deno) │     │  PCM16 bidirectional     │
        │  pgmq + pg_cron          │     └──────────────────────────┘
        │  Idempotency caches      │
        └────────┬─────────────────┘
                 │
        ┌────────▼─────────────────────────┐
        │      External Services             │
        │                                    │
        │  Gemini 3 Flash (scan/solve/sub)   │
        │  Gemini 3.1 Flash-Lite (normalize) │
        │  RevenueCat (entitlements + webhook)│
        │  APNs (push via ES256 JWT)          │
        │  PostHog (product analytics)        │
        │  Sentry (error tracking)            │
        │  CloudKit (user content sync)       │
        └────────────────────────────────────┘
```

### Hybrid Data Ownership

**CloudKit private database (user content, source of truth):**
`HouseholdProfile`, `DietaryRule`, `KitchenEquipment`, `PantryItem`, `MealSolveRequest`, `SuggestedDish`, `RecipePlan`, `RecipeIngredient`, `Step`, `RecipeImport`, `CookingSession`, `VoiceTurn`, `CookTimer`, `SubstitutionEvent`, `OutcomeFeedback`, `GroceryList`, `GroceryItem`, `MediaAsset`.

Data lives local-first in Core Data via `NSPersistentCloudKitContainer`, synced to the user's CloudKit private database. The backend never becomes authoritative for pantry, recipes, or sessions — user content is never mirrored to Postgres.

**Supabase Postgres (operational only):**
`app_users`, `device_installations`, `entitlement_snapshots`, `usage_counters`, `ai_request_log`, `prompt_versions`, `feature_flags`, `processed_webhook_events`, `webhook_log`, `ai_response_cache`, `ops_flagged_outputs`, `audit_log`, `notification_jobs`, `rate_limit_buckets`.

Operational metadata — quotas, entitlements, AI cost attribution, webhook audit, kill-switch feature flags — keyed on `canonical_user_key` with RLS on every row. User content is never here.

### Canonical User Key

```
canonical_user_key = "ck:<userRecordName>"           // if CloudKit account available
                   | "install:<keychainInstallId>"   // fallback (no iCloud)
```

RevenueCat `appUserID` uses the same canonical key. When an `install:`-keyed user later gains CloudKit availability, the app **alias-forwards** in a single Postgres transaction: SUM usage counters (no clamping — prevents quota-reset abuse via sign-out/sign-in), CK-wins for entitlement snapshots (RevenueCat webhook is ck-keyed), UPDATE `ai_request_log` / `device_installations` install→ck, mark install row `status = 'merged'` with a `merged_into` pointer (never hard-delete — audit trail). RevenueCat re-alias runs *after* the DB commits, never inside, so an external SDK call can't roll back identity state.

### SwiftUI + @Observable Architecture

MVVM with per-feature `@Observable` view models hosted on `@MainActor`-isolated services. Root coordinator owns long-lived services (`EntitlementService`, `RevenueCatService`, `SupabaseSessionClient`, `IdentityService`) and injects them via `@Environment` — no global singletons, every service is protocol-conformed for test substitution. Zero `useEffect`-style reactive drift: state is derived in the view body, event handlers run in `Button` / `Task` closures, and mount-only setup uses a named `useMountEffect` wrapper so intent is explicit.

Cook Mode's realtime voice pipeline uses Swift `actor` isolation for the Gemini Live WebSocket service, with structured concurrency (`Task` trees, `@MainActor` hop on the UI boundary, `AsyncThrowingStream` for token-by-token audio delivery) throughout.

### Deploy Lockstep

Per `CLAUDE.md`'s binding rule: every migration + Edge Function change lands on prod `ktqajarcomzplnpbczfo` in the same session as local. Verified via `supabase link` → `supabase db push` → `supabase functions deploy` followed by `supabase inspect db` advisor checks. Docs-only and iOS-only commits don't trigger the rule.

---

## Technical Highlights

- **Server-minted ephemeral Gemini Live tokens** — main provider key stays in Supabase Edge Function secrets; client never sees a long-lived credential. `uses: 1`, 60s open window, 35min hard deadline
- **Aggressive context pruning via `session.update`** — caps per-turn input audio at ~950 tokens regardless of session length; the dominant cost lever given that Gemini Live does not support prompt caching
- **Dual preamble pattern** — prompted model filler + client-side pre-recorded clip covers the ~2s function-call round-trip deterministically in 95%+ of substitutions
- **Constant-time RevenueCat webhook verification** with 10-min freshness window, atomic dedup RPC, 64 KiB body cap
- **Core Data + NSPersistentCloudKitContainer** for local-first user content with field-aware CloudKit conflict resolution — additive merges on feedback histories, last-write-wins on scalars
- **JWT HS256 session auth** with typed `AuthReason` enum (missing / expired / malformed / signature_invalid / user_stale) driving differentiated client retry severity and Sentry capture
- **Deterministic hard-rule validator** running outside the model on every substitution — allergen, dietary, equipment keyword scan with false-positive-aware compound-plant exclusions
- **Composite-key idempotency cache** scoped to `(canonical_user_key, request_id)` prevents cross-user replay of leaked request IDs
- **`pg_advisory_xact_lock` on alias-forward** serializes concurrent bootstrap + SUBSCRIBER_ALIAS webhook merge for the same user, closing phantom double-merge race
- **`search_path`-pinned SECURITY DEFINER RPCs** with REVOKE FROM PUBLIC + GRANT service_role — closes the PostgREST `/rpc` RLS-bypass vector
- **XcodeGen-driven project file** — `project.yml` is the source of truth; `Stir.xcodeproj` regenerated deterministically, eliminating merge conflicts on the project file
- **RevenueCat over StoreKit 2** for entitlement reconciliation with webhook-driven `billing_state` updates (`none|active|trial|grace|cancelled_active|expired` as a Postgres ENUM)
- **Atomic quota check** via single UPDATE … WHERE used_count < cap_count RETURNING — one round-trip, no TOCTOU window, cap snapshot-at-creation (not refresh-on-upgrade) to block sign-out-to-reset abuse
- **Single-vendor AI posture** (Gemini only) with `disable_cook_realtime` kill switch that falls Premium+ voice back to local Speech STT → Gemini 3 Flash text → AVSpeechSynthesizer TTS, `AI-VOICE-01` banner
- **Typed domain error matrix** (NET-01, AI-01..03, AI-VOICE-01, IMPORT-01, PERM-*, SYNC-01, RATE-01, BILL-01, PAY-01, ENT-VOICE-01, ENT-MULTI-IMAGE-01, VAL-01, AUTH-01) wired through server → network layer → ErrorPresenter → user-facing copy
- **Magic-byte image verification** on base64 uploads catches claimed-PNG-actual-SVG prompt-injection channel targeting the vision model

---

## Tech Stack

| Layer | Technology |
|---|---|
| **iOS Client** | SwiftUI, Swift 5.9+, iOS 17+, Xcode 26+ (iOS 26 SDK) |
| **Concurrency** | Swift Concurrency (async/await, actors, `@MainActor`), structured `Task` trees, `AsyncThrowingStream` |
| **State** | `@Observable` view models, `@Environment` DI, per-feature `NavigationStack` |
| **Persistence** | Core Data + `NSPersistentCloudKitContainer`, CloudKit private DB |
| **On-Device AI** | Vision framework (OCR, barcode), Speech framework + AVSpeechSynthesizer (voice fallback only) |
| **Audio** | AVAudioEngine (PCM16 16kHz capture + playback) |
| **Voice AI** | Google Gemini 3.1 Flash Live Preview at `thinkingLevel: minimal` via native `URLSessionWebSocketTask` |
| **Text / Multimodal AI** | Google Gemini 3 Flash (scan, solve, substitution, cook-turn fallback) |
| **Cheap AI lane** | Google Gemini 3.1 Flash-Lite (recipe normalize, grocery structuring) |
| **Payments** | RevenueCat over StoreKit 2, server-side webhook verification |
| **Backend** | Supabase (PostgreSQL, Deno Edge Functions, Auth, pgmq, pg_cron) |
| **Auth** | JWT HS256 (24h TTL), no mandatory login, CloudKit user record / install UUID as canonical key |
| **Push** | APNs direct (ES256 JWT) |
| **Analytics** | PostHog (events + feature flags + experiments, pseudonymous) |
| **Error Monitoring** | Sentry (iOS + Deno, PII redacted) |
| **Project Config** | XcodeGen (`project.yml` → `Stir.xcodeproj`), `.xcconfig` files, gitignored secrets template |
| **Architecture Decisions** | ADRs in `docs/decisions/` with typed status (Proposed / Accepted / Deferred / Superseded / Rejected) |

---

## Project Scale

| Metric | Count |
|---|---|
| Swift source files | 123 |
| Feature modules | 9 |
| Core Data entities | 14 |
| Supabase migrations | 37 |
| Edge Functions (Deno/TypeScript) | 8 |
| Backend test files | 19 |
| iOS unit test files | 25 |
| Architecture Decision Records | 7 |
| AI endpoints | 5 (`pantry-parse`, `dinner-solve`, `substitution`, `cook-turn`, `realtime-session`) |
| Distinct Gemini models in rotation | 3 (`gemini-3-flash-preview`, `gemini-3.1-flash-lite-preview`, `gemini-3.1-flash-live-preview`) |
| Entitlement tiers | 3 (Free, Premium $9.99/mo, Pro $14.99/mo) |
| Typed error codes | 14 |
| Design tokens (Colors / Typography / Spacing / Radius / Icons) | 5 token files |
| Canonical dietary rule types | 4 (allergy / diet / dislike / goal) |

---

## Development

### Prerequisites

| Tool | Minimum | Install |
|---|---|---|
| macOS | 14+ | — |
| Xcode | 26.4+ (iOS 26 SDK) | App Store |
| XcodeGen | 2.45+ | `brew install xcodegen` |
| Docker Desktop | running before `supabase start` | https://www.docker.com/products/docker-desktop |
| Supabase CLI | 2.0+ | `brew install supabase/tap/supabase` |
| Deno | 2.0+ | `brew install deno` |

### iOS setup

```bash
git clone https://github.com/scalinity/Stir.git && cd Stir
cp Config.xcconfig.example Config.xcconfig
# Edit Config.xcconfig with public keys (SUPABASE_URL, SUPABASE_ANON_KEY,
# REVENUECAT_PUBLIC_API_KEY, POSTHOG_PUBLIC_API_KEY, SENTRY_DSN_PUBLIC).
# See Prerequisites — these are public keys; Config.xcconfig itself is gitignored.

xcodegen generate
open Stir.xcodeproj
```

### Backend setup

```bash
cd Backend/supabase
supabase start              # Postgres + PostgREST + Edge Runtime (~30s first time)
supabase db reset           # applies all 37 migrations from empty
supabase functions serve --env-file .env
```

### Tests

```bash
# iOS (139 tests)
xcodebuild test -scheme Stir -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Backend (210 tests)
cd Backend/supabase && deno test --config=functions/deno.json --env-file=.env \
  --allow-env --allow-net --allow-read tests/
```

Gemini-touching integration tests are gated on `STIR_RUN_AI_INTEGRATION_TESTS=1` so CI doesn't burn the paid-tier budget.

See `CLAUDE.md` for the orientation pack — invariants, north-star constraints, and the binding deploy-lockstep rule. See `Specs/Stir-Full-Spec.md` for product truth, `Specs/Stir-Cook-Mode-Architecture.md` for voice architecture, `Specs/Design-System.md` for design tokens, and `Specs/Gemini-Live-Findings.md` for the API validation notes.

---

## Roadmap

| Direction | Description |
|---|---|
| **ActivityKit Live Activity** | Lock Screen + Dynamic Island countdowns for active Cook Mode timers, piggybacking on the Widget Extension target introduced in step 7 |
| **Home Screen + Lock Screen widgets** | "What can I cook tonight?" widget with pantry-aware dinner suggestions; Cook Mode resume widget for interrupted sessions |
| **Share Extension + App Intents** | Share-sheet recipe import from Safari / Reddit / screenshots; Shortcuts integration for "Scan my kitchen" and "Cook [saved meal]" |
| **Leftovers follow-up mode** | Next-day "use soon" suggestions driven by cooked-session ingredient deltas and staleness heuristics |
| **Multi-image pantry scan** | Pro-tier 3-photo pantry scan for deeper fridge/pantry coverage — `ENT-MULTI-IMAGE-01` entitlement already wired backend-side |
| **Ops admin console** | `/v1/ops/admin/*` endpoints for flagged-output review, prompt-version rollback, abuse investigation, webhook replay |
| **Beta + TestFlight** | Real privacy policy + ToS URLs, fastlane-driven TestFlight pipeline, GitHub Actions CI (lint + tests on PR, staging deploy on merge) |
| **Internationalization** | English-only at launch. Spanish + Portuguese-BR scoped as a post-launch track once core retention signals land |

---

## License

Proprietary. All rights reserved.

---

<p align="center">
  <em>Collapsing the weeknight dinner decision loop from 15 minutes to 2 — because the friction isn't lack of recipes, it's the gap between what's in your fridge and what you'll actually cook.</em>
</p>
