#!/usr/bin/env python3
"""
scripts/compile_rules.py
Compiles Cursor rules (.mdc) and GitHub Copilot instructions (.md)
directly from the canonical Rhizo Guide in AGENTS.md.

Usage:
    python3 scripts/compile_rules.py          # Compile and update rule files
    python3 scripts/compile_rules.py --check  # Verify files are up-to-date (CI check)
"""

import sys
import difflib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
AGENTS_MD = REPO_ROOT / "AGENTS.md"

BEGIN_MARKER = "<!-- BEGIN RHIZO GUIDE"
END_MARKER = "<!-- END RHIZO GUIDE -->"

CURSOR_HEADER = """---
description: Rhizo Multi-Agent Coordination Protocol & Harness Rules
globs: *
alwaysApply: true
---

<!-- AUTO-GENERATED FROM AGENTS.md BY scripts/compile_rules.py - DO NOT EDIT DIRECTLY -->

# Rhizo Multi-Agent Coordination Protocol for Cursor

"""

COPILOT_HEADER = """<!-- AUTO-GENERATED FROM AGENTS.md BY scripts/compile_rules.py - DO NOT EDIT DIRECTLY -->

# GitHub Copilot Instructions for Rhizo Multi-Agent Coordination

"""

def extract_guide_content(agents_path: Path) -> str:
    if not agents_path.exists():
        sys.stderr.write(f"Error: {agents_path} does not exist.\n")
        sys.exit(1)

    content = agents_path.read_text(encoding="utf-8")
    lines = content.splitlines()

    in_block = False
    extracted_lines = []

    for line in lines:
        if BEGIN_MARKER in line:
            in_block = True
            continue
        elif END_MARKER in line and in_block:
            in_block = False
            break

        if in_block:
            # Skip the generator instruction comment if present right after marker
            if "<!-- DO NOT EDIT DIRECTLY: Managed by" in line:
                continue
            extracted_lines.append(line)

    if not extracted_lines:
        # Fallback to entire content if markers were absent
        return content.strip() + "\n"

    # Trim leading/trailing blank lines
    text = "\n".join(extracted_lines).strip()
    return text + "\n"

def get_target_files(guide_body: str) -> dict[Path, str]:
    cursor_content = CURSOR_HEADER + guide_body
    copilot_content = COPILOT_HEADER + guide_body

    targets = {
        REPO_ROOT / "skills" / "rhizo" / "rules" / "cursor-rules.mdc": cursor_content,
        REPO_ROOT / "skills" / "rhizo" / "rules" / "copilot-instructions.md": copilot_content,
    }

    # Also update repo-level .github / .cursor files if those directories exist
    github_dir = REPO_ROOT / ".github"
    if github_dir.is_dir():
        targets[github_dir / "copilot-instructions.md"] = copilot_content

    cursor_dir = REPO_ROOT / ".cursor" / "rules"
    if cursor_dir.is_dir():
        targets[cursor_dir / "rhizo.mdc"] = cursor_content

    return targets

def main() -> int:
    check_mode = "--check" in sys.argv

    guide_body = extract_guide_content(AGENTS_MD)
    targets = get_target_files(guide_body)

    has_diff = False

    for target_path, expected_content in targets.items():
        if not target_path.exists():
            if check_mode:
                sys.stderr.write(f"DRIFT: Target file missing: {target_path.relative_to(REPO_ROOT)}\n")
                has_diff = True
                continue
            else:
                target_path.parent.mkdir(parents=True, exist_ok=True)

        current_content = target_path.read_text(encoding="utf-8") if target_path.exists() else ""

        if current_content != expected_content:
            if check_mode:
                sys.stderr.write(f"DRIFT: File out of sync with AGENTS.md: {target_path.relative_to(REPO_ROOT)}\n")
                diff = difflib.unified_diff(
                    current_content.splitlines(keepends=True),
                    expected_content.splitlines(keepends=True),
                    fromfile=str(target_path.relative_to(REPO_ROOT)),
                    tofile=f"{target_path.relative_to(REPO_ROOT)} (compiled from AGENTS.md)",
                )
                sys.stderr.writelines(diff)
                has_diff = True
            else:
                target_path.parent.mkdir(parents=True, exist_ok=True)
                target_path.write_text(expected_content, encoding="utf-8")
                print(f"Compiled: {target_path.relative_to(REPO_ROOT)}")
        else:
            if not check_mode:
                print(f"Up to date: {target_path.relative_to(REPO_ROOT)}")

    # Also verify/synchronize root SKILL.md with skills/rhizo/SKILL.md
    canonical_skill = REPO_ROOT / "skills" / "rhizo" / "SKILL.md"
    root_skill = REPO_ROOT / "SKILL.md"
    if canonical_skill.exists() and root_skill.exists() and not root_skill.is_symlink():
        canonical_text = canonical_skill.read_text(encoding="utf-8")
        root_text = root_skill.read_text(encoding="utf-8")
        if canonical_text != root_text:
            if check_mode:
                sys.stderr.write("DRIFT: Root SKILL.md is out of sync with skills/rhizo/SKILL.md\n")
                has_diff = True
            else:
                root_skill.write_text(canonical_text, encoding="utf-8")
                print("Synchronized: SKILL.md from skills/rhizo/SKILL.md")

    if check_mode:
        if has_diff:
            sys.stderr.write(
                "\nError: Rule or skill files are out of sync.\n"
                "Run 'python3 scripts/compile_rules.py' to recompile them and commit the changes.\n"
            )
            return 1
        print("All rule files are up to date with AGENTS.md.")
        return 0

    print("Rule compilation completed successfully.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
