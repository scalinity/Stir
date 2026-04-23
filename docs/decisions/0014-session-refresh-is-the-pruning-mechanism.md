# ADR 0014: Session refresh IS the pruning mechanism on Gemini Live

- **Status**: Accepted (amended 2026-04-22 PM — threshold tune + recap simplification; second pass same afternoon lowered cadence 7 → 2)
- **Date**: 2026-04-22
- **Owner-step**: Step 6 (voice) — supersedes the pruning + refresh-stub deferrals from ADR 0012
- **Supersedes**: ADR 0012 items B (pruneAfterStepAdvance as log-only stub) and C (refreshSession as log-only stub). Items A (FillerClipPlayer) and D (TTFA probe) of ADR 0012 remain Accepted.
- **Related**: CLAUDE.md §Gemini Live sharp-edges #1 + #7 (corrected), CLAUDE.md §Voice validation plan criterion 4 (rewritten), Specs/Stir-Cook-Mode-Architecture.md §5, `_shared/validation.ts` (RealtimeSessionRequest recap + is_refresh), `_shared/live_mint.ts`, `realtime-session/index.ts`, `Stir/Integrations/GeminiLive/RealtimeSession.swift` (`refreshSession()`, `buildRecap()`)

## Context

ADR 0012 closed D.1 by accepting four limitations for the step-6 v1 ship. Item B ("`pruneAfterStepAdvance` log-only stub — observed growth ~100 tokens/turn, below threshold") and item C ("`refreshSession()` log-only stub — no observed session crossed 10 min / 15 turns") rested on two assumptions that turned out to be wrong:

1. **That pruning via `session.update` with audio-item truncation was implementable on Gemini Live later.** CLAUDE.md sharp-edge #7 described this behavior, carried over from OpenAI Realtime's API surface without verification.
2. **That per-turn token growth was ~100 tokens, modest enough to defer mitigation.**

Both assumptions failed under the 2026-04-22 D.1 re-measurement:

- An 8-turn test session on a physical device showed prompt tokens growing from 7,143 (turn 1) to 11,920 (turn 8) — linear ~680 tokens/turn, **not ~100**. That growth rate extrapolates to ~$0.15-0.18 per 15-turn session vs the spec's ~$0.09 estimate, pushing Premium's 20-session cap from $1.80/mo to ~$3.00/mo (**60% over the $1.89 AI budget line**).
- A fresh read of the official `ai.google.dev/api/live` reference confirmed Gemini Live's WebSocket protocol has exactly four client-to-server message types: `BidiGenerateContentSetup`, `BidiGenerateContentClientContent`, `BidiGenerateContentRealtimeInput`, `BidiGenerateContentToolResponse`. **None support mid-session context truncation.** The docs explicitly state: "You cannot update the configuration while the connection is open." There is no equivalent to OpenAI Realtime's `session.update` with audio-item truncation.

The pruning-as-deferred-work framing of ADR 0012 was therefore not recoverable post-launch — the frame type doesn't exist in the protocol. Gemini Live's only mitigation for the "every prior audio re-sent on every subsequent turn" cost problem is **session refresh**: mint a new ephemeral token, open a new WebSocket with a curated initial systemInstruction (fresh context), and close the old WebSocket once the new one's `setupComplete` handshake lands.

CLAUDE.md originally treated pruning (sharp-edge #7) and refresh (sharp-edge #6) as two separate mitigations. On this protocol they are not separate — **refresh IS the pruning mechanism**. Conflating them was a carry-over from OpenAI Realtime, where the two concepts ARE distinct (session.update truncation vs session close + new session).

## Decision

Replace the stubs with a real `refreshSession()` implementation and remove `pruneAfterStepAdvance()` from the active code path. Update all architectural docs to match the Gemini Live protocol reality.

### Trigger policy

Trigger a refresh at turn completion when EITHER:

- `turnCount - lastRefreshedAtTurn >= 2` (cadence trigger; tighter than ADR 0012's deferred 15-turn threshold. 2026-04-22 PM amendments lowered 10 → 7 → 2; see "Amendments" below.)
- `turnUsageAccumulator.sumPromptTokens > 10_000` on the current turn (burst trigger; defends against a single long turn blowing the soft cap before cadence rolls. Still 10k after the 7→2 cadence drop — the cadence fires first in the normal case so the burst trigger is pure defense-in-depth for pathological long turns.)

Also refresh defensively on a server-initiated `goAway` frame (server signalling it's about to tear down the session for its own reasons, typically 30-min hard cap approach).

Fire-once guard (`isRefreshing`) prevents a second refresh kicking off mid-handoff. The threshold is rechecked on subsequent turns, so the cadence fires every N turns across the session lifetime, not exactly once.

### Handoff protocol

Implemented in `Stir/Integrations/GeminiLive/RealtimeSession.swift:refreshSession()`. Twelve-step dance, order-sensitive:

1. Guard against re-entry + terminal states.
2. Build compact recap (~200-300 tokens) from the last 3 model turns' spoken text + current step number.
3. Mint a new ephemeral token via `/v1/ai/realtime-session` with `is_refresh: true` (backend skips `voice_cook_session` quota increment) and `recap: <string>` (backend appends to `systemInstruction` for continuity).
4. Open a new `LiveWebSocketTransport` as a local variable.
5. Cancel the old mic forwarder + receive dispatcher under `intentionalTransportSwap = true`. The flag suppresses `handleTransportError` on the cancellation throw so the old transport's teardown doesn't move state to `.error`.
6. Swap `self.transport` + `self.mintResponse` to the new instances.
7. Restart the receive dispatcher on the new transport (it drives the setupComplete continuation in step 9).
8. Send the baked-in setup frame on the new transport (required even though the ephemeral token carries `bidiGenerateContentSetup` — see CLAUDE.md sharp-edge #19).
9. Await `setupComplete` with `LiveSessionBudget.setupHandshakeSec` budget.
10. Clear `intentionalTransportSwap`; restart mic forwarding against the new transport.
11. Close the old transport (idempotent).
12. Flush the just-finalized turn's pendingReport if still outstanding, then reset per-turn accumulators and bump `lastRefreshedAtTurn = turnCount`.

### Backend changes

- `RealtimeSessionRequest` Zod schema gains two optional fields: `recap: string?` (max 2048 chars) and `is_refresh: boolean?` (default false).
- When `is_refresh: true`, the realtime-session handler skips `incrementQuotaAtomic('voice_cook_session', ...)` — refresh is a handoff within an already-active cook session; the original session start already consumed the slot.
- When `recap` is non-empty, `live_mint.ts` appends it to `systemInstruction` under a `# Recent conversation context (from prior session)` delimiter, so the model treats the recap as context rather than part of the core style/rules contract.

### Recap content

Minimal v1 — just enough to avoid making the model re-introduce the recipe or forget its place:

- "You are mid-cook on step N of M."
- "Your recent replies (newest last):" + the last 3 model turns, each truncated to ~140 chars (roughly one sentence).
- "Continue from here. Don't re-introduce the recipe."

User-transcript capture is NOT in v1 recap — `inputAudioTranscription` frames are logged but not stashed. If continuity testing shows the model losing track of user context, the next iteration adds a parallel `recentUserTurns` ring buffer.

### Failure modes

- **Mint fails (network / backend 5xx / quota edge case)**: refresh aborts, old transport remains connected and functional. Session continues degraded (growth persists) until the next refresh attempt at the following trigger. Logged at `error`.
- **New WS open fails (DNS, TLS, token rejected)**: same as mint fail — old transport preserved.
- **setupComplete times out on new transport**: we've already swapped `self.transport` at this point, so the old transport is gone. Unrecoverable — state advances to `.error`, VM downgrades to C.3 on next tap.
- **In-flight `pendingReport` exists at refresh start**: flushed as `supersededByNextTurn` before accumulator reset. Loses 0-20% accuracy on the just-finalized turn's usage report (trailing usageMetadata frame may not have arrived yet). Acceptable — the big win is capping future turns, not perfect accounting of the boundary turn.

### Cost model correction

The spec §12.2 cost model of ~$0.00600 per voice turn / ~$0.090 per 15-turn session assumed pruning worked. Without pruning, real per-turn cost grows linearly with turn count. With refresh at every 10 turns + 15k-token burst threshold:

- **Unrefreshed baseline (projected from 8-turn measurement):** turns 1–15 would carry 7k → ~17k prompt tokens each. Session-total prompt: ~180k tokens × $0.75/M = $0.135 input + ~$0.025 output = **~$0.16 per 15-turn session.**
- **Refreshed at turn 10:** turns 1–10 at 7k → ~13k; refresh; turns 11–15 at 7k → 9k. Session-total prompt: ~100k + 40k = 140k × $0.75/M = $0.105 input + ~$0.025 output = **~$0.13 per 15-turn session.**
- **Refreshed at turn 10 AND 20:** keeps us at the ~$0.10-0.12 session range for 20+ turn sessions, maintaining Premium margin.

These are projections from a single 8-turn sample. The real numbers come from the 30-turn physical-device test (D.1 sign-off gate). Spec §12.2 update is blocked on those measurements; this ADR's numbers are illustrative only.

## Alternatives considered

- **Accept the unbounded growth; raise prices or lower voice cap (Path B from the 2026-04-22 diagnostic).** Rejected — trades 4-6 hours of engineering for weeks of downstream spec/SKU/cohort rework, a weaker headline Premium feature, and an irreversible product-model change (Apple's preserved-pricing rules lock post-launch). Engineering was the right cost.
- **Send `BidiGenerateContentClientContent.turns[]` with a reduced 3-turn history on every turn after refresh, letting the server incorporate fresh history rather than rebuilding from systemInstruction.** Rejected for v1 — adds complexity (requires `initial_history_in_client_content: true` in setup flag; changes how the server treats subsequent user input), and the compact-recap-in-systemInstruction path is simpler to implement and reason about. If continuity testing proves insufficient with text recap alone, this becomes v2.
- **Raw 3-turn replay (include the actual audio of last 3 turns in the new session's initial history).** Rejected — would carry the very audio tokens we're trying to prune OUT of the new session; defeats the purpose.
- **Trigger §18 OpenAI vendor contingency (switch to OpenAI Realtime, which does support session.update truncation).** Rejected by Daniel explicitly — refresh is a valid mitigation within Gemini Live's constraints; vendor contingency is reserved for outages, not for working around documented protocol limitations.

## Consequences

### Positive

- Premium unit economics are preserved. 10-turn cadence + 15k-token burst trigger keeps per-session cost within the ~$0.12-0.15 range across realistic cook lengths, matching the Premium $1.89/mo AI budget at 20 sessions.
- Architectural understanding is now correct. CLAUDE.md, Cook Mode Architecture, and ADR 0012 no longer describe a frame type that doesn't exist.
- Refresh is on the hot path — exercised every 10 turns in every Cook session that reaches that depth. Bugs surface fast.
- The `intentionalTransportSwap` flag pattern is reusable for any future controlled-teardown scenario.

### Negative

- Refresh is a 2-5s handoff during which the mic is briefly muted. At turn boundaries (user is silent) this is invisible; if a user tries to speak DURING the handoff, their audio is dropped until mic forwarding restarts. Rare — real-world turn boundaries align with natural pauses — but documented.
- A post-swap setupComplete timeout is unrecoverable; old transport is already closed. The VM's C.3 fallback covers this, but the user sees a brief voice interruption. Rare — `setupComplete` p50 is ~300 ms, p95 ~1 s, budget is 5 s.
- The recap is model-turn-only in v1. If continuity is lossy (model loses thread of what user asked), next iteration adds user transcripts. Measured on the 30-turn physical-device test.
- Cost-attribution for the boundary turn (the turn that triggered the refresh) loses 0-20% accuracy because its pendingReport flushes early with whatever tokens arrived before the trailing usageMetadata frame. Dashboards should understand this is measurement noise at refresh boundaries, not a billing error.

### Tradeoffs

- Complexity concentrates in one method (`refreshSession()`) rather than spreading across every step-advance call site. The deprecated `pruneAfterStepAdvance()` is kept as a no-op for any stale VM caller — removing it would be breaking, and the no-op cost is zero.
- Backend quota-skip on `is_refresh: true` trusts the authenticated client. A malicious iOS build could POST `is_refresh: true` on what should be a fresh session and bypass the quota check. Impact is contained (user still pays Gemini costs via their own sessions) and detectable (unusual session-count patterns would surface in PostHog LLM dashboards). Not worth hardening to parent-session-id verification in v1.

## Triggers to revisit

- **Physical-device 30-turn test fails to force 2+ refreshes.** Either the triggers are wrong or the refresh isn't firing; diagnose and tune.
- **Continuity breaks**: model re-introduces the recipe mid-cook, forgets the active step, or asks "what were you asking about?" after a refresh. Add user transcripts to recap (ring buffer parallel to `recentModelTurns`).
- **Post-refresh setupComplete timeouts > 5% of refreshes**: either the 5s budget is too tight on cellular or the new session's recap-suffixed systemInstruction is large enough to slow mint. Measure and widen budget OR trim recap.
- **PostHog shows `voice_session_refreshed` event at `refresh_reason=tokens` > 50% of refreshes**: the 15k burst trigger is firing more than the 10-turn cadence, meaning turn cost is still growing too fast within the 10-turn window. Lower cadence to 7 or 8 turns.
- **Gemini Live ships a mid-session truncation frame in a future API version**: revisit whether pruning-per-step-advance is cheaper than refresh. Unlikely near-term.

## Notes

- Follow-up edits land alongside this ADR: CLAUDE.md sharp-edge #7 rewritten; Cook Mode Architecture §5 rewritten; CLAUDE.md §Voice validation plan criterion 4 rewritten to measure refresh-bounded growth. Spec §12.2 cost model update waits on measurements from the 30-turn physical-device test (the unblock for D.1 sign-off).
- ADR 0012 remains Accepted for items A (FillerClipPlayer deferral — Gate 2 preamble rate holds ~100% so the client clip is redundant) and D (TTFA probe skipped — validated through daily use). Only items B and C are superseded here; ADR 0012's status field is updated to note the partial supersession.
- `pruneAfterStepAdvance()` stays in the code as a no-op logger. Any VM call site will produce a `prune_deprecated_noop` log line; this catches future drift cheaply.
- D.1 remains reopened until the 30-turn physical-device test measures clean per this ADR's trigger policy.

## Amendments

### 2026-04-22 PM — thresholds lowered, recap simplified

Device test #2 (40 turns, 4 successful refreshes at turns 10/20/30/40) surfaced two UX issues within an otherwise clean run:

1. **Felt latency spike at the top of each 10-turn window.** Per-turn prompt tokens observed at the refresh boundary: turn 10 = 12,737; turn 20 = 11,920; turn 30 = 14,154; turn 40 = 6,550 (cooler, fewer tool-call turns). The 12-14k range is within the 15k burst cap, but the perceived response time for the last 2-3 turns of each window was noticeably slower than fresh. Daniel's direction: "keep tokens low and the latency fast" — trading one extra ~3s refresh handoff per session for faster per-turn latency is the right call.
2. **Recap content is unused in practice.** "Prior context is not that important. As the conversation is moving forward, not really recalling back things that have been previously said."

**Amendments:**

- `refreshAtTurnCount`: 10 → **7**. Keeps per-turn prompt tokens roughly below ~8k across the window (extrapolating from the ~680 tokens/turn growth rate observed in D.1).
- `refreshAtPromptTokenCount`: 15_000 → **10_000**. Tighter burst defense for the rarer long tool-call turn, matched to the new cadence window.
- `buildRecap()` simplified to step-position only. Drops the `recentUserTurns` + `recentModelTurns` interleave and the `sanitizeForRecap()` pipeline. New recap is one line: "You are mid-cook on step N of M. Continue from here." (~30 tokens vs ~200-300 previously).

**Cost implication.** Per-session refresh count roughly doubles (1-2 → 2-3 for 15-turn sessions, 3-4 → 5-7 for 30-turn). Mint cost is negligible (~$0.0005 per mint — text-only generateContent on the small system prompt). The compounding effect on per-turn input tokens is the bigger lever: lower prompt tokens per turn translates roughly 1:1 to lower per-turn audio-input billing. Net effect on session cost is mildly favorable or neutral — the handoff overhead is a latency cost, not a meaningful billing cost.

**Trigger to revisit (amended):** if `voice_session_refreshed` event at `refresh_reason=tokens` > 50% of refreshes, the 10k burst trigger is still firing more than the 7-turn cadence and cadence should drop further (5 or 6 turns). If refresh rate becomes a felt irritation to users (3s handoff noticeable across 5-7 per session), consider raising the cadence back — but that's a quality regression on the latency axis, so measure before flipping.

### 2026-04-22 PM — second pass: cadence lowered 7 → 2

Same-afternoon follow-up. After the initial 7-turn amendment landed and a cost projection was pulled (30-turn session: ~$0.342 at 7-turn cadence vs ~$0.480 at 10-turn), Daniel pushed further: refresh on every second turn.

Rationale: per-turn prompt tokens at turn 7 of a 7-window are ~7,075 — noticeably slower than turn 1-2. Pushing to 2-turn cadence pins per-turn input at the ~1,500-2,500 baseline forever. At this cadence the session looks less like "fresh context occasionally" and more like "mostly-fresh context always", which is as close as we can get on Gemini Live to how an OpenAI Realtime session behaves with small-window pruning.

**Threshold:** `refreshAtTurnCount: 7 → 2`. Burst trigger stays at 10k (never fires in the 2-turn normal case; kept for pathological tool-call turns).

**Cost implication:** at 2-turn cadence over 30 turns = ~15 refreshes. Per-turn cost averages ~$0.0049 (steady at window positions 1-2). 30-turn session cost drops to ~$0.147 — another ~60% below the 7-turn cadence's $0.342, and ~90% below the unrefreshed baseline. Mint cost per refresh is still negligible ($0 LLM, trivial backend compute). Session cost is now dominated by the per-turn baseline + output audio, not cumulative audio growth.

**Latency implication:** 15× ~3s refresh handoffs across a 30-turn session. Each handoff is at a turn boundary (user silent; mic momentarily muted). If any handoff is felt mid-utterance, a 2-turn cadence quadruples the exposure vs 7-turn. This is the bet: silent handoffs + lower per-turn latency > fewer handoffs + longer per-turn latency. Trigger to revisit (new): if `voice_session_refreshed` handoffs land at >200ms user-perceptible gaps at p95 (measured from mic-mute-off to mic-mute-on), raise cadence back to 4-5 turns. If `refresh_failed` rate > 1%, cadence is cycling too fast for the mint infrastructure; back off.

**Margin implication:** Premium 20-session cap × 15-turn sessions ≈ $0.074 × 20 = $1.48/mo — now comfortably under the $1.89 AI budget line (previously at $2.46, 30% over). Pro's 40-session × 15-turn ≈ $2.96/mo which fits the $3.69 Pro budget. The 2-turn cadence brings voice unit economics into the healthy zone at the cap even without Gemini cache support landing.

### 2026-04-22 PM — third pass: cadence raised 2 → 4 (sweet spot)

Same-afternoon follow-up to the second pass. Device test with 2-turn cadence surfaced the expected downside: Daniel felt the ~3s refresh handoffs as too-frequent latency hits in conversation flow ("the every two turn recap is too low. It adds too much of latency"). Asked for the cost/latency sweet spot.

**Analysis.**

Cost-per-turn is LINEAR in cadence N (each extra turn in the window adds ~$0.0014 to the windowed average), but refreshes-per-session follow the hyperbola 30/N. The knee in savings-per-added-refresh sits between N=3 and N=5:

| N | Per-turn cost | 30-turn session | Refreshes | Savings per extra refresh (vs N+1) |
|---|---------------|-----------------|-----------|-------------------------------------|
| 2 | $0.0049 | $0.147 | 14 | $0.006 |
| 3 | $0.0063 | $0.189 | 9 | $0.017 |
| 4 | $0.0077 | $0.231 | 7 | $0.021 |
| 5 | $0.0091 | $0.273 | 5 | $0.020 |
| 6 | $0.0104 | $0.312 | 4 | $0.039 |
| 7 | $0.0118 | $0.354 | 4 | — |

The 3→2 step saves only $0.006 per extra refresh — inefficient use of handoff budget. The 5→4 and 4→3 steps each save ~$0.020 per extra refresh, which is where "cost per extra handoff" peaks. Below N=3, each additional refresh buys very little cost reduction.

**Threshold:** `refreshAtTurnCount: 2 → 4`. Burst trigger stays at 10k.

**Why 4, not 5:** at N=5, turn 5 of a window carries ~5,225 prompt tokens — 22% more than turn 4 of an N=4 window (~4,300). That 22% translates to a felt latency difference on the last turn of the window. N=4 pins every turn in the ~1,525-4,300 range where backend response time is uniformly fast; no turn is "noticeably slower than the first turn after a refresh."

**Cost implication:** 30-turn session cost rises from $0.147 (N=2) to $0.231 (N=4) — +$0.084, +57%. Still 35% below N=7 and 52% below N=10. Premium 20-session × 15-turn: ~$0.115/session × 20 = $2.30/mo — over the $1.89 AI budget line by ~22%, but within the historical tradeoff band the spec contemplated before the 2-turn cadence over-corrected. Pro 40-session × 15-turn: $4.60/mo — under the $3.69 budget line by $0.91 (Pro power-users skew long, so real average lands somewhere between 15-turn and 20-turn per-session).

**Latency implication:** ~7 refresh handoffs per 30-turn session, one every ~4-5 turns of conversation (~20-25s). About half the handoff frequency of N=2 (14 handoffs). Still ~5 refreshes per typical 15-turn Premium session, but distributed widely enough to land at turn boundaries without collision with active utterances.

**Trigger to revisit:** if `voice_session_refreshed latency_ms` p95 exceeds 5s (today ~3s), lower burst trigger. If average session cost exceeds $0.30 in PostHog LLM dashboards at typical session length, drop cadence to 3. If users report refreshes are still noticeable, raise to 5 and accept the slightly-slower turn 5.

### 2026-04-22 PM — measured-reality cost correction (post-step-6)

After step 6 shipped and the Cook Mode voice path was exercised across multiple 9+ turn sessions, the per-turn prompt token counts came in materially higher than this ADR's amendment modeling. Real observed numbers (9-turn session, cadence N=4, pre-mint landing, 22% tool-call rate):

| Turn type | Observed prompt tokens (mean) | Modeled in ADR 0014 amendment |
|-----------|-------------------------------|-------------------------------|
| Fresh turn (pos 1 in window) | 4,158 | ~1,525 |
| Mid-window turn (pos 2-3) | 4,677 | ~2,450-3,375 |
| Last turn in window (pos 4) | 4,895 | ~4,300 |
| Tool-call turn (double-pass) | 8,822 | not modeled separately |
| Response tokens | 124 avg | 150 |

**Why the projection was low:** the amendment modeled a ~1,525 token "baseline" + linear ~925/turn growth. Reality is a ~3,800 token baseline baked into every turn (systemInstruction template ~1,200 tokens, recipe context with 5+ steps ~1,500 tokens, pantry+household+equipment ~600 tokens, AUDIO-mode overhead ~200 audio tokens, fresh-turn user audio ~100 tokens) + ~500-700/turn growth from carried model audio within the refresh window. The "baseline" is what dominates; in-window growth is a secondary lever.

**Corrected 30-turn session cost** (at 22% tool-call rate, 7 refreshes firing at turn 4/8/12/16/20/24/28):

At 75/25 text:audio prompt split (central estimate): **~$0.265 per 30-turn session**.
At 60/40 split (more carried audio): **~$0.321 per 30-turn session**.

The amendment projected $0.231 — reality is 15-39% higher.

**Premium margin implication:** 15-turn typical session × 20-session cap = **$2.56-$3.10/mo** at the Premium AI line vs the $1.89/mo budget, which is **35-64% over budget**. The amendment projected $2.30/mo which was 22% over; reality is materially worse.

**Mitigation options (not yet deployed):**
1. Drop Premium monthly cap from 20 → 12-13 sessions. Keeps 15-turn average at ~$1.67-$1.81/mo, back under budget.
2. Trim system prompt + recipe context payload. System prompt could drop 200-400 text tokens; recipe context is already compressed (just step text, no prose). Realistic savings: 10-15% of baseline.
3. Wait for Gemini Live context caching (not yet GA). Would cache the ~3,000-token baseline at ~$0.19/M (75% discount on text), bringing per-turn cost down ~40%.

Option 1 is the actionable lever today. This becomes a product decision (Daniel) — do we cut the cap pre-launch to protect margin, or launch at 20 and accept sub-budget performance until caching lands?

**No change to refresh cadence from this finding.** Cadence N=4 is still the right latency tradeoff. The cost issue is the per-turn baseline, not the growth rate — lowering cadence further would add handoff latency without meaningfully moving the economics.
