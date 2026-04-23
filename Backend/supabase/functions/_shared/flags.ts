// Feature-flag reads + per-key typed registry.
//
// The flag_registry binds each server-side flag to its expected value shape
// via a Zod schema. readFlags() validates every row's value against the
// registered schema and logs mismatches at warn severity — the row is still
// passed through (client may still function on a malformed value) so a bad
// seed can't hard-fail bootstrap, but the log line surfaces it in dashboards.

import { z, type ZodIssue } from 'zod';
import type { SupabaseClient } from '@supabase/supabase-js';
import type { Logger } from './logger.ts';

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
  voice_turn_detection_mode:      {
    schema: z.enum(['semantic_vad', 'server_vad']),
    defaultValue: 'semantic_vad',
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
 * Read all feature_flags rows and convert to wire shape. Every row's value
 * is validated against the registry schema when a registry entry exists;
 * mismatches are logged at warn severity (so bad seeds surface in the
 * logs pipeline) but still emitted on the wire so a schema drift can't
 * hard-fail bootstrap. Unknown keys (not in the registry) are also logged
 * but returned — they let us ship new flags without a code round-trip.
 */
export async function readFlags(
  client: SupabaseClient,
  log?: Logger,
): Promise<FeatureFlagWire[]> {
  const { data, error } = await client
    .from('feature_flags')
    .select('key, payload_json, is_enabled, rollout_pct');
  if (error) throw error;

  type FlagPartial = Pick<FeatureFlagRow, 'key' | 'payload_json' | 'is_enabled' | 'rollout_pct'>;
  const rows = (data ?? []) as FlagPartial[];
  return rows.map((row) => {
    const value = row.payload_json?.value ?? null;
    const entry = flagRegistry[row.key];
    if (!entry) {
      log?.warn('flag_unknown_key', { key: row.key });
    } else {
      const parsed = entry.schema.safeParse(value);
      if (!parsed.success) {
        log?.warn('flag_value_schema_mismatch', {
          key: row.key,
          value,
          issues: parsed.error.issues.map((issue: ZodIssue) => ({
            path: issue.path.map(String).join('.'),
            message: issue.message,
          })),
        });
      }
    }
    return {
      key: row.key,
      value,
      is_enabled: row.is_enabled,
      rollout_pct: row.rollout_pct,
    };
  });
}
