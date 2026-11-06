// Shared shapes for the parity-check run files. `run.ts` writes a RunFile;
// `compare.ts` reads two of them. Kept separate so `compare.ts` never imports
// `run.ts` (which loads the local .env and bootstraps a user on import).

import type { FeatureKey } from './fixtures.ts';

/** The `ai_request_log` columns the parity check compares. */
export interface AiLogRow {
  model: string;
  input_tokens: number;
  output_tokens: number;
  cost_usd: number;
  latency_ms: number;
  retry_count: number | null;
  prompt_version: string | null;
}

export interface DinnerSolveResponse {
  dishes: Array<Record<string, unknown>>;
  errors: Array<Record<string, unknown>>;
  done: Record<string, unknown> | null;
}

export interface RequestRecord {
  feature: FeatureKey;
  fixture: string;
  note: string;
  /** The id the endpoint writes to `ai_request_log.request_id`. */
  request_id: string;
  /** Request body as sent (image base64 replaced by a size marker). */
  request: unknown;
  /** null when the request never got an HTTP response (network error, timeout). */
  http_status: number | null;
  /** Wall-clock ms until response headers arrived (the server's work is done by then). */
  latency_ms: number;
  /** Wall-clock ms until the body was fully read (dinner-solve adds ~150ms per streamed dish). */
  total_ms: number;
  error_code: string | null;
  error_message: string | null;
  cache_hit: boolean;
  /** Parsed JSON body; for dinner_solve a DinnerSolveResponse built from the SSE frames. */
  response: unknown;
  log: AiLogRow | null;
}

export interface RunFile {
  label: string;
  started_at: string;
  finished_at: string;
  functions_url: string;
  notes: string[];
  records: RequestRecord[];
}
