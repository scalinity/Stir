// Active-prompt reader.
//
// "Active" = is_default AND is_enabled. Each feature_key has exactly one
// active row; config-bootstrap returns the full set so iOS can log
// prompt_version in telemetry.
//
// Handlers call readActivePrompt() to hydrate template text + metadata.
// If multiple rows match (should never happen thanks to the seed
// invariant), the highest `version` wins.

import type { SupabaseClient } from '@supabase/supabase-js';

export interface ActivePrompt {
  feature_key: string;
  version: string;
  provider_model: string;
  template_blob: string;
  schema_hash: string;
  rollout_pct: number;
}

/**
 * Wire-format row for `/v1/config/bootstrap` prompts[] response. Slimmer
 * than ActivePrompt (no template_blob, no rollout_pct) because iOS only
 * needs the metadata for telemetry. Moved here from `config-bootstrap/
 * index.ts` in the step-5 review to keep prompts-table shapes in one
 * searchable location.
 */
export interface PromptWireRow {
  feature_key: string;
  version: string;
  provider_model: string;
  schema_hash: string;
  is_default: boolean;
  is_enabled: boolean;
}

/**
 * Read the active prompt for a feature. Returns null if no enabled
 * default row exists (e.g. a feature whose prompt is still placeholder
 * at v0.0.0 with is_enabled=false).
 */
export async function readActivePrompt(
  client: SupabaseClient,
  featureKey: string,
): Promise<ActivePrompt | null> {
  const { data, error } = await client
    .from('prompt_versions')
    .select('feature_key, version, provider_model, template_blob, schema_hash, rollout_pct')
    .eq('feature_key', featureKey)
    .eq('is_default', true)
    .eq('is_enabled', true)
    .order('version', { ascending: false })
    .limit(1)
    .maybeSingle<ActivePrompt>();
  if (error) throw error;
  return data;
}

/** Markers wrapping untrusted user-supplied text in the rendered prompt.
 * The substitution prompt template instructs the model to treat anything
 * between these markers as literal user data, never as instructions.
 * Defense-in-depth for indirect prompt injection (SA1-01); the hard-rule
 * validator is still the primary safety defense on output.
 */
export const USER_DATA_START = '<<<USER_DATA_START>>>';
export const USER_DATA_END = '<<<USER_DATA_END>>>';

export interface RenderPromptOptions {
  /** Keys in the context that should be wrapped in USER_DATA markers
   *  because their value is user-controlled free text. Raw-string values
   *  for these keys flow in unstructured; JSON-stringified values for
   *  these keys are structurally escaped by JSON.stringify so no wrapping
   *  is needed (but we wrap anyway for consistency when explicitly listed).
   *  Non-listed keys render unchanged.
   */
  untrusted?: ReadonlySet<string>;
}

/**
 * Render a prompt template by substituting {{placeholder}} tokens with
 * stringified JSON context.
 *
 * Intentionally simple — not Handlebars, not Mustache. {{ and }} are
 * the only delimiters; missing placeholders leave the literal token in
 * place (surfaces bugs visibly in telemetry). Values are JSON-stringified
 * so structured context doesn't get mangled.
 *
 * Keys listed in `options.untrusted` are wrapped in USER_DATA markers
 * after having any instance of the marker delimiters stripped from the
 * value (defense against a user crafting input that mimics the close
 * marker to escape the fence).
 */
export function renderPrompt(
  template: string,
  context: Record<string, unknown>,
  options: RenderPromptOptions = {},
): string {
  const untrusted = options.untrusted ?? EMPTY_SET;
  return template.replace(/\{\{(\w+)\}\}/g, (_match, key: string) => {
    if (key in context) {
      const v = context[key];
      const rendered = typeof v === 'string' ? v : JSON.stringify(v);
      if (untrusted.has(key)) {
        // Strip any occurrence of the marker delimiters from the value
        // so a user can't close the fence and inject unfenced text.
        // Three-tuple replace — the closing and opening markers are
        // syntactically distinct but both must be scrubbed.
        const sanitized = rendered.replaceAll(USER_DATA_START, '').replaceAll(USER_DATA_END, '');
        return `${USER_DATA_START}${sanitized}${USER_DATA_END}`;
      }
      return rendered;
    }
    return `{{${key}}}`;
  });
}

const EMPTY_SET: ReadonlySet<string> = new Set<string>();
