# Voice cheap-half drift check (SCA-330)

**When to run:** at the start of Step 6 (Cook Mode voice) work, OR any time
the spec §12 sharp-edges block is being relied upon and >2 weeks have passed
since the last drift check. CLAUDE.md "Voice validation plan" pins this as a
mandatory pre-flight before any voice-pipeline code spend.

**Why:** the expensive half (UX validation) ran April 2026 → `FINDINGS.md`.
The cheap half (~1h, terminal) verifies Google hasn't silently changed mint
shape, WS protocol, audio metering, or pricing. Catches drift cheaply; the
alternative is shipping code against stale assumptions.

**Authoritative spec:** `CLAUDE.md` §"Gemini Live — sharp edges" items 5–19.

---

## Pre-flight

You need the production paid-tier `GEMINI_API_KEY` (legacy `AIzaSy…` only —
new-format `AQ.xxx` keys are rejected by the mint endpoint, per CLAUDE.md
sharp-edge #18). The local `Backend/supabase/.env` has a `placeholder-step-1-unused`
value; pull the real key from `supabase secrets list --project-ref ktqajarcomzplnpbczfo`
or the GCP console for the Stir project.

```bash
export GEMINI_API_KEY="AIzaSy…"   # legacy 39-char format
```

Verify the key resolves to a paid-tier project. Free-tier returns a
`400 INVALID_ARGUMENT` that's indistinguishable from a malformed body
(sharp-edge #17) — verify in https://aistudio.google.com/app/apikey before
running.

---

## Run the automated checks

```bash
deno run --allow-env --allow-net scripts/gemini-live-drift-check.ts
```

The script exercises steps 1–4 (mint shape, WS open, PCM16 frame, audio
metering) and prints `pass`/`fail` per step plus the observed values. Drift
is anything that differs from the values quoted in CLAUDE.md §"Gemini Live —
sharp edges".

**Coverage (script-automated):**

1. `POST /v1alpha/auth_tokens` (snake_case path) with `x-goog-api-key` header
   → 200 + `token` + `name` of shape `auth_tokens/<id>`.
2. WS open to `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained?access_token=<name>`
   with NO `Authorization` header; send a `{"setup":{…}}` frame; assert the
   server emits `setupComplete` within 5s.
3. Send one PCM16 16kHz audio frame via `realtimeInput.audio` (base64); assert
   no protocol error.
4. Wait for `usageMetadata`; assert audio metering is still **25 tok/sec both
   ways**. The undocumented ~200-token AUDIO-mode per-pass overhead (sharp-edge
   #15) should reappear in `prompt_tokens_details`.

**Coverage (manual):**

5. Cross-check pricing on https://ai.google.dev/gemini-api/docs/pricing.
   Stir's cost model uses these values from CLAUDE.md / `MODEL_PRICING` in
   `_shared/cost.ts`:
   - `gemini-3.1-flash-live-preview` audio in $3.00 / 1M, audio out $12.00 / 1M
   - text in $0.75 / 1M
   - cached input discount 25% of standard text rate (ADR 0015 — assumed)
6. Run the same mint from inside the Edge Function environment:

   ```bash
   cd Backend/supabase
   supabase functions serve --env-file functions/.env
   # in another shell:
   curl -X POST http://localhost:54321/functions/v1/realtime-session \
        -H "Authorization: Bearer <fresh session JWT>" \
        -H "content-type: application/json" \
        -d '{"context":"smoke"}' | jq .
   ```

   Verify the response carries the same shape `realtimeSession.ts` was coded
   for (`token`, `expireTime`, `newSessionExpireTime`, `uses`, plus the
   pre-serialized `setup_frame_json`).
7. **On drift:** update `Specs/Stir-Full-Spec.md` §12 AND `CLAUDE.md` §"Gemini
   Live — sharp edges" item-by-item BEFORE writing any Cook Mode code that
   relies on the contract.

---

## Sign-off

Cheap-half passes when:
- All 4 automated checks return `pass`.
- Manual cross-check confirms pricing + setup_frame shape unchanged.
- Any deltas are reflected in spec §12 + CLAUDE.md in the same commit that
  marks SCA-330 Done.

If anything fails materially (mint shape changed, WS endpoint moved, audio
metering coefficient shifted, pricing changed), STOP and escalate — these are
architectural drifts, not tuning. Step 6 should not proceed until spec + code
are updated.

---

## Filing the result

* SCA-330 Linear issue gets a comment with the script output + manual notes.
* Mark Done if cheap-half clears; otherwise file each drift as a sub-issue
  before closing.
