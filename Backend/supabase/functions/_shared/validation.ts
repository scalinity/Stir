// Zod schemas for Edge Function request bodies.
//
// Every handler parses the request body through the relevant schema before
// touching the database. Failures surface as VAL-01 with structured
// field_errors for Sentry debugging on the iOS side.

import { z, ZodError, type ZodIssue } from 'zod';
import type { FieldError } from './errors.ts';

// ---------------------------------------------------------------------------
// /v1/session/bootstrap
// ---------------------------------------------------------------------------
//
// installation_id: UUID v4 generated in iOS keychain. Required. Regex enforces
//   RFC 4122 v4 strictly (version nibble == 4, variant nibbles ∈ {8,9,a,b}) —
//   both upper and lower case accepted so iOS's `UUID().uuidString` (uppercase)
//   and JS/CLI-generated UUIDs (lowercase) both pass. Rejects v1/v5/v7 shapes
//   that happen to pass Zod's permissive `.uuid()` check. Tightens the API
//   contract and gives clearer field_errors on malformed clients.
// cloudkit_user_record_name: Opaque CloudKit userRecordName. Apple-issued
//   format is `_` + 32 lowercase hex chars (spec §12, validated against real
//   CK records April 2026). Tightening to this regex — rather than allowing
//   any 1–256 char string — shrinks the identity-spoofing attack surface:
//   an attacker can still claim a valid-looking canonical_user_key if they
//   know another user's CK record name, but arbitrary-string abuse and
//   malformed-client bugs fail at the boundary with a structured VAL-01.
// cloudkit_web_auth_token: Short-lived token minted on-device via
//   CKFetchWebAuthTokenOperation. Server spends it against CloudKit Web
//   Services before trusting cloudkit_user_record_name. Optional so old
//   clients/local-only users still bootstrap; unverified CK claims fall back
//   to install:<uuid> in session-bootstrap instead of being trusted.
// build: iOS build string, e.g. "1.0.0 (42)". Required for telemetry.
// os_version: iOS version string, e.g. "17.5.1". Required for telemetry.

// SCA-380: exported so auth.ts can re-validate `installation_id` claim
// from a verified JWT. Pre-SCA-380 the JWT-extracted value was only
// type-checked + non-empty-checked, leaving a rogue / mis-minted JWT
// that survives signature verification (e.g. internal tooling bug,
// jose key rotation lag) free to inject arbitrary strings into
// `installation_id`-keyed Postgres lookups. The regex re-check is
// belt-and-suspenders: the only path that mints these JWTs already
// validates the claim against this same regex on the way in, so a
// healthy system never trips the new check.
export const UUID_V4_REGEX =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/;
const CK_RECORD_NAME_REGEX = /^_[a-f0-9]{32}$/;

// SCA-380: free-form telemetry strings reject any control character
// (`\r`, `\n`, `\t`, NUL, escape, etc). `build` and `os_version` are
// the only validation-time fields that flow untrusted into OSLog
// breadcrumbs, PostHog properties, and `device_installations`
// columns. Without this filter, a malicious client could inject CRLF
// (`"1.0.0\r\nfake_log_line spoofed=true"`) into a structured log
// stream and trick a downstream parser into seeing a fabricated
// log entry. The codepoint range covers all C0 + DEL + C1 controls.
const CONTROL_CHAR_REGEX = /[\x00-\x1f\x7f-\x9f]/;
const noControlChars = z.string().refine(
  (s) => !CONTROL_CHAR_REGEX.test(s),
  { message: 'must not contain control characters (CR, LF, NUL, etc.)' },
);

export const SessionBootstrapRequest = z.object({
  installation_id: z.string().regex(UUID_V4_REGEX, 'must be a UUID v4'),
  cloudkit_user_record_name: z.string()
    .regex(CK_RECORD_NAME_REGEX, 'must match `_` + 32 lowercase hex chars')
    .optional(),
  cloudkit_web_auth_token: z.string().min(16).max(4096).optional(),
  build: noControlChars.pipe(z.string().min(1).max(64)),
  os_version: noControlChars.pipe(z.string().min(1).max(64)),
}).strict();

export type SessionBootstrapRequest = z.infer<typeof SessionBootstrapRequest>;

// ---------------------------------------------------------------------------
// /v1/config/bootstrap (no body; GET with JWT)
// ---------------------------------------------------------------------------
// Placeholder: future GETs may accept query params (e.g. ?include=prompts,flags)
// to trim the payload. Step 1 returns everything unconditionally.

// ---------------------------------------------------------------------------
// /v1/ai/pantry-parse (step 3 + SCA-35 multi-image, step 7)
// ---------------------------------------------------------------------------
//
// Two payload shapes accepted, mutually exclusive:
//
// (a) Single-image (Free/Premium/Pro):
//     image_base64        + image_mime_type
//
// (b) Multi-image (Pro-only at handler level — gated by ENT-MULTI-IMAGE-01):
//     images: [{base64, mime_type}, ...]   length 2..4
//
// The schema accepts EITHER but never both, enforced via superRefine.
// The image count is derived from the payload shape (`images?.length
// ?? 1`); there is no separate count field on the wire — SCA-36 W8
// dropped the redundant `image_count` checksum that lived in three
// layers of the stack and added zero value.
//
// client_request_id: idempotency key; 10-min cache.
// image_base64 / image_mime_type: JPEG/HEIC/PNG/WebP image, ≤ ~6MB decoded.
//   Zod validates length; the handler validates decoded MIME + byte size
//   after base64 decode (cheaper to let Zod catch obviously-oversized
//   strings first).
// images: same per-image bounds as singular. Min 2 (single-image path
//   exists), max 4 (CLAUDE.md SCA-35 cap — covers fridge + 2 pantry
//   shelves + counter; per-image Gemini cost grows linearly so 4 is the
//   defensible v1 ceiling).
// household_profile_hash: optional — if present, a cache miss is also
//   forced when the caller's household changed between requests. Not
//   used in step 3 cache lookup (keyed on request_id only); future-proofs
//   the shape.

// ~6MB raw → ~8MB base64. Cap at 10MB of base64 as a hard ceiling.
const IMAGE_BASE64_MAX = 10 * 1024 * 1024;

const PantryParseImagePart = z.object({
  base64: z.string().min(100).max(IMAGE_BASE64_MAX),
  mime_type: z.enum(['image/jpeg', 'image/png', 'image/heic', 'image/webp']),
}).strict();

export const PANTRY_PARSE_MULTI_IMAGE_MAX = 4;

export const PantryParseRequest = z.object({
  client_request_id: z.string().uuid(),
  // Singular fields are optional now — required when `images` is absent.
  image_base64: z.string().min(100).max(IMAGE_BASE64_MAX).optional(),
  image_mime_type: z.enum(['image/jpeg', 'image/png', 'image/heic', 'image/webp']).optional(),
  // Multi-image array. min(2) so a 1-image request must use the singular
  // fields — keeps the back-compat path unambiguous and matches the iOS
  // back-compat behaviour (single capture continues to send singular).
  images: z.array(PantryParseImagePart).min(2).max(PANTRY_PARSE_MULTI_IMAGE_MAX).optional(),
  household_profile_hash: z.string().min(1).max(128).optional(),
}).strict().superRefine((body, ctx) => {
  const hasSingle = body.image_base64 !== undefined && body.image_mime_type !== undefined;
  // SCA-36 W19: rely on Zod's `.array(...).min(2)` for "is this a
  // multi-image request" rather than re-checking length here. A
  // 1-element `images[]` would have already been rejected; the
  // simpler boolean `images !== undefined` keeps a single source of
  // truth for the multi-image discriminator.
  const hasMulti = body.images !== undefined;
  if (!hasSingle && !hasMulti) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      path: ['images'],
      message: 'must provide image_base64+image_mime_type or images[2..4]',
    });
    return; // Skip downstream checks once root invariant fails.
  }
  if (hasSingle && hasMulti) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      path: ['images'],
      message: 'cannot provide both image_base64 and images[]; choose one',
    });
  }
});

export type PantryParseRequest = z.infer<typeof PantryParseRequest>;

// ---------------------------------------------------------------------------
// /v1/ai/dinner-solve (step 3)
// ---------------------------------------------------------------------------
//
// solve_request_id: client-generated UUID for idempotency; bound to the
//   same cache namespace (by feature_key) as pantry_parse to simplify
//   ops dashboards.
// parse_id: optional link to a prior pantry-parse row so ops can correlate
//   scan→solve funnels. Manual-entry flow sets this to null.
// ingredients: min 1 to avoid "solve with nothing" noise.
// constraints.max_time_minutes: optional; when set, caps total_time
//   across returned dishes.
// household_context.servings: 1..12 (mirror HouseholdProfile).

const DietaryRuleKind = z.enum(['allergy', 'diet', 'dislike', 'goal']);
const DietaryRuleSeverity = z.enum(['hard', 'soft']);

const IngredientLite = z.object({
  display_name: z.string().min(1).max(128),
  canonical_slug: z.string().min(1).max(128).optional(),
  amount_text: z.string().min(1).max(128).optional(),
}).strict();

// Step 7 — leftovers variant: when context_hint = 'leftovers', the solve
// uses the v1.1.0 prompt and emphasizes next-2-days use-up. `leftovers_items`
// is the list of leftover ingredients from a previous cook (sourced from
// OutcomeFeedback.leftoverCount > 0 + user selection in the Leftovers sheet).
const LeftoversItem = z.object({
  display_name: z.string().min(1).max(128),
  canonical_slug: z.string().min(1).max(128).optional(),
  approximate_amount_text: z.string().min(1).max(128).optional(),
}).strict();

export const DinnerSolveRequest = z.object({
  solve_request_id: z.string().uuid(),
  parse_id: z.string().uuid().optional(),
  ingredients: z.array(IngredientLite).min(1).max(200),
  // context_hint carries the solve intent. Default (undefined | 'standard')
  // → v1.0.0 prompt; 'leftovers' → v1.1.0 prompt canaried at rollout_pct=20.
  context_hint: z.enum(['standard', 'leftovers']).optional(),
  // Present iff context_hint === 'leftovers'. Empty array rejected here so
  // the client can't accidentally request leftovers mode with no leftovers.
  leftovers_items: z.array(LeftoversItem).min(1).max(20).optional(),
  constraints: z.object({
    max_time_minutes: z.number().int().min(1).max(360).optional(),
    cuisine_leaning: z.string().min(1).max(64).optional(),
    use_first: z.array(z.string().min(1).max(128)).max(20).optional(),
    avoid_equipment: z.array(z.string().min(1).max(64)).max(20).optional(),
    goal: z.string().min(1).max(256).optional(),
  }).strict().optional(),
  household_context: z.object({
    servings: z.number().int().min(1).max(12),
    dietary_rules: z.array(z.object({
      kind: DietaryRuleKind,
      value: z.string().min(1).max(64),
      severity: DietaryRuleSeverity,
    })).max(50),
    available_equipment: z.array(z.string().min(1).max(64)).max(50),
  }).strict(),
  // SCA-44 preference-memory digest. Optional — old clients that never
  // build the digest, AND new clients that have no rated meals in the
  // tier window, both omit the field entirely. Sizes here MUST mirror
  // the iOS PreferenceMemoryService caps (recentMealsCap=10,
  // dislikedMealsCap=5, highlightNotesCap=3, noteCharCap=100, title
  // 80 chars). A drift on either side is a wire-contract bug, not a
  // hot-path failure mode — the .strict() refine catches it as
  // VAL-01 with field-level detail.
  feedback_summary: z.object({
    recent_meal_count: z.number().int().min(0).max(1000),
    window_days: z.number().int().min(1).max(366),
    recent_meals: z.array(
      z.object({
        title: z.string().min(1).max(80),
        rating: z.number().int().min(1).max(5),
        workload: z.enum(['easy', 'medium', 'hard']),
        taste: z.enum(['loved', 'good', 'ok', 'bad']),
        spice_level: z.enum(['mild', 'medium', 'hot', 'too_hot']),
        would_repeat: z.boolean(),
        cooked_days_ago: z.number().int().min(0).max(366),
      }).strict(),
    ).max(10),
    aggregates: z.object({
      average_rating: z.number().min(1).max(5),
      dominant_taste: z.enum(['loved', 'good', 'ok', 'bad']),
      dominant_spice_level: z.enum(['mild', 'medium', 'hot', 'too_hot']),
      dominant_workload: z.enum(['easy', 'medium', 'hard']),
      high_rated_rate: z.number().min(0).max(1),
      would_repeat_rate: z.number().min(0).max(1),
    }).strict().nullable(),
    disliked_meals: z.array(z.string().min(1).max(80)).max(5),
    highlight_notes: z.array(
      z.object({
        title: z.string().min(1).max(80),
        rating: z.number().int().min(1).max(5),
        note: z.string().min(1).max(100),
      }).strict(),
    ).max(3),
  }).strict().optional(),
}).strict().refine(
  // Guard rails: leftovers mode must carry items; standard mode must not.
  (b) => {
    if (b.context_hint === 'leftovers') return !!b.leftovers_items && b.leftovers_items.length > 0;
    return !b.leftovers_items || b.leftovers_items.length === 0;
  },
  {
    message: "leftovers_items required when context_hint='leftovers' and forbidden otherwise",
    path: ['leftovers_items'],
  },
);

export type DinnerSolveRequest = z.infer<typeof DinnerSolveRequest>;

// ---------------------------------------------------------------------------
// /v1/ai/substitution (step 4)
// ---------------------------------------------------------------------------
//
// Mid-cook rescue for a missing ingredient or an equipment problem. Invoked
// by the Substitution Sheet on all tiers; step 6 adds a second invocation
// path (Gemini Live function-call) that hits the SAME endpoint — the wire
// shape is deliberately stable across both.
//
// sub_event_id: client-generated UUID. Idempotency key (10-min cache) AND
//   the primary key of the persisted SubstitutionEvent row in CloudKit.
// cooking_session_id: UUID of the CookingSession currently active on iOS.
//   Kept for telemetry / future ops lookup; server does not resolve it to
//   a Postgres row (user content is CloudKit-only).
// recipe_plan_id: UUID of the RecipePlan the user is cooking from. Same
//   CloudKit-only treatment; used here only as context the model may cite.
// missing_ingredient: either a RecipeIngredient the user picked
//   (display_name + canonical_slug) OR a free-text claim ("my blender").
//   The display_name is what the model will substitute for.
// user_problem: verbatim or paraphrased user description ("I'm out of
//   milk", "blender broke"). Max 500 chars — above that it stops being a
//   substitution ask and starts being a general Cook Mode Q&A.
// household_context.dietary_rules: hard-rule set to enforce. The model
//   must respect these AND the hard_rules.ts validator re-checks
//   server-side regardless of model adherence.
// household_context.available_equipment: authoritative — if the user's
//   problem is "blender broke", iOS is expected to POP blender from the
//   list before sending. We don't parse user_problem for negations here.
// household_context.pantry_snapshot: model uses this to prefer pantry
//   substitutes over non-pantry suggestions.
// recipe_context: current recipe state so the model can preserve
//   integrity ("don't substitute an aromatic into a dessert").

const MissingIngredient = z.object({
  display_name: z.string().min(1).max(128),
  canonical_slug: z.string().min(1).max(128).optional(),
  amount_text: z.string().min(1).max(128).optional(),
}).strict();

const PantrySnapshotItem = z.object({
  display_name: z.string().min(1).max(128),
  canonical_slug: z.string().min(1).max(128).optional(),
}).strict();

const RemainingIngredient = z.object({
  display_name: z.string().min(1).max(128),
  canonical_slug: z.string().min(1).max(128).optional(),
}).strict();

// SCA-425: numbered list of every recipe step so the substitution model
// can SEE the recipe's own instructions. Without this, the model has only
// `remaining_ingredients` + `current_step_number` and cannot tell when
// the recipe already produces the missing ingredient via a sub-recipe
// step (e.g. recipe says "make flatbread from flour" and the user says
// "I have no flatbread" — pre-SCA-425 the model proposed "make your own
// bread from flour", duplicating a step the recipe already has).
//
// Bounds mirror `RealtimeRecipeContext.all_steps` (the voice-path schema
// that closed the same blindness for cook-turn): step_number 1..100,
// instruction <= 2000 chars, timer_seconds nullable 0..36000.
//
// Optional for back-compat: legacy iOS clients that ship before this
// rollout will not send the field, and the v1.0.0 prompt does not
// reference it. v1.1.0 prompt (rollout-gated) consults it; the model
// gracefully degrades to ingredient-only behaviour when absent.
const SubstitutionRecipeStep = z.object({
  step_number: z.number().int().min(1).max(100),
  instruction: z.string().min(1).max(2000),
  timer_seconds: z.number().int().min(0).max(36000).nullable(),
}).strict();

export const SubstitutionRequest = z.object({
  sub_event_id: z.string().uuid(),
  cooking_session_id: z.string().uuid(),
  recipe_plan_id: z.string().uuid(),
  missing_ingredient: MissingIngredient,
  user_problem: z.string().min(1).max(500),
  // Step 6: optional Live-session correlation. Present when the request
  // came from a Gemini Live `substitution_check` function-call round-trip;
  // absent when the request came from the standalone Substitution Sheet.
  // Used for ai_request_log correlation and cost-attribution dashboards.
  // Wire-shape stability matters: iOS sends the same body with or without
  // this field depending on invocation path; server logs it if present.
  live_session_id: z.string().uuid().optional(),
  household_context: z.object({
    dietary_rules: z.array(z.object({
      kind: DietaryRuleKind,
      value: z.string().min(1).max(64),
      severity: DietaryRuleSeverity,
    })).max(50),
    available_equipment: z.array(z.string().min(1).max(64)).max(50),
    pantry_snapshot: z.array(PantrySnapshotItem).max(200),
  }).strict(),
  recipe_context: z.object({
    title: z.string().min(1).max(256),
    current_step_number: z.number().int().min(0).max(100),
    total_steps: z.number().int().min(1).max(100),
    remaining_ingredients: z.array(RemainingIngredient).max(100),
    // SCA-425. See SubstitutionRecipeStep comment above for the why.
    recipe_steps: z.array(SubstitutionRecipeStep).max(100).optional(),
  }).strict(),
}).strict();

export type SubstitutionRequest = z.infer<typeof SubstitutionRequest>;

// ---------------------------------------------------------------------------
// /v1/ai/recipe-step-rewrite (SCA-432)
// ---------------------------------------------------------------------------
//
// Called from SubstitutionSheetViewModel.accept() right after the user
// taps Accept on a safe swap. Rewrites the CURRENT step's instructionText
// so the prose references the substitute ingredient instead of the
// original (e.g. "Mix flour, a pinch of salt..." → "Combine 1 cup of
// finely crushed tortilla chips with a pinch of salt..."). Replaces the
// pre-SCA-432 swap-badge banner UX which left the original prose intact
// and showed a scrollable orange chip above the step.
//
// Idempotency: caller passes the same sub_event_id used for the
// substitution request; cached for 10 min via ai_response_cache so an
// accidental double-tap doesn't double-bill. Feature_key is distinct
// (`recipe_step_rewrite`) so the cache lookups don't collide.
//
// step_instruction_text: the literal RecipeStep.instructionText to
//   rewrite. Capped at 2000 chars (matches RealtimeRecipeContext bound).
// original_ingredient: display name BEFORE the swap (e.g. "all-purpose
//   flour"). The model uses this to locate references to swap out.
// substitute_ingredient: display name AFTER the swap (e.g. "finely
//   crushed tortilla chips"). What the rewritten prose should reference.
// amount_conversion: optional. When the substitution endpoint produced
//   a conversion ("1 cup → 1 cup", or "3 Tbsp butter → 2 Tbsp olive
//   oil + 1 tsp lemon juice"), pass it through so the rewritten step
//   carries the right quantity. Null when the swap is amountless.
// recipe_title: passed for context only — helps the model preserve dish
//   integrity in the rewrite ("the dough" stays a dough, not a batter).

export const RecipeStepRewriteRequest = z.object({
  sub_event_id: z.string().uuid(),
  step_instruction_text: z.string().min(1).max(2000),
  original_ingredient: z.string().min(1).max(128),
  substitute_ingredient: z.string().min(1).max(400),
  amount_conversion: z.string().min(1).max(400).optional(),
  recipe_title: z.string().min(1).max(256).optional(),
}).strict();

export type RecipeStepRewriteRequest = z.infer<typeof RecipeStepRewriteRequest>;

// ---------------------------------------------------------------------------
// /v1/ai/realtime-session (step 6)
// ---------------------------------------------------------------------------
//
// Mints an ephemeral Gemini Live auth token pre-configured for ONE Cook
// Session. iOS opens a WebSocket directly to Google with the returned
// token; the GEMINI_API_KEY never reaches the device.
//
// client_request_id: idempotency key — paired with cooking_session_id it
//   scopes the mint cache so a second tap within ~60 s returns the SAME
//   token (no double-charge, no leaked mints).
// cooking_session_id: CloudKit UUID of the CookingSession the user is
//   inside. Used for ai_request_log correlation and VoiceTurn grouping.
// recipe_plan_id: RecipePlan the session is cooking from; context-only,
//   not resolved server-side (user content is CloudKit-only).
// current_step_number: 1-indexed step the user is on when Cook Mode voice
//   opens. Drives the system prompt's "# Current step" block.
// recipe_context: server trusts iOS to send the data it needs for the
//   system prompt. No server-side lookup because user content isn't
//   mirrored to Supabase.
// household_context: same shape as substitution, for hard-rule and
//   pantry/equipment substitution decisions the model may make.

// SCA-147: when this schema tightens (new required field, narrowed
// bound, etc.), ALSO update
// `tests/_helpers/fixtures/realtime_recipe_context.ts`. That fixture
// factory is consumed by every voice-path handler test (currently
// `realtime_session_test.ts` + `cook_turn_test.ts`); keeping the
// fixture in lockstep with the schema means a single edit catches
// all consumers, vs the pre-SCA-147 pattern where each test file's
// `validBody()` carried an independent copy and drifted silently
// (`all_steps` add on 2026-04-22 fixed twice — `5348383`, `e117af4`).
const RealtimeRecipeContext = z.object({
  title: z.string().min(1).max(256),
  servings: z.number().int().min(1).max(12),
  estimated_minutes: z.number().int().min(1).max(720),
  total_steps: z.number().int().min(1).max(100),
  current_step_text: z.string().min(1).max(2000),
  // 0 → no timer. Use nullable for "no timer" but keep it integer so Zod
  // doesn't choke on null when a step has no timer.
  current_step_timer_seconds: z.number().int().min(0).max(36000).nullable(),
  // Full numbered list of every step in the recipe. Added 2026-04-22
  // after observed hallucination: user on step 2 asked about step 3
  // and the model invented content (said step 3 was "sautéing with
  // garlic" when it was really "add kale to boiling water"). Prior
  // context gave only the current step; the model had no grounding
  // for adjacent steps. Bounded `max(100)` matches `total_steps`
  // bound; each instruction capped at 2000 chars to match
  // `current_step_text`. Timer bound mirrors
  // `current_step_timer_seconds`.
  all_steps: z.array(
    z.object({
      step_number: z.number().int().min(1).max(100),
      text: z.string().min(1).max(2000),
      timer_seconds: z.number().int().min(0).max(36000).nullable(),
    }).strict(),
  ).max(100),
  remaining_ingredients: z.array(
    z.object({
      display_name: z.string().min(1).max(128),
      canonical_slug: z.string().min(1).max(128).optional(),
    }).strict(),
  ).max(50),
}).strict();

const RealtimeHouseholdContext = z.object({
  dietary_rules: z.array(
    z.object({
      kind: DietaryRuleKind,
      value: z.string().min(1).max(64),
      severity: DietaryRuleSeverity,
    }).strict(),
  ).max(50),
  available_equipment: z.array(z.string().min(1).max(64)).max(50),
  pantry_snapshot: z.array(
    z.object({
      display_name: z.string().min(1).max(128),
      canonical_slug: z.string().min(1).max(128).optional(),
    }).strict(),
  ).max(200),
}).strict();

export const RealtimeSessionRequest = z.object({
  client_request_id: z.string().uuid(),
  cooking_session_id: z.string().uuid(),
  recipe_plan_id: z.string().uuid(),
  current_step_number: z.number().int().min(1).max(100),
  recipe_context: RealtimeRecipeContext,
  household_context: RealtimeHouseholdContext,
  // Optional ~200-300 token recap appended to systemInstruction for
  // session refresh continuity (ADR 0014). Absent = fresh session.
  // Cap at 2048 chars to keep the mint body well under limits; iOS
  // builds a targeted recap from last 3 voice turns + timer state.
  recap: z.string().max(2048).optional(),
  // True when this mint is a silent handoff within an already-active
  // cook session (iOS refresh trigger at turn 10 / >15k tokens). When
  // set, the backend skips the voice_cook_session quota increment — the
  // original session start already consumed one slot and refreshes are
  // cost-control handoffs, not new sessions. Default false (fresh start).
  is_refresh: z.boolean().optional().default(false),
}).strict();

export type RealtimeSessionRequest = z.infer<typeof RealtimeSessionRequest>;

// ---------------------------------------------------------------------------
// /v1/ai/cook-turn (step 6 text fallback)
// ---------------------------------------------------------------------------
//
// Text fallback for Cook Mode voice when Gemini Live is unavailable. iOS
// transcribes the user's utterance on-device (SFSpeechRecognizer) and sends
// the transcript to this endpoint; the model replies with a short spoken
// response and optional suggested action. Same recipe + household context
// shape as realtime-session since the same system-prompt template variables
// are substituted.
//
// transcript: <500 chars; above that is a Q&A not a cook-turn.
// Still Premium+ only — voice fallback is the degraded path for an
// already-active voice cook session; Free users hit ENT-VOICE-01.

export const CookTurnRequest = z.object({
  client_request_id: z.string().uuid(),
  cooking_session_id: z.string().uuid(),
  recipe_plan_id: z.string().uuid(),
  current_step_number: z.number().int().min(1).max(100),
  transcript: z.string().min(1).max(500),
  recipe_context: RealtimeRecipeContext,
  household_context: RealtimeHouseholdContext,
}).strict();

export type CookTurnRequest = z.infer<typeof CookTurnRequest>;

// ---------------------------------------------------------------------------
// /v1/ai/voice-turn-usage (step 6 — PostHog LLM Observability)
// ---------------------------------------------------------------------------
//
// iOS fires this fire-and-forget after every Gemini Live `turnComplete`
// to report usageMetadata + latency from the WebSocket turn. Backend
// computes cost, inserts one ai_request_log row per turn, captures one
// $ai_generation to PostHog. Request is batched from v1 — iOS sends
// single-item arrays today; buffering can be added later without a
// schema change.
//
// Reconciliation contract (ADR 0009):
//   ai_request_log.request_id = "voice:<session_id>:<turn_index>"
//   $ai_span_id               = same
//   $ai_trace_id              = <session_id>  (matches mint trace)
//
// path:
//   'live_api'        — Gemini Live WebSocket (C.2). All v1 writes.
//   'gemini_fallback' — Reserved for future C.3 unification. Accepted
//                        but currently unused (SpeechFallbackService
//                        calls /v1/ai/cook-turn which captures directly).

const TurnUsage = z.object({
  turn_index: z.number().int().min(1).max(500),
  prompt_tokens_text: z.number().int().min(0).max(1_000_000),
  prompt_tokens_audio: z.number().int().min(0).max(1_000_000),
  // Raw `promptTokenCount` / `responseTokenCount` summed across
  // generation passes. May exceed `text + audio` by the AUDIO-mode
  // per-pass overhead (CLAUDE.md sharp-edge #15). Handler uses totals
  // for `ai_request_log.input_tokens` / `output_tokens` and prices the
  // uncategorized remainder at audio in/out rate.
  prompt_tokens_total: z.number().int().min(0).max(1_000_000),
  // Gemini Live `cachedContentTokenCount` — portion of prompt tokens
  // served from implicit context cache. When > 0, that portion is
  // discounted in pricing (Gemini publishes ~25% of text-in rate for
  // cached). Feeds `ai_request_log.prompt_cached_tokens` + PostHog
  // `$ai_cache_read_input_tokens` so the cap-reversal trigger in spec §9
  // ("cachedContentTokenCount ≥ 50% of promptTokenCount across 100
  // sessions") is measurable. Optional — iOS omits when the accumulated
  // count is zero (saves a field on the common path where caching isn't
  // firing).
  prompt_tokens_cached: z.number().int().min(0).max(1_000_000).optional(),
  response_tokens_text: z.number().int().min(0).max(1_000_000),
  response_tokens_audio: z.number().int().min(0).max(1_000_000),
  response_tokens_total: z.number().int().min(0).max(1_000_000),
  latency_ms: z.number().int().min(0).max(600_000),
  ended_reason: z.enum(['turn_complete', 'tool_response', 'error', 'interrupted']),
  prompt_version: z.string().min(1).max(32),
  // v1 is live_api only — /v1/ai/cook-turn handles the gemini_fallback
  // path with its own recordAIRequest emission. Reopening the enum
  // requires a deliberate ADR update (no silent addition) so dashboards
  // don't cross-contaminate semantically distinct rows.
  path: z.enum(['live_api']),
  ended_at: z.string().datetime(),
}).strict();

export const VoiceTurnUsageRequest = z.object({
  session_id: z.string().uuid(),
  turns: z.array(TurnUsage).min(1).max(50),
}).strict()
  // Cross-field invariant: cachedContentTokenCount CANNOT exceed
  // promptTokenCount, because cached tokens are a SUBSET of the prompt
  // tokens served on this turn. A buggy client sending cached > total
  // would produce dashboard ratios > 1.0 (e.g., cap-reversal trigger
  // "cachedContentTokenCount / promptTokenCount ≥ 0.5" fires wrongly).
  // Enforced at the request level rather than at TurnUsage because Zod
  // .refine() on an inner object is still validated per-item when
  // z.array() runs — same effective coverage, cleaner error message.
  .refine(
    (body) =>
      body.turns.every(
        (t) => (t.prompt_tokens_cached ?? 0) <= t.prompt_tokens_total,
      ),
    {
      message: 'prompt_tokens_cached must not exceed prompt_tokens_total',
      path: ['turns'],
    },
  );

export type VoiceTurnUsageRequest = z.infer<typeof VoiceTurnUsageRequest>;

// ---------------------------------------------------------------------------
// /v1/ai/recipe-import (step 7)
// ---------------------------------------------------------------------------
//
// import_id: client-generated UUID. Idempotency key AND the CloudKit
//   RecipeImport row's primary key. A second POST with the same
//   import_id returns the cached response (or 'queued' if async is
//   still processing).
// source_type: one of four strings.
//   - 'url'            : user pasted a URL into the Import Entry screen.
//                        Server fetches HTML, extracts recipe content.
//   - 'share_sheet'    : Safari/social share sheet passed a URL. Same
//                        code path as 'url' BUT kept distinct for
//                        funnel analytics — share_sheet conversion
//                        differs materially from manual paste.
//   - 'screenshot_ocr' : iOS ran Vision OCR client-side and sends text.
//   - 'pasted_text'    : user pasted recipe text directly (free-form).
// payload: shape depends on source_type. Zod refinement below enforces
//   the right shape per source.
// ocr_page_count: required on 'screenshot_ocr'; 0 on other paths. Used
//   to persist RecipeImport.ocrPageCount per spec §4.10.
const UrlImportPayload = z.object({
  url: z.string().url().max(2048),
  ocr_text: z.undefined().optional(),
  pasted_text: z.undefined().optional(),
  ocr_page_count: z.number().int().min(0).max(0).optional(),
}).strict();

const ScreenshotOcrPayload = z.object({
  url: z.undefined().optional(),
  ocr_text: z.string().min(1).max(200_000), // ~50 pages of OCR text
  pasted_text: z.undefined().optional(),
  ocr_page_count: z.number().int().min(1).max(20),
}).strict();

const PastedTextPayload = z.object({
  url: z.undefined().optional(),
  ocr_text: z.undefined().optional(),
  pasted_text: z.string().min(1).max(200_000),
  ocr_page_count: z.number().int().min(0).max(0).optional(),
}).strict();

export const RecipeImportRequest = z.object({
  import_id: z.string().uuid(),
  source_type: z.enum(['url', 'share_sheet', 'screenshot_ocr', 'pasted_text']),
  payload: z.union([UrlImportPayload, ScreenshotOcrPayload, PastedTextPayload]),
}).strict().superRefine((body, ctx) => {
  const s = body.source_type;
  const p = body.payload as {
    url?: string | undefined;
    ocr_text?: string | undefined;
    pasted_text?: string | undefined;
    ocr_page_count?: number | undefined;
  };
  if ((s === 'url' || s === 'share_sheet') && !p.url) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      path: ['payload', 'url'],
      message: `url required when source_type='${s}'`,
    });
  }
  if (s === 'screenshot_ocr') {
    if (!p.ocr_text) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['payload', 'ocr_text'],
        message: "ocr_text required when source_type='screenshot_ocr'",
      });
    }
    if (p.ocr_page_count === undefined || p.ocr_page_count < 1) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['payload', 'ocr_page_count'],
        message: "ocr_page_count must be >= 1 when source_type='screenshot_ocr'",
      });
    }
  }
  if (s === 'pasted_text' && !p.pasted_text) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      path: ['payload', 'pasted_text'],
      message: "pasted_text required when source_type='pasted_text'",
    });
  }
});

export type RecipeImportRequest = z.infer<typeof RecipeImportRequest>;

// ---------------------------------------------------------------------------
// /v1/ai/grocery-generate (step 7)
// ---------------------------------------------------------------------------
//
// source_id: idempotency key. Either a RecipePlan UUID or a CookingSession
//   UUID depending on source_type — iOS reuses the entity's own UUID here.
// source_type: metadata for telemetry only. NOT persisted on GroceryList
//   (spec §4.16 has sourceCookingSessionId but no source_type column).
// ingredients_needed: full set of recipe ingredients to diff against pantry.
// pantry_snapshot: iOS-supplied because backend doesn't mirror user content
//   (CloudKit-only, invariant §3).

const GroceryIngredient = z.object({
  display_name: z.string().min(1).max(128),
  canonical_slug: z.string().min(1).max(128).optional(),
  amount_text: z.string().min(1).max(128).optional(),
}).strict();

const GroceryPantryItem = z.object({
  display_name: z.string().min(1).max(128),
  canonical_slug: z.string().min(1).max(128).optional(),
}).strict();

export const GroceryGenerateRequest = z.object({
  source_id: z.string().uuid(),
  source_type: z.enum(['recipe', 'session', 'leftovers']),
  ingredients_needed: z.array(GroceryIngredient).min(1).max(200),
  pantry_snapshot: z.array(GroceryPantryItem).max(500),
  recipe_title: z.string().min(1).max(256).optional(), // context for model; aids category inference
}).strict();

export type GroceryGenerateRequest = z.infer<typeof GroceryGenerateRequest>;

// ---------------------------------------------------------------------------
// /v1/push/register (step 7)
// ---------------------------------------------------------------------------
//
// APNs token registration + notification prefs upsert. iOS calls on first
// token grant and on every prefs-change. Idempotent by (canonical_user_key,
// environment, apns_token) — re-registering the same token is a no-op UPDATE.
//
// apns_token: 64-hex-char Apple device token. Validated by length + charset.
// environment: 'production' (release) or 'sandbox' (TestFlight + DEBUG).
// notification_prefs: opt-in flags iOS surfaces in Settings → Notifications.
//
// SCA-322: prefs widened to cover every category in `APNsCategory`
// (_shared/apns.ts). Pre-fix `cook_reminder` and `billing_grace`
// (SCA-77) had no opt-out wire path because the schema only knew
// about `import_completion` and `reactivation` — pgmq-dispatch
// silently sent both regardless of user opt-out. Each category an
// iOS user can receive needs a flag here.

const APNS_TOKEN_REGEX = /^[0-9a-fA-F]{64}$/;

export const PushRegisterRequest = z.object({
  apns_token: z.string().regex(APNS_TOKEN_REGEX, 'must be 64 hex characters'),
  environment: z.enum(['production', 'sandbox']),
  notification_prefs: z.object({
    import_completion: z.boolean(),
    reactivation: z.boolean(),
    cook_reminder: z.boolean(),
    billing_grace: z.boolean(),
  }).strict(),
}).strict();

export type PushRegisterRequest = z.infer<typeof PushRegisterRequest>;

// ---------------------------------------------------------------------------
// Zod → FieldError[] helper
// ---------------------------------------------------------------------------

/** Convert a ZodError into the structured field_errors wire format. */
export function zodToFieldErrors(err: ZodError): FieldError[] {
  return err.issues.map((issue: ZodIssue) => ({
    field: issue.path.length > 0 ? issue.path.map(String).join('.') : '<root>',
    issue: issue.message,
  }));
}
