import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
import redis

REDIS_URL = os.environ.get("RHIZO_REDIS_URL", "redis://127.0.0.1:6379")
TEST_PREFIX = os.environ.get("RHIZO_REDIS_PREFIX", f"rhizo_test_tenancy_{os.getpid()}:")
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if os.name == "nt":
    BIN_PATH = os.path.abspath(os.path.join(REPO_ROOT, "bin", "rhizo.exe"))
else:
    BIN_PATH = os.path.abspath(os.path.join(REPO_ROOT, "bin", "rhizo"))


class TestTenancyOrchestratorAndSessionPubkey(unittest.TestCase):
    def setUp(self):
        self.test_home = tempfile.mkdtemp(prefix="rhizo_tenancy_home_")
        self.env = os.environ.copy()
        self.env["HOME"] = self.test_home
        self.env["USERPROFILE"] = self.test_home
        self.env["RHIZO_REDIS_URL"] = REDIS_URL
        self.env["RHIZO_REDIS_PREFIX"] = TEST_PREFIX
        self.env["RHIZO_PROJECT"] = "test_project"
        self.env["RHIZO_ALLOW_DRIFT"] = "1"
        self.r = redis.Redis.from_url(REDIS_URL, decode_responses=True)
        self.assertTrue(os.path.isfile(BIN_PATH), f"Binary not found at {BIN_PATH}")
        self.run_rhizo(["nuke"])

    def tearDown(self):
        self.run_rhizo(["nuke"])
        if hasattr(self, "test_home") and os.path.isdir(self.test_home):
            shutil.rmtree(self.test_home, ignore_errors=True)

    def run_rhizo(self, args, env_overrides=None):
        cmd_env = self.env.copy()
        if env_overrides:
            cmd_env.update(env_overrides)
        return subprocess.run(
            [BIN_PATH] + args,
            cwd=self.test_home,
            env=cmd_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
        )

    def test_01_orchestrator_project_scoped_resolution(self):
        """Messages sent to @orchestrator resolve to the leader of the sender's own project."""
        # 1. Register agents in proj_alpha
        self.run_rhizo(["open", "alpha_lead", "lead"], env_overrides={"RHIZO_PROJECT": "proj_alpha"})
        self.run_rhizo(["leader", "acquire", "orchestrator:proj_alpha", "--agent", "alpha_lead", "--lease", "300"],
                       env_overrides={"RHIZO_PROJECT": "proj_alpha"})
        self.run_rhizo(["open", "alpha_worker", "worker"], env_overrides={"RHIZO_PROJECT": "proj_alpha"})

        # 2. Register agents in proj_beta
        self.run_rhizo(["open", "beta_lead", "lead"], env_overrides={"RHIZO_PROJECT": "proj_beta"})
        self.run_rhizo(["leader", "acquire", "orchestrator:proj_beta", "--agent", "beta_lead", "--lease", "300"],
                       env_overrides={"RHIZO_PROJECT": "proj_beta"})
        self.run_rhizo(["open", "beta_worker", "worker"], env_overrides={"RHIZO_PROJECT": "proj_beta"})

        # 3. alpha_worker sends to @orchestrator
        res_alpha = self.run_rhizo([
            "send",
            "--to", "@orchestrator",
            "--from", "alpha_worker",
            "--subject", "Alpha Report",
            "--body", "Task in alpha complete"
        ], env_overrides={"RHIZO_PROJECT": "proj_alpha"})
        self.assertEqual(res_alpha.returncode, 0, f"Alpha send failed: {res_alpha.stderr}")
        self.assertIn("alpha_lead", res_alpha.stdout)

        # Verify alpha_lead inbox received it
        res_drain_alpha = self.run_rhizo(["drain", "alpha_lead", "10"], env_overrides={"RHIZO_PROJECT": "proj_alpha"})
        self.assertEqual(res_drain_alpha.returncode, 0)
        messages_alpha = json.loads(res_drain_alpha.stdout.strip())
        self.assertEqual(len(messages_alpha), 1)
        self.assertEqual(messages_alpha[0]["subject"], "Alpha Report")
        self.assertEqual(messages_alpha[0]["from"], "alpha_worker")

        # 4. beta_worker sends to @orchestrator
        res_beta = self.run_rhizo([
            "send",
            "--to", "@orchestrator",
            "--from", "beta_worker",
            "--subject", "Beta Report",
            "--body", "Task in beta complete"
        ], env_overrides={"RHIZO_PROJECT": "proj_beta"})
        self.assertEqual(res_beta.returncode, 0, f"Beta send failed: {res_beta.stderr}")
        self.assertIn("beta_lead", res_beta.stdout)

        # Verify beta_lead inbox received it
        res_drain_beta = self.run_rhizo(["drain", "beta_lead", "10"], env_overrides={"RHIZO_PROJECT": "proj_beta"})
        self.assertEqual(res_drain_beta.returncode, 0)
        messages_beta = json.loads(res_drain_beta.stdout.strip())
        self.assertEqual(len(messages_beta), 1)
        self.assertEqual(messages_beta[0]["subject"], "Beta Report")
        self.assertEqual(messages_beta[0]["from"], "beta_worker")

    def test_02_orchestrator_cross_project_leakage_prevented(self):
        """If sender's project has no leader, messaging @orchestrator must NOT leak to another project's orchestrator."""
        # Project delta has an orchestrator
        self.run_rhizo(["open", "delta_lead", "lead"], env_overrides={"RHIZO_PROJECT": "proj_delta"})
        self.run_rhizo(["leader", "acquire", "orchestrator:proj_delta", "--agent", "delta_lead", "--lease", "300"],
                       env_overrides={"RHIZO_PROJECT": "proj_delta"})

        # Project gamma has worker, but NO orchestrator
        self.run_rhizo(["open", "gamma_worker", "worker"], env_overrides={"RHIZO_PROJECT": "proj_gamma"})

        # gamma_worker attempts to message @orchestrator
        res = self.run_rhizo([
            "send",
            "--to", "@orchestrator",
            "--from", "gamma_worker",
            "--subject", "Gamma Status",
            "--body", "Should fail rather than leak"
        ], env_overrides={"RHIZO_PROJECT": "proj_gamma"})

        self.assertNotEqual(res.returncode, 0, "Must fail when project has no leader")
        self.assertIn("No active leader found for role @orchestrator in project 'proj_gamma'", res.stderr)

        # Ensure delta_lead inbox received ZERO messages
        delta_inbox_len = self.r.llen(f"{TEST_PREFIX}inbox:delta_lead")
        self.assertEqual(delta_inbox_len, 0, "No cross-project message leakage permitted!")

    def test_03_lead_role_resolution(self):
        """Messages to @lead resolve to project lead."""
        self.run_rhizo(["open", "my_lead", "lead"], env_overrides={"RHIZO_PROJECT": "proj_omega"})
        self.run_rhizo(["leader", "acquire", "orchestrator:proj_omega", "--agent", "my_lead", "--lease", "300"],
                       env_overrides={"RHIZO_PROJECT": "proj_omega"})
        self.run_rhizo(["open", "my_worker", "worker"], env_overrides={"RHIZO_PROJECT": "proj_omega"})

        res = self.run_rhizo([
            "send",
            "--to", "@lead",
            "--from", "my_worker",
            "--subject", "Lead Inquiry",
            "--body", "Checking in with lead"
        ], env_overrides={"RHIZO_PROJECT": "proj_omega"})
        self.assertEqual(res.returncode, 0, f"send to @lead failed: {res.stderr}")
        self.assertIn("my_lead", res.stdout)

    def test_04_session_pubkey_bound_on_open_heartbeat_listen(self):
        """rhizo open, rhizo heartbeat, and rhizo listen bind session_pubkey into Redis."""
        agent = "pubkey_agent"
        # 1. Open
        res_open = self.run_rhizo(["open", agent, "worker"])
        self.assertEqual(res_open.returncode, 0)
        pubkey_hash = self.r.hget(f"{TEST_PREFIX}agent:{agent}", "session_pubkey")
        pubkey_direct = self.r.get(f"{TEST_PREFIX}agent:{agent}:session_pubkey")
        self.assertIsNotNone(pubkey_hash)
        self.assertEqual(len(pubkey_hash), 64)
        self.assertEqual(pubkey_hash, pubkey_direct)

        # 2. Heartbeat
        res_hb = self.run_rhizo(["heartbeat", agent, "--json"])
        self.assertEqual(res_hb.returncode, 0, f"heartbeat failed: {res_hb.stderr}")
        hb_data = json.loads(res_hb.stdout.strip())
        self.assertEqual(hb_data["status"], "OK")
        self.assertEqual(hb_data["session_pubkey"], pubkey_hash)

        # 3. Listen
        res_listen = self.run_rhizo(["listen", agent, "1"])
        self.assertEqual(res_listen.returncode, 0)
        # Verify key still present and fresh TTL
        pubkey_after_listen = self.r.get(f"{TEST_PREFIX}agent:{agent}:session_pubkey")
        self.assertEqual(pubkey_after_listen, pubkey_hash)
        ttl = self.r.ttl(f"{TEST_PREFIX}agent:{agent}:session_pubkey")
        self.assertGreater(ttl, 0)

    def test_05_message_receiver_resolves_pubkey_from_redis_without_warning(self):
        """If a message has session_sig but omitted session_pubkey, receiver looks up Redis pubkey and validates cleanly."""
        self.run_rhizo(["open", "alice", "worker"])
        self.run_rhizo(["open", "bob", "worker"])

        # Send a message from alice to bob
        res_send = self.run_rhizo([
            "send",
            "--to", "bob",
            "--from", "alice",
            "--subject", "Crypto Attested",
            "--body", "Payload body"
        ])
        self.assertEqual(res_send.returncode, 0)

        # Peek / inspect raw inbox payload
        raw_msg_str = self.r.lindex(f"{TEST_PREFIX}inbox:bob", 0)
        msg_obj = json.loads(raw_msg_str)
        self.assertIn("session_sig", msg_obj)
        # Intentionally delete session_pubkey from the message wire payload to simulate envelope without pubkey
        del msg_obj["session_pubkey"]
        self.r.lset(f"{TEST_PREFIX}inbox:bob", 0, json.dumps(msg_obj))

        # Bob listens
        res_listen = self.run_rhizo(["listen", "bob", "2"])
        self.assertEqual(res_listen.returncode, 0)
        self.assertNotIn("WARNING: Message has session_sig but no authoritative public key found", res_listen.stderr)
        lines = [l for l in res_listen.stdout.splitlines() if l.strip().startswith("{")]
        self.assertTrue(len(lines) > 0)
        delivered_msg = json.loads(lines[0])
        self.assertTrue(delivered_msg.get("session_verified", False))


if __name__ == "__main__":
    unittest.main()
