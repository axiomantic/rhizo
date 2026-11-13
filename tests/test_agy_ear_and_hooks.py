#!/usr/bin/env python3
"""
test_agy_ear_and_hooks.py - Comprehensive verification for Antigravity Continuous Ear (--agy-ear / rhizo ear)
and Antigravity lifecycle hooks (PreInvocation, PostToolUse, Stop).
"""

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BIN_RHIZO = REPO_ROOT / "bin" / ("rhizo.exe" if sys.platform == "win32" or (REPO_ROOT / "bin" / "rhizo.exe").exists() else "rhizo")
REDIS_URL = os.environ.get("RHIZO_REDIS_URL", os.environ.get("REDIS_URL", "redis://127.0.0.1:6379/0"))
TEST_PREFIX = "test_agy_rhizo:"


class TestAgyEarAndHooks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.env = os.environ.copy()
        cls.env["RHIZO_BIN"] = str(BIN_RHIZO)
        cls.env["RHIZO_REDIS_URL"] = REDIS_URL
        cls.env["REDIS_URL"] = REDIS_URL
        cls.env["RHIZO_REDIS_PREFIX"] = TEST_PREFIX
        cls.env["RHIZO_SECRET"] = "test-secret-key-32-chars-long!!"
        cls.env["RHIZO_EAR_DISABLED"] = "0"  # Enable ear for unit tests specifically
        cls.env["RHIZO_QUIET"] = "1"
        cls.env.pop("ANTIGRAVITY_CONVERSATION_ID", None)
        cls.env.pop("ANTIGRAVITY_LS_ADDRESS", None)
        cls.env.pop("ANTIGRAVITY_CSRF_TOKEN", None)
        cls.env.pop("ANTIGRAVITY_PROJECT_ID", None)

    def run_rhizo(self, args: list, stdin_text: str = None, env_overrides: dict = None, cwd: str = None) -> subprocess.CompletedProcess:
        env = self.env.copy()
        if env_overrides:
            env.update(env_overrides)
        cmd = [str(BIN_RHIZO), f"--redis-url={REDIS_URL}", f"--prefix={TEST_PREFIX}"] + args
        return subprocess.run(
            cmd,
            input=stdin_text,
            capture_output=True,
            text=True,
            env=env,
            cwd=cwd,
        )

    def test_hook_install_antigravity_local(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            agent = "test-agy-worker"
            res = self.run_rhizo(["hook", "install", "--antigravity", "--local", "--agent", agent], cwd=tmp_dir)
            self.assertEqual(res.returncode, 0, f"Hook install failed: {res.stderr}")
            self.assertIn("Successfully installed Rhizo Antigravity hooks", res.stdout)

            hooks_json = Path(tmp_dir) / ".agents" / "hooks.json"
            self.assertTrue(hooks_json.exists(), "hooks.json was not created")

            with open(hooks_json) as f:
                data = json.load(f)

            self.assertIn("rhizo", data)
            rhizo_hook = data["rhizo"]

            # PreInvocation check
            self.assertIn("PreInvocation", rhizo_hook)
            pre_inv = rhizo_hook["PreInvocation"]
            self.assertEqual(len(pre_inv), 1)
            self.assertEqual(pre_inv[0]["type"], "command")
            self.assertIn("hook agy-pre-invocation --agent test-agy-worker", pre_inv[0]["command"])
            self.assertEqual(pre_inv[0]["timeout"], 10)

            # PostToolUse check (must be grouped with matcher)
            self.assertIn("PostToolUse", rhizo_hook)
            post_tool = rhizo_hook["PostToolUse"]
            self.assertEqual(len(post_tool), 1)
            self.assertEqual(post_tool[0]["matcher"], "*")
            self.assertEqual(len(post_tool[0]["hooks"]), 1)
            self.assertEqual(post_tool[0]["hooks"][0]["type"], "command")
            self.assertIn("hook agy-post-tool --agent test-agy-worker", post_tool[0]["hooks"][0]["command"])

            # Stop check
            self.assertIn("Stop", rhizo_hook)
            stop_hook = rhizo_hook["Stop"]
            self.assertEqual(len(stop_hook), 1)
            self.assertEqual(stop_hook[0]["type"], "command")
            self.assertIn("hook agy-stop --agent test-agy-worker", stop_hook[0]["command"])

    def test_agy_pre_invocation_hook(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            agent = "test-preinv-agent"
            # Without strand file, returns {}
            res = self.run_rhizo(["hook", "agy-pre-invocation", "--agent", agent], cwd=tmp_dir)
            self.assertEqual(res.returncode, 0)
            self.assertEqual(res.stdout.strip(), "{}")

            # With .vine.json, injects ephemeralMessage
            vine_manifest = {
                "task_id": "task-xyz-123",
                "strand_path": "/tmp/strand-xyz",
                "status": "IN_PROGRESS",
            }
            with open(Path(tmp_dir) / ".vine.json", "w") as f:
                json.dump(vine_manifest, f)

            res2 = self.run_rhizo(["hook", "agy-pre-invocation", "--agent", agent], cwd=tmp_dir)
            self.assertEqual(res2.returncode, 0)
            data = json.loads(res2.stdout.strip())
            self.assertIn("injectSteps", data)
            self.assertEqual(len(data["injectSteps"]), 1)
            msg = data["injectSteps"][0]["ephemeralMessage"]
            self.assertIn("task-xyz-123", msg)
            self.assertIn("/tmp/strand-xyz", msg)

    def test_agy_post_tool_hook(self):
        agent = "test-posttool-agent"
        agent_key = f"{TEST_PREFIX}agent:{agent}"
        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", agent_key], capture_output=True)

        # 1. PostTool with JObject arguments and toolSummary
        stdin_payload = json.dumps({
            "toolCall": {
                "name": "run_command",
                "arguments": {
                    "CommandLine": "nimble build",
                    "toolSummary": "Build project release"
                }
            }
        })
        res = self.run_rhizo(["hook", "agy-post-tool", "--agent", agent], stdin_text=stdin_payload)
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout.strip(), "{}")

        state = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", agent_key, "state"], capture_output=True, text=True).stdout.strip()
        activity = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", agent_key, "activity"], capture_output=True, text=True).stdout.strip()
        last_seen = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", agent_key, "last_seen"], capture_output=True, text=True).stdout.strip()
        self.assertEqual(state, "busy")
        self.assertEqual(activity, "Executing: run_command (Build project release)")
        self.assertTrue(len(last_seen) > 0 and int(last_seen) > 0)

        # 2. PostTool with JSON-stringified arguments
        stdin_str_args = json.dumps({
            "toolCall": {
                "name": "read_file",
                "arguments": json.dumps({"Path": "src/rhizo.nim", "toolSummary": "Inspect source"})
            }
        })
        res2 = self.run_rhizo(["hook", "agy-post-tool", "--agent", agent], stdin_text=stdin_str_args)
        self.assertEqual(res2.returncode, 0)
        activity2 = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", agent_key, "activity"], capture_output=True, text=True).stdout.strip()
        self.assertEqual(activity2, "Executing: read_file (Inspect source)")

        # 3. PostTool extends active task lease and updates progress
        task_id = "task-agy-telemetry-lease-test"
        task_key = f"{TEST_PREFIX}task:{task_id}"
        initial_lease = int(time.time()) + 10
        subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", task_key,
                        "id", task_id,
                        "state", "CLAIMED",
                        "worker", agent,
                        "lease_until", str(initial_lease)], capture_output=True)
        subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", agent_key, "current_task", task_id], capture_output=True)

        res3 = self.run_rhizo(["hook", "agy-post-tool", "--agent", agent], stdin_text=stdin_payload)
        self.assertEqual(res3.returncode, 0)

        new_lease_str = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", task_key, "lease_until"], capture_output=True, text=True).stdout.strip()
        new_lease = int(new_lease_str)
        self.assertGreaterEqual(new_lease, int(time.time()) + 295)

        progress = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", task_key, "progress"], capture_output=True, text=True).stdout.strip()
        self.assertEqual(progress, "Executing: run_command (Build project release)")

        # Clean up
        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", agent_key, task_key], capture_output=True)

    def test_agy_stop_hook(self):
        agent = "test-stop-agent"
        agent_key = f"{TEST_PREFIX}agent:{agent}"
        inbox_key = f"{TEST_PREFIX}inbox:{agent}"
        thrash_key = f"{TEST_PREFIX}hook_blocks:{agent}"

        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_key, thrash_key, agent_key], capture_output=True)

        # 1. Clean inbox -> returns {} and transitions busy to idle
        subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", agent_key, "state", "busy", "last_version_notified:rhizo", "0.2.34"], capture_output=True)
        res = self.run_rhizo(["hook", "agy-stop", "--agent", agent])
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout.strip(), "{}")
        state1 = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", agent_key, "state"], capture_output=True, text=True).stdout.strip()
        self.assertEqual(state1, "idle")

        # 2. Add unread message -> returns {"decision": "continue", "reason": ...}
        # Never returns "block"!
        msg_payload = {
            "id": "msg_test_001",
            "from": "tester",
            "to": agent,
            "type": "task",
            "subject": "Execute task immediately",
            "body": "Do work now",
            "timestamp": "2026-11-09T22:00:00Z",
        }
        subprocess.run(["redis-cli", "-u", REDIS_URL, "LPUSH", inbox_key, json.dumps(msg_payload)], capture_output=True)

        res2 = self.run_rhizo(["hook", "agy-stop", "--agent", agent])
        self.assertEqual(res2.returncode, 0)
        data = json.loads(res2.stdout.strip())
        self.assertEqual(data.get("decision"), "continue")
        self.assertIn("reason", data)
        self.assertIn("unread message", data["reason"].lower())

        # 3. Thrash valve: 3 strikes allows clean stop and transitions busy to idle
        subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", agent_key, "state", "busy"], capture_output=True)
        subprocess.run(["redis-cli", "-u", REDIS_URL, "SET", thrash_key, "3"], capture_output=True)
        res3 = self.run_rhizo(["hook", "agy-stop", "--agent", agent])
        self.assertEqual(res3.returncode, 0)
        self.assertEqual(res3.stdout.strip(), "{}")
        state3 = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", agent_key, "state"], capture_output=True, text=True).stdout.strip()
        self.assertEqual(state3, "idle")

        # Clean up
        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_key, thrash_key, agent_key], capture_output=True)

    def test_probe_telemetry(self):
        agent = "test-probe-telemetry-agent"
        agent_key = f"{TEST_PREFIX}agent:{agent}"
        now_sec = int(time.time())
        subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", agent_key,
                        "state", "busy",
                        "activity", "Executing: run_command (Compiling kernel)",
                        "last_seen", str(now_sec - 5)], capture_output=True)

        # 1. JSON probe
        res = self.run_rhizo(["probe", agent, "--json"])
        self.assertEqual(res.returncode, 0)
        data = json.loads(res.stdout.strip())
        self.assertEqual(data.get("agent_state"), "busy")
        self.assertEqual(data.get("activity"), "Executing: run_command (Compiling kernel)")
        self.assertGreaterEqual(data.get("last_seen_age_sec"), 4)

        # 2. Text probe
        res_text = self.run_rhizo(["probe", agent])
        self.assertEqual(res_text.returncode, 0)
        self.assertIn("BUSY", res_text.stdout)
        self.assertIn("Executing: run_command (Compiling kernel)", res_text.stdout)
        self.assertIn("s ago", res_text.stdout)

        # Clean up
        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", agent_key], capture_output=True)

    def test_duplicate_exit_when_agy_ear_active(self):
        agent = "test-ear-dedupe-agent"
        listener_key = f"{TEST_PREFIX}listener:{agent}"
        listener_data = {
            "pid": os.getpid(),
            "host": "localhost",
            "machine_id": "",
            "mode": "agy-ear",
            "started": int(time.time()),
        }
        subprocess.run(["redis-cli", "-u", REDIS_URL, "SETEX", listener_key, "120", json.dumps(listener_data)], capture_output=True)

        try:
            # Calling rhizo listen without --agy-ear when agy-ear is active should exit 0 with informative message
            res = self.run_rhizo(["listen", agent])
            self.assertEqual(res.returncode, 0, f"Expected clean exit 0, got {res.returncode}: {res.stderr}")
            self.assertIn("Continuous Antigravity Ear is already active", res.stdout)
        finally:
            subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", listener_key], capture_output=True)

    def test_agy_ear_streaming_and_routine_ack_suppression(self):
        agent = "test-ear-stream-agent"
        conv_id = "test-conv-999"

        with tempfile.TemporaryDirectory() as tmp_dir:
            log_file = Path(tmp_dir) / "agentapi_calls.jsonl"
            if sys.platform == "win32":
                mock_agentapi = Path(tmp_dir) / "agentapi.exe"
                c_src = Path(tmp_dir) / "mock_agentapi.c"
                log_path_escaped = log_file.as_posix()
                c_src.write_text(
                    f'#include <stdio.h>\n'
                    f'int main(int argc, char** argv) {{\n'
                    f'    FILE *f = fopen("{log_path_escaped}", "a");\n'
                    f'    if (f) {{\n'
                    f'        for (int i = 1; i < argc; i++) fprintf(f, "%s ", argv[i]);\n'
                    f'        fprintf(f, "\\n");\n'
                    f'        fclose(f);\n'
                    f'    }}\n'
                    f'    return 0;\n'
                    f'}}\n'
                )
                cc = "gcc" if shutil.which("gcc") else "clang"
                subprocess.run([cc, str(c_src), "-o", str(mock_agentapi)], check=True)
            else:
                mock_agentapi = Path(tmp_dir) / "agentapi"
                script_content = f"""#!/bin/sh
echo "$@" >> "{log_file}"
exit 0
"""
                mock_agentapi.write_text(script_content)
                mock_agentapi.chmod(mock_agentapi.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

            # Register agent session in Redis
            agent_key = f"{TEST_PREFIX}agent:{agent}"
            sess_key = f"{TEST_PREFIX}sessions"
            subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", agent_key, "agy_conversation_id", conv_id, "agy_agentapi_exe", str(mock_agentapi), "last_version_notified:rhizo", "0.2.34"], capture_output=True)
            subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", sess_key, f"agy:{conv_id}", agent], capture_output=True)

            inbox_key = f"{TEST_PREFIX}inbox:{agent}"
            subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_key], capture_output=True)

            # 1. Enqueue routine ACK message -> Should be suppressed
            ack_msg = {
                "id": "msg_ack_01",
                "from": "peer-worker",
                "to": agent,
                "type": "reply",
                "subject": "Task Claimed",
                "body": "ACK claimed",
                "timestamp": "2026-11-09T22:00:00Z",
            }
            # Also sign with secret
            import hashlib, hmac
            secret = "test-secret-key-32-chars-long!!"
            canonical = f"{ack_msg['id']}|{ack_msg['from']}|{ack_msg['to']}|{ack_msg['type']}|{ack_msg['subject']}|{ack_msg['body']}|{ack_msg['timestamp']}"
            ack_msg["sig"] = hmac.new(secret.encode(), canonical.encode(), hashlib.sha256).hexdigest()

            subprocess.run(["redis-cli", "-u", REDIS_URL, "LPUSH", inbox_key, json.dumps(ack_msg)], capture_output=True)

            # Run single turn of listen with --agy-ear and timeout 1s
            env_overrides = {
                "ANTIGRAVITY_CONVERSATION_ID": conv_id,
                "ANTIGRAVITY_AGENTAPI_EXE": str(mock_agentapi),
                "RHIZO_SUPPRESS_ACK_WAKE": "1",
            }
            res = self.run_rhizo(["listen", agent, "--agy-ear", "--timeout", "1", "-q"], env_overrides=env_overrides)
            self.assertEqual(res.returncode, 0, f"Listen failed: {res.stderr}")

            # Verify mock_agentapi was NOT called for routine ACK
            content = log_file.read_text() if log_file.exists() else ""
            self.assertFalse(log_file.exists() and log_file.stat().st_size > 0, f"Routine ACK was unexpectedly dispatched to agentapi: {content}")

            # 2. Enqueue substantive task message -> Should be dispatched via agentapi send-message
            task_msg = {
                "id": "msg_task_01",
                "from": "peer-lead",
                "to": agent,
                "type": "task",
                "task_id": "task-core-feat",
                "subject": "Important Directive: Ship Feature",
                "body": "Execute the following steps: ...",
                "timestamp": "2026-11-09T22:00:00Z",
            }
            task_canon = f"{task_msg['id']}|{task_msg['from']}|{task_msg['to']}|{task_msg['type']}|{task_msg['subject']}|{task_msg['body']}|{task_msg['timestamp']}"
            task_msg["sig"] = hmac.new(secret.encode(), task_canon.encode(), hashlib.sha256).hexdigest()

            subprocess.run(["redis-cli", "-u", REDIS_URL, "LPUSH", inbox_key, json.dumps(task_msg)], capture_output=True)

            res2 = self.run_rhizo(["listen", agent, "--agy-ear", "--timeout", "1", "-q"], env_overrides=env_overrides)
            self.assertEqual(res2.returncode, 0, f"Listen task failed: {res2.stderr}")

            # Verify mock_agentapi was called
            self.assertTrue(log_file.exists(), "agentapi was not invoked")
            logged_args = log_file.read_text().strip()
            self.assertIn("send-message", logged_args)
            self.assertIn(conv_id, logged_args)
            self.assertIn("Important Directive", logged_args)

            # Verify router delivery telemetry updated agent and task
            deliv_state = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", agent_key, "state"], capture_output=True, text=True).stdout.strip()
            deliv_activity = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", agent_key, "activity"], capture_output=True, text=True).stdout.strip()
            self.assertEqual(deliv_state, "busy")
            self.assertIn("Delivered: Important Directive", deliv_activity)

            task_key = f"{TEST_PREFIX}task:task-core-feat"
            deliv_at = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", task_key, "delivered_at"], capture_output=True, text=True).stdout.strip()
            self.assertTrue(len(deliv_at) > 0 and int(deliv_at) > 0)

            # Clean up
            subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_key, agent_key, task_key], capture_output=True)

    def test_vine_gate_interlock_woven_status(self):
        worker = "test-woven-worker"
        task_id = "task-woven-gate-test"

        # Create and claim task
        self.run_rhizo(["task", "create", task_id, "--title", "Test Woven Gate", "--target", worker])
        self.run_rhizo(["task", "claim", task_id, "--worker", worker, "--no-vine"])

        # Create strand manifest in redis with status "WOVEN"
        strand_key = f"{TEST_PREFIX}vine:strand:{task_id}"
        subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", strand_key, "task_id", task_id, "status", "WOVEN", "lifecycle_state", "WOVEN"], capture_output=True)

        # Complete task without --skip-gate (triggers checkVineGateInterlock)
        res = self.run_rhizo(["task", "complete", task_id])
        self.assertEqual(res.returncode, 0, f"Task complete failed on WOVEN strand: {res.stderr}")
        self.assertIn("COMPLETED", res.stdout)

    def test_audit_ticket_minted_on_strand_submitted(self):
        auditor = "test-auditor-agent"
        task_id = "task-audit-ticket-test"
        secret = "test-secret-key-32-chars-long!!"

        import hashlib, hmac

        msg = {
            "id": "msg_strand_sub_01",
            "from": "worker-lead",
            "to": auditor,
            "type": "event",
            "task_id": task_id,
            "subject": f"STRAND_SUBMITTED: {task_id}",
            "body": json.dumps({"event": "STRAND_SUBMITTED", "task_id": task_id, "strand": f"/path/{task_id}"}),
            "timestamp": "2026-11-09T22:00:00Z",
        }
        canonical = f"{msg['id']}|{msg['from']}|{msg['to']}|{msg['type']}|{msg['subject']}|{msg['body']}|{msg['timestamp']}"
        msg["sig"] = hmac.new(secret.encode(), canonical.encode(), hashlib.sha256).hexdigest()

        inbox_key = f"{TEST_PREFIX}inbox:{auditor}"
        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_key], capture_output=True)
        subprocess.run(["redis-cli", "-u", REDIS_URL, "LPUSH", inbox_key, json.dumps(msg)], capture_output=True)

        res = self.run_rhizo(["drain", "1", auditor, "--format", "json"])
        self.assertEqual(res.returncode, 0, f"Drain failed: {res.stderr}")

        drain_data = json.loads(res.stdout)
        item = drain_data[0] if isinstance(drain_data, list) else drain_data
        self.assertIn("audit_ticket", item)
        self.assertIn("audit_ticket_hash", item)
        ticket = item["audit_ticket"]
        thash = item["audit_ticket_hash"]
        self.assertEqual(len(ticket), 16)
        self.assertEqual(len(thash), 64)
        self.assertEqual(hashlib.sha256(ticket.encode("utf-8")).hexdigest(), thash)

        # Check redis storage on vine:strand:<task_id> and prefix:strand:<task_id>
        stored_hash = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", f"vine:strand:{task_id}", "audit_ticket_hash"], capture_output=True, text=True).stdout.strip()
        self.assertEqual(stored_hash, thash)
        stored_auditor_hash = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", f"vine:strand:{task_id}", f"audit_ticket_hash:{auditor}"], capture_output=True, text=True).stdout.strip()
        self.assertEqual(stored_auditor_hash, thash)

    def test_broadcast_strand_submitted_per_recipient_ticket_isolation(self):
        auditor = "remocha-auditor"
        implementer = "remocha-implementer"
        task_id = "task-per-auditor-hash-test"
        secret = "test-secret-key-32-chars-long!!"

        import hashlib, hmac

        # 1. First, auditor receives STRAND_SUBMITTED
        msg1 = {
            "id": "msg_sub_auditor_01",
            "from": "worker-lead",
            "to": auditor,
            "type": "event",
            "task_id": task_id,
            "subject": f"STRAND_SUBMITTED: {task_id}",
            "body": json.dumps({"event": "STRAND_SUBMITTED", "task_id": task_id, "strand": f"/path/{task_id}"}),
            "timestamp": "2026-11-12T12:00:00Z",
        }
        can1 = f"{msg1['id']}|{msg1['from']}|{msg1['to']}|{msg1['type']}|{msg1['subject']}|{msg1['body']}|{msg1['timestamp']}"
        msg1["sig"] = hmac.new(secret.encode(), can1.encode(), hashlib.sha256).hexdigest()

        inbox_auditor = f"{TEST_PREFIX}inbox:{auditor}"
        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_auditor], capture_output=True)
        subprocess.run(["redis-cli", "-u", REDIS_URL, "LPUSH", inbox_auditor, json.dumps(msg1)], capture_output=True)

        res1 = self.run_rhizo(["drain", "1", auditor, "--format", "json"])
        self.assertEqual(res1.returncode, 0, f"Drain auditor failed: {res1.stderr}")
        data1 = json.loads(res1.stdout)
        item1 = data1[0] if isinstance(data1, list) else data1
        ticket1 = item1["audit_ticket"]
        hash1 = item1["audit_ticket_hash"]
        self.assertEqual(len(ticket1), 16)
        self.assertEqual(hashlib.sha256(ticket1.encode("utf-8")).hexdigest(), hash1)

        # 2. 10ms later, non-auditor implementer receives broadcast copy of STRAND_SUBMITTED
        msg2 = {
            "id": "msg_sub_impl_02",
            "from": "worker-lead",
            "to": implementer,
            "type": "event",
            "task_id": task_id,
            "subject": f"STRAND_SUBMITTED: {task_id}",
            "body": json.dumps({"event": "STRAND_SUBMITTED", "task_id": task_id, "strand": f"/path/{task_id}"}),
            "timestamp": "2026-11-12T12:00:01Z",
        }
        can2 = f"{msg2['id']}|{msg2['from']}|{msg2['to']}|{msg2['type']}|{msg2['subject']}|{msg2['body']}|{msg2['timestamp']}"
        msg2["sig"] = hmac.new(secret.encode(), can2.encode(), hashlib.sha256).hexdigest()

        inbox_impl = f"{TEST_PREFIX}inbox:{implementer}"
        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_impl], capture_output=True)
        subprocess.run(["redis-cli", "-u", REDIS_URL, "LPUSH", inbox_impl, json.dumps(msg2)], capture_output=True)

        res2 = self.run_rhizo(["drain", "1", implementer, "--format", "json"])
        self.assertEqual(res2.returncode, 0, f"Drain implementer failed: {res2.stderr}")
        data2 = json.loads(res2.stdout)
        item2 = data2[0] if isinstance(data2, list) else data2
        ticket2 = item2["audit_ticket"]
        hash2 = item2["audit_ticket_hash"]
        self.assertEqual(len(ticket2), 16)
        self.assertNotEqual(ticket1, ticket2, "Distinct tickets must be minted for separate recipients")

        # 3. CRITICAL INVARIANT: The auditor's hash and the scalar hash must NOT be clobbered by implementer!
        s_key = f"vine:strand:{task_id}"
        auditor_stored = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", s_key, f"audit_ticket_hash:{auditor}"], capture_output=True, text=True).stdout.strip()
        impl_stored = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", s_key, f"audit_ticket_hash:{implementer}"], capture_output=True, text=True).stdout.strip()
        scalar_stored = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", s_key, "audit_ticket_hash"], capture_output=True, text=True).stdout.strip()

        self.assertEqual(auditor_stored, hash1, "Auditor-specific ticket hash must be preserved")
        self.assertEqual(impl_stored, hash2, "Implementer-specific ticket hash must be stored")
        self.assertEqual(scalar_stored, hash1, "Scalar audit_ticket_hash must NOT be overwritten by non-auditor recipient!")

    def test_router_retry_limit_dlq_and_hol_prevention(self):
        dead_agent = "test-dead-worker"
        alive_agent = "test-alive-worker"
        dead_conv = "conv-dead-999"
        alive_conv = "conv-alive-888"

        with tempfile.TemporaryDirectory() as tmp_dir:
            log_file = Path(tmp_dir) / "agentapi.log"
            mock_agentapi = Path(tmp_dir) / "agentapi"

            # Script fails on dead_conv, succeeds on alive_conv
            script = f"""#!/bin/sh
echo "CONV=$ANTIGRAVITY_CONVERSATION_ID|ARGS=$@" >> "{log_file}"
if [ "$ANTIGRAVITY_CONVERSATION_ID" = "{dead_conv}" ]; then
  exit 1
fi
exit 0
"""
            mock_agentapi.write_text(script)
            mock_agentapi.chmod(mock_agentapi.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

            # Register dead_agent and alive_agent
            dead_key = f"{TEST_PREFIX}agent:{dead_agent}"
            alive_key = f"{TEST_PREFIX}agent:{alive_agent}"
            sess_key = f"{TEST_PREFIX}sessions"

            import socket
            my_host = socket.gethostname()

            subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", dead_key,
                            "agy_conversation_id", dead_conv,
                            "agy_agentapi_exe", str(mock_agentapi),
                            "agy_ls_address", "127.0.0.1:49999",
                            "agy_csrf_token", "test_csrf_token",
                            "host", my_host,
                            "last_version_notified:rhizo", "0.2.34"], check=True)
            subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", alive_key,
                            "agy_conversation_id", alive_conv,
                            "agy_agentapi_exe", str(mock_agentapi),
                            "agy_ls_address", "127.0.0.1:49999",
                            "agy_csrf_token", "test_csrf_token",
                            "host", my_host,
                            "last_version_notified:rhizo", "0.2.34"], check=True)
            subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", sess_key, f"agy:{dead_conv}", dead_agent, f"agy:{alive_conv}", alive_agent], check=True)
            subprocess.run(["redis-cli", "-u", REDIS_URL, "SADD", f"{TEST_PREFIX}active_agents", dead_agent, alive_agent], check=True)

            inbox_dead = f"{TEST_PREFIX}inbox:{dead_agent}"
            inbox_alive = f"{TEST_PREFIX}inbox:{alive_agent}"
            dlq_dead = f"{TEST_PREFIX}dlq:{dead_agent}"
            subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", inbox_dead, inbox_alive, dlq_dead], check=True)

            # Stop existing router
            self.run_rhizo(["router", "stop"])

            # Start router
            router_env = self.env.copy()
            router_env["ANTIGRAVITY_AGENTAPI_EXE"] = str(mock_agentapi)
            router_env["ANTIGRAVITY_LS_ADDRESS"] = "127.0.0.1:49999"
            router_env["ANTIGRAVITY_CSRF_TOKEN"] = "test_csrf_token"
            router_env["RHIZO_EAR_DISABLED"] = "0"
            router_env["RHIZO_QUIET"] = "1"

            proc = subprocess.Popen(
                [str(BIN_RHIZO), f"--redis-url={REDIS_URL}", f"--prefix={TEST_PREFIX}", "router", "start"],
                env=router_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )

            try:
                time.sleep(1.5)

                # Send message to dead_agent and to alive_agent
                self.run_rhizo(["send", "--to", dead_agent, "--from", "orchestrator", "--subject", "MsgDead", "--body", "FailMe"])
                self.run_rhizo(["send", "--to", alive_agent, "--from", "orchestrator", "--subject", "MsgAlive", "--body", "PassMe"])

                # Wait for router to process both (retries + dlq)
                deadline = time.time() + 8.0
                while time.time() < deadline:
                    dlq_len = int(subprocess.run(["redis-cli", "-u", REDIS_URL, "LLEN", dlq_dead], capture_output=True, text=True).stdout.strip() or "0")
                    if dlq_len >= 1:
                        break
                    time.sleep(0.3)

                # 1. Alive agent must have received its message (no HOL blocking!)
                all_logs = log_file.read_text() if log_file.exists() else ""
                self.assertIn(f"CONV={alive_conv}", all_logs, f"Alive worker was starved by dead worker! Logs: {all_logs}")

                # 2. Dead agent message must be moved to DLQ after exceeding retries
                dlq_len = int(subprocess.run(["redis-cli", "-u", REDIS_URL, "LLEN", dlq_dead], capture_output=True, text=True).stdout.strip() or "0")
                self.assertEqual(dlq_len, 1, "Dead worker message must be moved to DLQ")

                # 3. Dead agent inbox must now be empty
                dead_inbox_len = int(subprocess.run(["redis-cli", "-u", REDIS_URL, "LLEN", inbox_dead], capture_output=True, text=True).stdout.strip() or "0")
                self.assertEqual(dead_inbox_len, 0, "Dead worker inbox must be empty after DLQ relocation")

                # 4. Dead agent's agy_conversation_id must be cleared in Redis
                saved_conv = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", dead_key, "agy_conversation_id"], capture_output=True, text=True).stdout.strip()
                self.assertEqual(saved_conv, "", "Dead worker agy_conversation_id must be cleared")

            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                self.run_rhizo(["router", "stop"])
                self.run_rhizo(["close", dead_agent])
                self.run_rhizo(["close", alive_agent])
                subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", dead_key, alive_key, dlq_dead, inbox_dead, inbox_alive], capture_output=True)



if __name__ == "__main__":
    unittest.main()
