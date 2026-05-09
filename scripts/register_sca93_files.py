#!/usr/bin/env python3
"""Register SCA-93 Cook Mode top-bar restructure files into Stir.xcodeproj.

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
    python3 scripts/register_sca93_files.py
"""
from __future__ import annotations

import pathlib
import re
import secrets
import sys

PBXPROJ = pathlib.Path("Stir.xcodeproj/project.pbxproj")

# Group UUIDs for parents:
#   DS_COMPONENTS_GROUP   — Stir/DesignSystem/Components
#   MODELS_GROUP          — Stir/Core/Models
#   STIR_SOURCES_PHASE    — main app target's Sources phase
DS_COMPONENTS_GROUP = "FC78F4C13D0ACA458C7B83DB"
MODELS_GROUP = "66E65A7D462C7E09A4A58F08"
STIR_SOURCES_PHASE = "7CA84D64FE6B899A8EB4D38B"

FILES = [
    # (filename, parent_group_uuid)
    ("StepDots.swift", DS_COMPONENTS_GROUP),
    ("RecipePlan+Duration.swift", MODELS_GROUP),
]


def gen_uuid() -> str:
    """Return a 24-char uppercase-hex UUID, the format Xcode uses."""
    return secrets.token_hex(12).upper()


def main() -> int:
    text = PBXPROJ.read_text()

    for filename, parent_group_uuid in FILES:
        if filename in text:
            print(f"  [skip] {filename} already registered")
            continue

        build_uuid = gen_uuid()
        ref_uuid = gen_uuid()

        # Filenames with `+` need quoting in pbxproj path/name fields.
        path_field = f'"{filename}"' if "+" in filename else filename

        # 1. PBXBuildFile entry — insert before "/* End PBXBuildFile section */".
        build_line = (
            f"\t\t{build_uuid} /* {filename} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {ref_uuid} /* {filename} */; }};\n"
        )
        text = text.replace(
            "/* End PBXBuildFile section */",
            build_line + "/* End PBXBuildFile section */",
            1,
        )

        # 2. PBXFileReference entry — insert before "/* End PBXFileReference section */".
        ref_line = (
            f"\t\t{ref_uuid} /* {filename} */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
            f"path = {path_field}; sourceTree = \"<group>\"; }};\n"
        )
        text = text.replace(
            "/* End PBXFileReference section */",
            ref_line + "/* End PBXFileReference section */",
            1,
        )

        # 3. Add to parent group's children list.
        group_pattern = re.compile(
            rf"({re.escape(parent_group_uuid)} /\* [^*]+\*/ = \{{[^}}]*?children = \()([^)]*)\)",
            re.DOTALL,
        )
        match = group_pattern.search(text)
        if not match:
            print(f"  [error] could not find parent group {parent_group_uuid} for {filename}")
            return 1
        new_child_line = f"\t\t\t\t{ref_uuid} /* {filename} */,\n"
        text = (
            text[:match.start(2)]
            + match.group(2)
            + new_child_line
            + text[match.end(2):]
        )

        # 4. Add to the Stir target's Sources build phase.
        phase_pattern = re.compile(
            rf"({re.escape(STIR_SOURCES_PHASE)} /\* Sources \*/ = \{{[^}}]*?files = \()([^)]*)\)",
            re.DOTALL,
        )
        match = phase_pattern.search(text)
        if not match:
            print(f"  [error] could not find Sources phase {STIR_SOURCES_PHASE} for {filename}")
            return 1
        new_source_line = f"\t\t\t\t{build_uuid} /* {filename} in Sources */,\n"
        text = (
            text[:match.start(2)]
            + match.group(2)
            + new_source_line
            + text[match.end(2):]
        )

        print(f"  [add]  {filename}  (build={build_uuid}, ref={ref_uuid})")

    PBXPROJ.write_text(text)
    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
