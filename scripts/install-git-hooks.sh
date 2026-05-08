#!/bin/bash
#
# Configure git to look for hooks in `scripts/git-hooks/` instead of
# `.git/hooks/`. Idempotent; safe to re-run. Run once per clone:
#
#   ./scripts/install-git-hooks.sh
#
# SCA-184: switched from a symlink-based installer to git's
# `core.hooksPath` config (supported since git 2.9). The earlier
# symlink approach had a case-mismatch landmine: the symlink target
# referenced `Scripts/` (capital) while the git-tracked directory is
# `scripts/` (lowercase). On case-insensitive macOS this silently
# worked; on case-sensitive APFS, Linux CI, or external drives, the
# installer would report success while installing zero hooks.
# `core.hooksPath` removes the symlink dance entirely — git uses the
# repo-relative path directly.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SRC_DIR="$REPO_ROOT/scripts/git-hooks"

if [ ! -d "$SRC_DIR" ]; then
    echo "ERROR: hook source dir missing at $SRC_DIR — nothing to install"
    exit 1
fi

# Make every script in the source dir executable. Versioned mode bits
# can drift across machines; this is the cheap belt-and-suspenders.
chmod +x "$SRC_DIR"/*

# Point git at the versioned directory. Stored relative to the repo
# root so it works for any clone of the repo.
git config core.hooksPath scripts/git-hooks

CURRENT="$(git config --get core.hooksPath)"
echo "✅ git core.hooksPath = $CURRENT"
echo
echo "installed hooks:"
for src in "$SRC_DIR"/*; do
    echo "  - $(basename "$src")"
done
echo
echo "verify with: git config --get core.hooksPath"
