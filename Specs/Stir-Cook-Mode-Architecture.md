# Stir — Cook Mode Realtime Research

Validated reference for implementing Cook Mode voice on **Google Gemini 3.1 Flash Live Preview** at `thinkingLevel: minimal`. Supersedes the earlier OpenAI `gpt-realtime-mini` research draft after the decision to consolidate on a single AI vendor (Google Gemini).

Last validated: April 17, 2026.

**Post-spike corrections (April 19, 2026 — step 6 scope-confirmation).** The April 2026 Gemini Live spike findings updated CLAUDE.md but not all sections below. Where this doc disagrees with CLAUDE.md §"Gemini Live — the sharp-edges section" or spec §10 entitlement table, **CLAUDE.md wins**. Known corrections:

| Section | Doc says | Correct |
|---|---|---|
| §3, §8 | Mint path `/v1beta/auth-tokens` | `/v1alpha/authTokens` (CLAUDE.md #14) |
| §3 | `Authorization: Bearer <token>` | `Authorization: Token <token>` (CLAUDE.md #13) |
| §3 | `turn_coverage: TURN_INCLUDES_ALL_INPUT` | `TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO` (new default post-spike) |
| §3, §8 | `voice_cook_sessions` (plural) | `voice_cook_session` (singular) — matches DB enum `usage_feature_key` |
| §5, §8 | Pro voice cap = 60/mo | 40/mo (spec §10 entitlement table + CLAUDE.md cost model) |
| §8 | `disable_cook_realtime` → `{ error: 'DISABLED' }` | `{ error: 'AI-VOICE-01' }` (spec §6 error-code matrix) |
| §6 | `preamble_present: bool` as a `cook_turn_resolved` PostHog property | Not in spec §15. Track via Sentry breadcrumbs + backend audio-transcript analysis, not a wire property. |

Substantive sections below are otherwise current as of the spike.

---

## 1. Model and pricing (validated)

**Model:** `gemini-3.1-flash-live-preview`
**Thinking level:** `minimal` (Live API default; optimized for lowest time-to-first-audio)

**Pricing (per 1M tokens, Google AI paid tier):**

| Modality | Input | Output | Cache |
| --- | --- | --- | --- |
| Text | $0.75 | $4.50 | not supported |
| Audio | $3.00 | $12.00 | not supported |
| Image / Video | $0.75 | — | not supported |

**Token metering (audio):**
- Both directions: **25 tokens/second** (1 token per 40ms)
- User audio input: 5s utterance → ~125 input tokens
- Assistant audio output: 6s response → ~150 output tokens

**Context window:** 131,072 tokens
**Function calling:** supported with streaming
**Structured outputs:** supported via `responseSchema`, but not needed for Live — Stir uses typed function calls instead
**Caching:** **not supported** for the Live API — this is the defining cost-control constraint. All cost control relies on explicit context pruning.

**Supported transports:** **WebSocket** (primary, stable). No first-class WebRTC support.

**Data policy:** Paid tier content is not used to improve Google's products.

**Preview status:** The Live API is still labeled Preview as of April 2026. Mitigated via `disable_cook_realtime` kill switch that falls all Premium+ voice traffic back to the text path (Speech STT → Gemini 3 Flash text → AVSpeechSynthesizer).

---

## 2. Cost model for Stir Cook Mode

**The context-accumulation problem.** Unlike OpenAI Realtime, Gemini Live does not bill cached input at a discount — caching is not supported at all. Every turn re-sends accumulated conversation context at full audio input rate. This makes aggressive context pruning the single most important cost-control lever.

**Pruning strategy:** after every step advance, the iOS client issues `session.update` events that truncate audio items older than the last 3 turns. This caps steady-state per-turn input context at ~950 audio tokens regardless of session length.

**Per-turn cost (Premium/Pro, steady-state after pruning reaches cap):**

| Component | Formula | Per turn |
| --- | --- | --- |
| New user audio input | 125 tokens × $3/1M | $0.000375 |
| Carried context audio (3 prior turns × 275 tokens) | 825 × $3/1M | $0.002475 |
| System prompt text input | 1000 × $0.75/1M | $0.000750 |
| Output audio | 150 tokens × $12/1M | $0.001800 |
| **Total per turn** | | **~$0.00540** |

**Per session / per user:**

| Scope | Turns | Cost |
| --- | --- | --- |
| One Cook Session (15 turns) | 15 | $0.081 |
| Premium user (20 sessions/mo) | 300 | **$1.62/mo** |
| Pro user (60 sessions/mo) | 900 | **$4.86/mo** |

Voice Cook Mode is ~95% of total Premium AI cost and ~99% of Pro AI cost. Runaway voice cost is the single most likely way unit economics break.

**Cost levers (v1):**
- `max_output_tokens: 150` at session config — caps assistant audio length per turn, eliminates long-monologue failure modes
- Aggressive pruning to last 3 turns via `session.update` — dominant cost lever
- Session refresh at 10 min / 15 turns — hard reset prevents long sessions from blowing context budget
- `thinkingLevel: minimal` — lowest latency tier, avoids paying for unnecessary reasoning on conversational routing tasks
- Semantic VAD (start) → server VAD (fallback) — semantic VAD avoids tokenizing ambient kitchen noise as speech

**Cost levers (not used in v1):**
- Prompt caching — not supported by the Live API; no mitigation path
- Batch API — not applicable to streaming voice

**Operational monitoring:**
- `voice_session_token_snapshot` event emitted every 5 turns logging cumulative tokens — catches pruning regressions early
- Alert: `voice_session_tokens_p95 > 50K` → pruning is failing or sessions are not being refreshed

---

## 3. Endpoints

**Ephemeral token mint (server-side via Supabase Edge Function):**

Gemini Live supports short-lived auth tokens minted from the main API key. The Stir backend mints one ephemeral token per Cook Session; the client uses it to open a WebSocket directly to Gemini, scoped to a single session.

```
POST https://generativelanguage.googleapis.com/v1beta/auth-tokens
x-goog-api-key: <main Gemini API key>
Content-Type: application/json

{
  "authToken": {
    "expire_time": "<ISO 8601 timestamp, ~5 min in future>",
    "new_session_expire_time": "<ISO 8601 timestamp, ~1 min in future>",
    "uses": 1,
    "bidi_generate_content_setup": {
      "model": "models/gemini-3.1-flash-live-preview",
      "generation_config": {
        "response_modalities": ["AUDIO"],
        "speech_config": { "voice_config": { "prebuilt_voice_config": { "voice_name": "Aoede" } } },
        "max_output_tokens": 150,
        "thinking_config": { "thinking_level": "minimal" }
      },
      "system_instruction": "<Cook Mode system prompt>",
      "tools": [{ "function_declarations": [ <tool definitions> ] }],
      "realtime_input_config": {
        "automatic_activity_detection": { "disabled": false },
        "turn_coverage": "TURN_INCLUDES_ALL_INPUT"
      }
    }
  }
}

→ { "name": "authTokens/<id>", "token": "<bearer value>", "expireTime": "..." }
```

Key constraints:
- `uses: 1` — token can be used to open exactly one session
- `new_session_expire_time` — token must be used to open a session within ~60 seconds
- `expire_time` — session itself must conclude before this (used as a backstop beyond the natural 30-min session limit)
- Session config is baked into the token at mint time — the Gemini API key stays server-side and never reaches the client

**Client connect (WebSocket):**

```
wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent
Authorization: Bearer <ephemeral token>
```

First client message after connect is the `BidiGenerateContentSetup` frame (or it's pre-baked via the token's `bidi_generate_content_setup` field, as shown above). Audio frames follow as `BidiGenerateContentRealtimeInput`.

---

## 4. Transport choice (WebSocket is the only serious option)

**Gemini Live does not offer first-class WebRTC** the way OpenAI does. The supported transport is WebSocket, and that's what client SDKs (Python `google-genai`, JS `@google/genai`) wrap.

**This is a real difference from the OpenAI path.** WebRTC's UDP + jitter buffers + adaptive bitrate are valuable in mobile network conditions — TCP-based WebSocket has head-of-line blocking and doesn't adapt bitrate. For Stir's cooking-in-home-Wi-Fi common case this is rarely noticed; for cellular or marginal Wi-Fi it will show as occasional audio stalls.

**Mitigation:**
- iOS client uses `URLSessionWebSocketTask` (native, zero external dependency, tight integration with URLSession's connectivity monitoring)
- Automatic reconnect-with-backoff on transient drops (single retry, then fall through to `AI-VOICE-01` text fallback)
- Network quality monitoring via `NWPathMonitor`; if the user drops to cellular mid-session, surface a soft banner suggesting they keep the phone near the router

**Transport comparison (for the record):**

| Axis | Gemini Live WebSocket | OpenAI Realtime WebRTC (rejected option) |
| --- | --- | --- |
| Voice-to-voice TTFA (prod reports) | 250–500ms | 220–450ms |
| Mobile network resilience | TCP head-of-line blocking | UDP + jitter buffers |
| Audio pipeline | Manual PCM16 frames | Peer connection handles it |
| iOS library footprint | 0 MB (URLSessionWebSocketTask) | 20–40 MB (WebRTC.xcframework) |
| Implementation complexity | Low | Medium-high |
| Reconnect story | Manual, native primitives | WebRTC ICE restart |
| Fits Google SDK direction | Yes | No |

Net: Gemini Live's WebSocket-only story is materially less resilient on cellular than OpenAI Realtime's WebRTC, and slightly higher TTFA on production measurements. Accepted for v1 given the all-Google stack decision.

**iOS implementation notes:**
- Use native `URLSessionWebSocketTask` — no SDK needed for bare-bones usage
- Audio input: capture via `AVAudioEngine` → PCM16 at 16kHz → base64-encode → send as `realtimeInput.audio` frames
- Audio output: receive `serverContent.modelTurn.parts[].inlineData` frames → base64-decode → feed to `AVAudioEngine` output node
- Barge-in: detect user speech start (local VAD or server VAD events) → emit `clientContent.turnComplete: false` to cancel current response
- The Python/JS `google-genai` SDKs are convenient reference implementations for protocol shape but not shipping on iOS

---

## 5. Session lifecycle

**Session initialization:**
1. iOS app opens Cook Mode (voice) → requests ephemeral token from Supabase `/v1/ai/realtime-session`
2. Supabase Edge Function:
   - Validates session JWT
   - Checks voice entitlement (Premium+) — if missing, returns `403 ENT-VOICE-01`
   - Checks voice Cook Session quota (20/mo Premium, 60/mo Pro) — if exceeded, returns `429 RATE-01`
   - Builds session config (system prompt with current recipe/step/pantry/rules, tool definitions, thinking_level, voice, max_output_tokens)
   - Calls Gemini `auth-tokens` endpoint with baked-in session config
   - Returns `{ auth_token, expires_at, session_id }` to the client
3. iOS app opens WebSocket to Gemini with the ephemeral token as Bearer auth
4. Session is ready; user can speak immediately (no further setup handshake needed — config was baked into the token)

**Protocol messages (client → server):**
- `BidiGenerateContentRealtimeInput` — audio frames (PCM16 base64)
- `BidiGenerateContentClientContent` — inject a text or tool-response item
- `session.update` — update system instruction or tool list mid-session (used for step advance, timer completion, pruning audio items older than last 3 turns)

**Protocol messages (server → client):**
- `serverContent.modelTurn.parts[].inlineData` — streamed audio chunks
- `serverContent.modelTurn.parts[].text` — transcripts and tool-adjacent text
- `toolCall.functionCalls[]` — function call emissions
- `serverContent.turnComplete` — turn finished
- `serverContent.interrupted` — user barge-in detected (server VAD)

**Session duration limits:**
- Maximum session duration: **30 minutes** (hard Gemini Live limit)
- Idle disconnect: **15 minutes** (connection closes if no input activity)
- Context window: **131K tokens** — effectively non-binding when pruning is enforced
- Cumulative turn count guidance: refresh at **15 turns** to prevent context pathologies even within the token budget

**Session refresh pattern for long Cook Sessions:**

Cook Sessions can legitimately run 30–45+ minutes (slow-roast a chicken, bake bread). Strategy:

1. App tracks elapsed session time and cumulative turn count
2. At **~10 minutes** elapsed **or** **~15 turns**, whichever comes first: app initiates a refresh
3. Refresh sequence:
   - Compress last 4 turns into a short summary string
   - Request new ephemeral token via Supabase `/v1/ai/realtime-session` with updated session config containing: current step, timer state, pending substitutions, turn summary
   - Open new WebSocket
   - Close old WebSocket after new one has confirmed its first response
   - User-facing: silent handoff; no banner unless refresh fails (in which case fall back to text path with `AI-VOICE-01`)
4. Token/cost telemetry emits `voice_session_refreshed` with `refresh_reason = turns | minutes | tokens`

The **10-minute / 15-turn** cadence is more aggressive than OpenAI's 22–25 minute pattern because Gemini lacks caching — pruning keeps per-turn input tokens bounded but the marginal-cost curve still rises with session length, and refreshing is essentially free.

---

## 6. Function calling behavior — the preamble difference from OpenAI

**Tool Call Preambles must be explicitly requested in the system prompt.** This is a behavioral divergence from OpenAI's `gpt-realtime` family and a known area of risk.

**The problem (unchanged from the OpenAI-era spec):** When the model emits a function call for substitutions, the round-trip to Supabase `/v1/ai/substitution` (Gemini 3 Flash + hard-rule validator, ~2s p95) creates dead air between the user's question and the model's spoken answer.

**The pattern (still applicable):** Instruct the model to speak a short neutral filler ("Let me check", "One moment") simultaneously with emitting the function call. The filler audio plays during the ~2s backend round-trip; when the function result arrives, the model speaks the substantive answer.

**The Gemini-specific wrinkle — spontaneity is weaker.** From deepsense.ai's GPT-vs-Gemini native audio comparison (late 2025):

> [gpt-realtime] Spontaneously inserts context-aware filler phrases (e.g., "Let me check on that…") while processing, masking latency and feeling highly human.
>
> [Gemini 2.5 Flash native audio] Lacks spontaneous filler words, resulting in dead air during processing.

Gemini 3.1 Flash Live is a generational improvement over 2.5 Flash native audio, but the preamble behavior has not been independently benchmarked as reliably spontaneous. **Stir treats preambles as an explicitly prompted pattern, not an emergent behavior**, and monitors preamble-present rate in eval and production telemetry.

**Implementation:**

1. **System prompt level** (applies to all tool calls):
   > Before calling any tool, you MUST first say one short, neutral filler line from this list out loud: "Let me check", "One moment", "Give me a second", "Let me look at that". Then call the tool immediately. Do not imply success or failure in the filler. This is required — never call a tool silently.

2. **Tool description level** (per-tool reinforcement):
   ```json
   {
     "name": "substitution_check",
     "description": "Check safe substitutions for a missing ingredient. Before calling this tool, you MUST first say a short filler out loud like \"Let me see what'll work\" or \"Let me check that\". Never call this tool without speaking first.",
     "parameters": { ... }
   }
   ```

3. **Telemetry validation**:
   - `cook_turn_resolved` event includes `preamble_present: bool` (derived from whether an audio transcript segment was emitted before the `toolCall` frame)
   - Dashboard: `preamble_present_rate` across all tool-call turns
   - Target: **≥95%** in eval, **≥90%** in production
   - Alert: drops below 90% over 30 min → rollback prompt version to last known good

**Example user experience for Stir:**

Without preamble (failure mode):
```
User: "I'm out of butter"
[2.0s dead air — function call round-trip]
Model: "You can use olive oil instead, 3/4 the amount."
```

With preamble (target):
```
User: "I'm out of butter"
Model: "Let me check" (spoken ~0.4s after user stops)
[0.4s–2.0s: function call executing in parallel with filler audio]
Model: "Olive oil will work — use 3/4 the amount, everything else stays the same."
```

**Mandatory client-side mitigation (ships regardless of spike outcome):** the iOS client plays one of three pre-recorded neutral filler clips ("Let me check", "One moment", "Give me a second") the instant a `toolCall` frame arrives, independent of any model-emitted preamble. This covers the ~2s backend round-trip deterministically and is the primary UX-correctness mechanism. The prompt-level preamble instruction is best-effort polish on top — if model emits its own filler, the client clip can be suppressed or overlapped cleanly. If spike shows model preamble rate <90% at MINIMAL, disable the model preamble via system prompt entirely and rely on the client clip alone (avoids double-speak).

**Secondary fallback if latency spikes beyond pre-recorded clip length:** surface a client-side visual "thinking" affordance (animated dot) that appears when a function call is in flight, so users have a non-audio signal too. Defense in depth, not a substitute.

---

## 7. Cook Mode system prompt template (v1 draft)

Stored as `prompt_versions` row with `feature_key=cook_mode_realtime`, `version=1.0.0`, `model_pin=gemini-3.1-flash-live-preview`.

```
You are Stir, a voice cooking assistant helping the user cook a specific recipe in real time.

# Current recipe
{recipe.title}
Servings: {recipe.servings}
Total time: {recipe.estimatedMinutes} minutes

# Current step
Step {currentStep.number} of {totalSteps}: {currentStep.instructionText}
{if currentStep.timerSeconds}Timer for this step: {currentStep.timerSeconds}s.{/if}

# Ingredients on hand
{pantrySnapshot.confirmedItems}

# Dietary rules (hard constraints, never violate)
{householdProfile.hardRules}

# Style
- Answer in 1–2 short sentences. This is a kitchen, not a classroom.
- Ground answers in the current step. If the user asks about a future step, briefly point forward but stay focused.
- For questions about doneness, spoilage, or food safety: never claim certainty. Suggest visual, smell, or temperature cues instead.
- Never invent substitutions. If the user asks for a substitution, call the `substitution_check` tool — do not improvise.
- If the user asks about allergens, refer to the recipe and pantry; do not infer.

# Tool use — REQUIRED BEHAVIOR
- Before calling ANY tool, you MUST first say one short, neutral filler line out loud from this list: "Let me check", "One moment", "Give me a second", "Let me look at that".
- Then call the tool immediately. Do not imply success or failure in the filler.
- Never call a tool silently. Speaking the filler first is a hard requirement.
- Approved tools: `substitution_check`, `start_timer`, `advance_step`.

# Safety
- For raw meat, eggs, or reheating leftovers, include a brief cue about internal temperature or visible doneness.
- If the user says they feel unwell, stop cooking advice and suggest they stop and take care of themselves.
```

**Tools (v1 definitions):**

```json
[
  {
    "name": "substitution_check",
    "description": "Check safe ingredient substitutions against the current recipe and the user's dietary rules. Before calling this tool, you MUST first say a short filler out loud like \"Let me see what'll work\" or \"Let me check that\". Never call this tool without speaking first.",
    "parameters": {
      "type": "object",
      "properties": {
        "missing_ingredient": { "type": "string" },
        "user_problem": { "type": "string", "description": "Verbatim or paraphrased user statement" }
      },
      "required": ["missing_ingredient"]
    }
  },
  {
    "name": "start_timer",
    "description": "Start a timer for the current or upcoming step. Before calling, say 'Starting timer now'.",
    "parameters": {
      "type": "object",
      "properties": {
        "seconds": { "type": "integer" },
        "label": { "type": "string" }
      },
      "required": ["seconds"]
    }
  },
  {
    "name": "advance_step",
    "description": "Move to the next step when the user says they're done with the current one. No preamble needed — this is instantaneous.",
    "parameters": { "type": "object", "properties": {} }
  }
]
```

**Client-side handling of `substitution_check`:**
1. Receive `toolCall.functionCalls[]` frame
2. POST to Supabase `/v1/ai/substitution` with: missing ingredient, current recipe, pantry snapshot, hard rules
3. Supabase runs Gemini 3 Flash + hard-rule validator, returns `{ substitution_text, constraint_safe: true/false, reasoning }`
4. Client sends back to Live session via `BidiGenerateContentClientContent` with a `functionResponse` turn
5. Model automatically generates an audio response speaking the result (no explicit `response.create` needed — Gemini Live auto-continues after function response)
6. Model speaks the validated substitution

If `constraint_safe: false`, the function output includes a canned safety message explaining the violation (e.g., "That substitution contains peanuts, which is listed as an allergy"), and the model speaks that instead.

---

## 8. Supabase integration notes

**Edge Function: `ai-realtime-session`**

```typescript
// POST /v1/ai/realtime-session
// Input: session JWT (from /v1/session/bootstrap) + recipe context in body
// Output: { auth_token, expires_at, session_id }

export default async function handler(req: Request) {
  const jwt = await verifySessionJWT(req);
  const userKey = jwt.canonical_user_key;

  // Entitlement check — voice is Premium+
  const ent = await getEntitlement(userKey);
  if (!ent.has_voice_cook_mode) {
    return json({ error: 'ENT-VOICE-01' }, 403);
  }

  // Quota check — voice Cook Sessions per month
  const { used, cap } = await getUsage(userKey, 'voice_cook_sessions');
  if (used >= cap) {
    return json({ error: 'RATE-01' }, 429);
  }

  // Build session config
  const recipeContext = await req.json();
  const systemPrompt = buildCookModePrompt(recipeContext);
  const tools = COOK_MODE_TOOLS;

  const now = new Date();
  const sessionOpenDeadline = new Date(now.getTime() + 60_000);   // must open within 60s
  const sessionHardDeadline = new Date(now.getTime() + 35 * 60_000); // 35 min backstop

  // Mint ephemeral token
  const mint = await fetch(
    'https://generativelanguage.googleapis.com/v1beta/auth-tokens',
    {
      method: 'POST',
      headers: {
        'x-goog-api-key': Deno.env.get('GEMINI_API_KEY')!,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        authToken: {
          expire_time: sessionHardDeadline.toISOString(),
          new_session_expire_time: sessionOpenDeadline.toISOString(),
          uses: 1,
          bidi_generate_content_setup: {
            model: 'models/gemini-3.1-flash-live-preview',
            generation_config: {
              response_modalities: ['AUDIO'],
              speech_config: {
                voice_config: {
                  prebuilt_voice_config: { voice_name: 'Aoede' }
                }
              },
              max_output_tokens: 150,
              thinking_config: { thinking_level: 'minimal' }
            },
            system_instruction: { parts: [{ text: systemPrompt }] },
            tools: [{ function_declarations: tools }],
            realtime_input_config: {
              automatic_activity_detection: { disabled: false },
              turn_coverage: 'TURN_INCLUDES_ALL_INPUT'
            }
          }
        }
      }),
    }
  );

  if (!mint.ok) {
    const errText = await mint.text();
    await logMintFailure(userKey, mint.status, errText);
    return json({ error: 'AI-01' }, 502);
  }

  const { token, expireTime } = await mint.json();

  // Increment quota + log for cost observability
  await incrementUsage(userKey, 'voice_cook_sessions');
  await logRealtimeSessionStart(userKey, recipeContext.recipe_id);

  return json({
    auth_token: token,
    expires_at: expireTime,
    session_id: crypto.randomUUID(),
  });
}
```

**Edge Function: `ai-substitution` (unchanged, but note dual invocation)**

Called in two contexts:
1. Directly from the Substitution Sheet (all tiers — standalone UX)
2. As the handler for Live session `substitution_check` function calls (Premium+ only, proxied through the iOS client)

Input and output shapes are identical. The hard-rule validator runs on the output regardless of invocation path.

**Feature flags that affect this function:**
- `disable_cook_realtime` — when true, the function returns `{ error: 'DISABLED' }` immediately; client falls back to text path with `AI-VOICE-01` banner
- `cook_voice_thinking_level` — `minimal` (default) or `low` (escalation path if reasoning proves insufficient in eval)
- `voice_turn_detection_mode` — `semantic_vad` (default) or `server_vad` (fallback if semantic VAD misfires in kitchen noise)

---

## 9. Fallback path (when Live API unavailable)

Triggered by: token mint failure, WebSocket connect failure, mid-session drop with failed reconnect, or `disable_cook_realtime` flag active.

UX: `AI-VOICE-01` banner appears ("Voice mode running in reduced quality — still here to help.")

Pipeline:
1. iOS app switches to native `SFSpeechRecognizer` for STT
2. Transcribed text POSTed to Supabase `/v1/ai/cook-turn` (Gemini 3 Flash, text in / text out)
3. Text response returned
4. `AVSpeechSynthesizer` speaks it (Enhanced or Premium voice depending on device)

Latency: p95 ~2.5s total round-trip (vs 250–500ms TTFA on Live API). Acceptable as degraded mode, not primary.

**Full Gemini outage (both Live and text):** Cook Mode becomes read-only — step progression via tap works, timers work, but no AI-mediated Q&A or substitutions. Substitution Sheet goes inert with "AI unavailable, try again later" copy.

---

## 10. Validation checklist before building

- [ ] curl `POST /v1beta/auth-tokens` with `model: "models/gemini-3.1-flash-live-preview"` and confirm 200 response with `token` field
- [ ] Verify ephemeral token opens WebSocket to `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`
- [ ] Verify token with `uses: 1` rejects on second use
- [ ] Verify `new_session_expire_time` enforces the 60-second open window
- [ ] Verify `expire_time` terminates the session at the hard deadline even mid-turn
- [ ] Test `session.update` event mid-session prunes audio items older than last 3 turns, confirmed by next-turn input token count
- [ ] Test function call preamble pattern end-to-end: filler audio transcript frame arrives before `toolCall` frame
- [ ] Measure `preamble_present_rate` across 120-turn eval set — target ≥95%
- [ ] Measure actual TTFA on WebSocket from iOS on Wi-Fi and cellular
- [ ] Measure end-to-end latency including Supabase Edge Function cold start
- [ ] Stress test session refresh at the 10-minute / 15-turn boundary — verify silent handoff
- [ ] Verify token usage reporting in `usageMetadata` frames matches metered billing in Google Cloud Console
- [ ] Test `disable_cook_realtime` flag: mint endpoint returns `DISABLED`, client falls through to text path, `AI-VOICE-01` banner appears
- [ ] Test `ENT-VOICE-01` enforcement: Free user session JWT → 403 at mint
- [ ] Test `RATE-01` enforcement: Premium user at 20/20 voice Cook Sessions → 429 at mint
- [ ] Test barge-in: user speaks mid-response → `serverContent.interrupted` frame → client stops audio playback immediately
- [ ] Test semantic VAD vs server VAD in noisy kitchen recording — compare false-activation rate

---

## References

- Gemini API Pricing: https://ai.google.dev/gemini-api/docs/pricing
- Gemini Live API guide: https://ai.google.dev/gemini-api/docs/live
- Gemini Live API ephemeral tokens: https://ai.google.dev/gemini-api/docs/ephemeral-tokens
- Gemini Live function calling: https://ai.google.dev/gemini-api/docs/live-tools
- Gemini Live session management: https://ai.google.dev/gemini-api/docs/live-session
- Gemini thinking levels: https://ai.google.dev/gemini-api/docs/thinking
- deepsense.ai GPT vs Gemini native audio benchmark: https://deepsense.ai/blog/native-audio-models-comparison-gpt-realtime-vs-gemini-2-5-flash/
