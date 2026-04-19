// Zod schemas for Edge Function request bodies.
//
// Every handler parses the request body through the relevant schema before
// touching the database. Failures surface as VAL-01 with structured
// field_errors for Sentry debugging on the iOS side.

import { z, ZodError } from 'zod';
import type { FieldError } from './errors.ts';

// ---------------------------------------------------------------------------
// /v1/session/bootstrap
// ---------------------------------------------------------------------------
//
// installation_id: UUID v4 generated in iOS keychain. Required.
// cloudkit_user_record_name: Opaque CloudKit userRecordName (e.g. `_abc...`).
//   Optional — absent on local-only users.
// build: iOS build string, e.g. "1.0.0 (42)". Required for telemetry.
// os_version: iOS version string, e.g. "17.5.1". Required for telemetry.

export const SessionBootstrapRequest = z.object({
  installation_id: z.string().uuid(),
  cloudkit_user_record_name: z.string().min(1).max(256).optional(),
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
// Zod → FieldError[] helper
// ---------------------------------------------------------------------------

/** Convert a ZodError into the structured field_errors wire format. */
export function zodToFieldErrors(err: ZodError): FieldError[] {
  return err.issues.map((issue) => ({
    field: issue.path.length > 0 ? issue.path.map(String).join('.') : '<root>',
    issue: issue.message,
  }));
}
