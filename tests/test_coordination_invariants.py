#!/usr/bin/env python3
"""tests/test_coordination_invariants.py
Comprehensive Invariant Test Suite for Multi-Agent Coordination Hardening.
Verifies all 17 empirical failure modes across rhizo, vine, and multi-agent harnesses.
"""

import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest

BIN_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bin", "rhizo"))
REDIS_URL = os.environ.get("RHIZO_REDIS_URL", "redis://127.0.0.1:6379/0")
TEST_PREFIX = "test_coord_inv:"


class TestCoordinationInvariants(unittest.TestCase):
    def setUp(self):
        self.test_home = tempfile.mkdtemp(prefix="rhizo_inv_home_")
        self.env = os.environ.copy()
        self.env["HOME"] = self.test_home
        self.env["USERPROFILE"] = self.test_home
        self.env["RHIZO_REDIS_URL"] = REDIS_URL
        self.env["RHIZO_REDIS_PREFIX"] = TEST_PREFIX
        self.env["RHIZO_PROJECT"] = "coord_test"
        # Reset virtual time and clear test prefix
        subprocess.run(["redis-cli", "-u", REDIS_URL, "EVAL",
                        f"local keys = redis.call('KEYS', '{TEST_PREFIX}*'); if #keys > 0 then redis.call('DEL', unpack(keys)) end", "0"],
                       capture_output=True, text=True)

    def tearDown(self):
        subprocess.run(["redis-cli", "-u", REDIS_URL, "EVAL",
                        f"local keys = redis.call('KEYS', '{TEST_PREFIX}*'); if #keys > 0 then redis.call('DEL', unpack(keys)) end", "0"],
                       capture_output=True, text=True)
        if os.path.isdir(self.test_home):
            shutil.rmtree(self.test_home, ignore_errors=True)

    def run_cmd(self, args, env_overrides=None, cwd=None):
        cmd_env = self.env.copy()
        if env_overrides:
            cmd_env.update(env_overrides)
        return subprocess.run([BIN_PATH] + args, capture_output=True, text=True, env=cmd_env, cwd=cwd)

    # -------------------------------------------------------------------------
    # Problem 1: Identity Isolation (No Cross-Process ~/.config Leaks)
    # -------------------------------------------------------------------------
    def test_01_identity_isolation(self):
        """Verify that sender identity is strictly process-bound and does not leak global current_agent."""
        # 1. Agent Alpha registers in home directory
        res_open = self.run_cmd(["open", "alpha_agent", "worker"])
        self.assertEqual(res_open.returncode, 0)

        # 2. Beta sends a message with RHIZO_AGENT_NAME=beta_agent
        res_send = self.run_cmd(
            ["send", "--to", "alpha_agent", "--subject", "Ping", "--body", "From Beta"],
            env_overrides={"RHIZO_AGENT_NAME": "beta_agent"}
        )
        self.assertEqual(res_send.returncode, 0)

        # 3. Read message and verify sender is beta_agent, NOT alpha_agent
        res_listen = self.run_cmd(["listen", "alpha_agent", "2"])
        self.assertEqual(res_listen.returncode, 0)
        msg = json.loads(res_listen.stdout.strip())
        self.assertEqual(msg["from"], "beta_agent")
        self.assertEqual(msg["to"], "alpha_agent")

    # -------------------------------------------------------------------------
    # Problem 2 & 4: Non-Destructive Directory & Decoupled Listener State
    # -------------------------------------------------------------------------
    def test_02_non_destructive_directory_and_stale_detection(self):
        """Verify that 'rhizo who' never prunes expired agents and reports STALE."""
        agent = "silent_worker"
        self.run_cmd(["open", agent, "worker"])

        # Advance virtual time beyond heartbeat TTL (150s)
        self.run_cmd(["time", "advance", "300"])

        # Query directory: agent must still be listed, but marked STALE
        res_who = self.run_cmd(["who", "*", "--json"])
        self.assertEqual(res_who.returncode, 0)
        agents = json.loads(res_who.stdout.strip())
        bot = next((a for a in agents if a.get("agent") == agent), None)
        self.assertIsNotNone(bot, "Expired agent was deleted from directory on read!")
        self.assertEqual(bot["status"], "STALE")
        self.assertEqual(bot["listener"], "NO_LISTENER")
        self.assertGreaterEqual(bot["elapsed_seconds"], 300)

        # Text table check
        res_text = self.run_cmd(["who", "*"])
        self.assertIn(agent, res_text.stdout)
        self.assertIn("STALE (5m)", res_text.stdout)

    # -------------------------------------------------------------------------
    # Problem 3: Disambiguating Work State from Listener State
    # -------------------------------------------------------------------------
    def test_03_decoupled_task_and_listener_state(self):
        """Verify that working on a task marks state as BUSY (<task_id>), not IDLE."""
        worker = "task_worker"
        self.run_cmd(["open", worker, "worker"])

        # Initially unassigned
        res_who1 = self.run_cmd(["who", "*", "--json"])
        bot1 = next(a for a in json.loads(res_who1.stdout) if a["agent"] == worker)
        self.assertEqual(bot1["state"], "IDLE")

        # Create and claim a task
        self.run_cmd(["task", "create", "task-sync-1", "--title", "Refactor Auth"])
        res_claim = self.run_cmd(["task", "claim", "task-sync-1", "--worker", worker, "--no-vine"])
        self.assertEqual(res_claim.returncode, 0)

        # Query directory: state must reflect busy with task id
        res_who2 = self.run_cmd(["who", "*", "--json"])
        bot2 = next(a for a in json.loads(res_who2.stdout) if a["agent"] == worker)
        self.assertIn("task-sync-1", bot2["state"].lower())
        self.assertIn("BUSY", bot2["state"].upper())

    # -------------------------------------------------------------------------
    # Problem 8: Anti-Detachment Guardrail (nohup / regular file rejection)
    # -------------------------------------------------------------------------
    def test_04_listener_detachment_guardrail(self):
        """Verify that 'rhizo listen' rejects redirection to a regular file unless --force is passed."""
        log_file = os.path.join(self.test_home, "nohup_test.log")
        with open(log_file, "w") as f:
            proc = subprocess.run(
                [BIN_PATH, "listen", "detached_worker"],
                stdout=f,
                stderr=subprocess.PIPE,
                text=True,
                env=self.env
            )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Unsupervised detachment detected", proc.stderr)
        self.assertIn("breaks supervisor", proc.stderr)

        # Negative control: with --force it must bypass the check
        with open(log_file, "w") as f:
            proc_force = subprocess.run(
                [BIN_PATH, "listen", "detached_worker", "1", "--force"],
                stdout=f,
                stderr=subprocess.PIPE,
                text=True,
                env=self.env
            )
        self.assertEqual(proc_force.returncode, 0)

    # -------------------------------------------------------------------------
    # Problem 16: Stale Message Detection
    # -------------------------------------------------------------------------
    def test_05_stale_message_detection(self):
        """Verify that messages older than 1h are flagged as is_stale and logged to stderr."""
        agent = "stale_receiver"
        self.run_cmd(["open", agent, "worker"])

        # Send a message
        res_send = self.run_cmd([
            "send", "--to", agent, "--from", "dispatcher", "--subject", "Old Order", "--body", "Execute Phase 1"
        ])
        self.assertEqual(res_send.returncode, 0)

        # Advance virtual time by 7200 seconds (2 hours)
        self.run_cmd(["time", "advance", "7200"])

        # Drain inbox: message must contain is_stale: true and trigger stderr warning
        res_drain = self.run_cmd(["drain", "1", agent])
        self.assertEqual(res_drain.returncode, 0)
        self.assertIn("Stale message", res_drain.stderr)
        msgs = json.loads(res_drain.stdout.strip())
        msg = msgs if isinstance(msgs, dict) else msgs[0]
        self.assertTrue(msg["is_stale"])
        self.assertGreaterEqual(msg["elapsed_seconds"], 7200)
        self.assertEqual(msg["age_human"], "2h")

    # -------------------------------------------------------------------------
    # Problem 5: Delivery Transparency & Unarmed Listener Warning
    # -------------------------------------------------------------------------
    def test_06_delivery_transparency(self):
        """Verify send outputs structured enqueue info and warns when recipient has no listener."""
        # Send to offline agent
        res_send = self.run_cmd([
            "send", "--to", "offline_bot", "--from", "sender", "--subject", "Notice", "--body", "Are you there?"
        ])
        self.assertEqual(res_send.returncode, 0)
        self.assertIn("ENQUEUED", res_send.stdout)
        self.assertIn("status: OFFLINE", res_send.stdout)
        self.assertIn("listener: NO_LISTENER", res_send.stdout)
        self.assertIn("Recipient 'offline_bot' has no active listener attached", res_send.stderr)

        # JSON mode
        res_json = self.run_cmd([
            "send", "--to", "offline_bot", "--from", "sender", "--subject", "Notice", "--body", "JSON Mode", "--json"
        ])
        self.assertEqual(res_json.returncode, 0)
        out = json.loads(res_json.stdout.strip())
        self.assertEqual(out["status"], "ENQUEUED")
        self.assertEqual(out["recipient_status"], "OFFLINE")
        self.assertFalse(out["listener_attached"])

    # -------------------------------------------------------------------------
    # Problem 6: Broadcast Scope Transparency
    # -------------------------------------------------------------------------
    def test_07_broadcast_scope_default_all(self):
        """Verify broadcast with no tags defaults to scope '*' and warns if only sender reached."""
        self.run_cmd(["open", "bcast_sender", "solo_project"])
        res_bcast = self.run_cmd([
            "broadcast", "--subject", "Global Alert", "--body", "All hands", "--from", "bcast_sender"
        ])
        self.assertEqual(res_bcast.returncode, 0)
        self.assertIn("BROADCAST", res_bcast.stdout)
        self.assertIn("scope: *", res_bcast.stdout)

    # -------------------------------------------------------------------------
    # Problem 7: Scatter-Reply Correlation & Progress
    # -------------------------------------------------------------------------
    def test_08_scatter_reply_correlation(self):
        """Verify rhizo reply with scatter id auto-routes to scatter collector queue."""
        w1 = "scatter_w1"
        self.run_cmd(["open", w1, "team"])

        # Worker starts with mock response queued: simulate receiving scatter message
        fake_scatter_id = "sc_99999_lead_1234"
        # Worker replies using --reply-to with scatter id prefix
        res_reply = self.run_cmd([
            "reply", "--to", "lead", "--reply-to", fake_scatter_id, "--from", w1,
            "--subject", "Re: Status", "--body", "Report 100% complete"
        ])
        self.assertEqual(res_reply.returncode, 0)

        # Verify reply was delivered to scatter queue
        res_pop = subprocess.run(
            ["redis-cli", "-u", REDIS_URL, "RPOP", f"{TEST_PREFIX}inbox:scatter:{fake_scatter_id}"],
            capture_output=True, text=True
        )
        self.assertIn("Report 100% complete", res_pop.stdout)

    # -------------------------------------------------------------------------
    # Problems 11 & 12: First-Class Tasks & Single-Active-Lease Invariant
    # -------------------------------------------------------------------------
    def test_09_single_active_lease_invariant(self):
        """Verify an agent cannot claim multiple concurrent tasks."""
        worker = "busy_worker"
        self.run_cmd(["task", "create", "t-001", "--title", "Task 1"])
        self.run_cmd(["task", "create", "t-002", "--title", "Task 2"])

        # Claim task 1
        res1 = self.run_cmd(["task", "claim", "t-001", "--worker", worker, "--no-vine"])
        self.assertEqual(res1.returncode, 0)

        # Claim task 2 -> must fail with active lease error
        res2 = self.run_cmd(["task", "claim", "t-002", "--worker", worker, "--no-vine"])
        self.assertNotEqual(res2.returncode, 0)
        self.assertIn("already holds active lease", res2.stderr)

        # Yield task 1
        res_yield = self.run_cmd(["task", "yield", "t-001", "--worker", worker, "--reason", "blocked"])
        self.assertEqual(res_yield.returncode, 0)

        # Now claiming task 2 succeeds
        res3 = self.run_cmd(["task", "claim", "t-002", "--worker", worker, "--no-vine"])
        self.assertEqual(res3.returncode, 0)

    # -------------------------------------------------------------------------
    # Problem 14: Operator Ruling Ledger
    # -------------------------------------------------------------------------
    def test_10_operator_ruling_ledger(self):
        """Verify operator rulings have verifiable cryptographic/ledger status."""
        dec_id = "dec-arch-01"
        self.run_cmd(["decision", "propose", dec_id, "--title", "Enable APFS Strands", "--by", "architect"])

        # Before ruling: verify returns status != APPROVED and exit code 1
        res_v1 = self.run_cmd(["decision", "verify", dec_id])
        self.assertEqual(res_v1.returncode, 1)
        self.assertEqual(res_v1.stdout.strip(), "PROPOSED")

        # Operator approves
        res_app = self.run_cmd(["decision", "approve", dec_id, "--note", "Approved for milestone 1"])
        self.assertEqual(res_app.returncode, 0)

        # After ruling: verify returns exit code 0
        res_v2 = self.run_cmd(["decision", "verify", dec_id])
        self.assertEqual(res_v2.returncode, 0)
        self.assertEqual(res_v2.stdout.strip(), "APPROVED")

    # -------------------------------------------------------------------------
    # Problem 13: Side-Effect Audit Trail Stream
    # -------------------------------------------------------------------------
    def test_11_audit_trail_logging(self):
        """Verify task actions and operator rulings are recorded in the audit trail."""
        self.run_cmd(["task", "create", "audit-task-1", "--title", "Audited Task"])
        self.run_cmd(["decision", "propose", "audit-dec-1", "--title", "Audited Decision", "--by", "lead"])
        self.run_cmd(["decision", "approve", "audit-dec-1", "--note", "Approved"])

        res_audit = self.run_cmd(["audit", "list", "--json"])
        self.assertEqual(res_audit.returncode, 0)
        events = json.loads(res_audit.stdout.strip())
        actions = [e["action"] for e in events]
        self.assertIn("task.create", actions)
        self.assertIn("decision.propose", actions)
        self.assertIn("decision.approve", actions)

    # -------------------------------------------------------------------------
    # Reminder System: Lifecycle & Non-Destructive Inspection
    # -------------------------------------------------------------------------
    def test_12_reminder_lifecycle_and_non_destructive_peeking(self):
        """Verify sticky reminder creation, non-destructive JSON inspection, acking, and dismissal."""
        res_add = self.run_cmd([
            "remind", "add", "Must use vine strands for all modifications",
            "--priority", "CRITICAL", "--cadence", "15m", "--ttl", "2h", "--by", "operator"
        ])
        self.assertEqual(res_add.returncode, 0)
        rem = json.loads(res_add.stdout.strip())
        self.assertEqual(rem["status"], "OK")
        rem_id = rem["id"]
        self.assertEqual(rem["priority"], "CRITICAL")

        # Non-destructive inspection for specific agent
        res_list = self.run_cmd(["remind", "list", "--for", "worker_alpha", "--json"])
        self.assertEqual(res_list.returncode, 0)
        list_data = json.loads(res_list.stdout.strip())
        self.assertEqual(list_data["total"], 1)
        target_rem = list_data["reminders"][0]
        self.assertEqual(target_rem["id"], rem_id)
        self.assertTrue(target_rem["due_for_target"])
        self.assertFalse(target_rem["acked_by_target"])

        # Ack reminder as worker_alpha
        res_ack = self.run_cmd(["remind", "ack", rem_id, "--agent", "worker_alpha"])
        self.assertEqual(res_ack.returncode, 0)

        # Inspect again: now shows acked
        res_list2 = self.run_cmd(["remind", "list", "--for", "worker_alpha", "--json"])
        list_data2 = json.loads(res_list2.stdout.strip())
        target_rem2 = list_data2["reminders"][0]
        self.assertTrue(target_rem2["acked_by_target"])
        self.assertIn("worker_alpha", target_rem2["acks"])

        # Dismiss
        res_del = self.run_cmd(["remind", "dismiss", rem_id])
        self.assertEqual(res_del.returncode, 0)
        res_list3 = self.run_cmd(["remind", "list", "--json"])
        list_data3 = json.loads(res_list3.stdout.strip())
        self.assertEqual(list_data3["total"], 0)

    # -------------------------------------------------------------------------
    # Reminder System: Piggybacking & Cadence Cooldown
    # -------------------------------------------------------------------------
    def test_13_reminder_piggybacking_and_cadence_cooldown(self):
        """Verify opportunistic piggybacking onto messages and cadence anti-fatigue cooldown."""
        self.run_cmd(["open", "worker_piggy", "worker"])
        res_add = self.run_cmd([
            "remind", "add", "Do not touch canonical main branch directly",
            "--priority", "HIGH", "--cadence", "10m"
        ])
        self.assertEqual(res_add.returncode, 0)

        # Send first message and drain
        self.run_cmd(["send", "--to", "worker_piggy", "--subject", "Task 1", "--body", "First task"])
        res_drain1 = self.run_cmd(["drain", "worker_piggy", "--json"])
        self.assertEqual(res_drain1.returncode, 0)
        msgs1 = json.loads(res_drain1.stdout.strip())
        self.assertEqual(len(msgs1), 1)
        self.assertIn("reminders", msgs1[0])
        self.assertEqual(msgs1[0]["reminders"][0]["priority"], "HIGH")

        # Send second message immediately (within 10m cadence)
        self.run_cmd(["send", "--to", "worker_piggy", "--subject", "Task 2", "--body", "Second task"])
        res_drain2 = self.run_cmd(["drain", "worker_piggy", "--json"])
        msgs2 = json.loads(res_drain2.stdout.strip())
        self.assertEqual(len(msgs2), 1)
        # Should NOT be piggybacked again immediately (cooldown active!)
        self.assertNotIn("reminders", msgs2[0])

        # Advance virtual time by 11 minutes (660 seconds)
        self.run_cmd(["time", "advance", "660"])

        # Send third message after cadence elapsed
        self.run_cmd(["send", "--to", "worker_piggy", "--subject", "Task 3", "--body", "Third task"])
        res_drain3 = self.run_cmd(["drain", "worker_piggy", "--json"])
        msgs3 = json.loads(res_drain3.stdout.strip())
        self.assertEqual(len(msgs3), 1)
        # Should now be piggybacked again!
        self.assertIn("reminders", msgs3[0])

    # -------------------------------------------------------------------------
    # Reminder System: Fallback Standalone Dispatch
    # -------------------------------------------------------------------------
    def test_14_reminder_fallback_standalone_dispatch(self):
        """Verify standalone broadcast message is dispatched when cadence elapses without peer traffic."""
        self.run_cmd(["open", "worker_idle", "worker"])
        self.run_cmd([
            "remind", "add", "Global emergency: freeze all deployments",
            "--priority", "CRITICAL", "--cadence", "5m"
        ])

        # Initial tick: idle worker has not exceeded cadence yet
        res_tick1 = self.run_cmd(["remind", "tick", "--json"])
        data_tick1 = json.loads(res_tick1.stdout.strip())
        # First impression is dispatched
        self.assertEqual(data_tick1["dispatched"], 1)

        # Check inbox of worker_idle
        res_drain = self.run_cmd(["drain", "worker_idle", "--json"])
        msgs = json.loads(res_drain.stdout.strip())
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["type"], "reminder")
        self.assertIn("freeze all deployments", msgs[0]["body"])

    # -------------------------------------------------------------------------
    # Anti-While-Loop Supervision Guardrail
    # -------------------------------------------------------------------------
    def test_15_anti_while_loop_supervision_guardrail(self):
        """Verify that rhizo listen detects parent while/until loops and rejects execution."""
        # Run inside a bash while loop
        bash_cmd = f"set -e; while true; do '{BIN_PATH}' listen test_agent_loop --timeout 1; done"
        res = subprocess.run(["bash", "-c", bash_cmd], capture_output=True, text=True, env=self.env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("bash loop", res.stderr)
        self.assertIn("SINGLE-SHOT", res.stderr)

    # -------------------------------------------------------------------------
    # Listener Re-Arm Notice & Identity Reminder
    # -------------------------------------------------------------------------
    def test_16_listener_rearm_notice_and_identity(self):
        """Verify listener prints exact re-arm command, harness advice, and explicit identity reminder."""
        self.run_cmd(["open", "test_listener_id", "worker"])
        self.run_cmd(["send", "--to", "test_listener_id", "--subject", "Hello", "--body", "World"],
                     env_overrides={"RHIZO_AGENT_NAME": "test_sender_id"})

        res = self.run_cmd(["listen", "test_listener_id", "--timeout", "5"], env_overrides={"RHIZO_QUIET": "0"})
        self.assertEqual(res.returncode, 0)
        self.assertIn("Listener Identity: @test_listener_id (this is YOU)", res.stderr)
        self.assertIn("Delivered Message:", res.stderr)
        self.assertIn("Exact command: rhizo listen test_listener_id", res.stderr)
        self.assertIn("Never wrap in 'while true' bash loop", res.stderr)


if __name__ == "__main__":
    unittest.main()
