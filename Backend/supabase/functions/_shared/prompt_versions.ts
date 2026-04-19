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

/**
 * Render a prompt template by substituting {{placeholder}} tokens with
 * stringified JSON context.
 *
 * Intentionally simple — not Handlebars, not Mustache. {{ and }} are
 * the only delimiters; missing placeholders leave the literal token in
 * place (surfaces bugs visibly in telemetry). Values are JSON-stringified
 * so structured context doesn't get mangled.
 */
export function renderPrompt(
  template: string,
  context: Record<string, unknown>,
): string {
  return template.replace(/\{\{(\w+)\}\}/g, (_match, key: string) => {
    if (key in context) {
      const v = context[key];
      if (typeof v === 'string') return v;
      return JSON.stringify(v);
    }
    return `{{${key}}}`;
  });
}
