#!/usr/bin/env python3
"""SCA-19 / SCA-28 — remove deleted Swift file references from
`Stir.xcodeproj/project.pbxproj`.

Mirrors `register_tutorial_files.py` but in reverse: removes
PBXBuildFile, PBXFileReference, group children, and sources-phase
entries for the named filenames. Idempotent — running twice on a
cleaned project is a no-op.

SCA-28 W11 — the matcher now anchors on the pbxproj's literal
delimiters (`/* <filename> */` and `path = <filename>;`) instead of
bare-substring containment. The earlier matcher accidentally scrubbed
unrelated files whose names contained a removed name as a substring
(e.g., `CoachMarkController` matched lines for
`CoachMarkControllerTests`). Per-file removal counts in the printed
output now reflect the actual delimiter-anchored matches.

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
    # SCA-19 — DS components, Stir/DesignSystem/Components/
    "CoachMarkAnchor.swift",
    "CoachMarkStep.swift",
    "CoachMarkController.swift",
    "CoachMarkSpotlight.swift",
    "CoachMarkCard.swift",
    "CoachMarkPresenter.swift",
    # SCA-19 — per-feature sequences, Stir/Features/Tutorial/
    "ScanCaptureCoachMarks.swift",
    "ScanReviewCoachMarks.swift",
    "DinnerOptionsCoachMarks.swift",
    "DishPreviewCoachMarks.swift",
    "CookModeTapCoachMarks.swift",
    "VoiceModeCoachMarks.swift",
    "PantryCoachMarks.swift",
    # SCA-19 — test, replaced by TutorialFlowContainerTests
    "CoachMarkControllerTests.swift",
    # SCA-28 — split into PantryInListPopulatedTutorial /
    # PantryInListEmptyTutorial (sibling files) so each variant is its
    # own focused View instead of two flows routed through one struct.
    "PantryInListTutorial.swift",
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
    """Remove every pbxproj line that references `<filename>`.

    pbxproj entries reference a filename in four places, with three
    distinct delimiter forms:
      • PBXFileReference + PBXGroup child:   `/* <filename> */`
      • PBXSourcesBuildPhase entry:          `/* <filename> in Sources */`
      • PBXFileReference path attribute:     `path = <filename>;`
    The PBXBuildFile line contains both `/* <filename> in Sources */`
    AND `/* <filename> */` — matching either form catches it once.

    Match all three so a filename like `CoachMarkController` doesn't
    accidentally scrub `CoachMarkControllerTests` lines (SCA-28 W11).
    Idempotent: a clean tree matches zero lines for every entry on a
    second run.
    """
    annotation = f"/* {filename} */"
    sources_marker = f"/* {filename} in Sources */"
    path_attr = f"path = {filename};"
    out_lines = []
    removed = 0
    for line in text.splitlines(keepends=True):
        if annotation in line or sources_marker in line or path_attr in line:
            removed += 1
            continue
        out_lines.append(line)
    return "".join(out_lines), removed


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
