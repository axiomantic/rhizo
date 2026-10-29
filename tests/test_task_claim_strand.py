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
    res = subprocess.run(cmd, shell=True, capture_output=True, text=True, env=proc_env, cwd=cwd)
    return res.returncode, res.stdout, res.stderr

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

        # Mock vine that outputs valid JSON with custom workspace path
        mock_vine = bin_dir / "vine"
        mock_vine.write_text(f"""#!/bin/sh
if [ "$1" = "new" ]; then
  cat <<EOF
{{
  "status": "created",
  "task_id": "$2",
  "project": "proj",
  "strand_path": "{custom_workspace}",
  "branch": "strand/$2",
  "tool": "git-worktree"
}}
EOF
  exit 0
fi
exit 1
""")
        mock_vine.chmod(0o755)

        env = {
            "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
            "HOME": str(home_dir),
            "RHIZO_AGENT_NAME": "test-worker-1",
            "RHIZO_PREFIX": f"test_strand_{os.getpid()}:"
        }

        # 1. Create task first
        code, out, err = run_cmd(f"{RHIZO_BIN} task create task-101 --title 'Test Task with Strand'", env=env, cwd=tmpdir)
        assert code == 0, f"Failed to create task: {err}"

        # 2. Claim task - should invoke mock vine and capture custom_workspace
        code, out, err = run_cmd(f"{RHIZO_BIN} task claim task-101 --lease 600", env=env, cwd=tmpdir)
        assert code == 0, f"Failed to claim task: {err}\nStdout: {out}"
        assert f"strand: {custom_workspace}" in out, f"User-visible output missing actual strand path: {out}"
        assert "[VINE] Provisioned isolated strand:" in err, f"Stderr missing vine notice: {err}"

        # 3. Verify Redis task record via task get --json
        code, out, err = run_cmd(f"{RHIZO_BIN} task get task-101 --json", env=env, cwd=tmpdir)
        assert code == 0, f"task get failed: {err}"
        task_data = json.loads(out)
        assert task_data.get("strand_path") == str(custom_workspace), f"Redis task record missing strand_path: {task_data}"
        assert task_data.get("state") == "IN_PROGRESS"
        assert task_data.get("owner") == "test-worker-1"

        # 4. Verify local mirror file
        mirror_file = home_dir / ".config" / "rhizo" / "current_task_test-worker-1.json"
        assert mirror_file.exists(), f"Local task mirror file not found at {mirror_file}"
        mirror_data = json.loads(mirror_file.read_text())
        assert mirror_data.get("strand_path") == str(custom_workspace), f"Mirror missing strand_path: {mirror_data}"
        assert mirror_data.get("task_id") == "task-101"
        assert mirror_data.get("owner") == "test-worker-1"

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

        code, out, err = run_cmd(f"{RHIZO_BIN} task create task-102 --title 'Override Test'", env=env, cwd=tmpdir)
        assert code == 0

        # Pass explicit --strand
        code, out, err = run_cmd(f"{RHIZO_BIN} task claim task-102 --strand '{explicit_strand}'", env=env, cwd=tmpdir)
        assert code == 0, f"claim with --strand failed: {err}"
        assert f"strand: {explicit_strand}" in out

        code, out, err = run_cmd(f"{RHIZO_BIN} task get task-102 --json", env=env, cwd=tmpdir)
        assert code == 0
        task_data = json.loads(out)
        assert task_data.get("strand_path") == str(explicit_strand)

        # Negative control: non-existent strand path must fail
        code, out, err = run_cmd(f"{RHIZO_BIN} task create task-103 --title 'Bad Strand Test'", env=env, cwd=tmpdir)
        assert code == 0
        non_existent = tmp_path / "does_not_exist"
        code, out, err = run_cmd(f"{RHIZO_BIN} task claim task-103 --strand '{non_existent}'", env=env, cwd=tmpdir)
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

        code, out, err = run_cmd(f"{RHIZO_BIN} task create task-104 --title 'No Vine Test'", env=env, cwd=tmpdir)
        assert code == 0

        code, out, err = run_cmd(f"{RHIZO_BIN} task claim task-104 --no-vine", env=env, cwd=tmpdir)
        assert code == 0, f"claim with --no-vine failed: {err}"
        assert "strand:" not in out
        assert "CLAIMED task 'task-104' for worker 'test-worker-3'" in out

        code, out, err = run_cmd(f"{RHIZO_BIN} task get task-104 --json", env=env, cwd=tmpdir)
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
        mock_vine = bin_dir / "vine"
        mock_vine.write_text("""#!/bin/sh
echo "Fatal: workspace allocation failed" >&2
exit 1
""")
        mock_vine.chmod(0o755)

        env = {
            "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
            "HOME": str(home_dir),
            "RHIZO_AGENT_NAME": "test-worker-4",
            "RHIZO_PREFIX": f"test_strand_{os.getpid()}:"
        }

        code, out, err = run_cmd(f"{RHIZO_BIN} task create task-105 --title 'Fail Test'", env=env, cwd=tmpdir)
        assert code == 0

        code, out, err = run_cmd(f"{RHIZO_BIN} task claim task-105", env=env, cwd=tmpdir)
        assert code != 0, "Claim must fail when vine new fails"
        assert "vine new task-105' failed" in err
        assert "Fatal: workspace allocation failed" in err

        # Verify task was NOT claimed
        code, out, err = run_cmd(f"{RHIZO_BIN} task get task-105 --json", env=env, cwd=tmpdir)
        assert code == 0
        task_data = json.loads(out)
        assert task_data.get("state") == "QUEUED"
        assert task_data.get("owner", "") == ""

        # 2. Mock vine that returns invalid JSON
        mock_vine.write_text("""#!/bin/sh
echo "Not JSON at all"
exit 0
""")
        code, out, err = run_cmd(f"{RHIZO_BIN} task claim task-105", env=env, cwd=tmpdir)
        assert code != 0, "Claim must fail when vine new returns invalid JSON"
        assert "Failed to parse Vine output as JSON" in err

        # 3. Mock vine that returns JSON missing strand_path
        mock_vine.write_text("""#!/bin/sh
echo '{"status": "created"}'
exit 0
""")
        code, out, err = run_cmd(f"{RHIZO_BIN} task claim task-105", env=env, cwd=tmpdir)
        assert code != 0, "Claim must fail when vine new returns JSON missing strand_path"
        assert "Vine output missing valid 'strand_path'" in err

        # 4. Mock vine that returns path that doesn't exist on disk
        non_existent = tmp_path / "ghost_strand"
        mock_vine.write_text(f"""#!/bin/sh
echo '{{"status": "created", "strand_path": "{non_existent}"}}'
exit 0
""")
        code, out, err = run_cmd(f"{RHIZO_BIN} task claim task-105", env=env, cwd=tmpdir)
        assert code != 0, "Claim must fail when provisioned directory does not exist on disk"
        assert "Provisioned strand path does not exist on disk" in err

def test_task_claim_real_vine_integration():
    real_vine_bin = Path("/Users/eek/Development/vine/bin/vine")
    if not real_vine_bin.exists():
        print("Skipping real vine integration test (binary not found)")
        return

    with tempfile.TemporaryDirectory(prefix="rhizo_real_vine_") as tmpdir:
        tmp_path = Path(tmpdir)
        repo_dir = tmp_path / "my real repo"
        repo_dir.mkdir()
        home_dir = tmp_path / "home"
        home_dir.mkdir()
        custom_workspaces = tmp_path / "custom spaces workspaces"
        custom_workspaces.mkdir()

        # Initialize git repo
        run_cmd(f"git init -b main -q '{repo_dir}'")
        run_cmd(f"git -C '{repo_dir}' config user.email test@axiomantic.mesh")
        run_cmd(f"git -C '{repo_dir}' config user.name 'Test Runner'")
        (repo_dir / "README.md").write_text("# Real Test Repo\n")
        run_cmd(f"git -C '{repo_dir}' add README.md")
        run_cmd(f"git -C '{repo_dir}' commit -q -m 'Initial commit'")

        env = {
            "PATH": f"{real_vine_bin.parent}:{os.environ.get('PATH', '')}",
            "HOME": str(home_dir),
            "RHIZO_AGENT_NAME": "real-worker",
            "RHIZO_PREFIX": f"test_real_vine_{os.getpid()}:",
            "VINE_WORKSPACES_DIR": str(custom_workspaces)
        }

        # 1. Create task
        code, out, err = run_cmd(f"{RHIZO_BIN} task create task-real-1 --title 'Real Vine Integration'", env=env, cwd=repo_dir)
        assert code == 0, f"Failed to create task: {err}"

        # 2. Claim task inside the git repo
        code, out, err = run_cmd(f"{RHIZO_BIN} task claim task-real-1 --lease 600", cwd=repo_dir, env=env)
        assert code == 0, f"Claim failed with real vine: {err}\nStdout: {out}"

        # 3. Verify user-visible output carries actual strand path inside custom_workspaces
        assert str(custom_workspaces) in out, f"Output does not contain custom workspace dir: {out}"
        assert "CLAIMED task 'task-real-1' for worker 'real-worker'" in out

        # 4. Verify task record in Redis
        code, out, err = run_cmd(f"{RHIZO_BIN} task get task-real-1 --json", env=env, cwd=repo_dir)
        assert code == 0
        task_data = json.loads(out)
        claimed_strand = task_data.get("strand_path")
        assert claimed_strand is not None and len(claimed_strand) > 0, "Redis task record missing strand_path"
        assert claimed_strand.startswith(str(custom_workspaces)), f"Strand path not under custom workspaces: {claimed_strand}"
        assert os.path.isdir(claimed_strand), f"Provisioned strand path does not exist on disk: {claimed_strand}"

        # 5. Verify local mirror
        mirror_file = home_dir / ".config" / "rhizo" / "current_task_real-worker.json"
        assert mirror_file.exists()
        mirror_data = json.loads(mirror_file.read_text())
        assert mirror_data.get("strand_path") == claimed_strand

if __name__ == "__main__":
    test_task_claim_actual_strand_path()
    test_task_claim_explicit_strand_override()
    test_task_claim_no_vine_flag()
    test_task_claim_vine_failure_handling()
    test_task_claim_real_vine_integration()
    print("All rhizo task claim strand path tests passed successfully!")
