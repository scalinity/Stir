#!/usr/bin/env python3
"""
SCA-89: Exhaustive-switch verification for staged Swift commits.

When a commit adds a new `case` to an `enum` under `Stir/Core/` or
`Stir/Shared/`, every exhaustive `switch` on that enum elsewhere in
the codebase must either gain an arm for the new case or carry a
`default:` / `@unknown default:` clause. Otherwise downstream files
break at compile time — caught only by `xcodebuild`, which is the
slow path. This hook surfaces the issue at commit time.

Algorithm:
  1. List staged Swift files under Stir/Core/ or Stir/Shared/.
  2. Per file, parse `git diff --cached -U10000` to identify added
     `case <name>` lines + walk back to the enclosing `enum <Name>`
     declaration via brace-depth tracking. (Brace tracking is naive
     but Swift code in this repo is regular enough that it holds.)
  3. For each enum that gained cases, collect the full set of
     existing case names (post-stage) by re-scanning the enum block.
  4. grep the entire `Stir/` tree for switch blocks that mention any
     sibling case — that's the heuristic for "this switch is over
     EnumName". Switches with no shared sibling reference are out
     of scope.
  5. For each candidate switch block, scan the lines from `switch`
     to the matching `}` for:
       - presence of the new case name → covered, OK
       - presence of `default:` or `@unknown default:` → exempt
       - otherwise → violation
  6. Exit 1 with a file:line + enum name + missing-case report if
     any violation found. Exit 0 otherwise.

Override:
  SKIP_PRECOMMIT_EXHAUSTIVE_CHECK=1 git commit ...

Limitations (deliberate, documented for future tightening):
  - Brace-depth tracking does not respect string literals / comments.
    For Swift code in this repo (no enum-decl-inside-string), false
    positives are rare. If they happen, override + file SCA-89-FOLLOWUP.
  - The "sibling case mention" heuristic is an under-approximation:
    a switch that only mentions the newly-added case (e.g. via earlier
    refactor) wouldn't be flagged. That's compile-safe and benign.
  - Multi-line `case X, Y, Z:` enum cases get parsed line-by-line —
    only the first identifier is tracked. Works for current Stir
    enums; tighten if a future enum splits cases across lines.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path


def run(cmd: list[str], cwd: str | None = None) -> str:
    """Run a command and return stdout, treating non-zero as empty output."""
    try:
        return subprocess.check_output(cmd, cwd=cwd, stderr=subprocess.DEVNULL).decode()
    except subprocess.CalledProcessError:
        return ""


def main() -> int:
    if os.environ.get("SKIP_PRECOMMIT_EXHAUSTIVE_CHECK", "0") == "1":
        print(
            "[pre-commit] ⚠️  BYPASSING exhaustive-switch check via "
            "SKIP_PRECOMMIT_EXHAUSTIVE_CHECK=1"
        )
        return 0

    repo_root = run(["git", "rev-parse", "--show-toplevel"]).strip()
    if not repo_root:
        return 0  # not in a git repo; nothing to do

    # Step 1: staged Swift files under Stir/Core/ or Stir/Shared/
    listing = run(
        [
            "git",
            "diff",
            "--cached",
            "--name-only",
            "--diff-filter=AM",
            "--",
            "Stir/Core/",
            "Stir/Shared/",
        ],
        cwd=repo_root,
    )
    staged = [p for p in listing.strip().split("\n") if p.endswith(".swift")]
    if not staged:
        return 0

    # Step 2: parse added cases per enum
    added_cases: dict[str, set[str]] = {}  # enum_name -> set of new case names
    enum_locations: dict[str, str] = {}  # enum_name -> "file:line"

    for rel_path in staged:
        # Get post-stage content + the unified diff with line numbers
        try:
            staged_content = subprocess.check_output(
                ["git", "show", f":{rel_path}"], cwd=repo_root
            ).decode()
        except subprocess.CalledProcessError:
            continue

        diff = run(["git", "diff", "--cached", "-U0", "--", rel_path], cwd=repo_root)
        added_lineno_set = set()
        cur = None
        for line in diff.split("\n"):
            m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)?", line)
            if m:
                cur = int(m.group(1))
                continue
            if line.startswith("+++") or line.startswith("---"):
                continue
            if line.startswith("+") and cur is not None:
                added_lineno_set.add(cur)
                cur += 1
            elif not line.startswith("-"):
                if cur is not None:
                    cur += 1

        # Walk the file building a (lineno -> enum_name) map via brace tracking
        line_to_enum: dict[int, str] = {}
        line_to_enum_decl_line: dict[str, int] = {}
        stack: list[tuple[str, int]] = []  # (enum_name, depth_at_decl)
        depth = 0
        for lineno, raw in enumerate(staged_content.split("\n"), 1):
            # Strip line comments for brace counting (Swift // comments)
            line_for_braces = re.sub(r"//.*$", "", raw)

            decl = re.match(
                r"^\s*(?:public|private|internal|fileprivate|open)?\s*"
                r"(?:indirect\s+)?enum\s+(\w+)",
                raw,
            )
            if decl:
                name = decl.group(1)
                stack.append((name, depth))
                line_to_enum_decl_line.setdefault(name, lineno)

            depth += line_for_braces.count("{") - line_for_braces.count("}")

            while stack and depth <= stack[-1][1]:
                stack.pop()

            if stack:
                line_to_enum[lineno] = stack[-1][0]

        # For each added line, if it's a case decl inside an enum, record it
        for lineno in added_lineno_set:
            raw = (
                staged_content.split("\n")[lineno - 1]
                if lineno - 1 < len(staged_content.split("\n"))
                else ""
            )
            cm = re.match(r"^\s*case\s+(\w+)", raw)
            if cm and lineno in line_to_enum:
                enum_name = line_to_enum[lineno]
                added_cases.setdefault(enum_name, set()).add(cm.group(1))
                enum_locations.setdefault(
                    enum_name,
                    f"{rel_path}:{line_to_enum_decl_line.get(enum_name, lineno)}",
                )

    if not added_cases:
        return 0

    # Step 3: collect ALL existing cases per touched enum (post-stage)
    all_cases: dict[str, set[str]] = {}
    for enum_name in added_cases:
        # grep the codebase for the enum declaration; read its block
        grep = run(
            [
                "grep",
                "-rln",
                "-E",
                rf"^\s*(public |private |internal |fileprivate |open )?(indirect )?enum\s+{enum_name}\b",
                "Stir/",
            ],
            cwd=repo_root,
        )
        decl_files = [p for p in grep.strip().split("\n") if p]
        for decl_file in decl_files:
            try:
                content = (Path(repo_root) / decl_file).read_text()
            except OSError:
                continue
            # Find the enum block by brace tracking from its decl
            depth = 0
            in_block = False
            for raw in content.split("\n"):
                line_for_braces = re.sub(r"//.*$", "", raw)
                if not in_block and re.match(
                    rf"^\s*(?:public|private|internal|fileprivate|open)?\s*"
                    rf"(?:indirect\s+)?enum\s+{enum_name}\b",
                    raw,
                ):
                    in_block = True
                    depth = line_for_braces.count("{") - line_for_braces.count("}")
                    if depth == 0 and "{" in line_for_braces:
                        depth = 1
                    continue
                if in_block:
                    depth += line_for_braces.count("{") - line_for_braces.count("}")
                    cm = re.match(r"^\s*case\s+(\w+)", raw)
                    if cm:
                        all_cases.setdefault(enum_name, set()).add(cm.group(1))
                    if depth <= 0:
                        in_block = False

    # Step 4 + 5: find switch blocks mentioning sibling cases; check exemption
    violations: list[tuple[str, int, str, set[str]]] = []
    # (file, switch_line, enum_name, missing_cases)

    for enum_name, new_cases in added_cases.items():
        siblings = all_cases.get(enum_name, set()) - new_cases
        if not siblings:
            # No siblings means this is a fresh enum with only the new case;
            # there can't be existing exhaustive switches on it. Skip.
            continue

        # Heuristic grep: find files that mention any sibling case via .<name>
        # We grep for the literal `case .<name>` (the canonical switch arm shape
        # in Swift), which is robust enough to identify candidate switch sites.
        sibling_pat = "|".join(re.escape(s) for s in siblings)
        candidate_files_raw = run(
            [
                "grep",
                "-rln",
                "-E",
                rf"\bcase\s+\.({sibling_pat})\b",
                "--include=*.swift",
                "Stir/",
            ],
            cwd=repo_root,
        )
        candidate_files = [p for p in candidate_files_raw.strip().split("\n") if p]

        for cf in candidate_files:
            try:
                content = (Path(repo_root) / cf).read_text()
            except OSError:
                continue
            lines = content.split("\n")
            i = 0
            while i < len(lines):
                line = lines[i]
                # Find a `switch` at start of line (after whitespace)
                if re.match(r"^\s*switch\b", line):
                    # Walk to matching close-brace
                    block_lines = []
                    block_depth = 0
                    found_open = False
                    j = i
                    while j < len(lines):
                        cur_for_braces = re.sub(r"//.*$", "", lines[j])
                        opens = cur_for_braces.count("{")
                        closes = cur_for_braces.count("}")
                        block_lines.append(lines[j])
                        if opens > 0:
                            found_open = True
                        block_depth += opens - closes
                        if found_open and block_depth <= 0:
                            break
                        j += 1
                    block = "\n".join(block_lines)

                    # Is this switch actually over our enum? Heuristic: it
                    # mentions at least one sibling case via `case .<name>`.
                    if not re.search(
                        rf"\bcase\s+\.({sibling_pat})\b", block
                    ):
                        i = j + 1
                        continue

                    # Exempt: explicit default: or @unknown default:
                    if re.search(r"^\s*(?:@unknown\s+)?default\s*:", block, re.M):
                        i = j + 1
                        continue

                    # Check coverage of the new cases
                    missing = set()
                    for nc in new_cases:
                        if not re.search(rf"\bcase\s+\.{re.escape(nc)}\b", block):
                            missing.add(nc)
                    if missing:
                        violations.append((cf, i + 1, enum_name, missing))
                    i = j + 1
                else:
                    i += 1

    if not violations:
        return 0

    # Step 6: report + exit 1
    print("[pre-commit] ❌ commit blocked — exhaustive-switch coverage gap")
    print()
    print("  SCA-89 — Swift switch statements over the modified enum(s) are")
    print("  not exhaustive after this commit. Add the new case(s) or a")
    print("  `default:` / `@unknown default:` arm.")
    print()
    by_file: dict[str, list[tuple[int, str, set[str]]]] = {}
    for path, lineno, enum_name, missing in violations:
        by_file.setdefault(path, []).append((lineno, enum_name, missing))
    for path, entries in sorted(by_file.items()):
        for lineno, enum_name, missing in sorted(entries):
            cases_list = ", ".join(sorted(missing))
            print(f"    {path}:{lineno}  switch on {enum_name}  missing case(s): {cases_list}")
    print()
    print("  to fix: add the missing case arms in each switch above, or add")
    print("  `default:` / `@unknown default:` if the switch is intentionally")
    print("  non-exhaustive on this enum.")
    print()
    print("  override (use sparingly; xcodebuild will still catch real gaps):")
    print("    SKIP_PRECOMMIT_EXHAUSTIVE_CHECK=1 git commit ...")
    return 1


if __name__ == "__main__":
    sys.exit(main())
