#!/bin/bash
#
# scripts/run-ios-tests.sh — agent-friendly xcodebuild test wrapper.
#
# Bakes in the three flake-recovery moves that have accumulated in
# `scripts/git-hooks/pre-push` (SCA-208, SCA-364, SCA-383) plus the
# Config.xcconfig staging step the worktree workflow keeps tripping
# over (SCA-355 sprint cluster, observations 4438/4467). The pre-push
# hook only protects the push event — iterative `xcodebuild test`
# calls during dev bypass it. SCA-426 is the wrapper that closes the
# gap so the next agent finds one canonical command in CLAUDE.md
# instead of rediscovering the recovery dance.
#
# Behavior:
#   1. Ensure Config.xcconfig exists; restore from Config.xcconfig.example
#      if missing (worktree case — the file is gitignored).
#   2. Pre-warm the destination simulator (shutdown all + boot + 4s
#      sleep) so the first xcodebuild invocation lands on a known-good
#      sim rather than a cold or wedged one.
#   3. Run `xcodebuild test -scheme Stir -destination ... -quiet` and
#      capture stdout to a tempfile so the flake heuristics have
#      something to grep.
#   4. On non-zero exit, detect the two flake signatures the pre-push
#      hook already enumerates:
#        - SBMainWorkspace preflight failure (sim wedged before runner
#          installed) — SCA-208.
#        - Silent test-runner death: log < 20 lines AND no test markers
#          (xcodebuild died between consecutive invocations without
#          producing any test output at all) — SCA-364.
#      On either match: shutdown + ERASE + boot the sim, sleep 5s, retry
#      ONCE. The erase is the SCA-383 upgrade — shutdown+boot wasn't
#      enough for the wedged sim observed in observation 4472.
#   5. Real test failures (substantive log w/ test markers) bypass
#      retry — that's a real red, not a flake.
#
# Env vars:
#   STIR_TEST_DEVICE        Override destination sim name. Default:
#                           "iPhone 17 Pro Max" (matches the pre-push
#                           hook post-SCA-292).
#   STIR_TEST_SKIP_WARMUP=1 Skip the pre-warm boot. For callers running
#                           back-to-back when the sim is known hot.
#
# Exit: passes through xcodebuild's exit code from the final attempt.

set -euo pipefail

DEVICE="${STIR_TEST_DEVICE:-iPhone 17 Pro Max}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# 1. Worktree Config.xcconfig restore. The file is gitignored
#    (holds Supabase URL + anon key + RC/PostHog/Sentry public keys),
#    so a fresh worktree won't have it. The .example fixture in the
#    repo is the public-key template the CI workflow uses — same idea
#    here.
if [ ! -f "Config.xcconfig" ]; then
    if [ -f "Config.xcconfig.example" ]; then
        echo "[run-ios-tests] staging Config.xcconfig from .example (fresh worktree)"
        cp Config.xcconfig.example Config.xcconfig
    else
        echo "[run-ios-tests] ❌ Config.xcconfig missing and no .example to stage from"
        exit 1
    fi
fi

# 2. Pre-warm the sim. Cheap (~5s) and reliably avoids the
#    first-push-after-reboot SBMainWorkspace error.
if [ "${STIR_TEST_SKIP_WARMUP:-0}" != "1" ]; then
    echo "[run-ios-tests] pre-warming $DEVICE simulator…"
    xcrun simctl shutdown all >/dev/null 2>&1 || true
    xcrun simctl boot "$DEVICE" >/dev/null 2>&1 || true
    sleep 4
fi

TMPLOG="$(mktemp -t stir-test-XXXXXX)"
trap 'rm -f "$TMPLOG"' EXIT

run_test() {
    set +e
    xcodebuild test \
        -scheme Stir \
        -destination "platform=iOS Simulator,name=$DEVICE" \
        -quiet \
        > "$TMPLOG" 2>&1
    EXIT=$?
    set -e
}

# 3. First attempt.
echo "[run-ios-tests] running xcodebuild test on ${DEVICE}…"
run_test

# 4. Flake detection + one-shot erase-and-retry. Mirrors the pre-push
#    hook's SCA-208/SCA-364 logic with the SCA-383 erase upgrade.
if [ "$EXIT" != "0" ]; then
    SIM_FLAKE_REASON=""
    if grep -qE 'Application failed preflight checks|Simulator device failed to launch' "$TMPLOG"; then
        SIM_FLAKE_REASON="SBMainWorkspace preflight"
    elif grep -qE 'Early unexpected exit, operation never finished bootstrapping|Test crashed with signal kill before establishing connection' "$TMPLOG"; then
        # Third flake class observed on 2026-05-15 (SCA-426 in-session
        # repro): xcodebuild builds successfully (substantive log,
        # test markers present) but the test-bundle host crashes
        # before any test runs. Distinct from SCA-208 (preflight) and
        # SCA-364 (short silent log). Same recovery — erase + boot.
        SIM_FLAKE_REASON="test-runner bootstrap crash"
    else
        TMPLOG_LINES="$(wc -l < "$TMPLOG" 2>/dev/null | tr -d ' ' || echo 0)"
        if [ "${TMPLOG_LINES:-0}" -lt 20 ] \
           && ! grep -qE 'Testing started|Testing failed|TEST FAILED|TEST SUCCEEDED|error:' "$TMPLOG"; then
            SIM_FLAKE_REASON="silent test-runner death (log=${TMPLOG_LINES}L, no test markers)"
        fi
    fi

    if [ -n "$SIM_FLAKE_REASON" ]; then
        echo "[run-ios-tests] ⚠️  sim flake detected ($SIM_FLAKE_REASON) — erasing $DEVICE and retrying once"
        xcrun simctl shutdown all >/dev/null 2>&1 || true
        xcrun simctl erase "$DEVICE" >/dev/null 2>&1 || true
        xcrun simctl boot "$DEVICE" >/dev/null 2>&1 || true
        sleep 5
        run_test
        if [ "$EXIT" = "0" ]; then
            echo "[run-ios-tests] ✅ retried after sim flake — tests passed"
        fi
    fi
fi

# 5. Report. Pass through xcodebuild's exit code so callers (CI,
#    other scripts, agents grepping for non-zero) see the truth.
if [ "$EXIT" = "0" ]; then
    echo "[run-ios-tests] ✅ tests passed"
else
    echo "[run-ios-tests] ❌ tests failed (exit=$EXIT)"
    echo "--- last 60 lines of test log ---"
    tail -n 60 "$TMPLOG"
fi
exit "$EXIT"
