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

if os.name == "nt":
    BIN_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bin", "rhizo.exe"))
else:
    BIN_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bin", "rhizo"))
REDIS_URL = os.environ.get("RHIZO_REDIS_URL", "redis://127.0.0.1:6379/0")
TEST_PREFIX = os.environ.get("RHIZO_REDIS_PREFIX", f"test_coord_inv_{os.getpid()}:")


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
        actual_cwd = cwd if cwd is not None else self.test_home
        return subprocess.run([BIN_PATH] + args, capture_output=True, text=True, env=cmd_env, cwd=actual_cwd)

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
        if os.name == "nt":
            self.skipTest("POSIX fstat stdout redirection check is not applicable on Windows")
        log_file = os.path.join(self.test_home, "nohup_test.log")
        with open(log_file, "w") as f:
            proc = subprocess.run(
                [BIN_PATH, "listen", "detached_worker", "2"],
                stdout=f,
                stderr=subprocess.PIPE,
                text=True,
                env=self.env,
                cwd=self.test_home,
                timeout=10
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
                env=self.env,
                cwd=self.test_home
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
        """Verify broadcast with no tags defaults to project scope and supports --all-projects for global scope."""
        self.run_cmd(["open", "bcast_sender", "solo_project"])
        res_bcast = self.run_cmd([
            "broadcast", "--subject", "Global Alert", "--body", "All hands", "--from", "bcast_sender"
        ])
        self.assertEqual(res_bcast.returncode, 0)
        self.assertIn("BROADCAST", res_bcast.stdout)
        self.assertIn("scope: @coord_test", res_bcast.stdout)

        # Cross-project broadcast with --all-projects
        res_bcast_all = self.run_cmd([
            "broadcast", "--all-projects", "--subject", "Global Alert", "--body", "All hands", "--from", "bcast_sender"
        ])
        self.assertEqual(res_bcast_all.returncode, 0)
        self.assertIn("scope: *", res_bcast_all.stdout)

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
        self.run_cmd(["decision", "propose", dec_id, "--title", "Enable Rift Strands", "--by", "architect"])

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
        self.run_cmd(["send", "--to", "worker_piggy", "--subject", "Task 1", "--body", "First task"],
                     env_overrides={"RHIZO_AGENT_NAME": "sender_piggy"})
        res_drain1 = self.run_cmd(["drain", "worker_piggy", "--json"])
        self.assertEqual(res_drain1.returncode, 0)
        msgs1 = json.loads(res_drain1.stdout.strip())
        self.assertEqual(len(msgs1), 1)
        self.assertIn("reminders", msgs1[0])
        self.assertEqual(msgs1[0]["reminders"][0]["priority"], "HIGH")

        # Send second message immediately (within 10m cadence)
        self.run_cmd(["send", "--to", "worker_piggy", "--subject", "Task 2", "--body", "Second task"],
                     env_overrides={"RHIZO_AGENT_NAME": "sender_piggy"})
        res_drain2 = self.run_cmd(["drain", "worker_piggy", "--json"])
        msgs2 = json.loads(res_drain2.stdout.strip())
        self.assertEqual(len(msgs2), 1)
        # Should NOT be piggybacked again immediately (cooldown active!)
        self.assertNotIn("reminders", msgs2[0])

        # Advance virtual time by 11 minutes (660 seconds)
        self.run_cmd(["time", "advance", "660"])

        # Send third message after cadence elapsed
        self.run_cmd(["send", "--to", "worker_piggy", "--subject", "Task 3", "--body", "Third task"],
                     env_overrides={"RHIZO_AGENT_NAME": "sender_piggy"})
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
        if os.name == "nt":
            self.skipTest("POSIX ps -p parent inspection is not applicable on Windows")
        # Run inside a bash while loop
        bash_cmd = f"set -e; while true; do '{BIN_PATH}' listen test_agent_loop --timeout 1; done"
        res = subprocess.run(["bash", "-c", bash_cmd], capture_output=True, text=True, env=self.env, cwd=self.test_home, timeout=10)
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

    # -------------------------------------------------------------------------
    # Case-Insensitive Channel & Agent Names
    # -------------------------------------------------------------------------
    def test_17_case_insensitive_channels(self):
        """Verify that agent inboxes, tags, queues, locks, decisions, and pub/sub channels are case-insensitive."""
        # 1. Register agent with mixed-case name and tags
        self.run_cmd(["open", "Worker-Alpha", "Backend,QA"])

        # 2. Send messages using various casing
        self.run_cmd(["send", "--to", "worker-alpha", "--subject", "Msg 1", "--body", "Body 1"],
                     env_overrides={"RHIZO_AGENT_NAME": "Manager-Bot"})
        self.run_cmd(["send", "--to", "WORKER-ALPHA", "--subject", "Msg 2", "--body", "Body 2"],
                     env_overrides={"RHIZO_AGENT_NAME": "Manager-Bot"})

        # 3. Drain using original mixed-case name
        res_drain = self.run_cmd(["drain", "Worker-Alpha", "--json"])
        msgs = json.loads(res_drain.stdout.strip())
        self.assertEqual(len(msgs), 2)
        self.assertEqual({m["body"] for m in msgs}, {"Body 1", "Body 2"})

        # 4. Multicast to tags with varying cases
        self.run_cmd(["broadcast", "--tags", "backend", "--subject", "Tag 1", "--body", "Broadcast 1"],
                     env_overrides={"RHIZO_AGENT_NAME": "Manager-Bot"})
        self.run_cmd(["broadcast", "--tags", "BACKEND", "--subject", "Tag 2", "--body", "Broadcast 2"],
                     env_overrides={"RHIZO_AGENT_NAME": "Manager-Bot"})
        self.run_cmd(["broadcast", "--tags", "qa", "--subject", "Tag 3", "--body", "Broadcast 3"],
                     env_overrides={"RHIZO_AGENT_NAME": "Manager-Bot"})

        # Drain via lowercase name
        res_drain2 = self.run_cmd(["drain", "worker-alpha", "--json"])
        msgs2 = json.loads(res_drain2.stdout.strip())
        self.assertEqual(len(msgs2), 3)
        self.assertEqual({m["body"] for m in msgs2}, {"Broadcast 1", "Broadcast 2", "Broadcast 3"})

        # 5. Queue case-insensitivity (enqueue with PascalCase, claim with lowercase, ack with UPPERCASE)
        res_enq = self.run_cmd(["enqueue", "RenderTasks", "--subject", "Task 1", "--body", "render_job_101"],
                               env_overrides={"RHIZO_AGENT_NAME": "Manager-Bot"})
        task_id = res_enq.stdout.strip()

        res_claim = self.run_cmd(["claim", "rendertasks", "--lease", "60", "--timeout", "1"],
                                 env_overrides={"RHIZO_AGENT_NAME": "Worker-Alpha"})
        self.assertEqual(res_claim.returncode, 0)
        claimed_task = json.loads(res_claim.stdout.strip())
        self.assertEqual(claimed_task["id"], task_id)

        res_ack = self.run_cmd(["ack", "RENDERTASKS", task_id])
        self.assertEqual(res_ack.returncode, 0)
        self.assertIn(f"ACK: {task_id}", res_ack.stdout)

        # 6. Lock case-insensitivity
        res_lock1 = self.run_cmd(["lock", "SharedDb", "30"],
                                 env_overrides={"RHIZO_AGENT_NAME": "Worker-Alpha"})
        self.assertEqual(res_lock1.returncode, 0)
        self.assertIn("shareddb by worker-alpha", res_lock1.stdout)

        # Attempt to acquire same lock with different casing from another worker
        res_lock2 = self.run_cmd(["lock", "shareddb", "30"],
                                 env_overrides={"RHIZO_AGENT_NAME": "Worker-Beta"})
        self.assertNotEqual(res_lock2.returncode, 0)
        self.assertIn("already held", res_lock2.stderr)

        # Unlock with UPPERCASE
        res_unlock = self.run_cmd(["unlock", "SHAREDDB"],
                                  env_overrides={"RHIZO_AGENT_NAME": "worker-alpha"})
        self.assertEqual(res_unlock.returncode, 0)
        self.assertIn("shareddb", res_unlock.stdout)

        # 7. Decision case-insensitivity
        res_prop = self.run_cmd(["decision", "propose", "DECISION-ALPHA", "--title", "Test Dec"],
                                env_overrides={"RHIZO_AGENT_NAME": "Worker-Alpha"})
        self.assertEqual(res_prop.returncode, 0)

        res_app = self.run_cmd(["decision", "approve", "decision-alpha"])
        self.assertEqual(res_app.returncode, 0)

        res_ver = self.run_cmd(["decision", "verify", "Decision-Alpha"])
        self.assertEqual(res_ver.returncode, 0)
        self.assertEqual(res_ver.stdout.strip(), "APPROVED")

        # 8. Task lifecycle case-insensitivity
        res_tc = self.run_cmd(["task", "create", "TASK-42", "--title", "Deploy pipeline"],
                              env_overrides={"RHIZO_AGENT_NAME": "Worker-Alpha"})
        self.assertEqual(res_tc.returncode, 0)

        res_tclaim = self.run_cmd(["task", "claim", "task-42", "--no-vine"],
                                  env_overrides={"RHIZO_AGENT_NAME": "Worker-Alpha"})
        self.assertEqual(res_tclaim.returncode, 0)

        res_tprog = self.run_cmd(["task", "progress", "Task-42", "--progress", "50%"],
                                 env_overrides={"RHIZO_AGENT_NAME": "Worker-Alpha"})
        self.assertEqual(res_tprog.returncode, 0)

        res_tcomp = self.run_cmd(["task", "complete", "TASK-42", "--skip-gate"],
                                 env_overrides={"RHIZO_AGENT_NAME": "Worker-Alpha"})
        self.assertEqual(res_tcomp.returncode, 0)

        res_tget = self.run_cmd(["task", "get", "task-42", "--json"])
        self.assertEqual(res_tget.returncode, 0)
        task_data = json.loads(res_tget.stdout.strip())
        self.assertEqual(task_data["state"], "COMPLETED")

        # 9. Leader election case-insensitivity
        res_lacq = self.run_cmd(["leader", "acquire", "ORCHESTRATOR-ROLE", "--agent", "Worker-Alpha"])
        self.assertEqual(res_lacq.returncode, 0)

        res_lst = self.run_cmd(["leader", "status", "orchestrator-role"])
        self.assertEqual(res_lst.returncode, 0)
        lead_data = json.loads(res_lst.stdout.strip())
        self.assertEqual(lead_data["leader"], "worker-alpha")

        res_lres = self.run_cmd(["leader", "resign", "Orchestrator-Role", "--agent", "worker-alpha"])
        self.assertEqual(res_lres.returncode, 0)

        # 10. Floor control case-insensitivity
        res_freq = self.run_cmd(["floor", "request", "ROUNDTABLE-ROOM"],
                                env_overrides={"RHIZO_AGENT_NAME": "Worker-Alpha"})
        self.assertEqual(res_freq.returncode, 0)

        res_fst = self.run_cmd(["floor", "status", "roundtable-room"])
        self.assertEqual(res_fst.returncode, 0)
        floor_data = json.loads(res_fst.stdout.strip())
        self.assertEqual(floor_data["holder"], "worker-alpha")

        res_fyield = self.run_cmd(["floor", "yield", "Roundtable-Room"],
                                  env_overrides={"RHIZO_AGENT_NAME": "Worker-Alpha"})
        self.assertEqual(res_fyield.returncode, 0)

        # 11. Blackboard case-insensitivity
        res_bb_set = self.run_cmd(["blackboard", "set", "DESIGN-ROOM", "StatusKey", "Ready"])
        self.assertEqual(res_bb_set.returncode, 0)

        res_bb_get = self.run_cmd(["blackboard", "get", "design-room", "StatusKey"])
        self.assertEqual(res_bb_get.returncode, 0)
        self.assertEqual(res_bb_get.stdout.strip(), "Ready")

        res_bb_clear = self.run_cmd(["blackboard", "clear", "Design-Room"])
        self.assertEqual(res_bb_clear.returncode, 0)

        # 12. Run cancellation case-insensitivity
        res_cancel_set = self.run_cmd(["cancel", "RUN-999", "--reason", "Test cancel"],
                                      env_overrides={"RHIZO_AGENT_NAME": "Worker-Alpha"})
        self.assertEqual(res_cancel_set.returncode, 0)

        res_cancel_chk = self.run_cmd(["cancel", "check", "run-999"])
        self.assertEqual(res_cancel_chk.returncode, 0)
        self.assertIn("cancelled", res_cancel_chk.stdout)

        res_cancel_clr = self.run_cmd(["cancel", "clear", "Run-999"])
        self.assertEqual(res_cancel_clr.returncode, 0)

        # 13. Ballot case-insensitivity
        res_ballot_open = self.run_cmd(["ballot", "open", "BALLOT-VOTE-1", "--options", "yes,no", "--voters", "Worker-Alpha,Worker-Beta"])
        self.assertEqual(res_ballot_open.returncode, 0)

        res_ballot_cast = self.run_cmd(["ballot", "cast", "ballot-vote-1", "--vote", "yes", "--voter", "worker-alpha"])
        self.assertEqual(res_ballot_cast.returncode, 0)

        res_ballot_tally = self.run_cmd(["ballot", "tally", "Ballot-Vote-1", "--raw"])
        self.assertEqual(res_ballot_tally.returncode, 0)
        self.assertEqual(res_ballot_tally.stdout.strip(), "yes")

    def test_18_field_telemetry_remediations(self):
        """Verify GVR-001, GVR-003, GVR-008, GVR-011, GVR-012 field telemetry remediations."""
        agent_canonical = "agent-canon-1"
        agent_alias = "agent-alias-1"
        agent_sender = "agent-sender-1"

        # 1. Alias CRUD
        res_alias_set = self.run_cmd(["alias", "set", agent_alias, agent_canonical])
        self.assertEqual(res_alias_set.returncode, 0)
        self.assertIn(f"@{agent_alias} -> @{agent_canonical}", res_alias_set.stdout)

        res_alias_get = self.run_cmd(["alias", "get", agent_alias])
        self.assertEqual(res_alias_get.returncode, 0)
        self.assertEqual(res_alias_get.stdout.strip(), agent_canonical)

        res_alias_list = self.run_cmd(["alias", "list", "--json"])
        self.assertEqual(res_alias_list.returncode, 0)
        alias_map = json.loads(res_alias_list.stdout.strip())
        self.assertEqual(alias_map.get(agent_alias), agent_canonical)

        # 2. Transparent Alias Delivery
        # Send message to alias; verify it routes directly into canonical inbox
        res_send = self.run_cmd(["send", "--to", agent_alias, "--subject", "Task for Alias", "--body", "Payload 1", "--from", agent_sender])
        self.assertEqual(res_send.returncode, 0)

        # Non-destructive check on canonical inbox via rhizo history
        res_hist_canon = self.run_cmd(["history", agent_canonical, "--json"])
        self.assertEqual(res_hist_canon.returncode, 0)
        hist_items = json.loads(res_hist_canon.stdout.strip())
        inbox_items = [h for h in hist_items if h.get("source") == "inbox"]
        self.assertEqual(len(inbox_items), 1)
        self.assertEqual(inbox_items[0]["to"], agent_canonical)
        self.assertEqual(inbox_items[0]["subject"], "Task for Alias")

        # 3. Health Probe (GVR-011)
        res_probe = self.run_cmd(["probe", agent_canonical, "--json"])
        self.assertEqual(res_probe.returncode, 0)
        probe_data = json.loads(res_probe.stdout.strip())
        self.assertEqual(probe_data["agent"], agent_canonical)
        self.assertEqual(probe_data["inbox_depth"], 1)
        self.assertIn("issues", probe_data)

        # 4. Atomic Inbox Rerouting (GVR-012)
        agent_target_2 = "agent-worker-2"
        res_reroute = self.run_cmd(["reroute", agent_canonical, agent_target_2, "--json"])
        self.assertEqual(res_reroute.returncode, 0)
        reroute_data = json.loads(res_reroute.stdout.strip())
        self.assertEqual(reroute_data["count"], 1)
        self.assertEqual(reroute_data["status"], "REROUTED")

        # Canonical inbox should now be empty; agent_target_2 inbox should have the message
        res_hist_target = self.run_cmd(["history", agent_target_2, "--json"])
        self.assertEqual(res_hist_target.returncode, 0)
        t_hist = json.loads(res_hist_target.stdout.strip())
        t_inbox = [h for h in t_hist if h.get("source") == "inbox"]
        self.assertEqual(len(t_inbox), 1)
        self.assertEqual(t_inbox[0]["to"], agent_target_2)
        self.assertEqual(t_inbox[0]["rerouted_from"], agent_canonical)

        # 5. Non-Destructive Invariant
        # Verification that rhizo history did not consume the message
        res_drain = self.run_cmd(["drain", "1", agent_target_2, "--json"])
        self.assertEqual(res_drain.returncode, 0)
        drained_msg = json.loads(res_drain.stdout.strip())
        self.assertIsInstance(drained_msg, dict)
        self.assertEqual(drained_msg["subject"], "Task for Alias")

        # 6. Strict Sender Identity Abort (GVR-008)
        # Without --from or RHIZO_AGENT_NAME or .vine.json, send MUST fail loudly
        res_fail_send = self.run_cmd(["send", "--to", agent_target_2, "--subject", "No Sender", "--body", "Should fail"],
                                     env_overrides={"RHIZO_AGENT_NAME": ""})
        self.assertNotEqual(res_fail_send.returncode, 0)
        self.assertIn("Cannot determine sender identity", res_fail_send.stderr)

        # 7. Alias Deletion
        res_alias_del = self.run_cmd(["alias", "del", agent_alias])
        self.assertEqual(res_alias_del.returncode, 0)
        res_alias_get2 = self.run_cmd(["alias", "get", agent_alias])
        self.assertNotEqual(res_alias_get2.returncode, 0)

    def test_19_llm_variance_and_multihop_reroute_invariants(self):
        """Verify LLM variance normalization and multi-hop reroute HMAC preservation."""
        # 1. LLM Variance Normalization in direct message sending
        # --to "@agent-norm-1" must deliver to inbox:agent-norm-1 (one-to-one, NOT multicast)
        res_send_at = self.run_cmd(["send", "--to", "@agent-norm-1", "--subject", "Hello At", "--body", "At payload", "--from", "agent-sender-2"])
        self.assertEqual(res_send_at.returncode, 0)

        # Inspect inbox:agent-norm-1 directly
        res_hist_at = self.run_cmd(["history", "@agent-norm-1", "--json"])
        self.assertEqual(res_hist_at.returncode, 0)
        items_at = [h for h in json.loads(res_hist_at.stdout.strip()) if h.get("source") == "inbox"]
        self.assertEqual(len(items_at), 1)
        self.assertEqual(items_at[0]["to"], "agent-norm-1")
        self.assertEqual(items_at[0]["subject"], "Hello At")

        # More variations: quotes, backticks, brackets, prefixes
        variations = [
            ("<@agent-norm-2>", "agent-norm-2"),
            ("\"agent:@agent-norm-3:\"", "agent-norm-3"),
            ("`inbox:agent-norm-4`", "agent-norm-4"),
        ]
        for raw_dest, canonical_name in variations:
            res_v = self.run_cmd(["send", "--to", raw_dest, "--subject", f"Subj {canonical_name}", "--body", "Payload", "--from", "agent-sender-2"])
            self.assertEqual(res_v.returncode, 0)
            res_h = self.run_cmd(["history", canonical_name, "--json"])
            self.assertEqual(res_h.returncode, 0)
            items = [h for h in json.loads(res_h.stdout.strip()) if h.get("source") == "inbox"]
            self.assertEqual(len(items), 1)
            self.assertEqual(items[0]["to"], canonical_name)

        # Probe with leading @
        res_probe_at = self.run_cmd(["probe", "@agent-norm-1", "--json"])
        self.assertEqual(res_probe_at.returncode, 0)
        probe_at_data = json.loads(res_probe_at.stdout.strip())
        self.assertEqual(probe_at_data["agent"], "agent-norm-1")
        self.assertEqual(probe_at_data["inbox_depth"], 1)

        # 2. Multi-Hop Reroute with Cryptographic HMAC Preservation (CRIT-1)
        # Hop 0: Send to hop-agent-a
        res_hop0 = self.run_cmd(["send", "--to", "hop-agent-a", "--subject", "Multi-Hop Task", "--body", "Secret payload", "--from", "hop-sender"])
        self.assertEqual(res_hop0.returncode, 0)

        # Hop 1: Reroute hop-agent-a -> hop-agent-b
        res_reroute_1 = self.run_cmd(["reroute", "hop-agent-a", "hop-agent-b", "--json"])
        self.assertEqual(res_reroute_1.returncode, 0)
        self.assertEqual(json.loads(res_reroute_1.stdout.strip())["count"], 1)

        # Hop 2: Reroute with flags before positional: reroute --json hop-agent-b hop-agent-c
        res_reroute_2 = self.run_cmd(["reroute", "--json", "hop-agent-b", "hop-agent-c"])
        self.assertEqual(res_reroute_2.returncode, 0)
        self.assertEqual(json.loads(res_reroute_2.stdout.strip())["count"], 1)

        # Hop 3: Drain hop-agent-c. Verifies cryptographic HMAC validation does NOT drop the message!
        res_drain_c = self.run_cmd(["drain", "1", "hop-agent-c", "--json"])
        self.assertEqual(res_drain_c.returncode, 0)
        self.assertNotIn("SECURITY", res_drain_c.stderr)
        msg_c = json.loads(res_drain_c.stdout.strip())
        self.assertEqual(msg_c["subject"], "Multi-Hop Task")
        self.assertEqual(msg_c["original_recipient"], "hop-agent-a")
        self.assertEqual(msg_c["to"], "hop-agent-c")

        # 3. Self-Reroute Rejection
        res_self = self.run_cmd(["reroute", "hop-agent-c", "hop-agent-c"])
        self.assertIn("ERR: Source and destination agents must be different", res_self.stdout)

        # 4. Case-Insensitive Pub/Sub channels
        res_pub = self.run_cmd(["pub", "CHANNEL:METRICS", "heartbeat payload"])
        self.assertEqual(res_pub.returncode, 0)

    def test_20_watchdog_liveness_check(self):
        """Verify rhizo watchdog check across all 4 operational states."""
        agent = "watchdog-agent-1"

        # 1. Idle state (no tasks in flight, no unread messages, no listener)
        # Should return STAND_DOWN (exit 0)
        res_idle = self.run_cmd(["watchdog", "check", "--agent", agent, "--json"])
        self.assertEqual(res_idle.returncode, 0)
        data_idle = json.loads(res_idle.stdout.strip())
        self.assertEqual(data_idle["status"], "STAND_DOWN")
        self.assertEqual(data_idle["substatus"], "IDLE")
        self.assertFalse(data_idle["action_required"])
        self.assertEqual(data_idle["recommended_command"], "none")

        # 2. Unread messages state (inbox depth > 0)
        # Send message to agent
        res_send = self.run_cmd(["send", "--to", agent, "--subject", "Wake Up", "--body", "Work available", "--from", "sender-1"])
        self.assertEqual(res_send.returncode, 0)

        # Watchdog check must detect unread messages and require action (exit 2)
        res_unread = self.run_cmd(["watchdog", "check", "--agent", agent, "--json"])
        self.assertEqual(res_unread.returncode, 2)
        data_unread = json.loads(res_unread.stdout.strip())
        self.assertEqual(data_unread["status"], "ACTION_REQUIRED")
        self.assertEqual(data_unread["substatus"], "UNREAD_MESSAGES")
        self.assertTrue(data_unread["action_required"])
        self.assertEqual(data_unread["inbox_depth"], 1)
        self.assertIn("rhizo listen", data_unread["recommended_command"])

        # Drain message
        res_drain = self.run_cmd(["drain", "1", agent, "--json"])
        self.assertEqual(res_drain.returncode, 0)

        # 3. Tasks in flight but no listener (enqueue task to queue)
        res_enq = self.run_cmd(["enqueue", "render_queue", "--subject", "Render Frame", "--body", '{"id":"t-100"}'])
        self.assertEqual(res_enq.returncode, 0)

        # Watchdog check must detect in-flight tasks and require REARM_LISTENER (exit 2)
        res_rearm = self.run_cmd(["watchdog", "check", "--agent", agent, "--json"])
        self.assertEqual(res_rearm.returncode, 2)
        data_rearm = json.loads(res_rearm.stdout.strip())
        self.assertEqual(data_rearm["status"], "ACTION_REQUIRED")
        self.assertEqual(data_rearm["substatus"], "REARM_LISTENER")
        self.assertTrue(data_rearm["action_required"])
        self.assertGreater(data_rearm["tasks_in_flight"], 0)
        self.assertEqual(data_rearm["recommended_command"], f"rhizo listen {agent}")

        # 4. Explicit --expect-listening flag overrides idle
        # Clean up queue
        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", f"{TEST_PREFIX}queue:render_queue", f"{TEST_PREFIX}queue:{{render_queue}}"], capture_output=True)
        res_expect = self.run_cmd(["watchdog", "check", "--agent", agent, "--expect-listening", "--json"])
        self.assertEqual(res_expect.returncode, 2)
        data_expect = json.loads(res_expect.stdout.strip())
        self.assertEqual(data_expect["status"], "ACTION_REQUIRED")
        self.assertEqual(data_expect["substatus"], "REARM_LISTENER")

        # 5. Active listener state (OK, exit 0) with stepped backoff & 4-strike cap
        # Register a mock listener in Redis
        listener_payload = json.dumps({"pid": os.getpid(), "host": "127.0.0.1", "started": int(time.time())})
        subprocess.run(["redis-cli", "-u", REDIS_URL, "SETEX", f"{TEST_PREFIX}listener:{agent}", "60", listener_payload], check=True)
        
        # Check 1: Streak 1, next cadence 1800s (30m)
        res_ok1 = self.run_cmd(["watchdog", "check", "--agent", agent, "--json"])
        self.assertEqual(res_ok1.returncode, 0)
        data_ok1 = json.loads(res_ok1.stdout.strip())
        self.assertEqual(data_ok1["status"], "OK")
        self.assertEqual(data_ok1["substatus"], "LISTENING")
        self.assertTrue(data_ok1["listener_active"])
        self.assertFalse(data_ok1["action_required"])
        self.assertEqual(data_ok1["streak"], 1)
        self.assertEqual(data_ok1["recommended_cadence"], 1800)
        self.assertEqual(data_ok1["next_action"], "SCHEDULE_TIMER")

        # Check 2: Streak 2, next cadence 3600s (60m)
        res_ok2 = self.run_cmd(["watchdog", "check", "--agent", agent, "--json"])
        self.assertEqual(res_ok2.returncode, 0)
        data_ok2 = json.loads(res_ok2.stdout.strip())
        self.assertEqual(data_ok2["streak"], 2)
        self.assertEqual(data_ok2["recommended_cadence"], 3600)
        self.assertEqual(data_ok2["next_action"], "SCHEDULE_TIMER")

        # Check 3: Streak 3, next cadence 7200s (120m)
        res_ok3 = self.run_cmd(["watchdog", "check", "--agent", agent, "--json"])
        self.assertEqual(res_ok3.returncode, 0)
        data_ok3 = json.loads(res_ok3.stdout.strip())
        self.assertEqual(data_ok3["streak"], 3)
        self.assertEqual(data_ok3["recommended_cadence"], 7200)
        self.assertEqual(data_ok3["next_action"], "SCHEDULE_TIMER")

        # Check 4: Streak 4 (Max Streak Reached -> Stand Down, cadence 0)
        res_ok4 = self.run_cmd(["watchdog", "check", "--agent", agent, "--json"])
        self.assertEqual(res_ok4.returncode, 0)
        data_ok4 = json.loads(res_ok4.stdout.strip())
        self.assertEqual(data_ok4["status"], "STAND_DOWN")
        self.assertEqual(data_ok4["substatus"], "MAX_STREAK_REACHED")
        self.assertEqual(data_ok4["streak"], 4)
        self.assertEqual(data_ok4["recommended_cadence"], 0)
        self.assertEqual(data_ok4["next_action"], "STAND_DOWN")

        # 6. Reset watchdog streak explicitly via CLI
        res_reset = self.run_cmd(["watchdog", "reset", "--agent", agent, "--json"])
        self.assertEqual(res_reset.returncode, 0)
        data_reset = json.loads(res_reset.stdout.strip())
        self.assertEqual(data_reset["streak"], 0)
        self.assertEqual(data_reset["recommended_cadence"], 900)

        # Re-check after reset: starts at streak 1
        res_after_reset = self.run_cmd(["watchdog", "check", "--agent", agent, "--json"])
        self.assertEqual(res_after_reset.returncode, 0)
        data_after = json.loads(res_after_reset.stdout.strip())
        self.assertEqual(data_after["streak"], 1)

        # 7. Activity reset: sending a message resets streak back to 0
        res_send = self.run_cmd(["send", "--to", "other-agent", "--subject", "Hello", "--body", "World", "--from", agent])
        self.assertEqual(res_send.returncode, 0)
        # Next check should be streak 1 again (because send reset it to 0)
        res_after_send = self.run_cmd(["watchdog", "check", "--agent", agent, "--json"])
        self.assertEqual(res_after_send.returncode, 0)
        data_after_send = json.loads(res_after_send.stdout.strip())
        self.assertEqual(data_after_send["streak"], 1)

    def test_21_work_item_state_machine(self):
        """Verify the unified Work Item State Machine (WISM), DAG dependencies, causal clearing, and hook gates."""
        prefix = TEST_PREFIX
        agent_parent = "wism-parent-worker"
        agent_child = "wism-child-worker"
        task_parent = "wism-task-1"
        task_child = "wism-task-2"

        # 1. Clean Redis state for test keys
        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL",
                        f"{prefix}task:{task_parent}",
                        f"{prefix}task:{task_child}",
                        f"{prefix}task:tasks_all",
                        f"{prefix}task:tasks_state:queued",
                        f"{prefix}task:tasks_state:blocked",
                        f"{prefix}task:tasks_state:delivered",
                        f"{prefix}task:tasks_state:in_progress",
                        f"{prefix}task:tasks_state:ready_to_weave",
                        f"{prefix}task:tasks_state:completed",
                        f"{prefix}task:tasks_state:orphaned",
                        f"{prefix}task:tasks_state:dead_letter",
                        f"{prefix}current_task:{agent_parent}",
                        f"{prefix}current_task:{agent_child}"], check=True)

        # 2. DAG Dependency Blocking & Automatic Unblocking
        # Create parent task (should start QUEUED)
        res_p = self.run_cmd(["task", "create", task_parent, "--title", "Parent Foundation Task"])
        self.assertEqual(res_p.returncode, 0)
        
        res_p_get = self.run_cmd(["task", "get", task_parent, "--json"])
        self.assertEqual(res_p_get.returncode, 0)
        data_p = json.loads(res_p_get.stdout.strip())
        self.assertEqual(data_p["state"], "QUEUED")

        # Create child task with dependency on parent (should start BLOCKED)
        res_c = self.run_cmd(["task", "create", task_child, "--title", "Child Dependent Task", "--depends-on", task_parent])
        self.assertEqual(res_c.returncode, 0)

        res_c_get = self.run_cmd(["task", "get", task_child, "--json"])
        self.assertEqual(res_c_get.returncode, 0)
        data_c = json.loads(res_c_get.stdout.strip())
        self.assertEqual(data_c["state"], "BLOCKED")
        self.assertIn(task_parent, data_c["depends_on"])

        # Invariant HIGH-1: Attempting to claim a BLOCKED task MUST fail
        res_blocked_claim = self.run_cmd(["task", "claim", task_child, "--worker", agent_child, "--no-vine"])
        self.assertNotEqual(res_blocked_claim.returncode, 0)
        self.assertIn("BLOCKED by incomplete dependencies", res_blocked_claim.stderr)

        # Claim and complete parent task
        res_p_claim = self.run_cmd(["task", "claim", task_parent, "--worker", agent_parent, "--lease", "60", "--no-vine"])
        self.assertEqual(res_p_claim.returncode, 0)

        res_p_comp = self.run_cmd(["task", "complete", task_parent, "--worker", agent_parent])
        self.assertEqual(res_p_comp.returncode, 0)

        # Invariant HIGH-1: Attempting to re-claim a COMPLETED task MUST fail
        res_comp_claim = self.run_cmd(["task", "claim", task_parent, "--worker", agent_parent, "--no-vine"])
        self.assertNotEqual(res_comp_claim.returncode, 0)
        self.assertIn("already COMPLETED", res_comp_claim.stderr)

        # Invariant check: Parent is COMPLETED, Child is AUTOMATICALLY promoted to QUEUED!
        res_c_get2 = self.run_cmd(["task", "get", task_child, "--json"])
        self.assertEqual(res_c_get2.returncode, 0)
        data_c2 = json.loads(res_c_get2.stdout.strip())
        self.assertEqual(data_c2["state"], "QUEUED")

        # 3. Full Lifecycle: Claim -> Progress -> Gate-Report -> Complete
        res_c_claim = self.run_cmd(["task", "claim", task_child, "--worker", agent_child, "--lease", "60", "--no-vine"])
        self.assertEqual(res_c_claim.returncode, 0)

        res_c_curr = self.run_cmd(["task", "current", agent_child, "--json"])
        self.assertEqual(res_c_curr.returncode, 0)
        data_curr = json.loads(res_c_curr.stdout.strip())
        self.assertEqual(data_curr["state"], "IN_PROGRESS")
        self.assertEqual(data_curr["id"], task_child)

        # Progress update
        res_prog = self.run_cmd(["task", "progress", task_child, "Implemented unit tests", "--worker", agent_child])
        self.assertEqual(res_prog.returncode, 0)

        # Invariant MEDIUM-1: Progress update on non-existent task MUST fail
        res_prog_nonexist = self.run_cmd(["task", "progress", "phantom-task-nonexistent", "Should fail", "--worker", agent_child])
        self.assertNotEqual(res_prog_nonexist.returncode, 0)
        self.assertIn("does not exist", res_prog_nonexist.stderr)

        # Gate Report
        res_gate = self.run_cmd(["task", "gate-report", task_child, "--gate-token", "GATE-OK-SHA-999", "--worker", agent_child])
        self.assertEqual(res_gate.returncode, 0)
        res_c_get3 = self.run_cmd(["task", "get", task_child, "--json"])
        data_c3 = json.loads(res_c_get3.stdout.strip())
        self.assertEqual(data_c3["state"], "READY_TO_WEAVE")
        self.assertEqual(data_c3["gate_token"], "GATE-OK-SHA-999")

        # Invariant HIGH-1: Attempting to claim a READY_TO_WEAVE task MUST fail
        res_weave_claim = self.run_cmd(["task", "claim", task_child, "--worker", "another-worker", "--no-vine"])
        self.assertNotEqual(res_weave_claim.returncode, 0)
        self.assertIn("READY_TO_WEAVE", res_weave_claim.stderr)

        # Complete
        res_c_comp = self.run_cmd(["task", "complete", task_child, "--worker", agent_child])
        self.assertEqual(res_c_comp.returncode, 0)
        res_c_curr2 = self.run_cmd(["task", "current", agent_child, "--json"])
        self.assertEqual(res_c_curr2.stdout.strip(), "{}")

        # Invariant HIGH-3: Project-scoped orchestrator can complete any worker's task
        task_orch_test = f"task-orch-{int(time.time()*1000)}"
        self.run_cmd(["task", "create", task_orch_test, "--title", "Orchestrator Complete Test"])
        self.run_cmd(["task", "claim", task_orch_test, "--worker", "sub-worker-1", "--no-vine"])
        res_orch_comp = self.run_cmd(["task", "complete", task_orch_test, "--worker", "myproj-orchestrator"])
        self.assertEqual(res_orch_comp.returncode, 0)

        # 4. Turn-End Codex Stop Hook Verification with local current_task.json and per-agent isolation
        rhizo_dir = os.path.join(self.test_home, ".config", "rhizo")
        os.makedirs(rhizo_dir, exist_ok=True)
        task_stamp_file = os.path.join(rhizo_dir, "current_task.json")
        worker_a_file = os.path.join(rhizo_dir, "current_task_worker_a.json")

        # Negative control: when current_task.json exists, hook MUST BLOCK
        mock_task = {"id": "pending-task-1", "subject": "Fix issue", "body": "Do work", "state": "DELIVERED"}
        with open(task_stamp_file, "w") as f:
            json.dump(mock_task, f)

        res_hook_block = self.run_cmd(["hook", "codex-stop", "--agent", "test-worker"])
        self.assertEqual(res_hook_block.returncode, 0)
        data_block = json.loads(res_hook_block.stdout.strip())
        self.assertEqual(data_block.get("decision"), "block")
        self.assertIn("UNACKNOWLEDGED ACTIVE TASK", data_block.get("reason", ""))

        # Positive control: when current_task.json is cleaned, hook MUST PASS (no block decision)
        if os.path.exists(task_stamp_file):
            os.remove(task_stamp_file)

        res_hook_pass = self.run_cmd(["hook", "codex-stop", "--agent", "test-worker"])
        self.assertEqual(res_hook_pass.returncode, 0)
        data_pass = json.loads(res_hook_pass.stdout.strip())
        self.assertNotEqual(data_pass.get("decision"), "block")

        # Invariant HIGH-2: Per-agent local isolation between concurrent agents
        mock_task_a = {"id": "task-a", "subject": "Work A", "body": "...", "state": "DELIVERED", "owner": "worker_a"}
        with open(worker_a_file, "w") as f:
            json.dump(mock_task_a, f)

        # Worker A MUST be blocked by its own current_task_worker_a.json
        res_hook_a = self.run_cmd(["hook", "codex-stop", "--agent", "worker_a"])
        self.assertEqual(res_hook_a.returncode, 0)
        self.assertEqual(json.loads(res_hook_a.stdout.strip()).get("decision"), "block")

        # Worker B (independent agent) MUST NOT be blocked by Worker A's file
        res_hook_b = self.run_cmd(["hook", "codex-stop", "--agent", "worker_b"])
        self.assertEqual(res_hook_b.returncode, 0)
        self.assertNotEqual(json.loads(res_hook_b.stdout.strip()).get("decision"), "block")

        if os.path.exists(worker_a_file):
            os.remove(worker_a_file)

    def test_22_bare_role_project_scoping(self):
        """Verify that bare generic roles (architect, orchestrator, etc.) are never used bare and always project-scoped."""
        proj = "alpha-proj"

        # 1. rhizo name without args uses project prefix
        res_name = self.run_cmd(["name"], env_overrides={"RHIZO_PROJECT": proj})
        self.assertEqual(res_name.returncode, 0)
        self.assertTrue(res_name.stdout.strip().startswith(proj + "-"))

        # 2. rhizo name architect prefixes with project
        res_name_arch = self.run_cmd(["name", "architect"], env_overrides={"RHIZO_PROJECT": proj})
        self.assertEqual(res_name_arch.returncode, 0)
        self.assertTrue(res_name_arch.stdout.strip().startswith(proj + "-architect-"))

        # 3. rhizo open architect automatically scopes to alpha-proj-architect
        res_open = self.run_cmd(["open", "architect"], env_overrides={"RHIZO_PROJECT": proj})
        self.assertEqual(res_open.returncode, 0)
        self.assertIn("alpha-proj-architect", res_open.stdout)
        self.assertIn("automatically scoped to project", res_open.stderr)

        # 4. rhizo listen with bare role scopes to alpha-proj-orchestrator
        res_listen = self.run_cmd(["listen", "orchestrator", "--timeout", "1"], env_overrides={"RHIZO_PROJECT": proj})
        self.assertEqual(res_listen.returncode, 0)
        self.assertIn("alpha-proj-orchestrator", res_listen.stderr)

        # Clean up
        self.run_cmd(["close", "alpha-proj-architect"], env_overrides={"RHIZO_PROJECT": proj})
        self.run_cmd(["close", "alpha-proj-orchestrator"], env_overrides={"RHIZO_PROJECT": proj})

    def test_23_terminal_title_and_poke_invariants(self):
        """Verify dynamic ANSI terminal titling and rhizo poke doorbell safety interlocks."""
        # 1. rhizo title sets terminal title via ANSI OSC escape sequence on stderr
        res_title = self.run_cmd(["title", "custom-worker"])
        self.assertEqual(res_title.returncode, 0)
        self.assertIn("Terminal title set to: custom-worker", res_title.stdout)
        self.assertIn("\x1b]0;custom-worker\x07", res_title.stderr)

        # 2. rhizo title with project scoping
        proj = "poke-proj"
        res_title_scoped = self.run_cmd(["title", "architect"], env_overrides={"RHIZO_PROJECT": proj})
        self.assertEqual(res_title_scoped.returncode, 0)
        self.assertIn("Terminal title set to: poke-proj-architect", res_title_scoped.stdout)
        self.assertIn("\x1b]0;poke-proj-architect\x07", res_title_scoped.stderr)

        # 3. rhizo poke dry-run on non-existent window
        res_poke_dry = self.run_cmd(["poke", "ghost-agent", "--dry-run", "--json"])
        self.assertEqual(res_poke_dry.returncode, 0)
        data_poke_dry = json.loads(res_poke_dry.stdout.strip())
        self.assertEqual(data_poke_dry["status"], "NOT_FOUND")
        self.assertTrue(data_poke_dry["dry_run"])
        self.assertEqual(data_poke_dry["command"], "rhizo listen ghost-agent")

        # 4. rhizo poke custom command dry-run
        res_poke_cmd = self.run_cmd(["poke", "ghost-agent", "--cmd", "echo wakeup", "--dry-run", "--json"])
        self.assertEqual(res_poke_cmd.returncode, 0)
        data_poke_cmd = json.loads(res_poke_cmd.stdout.strip())
        self.assertEqual(data_poke_cmd["command"], "echo wakeup")

        # 4b. rhizo poke custom command via '--' delimiter
        res_poke_dash = self.run_cmd(["poke", "ghost-agent", "--dry-run", "--json", "--", "echo", "wakeup via double dash"])
        self.assertEqual(res_poke_dash.returncode, 0)
        data_poke_dash = json.loads(res_poke_dash.stdout.strip())
        self.assertIn(data_poke_dash["command"], ["echo 'wakeup via double dash'", 'echo "wakeup via double dash"'])

        # 5. rhizo poke safety check: when an agent is actively listening with 0 unread messages, poke is SKIPPED
        target_agent = "healthy-worker"
        self.run_cmd(["open", target_agent, "worker"])

        # Register active listener state in Redis
        import socket
        my_pid = os.getpid()
        my_host = socket.gethostname()
        listener_json = json.dumps({"pid": my_pid, "host": my_host, "started": int(time.time())})
        subprocess.run(["redis-cli", "-u", REDIS_URL, "SET", f"{TEST_PREFIX}listener:{target_agent}", listener_json], check=True)
        subprocess.run(["redis-cli", "-u", REDIS_URL, "SETEX", f"{TEST_PREFIX}heartbeat:{target_agent}", "120", "alive"], check=True)

        # Verify probe reports HEALTHY listener
        res_probe = self.run_cmd(["probe", target_agent, "--json"])
        self.assertEqual(res_probe.returncode, 0)
        probe_data = json.loads(res_probe.stdout.strip())
        self.assertEqual(probe_data["status"], "HEALTHY")
        self.assertTrue(probe_data["listener_registered"])
        self.assertTrue(probe_data["listener_pid_alive"])

        # Now rhizo poke MUST skip to prevent corrupting active listener stdin
        res_poke_skip = self.run_cmd(["poke", target_agent, "--json"])
        self.assertEqual(res_poke_skip.returncode, 0)
        data_skip = json.loads(res_poke_skip.stdout.strip())
        self.assertEqual(data_skip["status"], "SKIPPED")
        self.assertEqual(data_skip["reason"], "ALREADY_LISTENING")
        self.assertIn("already actively listening", data_skip["message"])

        # With --force, the safety check is bypassed
        res_poke_force = self.run_cmd(["poke", target_agent, "--force", "--dry-run", "--json"])
        self.assertEqual(res_poke_force.returncode, 0)
        data_force = json.loads(res_poke_force.stdout.strip())
        self.assertNotEqual(data_force.get("status"), "SKIPPED")

        # Clean up
        self.run_cmd(["close", target_agent])

    # -------------------------------------------------------------------------
    # Problem 24: Two-Key Gate Command Interlock (rhizo task complete & rhizo reply)
    # -------------------------------------------------------------------------
    def test_24_two_key_gate_command_interlock(self):
        """Verify the Two-Key Gate Command Interlock in rhizo task complete and rhizo reply with real vine gate integration."""
        if shutil.which("vine") is None:
            self.skipTest("vine executable not installed or not in PATH")
        # Provision real canonical git repo matching RHIZO_PROJECT ("coord_test")
        repo_dir = os.path.join(self.test_home, "coord_test")
        os.makedirs(repo_dir, exist_ok=True)
        subprocess.run(["git", "init", "-b", "main", repo_dir], check=True, capture_output=True, env=self.env)
        subprocess.run(["git", "-C", repo_dir, "config", "user.name", "Coord Tester"], check=True, env=self.env)
        subprocess.run(["git", "-C", repo_dir, "config", "user.email", "coord@rhizo.local"], check=True, env=self.env)
        subprocess.run(["git", "-C", repo_dir, "commit", "--allow-empty", "-m", "initial commit"], check=True, capture_output=True, env=self.env)

        worker = "gate-worker-1"
        orchestrator = "gate-orchestrator-1"
        self.run_cmd(["open", worker, "worker"])
        self.run_cmd(["open", orchestrator, "orchestrator"])

        task_id = "task-gate-interlock-test"
        res_create = self.run_cmd(["task", "create", task_id, "--title", "Gate Interlock Test", "--assignee", worker])
        self.assertEqual(res_create.returncode, 0)

        # Provision real Vine strand using `vine new`
        res_vine = subprocess.run(
            ["vine", "new", task_id, "--repo", repo_dir, "--worktree"],
            capture_output=True, text=True, env=self.env, check=True
        )
        strand_data = json.loads(res_vine.stdout.strip())
        strand_dir = strand_data["strand_path"]
        manifest_path = os.path.join(strand_dir, ".vine.json")
        self.assertTrue(os.path.isfile(manifest_path), "Real .vine.json must be created by vine new")

        # Claim task with real strand directory
        res_claim = self.run_cmd(["task", "claim", task_id, "--worker", worker, "--strand", strand_dir, "--lease", "120"])
        self.assertEqual(res_claim.returncode, 0)

        # 1. Unverified Strand Interlock (initial state from vine new)
        # 1a: rhizo task complete inside strand MUST fail
        res_comp_fail = self.run_cmd(["task", "complete", task_id, "--worker", worker], cwd=strand_dir)
        self.assertNotEqual(res_comp_fail.returncode, 0)
        self.assertIn("[VINE GATE ERROR]", res_comp_fail.stderr)
        self.assertIn("Run `vine gate`", res_comp_fail.stderr)

        # 1b: rhizo task complete from outside strand (with recorded strand_path) MUST also fail
        res_comp_out_fail = self.run_cmd(["task", "complete", task_id, "--worker", worker])
        self.assertNotEqual(res_comp_out_fail.returncode, 0)
        self.assertIn("[VINE GATE ERROR]", res_comp_out_fail.stderr)

        # 1c: rhizo reply with explicit --complete inside strand MUST fail
        completion_flags = [
            ["--complete"],
            ["--status=complete"],
            ["--status", "complete"],
        ]
        for cflag in completion_flags:
            res_rep_fail = self.run_cmd(
                ["reply", "--to", orchestrator, "--from", worker, "--subject", "Finished task", "--body", "Work done"] + cflag,
                cwd=strand_dir
            )
            self.assertNotEqual(res_rep_fail.returncode, 0, f"Expected reply with flag '{cflag}' to fail in unverified strand")
            self.assertIn("[VINE GATE ERROR]", res_rep_fail.stderr)
            self.assertIn("Run `vine gate`", res_rep_fail.stderr)

        # 1d: rhizo send with explicit --complete inside strand MUST also fail
        res_send_fail = self.run_cmd(
            ["send", "--to", orchestrator, "--from", worker, "--subject", "Finished task", "--body", "Done", "--complete"],
            cwd=strand_dir
        )
        self.assertNotEqual(res_send_fail.returncode, 0)
        self.assertIn("[VINE GATE ERROR]", res_send_fail.stderr)

        # 2. Intermediate Inquiries & Non-Completion Subjects Must Pass (Normal Coordination Unimpeded)
        intermediate_inquiries = [
            "Task Claimed",
            "Clarification on test requirements",
            "Re: Is task done?",
            "Progress on complete refactor",
            "Task Done",
            "Task Complete",
        ]
        for subj in intermediate_inquiries:
            res_chat = self.run_cmd(
                ["reply", "--to", orchestrator, "--from", worker, "--subject", subj, "--body", "Status payload"],
                cwd=strand_dir
            )
            self.assertEqual(res_chat.returncode, 0, f"Intermediate inquiry '{subj}' must not trigger gate verification")

        # 3. Subdirectory Manifest Discovery
        sub_dir = os.path.join(strand_dir, "src", "nested")
        os.makedirs(sub_dir, exist_ok=True)
        res_sub_fail = self.run_cmd(
            ["reply", "--to", orchestrator, "--from", worker, "--subject", "Task Done", "--body", "Finished from subdir", "--complete"],
            cwd=sub_dir
        )
        self.assertNotEqual(res_sub_fail.returncode, 0)
        self.assertIn("[VINE GATE ERROR]", res_sub_fail.stderr)

        # 4. Manual Bypass via --skip-gate
        res_skip_reply = self.run_cmd(
            ["reply", "--to", orchestrator, "--from", worker, "--subject", "Task Done", "--body", "Forced", "--complete", "--skip-gate"],
            cwd=strand_dir
        )
        self.assertEqual(res_skip_reply.returncode, 0)

        # 5. Real Key 2 Test Failure Interlock (Anti-Green-Mirage via actual vine gate)
        res_gate_fail = subprocess.run(
            ["vine", "gate", "--dir", strand_dir, "--test-command", "exit 1"],
            capture_output=True, text=True, env=self.env
        )
        self.assertNotEqual(res_gate_fail.returncode, 0, "vine gate must fail when test command fails")
        with open(manifest_path) as f:
            failed_manifest = json.load(f)
        self.assertEqual(failed_manifest.get("status"), "GATE_FAILED")
        self.assertIsNone(failed_manifest.get("gate_token"))

        res_no_token_comp = self.run_cmd(["task", "complete", task_id, "--worker", worker], cwd=strand_dir)
        self.assertNotEqual(res_no_token_comp.returncode, 0)
        self.assertIn("[VINE GATE ERROR]", res_no_token_comp.stderr)

        # 6. Real Key 1 & Key 2 Pass via actual vine gate -> MUST SUCCEED
        res_gate_pass = subprocess.run(
            ["vine", "gate", "--dir", strand_dir, "--test-command", "true"],
            capture_output=True, text=True, env=self.env
        )
        self.assertEqual(res_gate_pass.returncode, 0, "vine gate must pass when test command succeeds")
        with open(manifest_path) as f:
            passed_manifest = json.load(f)
        self.assertIn(passed_manifest.get("status"), ["READY_TO_WEAVE", "READY_FOR_WEAVE"])
        self.assertEqual(passed_manifest.get("lifecycle_state"), "GATE_PASSED")
        gate_token = passed_manifest.get("gate_token") or passed_manifest.get("merge_tree_sha")
        self.assertTrue(bool(gate_token), "vine gate must produce a valid gate token")

        # 6-audit: Verify cryptographic gate certificate
        self.assertIn("test_output_hash", passed_manifest)
        import hashlib
        expected_sig = hashlib.sha256(f"{passed_manifest['merge_tree_sha']}:{passed_manifest['test_output_hash']}".encode()).hexdigest()
        self.assertEqual(passed_manifest["gate_token"], expected_sig)

        # 6-tamper: Tampered gate token MUST be rejected by rhizo task complete
        tampered_manifest = dict(passed_manifest)
        tampered_manifest["gate_token"] = "forged-token-signature-invalid"
        with open(manifest_path, "w") as f:
            json.dump(tampered_manifest, f)

        res_tamper = self.run_cmd(["task", "complete", task_id, "--worker", worker], cwd=strand_dir)
        self.assertNotEqual(res_tamper.returncode, 0)
        self.assertIn("Gate certificate verification failed", res_tamper.stderr)

        # Restore authentic manifest
        with open(manifest_path, "w") as f:
            json.dump(passed_manifest, f)

        # 6a: rhizo reply with explicit --complete now succeeds
        res_rep_ok = self.run_cmd(
            ["reply", "--to", orchestrator, "--from", worker, "--subject", f"Task {task_id} Done", "--body", "100% Green", "--complete"],
            cwd=strand_dir
        )
        self.assertEqual(res_rep_ok.returncode, 0)

        # 6b: rhizo task complete succeeds and records real gate token in Redis
        res_comp_ok = self.run_cmd(["task", "complete", task_id, "--worker", worker], cwd=strand_dir)
        self.assertEqual(res_comp_ok.returncode, 0)
        self.assertIn(f"COMPLETED task '{task_id}'", res_comp_ok.stdout)

        # 6c: Verify Redis task contract contains COMPLETED state and the real gate token
        res_get = self.run_cmd(["task", "get", task_id, "--json"])
        self.assertEqual(res_get.returncode, 0)
        task_data = json.loads(res_get.stdout.strip())
        self.assertEqual(task_data["state"], "COMPLETED")
        self.assertEqual(task_data["gate_token"], gate_token)

        # Clean up
        self.run_cmd(["close", worker])
        self.run_cmd(["close", orchestrator])


    # -------------------------------------------------------------------------
    # Problem 25: Completion-Aware Auto-Idle on Reply & Alias Resolution
    # -------------------------------------------------------------------------
    def test_25_auto_idle_on_reply_and_alias_resolution(self):
        """Verify completion-aware auto-idle, delivery isolation, and alias resolution."""
        worker = "auto-idle-worker"
        orchestrator = "auto-idle-orchestrator"
        self.run_cmd(["open", worker, "worker"])
        self.run_cmd(["open", orchestrator, "orchestrator"])

        # 1. Setup in-flight task on worker
        task_id = "task-idle-check"
        self.run_cmd(["task", "create", task_id, "--title", "Idle Check Task", "--assignee", worker])
        self.run_cmd(["task", "claim", task_id, "--worker", worker, "--no-vine"])

        rhizo_dir = os.path.join(self.test_home, ".config", "rhizo")
        os.makedirs(rhizo_dir, exist_ok=True)
        worker_task_file = os.path.join(rhizo_dir, f"current_task_{worker}.json")
        with open(worker_task_file, "w") as f:
            json.dump({"id": task_id, "state": "IN_PROGRESS"}, f)

        # Verify initial busy state in who
        res_who = self.run_cmd(["who", "--json"])
        self.assertEqual(res_who.returncode, 0)
        who_data = {a["agent"]: a for a in json.loads(res_who.stdout.strip())}
        self.assertIn(f"busy ({task_id})", who_data[worker]["state"].lower())

        # 2. Negative Control: Intermediate replies must NOT auto-idle (even with 'done' or 'complete' in subject)
        for intermediate_subj in ["Progress check: 50% done", "Re: Is task done?", "Work on complete refactor"]:
            res_inter = self.run_cmd([
                "reply", "--to", orchestrator, "--from", worker,
                "--subject", intermediate_subj, "--body", "Still running tests",
                "--skip-gate"
            ])
            self.assertEqual(res_inter.returncode, 0)

            # Worker local file must STILL exist
            self.assertTrue(os.path.exists(worker_task_file), f"Intermediate reply '{intermediate_subj}' must not clear local task stamp")

            # Worker presence in who must STILL be busy with updated activity
            res_who_inter = self.run_cmd(["who", "--json"])
            self.assertEqual(res_who_inter.returncode, 0)
            who_inter_data = {a["agent"]: a for a in json.loads(res_who_inter.stdout.strip())}
            self.assertIn(f"busy ({task_id})", who_inter_data[worker]["state"].lower())

        # 3. Positive Control: Explicit --complete flag triggers auto-idle
        res_comp = self.run_cmd([
            "reply", "--to", orchestrator, "--from", worker,
            "--subject", "Task Complete: Two-Key Gate Passed", "--body", "Finished cleanly",
            "--complete", "--skip-gate"
        ])
        self.assertEqual(res_comp.returncode, 0)

        # Local task stamp must be deleted
        self.assertFalse(os.path.exists(worker_task_file), "Completion reply must delete local task stamp")

        # Redis task pointers must be cleared
        res_cur = subprocess.run(["redis-cli", "-u", REDIS_URL, "GET", f"{TEST_PREFIX}current_task:{worker}"], capture_output=True, text=True)
        self.assertEqual(res_cur.stdout.strip(), "")
        res_hcur = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", f"{TEST_PREFIX}agent:{worker}", "current_task"], capture_output=True, text=True)
        self.assertEqual(res_hcur.stdout.strip(), "")

        # Worker state in who must be IDLE
        res_who_comp = self.run_cmd(["who", "--json"])
        self.assertEqual(res_who_comp.returncode, 0)
        who_comp_data = {a["agent"]: a for a in json.loads(res_who_comp.stdout.strip())}
        self.assertEqual(who_comp_data[worker]["state"].upper(), "IDLE")

        # 4. Explicit --idle flag triggers auto-idle even for non-completion subjects
        # Re-set task on worker
        with open(worker_task_file, "w") as f:
            json.dump({"id": "task-custom-done", "state": "IN_PROGRESS"}, f)
        subprocess.run(["redis-cli", "-u", REDIS_URL, "SET", f"{TEST_PREFIX}current_task:{worker}", "task-custom-done"], check=True)
        subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", f"{TEST_PREFIX}agent:{worker}", "current_task", "task-custom-done"], check=True)

        res_flag_idle = self.run_cmd([
            "reply", "--to", orchestrator, "--from", worker,
            "--subject", "Arbitrary non-completion subject", "--body", "Forcing idle",
            "--idle", "--skip-gate"
        ])
        self.assertEqual(res_flag_idle.returncode, 0)
        self.assertFalse(os.path.exists(worker_task_file))
        res_who_flag = self.run_cmd(["who", "--json"])
        who_flag_data = {a["agent"]: a for a in json.loads(res_who_flag.stdout.strip())}
        self.assertEqual(who_flag_data[worker]["state"].upper(), "IDLE")

        # 5. Non-task message delivery isolation: incoming replies/info must NOT stamp current_task
        # Clean orchestrator current_task
        orch_task_file = os.path.join(rhizo_dir, f"current_task_{orchestrator}.json")
        if os.path.exists(orch_task_file):
            os.remove(orch_task_file)
        subprocess.run(["redis-cli", "-u", REDIS_URL, "HDEL", f"{TEST_PREFIX}agent:{orchestrator}", "current_task"], check=True)

        # Send a reply to orchestrator
        self.run_cmd(["send", "--to", orchestrator, "--from", worker, "--type", "reply", "--subject", "Reply message", "--body", "Payload"])
        # Drain/listen to pop the message
        res_pop = self.run_cmd(["listen", orchestrator, "--timeout", "1"])
        self.assertEqual(res_pop.returncode, 0)

        # Orchestrator MUST NOT have current_task set in Redis or on disk
        self.assertFalse(os.path.exists(orch_task_file), "Delivering non-task message must not write local task stamp")
        res_orch_cur = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", f"{TEST_PREFIX}agent:{orchestrator}", "current_task"], capture_output=True, text=True)
        self.assertEqual(res_orch_cur.stdout.strip(), "", "Delivering non-task message must not set current_task in Redis")

        # 6. Bidirectional Alias Resolution
        alias_name = "alias-lead"
        target_name = "target-lead"
        self.run_cmd(["open", target_name, "orchestrator"])
        res_alias_set = self.run_cmd(["alias", "set", alias_name, target_name])
        self.assertEqual(res_alias_set.returncode, 0)

        # Send message to alias
        res_alias_send = self.run_cmd(["send", "--to", alias_name, "--from", worker, "--subject", "Hello Alias", "--body", "Content"])
        self.assertEqual(res_alias_send.returncode, 0)

        # Check inbox on alias resolves to target
        res_chk_alias = self.run_cmd(["check-inbox", alias_name])
        self.assertEqual(res_chk_alias.returncode, 0)
        self.assertEqual(res_chk_alias.stdout.strip(), "1")

        # Drain from alias resolves to target
        res_drain_alias = self.run_cmd(["drain", "1", alias_name])
        self.assertEqual(res_drain_alias.returncode, 0)
        self.assertIn("Hello Alias", res_drain_alias.stdout)

        # Inboxes are now 0
        self.assertEqual(self.run_cmd(["check-inbox", alias_name]).stdout.strip(), "0")
        self.assertEqual(self.run_cmd(["check-inbox", target_name]).stdout.strip(), "0")

        # 7. Broadcast Announcement Isolation
        # When a broadcast message is popped by listen, it must NOT set current_task or BUSY state
        self.run_cmd(["open", "broadcast-recipient", "worker"])
        res_bcast = self.run_cmd(["broadcast", "--from", worker, "--subject", "Swarm Plan Complete: Deployed", "--body", "All tasks done"])
        self.assertEqual(res_bcast.returncode, 0)
        res_bcast_pop = self.run_cmd(["listen", "broadcast-recipient", "--timeout", "1"])
        self.assertEqual(res_bcast_pop.returncode, 0)
        # Recipient MUST NOT have current_task in Redis
        res_rcp_cur = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", f"{TEST_PREFIX}agent:broadcast-recipient", "current_task"], capture_output=True, text=True)
        self.assertEqual(res_rcp_cur.stdout.strip(), "", "Broadcast message must not set current_task in Redis")
        # Recipient status in who must be IDLE
        res_who_b = self.run_cmd(["who", "--json"])
        who_b_data = {a["agent"]: a for a in json.loads(res_who_b.stdout.strip())}
        self.assertEqual(who_b_data["broadcast-recipient"]["state"].lower(), "idle")
        self.run_cmd(["close", "broadcast-recipient"])

        # Clean up
        self.run_cmd(["alias", "del", alias_name])
        self.run_cmd(["close", worker])
        self.run_cmd(["close", orchestrator])
        self.run_cmd(["close", target_name])

    # -------------------------------------------------------------------------
    # Problem 26: Cross-Project Isolation & Anti-Hijack Invariants
    # -------------------------------------------------------------------------
    def test_26_cross_project_isolation_and_anti_hijack_invariants(self):
        """Verify hermetic cross-project isolation, anti-hijack guards, scoped who/locks, and key migration."""
        proj_a = "alpha-system"
        proj_b = "beta-system"
        agent_a = "alpha-conductor"
        agent_b = "beta-worker"

        # 1. Register agent_a in proj_a
        res_open_a = self.run_cmd(["open", agent_a, "conductor"], env_overrides={"RHIZO_PROJECT": proj_a, "RHIZO_ALLOW_DRIFT": "1"})
        self.assertEqual(res_open_a.returncode, 0)
        self.assertIn("Registered Successfully", res_open_a.stdout)

        # Verify Redis has project set
        res_proj_get = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", f"{TEST_PREFIX}agent:{agent_a}", "project"], capture_output=True, text=True)
        self.assertEqual(res_proj_get.stdout.strip(), proj_a)

        # 2. Negative Control: proj_b session attempts to hijack agent_a without force-steal
        res_hijack = self.run_cmd(["open", agent_a, "worker"], env_overrides={"RHIZO_PROJECT": proj_b, "RHIZO_ALLOW_DRIFT": "1"})
        self.assertNotEqual(res_hijack.returncode, 0, "Cross-project hijack of active agent must be rejected")
        self.assertIn("Cross-project takeover denied", res_hijack.stderr)
        self.assertIn(proj_a, res_hijack.stderr)

        # 3. Positive Control: Override hijack with --force-steal
        res_steal = self.run_cmd(["open", agent_a, "worker", "--force-steal"], env_overrides={"RHIZO_PROJECT": proj_b, "RHIZO_ALLOW_DRIFT": "1"})
        self.assertEqual(res_steal.returncode, 0, "Cross-project takeover with --force-steal must succeed")
        res_stolen_proj = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", f"{TEST_PREFIX}agent:{agent_a}", "project"], capture_output=True, text=True)
        self.assertEqual(res_stolen_proj.stdout.strip(), proj_b)

        # Re-assign back to proj_a
        self.run_cmd(["open", agent_a, "conductor", "--force-steal"], env_overrides={"RHIZO_PROJECT": proj_a, "RHIZO_ALLOW_DRIFT": "1"})

        # 4. Cross-Project Inbox Drain & Check-Inbox Isolation
        # Send a message to agent_a
        self.run_cmd(["send", "--to", agent_a, "--from", "system", "--subject", "Confidential Task", "--body", "Secret payload"],
                     env_overrides={"RHIZO_PROJECT": proj_a, "RHIZO_ALLOW_DRIFT": "1"})

        # proj_b session attempts to check-inbox of agent_a
        res_chk_alien = self.run_cmd(["check-inbox", agent_a], env_overrides={"RHIZO_PROJECT": proj_b, "RHIZO_ALLOW_DRIFT": "1"})
        self.assertNotEqual(res_chk_alien.returncode, 0)
        self.assertIn("Check-inbox across projects denied", res_chk_alien.stderr)

        # proj_b session attempts to drain agent_a's inbox
        res_drain_alien = self.run_cmd(["drain", "10", agent_a], env_overrides={"RHIZO_PROJECT": proj_b, "RHIZO_ALLOW_DRIFT": "1"})
        self.assertNotEqual(res_drain_alien.returncode, 0)
        self.assertIn("Draining across projects denied", res_drain_alien.stderr)

        # proj_a session successfully drains its own inbox
        res_drain_own = self.run_cmd(["drain", "10", agent_a], env_overrides={"RHIZO_PROJECT": proj_a, "RHIZO_ALLOW_DRIFT": "1"})
        self.assertEqual(res_drain_own.returncode, 0)
        self.assertIn("Confidential Task", res_drain_own.stdout)

        # 5. Project-Scoped rhizo who Filtering
        self.run_cmd(["open", agent_b, "worker"], env_overrides={"RHIZO_PROJECT": proj_b, "RHIZO_ALLOW_DRIFT": "1"})

        # Unscoped / default who in proj_a MUST only see agent_a
        res_who_a = self.run_cmd(["who", "--json"], env_overrides={"RHIZO_PROJECT": proj_a, "RHIZO_ALLOW_DRIFT": "1"})
        self.assertEqual(res_who_a.returncode, 0)
        who_a_agents = [x["agent"] for x in json.loads(res_who_a.stdout.strip())]
        self.assertIn(agent_a, who_a_agents)
        self.assertNotIn(agent_b, who_a_agents, "Unscoped who in proj_a must not show proj_b agents")

        # Global who (-a / --all-projects) MUST see both
        res_who_all = self.run_cmd(["who", "-a", "--json"], env_overrides={"RHIZO_PROJECT": proj_a, "RHIZO_ALLOW_DRIFT": "1"})
        self.assertEqual(res_who_all.returncode, 0)
        who_all_agents = [x["agent"] for x in json.loads(res_who_all.stdout.strip())]
        self.assertIn(agent_a, who_all_agents)
        self.assertIn(agent_b, who_all_agents)

        # 6. Project-Scoped Distributed Locks
        # Acquire lock 'build' in proj_a
        res_lock_a = self.run_cmd(["lock", "build", "30", "--fencing"], env_overrides={"RHIZO_PROJECT": proj_a, "RHIZO_AGENT_NAME": agent_a, "RHIZO_ALLOW_DRIFT": "1"})
        self.assertEqual(res_lock_a.returncode, 0)
        self.assertIn("LOCKED alpha-system:build", res_lock_a.stdout)

        # Acquire lock 'build' in proj_b -> MUST SUCCEED because it is scoped to beta-system:build
        res_lock_b = self.run_cmd(["lock", "build", "30", "--fencing"], env_overrides={"RHIZO_PROJECT": proj_b, "RHIZO_AGENT_NAME": agent_b, "RHIZO_ALLOW_DRIFT": "1"})
        self.assertEqual(res_lock_b.returncode, 0)
        self.assertIn("LOCKED beta-system:build", res_lock_b.stdout)

        # Acquire lock 'build' in proj_a AGAIN -> MUST FAIL (already held)
        res_lock_a2 = self.run_cmd(["lock", "build", "30"], env_overrides={"RHIZO_PROJECT": proj_a, "RHIZO_AGENT_NAME": agent_a, "RHIZO_ALLOW_DRIFT": "1"})
        self.assertNotEqual(res_lock_a2.returncode, 0)
        self.assertIn("already held", res_lock_a2.stderr)

        # Clean up locks
        self.run_cmd(["unlock", "build"], env_overrides={"RHIZO_PROJECT": proj_a, "RHIZO_AGENT_NAME": agent_a, "RHIZO_ALLOW_DRIFT": "1"})
        self.run_cmd(["unlock", "build"], env_overrides={"RHIZO_PROJECT": proj_b, "RHIZO_AGENT_NAME": agent_b, "RHIZO_ALLOW_DRIFT": "1"})

        # 7. Project-Scoped Sweep
        # Expire heartbeat of agent_b in Redis
        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", f"{TEST_PREFIX}heartbeat:{agent_b}"], check=True)
        subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", f"{TEST_PREFIX}heartbeat:{agent_a}"], check=True)

        # Sweeping proj_a MUST only prune agent_a, leaving dead agent_b in proj_b untouched
        res_sweep_a = self.run_cmd(["sweep", "--raw"], env_overrides={"RHIZO_PROJECT": proj_a, "RHIZO_ALLOW_DRIFT": "1"})
        self.assertEqual(res_sweep_a.returncode, 0)
        self.assertIn("Pruned 1 dead agents", res_sweep_a.stdout)

        # Verify agent_b is STILL in active_agents set
        res_b_member = subprocess.run(["redis-cli", "-u", REDIS_URL, "SISMEMBER", f"{TEST_PREFIX}active_agents", agent_b], capture_output=True, text=True)
        self.assertEqual(res_b_member.stdout.strip(), "1", "Project-scoped sweep in proj_a must not prune proj_b agent")

        # Global sweep prunes agent_b
        res_sweep_all = self.run_cmd(["sweep", "--all-projects", "--raw"], env_overrides={"RHIZO_ALLOW_DRIFT": "1"})
        self.assertEqual(res_sweep_all.returncode, 0)
        self.assertIn("Pruned 1 dead agents", res_sweep_all.stdout)

        # 8. Key Migration Utility (rhizo migrate-keys)
        # Create a legacy untagged agent
        legacy_agent = "legacy-proj-worker"
        subprocess.run(["redis-cli", "-u", REDIS_URL, "SADD", f"{TEST_PREFIX}active_agents", legacy_agent], check=True)
        subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", f"{TEST_PREFIX}agent:{legacy_agent}", "state", "idle"], check=True)
        # Verify it has no project
        res_no_proj = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", f"{TEST_PREFIX}agent:{legacy_agent}", "project"], capture_output=True, text=True)
        self.assertEqual(res_no_proj.stdout.strip(), "")

        # Run migrate-keys for legacy-proj
        res_migrate = self.run_cmd(["migrate-keys", "--project", "legacy-proj"])
        self.assertEqual(res_migrate.returncode, 0)
        migrate_data = json.loads(res_migrate.stdout.strip())
        self.assertEqual(migrate_data["status"], "MIGRATION_COMPLETE")
        self.assertEqual(migrate_data["agents_tagged"], 1)

        # Verify agent now has project tagged
        res_tagged_proj = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", f"{TEST_PREFIX}agent:{legacy_agent}", "project"], capture_output=True, text=True)
        self.assertEqual(res_tagged_proj.stdout.strip(), "legacy-proj")

        # Clean up
        self.run_cmd(["close", agent_a], env_overrides={"RHIZO_PROJECT": proj_a, "RHIZO_ALLOW_DRIFT": "1"})
        self.run_cmd(["close", agent_b], env_overrides={"RHIZO_PROJECT": proj_b, "RHIZO_ALLOW_DRIFT": "1"})
        self.run_cmd(["close", legacy_agent], env_overrides={"RHIZO_PROJECT": "legacy-proj", "RHIZO_ALLOW_DRIFT": "1"})

    # -------------------------------------------------------------------------
    # Problem 27: PWD vs. Environment Variable Drift Guard
    # -------------------------------------------------------------------------
    def test_27_pwd_drift_guard_rejection(self):
        """Verify that PWD vs. Environment Variable Drift Guard aborts execution when RHIZO_PROJECT does not match directory."""
        repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
        res_mismatch = self.run_cmd(["name"], env_overrides={"RHIZO_PROJECT": "completely-alien-project"}, cwd=repo_root)
        self.assertNotEqual(res_mismatch.returncode, 0)
        self.assertIn("does not match active repository project", res_mismatch.stderr)
        self.assertIn("Aborting to prevent cross-project state corruption", res_mismatch.stderr)

        # With --allow-drift, it succeeds
        res_allowed = self.run_cmd(["name", "--allow-drift"], env_overrides={"RHIZO_PROJECT": "completely-alien-project"}, cwd=repo_root)
        self.assertEqual(res_allowed.returncode, 0)

    # -------------------------------------------------------------------------
    # Problem 28: Reminder Scope & Project Isolation
    # -------------------------------------------------------------------------
    def test_28_reminder_project_isolation(self):
        """Verify that scope: * reminders stay within their originating project and do not leak across projects."""
        proj_g = "gearmulator_test"
        proj_t = "telar_test"
        agent_g = f"g_worker_{int(time.time()*1000)}"
        agent_t = f"t_worker_{int(time.time()*1000)}"

        # 1. Register agents in different projects
        r_g = self.run_cmd(["open", agent_g, "worker"], env_overrides={"RHIZO_PROJECT": proj_g, "RHIZO_ALLOW_DRIFT": "1"})
        self.assertEqual(r_g.returncode, 0)
        r_t = self.run_cmd(["open", agent_t, "worker"], env_overrides={"RHIZO_PROJECT": proj_t, "RHIZO_ALLOW_DRIFT": "1"})
        self.assertEqual(r_t.returncode, 0)

        # 2. Add scoped reminder from gearmulator agent (scope: *)
        r_add_g = self.run_cmd(
            ["remind", "add", "Gearmulator internal alert", "--author", agent_g],
            env_overrides={"RHIZO_PROJECT": proj_g, "RHIZO_ALLOW_DRIFT": "1"}
        )
        self.assertEqual(r_add_g.returncode, 0)

        # 3. Add explicit global reminder
        r_add_glob = self.run_cmd(
            ["remind", "add", "Global cluster announcement", "--scope", "@global", "--author", "operator"],
            env_overrides={"RHIZO_PROJECT": proj_g, "RHIZO_ALLOW_DRIFT": "1"}
        )
        self.assertEqual(r_add_glob.returncode, 0)

        # 4. Check list for telar_agent: must NOT see gearmulator internal alert, but MUST see global announcement
        r_list_t = self.run_cmd(
            ["remind", "list", f"--for={agent_t}", "--json"],
            env_overrides={"RHIZO_PROJECT": proj_t, "RHIZO_ALLOW_DRIFT": "1"}
        )
        self.assertEqual(r_list_t.returncode, 0)
        t_data = json.loads(r_list_t.stdout.strip())
        t_texts = [rem["text"] for rem in t_data.get("reminders", [])]
        self.assertNotIn("Gearmulator internal alert", t_texts)
        self.assertIn("Global cluster announcement", t_texts)

        # 5. Check list for gearmulator_agent: MUST see both gearmulator internal alert and global announcement
        r_list_g = self.run_cmd(
            ["remind", "list", f"--for={agent_g}", "--json"],
            env_overrides={"RHIZO_PROJECT": proj_g, "RHIZO_ALLOW_DRIFT": "1"}
        )
        self.assertEqual(r_list_g.returncode, 0)
        g_data = json.loads(r_list_g.stdout.strip())
        g_texts = [rem["text"] for rem in g_data.get("reminders", [])]
        self.assertIn("Gearmulator internal alert", g_texts)
        self.assertIn("Global cluster announcement", g_texts)

        # Clean up
        self.run_cmd(["close", agent_g], env_overrides={"RHIZO_PROJECT": proj_g, "RHIZO_ALLOW_DRIFT": "1"})
        self.run_cmd(["close", agent_t], env_overrides={"RHIZO_PROJECT": proj_t, "RHIZO_ALLOW_DRIFT": "1"})

    # -------------------------------------------------------------------------
    # Problem 29: Swarm Roster Guard Socket/Bus Rejection
    # -------------------------------------------------------------------------
    def test_29_roster_guard_bus_alien_rejection(self):
        """Verify that rhizo listen --roster-guard drops alien messages and delivers authorized messages."""
        if shutil.which("garden") is None:
            self.skipTest("garden executable not installed or not in PATH")
        swarm_cfg = {
            "project": "coord_test",
            "orchestrator": {"name": "coord_test-lead", "agent": "coord_test-lead"},
            "workers": [{"name": "worker-guard-auth", "role": "implementer"}]
        }
        with open(os.path.join(self.test_home, "garden-swarm.json"), "w") as f:
            json.dump(swarm_cfg, f)

        worker = "worker-guard-auth"
        alien = "alien-infiltrator"
        orch = "coord_test-lead"

        self.run_cmd(["open", worker, "worker"])
        self.run_cmd(["open", alien, "alien"])
        self.run_cmd(["open", orch, "orchestrator"])

        # Start listener with --roster-guard in background
        proc = subprocess.Popen(
            [BIN_PATH, "listen", worker, "4", "--roster-guard"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env=self.env, cwd=self.test_home
        )
        time.sleep(0.3)

        # 1. Send from alien agent -> MUST BE DROPPED
        res_alien = self.run_cmd(
            ["send", "--to", worker, "--from", alien, "--subject", "Alien Attack", "--body", "Bad payload"]
        )
        self.assertEqual(res_alien.returncode, 0)
        time.sleep(0.3)

        # 2. Send from authorized orchestrator -> MUST BE DELIVERED
        res_legit = self.run_cmd(
            ["send", "--to", worker, "--from", orch, "--subject", "Authorized Directive", "--body", "Execute test"]
        )
        self.assertEqual(res_legit.returncode, 0)

        stdout, stderr = proc.communicate(timeout=5)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("Authorized Directive", stdout)
        self.assertIn("[RHIZO ROSTER GUARD] Dropping alien message", stderr)
        self.assertIn(alien, stderr)

        # Clean up
        self.run_cmd(["close", worker])
        self.run_cmd(["close", alien])
        self.run_cmd(["close", orch])

    # -------------------------------------------------------------------------
    # Problem 30: Intermediate Inquiry Lease Protection & Explicit Completion
    # -------------------------------------------------------------------------
    def test_30_intermediate_inquiry_lease_protection(self):
        """Verify that inquiries like 'Re: Is task done?' do not drop active leases, and explicit flags trigger completion."""
        worker = "worker-inquiry"
        orch = "orch-inquiry"
        self.run_cmd(["open", worker, "worker"])
        self.run_cmd(["open", orch, "orchestrator"])

        task_id = "task-inquiry-lease"
        self.run_cmd(["task", "create", task_id, "--title", "Lease Protection Task", "--target", worker])
        self.run_cmd(["task", "claim", task_id, "--worker", worker, "--no-vine"])

        # 1. Intermediate inquiry with 'done' in subject MUST NOT clear active task or drop lease
        res_inq1 = self.run_cmd([
            "reply", "--to", orch, "--from", worker,
            "--subject", "Re: Is task done?", "--body", "Still running benchmarks", "--skip-gate"
        ])
        self.assertEqual(res_inq1.returncode, 0)

        # Worker MUST still hold active in-flight lease
        res_who = self.run_cmd(["who", "--json"])
        who_map = {a["agent"]: a for a in json.loads(res_who.stdout.strip())}
        self.assertIn(f"busy ({task_id})", who_map[worker]["state"].lower())

        # 2. Intermediate inquiry with 'complete' in subject MUST NOT clear active task
        res_inq2 = self.run_cmd([
            "reply", "--to", orch, "--from", worker,
            "--subject", "Progress on complete refactor", "--body", "Writing tests", "--skip-gate"
        ])
        self.assertEqual(res_inq2.returncode, 0)
        res_who2 = self.run_cmd(["who", "--json"])
        who_map2 = {a["agent"]: a for a in json.loads(res_who2.stdout.strip())}
        self.assertIn(f"busy ({task_id})", who_map2[worker]["state"].lower())

        # 3. Explicit --status=complete flag triggers completion and transitions to IDLE
        res_comp = self.run_cmd([
            "reply", "--to", orch, "--from", worker,
            "--subject", "Refactor finished", "--body", "Tests green",
            "--status=complete", "--skip-gate"
        ])
        self.assertEqual(res_comp.returncode, 0)
        res_who3 = self.run_cmd(["who", "--json"])
        who_map3 = {a["agent"]: a for a in json.loads(res_who3.stdout.strip())}
        self.assertEqual(who_map3[worker]["state"].upper(), "IDLE")

        self.run_cmd(["close", worker])
        self.run_cmd(["close", orch])

    # -------------------------------------------------------------------------
    # Problem 31: Sweep Preserves In-Flight Worker Tasks
    # -------------------------------------------------------------------------
    def test_31_sweep_preserves_inflight_worker_tasks(self):
        """Verify that sweeping an expired DELIVERED task does not delete current_task of an active in-flight worker."""
        worker = "worker-sweep-safe"
        self.run_cmd(["open", worker, "worker"])

        # Claim active in-flight task
        active_task = "task-active-claimed"
        self.run_cmd(["task", "create", active_task, "--title", "Active Task", "--target", worker])
        self.run_cmd(["task", "claim", active_task, "--worker", worker, "--no-vine", "--lease", "3600"])

        # Create another task that was delivered but expired
        stale_delivered = "task-stale-delivered"
        self.run_cmd(["task", "create", stale_delivered, "--title", "Stale Delivery", "--target", worker])
        # Manually deliver and expire delivery_until
        subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", f"{TEST_PREFIX}task:{stale_delivered}",
                        "state", "DELIVERED", "owner", worker, "delivery_until", "1", "delivery_attempts", "1"], check=True)

        # Ensure current_task is set to the active task
        subprocess.run(["redis-cli", "-u", REDIS_URL, "SET", f"{TEST_PREFIX}current_task:{worker}", active_task], check=True)
        subprocess.run(["redis-cli", "-u", REDIS_URL, "SET", f"{TEST_PREFIX}agent_task:{worker}", active_task], check=True)

        # Advance virtual time and trigger sweep
        self.run_cmd(["time", "advance", "300"])
        res_sweep = self.run_cmd(["task", "sweep", "--json"])
        self.assertEqual(res_sweep.returncode, 0)

        # Stale task was swept to ORPHANED
        res_get_stale = self.run_cmd(["task", "get", stale_delivered, "--json"])
        self.assertEqual(json.loads(res_get_stale.stdout.strip())["state"], "ORPHANED")

        # Worker's active current_task MUST NOT have been deleted
        res_cur = subprocess.run(["redis-cli", "-u", REDIS_URL, "GET", f"{TEST_PREFIX}current_task:{worker}"], capture_output=True, text=True)
        self.assertEqual(res_cur.stdout.strip(), active_task, "Sweep of delivered task must not delete active worker's current_task")

        self.run_cmd(["close", worker])

    # -------------------------------------------------------------------------
    # Problem 32: doSend Links Canonical WISM Task ID
    # -------------------------------------------------------------------------
    def test_32_dosend_links_canonical_wism_task_id(self):
        """Verify that sending a task links directly to the canonical WISM task ID rather than creating transient msg_... records."""
        worker = "worker-canon-task"
        orch = "orch-canon-task"
        self.run_cmd(["open", worker, "worker"])
        self.run_cmd(["open", orch, "orchestrator"])

        canonical_tid = "task-real-canonical-99"
        self.run_cmd(["task", "create", canonical_tid, "--title", "Canonical Implementation", "--target", worker])

        # Send with explicit --task-id
        res_send = self.run_cmd([
            "send", "--to", worker, "--from", orch, "--type", "task",
            "--subject", f"Task Assignment: {canonical_tid}", "--body", "Implement core logic",
            "--task-id", canonical_tid
        ])
        self.assertEqual(res_send.returncode, 0)

        # Task in Redis MUST be in state DELIVERED with owner worker
        res_get = self.run_cmd(["task", "get", canonical_tid, "--json"])
        self.assertEqual(res_get.returncode, 0)
        t_data = json.loads(res_get.stdout.strip())
        self.assertEqual(t_data["state"], "DELIVERED")
        self.assertEqual(t_data["owner"], worker)

        # Worker's current_task MUST be the canonical task ID, not msg_...
        res_cur = subprocess.run(["redis-cli", "-u", REDIS_URL, "GET", f"{TEST_PREFIX}current_task:{worker}"], capture_output=True, text=True)
        self.assertEqual(res_cur.stdout.strip(), canonical_tid)

        # Verify no phantom msg_... tasks were created
        res_list = self.run_cmd(["task", "list", "--json"])
        tasks = json.loads(res_list.stdout.strip())
        msg_tasks = [t for t in tasks if t["id"].startswith("msg_")]
        self.assertEqual(len(msg_tasks), 0, "No transient msg_... task records should be created when canonical task ID is provided")

        self.run_cmd(["close", worker])
        self.run_cmd(["close", orch])

    # -------------------------------------------------------------------------
    # Problem 33: Directory-Scoped Identity Files & Default Worker Fallbacks Purged
    # -------------------------------------------------------------------------
    def test_33_purge_directory_session_identity(self):
        """Verify that directory .rhizo/session.json is ignored and unconfigured sessions fail loudly without defaulting to <dirname>-worker."""
        empty_dir = tempfile.mkdtemp(prefix="rhizo_dir_identity_")
        rhizo_subdir = os.path.join(empty_dir, ".rhizo")
        os.makedirs(rhizo_subdir, exist_ok=True)
        session_file = os.path.join(rhizo_subdir, "session.json")
        with open(session_file, "w") as f:
            json.dump({"agent": "rogue-directory-agent", "project": "rogue_proj"}, f)

        # Running without RHIZO_AGENT_NAME in this directory MUST fail loudly
        res_claim = self.run_cmd(
            ["task", "claim", "some-task-id", "--no-vine"],
            env_overrides={"RHIZO_AGENT_NAME": ""},
            cwd=empty_dir
        )
        self.assertNotEqual(res_claim.returncode, 0, "Unconfigured session must fail loudly without defaulting to dirname-worker or reading session.json")
        self.assertIn("Cannot determine worker name", res_claim.stderr)

        shutil.rmtree(empty_dir, ignore_errors=True)

    # -------------------------------------------------------------------------
    # Problem 34: Codex Listener Workflow Cases (Queued vs Consumed Messages)
    # -------------------------------------------------------------------------
    def test_34_codex_listener_workflow_cases(self):
        """Verify the exact 7-step Codex recipient workflow across two cases:
        Case A: Message remains queued in the inbox (no listener was active).
        Case B: Listener already consumed message and exited (inbox empty).
        In both cases, verify that the receiver processes the message and leaves exactly one listener waiting afterward.
        """
        codex_agent = f"codex_agent_{int(time.time() * 1000)}"
        sender_agent = f"sender_agent_{int(time.time() * 1000)}"
        project = "coord_test"

        # Register agents
        res_open = self.run_cmd(["open", codex_agent, "worker"])
        self.assertEqual(res_open.returncode, 0)
        res_open_sender = self.run_cmd(["open", sender_agent, "sender"])
        self.assertEqual(res_open_sender.returncode, 0)

        try:
            # =================================================================
            # Case A: Message remains queued in inbox (no listener active)
            # =================================================================
            # 1. Sender sends message to codex_agent
            res_send_a = self.run_cmd([
                "send", "--to", codex_agent, "--from", sender_agent,
                "--subject", "Task Case A", "--body", "Work from inbox queue"
            ])
            self.assertEqual(res_send_a.returncode, 0)

            # 2. Recipient executes 7-step workflow:
            # Step 1: No completed listener output.
            # Step 2: Drain and process remaining inbox.
            res_drain_a = self.run_cmd(["drain", "50", codex_agent, "--json"])
            self.assertEqual(res_drain_a.returncode, 0)
            msgs_a = json.loads(res_drain_a.stdout.strip())
            self.assertEqual(len(msgs_a), 1)
            self.assertEqual(msgs_a[0]["subject"], "Task Case A")

            # Process & acknowledge
            res_reply_a = self.run_cmd([
                "reply", "--to", sender_agent, "--from", codex_agent,
                "--subject", "Re: Task Case A", "--body", "Task A processed",
                "--reply-to", msgs_a[0]["id"]
            ])
            self.assertEqual(res_reply_a.returncode, 0)

            # Step 3: Refresh agent registration
            res_refresh_a = self.run_cmd(["open", codex_agent, "worker"])
            self.assertEqual(res_refresh_a.returncode, 0)

            # Step 4: Probe listener (none running)
            res_probe_a = self.run_cmd(["probe", codex_agent, "--json"])
            self.assertEqual(res_probe_a.returncode, 0)
            probe_data_a = json.loads(res_probe_a.stdout.strip())
            self.assertIn(probe_data_a["status"], ["NO_LISTENER", "DEAD"])

            # Step 5: Start one supervised foreground single-shot listener:
            # rhizo --project <project> listen <agent> --quiet
            listener_proc_a = subprocess.Popen(
                [BIN_PATH, "--project", project, "listen", codex_agent, "--quiet"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=self.env,
                cwd=self.test_home
            )
            time.sleep(0.3)

            # Step 6 & 7: Verify listener remains blocked waiting, with exactly ONE listener waiting afterward
            res_probe_live_a = self.run_cmd(["probe", codex_agent, "--json"])
            self.assertEqual(res_probe_live_a.returncode, 0)
            probe_live_data_a = json.loads(res_probe_live_a.stdout.strip())
            self.assertEqual(probe_live_data_a["status"], "HEALTHY")

            # Verify duplicate attempt is rejected
            res_dup_a = self.run_cmd(["listen", codex_agent, "1"])
            self.assertNotEqual(res_dup_a.returncode, 0)
            self.assertIn("Listener already active", res_dup_a.stderr)

            # Clean up Case A listener
            listener_proc_a.terminate()
            listener_proc_a.communicate()
            time.sleep(0.2)

            # =================================================================
            # Case B: Listener already consumed message and exited (inbox empty)
            # =================================================================
            # 1. Receiver has a listener running in background
            listener_proc_b = subprocess.Popen(
                [BIN_PATH, "--project", project, "listen", codex_agent, "--quiet"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=self.env,
                cwd=self.test_home
            )
            time.sleep(0.3)

            # 2. Sender dispatches message while listener is active
            res_send_b = self.run_cmd([
                "send", "--to", codex_agent, "--from", sender_agent,
                "--subject", "Task Case B", "--body", "Work consumed by listener"
            ])
            self.assertEqual(res_send_b.returncode, 0)

            # 3. Listener consumes message and exits with 0
            stdout_b, stderr_b = listener_proc_b.communicate(timeout=5)
            self.assertEqual(listener_proc_b.returncode, 0)

            # 4. Recipient executes 7-step workflow:
            # Step 1: Retrieve completed supervised listener output
            self.assertTrue(len(stdout_b.strip()) > 0)
            consumed_b = json.loads(stdout_b.strip())
            self.assertEqual(consumed_b["subject"], "Task Case B")

            # Step 2: Drain inbox - Crucial verification: inbox is EMPTY!
            res_drain_b = self.run_cmd(["drain", "50", codex_agent, "--json"])
            self.assertEqual(res_drain_b.returncode, 0)
            msgs_b = json.loads(res_drain_b.stdout.strip())
            self.assertEqual(len(msgs_b), 0, "Inbox must be empty because listener already consumed the message")

            # Process & acknowledge delivered message from listener output
            res_reply_b = self.run_cmd([
                "reply", "--to", sender_agent, "--from", codex_agent,
                "--subject", "Re: Task Case B", "--body", "Task B processed from listener output",
                "--reply-to", consumed_b["id"]
            ])
            self.assertEqual(res_reply_b.returncode, 0)

            # Step 3: Refresh agent registration
            res_refresh_b = self.run_cmd(["open", codex_agent, "worker"])
            self.assertEqual(res_refresh_b.returncode, 0)

            # Step 4: Probe listener (exited, so DEAD or NO_LISTENER)
            res_probe_b = self.run_cmd(["probe", codex_agent, "--json"])
            self.assertEqual(res_probe_b.returncode, 0)
            probe_data_b = json.loads(res_probe_b.stdout.strip())
            self.assertIn(probe_data_b["status"], ["NO_LISTENER", "DEAD"])

            # Step 5: Start one supervised foreground single-shot listener:
            # rhizo --project <project> listen <agent> --quiet
            listener_proc_b2 = subprocess.Popen(
                [BIN_PATH, "--project", project, "listen", codex_agent, "--quiet"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=self.env,
                cwd=self.test_home
            )
            time.sleep(0.3)

            # Step 6 & 7: Verify listener remains blocked waiting, with exactly ONE listener waiting afterward
            res_probe_live_b = self.run_cmd(["probe", codex_agent, "--json"])
            self.assertEqual(res_probe_live_b.returncode, 0)
            probe_live_data_b = json.loads(res_probe_live_b.stdout.strip())
            self.assertEqual(probe_live_data_b["status"], "HEALTHY")

            # Verify duplicate attempt is rejected
            res_dup_b = self.run_cmd(["listen", codex_agent, "1"])
            self.assertNotEqual(res_dup_b.returncode, 0)
            self.assertIn("Listener already active", res_dup_b.stderr)

            # Clean up Case B listener
            listener_proc_b2.terminate()
            listener_proc_b2.communicate()

        finally:
            self.run_cmd(["close", codex_agent])
            self.run_cmd(["close", sender_agent])

    # -------------------------------------------------------------------------
    # Problem 35: Target Agent Name Resolution & Active Listener Liveness in `rhizo who`
    # -------------------------------------------------------------------------
    def test_35_who_query_and_active_listener_liveness(self):
        """Verify that `rhizo who <agent>` resolves target across projects and active listeners are never STALE."""
        worker = "autopxd-architect-test"
        worker_proj = "python-autopxd2"

        # 1. Register worker in project python-autopxd2
        res_open = self.run_cmd(["open", worker, "architect", "--project", worker_proj])
        self.assertEqual(res_open.returncode, 0)

        try:
            # 2. Query from a different project (coord_test) with specific agent name
            res_who_specific = self.run_cmd(["who", worker, "--json"])
            self.assertEqual(res_who_specific.returncode, 0)
            data = json.loads(res_who_specific.stdout.strip())
            self.assertEqual(len(data), 1)
            self.assertEqual(data[0]["agent"], worker)
            self.assertEqual(data[0]["project"], worker_proj)
            self.assertEqual(data[0]["status"], "ACTIVE")

            # 3. Advance virtual time by 300s so heartbeat TTL (150s) elapses
            self.run_cmd(["time", "advance", "300"])

            # 4. Without a listener, it should now report STALE
            res_stale = self.run_cmd(["who", worker, "--json"])
            self.assertEqual(res_stale.returncode, 0)
            data_stale = json.loads(res_stale.stdout.strip())
            self.assertEqual(len(data_stale), 1)
            self.assertEqual(data_stale[0]["status"], "STALE")
            self.assertEqual(data_stale[0]["listener"], "NO_LISTENER")

            # 5. Start active listener process
            listener_proc = subprocess.Popen(
                [BIN_PATH, "--project", worker_proj, "listen", worker, "--quiet"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=self.env,
                cwd=self.test_home
            )
            time.sleep(0.3)

            try:
                # 6. With active listener, rhizo who MUST report ACTIVE and LISTENING even after 300s elapsed
                res_live = self.run_cmd(["who", worker, "--json"])
                self.assertEqual(res_live.returncode, 0)
                data_live = json.loads(res_live.stdout.strip())
                self.assertEqual(len(data_live), 1)
                self.assertEqual(data_live[0]["status"], "ACTIVE")
                self.assertEqual(data_live[0]["listener"], "LISTENING")

                # Also verify `rhizo who --all --json` includes the active listener as ACTIVE
                res_all = self.run_cmd(["who", "--all", "--json"])
                self.assertEqual(res_all.returncode, 0)
                data_all = json.loads(res_all.stdout.strip())
                match = next((a for a in data_all if a.get("agent") == worker), None)
                self.assertIsNotNone(match)
                self.assertEqual(match["status"], "ACTIVE")
                self.assertEqual(match["listener"], "LISTENING")
            finally:
                listener_proc.terminate()
                listener_proc.communicate()

        finally:
            self.run_cmd(["close", worker])

    def test_36_task_roadmap_and_garden_autosow(self):
        """Invariant: rhizo task creation and completion automatically sync with Garden's seed ledger."""
        import tempfile
        with tempfile.TemporaryDirectory() as temp_dir:
            # 1. Initialize .garden directory in temp project
            garden_dir = os.path.join(temp_dir, ".garden")
            seeds_dir = os.path.join(garden_dir, "seeds")
            os.makedirs(seeds_dir, exist_ok=True)

            task_id = "test-task-autosow-1"
            task_title = "Automated Task for Roadmap Sync"

            # 2. Run rhizo task create inside the project dir
            res_create = self.run_cmd(["task", "create", task_id, "--title", task_title], cwd=temp_dir)
            self.assertEqual(res_create.returncode, 0)

            # 3. Verify seed was auto-sown into .garden/seeds/
            seed_path = os.path.join(seeds_dir, f"{task_id}.toml")
            self.assertTrue(os.path.exists(seed_path), f"Seed {seed_path} should be auto-sown by rhizo task create")
            with open(seed_path, "r") as f:
                content = f.read()
            self.assertIn(task_id, content)
            self.assertIn("DISPATCHED", content)

            # 4. Verify rhizo roadmap or rhizo task roadmap works
            res_roadmap = self.run_cmd(["roadmap", "--json"], cwd=temp_dir)
            self.assertEqual(res_roadmap.returncode, 0)
            data = json.loads(res_roadmap.stdout.strip())
            self.assertIn("seasons", data)

            # 5. Claim and complete task
            worker = f"worker-roadmap-{int(time.time())}"
            self.run_cmd(["open", worker])
            try:
                res_claim = self.run_cmd(["task", "claim", task_id, "--worker", worker, "--no-vine"])
                self.assertEqual(res_claim.returncode, 0)

                res_comp = self.run_cmd(["task", "complete", task_id, "--worker", worker, "--skip-gate"], cwd=temp_dir)
                self.assertEqual(res_comp.returncode, 0)

                # 6. Verify seed was auto-harvested to WOVEN
                with open(seed_path, "r") as f:
                    updated_content = f.read()
                self.assertIn("status = \"WOVEN\"", updated_content)
            finally:
                self.run_cmd(["close", worker])

    def test_37_rhizo_reassign_swarm_directive(self):
        worker = f"worker-reassign-{int(time.time())}"
        self.run_cmd(["open", worker, "generic"])
        try:
            # 1. Dispatch reassign directive
            res = self.run_cmd([
                "reassign", worker,
                "--project", "dependanim",
                "--role", "architect",
                "--tags", "systems,semver",
                "--json"
            ])
            self.assertEqual(res.returncode, 0)
            data = json.loads(res.stdout.strip())
            self.assertEqual(data["status"], "DISPATCHED")
            self.assertEqual(data["project"], "dependanim")
            self.assertEqual(data["role"], "architect")
            self.assertIn("systems", data["tags"])

            # 2. Check worker inbox received the message
            res_drain = self.run_cmd(["drain", "1", worker, "--json"])
            self.assertEqual(res_drain.returncode, 0)
            msg = json.loads(res_drain.stdout.strip())
            self.assertIsInstance(msg, dict)
            self.assertEqual(msg["type"], "reassign")
            self.assertEqual(msg["subject"], "SWARM_REASSIGN")
            payload = json.loads(msg["body"])
            self.assertEqual(payload["project"], "dependanim")
            self.assertEqual(payload["role"], "architect")
            self.assertIn("systems", payload["tags"])
        finally:
            self.run_cmd(["close", worker])

    # -------------------------------------------------------------------------
    # Problem 38: Session-Specific Protocol Upgrade Notification & Compile-Time Diff
    # -------------------------------------------------------------------------
    def test_38_session_protocol_upgrade_notification(self):
        """Verify session-specific protocol upgrade notifications across Proactive Push,
        Reactive Pull fallback, compile-time changelog diff range slicing, and machine command exclusions.
        """
        w1 = f"worker-upg-1-{int(time.time() * 1000)}"
        w2 = f"worker-upg-2-{int(time.time() * 1000)}"
        self.run_cmd(["open", w1, "worker"])
        self.run_cmd(["open", w2, "worker"])

        try:
            # 1. Negative control: machine commands must NEVER advance last_version_notified
            # Reset watermarks and flush any pre-existing messages
            subprocess.run(["redis-cli", "-u", REDIS_URL, "HDEL", f"{TEST_PREFIX}agent:{w1}", "last_version_notified:rhizo", "last_version_notified_at:rhizo"], check=True)
            subprocess.run(["redis-cli", "-u", REDIS_URL, "HDEL", f"{TEST_PREFIX}agent:{w2}", "last_version_notified:rhizo", "last_version_notified_at:rhizo"], check=True)
            subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", f"{TEST_PREFIX}inbox:{w1}", f"{TEST_PREFIX}inbox:{w2}"], check=True)

            res_ver = self.run_cmd(["--version"])
            self.assertEqual(res_ver.returncode, 0)
            res_help = self.run_cmd(["--help"])
            self.assertEqual(res_help.returncode, 0)
            res_ping = self.run_cmd(["ping"])
            self.assertEqual(res_ping.returncode, 0)
            res_who_json = self.run_cmd(["who", "--json"])
            self.assertEqual(res_who_json.returncode, 0)

            # Verify neither worker has last_version_notified set
            v1_check = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", f"{TEST_PREFIX}agent:{w1}", "last_version_notified:rhizo"], capture_output=True, text=True)
            self.assertEqual(v1_check.stdout.strip(), "", "Machine commands (--version, --help, ping, --json) must not advance last_version_notified")

            # 2. Proactive Push: Trigger cluster notification scan
            # Running a non-machine command (e.g. who without --json) scans active agents and pushes directives
            res_who = self.run_cmd(["who"])
            self.assertEqual(res_who.returncode, 0)

            # Both w1 and w2 should have their watermark updated in Redis to current version
            v1_notified = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", f"{TEST_PREFIX}agent:{w1}", "last_version_notified:rhizo"], capture_output=True, text=True).stdout.strip()
            v2_notified = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", f"{TEST_PREFIX}agent:{w2}", "last_version_notified:rhizo"], capture_output=True, text=True).stdout.strip()
            self.assertEqual(v1_notified, "0.2.25")
            self.assertEqual(v2_notified, "0.2.25")

            # Verify inbox message payload for w1
            res_drain_1 = self.run_cmd(["drain", "1", w1, "--json"])
            self.assertEqual(res_drain_1.returncode, 0)
            msg1 = json.loads(res_drain_1.stdout.strip())
            self.assertEqual(msg1["from"], "system:upgrade")
            self.assertEqual(msg1["type"], "directive")
            self.assertIn("PROTOCOL_UPGRADE", msg1["subject"])
            self.assertIn("0.2.25", msg1["subject"])
            self.assertIn("[RHIZO PROTOCOL UPGRADE DIRECTIVE]", msg1["body"])
            self.assertIn("Mandatory Actions", msg1["body"])
            self.assertIn("file://~/.gemini/config/skills/rhizo/SKILL.md", msg1["body"])

            # 3. Multi-Session Verification: Already notified sessions do NOT get re-notified
            # Running who again shouldn't push new directives to w1 or w2
            res_who2 = self.run_cmd(["who"])
            self.assertEqual(res_who2.returncode, 0)
            res_drain_empty = self.run_cmd(["drain", "1", w1, "--json"])
            self.assertEqual(res_drain_empty.returncode, 0)
            self.assertEqual(res_drain_empty.stdout.strip(), "")

            # 4. Multi-Version Jump Changelog Diff:
            # Set w1's watermark back to 0.2.22 and remove messages
            subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", f"{TEST_PREFIX}agent:{w1}", "last_version_notified:rhizo", "0.2.22"], check=True)
            res_who3 = self.run_cmd(["who"])
            self.assertEqual(res_who3.returncode, 0)

            res_drain_jump = self.run_cmd(["drain", "1", w1, "--json"])
            self.assertEqual(res_drain_jump.returncode, 0)
            msg_jump = json.loads(res_drain_jump.stdout.strip())
            self.assertIn("0.2.22 -> 0.2.25", msg_jump["subject"])
            # Cumulative diff must include 0.2.25, 0.2.24, and 0.2.23
            self.assertIn("0.2.25", msg_jump["body"])
            self.assertIn("0.2.24", msg_jump["body"])
            self.assertIn("0.2.23", msg_jump["body"])

            # 5. Reactive Pull Fallback: Interactive command outputs rider to stderr
            w3 = f"worker-upg-pull-{int(time.time() * 1000)}"
            self.run_cmd(["open", w3, "worker"])
            # Manually set w3's watermark to 0.2.24 and flush its inbox
            subprocess.run(["redis-cli", "-u", REDIS_URL, "HSET", f"{TEST_PREFIX}agent:{w3}", "last_version_notified:rhizo", "0.2.24"], check=True)
            subprocess.run(["redis-cli", "-u", REDIS_URL, "DEL", f"{TEST_PREFIX}inbox:{w3}"], check=True)

            # w3 sends an interactive message
            res_send = self.run_cmd(
                ["send", "--to", w1, "--subject", "Hello", "--body", "Testing pull rider"],
                env_overrides={"RHIZO_AGENT_NAME": w3}
            )
            self.assertEqual(res_send.returncode, 0)
            self.assertIn("<!-- RHIZO_PROTOCOL_UPGRADE_RIDER -->", res_send.stderr)
            self.assertIn("[RHIZO PROTOCOL UPGRADE DIRECTIVE]", res_send.stderr)
            self.assertIn("<!-- END_RHIZO_PROTOCOL_UPGRADE_RIDER -->", res_send.stderr)

            # Watermark in Redis must now be updated to 0.2.25
            v3_notified = subprocess.run(["redis-cli", "-u", REDIS_URL, "HGET", f"{TEST_PREFIX}agent:{w3}", "last_version_notified:rhizo"], capture_output=True, text=True).stdout.strip()
            self.assertEqual(v3_notified, "0.2.25")

            # Second interactive command must NOT emit rider again
            res_send_again = self.run_cmd(
                ["send", "--to", w1, "--subject", "Hello again", "--body", "Testing no duplicate rider"],
                env_overrides={"RHIZO_AGENT_NAME": w3}
            )
            self.assertEqual(res_send_again.returncode, 0)
            self.assertNotIn("<!-- RHIZO_PROTOCOL_UPGRADE_RIDER -->", res_send_again.stderr)

            self.run_cmd(["close", w3])

        finally:
            self.run_cmd(["close", w1])
            self.run_cmd(["close", w2])


if __name__ == "__main__":
    unittest.main()


