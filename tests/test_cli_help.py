# tests/test_cli_help.py
# Automated tests verifying dedicated --help and -h handling across rhizo subcommands.
# Ensures that help requests exit 0 immediately and never block on Redis or touch network.

import subprocess
import os
from pathlib import Path

RHIZO_BIN = Path(__file__).parent.parent / "bin" / "rhizo"

def run_rhizo(*args, env=None, timeout=5):
    cmd = [str(RHIZO_BIN)] + list(args)
    run_env = os.environ.copy()
    if env:
        run_env.update(env)
    proc = subprocess.run(cmd, capture_output=True, text=True, env=run_env, timeout=timeout)
    return proc.returncode, proc.stdout, proc.stderr

def test_top_level_help():
    for flag in ["--help", "-h", "help"]:
        code, out, err = run_rhizo(flag)
        assert code == 0, f"Failed for {flag}: {err}"
        assert "Rhizo" in out
        assert "Usage:" in out
        assert "rhizo listen" in out

def test_listen_help_variants():
    # 1. rhizo listen --help
    code, out, err = run_rhizo("listen", "--help")
    assert code == 0, f"Error: {err}"
    assert "Usage: rhizo listen [name]" in out
    assert "--timeout" in out
    assert "--continuous" in out

    # 2. rhizo listen -h
    code, out, err = run_rhizo("listen", "-h")
    assert code == 0, f"Error: {err}"
    assert "Usage: rhizo listen [name]" in out

    # 3. rhizo listen <name> --help (previously would start listening or fail on agent)
    code, out, err = run_rhizo("listen", "mock-agent-xyz", "--help")
    assert code == 0, f"Error: {err}"
    assert "Usage: rhizo listen [name]" in out

    # 4. rhizo listen <name> -h
    code, out, err = run_rhizo("listen", "mock-agent-xyz", "-h")
    assert code == 0, f"Error: {err}"
    assert "Usage: rhizo listen [name]" in out

    # 5. rhizo help listen
    code, out, err = run_rhizo("help", "listen")
    assert code == 0, f"Error: {err}"
    assert "Usage: rhizo listen [name]" in out

    # 6. rhizo --help listen
    code, out, err = run_rhizo("--help", "listen")
    assert code == 0, f"Error: {err}"
    assert "Usage: rhizo listen [name]" in out

def test_messaging_subcommands_help():
    for subcmd in ["send", "reply", "broadcast", "request", "scatter"]:
        code, out, err = run_rhizo(subcmd, "--help")
        assert code == 0, f"{subcmd} --help failed: {err}"
        assert f"Usage: rhizo {subcmd}" in out

        code_h, out_h, err_h = run_rhizo(subcmd, "-h")
        assert code_h == 0, f"{subcmd} -h failed: {err_h}"
        assert f"Usage: rhizo {subcmd}" in out_h

def test_queue_and_lock_subcommands_help():
    for subcmd in ["open", "claim", "work", "lock", "unlock", "ack", "enqueue"]:
        code, out, err = run_rhizo(subcmd, "--help")
        assert code == 0, f"{subcmd} --help failed: {err}"
        assert f"Usage: rhizo {subcmd}" in out or f"Usage:\n  rhizo {subcmd}" in out

    # Sub-action claim renew
    code, out, err = run_rhizo("claim", "renew", "--help")
    assert code == 0
    assert "Usage: rhizo claim renew" in out

def test_inspection_and_cluster_subcommands_help():
    for subcmd in ["who", "probe", "watchdog", "leader", "status", "ping", "session"]:
        code, out, err = run_rhizo(subcmd, "--help")
        assert code == 0, f"{subcmd} --help failed: {err}"
        assert f"Usage: rhizo {subcmd}" in out or f"Usage:\n  rhizo {subcmd}" in out

def test_coordination_primitives_help():
    for subcmd in ["blackboard", "floor", "ballot", "workflow", "pulse", "cancel", "task", "decision", "audit"]:
        code, out, err = run_rhizo(subcmd, "--help")
        assert code == 0, f"{subcmd} --help failed: {err}"
        assert f"Usage: rhizo {subcmd}" in out or f"Usage:\n  rhizo {subcmd}" in out

def test_config_and_route_subaction_help():
    # route setup --help
    code, out, err = run_rhizo("route", "setup", "--help")
    assert code == 0
    assert "Usage: rhizo route setup" in out

    # config redis-persistence --help
    code, out, err = run_rhizo("config", "redis-persistence", "--help")
    assert code == 0
    assert "Usage: rhizo config redis-persistence" in out

def test_help_never_touches_redis():
    # Provide an unreachable Redis host; commands must still exit 0 immediately
    dead_redis = {"RHIZO_REDIS_URL": "redis://127.0.0.1:59999"}
    critical_subcmds = ["listen", "who", "lock", "unlock", "claim", "work", "probe", "watchdog"]
    for subcmd in critical_subcmds:
        code, out, err = run_rhizo(subcmd, "--help", env=dead_redis, timeout=2)
        assert code == 0, f"{subcmd} --help touched Redis or failed: {err}"
        assert f"Usage: rhizo {subcmd}" in out or f"Usage:\n  rhizo {subcmd}" in out

def test_unknown_subcommand_negative_control():
    code, out, err = run_rhizo("nonexistent-subcommand-xyz", "--help")
    assert code == 1
    assert "Error: Unknown subcommand" in err or "Unknown subcommand" in out

if __name__ == "__main__":
    test_top_level_help()
    test_listen_help_variants()
    test_messaging_subcommands_help()
    test_queue_and_lock_subcommands_help()
    test_inspection_and_cluster_subcommands_help()
    test_coordination_primitives_help()
    test_config_and_route_subaction_help()
    test_help_never_touches_redis()
    test_unknown_subcommand_negative_control()
    print("All test_cli_help.py tests passed successfully.")
