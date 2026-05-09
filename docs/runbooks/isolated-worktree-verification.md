# Isolated-worktree verification runbook

How to run backend tests against a verify worktree without contaminating the result with the main checkout's edge-runtime container.

> **TL;DR:** `supabase start`'s edge-runtime Docker container mounts files from the directory where the stack was started — usually the main checkout. Tests run from a verify worktree that POST to edge functions therefore hit the **main checkout's handler code**, not the worktree's. Two ways to handle this: Path A (hybrid skip-list) or Path B (full restart). Most multi-commit verify passes use Path A; Path B is the override when the skip list gets big.

> **Linear**: SCA-128. Provenance: `docs/deferred-work.md` line 69.

---

## Why this happens

`supabase start` boots a Docker stack that includes Postgres, Storage, GoTrue, Realtime, and the **edge runtime** (Deno) — the last one mounts the local `supabase/functions/` directory into the container at boot time. Once mounted, that path is fixed for the lifetime of the stack. Restarting the stack from a different directory rebinds the mount; otherwise the container keeps serving the original directory's code.

Worktrees inherit a separate working directory but share the parent repo's `.git`. They don't share the edge-runtime mount, because the mount is bound to the directory you ran `supabase start` from, not to git itself. That asymmetry is the whole problem.

---

## Decision tree

```
Did the verify worktree change ANY file under Backend/supabase/functions/?
│
├─ NO  → Path A is automatic. Tests hit handler code identical between main + worktree.
│        No action needed. Run tests from the worktree.
│
└─ YES → How many tests target the changed handler(s)?
         │
         ├─ < 30% of the relevant test set → Path A with skip list.
         │   Skip the divergent handler's tests; explicitly note the skip.
         │
         └─ ≥ 30% of the relevant test set → Path B (full restart).
             The skip list is too big to trust. Restart the stack against
             the worktree and run the full set.
```

The 30% threshold is a heuristic: skipping a third of your verification surface means the verify is no longer load-bearing. At that point the 60–90s ceremony of Path B is cheaper than the cognitive overhead of trusting a thin skip list.

---

## Path A — hybrid skip list (default)

Use when fewer than 30% of relevant tests target a handler that diverged between `main` and the verify worktree.

### Step 1 — identify divergent handlers

From the verify worktree (with the stack running against main):

```bash
# What handler files differ from main?
git diff main..HEAD --name-only | grep '^Backend/supabase/functions/' | sort -u
```

Each file in the output represents a handler whose tests will hit the **wrong code** if run from this worktree without restarting the stack.

### Step 2 — identify divergent test files

For each divergent handler, find the matching test file:

```bash
# Example: handler at Backend/supabase/functions/users-delete-request/index.ts
# Test files at Backend/supabase/tests/integration/users_delete_request_*.ts
ls Backend/supabase/tests/**/users_delete_request*.ts
ls Backend/supabase/tests/**/<handler-name>*.ts
```

If the handler has no integration tests, only unit tests, the skip is moot — unit tests don't touch the edge runtime.

### Step 3 — run the rest of the suite

```bash
# Run everything EXCEPT the divergent test files.
deno test \
  --config Backend/supabase/functions/deno.json \
  --allow-all \
  Backend/supabase/tests/ \
  --filter '!users_delete_request'  # repeat exclusions as needed
```

Or, if `--filter` exclusions get unwieldy, list the target test files explicitly instead.

### Step 4 — note the skip in the verify summary

When reporting the verify result, list every skipped test file with one-line reason:

```
Path A verify on <commit>:
  ✓ 247 tests passed (Backend/supabase/tests/, excluding the below)
  ⊘ Skipped: users_delete_request_*.ts — handler diverged from main; covered by manual smoke
  ⊘ Skipped: pgmq_dispatch_*.ts — handler diverged from main; covered by manual smoke
```

The skip list is the audit trail. If a regression slips through, the skip-list note is what tells the next agent "this handler wasn't actually verified."

### Manual smoke for skipped handlers

For each skipped handler, run a targeted smoke before merging:

```bash
# Example: users-delete-request smoke
curl -X POST http://localhost:54321/functions/v1/users-delete-request \
  -H "Authorization: Bearer <test-jwt>" \
  -H "Content-Type: application/json" \
  -d '{"installation_id":"test-uuid"}'
```

The smoke isn't a substitute for the integration test — it's a sanity floor. If the smoke 500s, the handler is broken and the skip was hiding it.

---

## Path B — full restart (override)

Use when the Path A skip list exceeds 30% of relevant tests OR when you don't trust your skip list.

### Step 1 — stop the stack

```bash
# From wherever the stack is currently running (probably main checkout).
supabase stop
```

Wait until the command returns. Confirm via `docker ps` that no `supabase_*` containers are still up.

### Step 2 — restart from the verify worktree

```bash
# From the verify worktree directory.
cd /path/to/worktree-dir
supabase start
```

Wait for the stack to come up (~30–45s). Confirm the edge runtime mounts the worktree path:

```bash
docker inspect supabase_edge_runtime_<project> | jq '.[0].HostConfig.Binds'
# Should show "/path/to/worktree-dir/Backend/supabase/functions:..."
```

### Step 3 — run the full suite

```bash
deno test \
  --config Backend/supabase/functions/deno.json \
  --allow-all \
  Backend/supabase/tests/
```

### Step 4 — restore main's stack on completion

When the verify finishes:

```bash
supabase stop
cd /path/to/main-checkout
supabase start
```

Otherwise the next session running tests from main will hit the worktree's code (same problem in reverse). Always restore.

**Total ceremony cost:** 60–90s of stack-cycling per verify pass. Acceptable when the skip-list approach would silently hide a regression.

---

## What about parallel multi-commit verifies?

If a sprint generates a chain of commits A → B → C → D and you want to verify each in isolation:

- **A through C** can usually run Path A if the divergence is contained within a single feature.
- **D** (or whichever commit introduced the most edge-function churn) takes Path B; the rest of the chain piggybacks on its restart since the stack is now bound to the latest worktree.

Don't restart the stack on every commit. The 60–90s ceremony × N commits is the failure mode this whole runbook exists to avoid.

---

## Ideal fix (deferred)

The ergonomic answer is **isolated Supabase stack per worktree** — each worktree gets its own Postgres + edge-runtime container with its own port allocation and its own mount. Then verifies in different worktrees don't compete for the same shared stack.

This is achievable today via Docker Compose project names + per-worktree `supabase/config.toml` overrides setting custom ports — but it's docker-networking work and worth deferring until the friction outpaces this runbook's cost.

When triggered (multi-developer setup, or daily multi-worktree verifies become routine):
- Generate a per-worktree `supabase/config.toml` with `[api] port = <hash-of-worktree>`
- Boot stacks via `COMPOSE_PROJECT_NAME=stir-<worktree-name>` to namespace containers
- Reroute test fixtures to the worktree-specific port

Filed as a follow-up trigger entry in `docs/deferred-work.md`. Until then, this runbook is the workflow.

---

## Provenance

- `docs/deferred-work.md` line 69 — original trigger entry
- Linear: SCA-128 (parent SCA-58)
- CLAUDE.md §Verification flows — link added in this commit
