// JUnit XML writer — GitHub Actions + most CI tools render this natively.
// Emits <testsuites><testsuite><testcase>...</testcase></testsuite></testsuites>
// with per-criterion testcase rows so CI shows which thresholds failed.

import type { HarnessResult } from './harness.ts';

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

export function resultsToJUnit(results: HarnessResult[]): string {
  const totalTests = results.reduce((a, r) => a + r.criteria.length, 0);
  const totalFailures = results.reduce(
    (a, r) => a + r.criteria.filter((c) => !c.pass).length,
    0,
  );
  const totalSkipped = results.filter((r) => r.skipped).length;
  const totalTime = results.reduce((a, r) => a + r.duration_ms, 0) / 1000;

  const suites = results.map((r) => {
    const cases = r.criteria.map((c) => {
      const body = c.pass
        ? ''
        : `<failure message="${esc(c.name + ': ' + c.actual + ' vs threshold ' + c.threshold)}">` +
          `actual=${c.actual}${c.unit ? ' ' + c.unit : ''} threshold=${c.threshold}` +
          `</failure>`;
      return `<testcase classname="${esc(r.name)}" name="${esc(c.name)}" time="0">${body}</testcase>`;
    }).join('');

    const skipBlock = r.skipped
      ? `<testcase classname="${esc(r.name)}" name="harness_run" time="0"><skipped message="${esc(r.skip_reason ?? 'skipped')}"/></testcase>`
      : '';

    return `<testsuite name="${esc(r.name)}" tests="${r.criteria.length}" failures="${r.criteria.filter((c) => !c.pass).length}" skipped="${r.skipped ? 1 : 0}" time="${(r.duration_ms / 1000).toFixed(3)}">${skipBlock}${cases}</testsuite>`;
  }).join('');

  return `<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="${totalTests}" failures="${totalFailures}" skipped="${totalSkipped}" time="${totalTime.toFixed(3)}">${suites}</testsuites>
`;
}
