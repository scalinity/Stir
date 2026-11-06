# ADR 0038: AI providers — Claude for text, OpenAI Realtime for voice, Gemini kept as a text fallback

- **Status**: Proposed
- **Date**: 2026-11-06
- **Owner-step**: standing (post-step-9 beta)
- **Supersedes**: CLAUDE.md north-star #1 ("Single AI vendor: Google Gemini"); ADR 0014 (session refresh is the pruning mechanism) for the voice path; ADR 0006 context (Gemini Live mint) is historical only. **Amends**: ADR 0010 (output cap maps to the OpenAI session cap), ADR 0015 (cost model inputs; caps unchanged).
- **Related**: ADR 0009 (PostHog LLM observability), ADR 0012 (TTFA gates), ADR 0013 (token-accounting grains), ADR 0017 (voice_session_owners), ADR 0025 (eval harness), ADR 0027 (telemetry schema), `_shared/ai_text.ts`, `_shared/claude.ts`, `_shared/gemini.ts`, `_shared/ai_request_log.ts`, `_shared/live_mint.ts`, `realtime-session/index.ts`, `Stir/Integrations/GeminiLive/`

## Context

Three forces reopen the single-vendor rule:

1. **Promotional credits.** Credits are held on both the Anthropic and OpenAI platforms. Amounts and expiry dates were not recorded; the runway is unknown.
2. **Gemini model shutdowns.** Google's deprecations page (retrieved 2026-11-06) lists `gemini-3.1-flash-lite-preview` (recipe import, grocery, pgmq recipe import) as shut down on **2026-05-25**, and `gemini-3.1-flash-live-preview` (voice) as shutting down on **2026-11-17**. `gemini-3-flash-preview` has no shutdown date. Two of the three production models are gone or about to be.
3. **No Anthropic voice API.** Anthropic's models page lists text and image input only; independent coverage (2026-09-29, 2026-10-10) confirms no realtime audio API. Voice must run on OpenAI or on a speech-to-text → Claude → text-to-speech pipeline.

Prod volume could not inform the choice: `ai_request_log` on `ktqajarcomzplnpbczfo` is empty (hourly `stir-cleanup-ai-request-log` purge) and one user was seen in the last 90 days. Five of the six eval harnesses are stubs (ADR 0025); only `eval:substitutions` has a corpus (50 cases).

## Decision

1. **Text runs on the Claude API.** Default model `claude-haiku-5-5`; a feature moves to `claude-sonnet-5-5` only when the parity check (below) shows Haiku failing it. Calls go through the official SDK (`npm:@anthropic-ai/sdk`), structured output through `output_config.format` (`json_schema`), never forced `tool_choice` and never prefill. Every response is checked for `stop_reason: "refusal"` and `max_tokens` before its content is read.
2. **One server-side selection, no per-request fallback.** The secret `AI_TEXT_PROVIDER` ∈ {`anthropic`, `gemini`} (default `anthropic`) picks the text provider for every endpoint. Gemini text stays callable behind it with the dead Lite ID replaced by `gemini-3.1-flash-lite` (shutdown 2027-05-07). There is no cross-vendor retry chain.
3. **Voice runs on OpenAI Realtime, `gpt-realtime-2.1-mini`, over WebSocket.** The backend mints a short-lived client secret (`POST /v1/realtime/client_secrets`); iOS connects to `wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini` with it. Gemini Live is removed: its model shuts down on 2026-11-17 and keeping a second voice client on iOS is not worth an untested `gemini-3.8-live` port. `disable_cook_realtime` still routes voice to the C.3 on-device fallback with `AI-VOICE-01`.
4. **Bounded growth uses server truncation, not refresh.** OpenAI Realtime caches the conversation prefix automatically (cached audio input $0.30/M on mini); a refresh opens a new session and discards that cache, which is the dominant voice cost lever. The session sets `truncation` with a `retention_ratio` and `token_limits.post_instructions`, and refresh is kept only as a reconnect for the session's maximum duration and transport recovery. The invariant from ADR 0014 — per-turn prompt tokens stay bounded — holds.
5. **Official SDKs are an accepted exception** to the Edge Function "no npm deps unless unavoidable" rule: `npm:@anthropic-ai/sdk@1.3.0` and `npm:openai` (pinned) through `npm:` specifiers, for typed errors and correct request shapes.
6. **Caps and prices are unchanged** (free 0 / Premium 13 / Pro 27 voice sessions). The cost model below is recomputed; changing caps or prices is a separate decision.

## Alternatives considered

- **GPT-Live 1 for voice** ($0.05/min, full-duplex, delegates to any backend model including Claude). Rejected: it bills every second the session is open, and Cook Mode holds the voice session from entry to dismiss (`CookModeRoot.buildVoiceDriver` → `RealtimeSession.preWarm`). A 30-minute cook costs $1.50 in voice time alone; Premium at 13 sessions would be ~$19.50/mo against a $9.99 price. Revisit if Cook Mode moves to open-on-ask sessions.
- **`gpt-realtime-2.1` (full) for voice.** Rejected on cost: modelled ~$0.29 per 15-turn session with caching (Premium ~$3.82/mo, 2× the $1.89 budget; erases the Pro annual margin). Its tool-use score is higher (Artificial Analysis agentic 38.0% vs mini 22.5%). It is the escalation path if mini misses tool calls in device testing.
- **Speech-to-text → Claude → text-to-speech pipeline.** Rejected: two more vendors, added latency, and a second set of turn-taking bugs.
- **GPT-6 Luna for text.** Same price as Haiku 5.5 ($0.10 / $0.50 per 1M, $0.01 cached) but lower on the Artificial Analysis Intelligence Index at every effort (low 10 vs 19, medium 18 vs 25). Rejected; credits exist on both platforms.
- **Keep Gemini voice behind `AI_VOICE_PROVIDER` on `gemini-3.8-live`.** Rejected: keeps ~6k lines of Gemini Live client on iOS and needs a full new validation pass for a model the app has never run.
- **Remove Gemini entirely.** Rejected: the credits are finite, and keeping the text path behind one secret costs one client file.
- **WebRTC transport.** Rejected: needs a third-party WebRTC framework on iOS. OpenAI recommends WebRTC for mobile robustness; WebSocket is supported and keeps `URLSessionWebSocketTask`.

## Consequences

### Positive

- Text cost per token drops ~5× (Haiku 5.5 $0.10 / $0.50 vs Gemini Flash $0.50 / $3.00 per 1M).
- Voice can cost less than Gemini Live did, because OpenAI caches the prefix and bills fewer audio tokens per second (10/s user, 20/s model vs Gemini's 25/25).
- Recipe import and grocery work again (their Gemini model was shut down).

### Negative

- Two vendors, two SDKs, two bills. North-star #1 becomes "Claude for text, OpenAI for voice."
- Voice margin depends on the cache hit rate, which OpenAI calls best-effort. It must be measured per turn (`response.done.usage.input_token_details.cached_tokens`) and watched.
- `gpt-realtime-2.1-mini` scores slightly below Gemini 3.1 Flash Live on tool use (22.5% vs 26.2%). Device testing must cover every tool.
- The evals cannot score five of six features; the parity check is weaker evidence than a corpus.

### Tradeoffs

- Taking a cheaper, slightly weaker voice model and measuring it, over a stronger one that doubles the AI budget.

## Cost model (inputs from ADR 0014's measured token shapes, prices below)

Assumptions: 15 turns, 3 tool-call turns, 3,300-token static text prefix, 3.8 s user speech and 5.0 s model speech per turn, input transcription on.

| Voice option | 15-turn session, 90% cache hits | no caching | Premium 13 / Pro 27 per month (cached) |
| --- | ---: | ---: | --- |
| Gemini 3.1 Flash Live (measured, retiring) | $0.13–0.16 | n/a | $1.69–2.08 / $3.51–4.32 |
| `gpt-realtime-2.1-mini` | $0.085 | $0.254 | $1.11 / $2.31 |
| `gpt-realtime-2.1` | $0.294 | $0.944 | $3.82 / $7.93 |

When the credits run out, these rates are what Stir pays; voice on mini stays inside the Premium $1.89 and Pro $3.69 AI budgets only while the cache hit rate holds.

## Sources (retrieved 2026-11-06 UTC through the self-hosted Firecrawl platform)

| Fact | Source |
| --- | --- |
| Claude prices (Haiku 5.5 $0.10 / $0.50, cache hit $0.01, prompts ≤100K; Sonnet 5.5 $2 / $10, cache hit $0.10; Opus 5.5 $4 / $20) | https://platform.claude.com/docs/en/about-claude/pricing.md |
| Claude models, modalities (no audio) | https://platform.claude.com/docs/en/about-claude/models/overview.md |
| OpenAI text prices (GPT-6 Luna $0.10 / $0.50, cached $0.01) and realtime prices (2.1-mini audio $10 / $20, cached $0.30; text $0.60 / $2.40, cached $0.06; 2.1 audio $32 / $64, cached $0.40) | https://platform.openai.com/docs/pricing ; https://developers.openai.com/api/docs/models/gpt-realtime-2.1-mini.md ; https://developers.openai.com/api/docs/models/gpt-6-luna.md |
| GPT-Live 1 billing ($0.05/min, per second, includes silence) | https://developers.openai.com/api/docs/models/gpt-live-1.md ; https://developers.openai.com/api/docs/guides/voice-latency-cost.md |
| Realtime audio token rates (user 1 per 100 ms, model 1 per 50 ms), automatic caching, truncation, `conversation.item.delete` | https://developers.openai.com/api/docs/guides/voice-latency-cost.md |
| WebSocket connection and ephemeral key on the socket | https://developers.openai.com/api/docs/guides/voice-websockets.md ; https://developers.openai.com/api/docs/guides/voice-webrtc.md |
| Speech-to-speech benchmarks (agentic, speech reasoning, time to first audio) | https://artificialanalysis.ai/speech-to-speech |
| Text-model Intelligence Index by effort | https://artificialanalysis.ai/leaderboards/models |
| Gemini shutdown dates | https://ai.google.dev/gemini-api/docs/deprecations |
| No Anthropic realtime voice API | https://postcutoff.com/e/2026-07-23-claude-voice-mode-opus-sonnet/ ; https://www.testingcatalog.com/anthropic-might-be-developing-its-own-voice-models/ |

## Notes

- The parity check, per feature: run Gemini and each Claude candidate on the same inputs, require schema-valid output and a clean hard-rule validator pass, compare outputs side by side, and score `eval:substitutions` (100% hard-rule pass required). Results and the per-feature model table are recorded here when the check runs.
- Measurement that keeps this decision honest: cache hit ratio on voice turns, tool-call success per tool, TTFA against the ADR 0012 gates.
- **Text prompt caching is off.** Every text system prompt is a template rendered with household context, so it differs per user and a prefix cache would mostly write (Haiku cache writes cost 1.25× input) and rarely read; with one active user in the last 90 days the saving is zero. Revisit when traffic exists, by putting the static template prefix in its own cached block ahead of the rendered context.
- **Wire additions, both backward-compatible:** the dinner-solve `done` SSE frame carries `model` (iOS reports it as `dinner_solve_completed.model` instead of a hard-coded literal); `/v1/ai/voice-turn-usage` turns accept optional `prompt_tokens_cached_audio`, because OpenAI prices cached audio and cached text differently. `config-bootstrap` reports `provider_model` from the live selection.
- **Gemini text fallback limits.** The fallback keeps `gemini-3-flash-preview`, which has no announced shutdown but is a preview model; check Google's deprecations page before flipping `AI_TEXT_PROVIDER=gemini`.
- **Prod smoke, 2026-11-06.** A throwaway function deployed to `ktqajarcomzplnpbczfo` (deleted the same session) ran the shared clients against the prod secrets:
  - Claude Haiku 5.5 structured output: `end_turn`, schema-valid JSON, 223 in / 8 out tokens, 1.3 s.
  - OpenAI client-secret mint: `ek_` secret, 120 s window, 0.74 s. `session.created` echoed the config as minted (model, `reasoning.effort: minimal`, `max_output_tokens: 400`, voice `marin`, PCM 24 kHz, `semantic_vad`, `gpt-transcribe`, `far_field`, all eight tools); the setup frame's `session.updated` echoed the truncation policy; one `response.create` completed with audio, and `usage` carried `cached_tokens_details` split by text and audio.
  - **The prod `GEMINI_API_KEY` is rejected** (`400 INVALID_ARGUMENT` on `gemini-3-flash-preview`). Until it is replaced, prod text features fail on the pre-0038 code, and `AI_TEXT_PROVIDER=gemini` is not a working fallback.
