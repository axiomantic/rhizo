# tests/test_guide.py
# Automated tests for `locutus guide install`, `uninstall`, and `check`.

import subprocess
import tempfile
import os
from pathlib import Path

RHIZO_BIN = Path(__file__).parent.parent / "bin" / "rhizo"

def run_locutus(*args):
    cmd = [str(RHIZO_BIN)] + list(args)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr

def test_guide_install_new_file():
    with tempfile.TemporaryDirectory() as tmpdir:
        target = Path(tmpdir) / "AGENTS.md"
        assert not target.exists()

        code, out, err = run_locutus("guide", "install", str(target))
        assert code == 0, f"Failed: {err}"
        assert "Created" in out
        assert target.exists()

        content = target.read_text()
        assert "<!-- BEGIN RHIZO GUIDE [v1.5] -->" in content
        assert "<!-- END RHIZO GUIDE -->" in content
        assert "Rhizo Multi-Agent Coordination Guide" in content

def test_guide_install_preserves_custom_content():
    with tempfile.TemporaryDirectory() as tmpdir:
        target = Path(tmpdir) / "AGENTS.md"
        custom_header = "# Project Specific Agent Rules\n\nRule 1: Always write tests.\n\n"
        target.write_text(custom_header)

        code, out, err = run_locutus("guide", "install", str(target))
        assert code == 0, f"Failed: {err}"
        assert "Appended" in out

        content = target.read_text()
        assert custom_header.strip() in content
        assert "<!-- BEGIN RHIZO GUIDE [v1.5] -->" in content
        assert "<!-- END RHIZO GUIDE -->" in content

def test_guide_install_updates_in_place():
    with tempfile.TemporaryDirectory() as tmpdir:
        target = Path(tmpdir) / "AGENTS.md"
        custom_text = "# Custom Header\n\nKeep this text intact!\n\n"
        initial_block = (
            "<!-- BEGIN RHIZO GUIDE [v1.0] -->\n"
            "Old outdated guide body.\n"
            "<!-- END RHIZO GUIDE -->\n"
        )
        custom_footer = "\n\n# Custom Footer\nKeep this footer intact too!\n"
        target.write_text(custom_text + initial_block + custom_footer)

        code, out, err = run_locutus("guide", "install", str(target))
        assert code == 0, f"Failed: {err}"
        assert "Updated" in out

        content = target.read_text()
        assert "Keep this text intact!" in content
        assert "Keep this footer intact too!" in content
        assert "Old outdated guide body" not in content
        assert "<!-- BEGIN RHIZO GUIDE [v1.5] -->" in content
        assert "<!-- END RHIZO GUIDE -->" in content

def test_guide_uninstall_cleans_block():
    with tempfile.TemporaryDirectory() as tmpdir:
        target = Path(tmpdir) / "AGENTS.md"
        custom_text = "# Custom Notes\n\nPreserve these notes.\n\n"
        block = (
            "<!-- BEGIN RHIZO GUIDE [v1.0] -->\n"
            "Guide body to remove.\n"
            "<!-- END RHIZO GUIDE -->\n"
        )
        target.write_text(custom_text + block)

        code, out, err = run_locutus("guide", "uninstall", str(target))
        assert code == 0, f"Failed: {err}"
        assert "Successfully uninstalled" in out

        content = target.read_text()
        assert "Preserve these notes." in content
        assert "BEGIN RHIZO GUIDE" not in content
        assert "END RHIZO GUIDE" not in content
        assert "Guide body to remove" not in content

def test_guide_unbalanced_marker_fails_safe():
    with tempfile.TemporaryDirectory() as tmpdir:
        target = Path(tmpdir) / "AGENTS.md"
        # Only BEGIN marker, no END marker (corrupt/malformed)
        corrupted = (
            "# Notes\n\n"
            "<!-- BEGIN RHIZO GUIDE [v1.0] -->\n"
            "Accidentally missing end marker!\n"
            "Important content that must not be deleted.\n"
        )
        target.write_text(corrupted)

        # Install must fail and not corrupt file
        code, out, err = run_locutus("guide", "install", str(target))
        assert code != 0
        assert "Malformed markers detected" in err or "Malformed" in out
        assert target.read_text() == corrupted, "File was modified despite malformed markers!"

        # Uninstall must also fail and not corrupt file
        code, out, err = run_locutus("guide", "uninstall", str(target))
        assert code != 0
        assert "Malformed markers detected" in err or "Malformed" in out
        assert target.read_text() == corrupted, "File was modified despite malformed markers!"

def test_guide_check_status():
    with tempfile.TemporaryDirectory() as tmpdir:
        target = Path(tmpdir) / "AGENTS.md"

        # Missing
        code, out, err = run_locutus("guide", "check", str(target))
        assert code == 0
        assert "[MISSING]" in out

        # Not found
        target.write_text("# Hello World\n")
        code, out, err = run_locutus("guide", "check", str(target))
        assert code == 0
        assert "[NOT FOUND]" in out

        # Installed
        run_locutus("guide", "install", str(target))
        code, out, err = run_locutus("guide", "check", str(target))
        assert code == 0
        assert "[INSTALLED]" in out
