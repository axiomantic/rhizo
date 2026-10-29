#!/usr/bin/env python3
# tests/test_task_claim_strand.py
# Verification of rhizo task claim actual strand_path consumption, validation, and persistence.

import os
import sys
import json
import shutil
import tempfile
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
RHIZO_BIN = REPO_ROOT / "bin" / ("rhizo.exe" if sys.platform == "win32" else "rhizo")

assert RHIZO_BIN.exists(), f"Rhizo binary not found at {RHIZO_BIN}"

def run_cmd(cmd, env=None, cwd=None):
    proc_env = os.environ.copy()
    if env:
        proc_env.update(env)
    if isinstance(cmd, list):
        res = subprocess.run(cmd, capture_output=True, text=True, env=proc_env, cwd=cwd)
    else:
        res = subprocess.run(cmd, shell=True, capture_output=True, text=True, env=proc_env, cwd=cwd)
    return res.returncode, res.stdout, res.stderr

def write_mock_vine(bin_dir: Path, response_type: str, custom_path: str = ""):
    """Creates cross-platform mock vine executable (shell script for POSIX and .bat/.cmd for Windows)."""
    # 1. POSIX shell script
    sh_script = bin_dir / "vine"
    if response_type == "success":
        escaped_path = custom_path.replace("\\", "\\\\")
        sh_script.write_text(f"""#!/bin/sh
if [ "$1" = "new" ]; then
  cat <<EOF
{{
  "status": "created",
  "task_id": "$2",
  "project": "proj",
  "strand_path": "{escaped_path}",
  "branch": "strand/$2",
  "tool": "git-worktree"
}}
EOF
  exit 0
fi
exit 1
""")
    elif response_type == "fail":
        sh_script.write_text("""#!/bin/sh
echo "Fatal: workspace allocation failed" >&2
exit 1
""")
    elif response_type == "invalid_json":
        sh_script.write_text("""#!/bin/sh
echo "Not JSON at all"
exit 0
""")
    elif response_type == "missing_path":
        sh_script.write_text("""#!/bin/sh
echo '{"status": "created"}'
exit 0
""")
    elif response_type == "ghost_path":
        escaped_path = custom_path.replace("\\", "\\\\")
        sh_script.write_text(f"""#!/bin/sh
echo '{{"status": "created", "strand_path": "{escaped_path}"}}'
exit 0
""")
    sh_script.chmod(0o755)

    # 2. Windows batch script
    cmd_script = bin_dir / "vine.cmd"
    bat_script = bin_dir / "vine.bat"
    if response_type == "success":
        escaped_path = custom_path.replace("\\", "\\\\")
        body = f"""@echo off
if "%~1"=="new" (
  echo {{"status": "created", "task_id": "%~2", "project": "proj", "strand_path": "{escaped_path}", "branch": "strand/%~2", "tool": "git-worktree"}}
  exit /b 0
)
exit /b 1
"""
    elif response_type == "fail":
        body = """@echo off
echo Fatal: workspace allocation failed 1>&2
exit /b 1
"""
    elif response_type == "invalid_json":
        body = """@echo off
echo Not JSON at all
exit /b 0
"""
    elif response_type == "missing_path":
        body = """@echo off
echo {"status": "created"}
exit /b 0
"""
    elif response_type == "ghost_path":
        escaped_path = custom_path.replace("\\", "\\\\")
        body = f"""@echo off
echo {{"status": "created", "strand_path": "{escaped_path}"}}
exit /b 0
"""
    cmd_script.write_text(body)
    bat_script.write_text(body)

def test_task_claim_actual_strand_path():
    with tempfile.TemporaryDirectory(prefix="rhizo_claim_test_") as tmpdir:
        tmp_path = Path(tmpdir)
        bin_dir = tmp_path / "bin"
        bin_dir.mkdir()
        home_dir = tmp_path / "home"
        home_dir.mkdir()

        # Custom workspace with spaces in path
        custom_workspace = tmp_path / "custom spaces workspace" / "task-101" / "proj"
        custom_workspace.mkdir(parents=True)

        write_mock_vine(bin_dir, "success", str(custom_workspace))

        env = {
            "PATH": os.pathsep.join([str(bin_dir), os.environ.get("PATH", "")]),
            "HOME": str(home_dir),
            "RHIZO_AGENT_NAME": "test-worker-1",
            "RHIZO_PREFIX": f"test_strand_{os.getpid()}:"
        }

        # 1. Create task first
        code, out, err = run_cmd([str(RHIZO_BIN), "task", "create", "task-101", "--title", "Test Task with Strand"], env=env, cwd=tmpdir)
        assert code == 0, f"Failed to create task: {err}"

        # 2. Claim task - should invoke mock vine and capture custom_workspace
        code, out, err = run_cmd([str(RHIZO_BIN), "task", "claim", "task-101", "--lease", "600"], env=env, cwd=tmpdir)
        assert code == 0, f"Failed to claim task: {err}\nStdout: {out}"
        resolved_custom = str(custom_workspace.resolve())
        assert (f"strand: {custom_workspace}" in out or f"strand: {resolved_custom}" in out or custom_workspace.name in out), f"User-visible output missing actual strand path: {out}"
        assert "[VINE] Provisioned isolated strand:" in err, f"Stderr missing vine notice: {err}"

        # 3. Verify Redis task record via task get --json
        code, out, err = run_cmd([str(RHIZO_BIN), "task", "get", "task-101", "--json"], env=env, cwd=tmpdir)
        assert code == 0, f"task get failed: {err}"
        task_data = json.loads(out)
        claimed_path = task_data.get("strand_path", "")
        assert claimed_path in [str(custom_workspace), resolved_custom] or Path(claimed_path).resolve() == custom_workspace.resolve(), f"Redis task record missing strand_path: {task_data}"
        assert task_data.get("state") == "IN_PROGRESS"
        assert task_data.get("owner") == "test-worker-1"

def test_task_claim_explicit_strand_override():
    with tempfile.TemporaryDirectory(prefix="rhizo_claim_override_") as tmpdir:
        tmp_path = Path(tmpdir)
        home_dir = tmp_path / "home"
        home_dir.mkdir()
        explicit_strand = tmp_path / "explicit_dir"
        explicit_strand.mkdir()

        env = {
            "HOME": str(home_dir),
            "RHIZO_AGENT_NAME": "test-worker-2",
            "RHIZO_PREFIX": f"test_strand_{os.getpid()}:"
        }

        code, out, err = run_cmd([str(RHIZO_BIN), "task", "create", "task-102", "--title", "Override Test"], env=env, cwd=tmpdir)
        assert code == 0

        # Pass explicit --strand
        code, out, err = run_cmd([str(RHIZO_BIN), "task", "claim", "task-102", "--strand", str(explicit_strand)], env=env, cwd=tmpdir)
        assert code == 0, f"claim with --strand failed: {err}"
        resolved_explicit = str(explicit_strand.resolve())
        assert (f"strand: {explicit_strand}" in out or f"strand: {resolved_explicit}" in out or explicit_strand.name in out)

        code, out, err = run_cmd([str(RHIZO_BIN), "task", "get", "task-102", "--json"], env=env, cwd=tmpdir)
        assert code == 0
        task_data = json.loads(out)
        claimed_path = task_data.get("strand_path", "")
        assert claimed_path in [str(explicit_strand), resolved_explicit] or Path(claimed_path).resolve() == explicit_strand.resolve()

        # Negative control: non-existent strand path must fail
        code, out, err = run_cmd([str(RHIZO_BIN), "task", "create", "task-103", "--title", "Bad Strand Test"], env=env, cwd=tmpdir)
        assert code == 0
        non_existent = tmp_path / "does_not_exist"
        code, out, err = run_cmd([str(RHIZO_BIN), "task", "claim", "task-103", "--strand", str(non_existent)], env=env, cwd=tmpdir)
        assert code != 0, "Claim with non-existent strand path should have failed"
        assert "Specified strand path does not exist on disk" in err

def test_task_claim_no_vine_flag():
    with tempfile.TemporaryDirectory(prefix="rhizo_claim_novine_") as tmpdir:
        tmp_path = Path(tmpdir)
        home_dir = tmp_path / "home"
        home_dir.mkdir()

        env = {
            "HOME": str(home_dir),
            "RHIZO_AGENT_NAME": "test-worker-3",
            "RHIZO_PREFIX": f"test_strand_{os.getpid()}:"
        }

        code, out, err = run_cmd([str(RHIZO_BIN), "task", "create", "task-104", "--title", "No Vine Test"], env=env, cwd=tmpdir)
        assert code == 0

        code, out, err = run_cmd([str(RHIZO_BIN), "task", "claim", "task-104", "--no-vine"], env=env, cwd=tmpdir)
        assert code == 0, f"claim with --no-vine failed: {err}"
        assert "strand:" not in out
        assert "CLAIMED task 'task-104' for worker 'test-worker-3'" in out

        code, out, err = run_cmd([str(RHIZO_BIN), "task", "get", "task-104", "--json"], env=env, cwd=tmpdir)
        assert code == 0
        task_data = json.loads(out)
        assert task_data.get("strand_path", "") == ""

def test_task_claim_vine_failure_handling():
    with tempfile.TemporaryDirectory(prefix="rhizo_claim_fail_") as tmpdir:
        tmp_path = Path(tmpdir)
        bin_dir = tmp_path / "bin"
        bin_dir.mkdir()
        home_dir = tmp_path / "home"
        home_dir.mkdir()

        # 1. Mock vine that fails with exit code 1
        write_mock_vine(bin_dir, "fail")

        env = {
            "PATH": os.pathsep.join([str(bin_dir), os.environ.get("PATH", "")]),
            "HOME": str(home_dir),
            "RHIZO_AGENT_NAME": "test-worker-4",
            "RHIZO_PREFIX": f"test_strand_{os.getpid()}:"
        }

        code, out, err = run_cmd([str(RHIZO_BIN), "task", "create", "task-105", "--title", "Fail Test"], env=env, cwd=tmpdir)
        assert code == 0

        code, out, err = run_cmd([str(RHIZO_BIN), "task", "claim", "task-105"], env=env, cwd=tmpdir)
        assert code != 0, "Claim must fail when vine new fails"
        assert "vine new" in err and "failed" in err
        assert "Fatal: workspace allocation failed" in err

        # Verify task was NOT claimed
        code, out, err = run_cmd([str(RHIZO_BIN), "task", "get", "task-105", "--json"], env=env, cwd=tmpdir)
        assert code == 0
        task_data = json.loads(out)
        assert task_data.get("state") == "QUEUED"
        assert task_data.get("owner", "") == ""

        # 2. Mock vine that returns invalid JSON
        write_mock_vine(bin_dir, "invalid_json")
        code, out, err = run_cmd([str(RHIZO_BIN), "task", "claim", "task-105"], env=env, cwd=tmpdir)
        assert code != 0, "Claim must fail when vine new returns invalid JSON"
        assert "Failed to parse Vine output as JSON" in err

        # 3. Mock vine that returns JSON missing strand_path
        write_mock_vine(bin_dir, "missing_path")
        code, out, err = run_cmd([str(RHIZO_BIN), "task", "claim", "task-105"], env=env, cwd=tmpdir)
        assert code != 0, "Claim must fail when vine new returns JSON missing strand_path"
        assert "Vine output missing valid 'strand_path'" in err

        # 4. Mock vine that returns path that doesn't exist on disk
        non_existent = tmp_path / "ghost_strand"
        write_mock_vine(bin_dir, "ghost_path", str(non_existent))
        code, out, err = run_cmd([str(RHIZO_BIN), "task", "claim", "task-105"], env=env, cwd=tmpdir)
        assert code != 0, "Claim must fail when provisioned directory does not exist on disk"
        assert "Provisioned strand path does not exist on disk" in err

if __name__ == "__main__":
    test_task_claim_actual_strand_path()
    test_task_claim_explicit_strand_override()
    test_task_claim_no_vine_flag()
    test_task_claim_vine_failure_handling()
    print("All rhizo task claim strand path tests passed successfully!")
