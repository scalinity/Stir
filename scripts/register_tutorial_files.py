#!/usr/bin/env python3
"""Register SCA-5 tutorial files into Stir.xcodeproj/project.pbxproj.

The Stir project uses explicit file references (no synchronized folder
groups). Adding a Swift file to the build requires four entries:
  1. PBXBuildFile (UUID -> file ref)
  2. PBXFileReference (the source file path)
  3. Membership in a PBXGroup (so it shows in Xcode's tree)
  4. Membership in a PBXSourcesBuildPhase (so it actually compiles)

This script is idempotent — running twice is a no-op (each new entry is
only added if its filename doesn't already appear in the relevant
section).

Run from repo root:
    python3 scripts/register_tutorial_files.py
"""
from __future__ import annotations

import pathlib
import re
import secrets
import sys

PBXPROJ = pathlib.Path("Stir.xcodeproj/project.pbxproj")

# (path-relative-to-group, parent-group-uuid, target-sources-phase-uuid)
DS_COMPONENTS_GROUP = "FC78F4C13D0ACA458C7B83DB"
FEATURES_GROUP = "34762D71E79B43578072353F"
TESTS_UNIT_GROUP = "071AE0605D7D1BFC77ED925A"
STIR_SOURCES_PHASE = "7CA84D64FE6B899A8EB4D38B"
TESTS_SOURCES_PHASE = "78AA863439D26F1494CED514"

# Files to add. Each entry: filename, parent_group_uuid, target_sources_phase_uuid
DS_FILES = [
    "TutorialFlowContainer.swift",
    "TutorialStepView.swift",
    "TutorialPresenter.swift",
    # SCA-5b — coach-mark infrastructure (flat in Components/, mirroring
    # the same pattern as the existing tutorial files).
    "CoachMarkAnchor.swift",
    "CoachMarkStep.swift",
    "CoachMarkController.swift",
    "CoachMarkSpotlight.swift",
    "CoachMarkCard.swift",
    "CoachMarkPresenter.swift",
]
FEATURE_FILES = [
    "TutorialKey.swift",
    "TutorialManager.swift",
    "TonightTour.swift",
    # SCA-5b — per-feature coach-mark sequences. Flat in Tutorial/
    # since the existing subgroup is already wired into the project.
    "ScanCaptureCoachMarks.swift",
    "ScanReviewCoachMarks.swift",
    "DinnerOptionsCoachMarks.swift",
    "DishPreviewCoachMarks.swift",
    "CookModeTapCoachMarks.swift",
    "VoiceModeCoachMarks.swift",
    "PantryCoachMarks.swift",
    "TutorialReplayView.swift",
]
TEST_FILES = [
    "TutorialManagerTests.swift",
    "CoachMarkControllerTests.swift",
]


def make_uuid() -> str:
    """Xcode UUIDs are 24-char uppercase hex."""
    return secrets.token_hex(12).upper()


def find_group_block(text: str, group_uuid: str) -> tuple[int, int]:
    """Return (start_of_children, end_of_children_paren) for the group."""
    # Match: <UUID> /* <name> */ = { ... children = ( ... ); ... };
    pattern = rf"{group_uuid} /\* [^*]* \*/ = \{{\s*isa = PBXGroup;.*?children = \((.*?)\);"
    m = re.search(pattern, text, re.DOTALL)
    if not m:
        raise SystemExit(f"Could not find PBXGroup {group_uuid}")
    return m.start(1), m.end(1)


def find_sources_phase_block(text: str, phase_uuid: str) -> tuple[int, int]:
    pattern = rf"{phase_uuid} /\* Sources \*/ = \{{\s*isa = PBXSourcesBuildPhase;.*?files = \((.*?)\);"
    m = re.search(pattern, text, re.DOTALL)
    if not m:
        raise SystemExit(f"Could not find PBXSourcesBuildPhase {phase_uuid}")
    return m.start(1), m.end(1)


def insert_in_section(text: str, section_marker: str, new_lines: list[str]) -> str:
    """Insert lines just before the matching End comment of a section."""
    end_marker = section_marker.replace("Begin", "End")
    end_idx = text.index(f"/* {end_marker} */")
    insertion = "".join(new_lines)
    return text[:end_idx] + insertion + text[end_idx:]


def add_pbx_buildfile(text: str, build_uuid: str, file_ref_uuid: str, filename: str) -> str:
    line = f"\t\t{build_uuid} /* {filename} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_uuid} /* {filename} */; }};\n"
    return insert_in_section(text, "Begin PBXBuildFile section", [line])


def add_pbx_filereference(text: str, file_ref_uuid: str, filename: str) -> str:
    line = (
        f"\t\t{file_ref_uuid} /* {filename} */ = "
        f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
        f"path = {filename}; sourceTree = \"<group>\"; }};\n"
    )
    return insert_in_section(text, "Begin PBXFileReference section", [line])


def add_to_group(text: str, group_uuid: str, file_ref_uuid: str, filename: str) -> str:
    start, end = find_group_block(text, group_uuid)
    children_block = text[start:end]
    if filename in children_block:
        return text  # already present
    insertion = f"\t\t\t\t{file_ref_uuid} /* {filename} */,\n"
    return text[:end] + insertion + text[end:]


def add_to_sources_phase(text: str, phase_uuid: str, build_uuid: str, filename: str) -> str:
    start, end = find_sources_phase_block(text, phase_uuid)
    files_block = text[start:end]
    if filename in files_block:
        return text
    insertion = f"\t\t\t\t{build_uuid} /* {filename} in Sources */,\n"
    return text[:end] + insertion + text[end:]


def create_subgroup(text: str, parent_uuid: str, group_name: str, group_uuid: str, child_uuids_named: list[tuple[str, str]]) -> str:
    """Create a new PBXGroup under `parent_uuid` and seed it with files."""
    children_lines = "".join(
        f"\t\t\t\t{cu} /* {cn} */,\n" for cu, cn in child_uuids_named
    )
    group_block = (
        f"\t\t{group_uuid} /* {group_name} */ = {{\n"
        f"\t\t\tisa = PBXGroup;\n"
        f"\t\t\tchildren = (\n"
        f"{children_lines}"
        f"\t\t\t);\n"
        f"\t\t\tpath = {group_name};\n"
        f"\t\t\tsourceTree = \"<group>\";\n"
        f"\t\t}};\n"
    )
    text = insert_in_section(text, "Begin PBXGroup section", [group_block])
    # Wire the new subgroup into its parent.
    text = add_to_group(text, parent_uuid, group_uuid, group_name)
    return text


def find_existing_subgroup(text: str, parent_uuid: str, name: str) -> str | None:
    """Return the UUID of `parent.<name>` subgroup if already present.
    Looks inside the parent group's children list for `<UUID> /* <name> */`.
    """
    start, end = find_group_block(text, parent_uuid)
    children = text[start:end]
    marker = f"/* {name} */"
    if marker not in children:
        return None
    # Pull out the UUID immediately preceding the comment, e.g.
    # "\t\t\t\t31D6F0F0... /* Tutorial */,\n"
    line_end = children.index(marker)
    line_start = children.rfind("\n", 0, line_end) + 1
    line = children[line_start:line_end].strip()
    return line.split()[0]


def file_already_referenced(text: str, filename: str, marker: str) -> bool:
    """Idempotency check — look for `path = <filename>;` in the named PBX
    section. Scoping to the explicit `path = ...;` form avoids false
    positives from comments or other unrelated mentions of the filename
    (review CA1 S4)."""
    section_start = text.index(f"/* {marker} */")
    section_end = text.index(
        f"/* {marker.replace('Begin', 'End')} */", section_start
    )
    section = text[section_start:section_end]
    return f"path = {filename};" in section


def register_file(text: str, filename: str, group_uuid: str, sources_phase_uuid: str) -> str:
    if file_already_referenced(text, filename, "Begin PBXFileReference section"):
        print(f"  - {filename}: already registered, skipping")
        return text

    build_uuid = make_uuid()
    file_ref_uuid = make_uuid()

    text = add_pbx_buildfile(text, build_uuid, file_ref_uuid, filename)
    text = add_pbx_filereference(text, file_ref_uuid, filename)
    text = add_to_group(text, group_uuid, file_ref_uuid, filename)
    text = add_to_sources_phase(text, sources_phase_uuid, build_uuid, filename)
    print(f"  + {filename}: build={build_uuid} ref={file_ref_uuid}")
    return text


def main() -> int:
    if not PBXPROJ.exists():
        print(f"error: {PBXPROJ} not found — run from Stir/ repo root", file=sys.stderr)
        return 1
    # Explicit utf-8 — `Path.write_text` defaults to platform encoding,
    # which trips on CI Linux runners. project.pbxproj is utf-8.
    text = PBXPROJ.read_text(encoding="utf-8")
    original = text

    print("Registering DesignSystem/Components files:")
    for f in DS_FILES:
        text = register_file(text, f, DS_COMPONENTS_GROUP, STIR_SOURCES_PHASE)

    # Features/Tutorial subgroup. If absent, create it first with no
    # children, then `register_file` will add each FEATURE_FILES entry
    # to it via the standard path. If present, just route into it.
    tutorial_group_uuid = find_existing_subgroup(text, FEATURES_GROUP, "Tutorial")
    if tutorial_group_uuid is None:
        tutorial_group_uuid = make_uuid()
        text = create_subgroup(
            text,
            FEATURES_GROUP,
            "Tutorial",
            tutorial_group_uuid,
            child_uuids_named=[],
        )
        print(f"  + Features/Tutorial group: {tutorial_group_uuid}")

    print("Registering Features/Tutorial files:")
    for f in FEATURE_FILES:
        text = register_file(text, f, tutorial_group_uuid, STIR_SOURCES_PHASE)

    print("Registering StirTests/Unit files:")
    for f in TEST_FILES:
        text = register_file(text, f, TESTS_UNIT_GROUP, TESTS_SOURCES_PHASE)

    if text == original:
        print("\nNothing to do — all files already registered.")
        return 0

    PBXPROJ.write_text(text, encoding="utf-8")
    print(f"\nWrote {PBXPROJ}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
