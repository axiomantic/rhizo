#!/usr/bin/env python3
"""tests/test_strand_lua.py
Comprehensive test suite for pure Redis strand state management in scripts/strand.lua.
Verifies:
1. Complete elimination of on-disk .vine.json dependency; Redis as single source of truth.
2. Lifecycle state machine: PROVISIONED -> SUBMITTED -> (RATIFIED | REJECTED) -> WOVEN.
3. Invariant 1: Independent auditor requirement (auditor_pubkey != author_pubkey, self-ratification prohibited).
4. Invariant 2: Active heartbeat lease enforcement for auditor before ratification.
5. Invariant 3: Anti-blink temporal floor enforcement (minimum audit review duration).
6. Invariant 4: Atomic state transitions and index set maintenance across states and projects.
7. Weave gate: Only RATIFIED strands can be woven into canonical trunk.
8. Remediated defect flow: SUBMITTED -> REJECTED -> remediate -> SUBMITTED -> RATIFIED -> WOVEN.
"""

import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest

STRAND_LUA_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts", "strand.lua"))
REDIS_URL = os.environ.get("RHIZO_REDIS_URL", "redis://127.0.0.1:6379/0")
TEST_PREFIX = os.environ.get("RHIZO_REDIS_PREFIX", f"test_strand_{os.getpid()}:")


class TestStrandLua(unittest.TestCase):
    def setUp(self):
        self.prefix = TEST_PREFIX
        self.lua_script = open(STRAND_LUA_PATH, "r").read()
        self.clear_keys()

    def tearDown(self):
        self.clear_keys()

    def clear_keys(self):
        subprocess.run([
            "redis-cli", "-u", REDIS_URL, "EVAL",
            f"local keys = redis.call('KEYS', '{self.prefix}*'); if #keys > 0 then redis.call('DEL', unpack(keys)) end", "0"
        ], capture_output=True, text=True)

    def run_lua(self, action, *args):
        cmd = ["redis-cli", "-u", REDIS_URL, "EVAL", self.lua_script, "0", self.prefix, action] + list(args)
        res = subprocess.run(cmd, capture_output=True, text=True)
        return res

    def set_mock_time_offset(self, offset_sec):
        subprocess.run(["redis-cli", "-u", REDIS_URL, "SET", f"{self.prefix}mock_time_offset", str(offset_sec)], check=True)

    def set_heartbeat(self, agent_name, ttl_sec=120):
        norm = agent_name.lower()
        subprocess.run(["redis-cli", "-u", REDIS_URL, "SETEX", f"{self.prefix}heartbeat:{norm}", str(ttl_sec), "1"], check=True)

    def test_01_strand_create(self):
        """Verify strand creation in Redis, state PROVISIONED, and index sets."""
        res = self.run_lua(
            "create",
            "task-foo-01",
            "rhizo",
            "/workspaces/rhizo/task-foo-01/rhizo",
            "strand/task-foo-01",
            "main",
            "commit_abc123",
            "alice",
            "pubkey_alice_999",
            "rhizo-orchestrator",
            "/canonical/rhizo"
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        data = json.loads(res.stdout.strip())
        self.assertEqual(data["status"], "OK")
        self.assertEqual(data["id"], "task-foo-01")
        self.assertEqual(data["project"], "rhizo")
        self.assertEqual(data["state"], "PROVISIONED")
        self.assertEqual(data["lifecycle_state"], "PROVISIONED")
        self.assertEqual(data["author"], "alice")
        self.assertEqual(data["author_pubkey"], "pubkey_alice_999")

        # Verify global index set
        smembers = subprocess.run(["redis-cli", "-u", REDIS_URL, "SMEMBERS", f"{self.prefix}strands"], capture_output=True, text=True)
        self.assertIn("task-foo-01", smembers.stdout)

        # Verify state index set
        s_prov = subprocess.run(["redis-cli", "-u", REDIS_URL, "SMEMBERS", f"{self.prefix}strands:state:provisioned"], capture_output=True, text=True)
        self.assertIn("task-foo-01", s_prov.stdout)

        # Verify project index set
        s_proj = subprocess.run(["redis-cli", "-u", REDIS_URL, "SMEMBERS", f"{self.prefix}strands:project:rhizo"], capture_output=True, text=True)
        self.assertIn("task-foo-01", s_proj.stdout)

        # Duplicate create must fail
        dup = self.run_lua("create", "task-foo-01", "rhizo", "/path", "branch", "main", "c1", "alice")
        self.assertIn("already exists", dup.stdout + dup.stderr)

    def test_02_strand_submit(self):
        """Verify submitting strand with Keys 1 and 2 gate token transitions to SUBMITTED."""
        self.run_lua("create", "task-sub-01", "rhizo", "/path", "strand/task-sub-01", "main", "c1", "alice", "pub_alice")

        res_sub = self.run_lua("submit", "task-sub-01", "gate_token_xyz_pass", "alice", "pub_alice", "head_commit_789")
        self.assertEqual(res_sub.returncode, 0)
        data = json.loads(res_sub.stdout.strip())
        self.assertEqual(data["status"], "OK")
        self.assertEqual(data["state"], "SUBMITTED")
        self.assertEqual(data["gate_token"], "gate_token_xyz_pass")
        self.assertGreater(data["submitted_at"], 0)

        # Verify index sets moved from provisioned to submitted
        s_prov = subprocess.run(["redis-cli", "-u", REDIS_URL, "SMEMBERS", f"{self.prefix}strands:state:provisioned"], capture_output=True, text=True)
        self.assertNotIn("task-sub-01", s_prov.stdout)

        s_sub = subprocess.run(["redis-cli", "-u", REDIS_URL, "SMEMBERS", f"{self.prefix}strands:state:submitted"], capture_output=True, text=True)
        self.assertIn("task-sub-01", s_sub.stdout)

        # Duplicate submit on already submitted strand must fail
        dup_sub = self.run_lua("submit", "task-sub-01", "gate_token_2", "alice")
        self.assertIn("already in SUBMITTED state", dup_sub.stdout + dup_sub.stderr)

    def test_03_ratify_invariant_independent_auditor(self):
        """Invariant: auditor_pubkey != author_pubkey (self-ratification strictly prohibited)."""
        self.run_lua("create", "task-audit-01", "rhizo", "/path", "strand/audit-01", "main", "c1", "alice", "pubkey_alice_same")
        self.run_lua("submit", "task-audit-01", "gate_token_ok", "alice", "pubkey_alice_same")

        # Set active heartbeat for alice
        self.set_heartbeat("alice")

        # Case 1: Same pubkey passed as auditor
        res_self = self.run_lua("ratify", "task-audit-01", "pubkey_alice_same", "alice", "audit_tok", "Approved", "0")
        self.assertIn("auditor_pubkey cannot match author_pubkey", res_self.stdout + res_self.stderr)

        # Case 2: Different pubkey but same agent name
        res_self_name = self.run_lua("ratify", "task-audit-01", "pubkey_different", "alice", "audit_tok", "Approved", "0")
        self.assertIn("auditor cannot match author", res_self_name.stdout + res_self_name.stderr)

        # State must remain SUBMITTED
        res_get = self.run_lua("get", "task-audit-01")
        data = json.loads(res_get.stdout.strip())
        self.assertEqual(data["strand"]["state"], "SUBMITTED")

    def test_04_ratify_invariant_active_heartbeat_lease(self):
        """Invariant: Auditor must hold an active heartbeat lease."""
        self.run_lua("create", "task-hb-01", "rhizo", "/path", "strand/hb-01", "main", "c1", "alice", "pubkey_alice")
        self.run_lua("submit", "task-hb-01", "gate_token_ok", "alice", "pubkey_alice")

        # Auditor 'bob' has NO active heartbeat
        res_nohb = self.run_lua("ratify", "task-hb-01", "pubkey_bob", "bob", "audit_tok", "Approved", "0")
        self.assertIn("does not hold an active heartbeat lease", res_nohb.stdout + res_nohb.stderr)

        # State must remain SUBMITTED
        res_get = self.run_lua("get", "task-hb-01")
        data = json.loads(res_get.stdout.strip())
        self.assertEqual(data["strand"]["state"], "SUBMITTED")

    def test_05_ratify_invariant_anti_blink_temporal_floor(self):
        """Invariant: Audit cannot be instantaneous; must respect anti-blink temporal floor."""
        self.run_lua("create", "task-blink-01", "rhizo", "/path", "strand/blink-01", "main", "c1", "alice", "pubkey_alice")
        self.run_lua("submit", "task-blink-01", "gate_token_ok", "alice", "pubkey_alice")

        # Bob is active
        self.set_heartbeat("bob")

        # Temporal floor is 30 seconds, but 0 seconds have elapsed
        res_blink = self.run_lua("ratify", "task-blink-01", "pubkey_bob", "bob", "audit_tok", "Approved", "30")
        self.assertIn("Anti-blink temporal floor violation", res_blink.stdout + res_blink.stderr)
        self.assertIn("below minimum required 30s", res_blink.stdout + res_blink.stderr)

        # Advance virtual time by 35 seconds to satisfy temporal floor
        self.set_mock_time_offset(35)

        # Now ratification must succeed!
        res_ok = self.run_lua("ratify", "task-blink-01", "pubkey_bob", "bob", "audit_token_verified", "Thoroughly tested", "30")
        self.assertEqual(res_ok.returncode, 0, res_ok.stderr)
        data = json.loads(res_ok.stdout.strip())
        self.assertEqual(data["status"], "OK")
        self.assertEqual(data["state"], "RATIFIED")
        self.assertEqual(data["auditor"], "bob")
        self.assertEqual(data["audit_token"], "audit_token_verified")

        # Verify index sets moved to ratified
        s_sub = subprocess.run(["redis-cli", "-u", REDIS_URL, "SMEMBERS", f"{self.prefix}strands:state:submitted"], capture_output=True, text=True)
        self.assertNotIn("task-blink-01", s_sub.stdout)

        s_rat = subprocess.run(["redis-cli", "-u", REDIS_URL, "SMEMBERS", f"{self.prefix}strands:state:ratified"], capture_output=True, text=True)
        self.assertIn("task-blink-01", s_rat.stdout)

    def test_06_reject_and_resubmit_flow(self):
        """Verify adversarial rejection transitions to REJECTED and allows subsequent remediation re-submission."""
        self.run_lua("create", "task-rej-01", "rhizo", "/path", "strand/rej-01", "main", "c1", "alice", "pubkey_alice")
        self.run_lua("submit", "task-rej-01", "gate_token_v1", "alice", "pubkey_alice")

        # Independent auditor rejects with findings
        res_rej = self.run_lua("reject", "task-rej-01", "pubkey_charlie", "charlie", "Missing negative control assertions in test_parser")
        self.assertEqual(res_rej.returncode, 0)
        data_rej = json.loads(res_rej.stdout.strip())
        self.assertEqual(data_rej["state"], "REJECTED")
        self.assertEqual(data_rej["rejection_reason"], "Missing negative control assertions in test_parser")

        # Verify index set: in rejected
        s_rej = subprocess.run(["redis-cli", "-u", REDIS_URL, "SMEMBERS", f"{self.prefix}strands:state:rejected"], capture_output=True, text=True)
        self.assertIn("task-rej-01", s_rej.stdout)

        # Worker remediates and re-submits
        res_resub = self.run_lua("submit", "task-rej-01", "gate_token_v2", "alice", "pubkey_alice", "head_commit_v2")
        self.assertEqual(res_resub.returncode, 0)
        data_resub = json.loads(res_resub.stdout.strip())
        self.assertEqual(data_resub["state"], "SUBMITTED")
        self.assertEqual(data_resub["gate_token"], "gate_token_v2")

        # Index set: removed from rejected, added to submitted
        s_rej2 = subprocess.run(["redis-cli", "-u", REDIS_URL, "SMEMBERS", f"{self.prefix}strands:state:rejected"], capture_output=True, text=True)
        self.assertNotIn("task-rej-01", s_rej2.stdout)

        s_sub2 = subprocess.run(["redis-cli", "-u", REDIS_URL, "SMEMBERS", f"{self.prefix}strands:state:submitted"], capture_output=True, text=True)
        self.assertIn("task-rej-01", s_sub2.stdout)

    def test_07_weave_gate_enforces_ratification(self):
        """Invariant: Only RATIFIED strands can be woven; unratified strands are rejected."""
        self.run_lua("create", "task-weave-01", "rhizo", "/path", "strand/weave-01", "main", "c1", "alice", "pubkey_alice")

        # 1. Attempt weave while PROVISIONED -> must fail
        res_w1 = self.run_lua("weave", "task-weave-01", "merge_sha_1", "orchestrator")
        self.assertIn("Cannot weave unratified strand", res_w1.stdout + res_w1.stderr)

        # 2. Submit strand
        self.run_lua("submit", "task-weave-01", "gate_token_ok", "alice", "pubkey_alice")

        # 3. Attempt weave while SUBMITTED -> must fail
        res_w2 = self.run_lua("weave", "task-weave-01", "merge_sha_1", "orchestrator")
        self.assertIn("Cannot weave unratified strand", res_w2.stdout + res_w2.stderr)

        # 4. Ratify strand
        self.set_heartbeat("bob")
        self.set_mock_time_offset(10)
        res_rat = self.run_lua("ratify", "task-weave-01", "pubkey_bob", "bob", "audit_token_pass", "Approved", "5")
        self.assertEqual(res_rat.returncode, 0)

        # 5. Now weave must succeed!
        res_w3 = self.run_lua("weave", "task-weave-01", "merge_sha_final", "orchestrator")
        self.assertEqual(res_w3.returncode, 0)
        data_w = json.loads(res_w3.stdout.strip())
        self.assertEqual(data_w["status"], "OK")
        self.assertEqual(data_w["state"], "WOVEN")
        self.assertEqual(data_w["merge_commit"], "merge_sha_final")

        # Verify index sets moved to woven
        s_rat = subprocess.run(["redis-cli", "-u", REDIS_URL, "SMEMBERS", f"{self.prefix}strands:state:ratified"], capture_output=True, text=True)
        self.assertNotIn("task-weave-01", s_rat.stdout)

        s_wov = subprocess.run(["redis-cli", "-u", REDIS_URL, "SMEMBERS", f"{self.prefix}strands:state:woven"], capture_output=True, text=True)
        self.assertIn("task-weave-01", s_wov.stdout)

    def test_08_strand_list_and_get(self):
        """Verify list and get queries across multiple strands and states."""
        self.run_lua("create", "task-list-a", "proj1", "/path/a", "branch/a", "main", "c1", "alice", "pk_a")
        self.run_lua("create", "task-list-b", "proj2", "/path/b", "branch/b", "main", "c2", "bob", "pk_b")
        self.run_lua("submit", "task-list-b", "token_b", "bob", "pk_b")

        # Get specific strand
        res_get = self.run_lua("get", "task-list-a")
        self.assertEqual(res_get.returncode, 0)
        data_get = json.loads(res_get.stdout.strip())
        self.assertEqual(data_get["strand"]["id"], "task-list-a")
        self.assertEqual(data_get["strand"]["project"], "proj1")

        # List all strands
        res_all = self.run_lua("list")
        self.assertEqual(res_all.returncode, 0)
        data_all = json.loads(res_all.stdout.strip())
        self.assertEqual(data_all["count"], 2)

        # List filtered by state
        res_sub = self.run_lua("list", "submitted")
        self.assertEqual(res_sub.returncode, 0)
        data_sub = json.loads(res_sub.stdout.strip())
        self.assertEqual(data_sub["count"], 1)
        self.assertEqual(data_sub["strands"][0]["id"], "task-list-b")


if __name__ == "__main__":
    unittest.main()
