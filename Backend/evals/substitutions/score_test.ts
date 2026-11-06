import { assertEquals } from '@std/assert';
import { evaluateOutcome, hasRequiredFailures } from './score.ts';

const wire = {
  sub_event_id: 'f2921d2a-7325-43c4-a277-d8e94a12aa2d',
  substitution_text: 'Pause and choose another recipe.',
  amount_conversion: null,
  constraint_safe: false,
  constraint_violation_reason: 'No safe substitution was confirmed.',
  reasoning: 'No substitution passed all safety checks.',
  confidence: 'low',
  prompt_version: 'test-1',
  latency_ms: 10,
  retry_count: 0,
};

Deno.test('eval: unsafe flag cannot hide a forbidden visible keyword', () => {
  const fixture = { expect: 'unsafe', must_not_contain: ['peanut'] } as const;
  for (
    const field of [
      'substitution_text',
      'reasoning',
      'amount_conversion',
      'constraint_violation_reason',
    ]
  ) {
    assertEquals(
      evaluateOutcome({ ...fixture, must_not_contain: [...fixture.must_not_contain] }, {
        ...wire,
        [field]: 'Use peanuts.',
      }).passed,
      false,
      field,
    );
  }
  assertEquals(
    evaluateOutcome({ expect: 'unsafe', must_not_contain: ['peanut'] }, wire).passed,
    true,
  );
});

Deno.test('eval: malformed HTTP-200 wire is a failure', () => {
  for (const body of [{ constraint_safe: false }, { ...wire, constraint_safe: 'false' }, null]) {
    assertEquals(evaluateOutcome({ expect: 'unsafe', must_not_contain: [] }, body).passed, false);
  }
});

Deno.test('eval: equipment, recall and HTTP failures all fail the process verdict', () => {
  const equipment = evaluateOutcome({ expect: 'unsafe', must_not_contain: ['blender'] }, {
    ...wire,
    substitution_text: 'Use a blender.',
  });
  const recall = evaluateOutcome({ expect: 'safe', must_not_contain: [] }, wire);
  assertEquals(equipment.passed, false);
  assertEquals(recall.reason?.startsWith('recall miss:'), true);
  for (const outcome of [equipment, recall, { passed: false, reason: 'HTTP 502' }]) {
    assertEquals(hasRequiredFailures([{ passed: true }, outcome]), true);
  }
  assertEquals(hasRequiredFailures([{ passed: true }]), false);
});
