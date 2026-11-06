// Text-provider parity check — comparison (ADR 0038).
//
// Usage:
//   deno run --config Backend/supabase/functions/deno.json --allow-read --allow-write \
//     Backend/evals/parity/compare.ts <a.json> <b.json> [--md <report.md>]
//
// Prints a per-feature table for both runs, then (with --md) writes a report
// with every fixture's output side by side for a human to judge.
//
// Metric notes:
//   success   HTTP 200. The endpoints Zod-parse the model output and retry
//             once, so a 200 means the output passed its schema; schema or
//             upstream failures after the retry surface as AI-01 / AI-02 /
//             IMPORT-01 (see the error breakdown).
//   clean     200 with retry_count 0 (no schema, upstream or hard-rule retry).
//   latency   wall clock to response headers, 200s only (dinner-solve then
//             streams its dishes ~150ms apart; that pacing is excluded).
//   cost      ai_request_log.cost_usd per call, all calls with a log row.

import { type FeatureKey, FEATURES } from './fixtures.ts';
import type { RequestRecord, RunFile } from './types.ts';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

type Json = Record<string, unknown>;

const obj = (v: unknown): Json => (v !== null && typeof v === 'object' ? v as Json : {});
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const str = (v: unknown): string => (typeof v === 'string' ? v : v == null ? '' : String(v));

function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const s = [...values].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 === 1 ? s[mid]! : (s[mid - 1]! + s[mid]!) / 2;
}

function percentile(values: number[], p: number): number | null {
  if (values.length === 0) return null;
  const s = [...values].sort((a, b) => a - b);
  return s[Math.max(0, Math.ceil(p * s.length) - 1)]!;
}

const ms = (v: number | null) => (v === null ? '-' : `${Math.round(v)}`);
const usd = (v: number | null) => (v === null ? '-' : `$${v.toFixed(6)}`);
const pct = (num: number, den: number) =>
  den === 0 ? '-' : `${num}/${den} (${Math.round((num / den) * 100)}%)`;

function easternTime(iso: string): string {
  return new Date(iso).toLocaleString('en-US', {
    timeZone: 'America/New_York',
    timeZoneName: 'short',
  });
}

function retryCount(r: RequestRecord): number | null {
  const res = obj(r.response);
  const fromBody = r.feature === 'dinner_solve' ? obj(res.done).retry_count : res.retry_count;
  if (typeof fromBody === 'number') return fromBody;
  return r.log?.retry_count ?? null;
}

function promptVersion(r: RequestRecord): string | null {
  const res = obj(r.response);
  const v = r.feature === 'dinner_solve' ? obj(res.done).prompt_version : res.prompt_version;
  return typeof v === 'string' ? v : r.log?.prompt_version ?? null;
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

interface FeatureStats {
  n: number;
  ok: number;
  clean: number;
  models: string[];
  p50: number | null;
  p95: number | null;
  costMean: number | null;
  costTotal: number;
  logged: number;
  errors: string;
  details: string[];
}

function featureStats(feature: FeatureKey, records: RequestRecord[]): FeatureStats {
  const ok = records.filter((r) => r.http_status === 200);
  const logged = records.filter((r) => r.log !== null);
  const costTotal = logged.reduce((sum, r) => sum + r.log!.cost_usd, 0);
  const errorCounts = new Map<string, number>();
  for (const r of records) {
    if (r.http_status !== 200) {
      const code = r.error_code ?? 'unknown';
      errorCounts.set(code, (errorCounts.get(code) ?? 0) + 1);
    }
  }
  const latencies = ok.map((r) => r.latency_ms);
  const retried = ok.filter((r) => (retryCount(r) ?? 0) > 0);
  const details: string[] = [];

  if (feature === 'dinner_solve') {
    const bodies = ok.map((r) => obj(r.response));
    const dishes = bodies.flatMap((b) => arr(b.dishes).map(obj));
    const passing = dishes.filter((d) => d.hard_constraint_pass === true).length;
    const slotErrors = bodies.reduce((sum, b) => sum + arr(b.errors).length, 0);
    const short = bodies.filter((b) => arr(b.dishes).length < 3).length;
    details.push(
      `dishes returned ${dishes.length} (${
        ok.length ? (dishes.length / ok.length).toFixed(1) : '-'
      } per request)`,
      `hard_constraint_pass true on ${pct(passing, dishes.length)} of dishes`,
      `slot errors (AI-02 frames): ${slotErrors}; requests with fewer than 3 dishes: ${short}`,
      `requests that needed a replacement/retry (validator or schema): ${retried.length}`,
    );
  } else if (feature === 'substitution') {
    const safe = ok.filter((r) => obj(r.response).constraint_safe === true).length;
    const blocked = ok.filter((r) => obj(r.response).constraint_safe === false);
    details.push(
      `constraint_safe true on ${pct(safe, ok.length)}`,
      `hard-rule failures (constraint_safe false, canned message): ${blocked.length}` +
        (blocked.length
          ? ` [${
            blocked.map((r) => `${r.fixture}: ${str(obj(r.response).constraint_violation_reason)}`)
              .join('; ')
          }]`
          : ''),
      `retried (schema, upstream or hard-rule): ${retried.length}`,
    );
  } else if (feature === 'recipe_import') {
    const quality = new Map<string, number>();
    for (const r of ok) {
      const q = str(obj(obj(r.response).recipe).parse_quality) || 'unknown';
      quality.set(q, (quality.get(q) ?? 0) + 1);
    }
    details.push(
      `parse_quality: ${[...quality].map(([k, v]) => `${k}=${v}`).join(', ') || '-'}`,
      `retried: ${retried.length}`,
    );
  } else {
    details.push(`retried: ${retried.length}`);
  }

  return {
    n: records.length,
    ok: ok.length,
    clean: ok.length - retried.length,
    models: [...new Set(logged.map((r) => r.log!.model))].sort(),
    p50: median(latencies),
    p95: percentile(latencies, 0.95),
    costMean: logged.length ? costTotal / logged.length : null,
    costTotal,
    logged: logged.length,
    errors: [...errorCounts].map(([k, v]) => `${k} x${v}`).join(', '),
    details,
  };
}

// ---------------------------------------------------------------------------
// Rendering of inputs and outputs (for the side-by-side report)
// ---------------------------------------------------------------------------

function names(list: unknown): string {
  return arr(list).map((i) => str(obj(i).display_name)).join(', ');
}

function rules(ctx: unknown): string {
  const r = arr(obj(ctx).dietary_rules).map(obj);
  return r.length
    ? r.map((x) => `${str(x.kind)}:${str(x.value)}/${str(x.severity)}`).join(', ')
    : 'none';
}

function describeInput(r: RequestRecord): string {
  const b = obj(r.request);
  switch (r.feature) {
    case 'dinner_solve':
      return `ingredients: ${names(b.ingredients)}\nrules: ${
        rules(b.household_context)
      }; equipment: ${
        arr(obj(b.household_context).available_equipment).join(', ') || 'none'
      }; servings ${str(obj(b.household_context).servings)}` +
        (b.constraints ? `\nconstraints: ${JSON.stringify(b.constraints)}` : '') +
        (b.context_hint ? `\ncontext_hint: ${str(b.context_hint)}` : '');
    case 'substitution':
      return `missing: ${str(obj(b.missing_ingredient).display_name)}; problem: "${
        str(b.user_problem)
      }"\nrules: ${rules(b.household_context)}; pantry: ${
        names(obj(b.household_context).pantry_snapshot) || 'empty'
      }\nrecipe: ${str(obj(b.recipe_context).title)}, step ${
        str(obj(b.recipe_context).current_step_number)
      }`;
    case 'recipe_step_rewrite':
      return `step: "${str(b.step_instruction_text)}"\n${str(b.original_ingredient)} -> ${
        str(b.substitute_ingredient)
      }` + (b.amount_conversion ? ` (${str(b.amount_conversion)})` : '');
    case 'cook_turn': {
      const ctx = obj(b.recipe_context);
      return `transcript: "${str(b.transcript)}"\nrecipe: ${str(ctx.title)}, step ${
        str(b.current_step_number)
      }: ${str(ctx.current_step_text)}\nrules: ${rules(b.household_context)}`;
    }
    case 'recipe_import':
      return truncate(str(obj(b.payload).pasted_text), 280);
    case 'grocery_generate':
      return `needed: ${names(b.ingredients_needed)}\npantry: ${
        names(b.pantry_snapshot) || 'empty'
      }`;
    case 'pantry_parse':
      return r.note;
  }
}

function truncate(s: string, max: number): string {
  return s.length > max ? `${s.slice(0, max - 1)}\u2026` : s;
}

function describeOutput(r: RequestRecord): string {
  if (r.http_status !== 200) {
    return `ERROR ${r.error_code ?? ''}: ${truncate(r.error_message ?? '', 200)}`;
  }
  const res = obj(r.response);
  switch (r.feature) {
    case 'dinner_solve': {
      const out = arr(res.dishes).map(obj).map((d) => {
        const plan = obj(d.recipe_plan);
        return `#${str(d.rank)} ${str(d.title)} (${
          str(d.total_time_minutes)
        } min, hard_constraint_pass=${str(d.hard_constraint_pass)}, missing ${
          str(d.missing_ingredient_count)
        }) ${truncate(str(d.why_it_fits), 160)}\n  ingredients: ${
          truncate(names(plan.ingredients), 220)
        }\n  ${arr(plan.steps).length} steps`;
      });
      for (const e of arr(res.errors).map(obj)) {
        out.push(`slot error: rank ${str(e.rank)} ${str(e.code)}`);
      }
      return out.join('\n');
    }
    case 'substitution':
      return `${res.constraint_safe === true ? 'SAFE' : 'BLOCKED'} (${str(res.confidence)}): ${
        truncate(str(res.substitution_text), 300)
      }` + (res.amount_conversion ? `\nconversion: ${str(res.amount_conversion)}` : '') +
        `\nreasoning: ${truncate(str(res.reasoning), 240)}` +
        (res.constraint_violation_reason
          ? `\nviolation: ${str(res.constraint_violation_reason)}`
          : '');
    case 'recipe_step_rewrite':
      return truncate(str(res.rewritten_text), 500);
    case 'cook_turn':
      return `${truncate(str(res.spoken_response), 400)}\naction: ${str(res.suggested_action)}${
        res.action_params ? ` ${JSON.stringify(res.action_params)}` : ''
      }`;
    case 'recipe_import': {
      const recipe = obj(res.recipe);
      const ingredients = arr(recipe.ingredients).map(obj).map((i) =>
        `${str(i.amount_text)} ${str(i.display_name)}`.trim()
      );
      const steps = arr(recipe.steps).map(obj).map((s) =>
        `${str(s.step_number)}. ${str(s.instruction_text)}`
      );
      return `${str(recipe.title)} (servings ${str(recipe.servings)}, ${
        str(recipe.estimated_minutes)
      } min, quality ${str(recipe.parse_quality)})\n${ingredients.length} ingredients: ${
        truncate(ingredients.join('; '), 260)
      }\n${steps.length} steps: ${truncate(steps.join(' '), 320)}` +
        (arr(recipe.edit_hints).length ? `\nedit_hints: ${arr(recipe.edit_hints).join(', ')}` : '');
    }
    case 'grocery_generate': {
      const missing = arr(res.missing_items).map(obj).map((i) =>
        `${str(i.display_name)}${i.amount_text ? ` (${str(i.amount_text)})` : ''} [${
          str(i.grocery_category)
        }]`
      );
      return `missing ${missing.length}: ${truncate(missing.join('; '), 360)}\nalready have: ${
        truncate(names(res.already_have), 160)
      }`;
    }
    case 'pantry_parse':
      return `${arr(res.ingredients).length} ingredients (confidence ${
        str(res.overall_confidence)
      }): ${truncate(names(res.ingredients), 360)}`;
  }
}

// ---------------------------------------------------------------------------
// Console + markdown
// ---------------------------------------------------------------------------

function loadRun(path: string): RunFile {
  const run = JSON.parse(Deno.readTextFileSync(path)) as RunFile;
  if (!Array.isArray(run.records)) throw new Error(`${path} is not a parity run file`);
  return run;
}

function table(rows: string[][]): string {
  const widths = rows[0]!.map((_, c) => Math.max(...rows.map((r) => r[c]!.length)));
  return rows.map((r) => r.map((cell, c) => cell.padEnd(widths[c]!)).join('  ').trimEnd()).join(
    '\n',
  );
}

const cell = (s: string) => truncate(s, 1200).replaceAll('|', '\\|').replaceAll('\n', '<br>');

function recordsByFeature(run: RunFile, feature: FeatureKey): RequestRecord[] {
  return run.records.filter((r) => r.feature === feature);
}

function main(): void {
  const positional: string[] = [];
  let mdPath: string | null = null;
  for (let i = 0; i < Deno.args.length; i++) {
    const a = Deno.args[i]!;
    if (a === '--md') mdPath = Deno.args[++i] ?? null;
    else positional.push(a);
  }
  if (positional.length !== 2 || (Deno.args.includes('--md') && !mdPath)) {
    console.error('usage: compare.ts <a.json> <b.json> [--md <report.md>]');
    Deno.exit(2);
  }
  const [a, b] = [loadRun(positional[0]!), loadRun(positional[1]!)];
  const runs = [a, b];

  const warnings: string[] = [];
  const statsByFeature = new Map<FeatureKey, [FeatureStats, FeatureStats]>();
  const rows: string[][] = [[
    'feature',
    'run',
    'n',
    'success',
    'clean',
    'p50 ms',
    'p95 ms',
    '$/call',
    '$ total',
    'model',
  ]];

  for (const spec of FEATURES) {
    const [ra, rb] = [recordsByFeature(a, spec.key), recordsByFeature(b, spec.key)];
    if (ra.length === 0 && rb.length === 0) continue;
    const sa = featureStats(spec.key, ra);
    const sb = featureStats(spec.key, rb);
    statsByFeature.set(spec.key, [sa, sb]);
    runs.forEach((run, i) => {
      const s = i === 0 ? sa : sb;
      rows.push([
        i === 0 ? spec.key : '',
        run.label,
        String(s.n),
        pct(s.ok, s.n),
        pct(s.clean, s.n),
        ms(s.p50),
        ms(s.p95),
        usd(s.costMean),
        usd(s.costTotal),
        s.models.join(',') || '-',
      ]);
    });
    if (sa.models.length && sa.models.join() === sb.models.join()) {
      warnings.push(
        `${spec.key}: both runs used the same model (${
          sa.models.join(', ')
        }); the provider switch may not have taken effect (was the stack restarted?).`,
      );
    }
    if (sa.n !== sb.n) warnings.push(`${spec.key}: run sizes differ (${sa.n} vs ${sb.n}).`);
    for (const r of [...ra, ...rb]) {
      if (r.cache_hit) {
        warnings.push(`${spec.key}/${r.fixture}: response came from the idempotency cache.`);
      }
    }
    for (const r of ra) {
      const other = rb.find((x) => x.fixture === r.fixture);
      if (!other) {
        warnings.push(`${spec.key}/${r.fixture}: missing from run ${b.label}.`);
        continue;
      }
      const [pa, pb] = [promptVersion(r), promptVersion(other)];
      if (pa && pb && pa !== pb) {
        warnings.push(`${spec.key}/${r.fixture}: prompt_version differs (${pa} vs ${pb}).`);
      }
    }
  }

  console.log(`A: ${a.label}  (${easternTime(a.started_at)})`);
  console.log(`B: ${b.label}  (${easternTime(b.started_at)})\n`);
  console.log(table(rows));
  console.log('');
  for (const [feature, pair] of statsByFeature) {
    pair.forEach((s, i) => {
      console.log(`${feature} / ${runs[i]!.label}`);
      for (const line of s.details) console.log(`  ${line}`);
      if (s.errors) console.log(`  errors: ${s.errors}`);
      if (s.logged < s.n) console.log(`  ai_request_log rows found for ${s.logged}/${s.n} calls`);
    });
  }
  if (warnings.length) {
    console.log('\nWarnings');
    for (const w of warnings) console.log(`  - ${w}`);
  }

  if (mdPath) {
    Deno.writeTextFileSync(mdPath, markdown(a, b, statsByFeature, rows, warnings));
    console.log(`\nwrote ${mdPath}`);
  }
}

function markdown(
  a: RunFile,
  b: RunFile,
  statsByFeature: Map<FeatureKey, [FeatureStats, FeatureStats]>,
  rows: string[][],
  warnings: string[],
): string {
  const out: string[] = ['# Text-provider parity report', ''];
  out.push(
    `- **A:** ${a.label} \u2014 ${easternTime(a.started_at)} to ${easternTime(a.finished_at)}`,
    `- **B:** ${b.label} \u2014 ${easternTime(b.started_at)} to ${easternTime(b.finished_at)}`,
    '',
    "Metrics: success = HTTP 200 (output passed the endpoint's Zod schema); clean = 200 with no retry; latency = " +
      'wall clock to response headers over 200s; cost = `ai_request_log.cost_usd` per call.',
    '',
    '## Summary',
    '',
    `| ${rows[0]!.join(' | ')} |`,
    `|${rows[0]!.map(() => '---').join('|')}|`,
    ...rows.slice(1).map((r) => `| ${r.map(cell).join(' | ')} |`),
    '',
  );
  if (warnings.length) {
    out.push('## Warnings', '', ...warnings.map((w) => `- ${w}`), '');
  }
  out.push('## Feature details', '');
  for (const [feature, pair] of statsByFeature) {
    out.push(`### ${feature}`, '');
    [a, b].forEach((run, i) => {
      const s = pair[i]!;
      out.push(`- **${run.label}**`);
      for (const line of s.details) out.push(`  - ${line}`);
      if (s.errors) out.push(`  - errors: ${s.errors}`);
    });
    out.push('');
  }

  out.push('## Outputs side by side', '');
  for (const spec of FEATURES) {
    const [ra, rb] = [recordsByFeature(a, spec.key), recordsByFeature(b, spec.key)];
    if (ra.length === 0 && rb.length === 0) continue;
    out.push(`### ${spec.key}`, '');
    const fixtureNames = [...new Set([...ra, ...rb].map((r) => r.fixture))];
    for (const name of fixtureNames) {
      const x = ra.find((r) => r.fixture === name);
      const y = rb.find((r) => r.fixture === name);
      const ref = (x ?? y)!;
      out.push(
        `#### ${name}`,
        '',
        `_${ref.note}_`,
        '',
        '**Input**',
        '',
        '```',
        describeInput(ref),
        '```',
        '',
      );
      const meta = (r?: RequestRecord) =>
        r
          ? `${r.http_status ?? 'ERR'} \u00B7 ${r.latency_ms} ms \u00B7 ${
            usd(r.log?.cost_usd ?? null)
          } \u00B7 ${r.log?.model ?? '-'} \u00B7 retries ${retryCount(r) ?? '-'}`
          : 'not run';
      out.push(
        `| A: ${cell(a.label)} | B: ${cell(b.label)} |`,
        '|---|---|',
        `| ${cell(meta(x))} | ${cell(meta(y))} |`,
        `| ${cell(x ? describeOutput(x) : '')} | ${cell(y ? describeOutput(y) : '')} |`,
        '',
      );
    }
  }
  return out.join('\n');
}

main();
