#!/usr/bin/env python3
"""SCA-19 one-shot — remove deleted coach-mark / sequence file references
from `Stir.xcodeproj/project.pbxproj`.

The full-screen tutorial migration (SCA-19) deletes every CoachMark*
file from the DS layer and every *CoachMarks.swift sequence from
Features/Tutorial/. Their pbxproj references must go too — Xcode would
otherwise fail at build with "file not found" for each phantom path.

Mirrors `register_tutorial_files.py` but in reverse: removes
PBXBuildFile, PBXFileReference, group children, and sources-phase
entries for the named filenames. Idempotent — running twice on a
cleaned project is a no-op.

Run from repo root:
    python3 scripts/unregister_coach_mark_files.py
"""
from __future__ import annotations

import pathlib
import re
import sys

PBXPROJ = pathlib.Path("Stir.xcodeproj/project.pbxproj")

# Files to scrub. SCA-19 deletes the entire coach-mark stack +
# per-feature sequence files + the no-longer-relevant
# CoachMarkControllerTests.
FILES_TO_REMOVE = [
    # DS components — Stir/DesignSystem/Components/
    "CoachMarkAnchor.swift",
    "CoachMarkStep.swift",
    "CoachMarkController.swift",
    "CoachMarkSpotlight.swift",
    "CoachMarkCard.swift",
    "CoachMarkPresenter.swift",
    # Per-feature sequences — Stir/Features/Tutorial/
    "ScanCaptureCoachMarks.swift",
    "ScanReviewCoachMarks.swift",
    "DinnerOptionsCoachMarks.swift",
    "DishPreviewCoachMarks.swift",
    "CookModeTapCoachMarks.swift",
    "VoiceModeCoachMarks.swift",
    "PantryCoachMarks.swift",
    # Test — replaced by TutorialFlowContainerTests
    "CoachMarkControllerTests.swift",
]


def remove_lines_containing(text: str, needle: str) -> tuple[str, int]:
    """Drop every full line that contains `needle`. Returns (text, count)."""
    out_lines = []
    removed = 0
    for line in text.splitlines(keepends=True):
        if needle in line:
            removed += 1
            continue
        out_lines.append(line)
    return "".join(out_lines), removed


def remove_filename(text: str, filename: str) -> tuple[str, int]:
    """Remove every pbxproj line that mentions `<filename>`.

    pbxproj entries reference a filename in four places (PBXBuildFile,
    PBXFileReference, PBXGroup children, PBXSourcesBuildPhase files).
    Each entry is exactly one line and contains `/* <filename> */` or
    `path = <filename>;` — both contain the literal filename, so a
    line-containment scrub catches all four without parsing the
    structure.

    A false-positive risk would be a comment somewhere mentioning
    the filename — pbxproj has no user comments, only auto-generated
    `/* ... */` annotations, so this is safe.
    """
    return remove_lines_containing(text, filename)


def main() -> int:
    if not PBXPROJ.exists():
        print(f"error: {PBXPROJ} not found — run from Stir/ repo root", file=sys.stderr)
        return 1
    text = PBXPROJ.read_text(encoding="utf-8")
    original = text

    total_removed = 0
    for f in FILES_TO_REMOVE:
        text, removed = remove_filename(text, f)
        if removed:
            print(f"  - {f}: removed {removed} pbxproj entries")
            total_removed += removed
        else:
            print(f"  · {f}: not present (already clean)")

    if text == original:
        print("\nNothing to do — pbxproj already clean.")
        return 0

    PBXPROJ.write_text(text, encoding="utf-8")
    print(f"\nRemoved {total_removed} pbxproj entries across {len(FILES_TO_REMOVE)} files.")
    print(f"Wrote {PBXPROJ}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
