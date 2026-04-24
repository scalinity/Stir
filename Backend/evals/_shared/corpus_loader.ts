// JSONL corpus loader with optional zod validation.

import type { z } from 'zod';

export async function loadJsonl<T>(
  path: URL | string,
  schema?: z.ZodType<T>,
): Promise<T[]> {
  const text = await Deno.readTextFile(path instanceof URL ? path : new URL(path));
  const out: T[] = [];
  let line = 0;
  for (const raw of text.split('\n')) {
    line++;
    const trimmed = raw.trim();
    if (!trimmed || trimmed.startsWith('//') || trimmed.startsWith('#')) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(trimmed);
    } catch (err) {
      throw new Error(`${path}:${line}: JSON parse failed — ${String(err)}`);
    }
    if (schema) {
      try {
        out.push(schema.parse(parsed));
      } catch (err) {
        throw new Error(`${path}:${line}: schema validation failed — ${String(err)}`);
      }
    } else {
      out.push(parsed as T);
    }
  }
  return out;
}
