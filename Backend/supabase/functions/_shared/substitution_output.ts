// Shared production/evaluation boundary for substitution output.
import { z } from 'zod';

export const SubstitutionOutput = z.object({
  substitution_text: z.string().min(1).max(400),
  amount_conversion: z.string().max(400).nullable().optional(),
  constraint_safe: z.boolean(),
  constraint_violation_reason: z.string().max(400).nullable().optional(),
  reasoning: z.string().min(1).max(400),
  confidence: z.enum(['high', 'medium', 'low']),
});

export type ParsedSubstitution = z.infer<typeof SubstitutionOutput>;

export const SubstitutionWireResponse = SubstitutionOutput.extend({
  sub_event_id: z.string().uuid(),
  amount_conversion: z.string().max(400).nullable(),
  constraint_violation_reason: z.string().max(400).nullable(),
  prompt_version: z.string().min(1),
  latency_ms: z.number().int().nonnegative(),
  retry_count: z.number().int().nonnegative(),
});

/** Neither the model nor the keyword validator can overrule a refusal. */
export function finalizeSubstitution(candidate: ParsedSubstitution, rulesPassed: boolean) {
  if (candidate.constraint_safe && rulesPassed) {
    return {
      ...candidate,
      amount_conversion: candidate.amount_conversion ?? null,
      constraint_violation_reason: null,
    };
  }
  // Never echo rejected model prose, including its violation reason.
  return {
    substitution_text:
      "That substitution can't be made safely — skip this ingredient or pause to pick another recipe.",
    amount_conversion: null,
    constraint_safe: false,
    constraint_violation_reason: 'No safe substitution was confirmed.',
    reasoning: 'No substitution passed all safety checks.',
    confidence: 'low' as const,
  };
}
