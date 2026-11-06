// Provider-neutral text-model error (ADR 0038). Handlers branch on `status`
// (retry once on >= 500) and log `upstreamStatus` — a PII-safe enum-like
// string (Google `error.status`, Anthropic `error.type`, or a synthetic
// `timeout` / `refusal`). `body` is kept for env-gated dev debugging only;
// it can echo prompt fragments and must never reach default log lines.
export class AITextError extends Error {
  readonly status: number;
  readonly body: string;
  readonly upstreamStatus: string | undefined;
  constructor(status: number, body: string, upstreamStatus: string | undefined, message?: string) {
    super(message ?? `AI text error: ${status}`);
    this.name = 'AITextError';
    this.status = status;
    this.body = body;
    this.upstreamStatus = upstreamStatus;
  }
}
