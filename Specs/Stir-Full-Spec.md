## 1. Product Vision

**Stir** is an iPhone app that turns a quick kitchen scan into a viable dinner, then stays with the user in live Cook Mode while they make it.

Stir is a weeknight decision-and-execution product, not a recipe database and not a pantry spreadsheet. The complete product surface in v1 is: camera scan of fridge/pantry/counter; fast ingredient confirmation; constraint entry; three ranked dinner options; dish preview; live Cook Mode with timers, step progression, and voice Q&A (Premium+ only); mid-cook substitutions; leftovers follow-up; recipe import from share sheet / URL / screenshot; Reminders write-back for grocery gaps; saved meals / favorites; Home Screen widget; Shortcuts launch path; subscription gating; analytics; and a thin backend for AI routing, quotas, entitlements, feature flags, and ops.

**Target user recap**
Primary user: weeknight home cook.
Buyer: same person.
Buying motion: self-serve.
Functional JTBD: when it is a tired weeknight and the user has ingredients at home but no plan, they want dinner decided and guided fast, so they can cook something good without scrolling recipe sites, wasting food, or defaulting to takeout.

**Non-goals**

* Grocery delivery checkout
* Smart-oven or thermometer integration
* Calorie/macronutrient tracking
* HealthKit nutrition logging
* Social feed or public community recipes
* Shared family pantry accounts
* Perfect perpetual inventory accounting
* Restaurant or takeout recommendation
* Desktop/web companion app
* Non-English launch

## 2. Core Workflow Narrative

### First session, minute by minute

**0:00–0:10 — Launch**
User opens Stir. A short welcome screen frames one job: *Cook what you already have.* Two paths are visible: **Try it now** and **See a sample**.

**0:10–0:35 — Lightweight household setup**
User selects:

* servings default
* hard dietary rules: allergies, vegetarian/vegan, etc.
* soft preferences: dislikes, goals like "high protein"
* available equipment: oven, air fryer, blender, etc.

No permission prompts yet.

**0:35–0:45 — Tonight Home**
User lands on the default tab with three actions:

* **Scan Kitchen**
* **Import Recipe**
* **Cook Saved**

A "why Stir works" strip shows: *Scan → pick a dinner → cook with voice*.

**0:45–1:05 — Camera capture**
User taps **Scan Kitchen**.
Stir shows a custom camera primer first, then requests camera permission. If denied, it offers a bundled sample kitchen photo so the user can still reach the aha moment.

**1:05–1:20 — Scan review**
The user sees recognized ingredients as chips with confidence states:

* confirmed
* needs review
* likely staple

They can fix obvious misses in one tap.

**1:20–1:35 — Constraints**
A bottom sheet asks for tonight's constraints:

* time
* cuisine leaning
* "use this first"
* avoid equipment
* goal like "high protein"

Defaults are prefilled from setup.

**1:35–2:05 — Dinner solve**
Stir returns exactly three options, each with:

* title
* total time
* why it fits
* missing-item count
* fit label: fastest / least waste / best fit

This is the aha moment.

**2:05–2:30 — Pick one and preview**
The user taps a dish card, sees a concise preview with ingredient list, missing items, and first three steps.

**2:30–3:00 — Enter Cook Mode (tap-based for Free; voice available on Premium+)**
Free users enter a tap-only Cook Mode with step cards, timers, and a text-based Substitution Sheet. Premium+ users see a microphone affordance; first voice tap requests microphone permission. If denied, voice falls back to tap. The user sees step 1, timer affordances, and a persistent "Ask while cooking" entry point.

### Steady-state usage cycle

Retention mode is weekly ongoing workflow, not daily habit theater. A healthy user opens Stir **2–5 times per week**, most often around the evening meal window.

Typical weekly cycle:

1. Open **Tonight**.
2. Scan current ingredients or replay a saved favorite.
3. Accept one of the three dinner options.
4. Cook with timers and, on Premium+, occasional voice turns.
5. Resolve one missing ingredient or timing adjustment without leaving the app.
6. Rate the meal and export missing items to Reminders.
7. See leftovers or "use soon" suggestions the next day.

### Multi-user handoff

None in v1. User, buyer, and approver are the same person. No family account, no shared pantry, no social graph.

### Failure-mode narrative

**AI uncertainty**
When Stir is not confident about a scan, it does not guess silently. It asks compact disambiguation questions: "cilantro or parsley?", "cooked rice?" It will not claim certainty on allergens, spoilage, or doneness.

**AI degradation / provider outage**
Stir runs on a single AI vendor (Google Gemini). If Gemini is fully unavailable, Stir shifts to saved-meal replay, cached plans, local timers, and the manual Substitution Sheet (which becomes inert — shows "AI unavailable, try again later"). No cross-vendor fallback is wired up in v1. Rationale: Gemini's paid SLA is 99.9%, giving ~8.7 hours/year expected downtime. The operational cost of maintaining a second vendor (keys, rate limits, legal disclosures, dual eval runs, dual Edge Function branches) outweighs the insurance value at v1 scale.

If only the Live API (voice) is unavailable, Cook Mode voice silently falls back to a text path: local Speech STT → Gemini 3 Flash text → AVSpeechSynthesizer. Banner `AI-VOICE-01` appears.

**Bad data**
Imported recipes that parse poorly land in an edit screen, never directly in Cook Mode. Scan errors are editable before any dinner solve.

**Permission denial**

* Camera denied → sample kitchen photo or manual import
* Microphone denied → tap-only Cook Mode (default Free experience anyway)
* Photos denied → paste URL or use share extension from Safari
* Reminders denied → keep grocery list in-app and copy/share it
* iCloud unavailable → local-only mode banner; product continues on-device

## 3. Architecture Decisions

### Resolved handoff gaps

* **[HANDOFF CONFLICT: auth strategy not specified while the handoff requires CloudKit-backed sync with no separate account requirement — proposing no mandatory sign-in, with CloudKit user record name as canonical user key when available and a keychain installation ID fallback when iCloud is unavailable.]**
* **[HANDOFF CONFLICT: `ios_capabilities` names Shortcuts while `v1_features` names Shortcuts/App Intents — proposing App Intents as the implementation substrate for Shortcuts, without treating it as an additional product-surface decision.]**
* **[HANDOFF CONFLICT: Pro tier includes "deeper household memory" but does not quantify a memory cap — proposing 1,000 remembered pantry items and 365-day preference memory for Pro to make entitlements enforceable.]**
* **[HANDOFF CONFLICT: async weekly suggestions are named in the handoff, but user content lives in CloudKit private storage the backend should not mirror — proposing on-device/local-notification generation for weekly suggestions, with backend async used only for explicit user-initiated imports and AI jobs.]**

### Stack selection

| Layer            | Choice                                                          | Why this is the right fit                                                                                                                    | Rejected alternative                                                                                                                                      |
| ---------------- | --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| UI               | **SwiftUI**                                                     | Fits iOS-only scope, fast iteration, widgets/live activities/share-extension consistency, modern navigation, `@Observable` integration       | UIKit-first adds too much view/controller ceremony                                                                                                        |
| UIKit usage      | **Only for camera preview wrapper if needed**                   | `AVCaptureVideoPreviewLayer` is still cleaner through `UIViewRepresentable`; everything else stays SwiftUI                                   | Full UIKit camera flow is unnecessary                                                                                                                     |
| Concurrency      | **Swift Concurrency**                                           | Native async/await, actors for stateful services, TaskGroups for media + network orchestration                                               | Combine-first architecture adds cognitive overhead                                                                                                        |
| View state       | **`@Observable` view models**                                   | Small, testable, and natural for SwiftUI 17+                                                                                                 | TCA is too heavy for this scope                                                                                                                           |
| Persistence      | **Core Data + NSPersistentCloudKitContainer**                   | Most predictable choice for sync, migrations, history tracking, and extension-safe persistence; matches a local-first app with iCloud sync   | SwiftData is attractive, but Core Data remains the safer production choice for CloudKit-heavy sync and migration stability on an iOS 17 deployment target |
| App sync         | **CloudKit private database via NSPersistentCloudKitContainer** | Keeps user content local-first, synced across the user's devices, with user isolation at the database boundary and a local replica on device | Supabase/Firebase as source-of-truth would duplicate the data plane and quietly turn the product into a web-backed app                                    |
| Backend          | **Supabase (Postgres + Edge Functions + Auth + pgmq/pg_cron)**  | Thin operational backend only: AI relay, quotas, prompt versions, feature flags, push jobs, entitlements, ops dashboard. RLS keyed on `canonical_user_key` on every ops table. Operational Postgres does **not** mirror user content — pantry/recipes/sessions stay in CloudKit as the source of truth. | Cloudflare Workers + D1 + KV + Queues is an equally valid thin-backend stack but adds tooling surface when Supabase Postgres + Edge Functions already cover the same needs. Pure Postgres-as-app-DB (with user content in Supabase) was also rejected — that would duplicate CloudKit and create two sources of truth. |
| Payments         | **RevenueCat over StoreKit 2**                                  | Faster entitlement reconciliation, clean webhooks, simpler restore/upgrade/grace handling, still native Apple billing underneath             | Pure StoreKit 2 is viable, but more server plumbing for a solo build                                                                                      |
| Auth             | **No mandatory login**                                          | Keeps first-session friction low and honors the handoff                                                                                      | Forced Sign in with Apple adds avoidable friction                                                                                                         |
| Analytics        | **PostHog**                                                     | Product analytics + feature flags + experiments in one place; send only pseudonymous events                                                  | Mixpanel would need a separate feature-flag tool                                                                                                          |
| Error monitoring | **Sentry**                                                      | Mature iOS + Supabase/Deno coverage, release health, stack traces                                                                            | Bugsnag is fine but no meaningful advantage here                                                                                                          |
| Push             | **APNs direct**                                                 | iOS-only app, no need for a third-party push layer                                                                                           | OneSignal is unnecessary extra surface                                                                                                                    |
| Primary AI (text/multimodal) | **Gemini 3 Flash**                                  | Best balance of multimodal quality, latency, and cost for scan/solve/substitution. Paid tier content is not used to improve Google's products. | OpenAI GPT-5.4 mini was evaluated as a cross-vendor fallback and rejected — operational tax (dual keys, dual eval runs, dual legal disclosures) exceeds the insurance value at v1 scale given Gemini's 99.9% SLA. |
| Cook Mode voice  | **Gemini 3.1 Flash Live Preview (`thinkingLevel: minimal`)**    | Native audio-to-audio via Live API, optimized for lowest time-to-first-token. Production deployments report 250–500ms TTFA. 131K context window. Native function calling with streaming. Supports session-level configuration of turn detection (server VAD or semantic VAD). Stir's voice-model job is narrow (conversational routing + tool calls) so MINIMAL reasoning is sufficient — substitution reasoning is delegated to Gemini 3 Flash + hard-rule validator. | OpenAI `gpt-realtime-mini` was the previous choice, rejected to consolidate on a single vendor. gpt-realtime-mini has stronger spontaneous tool-call preamble behavior, but preambles can be produced by Gemini Live via explicit system-prompt instruction. Gemini 3.1 Flash Live at thinkingLevel=HIGH is disqualified by latency (2.98s TTFA). |
| Cheap AI lane    | **Gemini 3.1 Flash-Lite**                                       | Best for recipe normalization and grocery structuring                                                                                        | GPT-5.4 nano is cheap, but Flash-Lite is a cleaner fit for an all-Google stack                                                                            |
| On-device AI     | **Vision OCR/barcode + Speech framework + AVSpeechSynthesizer** | Vision used for recipe OCR and barcode scanning. Speech framework + AVSpeechSynthesizer retained as the Cook Mode voice fallback path only (when Gemini Live is unavailable), not the primary Cook Mode voice stack. Avoids an iOS 18.2+ / Apple Intelligence device dependency. | Apple Foundation Models Framework would force an iOS 18.2+ and supported-device branch the handoff did not choose                                         |

CloudKit gives each app container one public database and a separate private database for each user; Apple also documents that `NSPersistentCloudKitContainer` maintains a local replica of the data. That matches Stir's hybrid, local-first posture almost exactly. ([Apple Developer][1])

Stir should still ship with a **minimum deployment target of iOS 17.0**, but by the current Apple submission rules, any App Store build shipped after April 28, 2026 must be built with Xcode 26+ using the iOS 26 SDK or later. That affects tooling, not the minimum OS target. ([Apple Developer][2])

### Identity model

**Canonical user key**

1. `ck:<userRecordName>` if CloudKit account is available
2. else `install:<keychainInstallationId>`

RevenueCat `appUserID` uses the same canonical key. If the user starts in local-only mode and later gains iCloud availability, the app aliases the installation key to the CloudKit key in RevenueCat and the backend.

### Sync strategy

**Pattern:** optimistic local writes + eventual CloudKit sync.

* Local Core Data store is the app's immediate source of truth.
* Every user action writes locally first.
* CloudKit mirrors user data in the background.
* Conflict resolution is field-aware and last-write-wins for simple timestamps; additive merges for feedback and session histories.
* Backend never becomes authoritative for pantry, recipes, or sessions.

### File / module organization

**Single Xcode project, feature-folder architecture, no TCA.**

```
Stir/
  App/
    StirApp.swift
    RootCoordinator.swift
  DesignSystem/
  Core/
    Models/
    Repositories/
    Services/
    Utilities/
  Features/
    Onboarding/
    Tonight/
    Scan/
    Solve/
    CookMode/
    Import/
    Saved/
    Settings/
    Billing/
  Integrations/
    Camera/
    Speech/
    Vision/
    Reminders/
    CloudKit/
    RevenueCat/
    PostHog/
    Sentry/
    GeminiLive/
  Extensions/
    ShareExtension/
    Widgets/
    AppIntents/
  Tests/
    Unit/
    Integration/
    UITests/
Backend/
  supabase/
    migrations/               # SQL schema + RLS policies
    functions/                # Deno Edge Functions, one per /v1 endpoint
      _shared/                # shared utils (auth, Gemini client, validators, hard-rule engine)
      session-bootstrap/
      config-bootstrap/
      ai-pantry-parse/
      ai-dinner-solve/
      ai-realtime-session/    # mints Gemini Live ephemeral session token
      ai-cook-turn/           # text fallback when Live API unavailable
      ai-substitution/        # also invoked from Realtime function-call round-trips
      ai-recipe-import/
      ai-grocery-generate/
      push-register/
      revenuecat-webhook/
      ops-flag-output/
      ops-admin/              # RLS-gated admin handlers
    seed/                     # prompt_versions seeds, feature flag defaults
```

### Backend API surface

| Endpoint                  | Method | Auth                                                | Purpose                                                                           | Idempotency                 |
| ------------------------- | ------ | --------------------------------------------------- | --------------------------------------------------------------------------------- | --------------------------- |
| `/v1/session/bootstrap`   | POST   | none on first call; rate-limited by IP + install ID | Establish session, resolve canonical user key, fetch flags + entitlements summary | yes via `installation_id`   |
| `/v1/config/bootstrap`    | GET    | session JWT                                         | Fetch feature flags, prompt versions, quota snapshot                              | cacheable                   |
| `/v1/ai/pantry-parse`     | POST   | session JWT                                         | Parse scan image into structured ingredients                                      | yes via `client_request_id` |
| `/v1/ai/dinner-solve`     | POST   | session JWT; Premium+ entitlement when `context_hint=leftovers` | Generate 3 ranked dinner options. Leftovers mode (`context_hint=leftovers`) rejects Free users with `ENT-LEFTOVERS-01` before consuming quota. | yes via `solve_request_id`  |
| `/v1/ai/realtime-session` | POST   | session JWT + Premium+ entitlement check            | Mint a short-lived Gemini Live ephemeral session token for Cook Mode voice. Server holds the Gemini API key and session config (model, voice, system prompt, allowed function calls, thinking level); client opens a stateful WebSocket directly to Gemini Live using the ephemeral token. Rejects with `ENT-VOICE-01` if user has no Cook Mode voice entitlement, or `RATE-01` if user has exceeded voice Cook Session quota. | session-scoped token; one mint per Realtime session, re-minted on session refresh (~every 10 min or 15 turns) |
| `/v1/ai/cook-turn`        | POST   | session JWT                                         | Text fallback for Cook Mode voice when Live API is unavailable                    | no; conversational          |
| `/v1/ai/substitution`     | POST   | session JWT                                         | Resolve missing ingredient / equipment / dietary change. Also invoked as the Realtime session's substitution function-call handler. | yes via `sub_event_id`      |
| `/v1/ai/recipe-import`    | POST   | session JWT                                         | Normalize URL / OCR text into structured recipe                                   | yes via `import_id`         |
| `/v1/ai/grocery-generate` | POST   | session JWT                                         | Generate grocery diff list from plan/session                                      | yes via `source_id`         |
| `/v1/push/register`       | POST   | session JWT                                         | Upsert APNs token and notification prefs                                          | yes                         |
| `/v1/revenuecat/webhook`  | POST   | RevenueCat signature                                | Receive entitlement changes                                                       | yes via webhook event ID    |
| `/v1/ops/flag-output`     | POST   | session JWT                                         | User flags bad AI output                                                          | yes                         |
| `/v1/ops/admin/*`         | mixed  | Supabase Auth (admin role) + RLS                    | Internal moderation, overrides, prompt rollbacks                                  | n/a                         |

### AI architecture

**Vendor:** Google Gemini (sole provider). All AI traffic routes through Gemini family models. No cross-vendor fallback is wired up in v1.

**Routing logic**

* Pantry scan / dinner solve / substitutions (outside Cook Mode) → **Gemini 3 Flash**
* **Cook Mode voice turns → Gemini 3.1 Flash Live Preview at `thinkingLevel: minimal` via direct client↔Gemini Live WebSocket connection.** The Supabase backend mints an ephemeral session token via the Gemini Live API's token-minting endpoint; the main Gemini API key never leaves Supabase Edge Functions. Each Cook Session gets a fresh ephemeral token; long Cook Sessions (>~10 min OR >15 turns, whichever comes first) transparently refresh by minting a new token and reopening the Live connection with a summarized context carry-over.
* **Cook Mode substitutions → triggered as a function call from inside the active Live API session, using an explicit Tool Call Preamble pattern: the system prompt instructs the model to speak a short neutral filler ("Let me check") immediately before emitting the function call. The function handler runs Gemini 3 Flash text generation with the standalone substitution prompt and the hard-rule validator, then returns a structured result which the Live session speaks back. The voice model never invents substitutions.**
* Recipe normalization / grocery structuring → **Gemini 3.1 Flash-Lite**
* Gemini Live API unavailable → Cook Mode voice falls back to local Speech (STT) → Gemini 3 Flash (text) → AVSpeechSynthesizer (TTS), with the `AI-VOICE-01` banner shown
* Gemini API fully down → no fresh AI generation; saved meals, cached plans, local timers, and manual edit paths remain functional

**Context management**

* No free-form long chat history
* Non-voice requests are built from typed domain state:

  * household profile
  * pantry snapshot
  * recipe plan
  * current step
  * last 4 user/assistant turns
* Cook Mode Live sessions bootstrap from the same typed state at session open; per-turn context then accumulates server-side within the session only, scoped to one Cook Session and discarded when the session closes
* **Session refresh as pruning**: Gemini Live has no mid-session history truncation frame, so cost is bounded by minting a new ephemeral token with a compact recap appended to `systemInstruction` and atomically swapping the WebSocket. Triggers: every 10 turns since last refresh OR any single turn exceeding 15,000 prompt tokens. This is the primary cost control lever given that Gemini Live does not support prompt caching AND does not support client-side truncation. See ADR 0014 for the protocol-level correction.
* On step advance / timer completion / substitution, the app sends a typed event to the active Live session so the model's notion of "current step" stays accurate
* Imported recipes are always treated as **untrusted content**, never as executable instructions

**Prompt versioning**

* Prompt templates live in backend `prompt_versions`
* Each prompt has:

  * `feature_key`
  * semantic version
  * model pin
  * schema hash
  * canary percentage
  * rollback flag
* App includes prompt version in telemetry on every AI call

**Guardrail layer**

* Hard dietary/allergen/equipment/time rules enforced outside the model
* JSON schema validation on every model response
* Any response that fails validation or violates hard rules is discarded and retried
* Realtime substitution function-call outputs run through the same hard-rule validator as the standalone `/v1/ai/substitution` endpoint before being spoken back
* Cook Mode system prompt pins `max_output_tokens` at ~150 to enforce response brevity and cap runaway output audio cost

**Cost observability**

* Every AI response logs provider, model, input tokens, output tokens, latency, cost, thinking_level
* Live sessions log per-turn audio token counts (input and output) and per-session cumulative totals, with a hard cap triggering automatic session refresh
* Daily rollups by feature and user cohort

## 4. Data Model

### On-device + CloudKit schema

#### 4.1 HouseholdProfile

| Field               | Type        | Notes                          |
| ------------------- | ----------- | ------------------------------ |
| id                  | UUID        | PK                             |
| canonicalUserKey    | String      | indexed, unique in local store |
| locale              | String      | default from device            |
| timezone            | String      | default from device            |
| servingsDefault     | Int16       | 1–12                           |
| preferredUnits      | String enum | imperial / metric              |
| onboardingCompleted | Bool        |                                |
| createdAt           | Date        | indexed                        |
| updatedAt           | Date        | indexed                        |
| deletedAt           | Date?       | soft delete                    |

**Indexes**: `canonicalUserKey`, `updatedAt`
**Delete**: soft-delete; cascades user-visible removal to child entities
**Audit**: yes

#### 4.2 DietaryRule

| Field       | Type        | Notes                           |
| ----------- | ----------- | ------------------------------- |
| id          | UUID        | PK                              |
| householdId | UUID        | FK                              |
| kind        | String enum | allergy / diet / dislike / goal |
| value       | String      | e.g. peanut, vegetarian         |
| severity    | String enum | hard / soft                     |
| source      | String enum | user / learned                  |
| isActive    | Bool        |                                 |
| createdAt   | Date        |                                 |
| updatedAt   | Date        |                                 |

**Constraint**: unique `(householdId, kind, value)`
**Delete**: hard delete
**Audit**: yes

#### 4.3 KitchenEquipment

| Field       | Type   |
| ----------- | ------ |
| id          | UUID   |
| householdId | UUID   |
| code        | String |
| isAvailable | Bool   |
| createdAt   | Date   |
| updatedAt   | Date   |

**Constraint**: unique `(householdId, code)`
**Delete**: hard delete
**Audit**: no

#### 4.4 PantryItem

| Field                   | Type        | Notes                                      |
| ----------------------- | ----------- | ------------------------------------------ |
| id                      | UUID        | PK                                         |
| householdId             | UUID        | FK                                         |
| canonicalIngredientSlug | String      | points to bundled catalog                  |
| displayName             | String      | user-facing                                |
| source                  | String enum | scan / manual / staple / import            |
| amountText              | String?     | optional, v1 mostly free text              |
| normalizedAmount        | Double?     | optional                                   |
| normalizedUnit          | String?     | optional                                   |
| quantityConfidence      | Double      | 0–1                                        |
| memoryState             | String enum | ephemeral / remembered / expired / unknown |
| lastSeenAt              | Date        | indexed                                    |
| expiresAt               | Date?       | indexed                                    |
| confidence              | Double      | 0–1                                        |
| userConfirmed           | Bool        |                                            |
| mediaAssetId            | UUID?       | FK nullable                                |
| createdAt               | Date        |                                            |
| updatedAt               | Date        |                                            |
| deletedAt               | Date?       | soft delete                                |

**Indexes**: `(householdId, lastSeenAt)`, `(householdId, memoryState)`, `expiresAt`
**Delete**: soft delete
**Audit**: yes

#### 4.5 MealSolveRequest

| Field                   | Type              |
| ----------------------- | ----------------- |
| id                      | UUID              |
| householdId             | UUID              |
| sourceAssetIds          | [UUID] serialized |
| constraintJSON          | Data              |
| pantrySnapshotJSON      | Data              |
| status                  | String enum       |
| aiRequestId             | String?           |
| requestedAt             | Date              |
| completedAt             | Date?             |
| selectedSuggestedDishId | UUID?             |
| deletedAt               | Date?             |

**Indexes**: `householdId`, `requestedAt desc`, `status`
**Delete**: soft delete
**Audit**: yes

#### 4.6 SuggestedDish

| Field                  | Type        |
| ---------------------- | ----------- |
| id                     | UUID        |
| solveRequestId         | UUID        |
| rank                   | Int16       |
| title                  | String      |
| summary                | String      |
| estimatedMinutes       | Int16       |
| fitLabelPrimary        | String enum |
| fitLabelSecondary      | String?     |
| missingIngredientCount | Int16       |
| hardConstraintPass     | Bool        |
| reasoningSummary       | String      |
| confidence             | Double      |
| recipePlanId           | UUID        |
| selectedAt             | Date?       |

**Constraint**: unique `(solveRequestId, rank)`
**Delete**: hard delete with parent
**Audit**: no

#### 4.7 RecipePlan

| Field             | Type        |
| ----------------- | ----------- |
| id                | UUID        |
| householdId       | UUID        |
| origin            | String enum |
| title             | String      |
| summary           | String      |
| servings          | Int16       |
| estimatedMinutes  | Int16       |
| cuisine           | String?     |
| difficulty        | Int16       |
| sourceURL         | String?     |
| sourceAttribution | String?     |
| isFavorite        | Bool        |
| isSaved           | Bool        |
| aiVersion         | String      |
| createdAt         | Date        |
| updatedAt         | Date        |
| archivedAt        | Date?       |
| deletedAt         | Date?       |

**Indexes**: `(householdId, updatedAt desc)`, `isFavorite`, `origin`
**Delete**: soft delete
**Audit**: yes

#### 4.8 RecipeIngredient

| Field                   | Type        |
| ----------------------- | ----------- |
| id                      | UUID        |
| recipePlanId            | UUID        |
| canonicalIngredientSlug | String?     |
| displayName             | String      |
| amountText              | String      |
| normalizedAmount        | Double?     |
| normalizedUnit          | String?     |
| isOptional              | Bool        |
| source                  | String enum |
| sortOrder               | Int16       |

**Indexes**: `(recipePlanId, sortOrder)`
**Delete**: hard delete with recipe
**Audit**: no

#### 4.9 Step

| Field           | Type                |
| --------------- | ------------------- |
| id              | UUID                |
| recipePlanId    | UUID                |
| stepNumber      | Int16               |
| title           | String?             |
| instructionText | String              |
| timerSeconds    | Int32?              |
| cautionTags     | [String] serialized |
| sortOrder       | Int16               |

**Constraint**: unique `(recipePlanId, stepNumber)`
**Delete**: hard delete with recipe
**Audit**: no

#### 4.10 RecipeImport

| Field        | Type        |
| ------------ | ----------- |
| id           | UUID        |
| householdId  | UUID        |
| sourceType   | String enum |
| sourceURL    | String?     |
| rawTextHash  | String      |
| ocrPageCount | Int16       |
| status       | String enum |
| submittedAt  | Date        |
| completedAt  | Date?       |
| aiRequestId  | String?     |
| recipePlanId | UUID?       |
| errorCode    | String?     |

**Indexes**: `submittedAt desc`, `status`
**Delete**: hard delete after linked recipe exists and retention window passes
**Audit**: yes

#### 4.11 CookingSession

| Field                 | Type                |
| --------------------- | ------------------- |
| id                    | UUID                |
| householdId           | UUID                |
| recipePlanId          | UUID                |
| entryPoint            | String enum         |
| sessionStatus         | String enum         |
| currentStepIndex      | Int16               |
| startedAt             | Date                |
| endedAt               | Date?               |
| lowConfidenceCount    | Int16               |
| localNotificationIds  | [String] serialized |
| aiConversationVersion | String              |
| voiceEnabled          | Bool                |
| deletedAt             | Date?               |

**Indexes**: `(householdId, startedAt desc)`, `sessionStatus`
**Delete**: soft delete
**Audit**: yes

#### 4.12 VoiceTurn

| Field            | Type        |
| ---------------- | ----------- |
| id               | UUID        |
| cookingSessionId | UUID        |
| turnIndex        | Int16       |
| speaker          | String enum |
| transcriptText   | String      |
| inputMode        | String enum |
| latencyMs        | Int32       |
| resultType       | String enum |
| createdAt        | Date        |

**Indexes**: `(cookingSessionId, turnIndex)`
**Delete**: hard delete with session or on retention expiry
**Audit**: no

#### 4.13 Timer

| Field            | Type        |
| ---------------- | ----------- |
| id               | UUID        |
| cookingSessionId | UUID        |
| stepId           | UUID?       |
| label            | String      |
| durationSec      | Int32       |
| startedAt        | Date?       |
| endedAt          | Date?       |
| state            | String enum |

**Indexes**: `(cookingSessionId, state)`
**Delete**: hard delete with session
**Audit**: no

#### 4.14 SubstitutionEvent

| Field                     | Type    |
| ------------------------- | ------- |
| id                        | UUID    |
| cookingSessionId          | UUID    |
| recipeIngredientId        | UUID?   |
| stepId                    | UUID?   |
| userProblemText           | String  |
| modelSuggestionText       | String  |
| accepted                  | Bool?   |
| acceptedAlternativeText   | String? |
| hardConstraintCheckPassed | Bool    |
| createdAt                 | Date    |

**Indexes**: `(cookingSessionId, createdAt desc)`
**Delete**: hard delete with session
**Audit**: yes

#### 4.15 OutcomeFeedback

| Field            | Type        |
| ---------------- | ----------- |
| id               | UUID        |
| cookingSessionId | UUID        |
| rating           | Int16       |
| workload         | String enum |
| taste            | String enum |
| spiceLevel       | String enum |
| wouldRepeat      | Bool        |
| notes            | String?     |
| leftoverCount    | Int16       |
| createdAt        | Date        |

**Constraint**: unique `cookingSessionId`
**Delete**: hard delete with session or user deletion
**Audit**: yes

#### 4.16 GroceryList

| Field                  | Type        |                  |
| ---------------------- | ----------- | ---------------- |
| id                     | UUID        |                  |
| householdId            | UUID        |                  |
| sourceCookingSessionId | UUID?       |                  |
| status                 | String enum | draft / exported |
| reminderListId         | String?     |                  |
| exportedAt             | Date?       |                  |
| createdAt              | Date        |                  |

**Indexes**: `createdAt desc`, `status`
**Delete**: soft delete
**Audit**: yes

#### 4.17 GroceryItem

| Field                   | Type        |
| ----------------------- | ----------- |
| id                      | UUID        |
| groceryListId           | UUID        |
| canonicalIngredientSlug | String?     |
| displayName             | String      |
| quantityText            | String?     |
| priority                | String enum |
| isChecked               | Bool        |
| reminderId              | String?     |
| sortOrder               | Int16       |

**Indexes**: `(groceryListId, sortOrder)`
**Delete**: hard delete with list
**Audit**: no

#### 4.18 MediaAsset

| Field            | Type        |                                 |
| ---------------- | ----------- | ------------------------------- |
| id               | UUID        |                                 |
| ownerType        | String enum |                                 |
| ownerId          | UUID        |                                 |
| localPath        | String      |                                 |
| thumbnailPath    | String?     |                                 |
| mimeType         | String      |                                 |
| byteSize         | Int64       |                                 |
| width            | Int32       |                                 |
| height           | Int32       |                                 |
| persistenceScope | String enum | temp / keep_local / cloud_asset |
| capturedAt       | Date        |                                 |
| expiresAt        | Date?       |                                 |

**Indexes**: `ownerType+ownerId`, `expiresAt`
**Delete**: hard delete + file removal
**Audit**: no

### Bundled read-only ingredient catalog

`IngredientCanonical` is **not** a CloudKit-synced user entity in v1.
It ships as a bundled JSON/SQLite resource with:

* `slug`
* `displayName`
* `aliases`
* `category`
* `defaultShelfLifeHint`
* `allergenTags`
* `unitHints`
* `substitutionClass`

This avoids syncing a global ontology through user storage.

### Foreign keys and cascade policy

* `HouseholdProfile` → cascades delete to all user-generated entities
* `RecipePlan` → cascades hard delete to `RecipeIngredient`, `Step`
* `CookingSession` → cascades hard delete to `VoiceTurn`, `Timer`, `SubstitutionEvent`, `OutcomeFeedback`
* `GroceryList` → cascades hard delete to `GroceryItem`
* `MediaAsset` → deleting owner nullifies if asset is reusable; otherwise delete file + row

### Soft delete vs hard delete

**Soft delete**

* HouseholdProfile
* PantryItem
* MealSolveRequest
* RecipePlan
* CookingSession
* GroceryList

**Hard delete**

* DietaryRule
* KitchenEquipment
* SuggestedDish
* RecipeIngredient
* Step
* RecipeImport after retention expiry
* VoiceTurn
* Timer
* SubstitutionEvent
* OutcomeFeedback
* GroceryItem
* MediaAsset

### Audit trail

Use **Core Data persistent history tracking** for:

* HouseholdProfile
* PantryItem
* MealSolveRequest
* RecipePlan
* RecipeImport
* CookingSession
* SubstitutionEvent
* OutcomeFeedback
* GroceryList

### Backend operational schema

All tables live in Supabase Postgres with Row-Level Security enabled. Every row is keyed by `canonical_user_key` (or a hash for sensitive tables), and the default RLS policy restricts row access to the caller's own key as resolved by `/v1/session/bootstrap`. Ops-only tables (`prompt_versions`, `feature_flags`, `ops_flagged_outputs`, `audit_log`) are gated to the admin role only. `notification_jobs` dispatch is driven by `pg_cron` scheduling a dispatcher Edge Function that reads from `pgmq` and sends via APNs.

| Table                   | Key fields                                                                                                                                                                            | Purpose                        |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| `app_users`             | `canonical_user_key PK`, `current_install_id`, `revenuecat_app_user_id`, `source_type`, `merged_into`, `created_at`, `last_seen_at`                                                   | Canonical identity and aliases |
| `device_installations`  | `installation_id PK`, `canonical_user_key FK`, `build`, `os_version`, `push_token`, `notifications_enabled`, `last_seen_at`                                                           | Installation tracking          |
| `entitlement_snapshots` | `canonical_user_key FK`, `tier`, `is_trial`, `expires_at`, `billing_state`, `updated_at`                                                                                              | Current plan state             |
| `usage_counters`        | `canonical_user_key`, `period_start`, `feature_key`, `used_count`, `cap_count`, `updated_at`                                                                                          | Monthly limits                 |
| `ai_request_log`        | `request_id PK`, `canonical_user_key`, `feature_key`, `model`, `input_tokens`, `output_tokens`, `cost_usd`, `latency_ms`, `thinking_level`, `prompt_version`, `created_at`            | Cost + reliability             |
| `prompt_versions`       | `feature_key`, `version`, `provider_model`, `template_blob`, `schema_hash`, `rollout_pct`, `is_default`, `is_enabled`, `created_at`                                                   | Prompt control                 |
| `feature_flags`         | `key PK`, `payload_json`, `rollout_pct`, `is_enabled`, `updated_at`                                                                                                                   | Runtime config                 |
| `ops_flagged_outputs`   | `id PK`, `request_id`, `canonical_user_key_hash`, `feature_key`, `issue_type`, `status`, `reviewer_note`, `created_at`                                                                | Manual review queue            |
| `audit_log`             | `id PK`, `actor_type`, `actor_id`, `action`, `target_type`, `target_id`, `metadata_json`, `created_at`                                                                                | Admin trace                    |
| `notification_jobs`     | `id PK`, `canonical_user_key`, `kind`, `scheduled_at`, `state`, `payload_json`                                                                                                        | Remote push jobs only          |

### Multi-tenancy boundary

* **User content**: isolated by Apple at the **CloudKit private database** boundary
* **Backend operational data**: isolated by `canonical_user_key`; enforced by Postgres RLS on every ops table; no direct client database access (all traffic goes through Supabase Edge Functions authenticated by the session JWT)
* **No shared vector store**
* **No cross-user memory**

## 5. Feature Inventory

| Feature                     | Description                                            | User story + acceptance criteria                                                                                                                                           | Screens                        | Data touchpoints                                | Integrations                         | Success metric             |
| --------------------------- | ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------ | ----------------------------------------------- | ------------------------------------ | -------------------------- |
| Camera pantry scan          | Scan fridge/pantry/counter into structured ingredients | As a cook, I want to point at ingredients and get a usable list in <10s. **Accept:** image captured, parsed, editable chips shown, user can continue even with uncertainty | Scan Camera, Scan Review       | MediaAsset, PantryItem, MealSolveRequest        | Camera, Vision, Gemini 3 Flash       | scan completion rate       |
| Household setup             | Capture diet, dislikes, servings, equipment            | As a new user, I want Stir to know my constraints before it suggests food. **Accept:** setup completes in <30s and persists                                                | Welcome, Setup screens         | HouseholdProfile, DietaryRule, KitchenEquipment | local only                           | onboarding completion      |
| Tonight solver              | Generate 3 ranked dinner options                       | As a tired user, I want three real choices, not 30. **Accept:** up to 3 options, all pass hard constraints, each shows fit reason. If <3 options pass hard rules (sparse pantry + strict dietary rules), show what's available plus a 'broaden constraints' CTA — never pad with rule-violating options                                        | Constraints, Dinner Options    | MealSolveRequest, SuggestedDish, RecipePlan     | Gemini 3 Flash                       | solve-to-selection rate    |
| Ranking labels              | Show fastest / least waste / best fit                  | As a user, I want to know why each option exists. **Accept:** each option displays a primary label and short rationale                                                     | Dinner Options                 | SuggestedDish                                   | Gemini 3 Flash                       | option trust click-through |
| Pantry staples profile      | Persist assumed staples separately from scans          | As a user, I want Stir to assume oil/spices/rice without rescanning every time. **Accept:** staples editable and applied in solves                                         | Household Preferences          | PantryItem                                      | local/CloudKit                       | repeat solve rate          |
| Cook Mode (tap-based)       | Step cards + swipe/tap progression. Available on all tiers. | As a cook, I want the app to stay on the current step, not bury me in text. **Accept:** current step visible, next/previous reliable, timers attach to steps               | Cook Mode                      | RecipePlan, Step, CookingSession, Timer         | ActivityKit                          | cook start rate            |
| Auto timers                 | Generate timers from steps                             | As a cook, I want timers without manual setup. **Accept:** timers created from step metadata and editable before start                                                     | Cook Mode                      | Timer, Step                                     | local notifications, Live Activities | timer usage rate           |
| Hands-free Q&A              | Voice question answering in Cook Mode. **Premium+ only.** | As a user, I want to ask "what next?" or "is this simmering?" without leaving the flow. **Accept:** spoken response begins <1.0s p95 (time-to-first-audio) and is tied to the current step; user can interrupt mid-response (barge-in); voice button tapped on Free tier → hard paywall presenting annual trial CTA. | Cook Mode, Paywall             | VoiceTurn, CookingSession                       | Microphone, Gemini 3.1 Flash Live Preview (primary); Speech + Gemini 3 Flash text + AVSpeechSynthesizer (fallback when Live API unavailable) | cook-mode turn success, voice-triggered conversion |
| Mid-cook substitutions      | Resolve missing ingredient/equipment/change-of-plan. Text-based for Free (sheet); voice-invoked via function call for Premium+. | As a user, I want a rescue path when I'm out of something. **Accept:** substitute respects hard rules and updates current plan                                             | Substitution Sheet             | SubstitutionEvent, RecipePlan                   | Gemini 3 Flash                       | accepted substitution rate |
| Portion scaling             | Recompute ingredient amounts and steps                 | As a user, I want to halve/double a meal. **Accept:** ingredients and timer hints rescaled before or during session                                                        | Dish Preview, Cook Mode        | RecipePlan, RecipeIngredient                    | local compute                        | scale feature use          |
| Leftovers mode              | Suggest next-day reuse                                 | As a user, I want leftovers to become the next dinner, not waste. **Accept:** leftovers create a follow-up suggestion or reminder                                          | Feedback Sheet, Leftovers      | OutcomeFeedback, PantryItem, RecipePlan         | local notifications, Gemini 3 Flash  | leftovers follow-up rate   |
| Share extension import      | Accept recipes from Safari/social share sheet          | As a user, I want to import a recipe without copy/paste. **Accept:** URL/text lands in Import Review and normalizes into editable steps                                    | Share Extension, Import Review | RecipeImport, RecipePlan                        | Share Extension                      | import start rate          |
| Photo/screenshot OCR import | Turn screenshots or recipe cards into steps            | As a user, I want to photograph a recipe and cook from it. **Accept:** OCR text extracted on device, AI normalizer produces editable structure                             | Import Entry, Import Review    | MediaAsset, RecipeImport, RecipePlan            | Photos, Vision, Gemini 3.1 Flash-Lite | OCR parse accept rate      |
| Grocery export              | Send missing items to Reminders                        | As a user, I want the shortfall list in my existing reminders app. **Accept:** items export to chosen list; on permission denial, list stays in-app                        | Grocery Export                 | GroceryList, GroceryItem                        | EventKit Reminders                   | export completion          |
| Pantry correction chips     | Fix scan mistakes fast                                 | As a user, I want correcting the scan to be easier than retyping. **Accept:** add/remove/rename via chips, no full form required                                           | Scan Review                    | PantryItem                                      | local                                | correction completion      |
| Saved meals / favorites     | Replay meals that worked                               | As a user, I want one-tap replay for reliable weeknight wins. **Accept:** saved favorite opens straight to preview or Cook Mode                                            | Saved Library, Recipe Detail   | RecipePlan, OutcomeFeedback                     | CloudKit                             | repeat-cook rate           |
| Widget                      | Launch Tonight mode from Home Screen                   | As a user, I want faster entry when it's dinner time. **Accept:** widget opens app to Tonight Home or Use Soon card                                                        | Widget                         | none + local snapshots                          | WidgetKit                            | widget tap rate            |
| Shortcuts / App Intents     | Voice-launch "What can I cook?" and quick add          | As a user, I want Siri/Shortcuts entry points. **Accept:** shortcut opens app with prefilled mode or adds pantry item                                                      | App Intents                    | PantryItem                                      | Shortcuts, App Intents               | shortcut run rate          |
| Post-meal feedback          | Capture what worked and what did not                   | As a user, I want Stir to learn my taste and workload tolerance. **Accept:** 10-second sheet after cook, optional notes                                                    | Feedback Sheet                 | OutcomeFeedback                                 | local                                | feedback completion        |

## 6. Screen Inventory

### Global error copy matrix

Use these exact messages everywhere; each screen references applicable codes.

| Code            | User-visible message                                                                        | Recovery action                    |
| --------------- | ------------------------------------------------------------------------------------------- | ---------------------------------- |
| `NET-01`        | "Couldn't reach Stir right now. Check your connection and try again."                       | Retry / Go Back                    |
| `INTERNAL-01`   | "Stir hit an unexpected error on our end. Please try again in a moment."                    | Retry / Go Back                    |
| `AI-01`         | "Dinner planning is temporarily unavailable. Try again in a moment or cook a saved meal."   | Retry / Open Saved Meals           |
| `AI-02`         | "I'm not confident about a few ingredients. Confirm them to keep going."                    | Review Ingredients                 |
| `AI-03`         | "This is taking longer than expected."                                                      | Keep Waiting / Retry / Cook Saved  |
| `AI-VOICE-01`   | "Voice mode running in reduced quality — still here to help."                               | Continue / Use Taps                |
| `IMPORT-01`     | "I couldn't turn that recipe into clean steps yet."                                         | Edit Manually / Retry / Cancel     |
| `PERM-CAM-01`   | "Camera access is off. Turn it on to scan your kitchen."                                    | Open Settings / See sample dinner ideas |
| `PERM-MIC-01`   | "Microphone access is off. You can keep cooking with taps, or turn on the mic in Settings." | Keep Cooking / Open Settings       |
| `PERM-PHOTO-01` | "Photos access is off. Enable it to import a screenshot or recipe photo."                   | Open Settings / Paste Link Instead |
| `PERM-REM-01`   | "Reminders access is off. Your grocery list will stay in Stir until you enable Reminders."  | Keep In App / Open Settings        |
| `SYNC-01`       | "iCloud Sync isn't available. Stir will work on this device only for now."                  | Continue Locally / Learn More      |
| `RATE-01`       | "You've used all of this month's available actions for your plan."                          | Upgrade / See Reset Date           |
| `BILL-01`       | "We couldn't confirm your subscription right now."                                          | Restore Purchases / Retry          |
| `PAY-01`        | "Purchase didn't go through. You weren't charged."                                          | Try Again / Choose Another Plan    |
| `ENT-VOICE-01`  | "Cook Mode voice is a Premium feature. Try it free for 7 days."                             | Start Trial / See Plans            |
| `ENT-MULTI-IMAGE-01` | "Multi-image scan is available on Pro. Upgrade to scan your whole kitchen at once."    | See Plans / Continue with one      |
| `ENT-LEFTOVERS-01`   | "Turn leftovers into a next meal with Stir Premium. Try it free for 7 days."           | Start Trial / See Plans            |
| `VOICE-SESSION-01`   | *(internal; iOS rebuilds voice driver silently)*                                         | Driver rebuild (silent)            |
| `VAL-01`        | "Something went wrong. Please try again or contact support if this keeps happening."        | Retry / Contact Support            |
| `AUTH-01`       | *(internal; auto-handled by iOS re-bootstrap)*                                              | Auto-refresh (silent)              |
| `METHOD-NOT-ALLOWED-01` | *(internal; never user-visible — client bug)*                                       | None (Sentry alert)                |

**`VAL-01` — request body validation failure.** Server returns `400 { error: "VAL-01", message, field_errors: [{ field, issue }] }`. iOS logs the full payload to Sentry at `error` severity and shows the generic user-visible copy above (one-tap Retry; Contact Support for persistent failures). iOS never retries automatically — a malformed request body is an iOS bug, not a transient failure.

`field_errors` shape:

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

**`AUTH-01` — session missing / expired / malformed / signature_invalid / user_stale / reauth_required.** Server returns `401 { error: "AUTH-01", message, reason: "missing" | "expired" | "malformed" | "signature_invalid" | "user_stale" | "reauth_required" }`. iOS auto-re-bootstraps via `/v1/session/bootstrap` and retries the original request ONCE for the first five reasons. `missing|expired|user_stale` are routine (info-level); `malformed|signature_invalid` page Sentry at alert threshold. **`reauth_required` is distinct:** set by admin `users.force_reauth` (step-8 ADR 0023), maps to a Sign-in-with-Apple re-flow (rotate Keychain install_id + clear canonical_user_key + nav to SIWA with header "Please sign in again to continue") rather than silent retry. If any retry-path 401s again, surface `NET-01` (no retry storm). See `CLAUDE.md` §"AUTH-01 response shape" and ADR 0023.

**`VOICE-SESSION-01` — voice session lifecycle violation.** Server returns `{ error: "VOICE-SESSION-01", message, reason: "session_missing" | "owner_mismatch" | "session_closed" | "lookup_failed" }`. HTTP 403 for the first three reasons; HTTP 500 for `lookup_failed`. iOS rebuilds the voice driver silently — NEVER paywalls (`ENT-VOICE-01` has Premium-upsell semantics and would punish a superseded Premium user). Reasons: `session_missing` = mint-race or retention cron cleanup; `owner_mismatch` = IDOR attempt (authenticated user posting turns under another user's session_id); `session_closed` = superseded by a newer mint from the same user; `lookup_failed` = transient DB error during the `voice_session_owners` SELECT (replica lag, connectivity blip) — same silent-rebuild handler path; the distinction is server-side observability. Not listed on any screen-level applicable-errors row because the error is internal-only (matches `AUTH-01` treatment). See ADR 0017.

**`INTERNAL-01` — 500-class server error (response received, server failed).** Server returns `500 { error: "INTERNAL-01", message }`. Distinct from `NET-01` (which iOS interprets as "no response received / network unreachable") so dashboards can separate edge-network problems from server-side bugs and user-facing copy can say "server" instead of "your connection". iOS shows the generic user-visible copy above with Retry / Go Back. Sentry captures at `error` severity with the originating `request_id`.

**`METHOD-NOT-ALLOWED-01` — wrong HTTP method against an endpoint.** Server returns `405 { error: "METHOD-NOT-ALLOWED-01", message }`. Internal-only (client bug, never user-visible) — same treatment as `AUTH-01` and `VOICE-SESSION-01`. iOS logs to Sentry at `error` with the offending request line. No retry (client bug). Mapped at the Edge Function shared handler boundary: any handler whose `Allow` header doesn't include the incoming `request.method` returns this code. iOS should never fire one in steady state — appearance in production telemetry indicates an endpoint contract drift between iOS and Edge Functions.

**ENT-\* paywall trigger mapping.** Each entitlement-gated error code maps 1:1 to a `paywall_viewed.trigger` value (see §15). When iOS receives one of these codes from a server-gated action, it routes to `PaywallView` with the matching trigger:

| Server error | `paywall_viewed.trigger` | Origin surface |
| --- | --- | --- |
| `ENT-VOICE-01` | `voice_affordance_tapped` (Free tap) or `voice_cook_quota_exhausted` (cap reached) | Cook Mode mic affordance |
| `ENT-MULTI-IMAGE-01` | `multi_image_scan_gate` | Scan Camera (≥2 photo selection) |
| `ENT-LEFTOVERS-01` | `leftovers_gate` | Post-cook feedback (leftover count >0) |

Other paywall triggers (`dinner_solve_quota_exhausted`, `pantry_cap_reached`, `recipe_import_quota_exhausted`, `saved_favorites_gate`, `widgets_gate`, `settings_upgrade`) originate from client-side gates rather than server error codes and don't have a corresponding `ENT-*` row.

### Accessibility baseline

Every screen must meet a WCAG 2.2 AA-equivalent mobile baseline:

* Dynamic Type through XXXL without clipped primary actions
* 44x44pt minimum hit targets
* VoiceOver labels for every action, ingredient chip, and timer
* no color-only confidence communication
* Reduce Motion respected
* captions / text alternatives for spoken guidance
* haptics optional, never required

### Screen table

| Screen                      | Purpose                                  | User actions                                                   | Data displayed                                 | Transitions                                             | Loading / empty                                                | Applicable errors                         | A11y notes                                       |
| --------------------------- | ---------------------------------------- | -------------------------------------------------------------- | ---------------------------------------------- | ------------------------------------------------------- | -------------------------------------------------------------- | ----------------------------------------- | ------------------------------------------------ |
| Launch / Session Restore    | Restore local state, entitlements, flags | none                                                           | splash + spinner                               | to Welcome or Tonight Home                              | loading skeleton only                                          | `NET-01`, `BILL-01`, `SYNC-01` banner     | announce loading status                          |
| Welcome                     | Frame core value, start onboarding       | Try it now, See a sample                                       | tagline, short explainer                       | to Setup 1 or Sample Solve                              | no empty state                                                 | none                                      | clear heading hierarchy                          |
| Setup 1: Preferences        | Collect diet/dislikes/goals              | select chips, next                                             | preference choices                             | to Setup 2                                              | saved draft state                                              | none                                      | chip labels read as toggle state                 |
| Setup 2: Kitchen & Servings | Collect equipment/servings               | select, next                                                   | equipment list, serving picker                 | to Tonight Home                                         | saved draft state                                              | none                                      | all controls accessible via rotor                |
| Tonight Home                | Default control center                   | Scan Kitchen, Import Recipe, Cook Saved, open paywall          | recent meals, use-soon card, plan badge        | to Scan, Import, Saved, Plan                            | loading recent history; empty = first-use cards                | `SYNC-01`, `BILL-01` banner               | widget-like cards with descriptive labels        |
| Scan Camera                 | Capture kitchen image                    | capture, retake, pick sample                                   | live preview, framing hints                    | to Scan Review                                          | loading camera; empty if no permission → sample offer          | `PERM-CAM-01`, `NET-01`                   | voice guidance optional for framing              |
| Scan Review                 | Confirm parsed ingredients               | confirm/remove/add, continue                                   | ingredient chips with confidence               | to Constraints                                          | skeleton while parse runs; empty impossible if parse succeeded | `AI-02`, `AI-03`, `AI-01`                 | confidence communicated by text and icon         |
| Constraints Sheet           | Add tonight constraints                  | set time/goal/use-first, solve                                 | picker chips                                   | to Dinner Options                                       | defaults prefilled                                             | `RATE-01`, `NET-01`                       | large segmented controls                         |
| Dinner Options              | Show 3 ranked meals                      | tap card, rescan, adjust constraints                           | 3 cards with labels and missing counts         | to Dish Preview, back to Constraints                    | skeleton cards while solving; empty or <3 viable = 'broaden constraints' retry card with suggestions (relax time window, drop one optional dislike, confirm 1–2 pantry staples)               | `AI-01`, `AI-03`, `RATE-01`               | cards read rank, time, fit reason                |
| Dish Preview                | Show chosen meal before cook             | start cook, scale servings, export groceries, favorite         | ingredients, missing items, first steps        | to Cook Mode, Grocery Export, Paywall                   | loading minimal                                                | `RATE-01`, `BILL-01` when locked action   | ingredient list supports VoiceOver reorder       |
| Cook Mode                   | Core execution surface (tap-based for Free, voice+tap for Premium+) | next/prev step, ask (voice — Premium+), start/pause timer, substitution, scale | current step, upcoming step, timers, mic state (Premium+ only) | to Substitution, Feedback, background via Live Activity | step skeleton if session restore; no empty state               | `PERM-MIC-01`, `AI-01`, `AI-03`, `AI-VOICE-01`, `ENT-VOICE-01`, `NET-01` | step text large, timer announced                 |
| Substitution Sheet          | Rescue missing ingredient/equipment      | describe issue, accept/reject suggestion                       | current ingredient, suggestion, why            | back to Cook Mode                                       | spinner while generating                                       | `AI-01`, `AI-03`                          | accepted/rejected buttons distinct               |
| Import Entry                | Choose import source                     | paste URL, open Photos, open share import                      | entry options                                  | to Import Review                                        | empty = helper copy                                            | `PERM-PHOTO-01`, `NET-01`                 | input labels explicit                            |
| Share Extension Import      | Receive recipe from another app          | import, cancel                                                 | source URL/text preview                        | to app deep link Import Review                          | spinner while handoff                                          | `IMPORT-01`, `NET-01`                     | concise action names                             |
| Import Review / Edit        | Edit normalized recipe                   | edit title, ingredients, steps, save                           | structured recipe                              | to Dish Preview or Saved                                | skeleton while parse; empty = raw text editor fallback         | `IMPORT-01`, `AI-01`                      | editable fields accessible                       |
| Saved Library               | Browse favorites and imports             | open recipe, filter, delete, upgrade for favorites             | recent recipes, favorites, imports             | to Recipe Detail                                        | empty = "No saved meals yet"                                   | `RATE-01` for locked favorites            | list items with summary voice labels             |
| Recipe Detail / Replay      | Replay saved recipe                      | start cook, edit, unfavorite                                   | recipe plan                                    | to Cook Mode                                            | no empty                                                       | `BILL-01` if entitlement mismatch         | same as preview                                  |
| Leftovers                   | Show follow-up reuse ideas               | pick idea, dismiss                                             | leftover-based suggestions                     | to Dish Preview                                         | empty = "No leftovers queued"                                  | `AI-01`                                   | simple card actions                              |
| Grocery Export              | Review and send to Reminders             | export, copy, share                                            | grouped grocery items                          | back to preview/session                                 | empty = "Nothing missing"                                      | `PERM-REM-01`, `NET-01`                   | grouped by priority, not color-only              |
| Feedback Sheet              | Capture post-meal rating                 | rate meal, add notes, leftovers count                          | rating controls                                | to Tonight Home / Saved                                 | no empty                                                       | none                                      | fast, one-handed layout                          |
| Settings                    | App preferences and system state         | household prefs, plan, permissions, privacy, support           | plan card, sync state, notification prefs      | to sub-screens                                          | loading entitlements                                           | `BILL-01`, `SYNC-01`                      | readable grouped form                            |
| Household Preferences       | Edit setup data                          | modify rules/equipment/staples                                 | household profile                              | back to Settings                                        | empty = none                                                   | `SYNC-01` banner                          | all list edit actions accessible                 |
| Plan & Billing              | Upgrade/manage plan                      | see tiers, start trial, restore purchases, manage subscription | tier comparison, current usage counters        | back to Settings or paywall origin                      | loading products                                               | `PAY-01`, `BILL-01`, `RATE-01`            | price and trial copy readable without truncation |
| Local-Only / Sync Status    | Explain iCloud unavailability            | continue local, retry sync                                     | sync explanation                               | back to prior screen                                    | none                                                           | `SYNC-01`                                 | no fear-inducing language                        |
| Permission Recovery Sheet   | Explain denied permission in context     | open settings, alternate path                                  | reason + alternate path                        | back to origin                                          | none                                                           | context-specific permission code          | speaks alternate path first                      |

## 7. Onboarding Flow

### First 60–120 seconds

1. **Welcome**

   * CTA: **Try it now**
   * Secondary: **See a sample**
2. **Preferences**

   * hard dietary rules
   * soft dislikes/goals
3. **Kitchen & servings**

   * servings
   * equipment
4. **Tonight Home**

   * focus state: large **Scan Kitchen** button
5. **Camera primer**

   * "Point at your fridge, pantry, or counter."
6. **OS camera permission**

   * if denied, immediate sample-photo fallback
7. **Scan Review**

   * confirm/remove/add ingredients
8. **Constraints**

   * "20 minutes", "high protein", "use spinach first"
9. **Dinner Options**

   * aha moment
10. **Dish Preview**
11. **Cook Mode** (tap-based for Free users; voice affordance hidden until upgrade)

* if user taps the voice affordance (Premium+), microphone permission requested here

12. **Post-cook feedback / Reminders export**

* Reminders permission only when user taps export

### Aha moment

**User sees 3 viable dinners from their own ingredients within 120 seconds (p90).** First-time flow math: setup (25s) + Tonight Home (3s) + scan camera + permission (10s) + capture (5s) + parse p95 (4s) + review (10s) + constraints (15s) + solve p95 (3.5s) ≈ 75–80s best case, 110–140s realistic p90 accounting for user indecision and network variance. Stretch goal <90s applies only to the sample-photo path for returning/demo users.

### Trust-earning stub path

If any setup or permissions block first value:

* camera denied → bundled sample kitchen image
* photos denied → paste recipe URL
* mic denied → tap-only cook mode (default Free experience anyway)
* iCloud unavailable → local-only mode, no blockade

### Onboarding failure states

| Step              | Failure                | Response                            |
| ----------------- | ---------------------- | ----------------------------------- |
| Setup             | user skips preferences | allow skip, use generic defaults    |
| Camera permission | denied                 | sample photo fallback               |
| Scan parse        | AI timeout             | keep current image, retry parse     |
| Dinner solve      | provider outage        | retry, then open sample saved meal  |
| Cook Mode mic     | denied (Premium+)      | continue with taps                  |
| Reminders export  | denied                 | in-app grocery list with copy/share |

## 8. Engagement & Reactivation

Retention is weekly workflow, so reactivation should feel situational, not addictive.

| Trigger                     | Condition                                                                 | Channel                                      | Message                                                                                                 | Consent / quiet hours / caps                      | Expected response                       | Fallback if ignored twice       |
| --------------------------- | ------------------------------------------------------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------- | --------------------------------------- | ------------------------------- |
| Use-soon ingredient         | user has a remembered item with `expiresAt <= 48h` and no solve in 24h    | local notification                           | "Use your spinach before it goes — want 3 dinner ideas?"                                                | notification opt-in; 8am–8:30pm local; max 2/week | open Tonight with prefilled "use first" | show only widget card           |
| Leftovers follow-up         | previous session logged leftovers >0 and no follow-up solve in 20h        | local notification                           | "Your leftovers can become tomorrow's dinner in one tap."                                               | opt-in; 10am–7pm; max 2/week                      | open Leftovers screen                   | suppress for 14 days            |
| Recipe import complete      | async import finishes while app backgrounded                              | push or local notif if still pending locally | "Your recipe is ready to cook."                                                                         | opt-in; immediate; transactional                  | open Import Review                      | in-app banner next launch       |
| High-rated repeat candidate | user rated meal 4–5 and has not saved it                                  | in-app card after feedback                   | "Save this as a one-tap weeknight meal?"                                                                | no push; only after positive feedback             | save favorite (paywall if Free)         | never nag again for same recipe |
| Widget nudge                | user completes 3 sessions in 14 days and has no widget interaction        | in-app nudge on Home                         | "Pin Stir to your Home Screen for faster dinner starts."                                                | max once every 21 days                            | install widget (paywall if Free)        | dismiss permanently             |
| Billing grace period        | RevenueCat marks billing state grace/retry                                | push + in-app banner                         | "Your Stir plan is still active, but Apple couldn't renew it. Update billing to keep Premium features." | push opt-in; one push at state entry, one at 48h  | open Manage Subscription                | in-app banner only              |

> **Note (SCA-74, 2026-05-07):** the per-trial "2 days remaining" reminder was retired. Apple's system trial-end notification is sufficient for v1; we can re-add a Stir-side nudge if beta data shows trial-conversion underperforming the 25% target (§Definition-of-Done).
| Habit window reactivation   | user's `last_seen_at` falls between 14 and 21 days ago (any day); status='active'; push_token present; reactivation pref opted-in (default true) | APNs remote push                             | "What's for dinner? Haven't cooked in a while? See what tonight's dinner could be."                      | opt-in (default on); max 1 per 30-day window      | open Tonight Home via `stir://tonight?trigger=reactivation` deep link | suppress 30 days                |

**Focus awareness**
v1 does not request time-sensitive notification privileges. Use normal interruption levels and rely on iOS Focus handling. Respect app-level quiet hours if the user changes them.

## 9. Monetization & Billing

### Tier structure

| Tier            |     Price | Includes                                                                                                                                        | Overage behavior          |
| --------------- | --------: | ----------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- |
| Free            |        $0 | 6 Dinner Solves/mo, **unlimited tap-based Cook Sessions** (no voice), 25 remembered pantry items, 2 recipe imports/mo, text-based Substitution Sheet | hard cap on solves/imports until reset; tap Cook Mode always available |
| Premium monthly |  $9.99/mo | 40 Dinner Solves/mo, 13 voice Cook Sessions/mo (plus unlimited tap), 250 remembered pantry items, unlimited imports, widgets, shortcuts, leftovers, saved favorites | hard cap; upgrade or wait |
| Premium annual  | $69.99/yr | same as Premium monthly + **7-day free trial**                                                                                                  | hard cap; upgrade or wait |
| Pro monthly     | $14.99/mo | 120 Dinner Solves/mo, 27 voice Cook Sessions/mo (plus unlimited tap), 1,000 remembered pantry items, multi-image scans, priority inference queue, 365-day household memory | hard cap; upgrade or wait |
| Pro annual      | $139.99/yr | same as Pro monthly                                                                                                                            | hard cap; upgrade or wait |

**Tier design rationale.** Cook Mode voice is the headline differentiator — the feature that materially changes the cooking experience. Free tier gets the full scan-to-plan core loop (the aha moment) plus tap-based Cook Mode, but voice is Premium+. This creates a clear, experiential upgrade trigger: users see exactly what they're paying for the moment they tap the voice affordance.

Free tier is net-positive on unit economics without voice (~$0.08/user/mo AI cost). The 7-day Premium annual trial converts trial-ineligible quota-hitting conversions (~5%) into trial-starters (~25%) at ~45% trial-to-paid, materially improving free-to-paid conversion economics.

### SKU strategy

**Subscription group:** `stir.subscriptions`

**Products**

* `stir.premium.monthly`
* `stir.premium.annual.trial7`
* `stir.pro.monthly`
* `stir.pro.annual`

**Family Sharing:** off for all SKUs
**Consumables:** none
**Intro offer:** 7-day free trial on `stir.premium.annual.trial7` only (Apple-native intro offer, one-per-Apple-ID enforced at platform level)

### Paywall strategy

**Primary conversion vehicle: the 7-day Premium annual trial.**

The paywall always leads with the annual trial as the headline CTA. Monthly Premium is a secondary CTA for users uncomfortable with trial auto-billing. Pro is tertiary.

**Paywall UX — standard full-sheet presentation**

* Hero: *Cook hands-free. Try Premium free for 7 days.*
* Primary CTA: **Start 7-day free trial** → `stir.premium.annual.trial7` ($59.99/yr, 7 days free, auto-renews)
* Secondary CTA: **Premium monthly, $9.99/mo** → `stir.premium.monthly` (no trial, immediate billing, cancel anytime)
* Tertiary link: **Compare plans** → reveals Pro tier
* Tertiary link: **Restore Purchases**
* Clear trial terms: "7 days free, then $69.99/yr. Cancel anytime in Settings."
* Current usage counters displayed for users who hit a quota

**Soft paywall moments** (dismissable, non-blocking; goal: seed conversion intent)

* After first successful Dinner Solve → one-time soft paywall: *"Loving it? Premium adds voice Cook Mode and saves your favorites."*
* When tapping a Premium-locked feature that isn't Cook Mode voice:
  * Save favorite
  * Leftovers mode
  * Widget setup
  * Shortcuts setup

**Hard paywall moments** (blocking; goal: capture high-intent conversion)

* **User taps voice affordance in Cook Mode on Free tier** — this is the single highest-intent paywall trigger. User has just decided they want hands-free cooking *right now*. Present paywall with `ENT-VOICE-01` framing: "Cook Mode voice is Premium. Try it free for 7 days."
* Free Dinner Solve quota exhausted (after 6 solves)
* Recipe Import quota exhausted (after 2 imports)
* Attempting Pro-only multi-image scan
* Attempting to exceed remembered pantry-item cap

**Trial management**

* In-app trial countdown visible in Settings and Plan & Billing during active trial
* Push + in-app banner at 2 days remaining (opt-in)
* Silent conversion on day 8 (Apple handles the billing event via webhook)
* User can cancel from Settings at any time during trial to avoid conversion

### Billable unit implementation

These map directly to entitlement counters and telemetry:

* **Dinner Solve** = one completed AI planning request that returns up to 3 ranked meals
* **voice Cook Session** (Premium+ only) = one accepted plan or imported recipe opened in Cook Mode **with voice enabled**, including up to 25 live AI turns and 5 substitution events within 6 hours
* **tap Cook Session** (all tiers) = unmetered, unlimited
* **Recipe Import** = one normalized recipe from URL, screenshot, photo, or pasted text

### Apple fee accounting

Apple's current subscription economics remain:

* **15%** proceeds for developers in the App Store Small Business Program
* otherwise **70%** net in the first paid year for auto-renewing subscriptions
* **85%** after one year of paid service in the same subscription group. ([Apple Developer][3])

**Net per paying user (steady-state, year 2+, non-SMB)**

* Premium monthly: `9.99 × 0.85 = $8.4915`
* Pro monthly: `14.99 × 0.85 = $12.7415`
* Premium annual monthly equivalent net: `(69.99 / 12) × 0.85 = $4.9576`
* Pro annual monthly equivalent net: `(139.99 / 12) × 0.85 = $9.9159`

**Year-1 annual net (70% proceeds):**

* Premium annual year-1 monthly equivalent: `(69.99 / 12) × 0.70 = $4.0828`
* Pro annual year-1 monthly equivalent: `(139.99 / 12) × 0.70 = $8.1661`

### Cohort economics

Use the AI cost model from §12.

Assumptions (per active user, per month):

* **Free AI cost**: $0.075 (scan + solve + import + grocery; no voice)
* **Premium AI cost**: $1.89 (Free features + 13 voice Cook Sessions at ADR 0015 caps; measured range $1.69–$2.08)
* **Pro AI cost**: $3.69 (Premium features + scaled to 27 voice Cook Sessions at ADR 0015 caps; measured range $3.51–$4.32)
* backend + observability = **$0.20**
* support reserve = **$0.15**

| Tier                          | Net revenue/mo |    AI | Infra | Support | Contribution margin/mo | 4-month CAC ceiling |
| ----------------------------- | -------------: | ----: | ----: | ------: | ---------------------: | ------------------: |
| Free                          |         0.0000 | 0.075 |  0.20 |    0.15 |           **−0.4250** |                 n/a |
| Premium monthly               |         8.4915 |  1.89 |  0.20 |    0.15 |             **6.2515** |           **25.01** |
| Pro monthly                   |        12.7415 |  3.69 |  0.20 |    0.15 |             **8.7015** |           **34.81** |
| Premium annual (steady-state) |         4.9576 |  1.89 |  0.20 |    0.15 |             **2.7176** |           **10.87** |
| Pro annual (steady-state)     |         9.9159 |  3.69 |  0.20 |    0.15 |             **5.8759** |           **23.50** |
| Premium annual (year 1)       |         4.0828 |  1.89 |  0.20 |    0.15 |             **1.8428** |            **7.37** |
| Pro annual (year 1)           |         8.1661 |  3.69 |  0.20 |    0.15 |             **4.1261** |           **16.50** |

**Margin flags:**

* **Pro annual year-1 contribution margin is $4.13/mo — healthy.** The Pro voice cap is deliberately set at 27 sessions per ADR 0015 (2026-04-23 revision after device-measured Live API cost data revealed the implicit-caching assumption was empirically false) and Pro annual priced at $139.99 to protect against the power-law usage distribution — a small fraction of Pro users consume at the cap while average users leave quota unused, so the realized average drifts toward the cap, not the mean. Pre-ADR-0015 configurations (40 and 60-session caps at various price points) were considered and rejected — they yielded fragile margins that couldn't absorb the per-turn cost reality plus any usage variance, and left insufficient headroom for founder-discount promotional codes during beta. The "preserve price, trim cap" tradeoff was durable where the alternative was a price-raise cliff. If beta telemetry shows <15% of Pro users hitting the 27-session cap AND caching emerges on Live API (ADR 0015 trigger query), consider raising the cap selectively via a superseding ADR rather than across the board.
* **Premium monthly is the healthiest SKU.** $6.25/mo contribution margin, $25.01 4-month CAC ceiling. Optimize acquisition here.
* **Free tier is $0.43/mo net negative.** At 5% free-to-paid conversion over 6 months and ~8 months average paid retention, each converted free user generates ~$30–60 lifetime value depending on SKU mix minus ~$2.55 in free-tier cost — comfortably net-positive at projected economics. Worth monitoring if free-tier cost drifts above $0.50/mo or if conversion falls below 3%.

### Billing edge cases

| Case                  | Handling                                                                                              |
| --------------------- | ----------------------------------------------------------------------------------------------------- |
| Refunds               | Apple-mediated; RevenueCat webhook updates entitlements; preserve local data, revoke locked features  |
| Upgrade/downgrade     | handled by subscription group; RevenueCat syncs new entitlement state                                 |
| Failed renewal        | enable Billing Grace Period; app stays unlocked while Apple retries payment if entitlement says grace |
| Billing retry         | show banner + manage-subscription CTA                                                                 |
| Restore purchases     | always visible in Plan & Billing                                                                      |
| Cancellation          | user retains access until period end; instrument cancellation reason survey in-app on next launch     |
| Offer codes           | supported for creator seeding and beta recovery; use Apple offer codes rather than custom promo logic |
| Promos                | v1 uses intro trial only; no win-back automation                                                      |
| Trial abuse           | Apple enforces intro-offer eligibility at platform level — one trial per Apple ID per subscription group, not our problem to enforce |
| International pricing | use App Store price matrix if later expanding outside US                                              |
| Taxes/VAT             | Apple handles store taxation and remittance                                                           |

Apple's current docs confirm Billing Grace Period behavior, support for offer codes across all IAP types, and current subscription handling paths. ([Apple Developer][4])

## 10. Account & Entitlement Model

### Account states

| State                   | Meaning                                 | Entry                                 | Exit                                                       |
| ----------------------- | --------------------------------------- | ------------------------------------- | ---------------------------------------------------------- |
| `anonymous_local`       | no iCloud, local-only, free tier        | first launch without CloudKit account | iCloud available, purchase, uninstall                      |
| `anonymous_synced_free` | canonical CloudKit identity, free tier  | first launch with CloudKit available  | trial, paid, banned                                        |
| `trial_premium`         | Premium annual in trial                 | successful intro offer redemption     | active premium, expired free, banned                       |
| `premium_active`        | paid Premium entitlement                | purchase or trial conversion          | cancelled_active, billing_grace, expired_free, upgrade_pro |
| `pro_active`            | paid Pro entitlement                    | purchase or upgrade                   | cancelled_active, billing_grace, expired_free              |
| `billing_grace`         | Apple retrying failed renewal           | webhook / entitlement state           | active, expired_free                                       |
| `cancelled_active`      | cancelled, access continues to end date | user cancellation                     | expired_free or resubscribe                                |
| `expired_free`          | paid access ended                       | expiry                                | resubscribe                                                |
| `banned`                | abuse / ToS violation                   | admin action                          | manual unban only                                          |

### Entitlements by tier

| Entitlement              |     Free |   Premium |       Pro |
| ------------------------ | -------: | --------: | --------: |
| Dinner Solves / month    |        6 |        40 |       120 |
| Tap Cook Sessions / month | unlimited | unlimited | unlimited |
| **Voice Cook Sessions / month** | **0**  |       **13** |       **27** |
| Recipe Imports / month   |        2 | unlimited | unlimited |
| Remembered pantry items  |       25 |       250 |     1,000 |

The "Remembered pantry items" cap is shipped to iOS on `entitlements.standing_pantry_cap` (bootstrap + config-bootstrap; SCA-100). iOS reads the wire value via `EntitlementService.rememberedPantryCap`, which falls back to `Tier.rememberedPantryCap` (constant table) when the field is absent (pre-SCA-100 server response or cold-launch-before-bootstrap). Server-side resolution goes through `effectiveTier()` so a stale RevenueCat row with `billing_state IN ('none','expired')` correctly demotes to the Free cap. Cap is enforced client-side only — user content lives in CloudKit per north-star #3, not Postgres — so the iOS gate (`PantryListViewModel`, `ScanViewModel`) is the only enforcement point. Future cap changes (marketing A/B, per-user override) ship via the bootstrap response without an iOS release; values stay in lockstep with the table above.
| **Cook Mode voice**      |     **no** |     **yes** |     **yes** |
| Substitution Sheet (text) |      yes |       yes |       yes |
| Saved favorites          |       no |       yes |       yes |
| Widgets                  |       no |       yes |       yes |
| Shortcuts / App Intents  |       no |       yes |       yes |
| Leftovers mode           |       no |       yes |       yes |
| Multi-image scan         |       no |        no |       yes |
| Priority inference queue |       no |        no |       yes |
| Preference memory window |  30 days |   90 days |  365 days |

### Session management

* backend session JWT TTL: **24 hours**
* refresh on app foreground after TTL or entitlement change
* one canonical user can use multiple devices if CloudKit identity is available
* local-only users are effectively single-device
* quotas:

  * paid tiers: server-side via backend `usage_counters`
  * free tier: local + CloudKit mirrored counter, with backend sanity limits
  * voice Cook Session quota enforced at `/v1/ai/realtime-session` token-mint time — refuses to mint if user has no voice entitlement or exceeded monthly cap

## 11. Data Lifecycle

### Retention policy

| Data class                      | Retention                                    | Notes                                                                     |
| ------------------------------- | -------------------------------------------- | ------------------------------------------------------------------------- |
| Household profile / preferences | until user deletes account/data              | synced via CloudKit                                                       |
| Pantry remembered items         | until user deletes or item expires + 30 days | stale cleanup weekly                                                      |
| Meal plans / saved recipes      | until user deletes                           | favorites preserved                                                       |
| Cooking sessions                | 24 months rolling                            | older sessions summarized then removed                                    |
| Voice turns                     | 30 days                                      | enough for support/debugging and personalization signals                  |
| Substitution events             | 12 months                                    | flywheel input                                                            |
| Outcome feedback                | 24 months                                    | personalization input                                                     |
| Raw scan images                 | 7 days max by default                        | temp assets auto-purged; shorter if parse succeeds and user does not save |
| Raw imported recipe images      | 14 days max                                  | purge after normalized recipe saved                                       |
| Grocery export metadata         | 90 days                                      | reminder IDs only                                                         |
| Backend AI request metadata     | 30 days raw, 13 months aggregate             | no raw user content in standard logs                                      |
| Crash logs                      | 90 days                                      | Sentry                                                                    |
| Analytics events                | 13 months                                    | PostHog standard retention target                                         |

### Deletion SLA

CCPA baseline:

* local delete: immediate
* CloudKit delete queue: same session when possible
* backend metadata purge: within **30 days**
* analytics pseudonymization / delete request: within **30 days**
* support path: in-app settings + support email

### Export format

**Export bundle**

* `profile.json`
* `pantry.csv`
* `recipes.json`
* `sessions.json`
* `feedback.csv`
* `grocery_exports.csv`
* optional `media/` folder for any user-kept images

Export initiated from Settings via share sheet.

### Backup + restore

* primary restore path: CloudKit private database
* local-only restore path: encrypted iPhone backup / restore
* no backend content restore needed because backend is not source of truth for user data

### Migration plan

* Core Data versioned model
* lightweight migrations whenever possible
* explicit mapping models only for breaking entity changes
* backend Supabase Postgres migrations (managed via `supabase db` / `supabase migration`) tracked in source control and applied per environment
* any prompt schema change must be backward-compatible for at least one app version

### Data residency

* user content sync: Apple CloudKit-managed regioning
* backend operational metadata: U.S. region
* AI provider: Google Gemini paid API endpoints, U.S.-hosted for launch configuration

## 12. AI Component Audit

### Provider choice and pricing

**Single provider: Google Gemini.** All AI traffic (scan, solve, voice, substitution, import, grocery) routes through Gemini family models. No cross-vendor fallback is wired up in v1.

**Pricing (Google AI, paid tier, per 1M tokens):**

| Model | Input (text/image/video) | Input (audio) | Output | Cache |
| --- | --- | --- | --- | --- |
| Gemini 3 Flash Preview | $0.50 | $1.00 | $3.00 | $0.05 text / $0.10 audio + $1.00/1M/hour storage |
| Gemini 3.1 Flash-Lite Preview | $0.25 | $0.50 | $1.50 | $0.025 text + $1.00/1M/hour storage |
| Gemini 3.1 Flash Live Preview | $0.75 (text) | $3.00 | $4.50 (text) / $12.00 (audio) | Not supported |

Key Live API facts:
- Audio tokens are metered at 25 tokens per second of audio (both directions)
- `thinkingLevel` defaults to `minimal` for Live sessions, optimized for lowest time-to-first-token
- Context window: 131,072 tokens
- Function calling: supported with streaming
- Caching: **not supported** for the Live API — cost control relies on context pruning
- Preview status: still labeled preview as of April 2026; mitigated by the `disable_cook_realtime` kill switch

Google's paid tier states content is **not** used to improve its products.

**Target ARPU used in % calculations**
Premium monthly net ARPU = **$8.4915**

### 12.1 Cost table

> **Updated 2026-04-23 with ADR 0015 cap reshuffle.** Step 6 Cook Mode voice shipped and was exercised across multiple 9+ turn sessions. Per-turn prompt tokens came in ~3x higher than the ADR 0014 amendment modeled, because the baked-in systemInstruction + recipe context + pantry + household + AUDIO-mode overhead is ~3,800 tokens per turn, not ~1,500. Real 15-turn session cost lands at ~$0.13-0.16 (vs $0.12-0.15 projected). Pre-ADR-0015, the 20-session/mo Premium cap would have landed at $2.56-$3.10/mo — 35-64% over the $1.89 AI budget line. ADR 0015 (2026-04-23) cut caps to Premium 13 / Pro 27 after a second device-measured finding confirmed implicit caching empirically does NOT fire on `gemini-3.1-flash-live-preview` (50+ turns checked, `usageMetadata.cachedContentTokenCount` zero or absent throughout). The "wait for caching GA" mitigation option is permanently assumed unavailable in cost models; the trigger-to-revisit query in ADR 0015 is the only path to reopen. See ADR 0014 "measured-reality cost correction" amendment and ADR 0015 for the full caching-finding + cap-reshuffle rationale.

**Voice Cook Mode cost model (device-measured):** context accumulates across turns at full audio input rate (no cache, no mid-session pruning — refresh IS the cost lever, ADR 0014). Refresh triggers at `turnCount - lastRefreshedAtTurn >= 4` OR `promptTokens > 10_000` on a single turn, `max_output_tokens: 400` cap (ADR 0010), pre-mint one turn before refresh (shaves ~1.9s off handoff).

Per turn, measured on 9-turn device session, cadence N=4, ~22% tool-call rate:
- Non-tool turn (steady-state): ~4,527 prompt tokens + ~124 response audio tokens
- Tool-call turn (double generation pass for toolCall + toolResponse): ~8,822 prompt tokens + ~150 response
- Prompt split ≈ 75/25 text/audio at low end, 60/40 at high end (backend captures `prompt_audio_tokens` + `prompt_text_tokens` for exact per-call breakdown in `ai_request_log` → PostHog LLM Observability)
- Blended rate at 75/25: $1.31/M prompt; at 60/40: $1.65/M prompt

Session cost at ~22% tool-call rate (7 refreshes per 30 turns):
- **15-turn session**: ~$0.13 (low end, 75/25) to ~$0.16 (high end, 60/40)
- **20-turn session**: ~$0.17 to ~$0.21
- **30-turn session**: ~$0.27 to ~$0.32

| Feature                 | Model                 | Representative token budget                                 |                               Cost per interaction | Volume / Premium user / month | Monthly AI cost / Premium user | % of Premium net ARPU |
| ----------------------- | --------------------- | ----------------------------------------------------------- | -------------------------------------------------: | ----------------------------: | -----------------------------: | --------------------: |
| Pantry scan parse       | Gemini 3 Flash        | 1 image @1120 tokens + ~1080 text/context input, 450 output |  `(2200 × $0.50/1M) + (450 × $3.00/1M) = $0.00245` |                            10 |                     `$0.02450` |               `0.29%` |
| Dinner solve            | Gemini 3 Flash        | 2400 input, 900 output                                      |  `(2400 × $0.50/1M) + (900 × $3.00/1M) = $0.00390` |                            12 |                     `$0.04680` |               `0.55%` |
| Voice Cook Mode session (15 turns, measured) | Gemini 3.1 Flash Live Preview (MINIMAL) | ~4,527 prompt / non-tool turn + ~8,822 / tool-call turn + ~124 response audio/turn; 75/25 to 60/40 text:audio split | `~$0.142 per 15-turn session` (midpoint of $0.13-$0.16 range) | 13 sessions (ADR 0015) | `$1.84600` | `21.74%` |
| Substitution rescue     | Gemini 3 Flash        | 1600 input, 260 output                                      |  `(1600 × $0.50/1M) + (260 × $3.00/1M) = $0.00158` |                             8 |                     `$0.01264` |               `0.15%` |
| Recipe import normalize | Gemini 3.1 Flash-Lite | 2200 OCR text input, 550 output                             | `(2200 × $0.25/1M) + (550 × $1.50/1M) = $0.001375` |                             4 |                     `$0.00550` |               `0.06%` |
| Grocery list generation | Gemini 3.1 Flash-Lite | 650 input, 140 output                                       | `(650 × $0.25/1M) + (140 × $1.50/1M) = $0.0003725` |                             4 |                     `$0.00149` |               `0.02%` |

**Total monthly AI cost / Premium user = `0.02450 + 0.04680 + 1.84600 + 0.01264 + 0.00550 + 0.00149 = $1.93693`**
**Total AI cost as % of Premium net ARPU = `1.93693 / 8.4915 = 22.81%`**

**Lands inside the 22.27% Premium AI guardrail per ADR 0015.** At 13-session × 15-turn cap, total is ~$1.94/mo (22.8% of ARPU) — hugs the guardrail with minimal slack; measured range $1.69–$2.08/mo accounts for tool-call rate variance (12%–35% observed band). Slack is in the cap itself, not per-call cost. If usage concentrates toward the heavy tail OR average session length exceeds 15 turns OR tool-call rate trends above 22%, margin tightens. Monitor `ai_cost_usd_per_active_user` during beta; revisit via ADR 0015 trigger query (`prompt_cached_tokens / input_tokens` rolling median ≥ 0.30) if cap hit-rate is low but realized cost drifts.

**Free user AI cost = `0.02450 (6 scans/10) + 0.04680 + 0.01264 (if 8 subs used) + 0.00550 (2 imports) + 0.00149 + $0 (no voice) ≈ $0.075/user/month`.** Voice is the dominant cost line; stripping it makes Free tier net-positive on AI spend. ADR 0008 (Free 20 voice sessions during step-6 development) is Superseded by ADR 0015 — Free reverts to 0 voice sessions in the ADR 0015 release, consolidating with the Premium 20→13 and Pro 40→27 cap changes.

**Pro user AI cost ≈ $3.69/user/month** driven by 27 voice Cook Sessions at ~$0.133 each (per ADR 0015; measured range $3.51–$4.32/mo).

Voice Cook Mode is now **95.3% of a Premium user's AI cost** and **97.5% of a Pro user's AI cost**. This is a feature-concentrated cost profile — runaway voice cost is the single most likely way unit economics break. Operational monitoring of per-user voice session token consumption is therefore critical.

### 12.2 Feature-by-feature audit

#### Pantry scan parse

* **What it does**: turns one kitchen image into a structured ingredient list with confidence bands
* **Model**: Gemini 3 Flash
* **Rationale**: multimodal strength + low cost
* **Latency budget**: p95 < 4.0s from image upload to reviewed chips
* **Inference path**: image + household profile + bundled ingredient ontology excerpt → JSON schema output
* **Streaming**: no; single-shot response
* **Reliability tolerance**: may be incomplete; must not hallucinate hidden ingredients with high confidence
* **Guardrails**:

  * schema validation
  * confidence thresholding
  * ambiguous items routed to user confirmation
  * no allergen claims without user confirmation
* **Prompt/context**: image + short pantry parser prompt + allowed JSON schema
* **Eval set**: `eval_pantry_scan_v1.jsonl` with 150 kitchen photos
* **Success criteria**:

  * top-10 ingredient precision ≥ 0.90
  * recall ≥ 0.75
  * hard-allergen false positive/negative rate < 1%

#### Dinner solve

* **What it does**: produce exactly 3 ranked dinner options
* **Model**: Gemini 3 Flash
* **Latency budget**: p95 < 3.5s
* **Inference path**: pantry snapshot + preferences + time/equipment + recent feedback summary → 3 structured options
* **Streaming**: yes, card-by-card streaming to improve perceived latency
* **Reliability tolerance**: zero hard-rule violations
* **Guardrails**:

  * hard-rule checker post-model
  * discard and retry invalid options
  * never return >3 options
* **Eval set**: `eval_dinner_solve_v1.jsonl` with 200 pantry scenarios
* **Success criteria**:

  * hard-rule pass rate = 100%
  * cookability pass by human eval ≥ 85%
  * selection rate in beta ≥ 60%

#### Voice Cook Mode turn (Premium+ only)

* **What it does**: answer current-step questions and keep the user moving, hands-free
* **Model**: **Gemini 3.1 Flash Live Preview** at `thinkingLevel: minimal`, via stateful WebSocket to the Live API using an ephemeral session token minted by Supabase
* **Fallback**: when Live API is unavailable, transparent fallback to local Speech (STT) → Gemini 3 Flash (text) → AVSpeechSynthesizer (TTS) with `AI-VOICE-01` banner
* **Latency budget**: **p95 < 1.0s time-to-first-audio** (Gemini Live production reports 250–500ms TTFA on US networks); p95 < 2.5s total round-trip for text fallback path
* **Inference path**: streamed user audio + session system prompt (current recipe plan, current step, last 4 turns, timer state, hard dietary rules, allowed function calls) → streamed audio response. Substitutions and timer actions exposed as function calls, not free-form speech.
* **Streaming**: native bidirectional audio; barge-in and turn-taking handled by the Live API
* **Reliability tolerance**: concise, step-grounded, no made-up steps; no model-invented substitutions
* **Guardrails**:

  * system prompt pins the model to the current step and forbids substitutions outside the function-call path
  * food-safety-sensitive questions get a prepended safety cue before the spoken answer
  * substitution function-call outputs run through the same hard-rule validator as the standalone substitution feature before being spoken
  * per-session audio token budget caps at 40K cumulative tokens → forces session refresh; hard cap at 80K → session reset with banner
  * `max_output_tokens: 150` enforced at session config to prevent runaway output audio cost
  * **Tool Call Preamble pattern — [UNVALIDATED ASSUMPTION — week-one spike required before Cook Mode voice build proceeds].** The intent is that the system prompt instructs the model to say a short neutral filler ("Let me check", "One moment") simultaneously with emitting any tool call, masking the ~2s substitution backend round-trip. Unlike OpenAI's gpt-realtime family, Gemini Live is not known to produce preambles spontaneously, and its adherence to a prompt instruction to 'speak X then emit tool call' under MINIMAL reasoning has not been independently benchmarked. The week-one spike must measure preamble-present rate across ≥50 tool-call invocations. **Mandatory mitigation regardless of spike outcome: client-side pre-recorded filler audio.** The iOS client plays one of three pre-recorded neutral filler clips ("Let me check", "One moment", "Give me a second") the instant a `toolCall` frame arrives, independently of any model-emitted preamble. This covers the ~2s backend round-trip deterministically. The prompt-level preamble is best-effort polish on top; if it fires the client filler is skipped or overlapped cleanly. If spike shows model preamble rate <90%, the client-side clip is the primary UX and model preamble is disabled via system prompt to avoid double-speak.
  * Turn detection: start with `semantic_vad` (chunks based on utterance completion) to reduce false-positive tokenization of non-speech kitchen noise; fall back to `server_vad` if semantic VAD proves unreliable in testing
  * Session refresh as pruning (ADR 0014): trigger a new mint + WS swap every 10 turns OR whenever a single turn exceeds 15,000 prompt tokens, carrying a compact recap (~200-300 tokens) in the new session's `systemInstruction` for continuity. Earlier drafts specified `session.update` with audio-item truncation; that frame type doesn't exist on Gemini Live.
* **Eval set**: `eval_cook_turns_v1.jsonl` with 120 scripted dialogues, run against **both** the Live API path and the text fallback path
* **Success criteria**:

  * wrong-step answer rate < 3% on both paths
  * p95 time-to-first-audio < 1.0s on Live API; p95 total latency < 2.5s on fallback
  * user "helpful" thumbs-up ≥ 80%
  * barge-in acknowledged within 300ms on Live API
  * preamble-present rate ≥ 95% on Live API tool-call turns (verifiable from audio transcripts in eval)
  * per-session cumulative token usage stays below 40K in >95% of sessions (validates pruning)

#### Substitution rescue

* **What it does**: propose safe replacements mid-cook
* **Model**: Gemini 3 Flash
* **Invocation**: standalone from the Substitution Sheet (all tiers), or as a function call from inside the active Cook Mode Live API session (Premium+)
* **Latency budget**: p95 < 2.8s
* **Inference path**: missing ingredient + current recipe + hard rules + equipment
* **Streaming**: no; single structured suggestion
* **Reliability tolerance**: zero hard-rule violations
* **Guardrails**:

  * external hard-rule validator (identical on both invocation paths)
  * canned safety copy for allergens, raw meat, eggs, leftovers
  * reject if model cannot preserve recipe integrity
* **Eval set**: `eval_substitutions_v1.jsonl` with 100 cases
* **Success criteria**:

  * hard-rule pass rate = 100%
  * accepted-substitution rate ≥ 50% in beta
  * post-session complaint rate < 5%

#### Recipe import normalize

* **What it does**: normalize OCR text / URL content into title, ingredients, steps
* **Model**: Gemini 3.1 Flash-Lite
* **Latency budget**: synchronous URL imports < 4s; screenshot OCR imports async if >1 page
* **Inference path**: on-device OCR / fetched HTML cleanup → structured recipe schema
* **Streaming**: no
* **Reliability tolerance**: can require edit; must not silently drop steps without flagging
* **Guardrails**:

  * HTML stripped and sanitized
  * imported content treated as untrusted
  * parser flags uncertain servings or merged steps
* **Eval set**: `eval_recipe_import_v1.jsonl` with 100 recipes
* **Success criteria**:

  * 85% parse acceptable without major edit
  * 95% ingredient-line retention
  * 95% step-order preservation

#### Grocery list generation

* **What it does**: generate missing-item list and map to Reminders-friendly structure
* **Model**: Gemini 3.1 Flash-Lite
* **Latency budget**: p95 < 1.5s
* **Inference path**: recipe ingredients - pantry remembered items = draft grocery list
* **Streaming**: no
* **Reliability tolerance**: duplicates allowed temporarily, omissions not
* **Guardrails**:

  * post-model dedupe normalizer
  * no silent export if permission missing
* **Eval set**: `eval_grocery_v1.jsonl` with 100 cases
* **Success criteria**:

  * dedupe accuracy ≥ 95%
  * missing-item recall ≥ 98%

### 12.3 AI Risk & Safety Audit

| Feature                    | Prompt injection defense                                                                               | Retrieval poisoning defense                                      | Cross-user leakage defense                       | Output sanitization                                | Harm classes                                                | Drift detection                                            | Liability-sensitive treatment                    |
| -------------------------- | ------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------- | ------------------------------------------------ | -------------------------------------------------- | ----------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------ |
| Pantry scan parse          | no user text can alter system instructions; image and OCR treated as content only                      | none; no external retrieval                                      | request built only from current user local state | schema validation + confidence threshold           | allergen misclassification, hidden-ingredient hallucination | nightly eval + live low-confidence rate alert              | "Check allergens yourself" when ambiguous        |
| Dinner solve               | imported recipe text never included in solve prompt as authority                                       | none in v1                                                       | no shared memory; CloudKit private DB boundary   | schema + hard-rule validator                       | allergen/diet violations, unrealistic meals                 | canary prompt rollout, rollback if hard-rule violations >0 | explicit warning if spoilage/freshness uncertain |
| Voice Cook Mode turn       | user utterances cannot override system prompt; tool surface limited to substitution + timer function calls | none                                                             | session context scoped to one Cook Session only; Live API session closed when Cook Mode exits | no free-form tool execution; substitution function-call outputs re-validated by hard-rule engine before being spoken | bad food-safety advice, timing errors, model-invented substitutions | helpfulness ↓ or complaint ↑ triggers rollback; Live-to-fallback ratio monitored | prepend safety cue on meat/eggs/leftovers        |
| Substitution rescue        | same as above                                                                                          | none                                                             | same as above                                    | structured output only                             | allergen exposure, recipe breakage                          | zero hard-rule violations accepted                         | user retains judgment; visible safety warning    |
| Recipe import normalize    | imported HTML/OCR sanitized; never allow "ignore previous instructions" content to act as instructions | HTML cleaned, scripts stripped, URL domain allowlist for fetcher | import scoped to current user only               | sanitize text before display                       | malformed steps, copyright attribution omission             | parse-failure alerting by source type                      | imported recipes always editable before use      |

**Provider training-data policy:** Google Gemini paid API — content is not used to improve products. ([Google AI for Developers][5])

### 12.4 Global AI safety rules

* Never present hidden chain-of-thought.
* Never claim certainty on spoilage, allergens, or doneness.
* Reject outputs that violate hard dietary rules.
* Do not store raw prompts/responses for training.
* No tool execution from model output without typed validation.
* No RAG over other users' content.
* No vector DB in v1.

## 13. Production Readiness

### Error handling

* central `AppError` enum in iOS app
* `ErrorPresenter` maps typed errors to error copy codes from §6
* retry policy:

  * network 5xx / timeouts: exponential backoff 0.5s, 1.5s, 3s
  * schema failures: one automatic retry on same model, then escalate
  * client errors 4xx: no retry
  * Live API connect failure or mid-session drop: one immediate attempt (re-mint ephemeral token + reconnect), then fall back to the text Cook Mode path with `AI-VOICE-01` banner
  * Live API ephemeral token mint failure: single retry with exponential backoff, then fall back
  * Gemini API complete outage (all models): surface `AI-01`, user can use saved meals, cached plans, local timers, manual Substitution Sheet becomes inert
* persistent offline queue only for:

  * feedback submission
  * analytics
  * grocery export metadata
* never queue AI content generation blindly when app backgrounded unless user explicitly initiated an async import

### Observability

**Dashboards**

* onboarding funnel
* solve funnel
* cook completion
* subscription funnel
* AI cost by feature
* Gemini service health
* sync health

**Metrics**

* `solve_success_rate`
* `solve_to_selection_rate`
* `selection_to_cook_start_rate`
* `cook_completion_rate`
* `voice_cook_start_rate` (Premium+)
* `voice_paywall_conversion_rate` (Free tap → paywall → trial start)
* `mean_rating`
* `ai_cost_usd_per_active_user` segmented by tier (Free / Premium / Pro)
* `voice_session_tokens_p95` (catches runaway sessions before cost spikes)
* `cook_voice_live_share` (share of voice cook turns served by Live API vs text fallback)
* `cook_voice_ttfa_p95_ms`
* `preamble_present_rate` (share of tool calls preceded by filler audio)
* `cloudkit_sync_error_rate`
* `purchase_conversion_rate`, `trial_to_paid_rate`

**Alerts**

* any AI request failure rate > 5% over 15 min
* Live API fallback share > 10% over 30 min (indicates Live API degradation)
* Live API p95 time-to-first-audio > 1.5s over 30 min
* dinner solve hard-rule violation > 0 in canary
* AI cost / Premium user > $3.00 daily (roughly 2x expected)
* AI cost / Pro user > $8.00 daily
* voice_session_tokens_p95 > 50K (pruning is failing)
* preamble_present_rate < 90% (Gemini not following tool-call preamble instruction)
* CloudKit sync error rate > 3%
* crash-free sessions < 99.2%
* payment confirmation lag > 10 min p95
* trial-to-paid conversion rate falls below 25% of 7-day rolling baseline

### Security (web2)

* Supabase Edge Function secrets store provider keys (**single Gemini API key**, RevenueCat webhook secret, APNs auth key). **No provider API keys ever in the app bundle.** Cook Mode voice uses the ephemeral-token pattern: the client receives a short-lived session token from `/v1/ai/realtime-session` scoped to one Live API session, and connects directly to Gemini Live with that token. The main Gemini API key stays in Supabase and is never exposed to the client.
* HTTPS only
* signed session JWT from backend; short TTL
* request size caps:

  * images 5 MB compressed max
  * OCR text 50 KB max
* URL fetch allowlist and content-type validation for recipe imports
* rate limiting by IP + canonical user key + endpoint, enforced in Edge Functions and backed by Postgres counters. Per-user voice Cook Session quota enforced at token-mint time — `/v1/ai/realtime-session` refuses to mint a new ephemeral token if the user has no voice entitlement or has exceeded their monthly cap. **Apple ID rotation defense:** IP-based layer caps daily Dinner Solve count at 30 across all canonical user keys originating from the same IP — targets the sign-out-of-iCloud-to-reset-quota abuse vector without penalizing legitimate household-shared IPs (daily 30 is well above any real household usage).  
* webhook signature verification for RevenueCat
* APNs auth key stored only server-side
* all local sensitive identifiers in Keychain, not `UserDefaults`

### Security (AI)

See §12.3. In addition:

* strip HTML, markdown links, hidden text, and suspicious control sequences from imported recipes
* cap model outputs by schema and token budget (`max_output_tokens: 150` on Live sessions)
* never render model output as rich HTML
* redact user free-text in logs unless user opted into diagnostics

### Deployment

**Environments**

* `dev` — local Supabase CLI (`supabase start`) + dev CloudKit env
* `staging` — Supabase staging project + dev CloudKit env
* `prod` — Supabase prod project + prod CloudKit env

**App identifiers**

* `com.company.stir.dev`
* `com.company.stir.beta`
* `com.company.stir`

**CloudKit**

* separate dev/prod CloudKit environments as Apple provides
* schema explicitly promoted before production rollout

**CI/CD**

* GitHub Actions:

  * lint + unit tests on PR
  * integration tests on merge
  * `supabase db push` (migrations) + `supabase functions deploy` to staging on merge to `main`; promote to prod on tag
  * TestFlight upload on tag via fastlane
* phased App Store release:

  * 10%
  * 50%
  * 100%

### Feature flags + experimentation

**Client flags via PostHog**

* `paywall_variant`
* `widget_nudge_enabled`
* `leftovers_mode_enabled`
* `cook_voice_default_on` (Premium+ only; whether voice mic affordance is default-active vs default-off)
* `voice_turn_detection_mode` (values: `semantic_vad` | `server_vad`)

**Server flags via backend**

* `prompt_version_override`
* `recipe_import_async_threshold`
* `priority_queue_pro_enabled`
* `cook_voice_thinking_level` (values: `minimal` | `low`; MINIMAL is default, LOW is escalation path if reasoning proves insufficient)

**Kill switches**

* `disable_scan_parse`
* `disable_cook_realtime` (disables Live API mint; all Premium+ voice traffic falls back to Gemini text + AVSpeechSynthesizer with `AI-VOICE-01` banner)
* `disable_imports`
* `force_saved_meals_only`

### Degraded mode

| Failure                   | Fallback                                                 |
| ------------------------- | -------------------------------------------------------- |
| Gemini Live API unavailable (token mint fails, WebSocket connect fails, or mid-session drop with failed reconnect) | Cook Mode voice falls back to local Speech → Gemini 3 Flash text → AVSpeechSynthesizer, with `AI-VOICE-01` banner. **Pre-warm at Cook Mode entry:** initialize `SFSpeechRecognizer` and load the selected AVSpeechSynthesizer voice into memory even while the Live path is working, so fallback can engage in <200ms if Live drops mid-session. Expected fallback TTFA p95: 1.5–2.5s (Speech STT ~500ms + Gemini Flash text ~800ms + AVSpeechSynthesizer start ~200ms + network variance). No barge-in on fallback path; turn-taking is tap-to-speak. This UX gap is material — Premium is sold on hands-free cooking, so fallback is treated as a first-class product path, not a last-resort degraded mode. |
| Gemini API fully unavailable | No fresh AI generation. Saved meals, cached plans, manual edit paths, local timers, local grocery list, Reminders export all continue to work. Substitution Sheet becomes inert with friendly copy. |
| CloudKit unavailable      | local-only mode                                          |
| RevenueCat unavailable    | use cached entitlements for 24h grace                    |
| Reminders unavailable     | in-app grocery list + copy/share                         |
| Speech framework unavailable and Live API unavailable | tap-only Cook Mode     |

### Model / prompt rollback

* every prompt version pinned by semantic version
* new prompt versions run on offline eval set before staging
* canary rollout starts at 5%
* automatic rollback if:

  * hard-rule violation > 0
  * fallback rate doubles
  * user thumbs-down rate > 15% above baseline
  * p95 latency > SLO for 30 min
  * voice_session_tokens_p95 spikes >30% above baseline (pruning regression)

## 14. Admin & Ops Tooling

### Ops stack

* **PostHog** for product dashboards and feature flags
* **RevenueCat dashboard** for billing state and entitlement debugging
* **Sentry** for crashes and backend errors
* **Internal `/ops` web console** served from Supabase (Edge Functions + a small admin SPA), gated to the admin role via Supabase Auth + RLS on ops-only tables

### Required ops surfaces

| Tool               | Capability                                                                                                 |
| ------------------ | ---------------------------------------------------------------------------------------------------------- |
| AI review queue    | list flagged outputs, request metadata, current prompt version, resolution state                           |
| Manual AI override | mark a request invalid, withdraw a suggestion, or pin a safe canned fallback for a specific recipe/session |
| User management    | ban / unban by canonical user key, reset quotas, force local reauth                                        |
| Cost anomaly view  | top users by AI cost, top features by spend, runaway voice sessions by cumulative token count              |
| Voice session inspector | per-user cumulative voice token consumption, session count, average session length — catches outlier users |
| Feature flag panel | toggle client and server flags                                                                             |
| Prompt control     | set default prompt version, canary %, rollback                                                             |
| Audit log          | immutable record of ops actions                                                                            |

### Minimal `/ops` console pages

1. Dashboard
2. AI Requests
3. Voice Sessions (cost/runaway monitoring)
4. Flagged Outputs
5. Entitlements & Usage
6. Feature Flags
7. Prompt Versions
8. Audit Log

### `cost_anomalies.details_json` shape per `anomaly_type`

SCA-315 S10: `cost_anomalies.details_json` is a `jsonb` column that varies in shape by `anomaly_type`. Pinning the shape here so future ops dashboards / Sentry breadcrumbs / Slack-alert formatters don't drift across detector revisions. The detector is `stir_ops_cost_anomaly_scan()` (`20260509144834_cost_anomaly_scan_session_id_rewrite.sql`); the dispatch path is `stir_ops_cost_anomaly_dispatch()` (`20260424000007_cost_anomaly_dispatch_canonical_tags.sql`).

| `anomaly_type`                  | `severity`        | `details_json` shape                                                                                                                                                              |
| ------------------------------- | ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `daily_spend_hard_cap`          | `critical`        | `{ "tier": "free"\|"premium"\|"pro", "spend_24h_usd": numeric, "call_count": int }` — fires when any tier exceeds $10/24h hard cap                                                |
| `daily_spend_2x`                | `warn`            | Same shape as `daily_spend_hard_cap` — fires when Premium > $3 OR Pro > $8 in 24h (2× expected envelope)                                                                          |
| `voice_session_tokens_over_cap` | `critical`        | `{ "session_id": text, "total_tokens": int, "turn_count": int, "started_at": timestamptz, "last_turn_at": timestamptz }` — single voice session crossed 50K cumulative tokens     |
| `runaway_session`               | `critical`        | `{ "session_id": text, "turn_count": int, "duration_ms": numeric, "started_at": timestamptz, "last_turn_at": timestamptz, "total_tokens": int }` — single voice session ran > 10min AND > 20 turns |

The dispatch path wraps the row in a Sentry-shaped envelope with `event_id = cost_anomalies.id`, `tags = { anomaly_type, severity }`, and `extra = details_json` verbatim. Dashboards that consume `extra.*` keys MUST handle the per-`anomaly_type` shape divergence — there is no shared subset across all four types beyond severity classification.

## 15. Telemetry Spec

**Anchor metric**
`core_success_event`: user scans ingredients, selects one of the top three AI-generated dinner options, enters Cook Mode within three minutes, and finishes the meal with a rating of at least 4/5.

**Premium-conversion anchor metric**
`voice_conversion_event`: Free user taps voice affordance → sees paywall → starts 7-day trial → converts to paid Premium.

### Event table

| Event name                         | Properties                                                                                     | Purpose                    | Dashboard               |
| ---------------------------------- | ---------------------------------------------------------------------------------------------- | -------------------------- | ----------------------- |
| `app_opened`                       | app_version, build, cold_start, canonical_user_key_hash                                        | DAU/WAU base               | Acquisition & Retention |
| `onboarding_started`               | entry_source                                                                                   | onboarding funnel          | Onboarding              |
| `onboarding_completed`             | duration_sec, skipped_steps                                                                    | onboarding completion      | Onboarding              |
| `camera_permission_result`         | status, context                                                                                | permission funnel          | Onboarding              |
| `scan_started`                     | source=live/sample, flash_mode                                                                 | core funnel start          | Core Loop               |
| `scan_submitted`                   | image_count, source                                                                            | usage volume               | Core Loop               |
| `scan_parse_completed`             | parsed_count, low_confidence_count, latency_ms, image_count                                    | scan quality               | Core Loop               |
| `ingredient_corrected`             | action=add/remove/rename, count                                                                | flywheel capture           | Flywheel                |
| `constraints_set`                  | time_bucket, goal, use_first_flag                                                              | solve context              | Core Loop               |
| `dinner_solve_requested`           | pantry_count, constraint_count, feedback_summary_present, recent_meal_count                    | solve attempt count        | Core Loop               |
| `dinner_solve_completed`           | latency_ms, model, result_count                                                                | solve health               | AI Ops                  |
| `suggested_dish_selected`          | rank, label_primary, missing_count                                                             | selection funnel           | Core Loop               |
| `cook_mode_started`                | within_3min, source=solve/import/saved, voice_enabled                                          | core success funnel        | Core Loop               |
| `cook_step_advanced`               | step_index, manual_or_voice                                                                    | usage depth                | Cook Mode               |
| `timer_started`                    | duration_bucket, generated_vs_manual (generated/manual/voice)                                    | timer adoption             | Cook Mode               |
| `voice_affordance_tapped`          | tier (free/premium/pro), result (paywall_shown/voice_started/permission_denied/busy/voice_stopped) | conversion funnel          | Paywall + Cook Mode     |
| `cook_turn_submitted`              | turn_type, current_step_index, path=live_api/gemini_fallback                                    | voice Q&A usage            | AI Ops                  |
| `cook_turn_resolved`               | latency_ttfa_ms, latency_total_ms, barge_in, path, result_type (normal/tool_call/error), error_code? | Cook Mode quality          | AI Ops                  |
| `voice_session_token_snapshot`     | session_id, turns_so_far, cumulative_tokens, current_step_index                                | runaway cost detection     | AI Ops                  |
| `voice_session_refreshed`          | session_id, refresh_reason (turns/tokens/goaway/transport_error; minutes reserved), turns_at_refresh, success | refresh cadence + refresh success rate | AI Ops                  |
| `voice_quota_refund`               | request_id, reason ∈ {no_active_prompt, mint_failed, mint_unexpected_error}, upstream_status? | refund-audit observability (SCA-145) — disambiguates the increment-then-refund path on the placeholder-key CI path from never-incremented. NOTE: `request_id` is a request-scoped log correlator only — refund branches return BEFORE `logAIRequest()`, so no `ai_request_log` row joins. Find refunded requests via PostHog Insight on this event. | AI Ops                  |
| `substitution_requested`           | problem_type, invocation=sheet/realtime_function_call, sub_event_id                            | rescue usage               | Cook Mode               |
| `substitution_accepted`            | accepted, constraint_safe, invocation=sheet/realtime_function_call, sub_event_id, reason (user_accepted/user_rejected/unsafe_acknowledged/auto_applied/unsafe_refused) | rescue quality             | Flywheel / AI Ops       |
| `voice_substitution_disambiguated` | session_id, candidate_count, surface (voice/tap), resolved_to (free_text_fallback) | matchIngredient ambiguity rate (SCA-148)   | Cook Mode               |
| `cook_session_completed`           | duration_min, steps_completed, voice_enabled                                                   | completion funnel          | Core Loop               |
| `meal_rated`                       | rating, workload, taste, would_repeat, leftovers_handoff_offered, leftovers_handoff_taken, leftovers_eligible_free | core success completion    | Core Loop               |
| `meal_rating_skipped`              | recipe_plan_id                                                                                 | opt-out rate on rating sheet (complement to meal_rated; typically one of the pair follows every cook_session_completed — force-quit / crash / background-kill between sheet open and dismissal yield zero emissions, so dashboards should treat "neither fired" as a valid third state rather than a data bug) | Core Loop               |
| `grocery_list_exported`            | item_count, destination=reminders/in_app                                                       | write-back success         | Utility                 |
| `favorite_saved`                   | recipe_origin, source ∈ {tonight, post_meal_feedback, saved_replay}                            | retention asset            | Retention               |
| `recipe_import_started`            | source_type                                                                                    | import funnel              | Import                  |
| `recipe_import_completed`          | source_type, parse_quality, edit_required                                                      | import quality             | Import                  |
| `paywall_viewed`                   | trigger, variant, current_tier                                                                 | paywall funnel             | Billing                 |
| `trial_started`                    | sku, trigger                                                                                   | monetization funnel        | Billing                 |
| `purchase_started`                 | sku, origin                                                                                    | checkout funnel            | Billing                 |
| `leftovers_followup_scheduled`     | fire_at                                                                                        | leftovers retention loop   | Engagement              |
| `leftovers_followup_fired`         | (none)                                                                                         | leftovers retention loop   | Engagement              |
| `leftovers_followup_tapped`        | (none)                                                                                         | leftovers retention loop   | Engagement              |
| `leftovers_followup_suppressed`    | reason ∈ {weekly_cap, unactioned_streak}                                                       | leftovers retention loop   | Engagement              |
| `use_soon_scheduled`               | fire_at                                                                                        | use-soon retention loop    | Engagement              |
| `use_soon_fired`                   | (none)                                                                                         | use-soon retention loop    | Engagement              |
| `use_soon_tapped`                  | (none)                                                                                         | use-soon retention loop    | Engagement              |
| `use_soon_suppressed`              | reason ∈ {weekly_cap, unactioned_streak, recent_session, no_candidate, no_displayable_candidate} | use-soon retention loop    | Engagement              |
| `notification_schedule_rollback_failed` | scheduler_id, identifier, error_description                                              | scheduler reliability (SCA-309) | Reliability             |
| `repeat_candidate_card_shown`      | recipe_plan_id, tier                                                                           | save-prompt funnel         | Engagement              |
| `repeat_candidate_card_dismissed`  | recipe_plan_id, outcome ∈ {paywall_routed, deferred, suppressed}                               | save-prompt funnel         | Engagement              |
| `sample_showcase_viewed`           | dish_count                                                                                     | onboarding sample funnel   | Onboarding              |
| `sample_showcase_exited`           | outcome ∈ {continued_to_onboarding, back_to_welcome}                                           | onboarding sample funnel   | Onboarding              |
| `widget_nudge_shown`               | (none)                                                                                         | widget adoption funnel     | Engagement              |
| `widget_nudge_dismissed`           | outcome ∈ {acted, deferred, suppressed}                                                        | widget adoption funnel     | Engagement              |
| `app_users_bootstrapped`           | has_cloudkit_record, tier                                                                      | identity funnel            | Identity                |
| `app_users_merged`                 | tier                                                                                           | identity funnel            | Identity                |
| `deletion_request_submitted`       | request_id, actor_id ∈ {user, admin}, deletion_request_id                                      | privacy / CCPA SLA funnel  | Privacy / Compliance    |
| `entitlement_state_changed`        | from_state, to_state, billing_state, source ∈ {ios_foreground, server_webhook}, [event_type, tier, is_trial] | churn / recovery           | Billing                 |
| `ops_admin.flagged_outputs.created` | feature_key, flagged_output_id, had_cached_output                                             | ops flag-rate              | Ops                     |
| `purchase_completed`               | sku, price, trial, intro_offer                                                                 | revenue funnel             | Billing                 |
| `restore_purchases_tapped`         | origin                                                                                         | support funnel             | Billing                 |
<!-- entitlement_state_changed extended with `source` per SCA-62 — see row above with full property set -->
| `reactivation_notification_opened` | trigger_kind                                                                                   | reactivation effectiveness | Retention               |
| `widget_added`                     | source                                                                                         | entry-point adoption       | Retention               |
| `shortcut_run`                     | intent_name                                                                                    | entry-point adoption       | Retention               |
| `ai_request_completed`             | feature_key, model, input_tokens, output_tokens, cost_usd, latency_ms, thinking_level          | cost and reliability       | AI Ops                  |
| `ai_request_failed`                | feature_key, error_type                                                                        | error rate                 | Reliability             |
| `screen_error_shown`               | screen_name, error_code                                                                        | UX reliability             | Reliability             |
| `sync_state_changed`               | state, device_count                                                                            | CloudKit health            | Reliability             |
| `tutorial_started`                 | tutorial_id                                                                                    | first-run feature-tour funnel | Onboarding           |
| `tutorial_step_advanced`           | tutorial_id, from_step, to_step                                                                | step-by-step drop-off       | Onboarding              |
| `tutorial_completed`               | tutorial_id                                                                                    | tour completion             | Onboarding              |
| `tutorial_skipped`                 | tutorial_id                                                                                    | tour abandonment            | Onboarding              |
| `pantry_auto_consume_resolved`     | ephemeral_deleted, remembered_bumped, unmatched, optional_skipped, substituted_count            | pantry-as-state-model fidelity (ADR 0029)  | Core Loop               |
| `pantry_tombstone_reaper_ran`      | rows_purged, retention_days                                                                     | CloudKit zone hygiene cadence coverage (SCA-97) | Reliability        |
| `pantry_tier_downgrade_reconciled` | previous_tier, new_tier, previous_effective_tier, new_effective_tier, archived_count, total_remembered_pre, total_remembered_post | tier-downgrade reconciliation visibility (SCA-99 / ADR 0035; effective-tier pair added SCA-298) | Reliability             |
| `leftovers_dish_selected`          | rank, leftovers_items_count, prompt_version, source_recipe_plan_id, new_recipe_plan_id, persist_ms | leftovers handoff conversion (SCA-55), persist-latency dashboard (SCA-106) | Core Loop               |

**Event property clarifications:**

- **`paywall_viewed.trigger`** — discrete string identifying the surface that produced the paywall presentation. Stable wire values; renaming any breaks an existing PostHog dashboard. Current values: `dinner_solve_quota_exhausted`, `pantry_cap_reached` (user hit their tier's remembered-pantry cap on Pantry Management — Free 25 / Premium 250 / Pro 1000), `recipe_import_quota_exhausted`, `saved_favorites_gate`, `widgets_gate`, `leftovers_gate`, `multi_image_scan_gate`, `settings_upgrade` (Free user tapping Settings > Plan & Billing > Upgrade to Premium → full PaywallView), `settings_pro_comparison` (Settings > Plan & Billing → Pro-comparison sheet directly, used by both Free "See Pro features" and Premium "Upgrade to Pro" entry points; `current_tier` discriminates the two), `voice_affordance_tapped`, `voice_cook_quota_exhausted`. `settings_upgrade` and `settings_pro_comparison` are intentionally distinct so the Premium-trial funnel (PaywallView path) and the Pro-comparison funnel don't conflate — comparison-sheet impressions don't lead to a Premium trial, only to Pro purchase or dismiss. Mirrored 1:1 with `PaywallTrigger.telemetryValue` (iOS); adding a new value requires updating `PaywallTrigger.swift`, this list, and the CLAUDE.md telemetry list in the same commit.
- **`cook_turn_resolved.result_type`** — every terminal turn path emits `cook_turn_resolved`, including errors and interruptions. Values: `normal` (successful reply), `tool_call` (successful reply that executed a model-suggested action — advance step, start timer), `error` (endTurn threw — emptyTranscript, network, AI-VOICE-01, rate limit, any StirError). Error emissions carry `error_code` (the Stir ErrorCode raw value) and `latency_ttfa_ms = 0` since TTFA couldn't be clocked. Submitted:resolved ratio must stay ~1:1 — a drift below 90% indicates silent error swallowing, not real turn failure.
- **`cook_turn_resolved.latency_ttfa_ms`** — Live path: driver-level, from server's `inputTranscription.finished=true` to first `modelTurn.parts[].inlineData` audio chunk (frame-level precision). Fallback path: Speech-to-Text wall-clock latency. Zero on error paths where neither anchor was reached.
- **`cook_turn_resolved.barge_in`** — `true` when the user tapped the mic during the prior turn's `modelSpeaking` state to start THIS turn. Semantics: "this turn began by interrupting the previous turn's playback", not "this turn was interrupted" (the resolved event fires at turnComplete, before playback finishes, so we can't retroactively flag an in-flight turn). Flag is reset after emission. `helpful_vote` was previously scaffolded-but-unwired; removed from the emission pending a thumbs-up/down UI.
- **`voice_session_refreshed.refresh_reason`** — shipped values: `turns` (crossed `refreshAtTurnCount = 4` boundary per ADR 0014), `tokens` (hit `refreshAtPromptTokenCount` soft cap on a single turn), `goaway` (server emitted a goAway frame), `transport_error` (WebSocket errored mid-session; refresh as recovery). Reserved for future: `minutes` (crossed `refreshAtElapsedSec` — not yet wired).
- **`voice_session_refreshed.success`** — boolean. Fires on BOTH success and failure paths of `refreshSession()` (not just on request, as pre-2026-04-22 drafts). `success=true` → the swap committed, new session is live; `success=false` → any step threw (mint / WS open / setup handshake / post-swap cleanup). Dashboards compute refresh success rate = `count(success=true) / count(*)`. Failure emission makes the "Voice session health" tile bidirectional — prior one-sided design left refresh failures telemetry-invisible.
- **`substitution_requested.sub_event_id`** / **`substitution_accepted.sub_event_id`** + **`substitution_accepted.invocation`** — the rescue-usage funnel joins requested → accepted pairs on `sub_event_id`. Both events MUST fire for every substitution attempt on both the sheet and voice paths — no half-depth asymmetry. The voice path has no user confirm step, so safe results auto-emit `substitution_accepted` with `accepted=true, constraint_safe=true, reason=auto_applied`, and unsafe results auto-emit `accepted=false, constraint_safe=false, reason=unsafe_refused`. Sheet `reason` values are `user_accepted` / `user_rejected` / `unsafe_acknowledged`. Dashboards slice voice vs sheet on `invocation` and accept-rate via `reason`.
- **`voice_substitution_disambiguated`** — pinned by SCA-148 (CookModeViewModel.matchIngredient longest-match preference follow-up). Fires when the voice-side matcher detects ≥2 substring candidates whose displayName length ties at the longest length (e.g. "ric" against a recipe with both "rice" and "rind"). The CA1-H2 longest-match preference can disambiguate "rice" vs "white rice" / "rice noodles" (10 vs 12 chars) but collapses on equal-length matches. Properties: `session_id` (UUID string of the cooking-session, "unknown" placeholder when nil pre-persist — matches `leftovers_dish_selected.source_recipe_plan_id` convention), `candidate_count` (≥2, the number of equally-long winners), `surface` ∈ closed enum `{voice, tap}` mirroring `VoiceSessionTelemetry.SubstitutionDisambiguationSurface` (voice is the only emit site today; tap reserved for if the SubstitutionSheet auto-apply branch ever picks up matchIngredient logic), `resolved_to` ∈ closed enum `{free_text_fallback}` mirroring `VoiceSessionTelemetry.SubstitutionDisambiguationResolution`. v1 emits ONLY `free_text_fallback` — ambiguous voice matches route to the free-text persistence path (no recipe row mutation; the model's narration carries the user-facing swap). SCA-199 (/review-2 S1) trimmed three speculative resolution values (`user_picked_first`/`user_picked_second`/`timed_out`) that were declared in advance of the Phase 2 mid-turn-prompt UX; re-add cases when the prompt-UX commit actually lands rather than locking the wire vocabulary today. Adding a new `surface` or `resolved_to` value is a wire-contract change — update `VoiceSessionTelemetry.swift` enum + this clarification + CLAUDE.md telemetry list in the same commit. Dashboard signal: 7-day rolling rate of `voice_substitution_disambiguated / substitution_requested(invocation=realtime_function_call) ≥ 1%` justifies the prompt-UX build-out per the SCA-148 ticket trigger.
- **`pantry_tombstone_reaper_ran`** — pinned by SCA-97. Fires from `PantryTombstoneReaper.runIfDue(...)` after every successful pass through `PantryItemRepository.purgeTombstones(olderThan:for:)` — the reaper is foreground-triggered (alongside the existing `softDeleteExpired` sweep in `RootView`'s scenePhase `.active` branch), once-per-day-cadence-throttled via a UserDefaults timestamp (`com.scalinity.stir.pantry.tombstoneReaper.lastRunAt`), and bounded by a 90-day retention window. **Emitted on every successful run, including zero-row passes** — the dashboard signal is "reaper ran today" not "reaper found something today", so missing emissions reliably indicate a wiring regression (foreground hook detached, repo throwing every call). Properties are counts only — never ingredient names — to satisfy ADR 0009's privacy invariant. Failed runs (Core Data fault during fetch/save) emit nothing AND don't move the cadence timestamp, so the next foreground retries instead of waiting a full day. `rows_purged` is the integer count of soft-deleted PantryItem rows whose `deletedAt < (now - retention)` was hard-deleted on this run; `retention_days` is the configured retention window in whole days (default 90, configurable via the reaper's init for tests / future tier scaling). Throttle-skipped foregrounds are silent. Dashboard signal: a sudden drop in distinct-user emission rate signals the foreground hook is detached; a sudden spike in `rows_purged` p95 signals a soft-delete burst (e.g. bulk-pantry-clear via `softDeleteAll`) is now aging into the retention window. CCPA scope is satisfied independently by the account-delete path (SCA-61 / SCA-88); this reaper is purely a CloudKit-zone-size hygiene loop.
- **`pantry_tier_downgrade_reconciled`** — pinned by SCA-99 / ADR 0035. Fires from `EntitlementService.publishReconciliationOutcome` after `PantryItemRepository.reconcileForTierChange(newCap:on:)` resolves on every detected effective-tier downgrade hydrate (`Premium/Pro → Free`, `Pro → Premium`). Emitted **unconditionally on every detected downgrade** — including zero-archive passes when `total_remembered_pre <= newCap` already (user was already below the post-downgrade cap) — so the dashboard signal is "downgrade reached reconciliation" not "downgrade archived something". A missing emission on a confirmed billing-state delta indicates the `applyTierChange` hook is detached from `hydrate`. `previous_tier` and `new_tier` are the LITERAL RevenueCat `Tier.rawValue` discriminants (`free|premium|pro`) — the unmodified tier on the prior and incoming entitlement bodies. `previous_effective_tier` and `new_effective_tier` (added SCA-298) are the post-billing-state-demotion tiers from `EntitlementService.effectiveTier`: a `(tier=.premium, billingState=.expired)` snapshot reports `effective=free`, matching the server-side `effectiveTier(entitlement)` resolution. The effective pair is the source of truth for the downgrade-cohort funnels — a Premium trial-expiry hydrate emits literal `previous_tier=premium, new_tier=premium` (RC keeps the tier across the expiry transition) but effective `premium → free`, and a dashboard filter that splits the cohort on the literal pair would drop it. `archived_count` is the count of `.remembered` rows soft-archived to `.ephemeral` this pass; rows are selected oldest-first by `lastSeenAt asc, createdAt asc` and stamped with `expiresAt` per the standard ephemeral formula so they enter the next morning's foreground sweep. `total_remembered_pre` and `total_remembered_post` are the `.remembered, deletedAt == nil` row counts before and after — when `archived_count > 0` they satisfy `total_remembered_post = min(total_remembered_pre, newCap)`; when `archived_count == 0` they are equal. The non-blocking banner on `PantryListView` only surfaces when `archived_count > 0` (zero-archive passes don't pop a banner saying "your 0 oldest items are now temporary"). SCA-298 W21 also gated emission on `ReconcileOutcome.handlerRan == true`: the `RootCoordinator` tier-downgrade closure's coordinator-deallocated and no-resolved-household short-circuit paths now return `handlerRan=false`, and `publishReconciliationOutcome` suppresses telemetry on that signal so the dashboard's "downgrade reached reconciliation" semantics don't conflate "handler executed but no rows archived" with "handler never ran because no household was wired in". Counts only — no item names — per ADR 0009's privacy invariant. Dashboard signal: rising `archived_count` p95 across the `previous_effective_tier=premium, new_effective_tier=free` trial-expiry cohort sizes the reconciliation cost; tracking that cohort against the trial-cohort denominator gives the "what fraction of trial expirers had a real over-cap pantry" metric called out as a re-upgrade-restoration trigger in ADR 0035.
- **`pantry_auto_consume_resolved`** — fired once per `cook_session_completed`, after `PantryItemRepository.consumeForRecipe` runs. Per ADR 0029, the consume rule is memory-state-aware: matched-and-`.ephemeral` rows soft-delete, matched-and-`.remembered` rows bump `lastSeenAt`, `.expired`/`.unknown` and unmatched are no-ops. Properties are counts only — never ingredient names — to satisfy ADR 0009's privacy invariant. `unmatched` is the catch-all bucket: ingredient with no pantry-row match, including blank/malformed names and repository fetch failures (so `(ephemeral_deleted + remembered_bumped + unmatched + optional_skipped)` always sums to the ingredients walked). `substituted_count` is informational and NOT deducted from `ephemeral_deleted` / `remembered_bumped` — it counts effective ingredients whose source was an accepted `SubstitutionEvent` rather than the original recipe row. Dashboard signal: if `unmatched / (ephemeral_deleted + remembered_bumped + unmatched) > 0.5` over a 14-day window aggregated across all users at the event-level, the matcher in `fetchExisting` needs hardening — escalation trigger + query sketch in ADR 0029 §"Trigger to revisit". The event fires unconditionally (even when all five counts are zero) so dashboard time-series stays continuous and a missing emission flags a wiring regression.
- **`dinner_solve_requested.feedback_summary_present` / `dinner_solve_requested.recent_meal_count`** — pinned by ADR 0030 (preference-memory loop). `feedback_summary_present` is true iff iOS attached a non-nil `feedback_summary` to the request body, which happens only when the user has at least one rated `OutcomeFeedback` row inside the tier window (Free 30d / Premium 90d / Pro 365d — CLAUDE.md §Tier-entitlements). `recent_meal_count` is the un-capped count of rated meals in that window (the `recent_meals` array on the wire is capped at 10; this property carries the total). The two together let funnels split conversion by whether the loop had data to feed in — rising upgrade conversion correlated with `feedback_summary_present=true` is the strongest signal that the tier-window cliff is doing real work. A sudden drop in `feedback_summary_present` rate without a corresponding drop in OutcomeFeedback writes signals a CoreData / windowing regression in `PreferenceMemoryService.buildDigest`. Server kill-switch (`preference_memory_enabled`) does NOT change these properties — they reflect what iOS sent, not what the prompt rendered, so a flag flip surfaces in the prompt-version dashboards instead.
- **`scan_started.flash_mode`** — pinned by SCA-47 (user-selectable flash toggle on the scan camera). Discrete string ∈ `{"off", "on", "auto"}`, 1:1 with `ScanFlashMode.rawValue` on iOS. Carries the user's selected flash policy at shutter time, sourced from `@AppStorage("com.scalinity.stir.scan.flashMode")` on the device (per-installation, not synced). Default `"off"` preserves the SCA-39 instant-shutter floor; `"on"` and `"auto"` are user-opt-in for dark pantries and pay the metering pre-flash latency penalty documented in SCA-39's commit message. The dashboard signal SCA-47 was filed against: if the 7-day rolling rate of `ai_request_failed{code="AI-02", feature="pantry_parse"}` climbs more than ~3pp above the pre-SCA-39 baseline AND `flash_mode="off"` dominates the regressed cohort, the dark-pantry concern that motivated the toggle has materialized — escalate by surfacing flash-on prompts or auto-suggesting `.auto` on low-light captures. Renaming any value is a wire-contract change — update `ScanFlashMode.swift` raw values, `ScanFlashModeTests.swift::test_rawValue_matchesTelemetryContract`, the CLAUDE.md telemetry list, and this bullet in the same commit.
- **`meal_rated.leftovers_handoff_offered` / `meal_rated.leftovers_handoff_taken` / `meal_rated.leftovers_eligible_free`** — pinned by SCA-55 (Leftovers entry-point wiring). `_offered` is true iff the user logged `leftover_count > 0` AND the OutcomeFeedback gate routed them either into LeftoversRoot (Premium+) or to the leftovers-gate paywall (Free); false otherwise. `_taken` is reserved for the Premium+ branch — true iff the gate produced `.openLeftovers`. The Free→paywall path's downstream conversion is measured via `paywall_viewed.trigger=leftovers_gate` → `purchase_completed`, NOT via `_taken`. `_eligible_free` is the conversion-opportunity sizer: true iff `leftover_count > 0 AND tier == .free`. Together they let the funnel split outcomes by tier without needing per-event joins. Skip path (`meal_rating_skipped`) does NOT carry these properties — skip always routes to `.dismiss` regardless of any unsaved leftoverCount stepper value, so the gate decision didn't run.
- **`leftovers_dish_selected`** — pinned by SCA-55. Fires when a Premium+ user picks a dish from `LeftoversRoot` and `SolveRepository.createLeftoversSolveWithDish` persists it as a new RecipePlan. `rank` is 1..3 (matches the dish's position in the leftovers solve result). `leftovers_items_count` is the number of selected items the leftovers solve was built from (per `LeftoversSessionViewModel.selectedItems.count`). `prompt_version` reflects the backend-emitted version on the leftovers solve's `done` event (or `"unknown"` if the stream failed mid-solve). `source_recipe_plan_id` joins back to the meal that produced the leftovers (the `OutcomeFeedback` session's `recipePlan`); `new_recipe_plan_id` is the persisted leftover plan that becomes the next `latestTonightPick` per the LeftoversSolveView helper text "adds it to tomorrow's Tonight." `persist_ms` (SCA-106) is the background-NSManagedObjectContext save latency for the leftovers solve persist (RecipePlan + N RecipeIngredient + M RecipeStep + 1 SuggestedDish + 1 MealSolveRequest, all on a single bg `save()` call). Typical-case ~5-15 ms; pathological dishes (40+ ingredients, 20+ steps on a fragmented store) historically spiked to 100-200 ms before the bg-context migration. Dashboard signal: p95(`persist_ms`) > 50 ms over a 14-day window OR a sudden long-tail jump = revisit the bg-context path or split the persist into a coarser batch. The property is emitted unconditionally; only the success path reaches it (failures route to `vm.markPersistenceFailed` and don't fire `leftovers_dish_selected`). Pairs with `meal_rated.leftovers_handoff_*` for the full Premium-side conversion funnel.
- **`notification_schedule_rollback_failed`** — pinned by SCA-309, `reactivation` enum value added by SCA-318. Fires from `NotificationSchedulerKit.addWithRollback` when the primary `UNUserNotificationCenter.add(...)` throws AND the rollback re-add of the prior request ALSO throws — the "user has no pending follow-up at all" outcome that OSLog-only logging hid from dashboards. `LeftoversFollowupScheduler`, `UseSoonScheduler`, and (since SCA-318) `ReactivationScheduler` all wire the same callback, discriminated by `scheduler_id` ∈ `{"leftovers_followup", "use_soon", "reactivation"}` (matching their existing telemetry-event prefix; adding a new scheduler that delegates to the kit is a wire-contract change — update `NotificationSchedulerKit.swift` callers, this clarification, and the CLAUDE.md telemetry list in the same commit). `identifier` is the failing `UNNotificationRequest.identifier` the kit tried to add (e.g. `"stir.leftoversFollowup.<sessionId>"`); `error_description` is the OS-supplied `NSError.localizedDescription` from the rollback re-add throw — counts only, no user content, satisfies ADR 0009. Dashboard signal: any non-zero 7-day rolling rate is unexpected (the prior add succeeded by definition, so the rollback target was valid at schedule time); a sustained rate signals a system-level notification subsystem fault (auth flipped to `denied` between primary and rollback, NSError thrown from a memory pressure event, etc.) and warrants user-visible recovery copy in the affected scheduler. Single-success branches (`primary add succeeded` OR `rollback re-add succeeded`) do NOT emit — only the both-failures terminal state.
- **`tutorial_started` / `tutorial_step_advanced` / `tutorial_completed` / `tutorial_skipped`** — in-app feature tours (SCA-5 / 5b / 12 / 13 / 14), distinct from the setup-onboarding funnel (`onboarding_started` / `onboarding_completed`). `tutorial_id` is a snake_case identifier matching `TutorialKey.rawValue`. v1 keys: `tonight_tour` (full-screen Tonight Home intro via `TutorialPresenter`), `scan_capture`, `scan_review`, `dinner_options`, `dish_preview`, `cook_mode_tap`, `voice_mode`, `pantry_management`, `pantry_in_list_tour` (contextual coach-mark sequences via `CoachMarkPresenter`). `from_step` / `to_step` carry per-step telemetry IDs (snake_case — e.g. `intro`/`solve`/`saved`/`settings` for the Tonight tour; `framing`/`shutter` for scan capture; variant-prefixed `populated_*`/`empty_*` for `pantry_in_list_tour`). Lifecycle: exactly one `tutorial_started` per presentation, then exactly one of `{tutorial_completed, tutorial_skipped}` on resolution; `tutorial_step_advanced` fires on every intra-tour advance (NOT on the final-step → completed transition — that's covered by `tutorial_completed` alone). **Disappear is non-terminal** — when the host view leaves the tree (tab switch, NavigationStack push, intra-screen branch swap, system overlay), the controller's `suspend()` runs and intentionally emits NO telemetry; the tour re-arms when the host re-appears. The lifecycle invariant is enforced by `CoachMarkController.suspend()` and pinned by `test_suspend_dropsOverlayWithoutMarkingCompleted`. Backgrounding / app-kill mid-tour without explicit resolution is a known third state — funnel queries should compute abandonment as `count(tutorial_started) − count(tutorial_completed) − count(tutorial_skipped)`. (Earlier drafts of this section described an emitted `reason="navigated_away"` property on `tutorial_skipped`; that was never implemented because it re-introduced a "tab switch silently completes the tour" footgun. SCA-17 review-5 audit reconciled this: spec now matches code; no `reason` property exists.)

### PostHog LLM Observability events

Distinct from the product event table above. `$ai_generation` and `$ai_trace` feed PostHog's LLM Analytics dashboards natively (cost-by-feature, latency, error rate, trace view). Every AI call in Stir emits both an `ai_request_log` row (Supabase, authoritative billing record) and a `$ai_generation` event (PostHog, dashboard source) — they're dual-writes reconciled by request id.

**Privacy posture:** neither `$ai_input` nor `$ai_output_choices` is ever populated. No user content, transcripts, or AI response text reaches PostHog. Only tokens, cost, latency, model metadata, and error flags.

**Dashboard-join contract:**

| PostHog field         | Stir value                                                                                                   |
| --------------------- | ------------------------------------------------------------------------------------------------------------ |
| `distinct_id`         | `canonical_user_key_hash` (16-char SHA-256) — WHO                                                            |
| `$ai_span_id`         | `ai_request_log.request_id` — WHICH call (1:1 reconciliation)                                                 |
| `$ai_trace_id`        | Feature grouping id: `solve_request_id` \| `import_id` \| `sub_event_id` \| `session_id` \| `client_request_id` |
| `$ai_parent_id`       | Unused in v1 (flat span structure)                                                                            |

**`$ai_generation` properties (every AI call):**

| Property                | Value                                                                                                 |
| ----------------------- | ----------------------------------------------------------------------------------------------------- |
| `$ai_trace_id`          | feature grouping id                                                                                   |
| `$ai_span_id`           | request id (= ai_request_log.request_id)                                                              |
| `$ai_span_name`         | `pantry_parse` \| `dinner_solve` \| `substitution` \| `recipe_import` \| `grocery_generate` \| `cook_turn` \| `recipe_import_async` \| `voice_cook_turn` |
| `$ai_model`             | Gemini model string                                                                                   |
| `$ai_provider`          | `gemini` (always)                                                                                     |
| `$ai_input_tokens`      | int                                                                                                   |
| `$ai_output_tokens`     | int                                                                                                   |
| `$ai_total_cost_usd`    | USD (6-decimal precision, server-computed)                                                             |
| `$ai_latency`           | seconds                                                                                               |
| `$ai_is_error`          | bool                                                                                                  |
| `$ai_error`             | Stir ErrorCode (only when `$ai_is_error=true`)                                                        |
| `feature`               | `ai_request_log.feature_key`                                                                          |
| `prompt_version`        | e.g. `1.0.0`                                                                                          |
| `thinking_level`        | `minimal` \| `low`                                                                                    |
| `retry_count`           | int (0 = first try)                                                                                   |
| `error_code`            | Stir ErrorCode duplicate for non-LLM filters                                                          |
| `path`                  | `live_api` \| `gemini_fallback` — voice-turn calls only; absent on non-voice AI                       |

**`$ai_trace` properties (voice sessions only in v1):** exactly ONE `$ai_trace` per session, fired from iOS `CookModeViewModel` at session close. Carries both input_state (captured at VM attach time) and output_state (session totals) in a single emission — PostHog is append-only, so a mint-time + close-time pair would create two sibling events rather than updating a single record (ADR 0009).

| Property                | Value                                                                                                                         |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `$ai_trace_id`          | `session_id`                                                                                                                  |
| `$ai_span_name`         | `voice_session_start`                                                                                                         |
| `$ai_input_state`       | `{ recipe_plan_id, cooking_session_id, current_step_number, prompt_version, path }`                                           |
| `$ai_output_state`      | `{ total_turns, total_prompt_tokens, total_response_tokens, total_prompt_tokens_{text,audio}, total_response_tokens_{text,audio}, ended_reason, duration_ms, path }` |
| `feature`               | `cook_mode_realtime`                                                                                                          |

`ended_reason` values: `user_exit` \| `user_stop` \| `user_pause` \| `session_finish` \| `error`.

Trace aggregation: PostHog's pseudo-trace rollup sums `$ai_generation` costs and latencies under the same `$ai_trace_id` automatically. The explicit close-time `$ai_trace` surfaces Stir-semantic metadata (recipe_plan_id, total_turns, ended_reason) in the trace view that the pseudo-trace alone wouldn't carry.

### Core dashboards

1. **Onboarding**
   `onboarding_started → onboarding_completed → scan_started → dinner_solve_completed`
2. **Core Success Funnel**
   `scan_submitted → dinner_solve_completed → suggested_dish_selected → cook_mode_started(within_3min) → cook_session_completed → meal_rated(>=4)`
3. **Voice Conversion Funnel**
   `voice_affordance_tapped(tier=free) → paywall_viewed(trigger=voice) → trial_started → purchase_completed`
4. **Billing Funnel**
   `paywall_viewed → purchase_started → purchase_completed → trial_to_paid`
5. **Retention**
   weekly cohorts anchored on `cook_session_completed`
6. **AI Ops**
   cost/user by tier, cost/feature, voice-session token distribution, fallback rate, latency, schema failures, Live API share + TTFA, preamble-present rate
7. **Flywheel**
   ingredient corrections, substitution acceptances, ratings, favorites

## 16. Testing Strategy

### Coverage targets

* domain / business logic: **85%**
* repository + sync logic: **75%**
* backend route/service layer: **80%**
* UI view models: **70%**
* end-to-end XCUITest smoke coverage on core funnel: **critical paths only**

### Test types

**Unit tests**

* pantry normalization
* hard dietary constraint engine
* dinner ranking post-validator
* quota counter math
* paywall gate logic (including voice entitlement gating)
* entitlement mapping
* reminder export mapper
* voice-session token budget tracker (prune-at-3-turns logic)

**Integration tests**

* camera capture to parse request object
* Vision OCR to recipe import normalization
* RevenueCat webhook to entitlement state
* CloudKit sync conflict resolution
* APNs token registration
* backend model routing
* Gemini Live session establishment through `/v1/ai/realtime-session`, including session config bootstrap with recipe context, thinking_level=minimal, max_output_tokens cap, and turn detection config
* Cook Mode Live API function-call round-trips to `/v1/ai/substitution` with hard-rule validator invocation
* Cook Mode forced-fallback path (`disable_cook_realtime` flag on → verify Gemini text + AVSpeechSynthesizer still works end-to-end)
* Voice entitlement enforcement: Free user hitting `/v1/ai/realtime-session` → 403 with `ENT-VOICE-01`
* Supabase RLS policy tests: confirm a session JWT for user A cannot read user B's `usage_counters`, `ai_request_log`, or `entitlement_snapshots` rows
* Session refresh (ADR 0014): verify refresh triggers at `turnCount - lastRefreshedAtTurn >= 10` AND on any single turn with `promptTokens > 15000`, that setupComplete on the new WS lands within 5s, and per-turn prompt tokens reset to ~6-7k baseline on the first turn of the new session. Earlier "session pruning via `session.update`" test was removed — the frame doesn't exist on Gemini Live.

**Manual QA checklist before each beta/prod build**

* new install, no permissions granted
* first solve with sample photo
* first solve with real camera
* camera denied flow
* photos denied flow
* reminders denied flow
* iCloud unavailable flow
* free tier quota exhaustion (solves, imports)
* Free tier: tap-based Cook Mode works, Substitution Sheet works, voice button tap → paywall appears
* Premium trial start flow via voice paywall trigger
* Premium trial start flow via save-favorite paywall trigger
* Premium trial expiry + conversion to paid
* upgrade from Premium to Pro
* downgrade from Pro to Premium
* restore purchases
* billing grace banner state (sandbox)
* Cook Mode voice via Gemini Live (happy path, barge-in, substitution via function call with preamble)
* Cook Mode voice forced to text fallback (`disable_cook_realtime` on) with `AI-VOICE-01` banner visible
* Cook Mode long session (>15 turns) — verify silent refresh
* Cook Mode noisy environment (kitchen sounds) — verify pruning keeps costs bounded
* saved meal replay offline
* widget tap deep link
* shortcut run deep link
* share extension import from Safari
* screenshot OCR import
* local-only to CloudKit-available migration
* deletion/export flows
* crash-free background/foreground restore
* Live Activity start/stop
* VoiceOver sweep on Home, Dinner Options, Cook Mode (tap + voice variants), Billing

### Beta plan

* **Phase 1**: 5 internal testers
* **Phase 2**: 10–15 external beta cooks via TestFlight
* **Duration**: 2 weeks
* **Success thresholds before public launch**

  * 70% of beta users reach aha moment
  * 50% complete at least one Cook Session (tap or voice)
  * ≥25% of Free beta users who tap the voice affordance start a trial
  * median meal rating ≥ 4
  * no blocker bug in core funnel
  * AI cost / active beta Premium user < **$2.50** (50% buffer above $1.71 projection)
  * AI cost / active beta Pro user < **$6.50**
  * Cook Mode Live API share ≥ 90% of voice turns
  * preamble-present rate ≥ 90% on Live API tool-call turns

### AI eval set

| Eval set                |          Size | Pass criteria                        |
| ----------------------- | ------------: | ------------------------------------ |
| `eval_pantry_scan_v1`   |    150 photos | precision ≥ 0.90, recall ≥ 0.75      |
| `eval_dinner_solve_v1`  | 200 scenarios | 100% hard-rule pass, 85% cookability |
| `eval_cook_turns_v1`    |     300 turns | wrong-step rate < 3% on both Live API and fallback paths; preamble-present rate ≥ 95% on Live API tool-call turns. Size rationale: at n=120 a one-sided 95% CI around 0 observed errors only bounds the true rate below ~2.5%, which is indistinguishable from the 3% target; n=300 tightens to ~1%, enough for the eval to fail a real regression. For tighter bounds (±0.5% around the target) the set would need n≥500 — accept n=300 as the v1 minimum. |
| `eval_substitutions_v1` |     300 cases | 100% hard-rule pass (0 allergen violations observed). Size rationale: allergen substitution is legally sensitive. At n=100 observing 0/100 violations only proves <3.6% real violation rate at 95% CI — that exposure is not acceptable for allergen-adjacent output. At n=300 the same 0 observed bounds true rate below ~1.2%. Weight the set heavily toward allergen-adjacent substitutions (peanut, tree nut, dairy, gluten, egg, shellfish, soy), equipment swaps that change safety profile (no-oven dairy-heavy recipe), and dietary-constraint intersections (vegan + nut-free). Synthetic candidates can be generated via Gemini 3 Pro and hand-validated for ~8–12 hours of curation work. |
| `eval_recipe_import_v1` |   100 recipes | 85% acceptable without major edit    |
| `eval_grocery_v1`       |     100 plans | 98% missing-item recall              |

Run evals:

* on every prompt change
* on every model swap
* nightly against staging defaults
* before turning canary > 25%

### AI security test plan

* prompt injection attempts in imported recipe text
* OCR with embedded "ignore instructions" text
* voice-spoken injection attempts during a Cook Mode Live API session (verify substitution function-call validator still rejects allergen violations)
* malformed JSON from provider
* cross-user data isolation check using two beta accounts/devices
* forced Gemini Live outage → fallback path engages correctly
* forced full Gemini outage → saved-meals-only mode engages correctly
* billing-grace + AI usage interaction
* quota bypass attempts via clock change / reinstall
* voice entitlement bypass attempts (e.g., Free user manipulating local state to request Live session token)
* offensive / harmful text entered during cook turns
* allergen-specific substitution stress set

## 17. Launch Content Kit

### Landing page copy

**Hero headline**
Dinner from what's already in your kitchen.

**Subhead**
Scan your fridge, pantry, or counter. Stir gives you three meals you can actually cook tonight, then guides you step by step without recipe-site chaos.

**CTA**
Get early access

**Pillar 1**
**Decide in minutes, not tabs**
Stop bouncing between Google, TikTok, recipe blogs, and the inside of your fridge. Stir turns what you already have into three real dinner options in about a minute.

**Pillar 2**
**Cook hands-free** *(Premium)*
Once you pick a meal, Stir stays with you — literally. Ask "what's next?" with flour on your hands, get answers, start timers, handle substitutions without touching the phone. Try it free for 7 days.

**Pillar 3**
**Waste less food**
Use the spinach before it goes bad. Turn leftovers into tomorrow's dinner. Write missing items straight to Reminders when you're done.

### X / Twitter launch post

I built an iPhone app for the exact weeknight problem I keep having: staring into the fridge with no plan.

Stir lets you scan what's in your kitchen, gives you 3 dinners you can actually make, then guides you step by step — hands-free — while you cook.

Looking for beta testers.

### LinkedIn launch post

I've been working on a consumer iOS app called **Stir**.

The problem is simple: most cooking apps help once you already know what you want to make. The painful part is usually earlier — standing in the kitchen at 6 p.m. with ingredients, low energy, and no plan.

Stir is built for that moment. You scan what you already have, add a constraint like "20 minutes" or "high protein," and it gives you three realistic dinner options. Once you choose one, Premium users switch into a hands-free Cook Mode with voice guidance, timers, and substitutions — no touching the phone mid-cook.

I'm opening a small beta now and looking for people who cook on weeknights and want to stress-test it honestly.

### Reddit post

**Subreddit:** r/WhatShouldICook
**Title:** I built an iPhone app that scans what's in your kitchen and suggests 3 dinners — looking for honest feedback

**Body:**
I hope this is okay to post here — manual rule check first before posting.

I built a small iPhone app called **Stir** for the exact problem this sub exists for: having ingredients at home but getting stuck on what to make.

The flow is:

* point your phone at your fridge / counter / pantry
* add a constraint like "20 minutes" or "high protein"
* get 3 dinner ideas based on what you already have
* pick one and cook with step cards, timers, and (on Premium) hands-free voice guidance

It's not a recipe social app and it's not trying to be a full pantry spreadsheet. The whole point is to get from "I don't know what to cook" to "I'm cooking this now" with less friction.

I'm looking for brutally honest feedback from people who actually cook during the week. If you'd try it, I'd love to know:

1. would this beat your current workflow?
2. where would you distrust it?
3. what would make you keep using it after the novelty wears off?

### Founder story post

I didn't build Stir because the world needed another recipe app.

I built it because the part of cooking that wears me down usually has nothing to do with cooking. It's the 10–15 minutes before that: opening the fridge, checking what's still good, half-remembering what ingredients are in the back, scrolling for ideas, then giving up and making the same thing again.

Existing apps mostly assume you already know the recipe, already planned the week, or want to save content. I wanted the opposite: an app for the exact moment dinner becomes a decision problem.

So Stir starts there. Point your phone at what you've got, say "20 minutes" or "use the spinach first," get three real options, and then keep moving while you cook — hands-free if you want.

### Testimonial request template

Subject: Quick question about Stir

Hey — thanks again for trying Stir.

I'm collecting short, specific testimonials from early users. Would you be open to replying with 2–3 sentences on:

* what problem it solved for you
* the moment it felt useful
* whether you'd keep using it on weeknights

Even one honest sentence is helpful. If something didn't work, I'd rather hear that too.

### 30-day content calendar

| Experiment objective        | Asset                                                | CTA                   | Success metric          |
| --------------------------- | ---------------------------------------------------- | --------------------- | ----------------------- |
| Prove 10-second visual hook | short reel: "Scan fridge → 3 dinners"                | waitlist / TestFlight | view-to-click rate      |
| Show hands-free cooking     | screen recording of Cook Mode voice + substitution   | trial signup          | trial start rate        |
| Hit cheap/healthy audience  | "use what you have" dinner examples                  | beta signup           | saves/shares            |
| Hit meal-prep audience      | leftovers-to-next-day clip                           | beta signup           | qualified signups       |
| Build trust                 | founder talking-head on why scan errors are editable | follow + signup       | comment quality         |
| Show speed                  | stopwatch-based "from open to dinner options"        | signup                | hook retention          |
| Social proof                | stitched beta reaction clips                         | download              | conversion from profile |
| Position against status quo | split-screen "recipe blog chaos vs Stir"             | signup                | CTR                     |
| Push saved-meal loop        | "one-tap replay on Wednesday"                        | trial                 | repeat-user conversion  |
| Trial framing               | "7 days free, cook dinner with your voice"           | trial                 | trial start rate        |

## 18. ASO Checklist

### Metadata

**App name (30 chars max)**
`Stir: AI Dinner Copilot`

**Subtitle (30 chars max)**
`Cook what you already have`

**Keyword field (100 chars max)**
`ingredients,leftovers,dinner,recipes,pantry,fridge scan,meal planner,what to cook,weeknight,voice`

### Icon strategy

* simple, high-contrast mark
* no text
* warm "stir" swirl / spoon motion on dark field
* legible at 60pt
* avoid literal fridge photo or chef-hat clichés

### Screenshot set (5–8)

1. **"Point at your kitchen"** — scan camera
2. **"Get 3 dinners in 60 seconds"** — options screen
3. **"Cook hands-free"** — Cook Mode with voice (badged "Premium")
4. **"Out of something? Fix it mid-cook"** — substitution sheet
5. **"Write missing items to Reminders"** — grocery export
6. **"Use leftovers tomorrow"** — leftovers screen
7. **"Save your weeknight winners"** — favorites
8. **"Start from a widget or shortcut"** — Home Screen entry

### Description structure

**Above the fold hook**
Stop scrolling recipe sites when you already have food at home.

**Body copy**

* Scan your fridge, pantry, or counter
* Get 3 dinner ideas that fit your time, taste, and ingredients
* Cook with step-by-step guidance, timers, and quick answers
* Go hands-free with Premium voice Cook Mode (7-day free trial)
* Fix missing ingredients without abandoning the meal
* Turn leftovers and missing items into a next-step plan

**Review solicitation cadence**

* only after:

  * successful Cook Session completed
  * rating >= 4
  * at least 2 sessions total
* never on first launch
* never right after a paywall or error

### Preview video concept

30 seconds, captions always on:

1. open app
2. scan counter/fridge
3. "20 minutes"
4. 3 dinner cards appear
5. enter Cook Mode
6. hands-free voice question mid-cook
7. export groceries

### App Store Connect optimization

* create at least 3 custom product pages:

  * **fridge scan / dinner ideas**
  * **hands-free cooking / voice Premium**
  * **leftovers / waste less**
* map creator links to specific custom product pages
* iterate subtitle and first 3 screenshots monthly based on conversion

Apple currently allows up to 70 custom product pages per app, and those pages can use distinct screenshots, previews, promotional text, and keywords. ([Apple Developer][7])

## 19. Legal & Regulatory Checklist

**Baseline:** CCPA

### Claims risk

Main harm classes if output is wrong:

* allergen exposure
* unsafe cooking / undercooking / spoilage judgment
* wasted food and time
* billing confusion

**Product rule:** no medical, dietary, or food-safety guarantees.

### Data sensitivity

Handled data classes:

* kitchen photos
* OCR'd recipe text
* voice transcripts
* dietary preferences / allergies
* grocery write-back metadata
* purchase / entitlement data
* pseudonymous analytics IDs

### Jurisdictions

* **Launch**: U.S. only
* **Baseline law**: CCPA / CPRA-style deletion and disclosure posture
* **Do not expand to EU/UK storefronts** until GDPR/UK-GDPR review is complete

### Required legal artifacts

* Terms of Service
* Privacy Policy
* in-app food-safety disclaimer language
* CCPA deletion/request process
* App Store privacy nutrition labels
* privacy manifest and required-reason API declarations as applicable

Apple requires app privacy details in App Store Connect and privacy-manifest / required-reason API compliance for relevant APIs and listed SDKs. ([Apple Developer][8])

### [LEGAL REVIEW REQUIRED]

* allergy / food-safety disclaimer wording
* ToS limitation-of-liability language for cooking guidance
* privacy policy disclosure of AI subprocessors and analytics vendors (Google Gemini including Live API, Supabase as operational-metadata processor)
* CCPA request handling workflow and designated contact
* App Store age-rating and "not for children under 13" positioning
* creator seeding / offer-code terms if using promotional campaigns
* copyright/attribution treatment for imported recipes from URLs
* trial disclosure language — Apple requires clear disclosure of auto-renewal, billing date, and cancellation path on the paywall

## 20. Cut List

| Excluded item                            | Why it is cut from v1                                                          |
| ---------------------------------------- | ------------------------------------------------------------------------------ |
| Grocery delivery checkout                | shifts product center from dinner resolution to commerce                       |
| Supermarket APIs / store prices          | high integration overhead, weak wedge                                          |
| Family/shared pantry                     | turns single-user household memory into access-control and conflict product    |
| Public social feed                       | distribution temptation, but weakens the core loop                             |
| Community recipe marketplace             | content moderation + creator economics, not needed                             |
| Desktop/web app                          | anti-signal for the phone-native job                                           |
| HealthKit nutrition logging              | changes trust/compliance burden and product meaning                            |
| Smart appliance control                  | hardware matrix and unreliable payoff                                          |
| Barcode-perfect pantry accounting        | not required to solve dinner tonight                                           |
| Location-aware dinner suggestions        | location not a load-bearing input for v1                                       |
| Wearables / Apple Watch app              | secondary surface, not core                                                    |
| CarPlay / Siri-first in-car flow         | wrong context for cooking product                                              |
| Personalized grocery budget optimization | adjacent but not core                                                          |
| Meal-planning calendar                   | easy to bloat into planning software                                           |
| Custom on-device LLM                     | complexity with little v1 benefit                                              |
| Apple Foundation Models path             | would fragment device support and conflict with the chosen minimum iOS posture |
| Cross-vendor AI fallback (OpenAI)        | operational tax exceeds insurance value at v1 scale; single-provider bet accepted |
| Fine-tuning proprietary models           | no need before eval-driven prompt work tops out                                |
| Full offline AI generation               | not necessary for launch                                                       |
| Free-tier voice Cook Sessions            | voice is the Premium differentiator; free voice undermines the upgrade trigger and flips free-tier unit economics negative |

## 21. Required User Actions

1. Register domain and reserve social handles.
2. Run trademark search in USPTO TESS for **Stir** and shortlisted alternates.
3. Enroll in Apple Developer Program (**$99/year**). ([Apple Developer][9])
4. Create App Store Connect app records for dev/beta/prod bundle IDs.
5. Enable capabilities:

   * iCloud / CloudKit
   * In-App Purchase
   * Push Notifications
   * Background Modes (remote notifications, background fetch)
   * App Groups
   * Widgets / Live Activities
6. Configure CloudKit container and deploy schema to production before launch.
7. Create subscription group and SKUs in App Store Connect:

   * `stir.premium.monthly`
   * `stir.premium.annual.trial7`
   * `stir.pro.monthly`
   * `stir.pro.annual`
8. Set Family Sharing **off** for all SKUs.
9. Configure RevenueCat project, offerings, entitlements, and webhook destination.
10. Point App Store Server Notifications / RevenueCat integration correctly.
11. Create Google Gemini paid API project with access to: Gemini 3 Flash, Gemini 3.1 Flash-Lite, and **Gemini 3.1 Flash Live Preview**. Enable Live API for the project. Verify billing is enabled (Live API requires paid tier).
12. Create Supabase project:

    * Postgres database (run migrations in `Backend/supabase/migrations/` for the operational schema in §4)
    * RLS policies enabled on every ops table, keyed on `canonical_user_key`
    * Edge Functions (Deno) deployed for each `/v1/…` endpoint in §3
    * `pg_cron` + `pgmq` for `notification_jobs` dispatch
    * Supabase Auth restricted to admin role for `/ops` console access
13. Set Edge Function secrets in Supabase:

    * Gemini API key (single key; used for all Gemini features including Live API ephemeral token minting)
    * RevenueCat webhook secret
    * APNs auth key identifiers
    * PostHog key
    * Sentry DSN
14. Set up PostHog project and feature flags.
15. Set up Sentry project for iOS + backend.
16. Generate APNs auth key in Apple Developer portal.
17. Prepare App Store privacy details / nutrition label.
18. Prepare privacy manifest and required-reason API declarations.
19. Write Privacy Policy and Terms of Service (ensure trial auto-renewal disclosure matches Apple's requirements).
20. Get lawyer review on flagged items from §19.
21. Recruit 10–15 TestFlight beta users from:

    * r/WhatShouldICook
    * r/EatCheapAndHealthy
    * r/MealPrepSunday
    * creator outreach to Ethan Chlebowski / Pro Home Cooks-adjacent micro-creators
22. Produce App Store screenshots and 30-second preview video (must showcase voice Cook Mode).
23. Do ASO keyword research in a real tool (AppTweak / Sensor Tower / data.ai).
24. Build on current Apple toolchain. If submitting after April 28, 2026, use Xcode 26+ and iOS 26 SDK or later. ([Apple Developer][2])
25. Choose U.S.-only storefronts for launch.
26. Fill App Store age-rating questionnaire carefully.
27. Configure phased release and custom product pages.
28. Create support email and deletion-request path.
29. Decide whether to use a cookie-free landing page or implement web consent if adding marketing cookies.
30. **Verify Supabase region / Google Cloud Gemini endpoint region alignment before beta.** Supabase is the sole network hop between iOS client and Gemini for all non-voice AI calls (client → Edge Function → Gemini → back). If Supabase project is provisioned in a region that's not adjacent to the Gemini endpoint (e.g., Supabase us-east-1 + Gemini us-central1), expect +100–200ms egress on every AI request. For Dinner Solve (p95 target 3.5s) that's 3–6% of the latency budget. Check actual round-trip with a production-representative payload and provision Supabase accordingly — us-central1 is the safest default. If reprovisioning is infeasible, update §12.2 latency budgets to reflect measured reality.

## 22. Open Questions

### Assumptions still unvalidated

1. **Does scan-to-dinner beat opening a general AI app by enough to stick?**
   Validate with 10 beta users; measure time-to-first-viable-meal vs their current workflow.

2. **Is single-image scan quality enough, or does multi-image become mandatory for most kitchens?**
   Validate by measuring correction rate on real homes. If correction rate >25%, move multi-image into Premium earlier or redesign scan UX.

3. **Does the voice-tap paywall convert at projected rates (25% trial start, 45% trial-to-paid)?**
   This is the single most important conversion metric for v1 unit economics. Monitor during beta; if trial-start rate is <15%, reconsider paywall framing (voice demo video on the paywall itself, softer trial messaging, etc.).

4. **Are the current free caps correctly placed?**
   Track free-user exhaustion of Dinner Solves and Imports vs uninstall/churn vs conversion. Watch whether tap-only Cook Mode is "enough" for 80%+ of Free users to complete a full session.

5. **Does local-only/no-mandatory-login create too much quota abuse?**
   Watch reinstall/reset patterns and backend anonymous spend anomalies. With voice gated, the abuse surface is smaller — mainly Dinner Solves.

6. **Do users trust leftovers suggestions?**
   Measure leftover reminder open rate and follow-up cook starts.

7. **Is single-vendor (Google) risk acceptable long-term?**
   Accepted for v1. Rationale: Gemini's 99.9% paid SLA gives ~8.7 hrs/year expected downtime, during which saved meals and cached plans cover the core experience. Operational cost of maintaining a cross-vendor fallback (OpenAI/Anthropic) exceeds the insurance value at v1 scale. **Pre-committed revisit triggers:** (a) cumulative Live API unavailability >2 hours in any rolling 30-day window as measured by `cook_voice_live_share` telemetry → enable OpenAI `gpt-realtime-mini` as secondary Cook Mode vendor within 30 days (this is a planned contingency, not proactive buildout — spec `docs/decisions/fallback-vendor.md` should be drafted pre-launch with the mint endpoint shape and Edge Function routing already scoped); (b) actual Gemini text API downtime exceeds 2x the SLA in any quarter → same trigger, text path; (c) Gemini pricing or data-policy changes materially adversely → full vendor re-evaluation; (d) Live API leaves preview status with material behavioral differences (preamble adherence regression, pricing reshape, TTFA change) → eval revalidation + trigger review. Do not leave this open-ended post-launch; you will be too busy to make the call cleanly.

8. **Will Gemini Live Preview remain behaviorally stable through v1 launch?**
   The API is in preview. Mitigated by the `disable_cook_realtime` kill switch (instant cutover to text fallback) and the weekly eval runs that would catch behavioral drift. Revisit at GA.

9. **Do the 13/27 voice-session caps (ADR 0015) match real usage shapes?**
   Premium 13 / Pro 27 caps were set using step-6 device-measured per-turn cost + the permanent-no-caching assumption (implicit caching empirically doesn't fire on `gemini-3.1-flash-live-preview`). The caps align with median weekday-cooker patterns (~3 cooking-heavy days × 4 weeks ≈ 12 sessions) but may be tight for a daily-cooker segment. Watch cap hit-rate + post-cap churn during beta. If >30% of Premium users hit the cap AND churn spikes after, consider a superseding ADR that either raises the cap (if the ADR 0015 caching-trigger query also fires) or shifts tier pricing. Trigger criteria detailed in ADR 0015 "Trigger to revisit."

### Post-launch risk areas

* CloudKit edge cases when users move between local-only and synced mode
* Gemini Live Preview API behavior or pricing changes during v1 lifecycle
* soft paywall timing hurting early trust
* creator-content installs not turning into retained cooks
* import quality variance from chaotic recipe pages and screenshots
* Pro tier margin compression if voice usage trends upward

### `[HANDOFF CONFLICT: ...]` log

* **[HANDOFF CONFLICT: auth strategy not specified while the handoff requires CloudKit-backed sync with no separate account requirement — proposing no mandatory sign-in, with CloudKit user record name as canonical user key when available and a keychain installation ID fallback when iCloud is unavailable.]**
* **[HANDOFF CONFLICT: `ios_capabilities` names Shortcuts while `v1_features` names Shortcuts/App Intents — proposing App Intents as the implementation substrate for Shortcuts, without treating it as an additional product-surface decision.]**
* **[HANDOFF CONFLICT: Pro tier includes "deeper household memory" but does not quantify a memory cap — proposing 1,000 remembered pantry items and 365-day preference memory for Pro to make entitlements enforceable.]**
* **[HANDOFF CONFLICT: async weekly suggestions are named in the handoff, but user content lives in CloudKit private storage the backend should not mirror — proposing on-device/local-notification generation for weekly suggestions, with backend async used only for explicit user-initiated imports and AI jobs.]**

## Definition of Done

**Core product**

* [ ] New user can reach 3 dinner options from a live or sample scan in <120 seconds p90 (stretch <90s on the sample-photo path)
* [ ] User can select a dish and enter Cook Mode in <3 minutes
* [ ] Tap-based Cook Mode works for all tiers with next/prev step, timers, and Substitution Sheet
* [ ] Voice Cook Mode works for Premium+ users with Gemini Live API primary + fallback to text path + `AI-VOICE-01` banner
* [ ] Voice affordance on Free tier triggers hard paywall (`ENT-VOICE-01`) with annual trial CTA as primary
* [ ] Recipe import works from URL and screenshot
* [ ] Grocery export works to Reminders with denial fallback
* [ ] Saved favorites replay correctly
* [ ] Widget and one Shortcut/App Intent work end-to-end

**AI quality**

* [ ] Pantry scan eval passes target thresholds
* [ ] Dinner solve passes 100% hard-rule eval
* [ ] Substitution eval has 0 hard-rule violations (both standalone and Live API function-call invocations)
* [ ] Cook Mode turn eval passes wrong-step rate target on both Live API and fallback paths
* [ ] Preamble-present rate ≥ 95% on Live API tool-call turns in eval
* [ ] Recipe import eval meets acceptance target
* [ ] Total monthly AI cost estimate remains under **$2.50/active Premium user** and **$6.50/active Pro user** at launch assumptions (50% buffer above projections)
* [ ] Live API fallback path is tested and functional

**Data + sync**

* [ ] Core Data persistent store stable across cold launches
* [ ] CloudKit sync verified across two devices on same iCloud account
* [ ] Local-only mode works when iCloud is unavailable
* [ ] Export and delete flows work and are documented
* [ ] Schema migrations tested from at least one prior build

**Billing**

* [ ] StoreKit products approved and visible
* [ ] RevenueCat entitlements update correctly
* [ ] Trial, purchase, upgrade, downgrade, restore, cancellation, and grace-period states tested in sandbox
* [ ] Free caps and paid caps enforced correctly
* [ ] Voice entitlement enforced at `/v1/ai/realtime-session` — Free user request returns 403 with `ENT-VOICE-01`

**Reliability + security**

* [ ] Sentry captures app and backend errors
* [ ] PostHog receives funnel and AI cost events
* [ ] Backend rate limiting active (including per-user voice Cook Session minute/count caps)
* [ ] RevenueCat webhook signature verified
* [ ] No API keys in app bundle. Cook Mode voice uses ephemeral Gemini Live session tokens minted by Supabase Edge Functions; the main Gemini API key stays server-side.
* [ ] Prompt rollback and feature kill switches work (including `disable_cook_realtime`)
* [ ] Session pruning verified — cumulative voice session tokens stay <40K in 95%+ of sessions

**UX**

* [ ] Every screen has loading, empty, and error states
* [ ] VoiceOver sweep completed on primary flow
* [ ] Dynamic Type verified on primary flow
* [ ] Permission-denied flows are graceful
* [ ] Paywall copy and trial disclosure match Apple requirements
* [ ] App review-worthy copy, screenshots, and preview video ready (preview video must showcase voice Cook Mode)

**Launch ops**

* [ ] Privacy Policy and ToS live
* [ ] [LEGAL REVIEW REQUIRED] items signed off
* [ ] App privacy details and privacy manifest complete
* [ ] TestFlight beta completed with 10–15 users
* [ ] Core success event observed in real beta telemetry
* [ ] Voice conversion event observed at ≥25% trial-start rate in beta
* [ ] App Store metadata, custom product pages, and phased release plan set

[1]: https://developer.apple.com/documentation/cloudkit/designing-and-creating-a-cloudkit-database "https://developer.apple.com/documentation/cloudkit/designing-and-creating-a-cloudkit-database"
[2]: https://developer.apple.com/news/upcoming-requirements/ "https://developer.apple.com/news/upcoming-requirements/"
[3]: https://developer.apple.com/app-store/small-business-program/ "https://developer.apple.com/app-store/small-business-program/"
[4]: https://developer.apple.com/help/app-store-connect/manage-subscriptions/enable-billing-grace-period-for-auto-renewable-subscriptions/ "https://developer.apple.com/help/app-store-connect/manage-subscriptions/enable-billing-grace-period-for-auto-renewable-subscriptions/"
[5]: https://ai.google.dev/gemini-api/docs/pricing "https://ai.google.dev/gemini-api/docs/pricing"
[7]: https://developer.apple.com/app-store/custom-product-pages/ "https://developer.apple.com/app-store/custom-product-pages/"
[8]: https://developer.apple.com/app-store/app-privacy-details/ "https://developer.apple.com/app-store/app-privacy-details/"
[9]: https://developer.apple.com/get-started/ "https://developer.apple.com/get-started/"
