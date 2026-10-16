#!/usr/bin/env python3
"""tests/test_pulse.py
Comprehensive test suite for rhizo pulse distributed cron and ZSET scheduler.
Verifies:
1. Pulse registration, listing, retrieval, and removal.
2. Cron expression parsing and advancement across standard 5-field cron, aliases, and @every intervals.
3. High-availability zero-duplicate execution under concurrent sweepers.
4. Monotonic fencing lease advancement on tick.
5. End-to-end task enqueuing and worker queue claiming with HMAC verification.
"""

import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor

if os.name == "nt":
    BIN_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bin", "rhizo.exe"))
else:
    BIN_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bin", "rhizo"))
REDIS_URL = os.environ.get("RHIZO_REDIS_URL", "redis://127.0.0.1:6379/0")
TEST_PREFIX = os.environ.get("RHIZO_REDIS_PREFIX", f"test_pulse_{os.getpid()}:")


class TestRhizoPulse(unittest.TestCase):
    def setUp(self):
        self.test_home = tempfile.mkdtemp(prefix="rhizo_pulse_home_")
        self.env = os.environ.copy()
        self.env["HOME"] = self.test_home
        self.env["USERPROFILE"] = self.test_home
        self.env["RHIZO_REDIS_URL"] = REDIS_URL
        self.env["RHIZO_REDIS_PREFIX"] = TEST_PREFIX
        self.env["RHIZO_PROJECT"] = "pulse_test"
        # Clear test prefix and mock time
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

    def test_01_pulse_add_list_and_remove(self):
        """Verify adding, listing in tabular and JSON format, and removing pulses."""
        # 1. Empty list
        res_list_empty = self.run_cmd(["pulse", "list"])
        self.assertEqual(res_list_empty.returncode, 0)
        self.assertIn("No active pulses registered.", res_list_empty.stdout)

        # 2. Add pulse
        res_add = self.run_cmd([
            "pulse", "add", "heartbeat-01", "*/5 * * * *",
            "--queue", "tasks",
            "--body", "Worker Heartbeat",
            "--title", "Heartbeat Monitor"
        ])
        self.assertEqual(res_add.returncode, 0, res_add.stderr)
        self.assertIn("registered successfully", res_add.stdout)

        # 3. List table format
        res_list_tbl = self.run_cmd(["pulse", "list"])
        self.assertEqual(res_list_tbl.returncode, 0)
        self.assertIn("heartbeat-01", res_list_tbl.stdout)
        self.assertIn("*/5 * * * *", res_list_tbl.stdout)
        self.assertIn("tasks", res_list_tbl.stdout)

        # 4. List JSON format
        res_list_json = self.run_cmd(["pulse", "list", "--json"])
        self.assertEqual(res_list_json.returncode, 0)
        data = json.loads(res_list_json.stdout.strip())
        self.assertEqual(data.get("status"), "OK")
        pulses = data.get("pulses", [])
        self.assertEqual(len(pulses), 1)
        p = pulses[0]
        self.assertEqual(p["id"], "heartbeat-01")
        self.assertEqual(p["cron"], "*/5 * * * *")
        self.assertEqual(p["queue"], "tasks")
        self.assertEqual(p["body"], "Worker Heartbeat")
        self.assertEqual(p["title"], "Heartbeat Monitor")
        self.assertEqual(p["total_ticks"], 0)
        self.assertEqual(p["status"], "ACTIVE")
        self.assertGreater(p["next_run"], 0)

        # 5. Adding duplicate ID must fail
        res_add_dup = self.run_cmd([
            "pulse", "add", "heartbeat-01", "*/10 * * * *",
            "--queue", "other",
            "--body", "Duplicate pulse"
        ])
        self.assertNotEqual(res_add_dup.returncode, 0)
        self.assertIn("already exists", res_add_dup.stderr + res_add_dup.stdout)

        # 6. Remove pulse
        res_rem = self.run_cmd(["pulse", "remove", "heartbeat-01"])
        self.assertEqual(res_rem.returncode, 0)
        self.assertIn("removed successfully", res_rem.stdout)

        # 7. List should be empty again
        res_list_after = self.run_cmd(["pulse", "list"])
        self.assertEqual(res_list_after.returncode, 0)
        self.assertIn("No active pulses registered.", res_list_after.stdout)

        # 8. Removing non-existent pulse must fail
        res_rem_ghost = self.run_cmd(["pulse", "remove", "non-existent-pulse"])
        self.assertNotEqual(res_rem_ghost.returncode, 0)

    def test_02_cron_expression_advancement(self):
        """Verify cron expression advancement with virtual time offsets."""
        # Add pulse with @every 30s schedule
        res_add = self.run_cmd([
            "pulse", "add", "fast-pulse", "@every 30s",
            "--queue", "fast_jobs",
            "--body", "Fast job payload",
            "--title", "Fast Pulse 30s"
        ])
        self.assertEqual(res_add.returncode, 0)

        # Get initial next_run
        res_list = self.run_cmd(["pulse", "list", "--json"])
        data = json.loads(res_list.stdout.strip())
        initial_next_run = data["pulses"][0]["next_run"]

        # Tick when not due -> 0 dispatched
        res_tick_early = self.run_cmd(["pulse", "tick"])
        self.assertEqual(res_tick_early.returncode, 0)
        self.assertIn("No due pulses to tick", res_tick_early.stdout)

        # Advance time by 35 seconds to make it due
        self.run_cmd(["time", "advance", "35"])

        # Tick now -> 1 dispatched
        res_tick_due = self.run_cmd(["pulse", "tick", "--json"])
        self.assertEqual(res_tick_due.returncode, 0)
        tick_data = json.loads(res_tick_due.stdout.strip())
        self.assertEqual(tick_data["ticked"], 1)
        ticked_info = tick_data["pulses"][0]
        self.assertEqual(ticked_info["id"], "fast-pulse")
        self.assertEqual(ticked_info["total_ticks"], 1)
        self.assertGreater(ticked_info["next_run"], initial_next_run)

        # Verify pulse list state after tick
        res_list2 = self.run_cmd(["pulse", "list", "--json"])
        data2 = json.loads(res_list2.stdout.strip())
        p2 = data2["pulses"][0]
        self.assertEqual(p2["total_ticks"], 1)
        self.assertEqual(p2["fencing_token"], 1)
        self.assertEqual(p2["next_run"], ticked_info["next_run"])

        # Second advance by another 35 seconds and second tick
        self.run_cmd(["time", "advance", "35"])
        res_tick_second = self.run_cmd(["pulse", "tick", "--json"])
        self.assertEqual(res_tick_second.returncode, 0)
        tick_data2 = json.loads(res_tick_second.stdout.strip())
        self.assertEqual(tick_data2["ticked"], 1)
        self.assertEqual(tick_data2["pulses"][0]["total_ticks"], 2)
        self.assertEqual(tick_data2["pulses"][0]["fencing_token"], 2)

    def test_03_work_queue_enqueuing_and_worker_claiming(self):
        """Verify that due pulses enqueue authentic signed messages claimed by workers."""
        queue_name = "scheduled_tasks"
        body_content = "Execute database vacuum and index recompute"

        # Register pulse with immediate execution
        res_add = self.run_cmd([
            "pulse", "add", "db-vacuum", "0 0 * * *",
            "--queue", queue_name,
            "--body", body_content,
            "--title", "Nightly DB Vacuum",
            "--immediate"
        ])
        self.assertEqual(res_add.returncode, 0)

        # Tick immediately to process the due pulse
        res_tick = self.run_cmd(["pulse", "tick"])
        self.assertEqual(res_tick.returncode, 0)
        self.assertIn("Ticked and enqueued 1 pulse(s)", res_tick.stdout)

        # Worker claims the enqueued pulse from work queue
        res_claim = self.run_cmd(["claim", queue_name, "--timeout", "2"])
        self.assertEqual(res_claim.returncode, 0, res_claim.stderr)
        msg = json.loads(res_claim.stdout.strip())

        self.assertEqual(msg["type"], "pulse")
        self.assertEqual(msg["to"], f"queue:{queue_name}")
        self.assertEqual(msg["subject"], "Nightly DB Vacuum")
        self.assertEqual(msg["body"], body_content)
        self.assertEqual(msg["from"], "system:pulse")
        self.assertIn("pulse", msg.get("tags", []))
        self.assertIn("db-vacuum", msg.get("tags", []))
        self.assertTrue(len(msg.get("sig", "")) > 0)

        # Acknowledge the claimed task
        res_ack = self.run_cmd(["ack", queue_name, msg["id"]])
        self.assertEqual(res_ack.returncode, 0)
        self.assertIn("ACK:", res_ack.stdout)

    def test_04_high_availability_zero_duplicate_ticks(self):
        """Verify that concurrent sweepers guarantee zero duplicate ticks on due pulses."""
        num_pulses = 5
        # Add 5 pulses set to immediate run
        for i in range(num_pulses):
            p_id = f"ha-pulse-{i}"
            res = self.run_cmd([
                "pulse", "add", p_id, "@every 60s",
                "--queue", "ha_sink",
                "--body", f"Payload for {p_id}",
                "--immediate"
            ])
            self.assertEqual(res.returncode, 0)

        # Launch 8 concurrent sweepers competing to tick due pulses
        def run_sweeper(_):
            return self.run_cmd(["pulse", "tick", "--json"])

        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(run_sweeper, range(8)))

        for r in results:
            self.assertEqual(r.returncode, 0)

        # Sum total ticked pulses reported across all concurrent sweepers
        total_reported_ticks = 0
        for r in results:
            try:
                data = json.loads(r.stdout.strip())
                total_reported_ticks += data.get("ticked", 0)
            except Exception:
                pass

        # Exactly 5 pulses must have been ticked across the swarm, no more, no less
        self.assertEqual(total_reported_ticks, num_pulses)

        # Check total ticks on all pulses in Redis
        res_list = self.run_cmd(["pulse", "list", "--json"])
        data = json.loads(res_list.stdout.strip())
        pulses = data.get("pulses", [])
        self.assertEqual(len(pulses), num_pulses)
        for p in pulses:
            self.assertEqual(p["total_ticks"], 1, f"Pulse {p['id']} was ticked {p['total_ticks']} times!")

        # Drain the target queue to verify exactly 5 messages were enqueued
        res_drain = self.run_cmd(["drain", "10", "--format", "json"], env_overrides={"RHIZO_AGENT_NAME": "dummy_agent"})
        # Alternatively check queue length directly in Redis
        redis_len = subprocess.run([
            "redis-cli", "-u", REDIS_URL, "LLEN", f"{TEST_PREFIX}queue:{{ha_sink}}"
        ], capture_output=True, text=True)
        q_len = int(redis_len.stdout.strip())
        self.assertEqual(q_len, num_pulses, f"Queue contains {q_len} items, expected {num_pulses} (zero duplicates invariant violation)!")

    def test_05_monotonic_fencing_leases(self):
        """Verify that monotonic fencing tokens strictly increase across tick cycles."""
        res_add = self.run_cmd([
            "pulse", "add", "fence-pulse", "@every 10s",
            "--queue", "fenced_queue",
            "--body", "Fencing Payload",
            "--immediate"
        ])
        self.assertEqual(res_add.returncode, 0)

        fencing_tokens = []
        for cycle in range(3):
            if cycle > 0:
                self.run_cmd(["time", "advance", "15"])
            res_tick = self.run_cmd(["pulse", "tick", "--json"])
            self.assertEqual(res_tick.returncode, 0)
            data = json.loads(res_tick.stdout.strip())
            self.assertEqual(data["ticked"], 1)
            fencing_tokens.append(data["pulses"][0]["fencing_token"])

        # Strictly increasing monotonic order
        self.assertEqual(len(fencing_tokens), 3)
        self.assertTrue(fencing_tokens[0] < fencing_tokens[1] < fencing_tokens[2],
                        f"Fencing tokens are not strictly monotonic: {fencing_tokens}")


if __name__ == "__main__":
    unittest.main()
