#!/usr/bin/env python3
"""
test_hooks.py - Unit and integration tests for Rhizo lifecycle hooks.
Tests claude_stop_hook.py, codex_stop_hook.py, agy_stop_hook.py, and session_lifecycle_hook.py.
"""

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HOOKS_DIR = REPO_ROOT / "skills" / "rhizo" / "hooks"
BIN_RHIZO = REPO_ROOT / "bin" / ("rhizo.exe" if sys.platform == "win32" or (REPO_ROOT / "bin" / "rhizo.exe").exists() else "rhizo")
REDIS_URL = os.environ.get("RHIZO_REDIS_URL", os.environ.get("REDIS_URL", "redis://127.0.0.1:6379/0"))
TEST_PREFIX = "test_rhizo_hooks:"


class TestRhizoHooks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.env = os.environ.copy()
        cls.env["RHIZO_BIN"] = str(BIN_RHIZO)
        cls.env["RHIZO_REDIS_URL"] = REDIS_URL
        cls.env["REDIS_URL"] = REDIS_URL
        cls.env["RHIZO_REDIS_PREFIX"] = TEST_PREFIX
        cls.env["RHIZO_SECRET"] = "test-secret-key-32-chars-long!!"

    def run_hook(self, script_name: str, stdin_payload: dict, extra_args: list = None, env_overrides: dict = None) -> tuple[int, dict]:
        script_path = HOOKS_DIR / script_name
        env = self.env.copy()
        if env_overrides:
            env.update(env_overrides)

        cmd = [sys.executable, str(script_path)]
        if extra_args:
            cmd.extend(extra_args)

        proc = subprocess.run(
            cmd,
            input=json.dumps(stdin_payload),
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(proc.returncode, 0, f"{script_name} failed: {proc.stderr}")
        out_str = proc.stdout.strip()
        try:
            return proc.returncode, json.loads(out_str) if out_str else {}
        except json.JSONDecodeError:
            self.fail(f"Invalid JSON from {script_name}: {out_str}")

    def test_claude_stop_hook(self):
        agent = "test_claude_agent"
        inbox_key = f"{TEST_PREFIX}inbox:{agent}"
        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_key], capture_output=True)

        env_overrides = {"RHIZO_AGENT_NAME": agent}

        try:
            # 1. Empty inbox: returns empty object
            code, out = self.run_hook("claude_stop_hook.py", {"session_id": "ses_123"}, env_overrides=env_overrides)
            self.assertEqual(out, {})

            # 2. Send message
            subprocess.run([
                str(BIN_RHIZO), "--redis-url", REDIS_URL, "--prefix", TEST_PREFIX,
                "send", "--to", agent, "--from", "alice",
                "--subject", "Review Request", "--body", "Please review PR 99",
                "--urgency=soon"
            ], check=True, env=self.env)

            # 3. Non-empty inbox: returns block decision with additionalContext
            code, out = self.run_hook("claude_stop_hook.py", {"session_id": "ses_123"}, env_overrides=env_overrides)
            self.assertEqual(out.get("decision"), "block")
            self.assertTrue("1 new Rhizo bus message" in out.get("reason", ""))
            hook_out = out.get("hookSpecificOutput", {})
            self.assertEqual(hook_out.get("hookEventName"), "Stop")
            self.assertTrue("[RHIZO BUS]" in hook_out.get("additionalContext", ""))
            self.assertIn("Please review PR 99", hook_out.get("additionalContext", ""))

            # 4. Subsequent check is now empty
            code, out = self.run_hook("claude_stop_hook.py", {"session_id": "ses_123"}, env_overrides=env_overrides)
            self.assertEqual(out, {})

            # 5. Tasks in flight but no listener: returns block decision to re-arm listener
            subprocess.run([
                str(BIN_RHIZO), "--redis-url", REDIS_URL, "--prefix", TEST_PREFIX,
                "enqueue", "test_hook_q", "--subject", "Task in flight", "--body", '{"id":"t-hook-1"}'
            ], check=True, env=self.env)

            code, out = self.run_hook("claude_stop_hook.py", {"session_id": "ses_123"}, env_overrides=env_overrides)
            self.assertEqual(out.get("decision"), "block")
            self.assertIn("Rhizo listener missing", out.get("reason", ""))
            self.assertIn("[RHIZO WATCHDOG WARNING]", out.get("hookSpecificOutput", {}).get("additionalContext", ""))

            # Clean up queue
            subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", f"{TEST_PREFIX}queue:test_hook_q", f"{TEST_PREFIX}queue:{{test_hook_q}}"], capture_output=True)
        finally:
            subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_key, f"{TEST_PREFIX}queue:test_hook_q", f"{TEST_PREFIX}queue:{{test_hook_q}}"], capture_output=True)

    def test_codex_stop_hook(self):
        agent = "test_codex_agent"
        inbox_key = f"{TEST_PREFIX}inbox:{agent}"
        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_key], capture_output=True)

        env_overrides = {"RHIZO_AGENT_NAME": agent}

        try:
            # 1. Empty inbox: returns empty object
            code, out = self.run_hook("codex_stop_hook.py", {"session_id": "codex_ses_456", "turn_id": "t1"}, env_overrides=env_overrides)
            self.assertEqual(out, {})

            # 2. Send message
            subprocess.run([
                str(BIN_RHIZO), "--redis-url", REDIS_URL, "--prefix", TEST_PREFIX,
                "send", "--to", agent, "--from", "lead_dev",
                "--subject", "Deploy Staging", "--body", "Run deploy script now",
                "--immediate"
            ], check=True, env=self.env)

            # 3. Non-empty inbox: returns block with reason as next prompt
            code, out = self.run_hook("codex_stop_hook.py", {"session_id": "codex_ses_456", "turn_id": "t1"}, env_overrides=env_overrides)
            self.assertEqual(out.get("decision"), "block")
            reason_text = out.get("reason", "")
            self.assertTrue("[RHIZO BUS]" in reason_text)
            self.assertIn("Deploy Staging", reason_text)
            self.assertIn("Run deploy script now", reason_text)
            self.assertIn("urgency: immediate", reason_text)
        finally:
            subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_key], capture_output=True)

    def test_agy_stop_hook(self):
        agent = "test_agy_agent"
        inbox_key = f"{TEST_PREFIX}inbox:{agent}"
        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_key], capture_output=True)

        env_overrides = {"RHIZO_AGENT_NAME": agent}

        try:
            # 1. Empty inbox: returns empty object
            code, out = self.run_hook("agy_stop_hook.py", {"conversationId": "conv_789"}, env_overrides=env_overrides)
            self.assertEqual(out, {})

            # 2. Send message
            subprocess.run([
                str(BIN_RHIZO), "--redis-url", REDIS_URL, "--prefix", TEST_PREFIX,
                "send", "--to", agent, "--from", "qa_bot",
                "--subject", "Tests Complete", "--body", "All 50 unit tests passed",
            ], check=True, env=self.env)

            # 3. Non-empty inbox: returns continue with reason
            code, out = self.run_hook("agy_stop_hook.py", {"conversationId": "conv_789"}, env_overrides=env_overrides)
            self.assertEqual(out.get("decision"), "continue")
            self.assertIn("Tests Complete", out.get("reason", ""))
            self.assertIn("All 50 unit tests passed", out.get("reason", ""))
        finally:
            subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_key], capture_output=True)

    def test_session_lifecycle_hook(self):
        sid = "lifecycle_test_session"
        agent = "test_lifecycle_agent"
        env_overrides = {"RHIZO_AGENT_NAME": agent}

        # 1. SessionStart registers agent
        code, out = self.run_hook(
            "session_lifecycle_hook.py",
            {"session_id": sid, "hook_event_name": "SessionStart"},
            extra_args=["start"],
            env_overrides=env_overrides,
        )
        self.assertIn("hookSpecificOutput", out)
        self.assertEqual(out["hookSpecificOutput"]["hookEventName"], "SessionStart")
        self.assertIn(f"@{agent}", out["hookSpecificOutput"]["additionalContext"])

        # 2. SessionEnd deregisters agent
        code, out = self.run_hook(
            "session_lifecycle_hook.py",
            {"session_id": sid, "hook_event_name": "SessionEnd"},
            extra_args=["end"],
            env_overrides=env_overrides,
        )
        self.assertEqual(out, {})

    def test_harness_session_prefixes(self):
        """Test pi:, cursor:, and copilot: session mapping, resolution, and CLI inheritance."""
        harnesses = [
            ("pi", "pi:ses_pi_alpha", "pi-reviewer"),
            ("cursor", "cursor:ses_cur_beta", "cursor-coder"),
            ("copilot", "copilot:ses_cop_gamma", "copilot-assistant"),
        ]

        for harness_name, session_key, agent_name in harnesses:
            # 1. Set session mapping via CLI
            res_set = subprocess.run([
                str(BIN_RHIZO), "--redis-url", REDIS_URL, "--prefix", TEST_PREFIX,
                "session", "set", session_key, agent_name
            ], capture_output=True, text=True, env=self.env)
            self.assertEqual(res_set.returncode, 0, f"session set failed for {session_key}: {res_set.stderr}")
            self.assertIn(f"OK [session] {session_key} -> {agent_name}", res_set.stdout)

            # 2. Get session mapping via CLI
            res_get = subprocess.run([
                str(BIN_RHIZO), "--redis-url", REDIS_URL, "--prefix", TEST_PREFIX,
                "session", "get", session_key
            ], capture_output=True, text=True, env=self.env)
            self.assertEqual(res_get.returncode, 0)
            self.assertEqual(res_get.stdout.strip(), agent_name)

            # 3. Verify CLI commands inherit agent identity when RHIZO_SESSION_ID is set
            recipient = f"recip_{harness_name}"
            test_env = self.env.copy()
            test_env["RHIZO_SESSION_ID"] = session_key
            test_env.pop("RHIZO_AGENT_NAME", None)

            res_send = subprocess.run([
                str(BIN_RHIZO), "--redis-url", REDIS_URL, "--prefix", TEST_PREFIX,
                "send", "--to", recipient, "--subject", f"From {harness_name}", "--body", "Payload content"
            ], capture_output=True, text=True, env=test_env)
            self.assertEqual(res_send.returncode, 0, f"send with session {session_key} failed: {res_send.stderr}")

            # Verify message envelope sender in Redis
            res_drain = subprocess.run([
                str(BIN_RHIZO), "--redis-url", REDIS_URL, "--prefix", TEST_PREFIX,
                "drain", "1", recipient, "--json"
            ], capture_output=True, text=True, env=self.env)
            self.assertEqual(res_drain.returncode, 0)
            msg = json.loads(res_drain.stdout.strip())
            self.assertEqual(msg.get("from"), agent_name)

            # 4. Remove session mapping
            res_rm = subprocess.run([
                str(BIN_RHIZO), "--redis-url", REDIS_URL, "--prefix", TEST_PREFIX,
                "session", "remove", session_key
            ], capture_output=True, text=True, env=self.env)
            self.assertEqual(res_rm.returncode, 0)

    def test_native_hook_cli(self):
        """Test native rhizo hook codex-stop and rhizo hook install CLI commands."""
        agent = "test_native_hook_agent"
        inbox_key = f"{TEST_PREFIX}inbox:{agent}"
        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_key], capture_output=True)

        try:
            # 1. Unregistered agent -> returns empty object {}
            res = subprocess.run([
                str(BIN_RHIZO), "--redis-url", REDIS_URL, "--prefix", TEST_PREFIX,
                "hook", "stop", "--agent", agent
            ], capture_output=True, text=True, env=self.env)
            self.assertEqual(res.returncode, 0)
            self.assertEqual(json.loads(res.stdout.strip()), {})

            # 2. Registered agent with NO_LISTENER -> returns block decision
            subprocess.run([
                str(BIN_RHIZO), "--redis-url", REDIS_URL, "--prefix", TEST_PREFIX,
                "open", agent, "test"
            ], check=True, env=self.env)

            res = subprocess.run([
                str(BIN_RHIZO), "--redis-url", REDIS_URL, "--prefix", TEST_PREFIX,
                "hook", "stop", "--agent", agent
            ], capture_output=True, text=True, env=self.env)
            self.assertEqual(res.returncode, 0)
            data = json.loads(res.stdout.strip())
            self.assertEqual(data.get("decision"), "block")
            self.assertIn("listener is DEAD", data.get("reason", ""))
            self.assertIn(f"@{agent}", data.get("reason", ""))

            # 3. Message sent to agent -> returns block decision with message payload
            subprocess.run([
                str(BIN_RHIZO), "--redis-url", REDIS_URL, "--prefix", TEST_PREFIX,
                "send", "--from", "test_sender", "--to", agent,
                "--subject", "Critical Security Audit", "--body", "Investigate CVE-2026-99"
            ], check=True, env=self.env)

            res = subprocess.run([
                str(BIN_RHIZO), "--redis-url", REDIS_URL, "--prefix", TEST_PREFIX,
                "hook", "stop", "--agent", agent
            ], capture_output=True, text=True, env=self.env)
            self.assertEqual(res.returncode, 0)
            data = json.loads(res.stdout.strip())
            self.assertEqual(data.get("decision"), "block")
            self.assertIn("Critical Security Audit", data.get("reason", ""))
            self.assertIn("Investigate CVE-2026-99", data.get("reason", ""))

            # 4. Test rhizo hook install --codex
            import tempfile
            with tempfile.TemporaryDirectory() as tmpdir:
                res_inst = subprocess.run([
                    str(BIN_RHIZO), "hook", "install", "--codex", "--agent", agent
                ], capture_output=True, text=True, cwd=tmpdir)
                self.assertEqual(res_inst.returncode, 0)
                self.assertIn("Successfully installed", res_inst.stdout)

                hooks_json_path = Path(tmpdir) / ".codex" / "hooks.json"
                self.assertTrue(hooks_json_path.exists())
                with open(hooks_json_path, "r", encoding="utf-8") as f:
                    hooks_data = json.load(f)
                self.assertIn("hooks", hooks_data)
                self.assertIn("Stop", hooks_data["hooks"])
                stop_entry = hooks_data["hooks"]["Stop"][0]
                self.assertEqual(stop_entry.get("type"), "command")
                self.assertIn(f"rhizo hook codex-stop --agent {agent}", stop_entry.get("command", ""))
        finally:
            subprocess.run([
                str(BIN_RHIZO), "--redis-url", REDIS_URL, "--prefix", TEST_PREFIX,
                "close", agent
            ], capture_output=True, env=self.env)
            subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_key], capture_output=True)


if __name__ == "__main__":
    unittest.main()
