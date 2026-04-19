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
//   Full server-to-server CK verification is deferred — see spec §12 and
//   CLAUDE.md §"Deferred". Optional — absent on local-only users.
// build: iOS build string, e.g. "1.0.0 (42)". Required for telemetry.
// os_version: iOS version string, e.g. "17.5.1". Required for telemetry.

const UUID_V4_REGEX =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/;
const CK_RECORD_NAME_REGEX = /^_[a-f0-9]{32}$/;

export const SessionBootstrapRequest = z.object({
  installation_id: z.string().regex(UUID_V4_REGEX, 'must be a UUID v4'),
  cloudkit_user_record_name: z.string()
    .regex(CK_RECORD_NAME_REGEX, 'must match `_` + 32 lowercase hex chars')
    .optional(),
  build: z.string().min(1).max(64),
  os_version: z.string().min(1).max(64),
}).strict();

export type SessionBootstrapRequest = z.infer<typeof SessionBootstrapRequest>;

// ---------------------------------------------------------------------------
// /v1/config/bootstrap (no body; GET with JWT)
// ---------------------------------------------------------------------------
// Placeholder: future GETs may accept query params (e.g. ?include=prompts,flags)
// to trim the payload. Step 1 returns everything unconditionally.

// ---------------------------------------------------------------------------
// /v1/ai/pantry-parse (step 3)
// ---------------------------------------------------------------------------
//
// image_base64: JPEG/HEIC/PNG/WebP image, ≤ ~6MB decoded. Zod validates
//   length; the handler validates decoded MIME + byte size after base64
//   decode (cheaper to let Zod catch obviously-oversized strings first).
// client_request_id: idempotency key; 10-min cache.
// image_count: step-3 supports only 1. Multi-image is Pro-tier and
//   returns ENT-MULTI-IMAGE-01 when >1 on non-Pro; UI lands in step 7.
// household_profile_hash: optional — if present, a cache miss is also
//   forced when the caller's household changed between requests. Not
//   used in step 3 cache lookup (keyed on request_id only); future-proofs
//   the shape.

// ~6MB raw → ~8MB base64. Cap at 10MB of base64 as a hard ceiling.
const IMAGE_BASE64_MAX = 10 * 1024 * 1024;

export const PantryParseRequest = z.object({
  client_request_id: z.string().uuid(),
  image_base64: z.string().min(100).max(IMAGE_BASE64_MAX),
  image_mime_type: z.enum(['image/jpeg', 'image/png', 'image/heic', 'image/webp']),
  image_count: z.number().int().min(1).max(8).optional(),
  household_profile_hash: z.string().min(1).max(128).optional(),
}).strict();

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

export const DinnerSolveRequest = z.object({
  solve_request_id: z.string().uuid(),
  parse_id: z.string().uuid().optional(),
  ingredients: z.array(IngredientLite).min(1).max(200),
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
}).strict();

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

export const SubstitutionRequest = z.object({
  sub_event_id: z.string().uuid(),
  cooking_session_id: z.string().uuid(),
  recipe_plan_id: z.string().uuid(),
  missing_ingredient: MissingIngredient,
  user_problem: z.string().min(1).max(500),
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
  }).strict(),
}).strict();

export type SubstitutionRequest = z.infer<typeof SubstitutionRequest>;

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
