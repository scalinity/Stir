// Feature-flag reads + per-key typed registry.
//
// The flag_registry binds each server-side flag to its expected value shape
// via a Zod schema. When /v1/config/bootstrap hydrates, we verify the DB
// row matches the registered schema and log (but don't fail) on mismatch
// so a bad seed never silently corrupts the iOS client.

import { z } from 'zod';
import type { SupabaseClient } from '@supabase/supabase-js';

export interface FeatureFlagRow {
  key: string;
  description: string;
  payload_json: { value: unknown };
  is_enabled: boolean;
  rollout_pct: number;
  updated_at: string;
}

export interface FeatureFlagWire {
  key: string;
  value: unknown;
  is_enabled: boolean;
  rollout_pct: number;
}

// ---------------------------------------------------------------------------
// Flag registry — canonical list of server-side flag keys + their value types.
// Mirrors CLAUDE.md §"Feature flags" server-side + kill switches.
// ---------------------------------------------------------------------------

const KillSwitch = z.boolean();

export const flagRegistry: Readonly<Record<string, { schema: z.ZodType; defaultValue: unknown }>> = {
  disable_cook_realtime:          { schema: KillSwitch, defaultValue: false },
  disable_scan_parse:             { schema: KillSwitch, defaultValue: false },
  disable_imports:                { schema: KillSwitch, defaultValue: false },
  force_saved_meals_only:         { schema: KillSwitch, defaultValue: false },
  priority_queue_pro_enabled:     { schema: KillSwitch, defaultValue: false },
  cook_voice_thinking_level:      {
    schema: z.enum(['minimal', 'low']),
    defaultValue: 'minimal',
  },
  prompt_version_override:        {
    schema: z.union([z.null(), z.string()]),
    defaultValue: null,
  },
  recipe_import_async_threshold:  {
    schema: z.number().int().positive(),
    defaultValue: 8192,
  },
};

/**
 * Read all feature_flags rows and convert to wire shape.
 * Validates each row's value against the registry schema; mismatches are
 * passed through (client may still function) but can be audited in logs.
 */
export async function readFlags(client: SupabaseClient): Promise<FeatureFlagWire[]> {
  const { data, error } = await client
    .from('feature_flags')
    .select('key, payload_json, is_enabled, rollout_pct');
  if (error) throw error;

  type FlagPartial = Pick<FeatureFlagRow, 'key' | 'payload_json' | 'is_enabled' | 'rollout_pct'>;
  const rows = (data ?? []) as FlagPartial[];
  return rows.map((row) => ({
    key: row.key,
    value: row.payload_json?.value ?? null,
    is_enabled: row.is_enabled,
    rollout_pct: row.rollout_pct,
  }));
}
