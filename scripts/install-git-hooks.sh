#!/bin/bash
#
# Symlinks every script in Scripts/git-hooks/ into .git/hooks/, so
# the versioned hooks are picked up by git on every push. Idempotent;
# safe to re-run.
#
# Run from anywhere in the repo:
#   ./Scripts/install-git-hooks.sh
#
# Why a symlink (vs cp): so future updates to the versioned hook
# automatically apply without re-running this installer.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SRC_DIR="$REPO_ROOT/Scripts/git-hooks"
DEST_DIR="$REPO_ROOT/.git/hooks"

if [ ! -d "$SRC_DIR" ]; then
    echo "no hooks at $SRC_DIR — nothing to install"
    exit 0
fi

mkdir -p "$DEST_DIR"

for src in "$SRC_DIR"/*; do
    name="$(basename "$src")"
    dest="$DEST_DIR/$name"
    # Replace any existing file/symlink at that hook name.
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        rm "$dest"
    fi
    ln -s "../../Scripts/git-hooks/$name" "$dest"
    chmod +x "$src"
    echo "installed: $dest -> ../../Scripts/git-hooks/$name"
done

echo
echo "✅ git hooks installed. Verify with: ls -la .git/hooks/"
