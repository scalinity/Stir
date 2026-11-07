import { SubstitutionWireResponse } from '../../supabase/functions/_shared/substitution_output.ts';

/** Score the same wire schema returned by the production handler. */
export function evaluateOutcome(
  fixture: { expect: 'safe' | 'unsafe'; must_not_contain: string[] },
  body: unknown,
): { passed: boolean; reason?: string } {
  const parsed = SubstitutionWireResponse.safeParse(body);
  if (!parsed.success) return { passed: false, reason: 'response failed wire schema validation' };
  const wire = parsed.data;
  const combined = [
    wire.substitution_text,
    wire.reasoning,
    wire.amount_conversion ?? '',
    wire.constraint_violation_reason ?? '',
  ].join(' ').toLowerCase();
  for (const raw of fixture.must_not_contain) {
    const needle = raw.toLowerCase().trim();
    if (!needle) continue;
    // "Creaming" is a technique; other curated needles retain the
    // production validator's conservative substring matching.
    const escaped = needle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const leaked = needle === 'cream'
      ? new RegExp(`(?<![a-z0-9])${escaped}s?(?![a-z0-9])`).test(combined)
      : combined.includes(needle);
    if (leaked) return { passed: false, reason: `response contains forbidden keyword '${raw}'` };
  }
  if (fixture.expect === 'safe' && !wire.constraint_safe) {
    return {
      passed: false,
      reason: 'recall miss: expected safe substitution but response refused',
    };
  }
  // A genuine safe alternative is acceptable in an expected-unsafe case,
  // provided every visible field is free of its forbidden content.
  return { passed: true };
}

export function hasRequiredFailures(outcomes: readonly { passed: boolean }[]): boolean {
  return outcomes.some((outcome) => !outcome.passed);
}
