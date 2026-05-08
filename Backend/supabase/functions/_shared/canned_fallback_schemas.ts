// canned_fallback_schemas.ts
//
// SCA-81 — per-feature shape validation for canned_fallback_json
// payloads pinned by ops admins. Before this, ops-admin's
// FlaggedOutputsResolveParams accepted any JSON object within a
// 64 KiB cap; an admin pasting a dinner_solve response into a
// substitution row would land in ai_response_cache.response_body
// and break iOS decode on the next cache hit.
//
// The validator is deliberately a top-level-key allowlist rather
// than a full-fidelity Zod schema:
//
//   * Allowlists are robust to handler-side wire-shape evolution
//     (a new optional field doesn't break old fallbacks).
//   * They catch the big foot-gun: pasting the wrong feature's
//     response shape entirely. That's the failure mode the audit
//     ticket described.
//   * Full Zod schemas per feature would need per-field validation
//     against shapes that already exist in iOS Codable + handler
//     code. Maintaining a third copy of each shape would add drift
//     surface (3 places to update on every wire change). Pragmatic
//     v1: top-level allowlist; ratchet to deeper validation if
//     beta surfaces a foot-gun the allowlist missed.
//
// Reference shapes (confirmed in handler code):
//
//   pantry_parse:        { items: [...] }
//   dinner_solve:        { events: [...] }   (NDJSON-shaped solve events)
//   substitution:        { suggestion, why, ... }
//   recipe_import:       { import_id, status: 'completed', recipe } | { import_id, status: 'queued' }
//   grocery_generate:    { items: [...], reminders_export_url? }
//   cook_turn:           { reply_text, intent }
//   cook_mode_realtime:  // Live API audio chunks; not cache-replayable.
//                        // Allowlist marks it as "no canned fallback supported"
//                        // (ops admin should use action='dismissed' or
//                        // 'withdrawn' for this feature_key).

export type FeatureKey =
  | 'pantry_parse'
  | 'dinner_solve'
  | 'substitution'
  | 'recipe_import'
  | 'grocery_generate'
  | 'cook_turn'
  | 'cook_mode_realtime';

interface ShapeRule {
  /** At least one of these top-level keys must be present. */
  requiredAnyOf: string[];
  /** Allowed top-level keys (superset of `requiredAnyOf`). */
  allowed: ReadonlySet<string>;
  /**
   * Marker: when true, the feature_key does not support a canned
   * fallback (e.g. live-streaming voice). Validation hard-rejects
   * any payload regardless of shape.
   */
  unsupported?: boolean;
}

const RULES: Record<FeatureKey, ShapeRule> = {
  pantry_parse: {
    requiredAnyOf: ['items'],
    allowed: new Set(['items', 'image_count', 'parse_quality']),
  },
  dinner_solve: {
    requiredAnyOf: ['events'],
    allowed: new Set(['events']),
  },
  substitution: {
    requiredAnyOf: ['suggestion'],
    allowed: new Set([
      'suggestion',
      'why',
      'confidence',
      'alternative_suggestions',
      'latency_ms',
      'cost_usd',
    ]),
  },
  recipe_import: {
    requiredAnyOf: ['import_id'],
    allowed: new Set(['import_id', 'status', 'recipe', 'error']),
  },
  grocery_generate: {
    requiredAnyOf: ['items'],
    allowed: new Set(['items', 'reminders_export_url']),
  },
  cook_turn: {
    requiredAnyOf: ['reply_text'],
    allowed: new Set(['reply_text', 'intent', 'confidence', 'latency_ms']),
  },
  cook_mode_realtime: {
    requiredAnyOf: [],
    allowed: new Set(),
    unsupported: true,
  },
};

export interface CannedFallbackValidationError {
  field: string;
  issue: string;
}

/**
 * Validate a canned_fallback_json payload against the per-feature
 * top-level-key allowlist. Returns an empty array on success; otherwise
 * one or more {field, issue} entries suitable for VAL-01 field_errors
 * propagation.
 *
 * Caller (handleFlaggedOutputsResolve) should refuse the resolve if
 * the result is non-empty.
 */
export function validateCannedFallback(
  featureKey: string,
  payload: Record<string, unknown>,
): CannedFallbackValidationError[] {
  if (!isKnownFeatureKey(featureKey)) {
    return [{
      field: 'feature_key',
      issue: `unknown feature_key '${featureKey}' — extend canned_fallback_schemas.ts`,
    }];
  }
  const rule = RULES[featureKey];

  if (rule.unsupported) {
    return [{
      field: 'canned_fallback_json',
      issue:
        `feature_key '${featureKey}' does not support canned fallbacks; use action='dismissed' or 'withdrawn'`,
    }];
  }

  const errors: CannedFallbackValidationError[] = [];

  // Reject unknown top-level keys.
  for (const key of Object.keys(payload)) {
    if (!rule.allowed.has(key)) {
      errors.push({
        field: `canned_fallback_json.${key}`,
        issue: `unknown top-level key for feature_key '${featureKey}'; allowed: ${
          [...rule.allowed].join(', ')
        }`,
      });
    }
  }

  // Require at least one anchor key.
  const hasRequired = rule.requiredAnyOf.some((k) => k in payload);
  if (!hasRequired && rule.requiredAnyOf.length > 0) {
    errors.push({
      field: 'canned_fallback_json',
      issue: `missing required key for feature_key '${featureKey}'; need at least one of: ${
        rule.requiredAnyOf.join(', ')
      }`,
    });
  }

  return errors;
}

function isKnownFeatureKey(key: string): key is FeatureKey {
  return key in RULES;
}
