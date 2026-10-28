import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
import redis

REDIS_URL = os.environ.get("RHIZO_REDIS_URL", "redis://127.0.0.1:6379")
TEST_PREFIX = os.environ.get("RHIZO_REDIS_PREFIX", f"rhizo_test_purge_{os.getpid()}:")
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if os.name == "nt":
    BIN_PATH = os.path.abspath(os.path.join(REPO_ROOT, "bin", "rhizo.exe"))
else:
    BIN_PATH = os.path.abspath(os.path.join(REPO_ROOT, "bin", "rhizo"))


class TestMessagingAndJsonPurge(unittest.TestCase):
    def setUp(self):
        self.test_home = tempfile.mkdtemp(prefix="rhizo_purge_home_")
        self.env = os.environ.copy()
        self.env["HOME"] = self.test_home
        self.env["USERPROFILE"] = self.test_home
        self.env["RHIZO_REDIS_URL"] = REDIS_URL
        self.env["RHIZO_REDIS_PREFIX"] = TEST_PREFIX
        self.env["RHIZO_PROJECT"] = "test_project"
        self.env["RHIZO_ALLOW_DRIFT"] = "1"
        self.r = redis.Redis.from_url(REDIS_URL, decode_responses=True, protocol=2)
        self.assertTrue(os.path.isfile(BIN_PATH), f"Binary not found at {BIN_PATH}")
        self.run_rhizo(["nuke"])

    def tearDown(self):
        self.run_rhizo(["nuke"])
        if hasattr(self, "test_home") and os.path.isdir(self.test_home):
            shutil.rmtree(self.test_home, ignore_errors=True)
        seed_file = os.path.join(REPO_ROOT, ".garden", "seeds", "task-purge-test.toml")
        if os.path.exists(seed_file):
            try:
                os.remove(seed_file)
            except OSError:
                pass

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

    def test_01_send_defaults_to_message_type(self):
        """rhizo send without --type or --task defaults to msgType='message' and does not create WISM tasks."""
        self.run_rhizo(["open", "alice", "worker"])
        self.run_rhizo(["open", "bob", "worker"])

        # Send a direct query/message
        res_send = self.run_rhizo([
            "send",
            "--to", "bob",
            "--from", "alice",
            "--subject", "Status Query",
            "--body", "Are you available for sync?"
        ])
        self.assertEqual(res_send.returncode, 0, f"send failed: {res_send.stderr}")

        # Pop message via listen
        res_listen = self.run_rhizo(["listen", "bob", "2"])
        self.assertEqual(res_listen.returncode, 0, f"listen failed: {res_listen.stderr}")
        
        # Verify JSON wire envelope
        lines = [line for line in res_listen.stdout.splitlines() if line.strip().startswith("{")]
        self.assertTrue(len(lines) > 0, "Expected JSON message on stdout")
        msg = json.loads(lines[0])
        self.assertEqual(msg.get("type"), "message", f"Expected type='message', got {msg.get('type')}")
        self.assertEqual(msg.get("subject"), "Status Query")

        # Verify reception banner is conversational coordination, NOT task mandate
        self.assertIn("💬 [RHIZO MESSAGE RECEIVED: CONVERSATIONAL COORDINATION] 💬", res_listen.stderr)
        self.assertNotIn("🚨 [RHIZO TASK DELIVERED", res_listen.stderr)
        self.assertIn("Do NOT run 'rhizo task claim'", res_listen.stderr)

    def test_02_explicit_task_flag_and_banner(self):
        """rhizo send with --task or --type task sets msgType='task' and emits autonomous worker mandate banner."""
        self.run_rhizo(["open", "alice", "worker"])
        self.run_rhizo(["open", "bob", "worker"])

        # Send an explicit task directive
        res_send = self.run_rhizo([
            "send",
            "--to", "bob",
            "--from", "alice",
            "--task",
            "--subject", "TASK: Implement telemetry",
            "--body", "Build telemetry reporter"
        ])
        self.assertEqual(res_send.returncode, 0, f"send failed: {res_send.stderr}")

        # Listen on bob
        res_listen = self.run_rhizo(["listen", "bob", "2"])
        self.assertEqual(res_listen.returncode, 0)
        lines = [line for line in res_listen.stdout.splitlines() if line.strip().startswith("{")]
        self.assertTrue(len(lines) > 0)
        msg = json.loads(lines[0])
        self.assertEqual(msg.get("type"), "task")

        # Verify operational task mandate banner is emitted
        self.assertIn("🚨 [RHIZO TASK DELIVERED: IMMEDIATE AUTONOMOUS ACTION REQUIRED] 🚨", res_listen.stderr)
        self.assertIn("AUTONOMOUS WORKER MANDATE", res_listen.stderr)

    def test_03_broadcast_banner_bifurcation(self):
        """Broadcast messages emit cluster awareness banner, not task directive."""
        self.run_rhizo(["open", "bob", "worker"])

        # Send cluster broadcast
        res_bc = self.run_rhizo([
            "broadcast",
            "--from", "orchestrator",
            "--subject", "AUDIT_RATIFIED: Feature X Complete",
            "--body", "Feature X has been woven to main."
        ])
        self.assertEqual(res_bc.returncode, 0)

        res_listen = self.run_rhizo(["listen", "bob", "2"])
        self.assertEqual(res_listen.returncode, 0)
        self.assertIn("📢 [RHIZO BROADCAST RECEIVED: CLUSTER AWARENESS] 📢", res_listen.stderr)
        self.assertNotIn("🚨 [RHIZO TASK DELIVERED", res_listen.stderr)
        self.assertIn("AWARENESS NOTICE", res_listen.stderr)

    def test_04_cross_machine_pid_safety(self):
        """Cross-machine listeners with differing machine_id must NOT invoke POSIX kill(pid, 0)."""
        self.run_rhizo(["open", "charlie", "worker"])
        
        # Inject remote listener lock with a PID that definitely does NOT exist on local machine
        fake_remote_lock = json.dumps({
            "pid": 9999999,
            "host": "remote-mac-node-02",
            "machine_id": "remote-machine-uuid-9999",
            "started": int(time.time())
        })
        self.r.set(f"{TEST_PREFIX}listener:charlie", fake_remote_lock, ex=300)

        # Probe charlie - because machine_id differs, PID must NOT be evaluated as dead
        res_probe = self.run_rhizo(["probe", "charlie", "--json"])
        self.assertEqual(res_probe.returncode, 0)
        probe_data = json.loads(res_probe.stdout.strip())
        self.assertNotEqual(probe_data.get("status"), "STALLED", "Remote listener must not be flagged STALLED by local PID probe")

    def test_05_cross_project_tenancy_gate(self):
        """Direct task directive across projects must be rejected unless explicitly allowed."""
        # Register alice under project alpha
        self.run_rhizo(["open", "alice", "worker"], env_overrides={"RHIZO_PROJECT": "alpha_project"})
        # Register bob under project beta
        self.run_rhizo(["open", "bob", "worker"], env_overrides={"RHIZO_PROJECT": "beta_project"})

        # Alice attempts to dispatch a task directive directly to bob in beta_project
        res_denied = self.run_rhizo([
            "send",
            "--to", "bob",
            "--from", "alice",
            "--type", "task",
            "--subject", "Cross-project Task",
            "--body", "Run migrations"
        ], env_overrides={"RHIZO_PROJECT": "alpha_project"})

        self.assertNotEqual(res_denied.returncode, 0, "Direct cross-project task assignment must be rejected")
        self.assertIn("Cross-project task assignment denied", res_denied.stderr)

        # Now test with --cross-project override
        res_allowed = self.run_rhizo([
            "send",
            "--to", "bob",
            "--from", "alice",
            "--type", "task",
            "--cross-project", "beta_project",
            "--subject", "Cross-project Task Allowed",
            "--body", "Run migrations with override"
        ], env_overrides={"RHIZO_PROJECT": "alpha_project"})
        self.assertEqual(res_allowed.returncode, 0, f"Expected success with --cross-project: {res_allowed.stderr}")

    def test_06_zero_disk_json_purge(self):
        """Lifecycle operations must NOT write or read on-disk current_task_<agent>.json or sessions.json."""
        rhizo_dir = os.path.join(self.test_home, ".config", "rhizo")

        # 1. Open agent
        self.run_rhizo(["open", "worker_x", "worker"])
        self.assertFalse(os.path.exists(os.path.join(rhizo_dir, "sessions.json")), "sessions.json must NOT be created")

        # 2. Set and list sessions
        res_sess_set = self.run_rhizo(["session", "set", "sess_test_123", "worker_x"])
        self.assertEqual(res_sess_set.returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(rhizo_dir, "sessions.json")), "sessions.json must NOT be created on session set")

        res_sess_list = self.run_rhizo(["session", "list", "--json"])
        self.assertEqual(res_sess_list.returncode, 0)
        sess_data = json.loads(res_sess_list.stdout.strip())
        self.assertIn("sess_test_123", sess_data)

        # 3. Task claim
        self.run_rhizo(["task", "create", "task-purge-test", "--title", "Test Zero Disk Purge"])
        res_claim = self.run_rhizo(["task", "claim", "task-purge-test", "--worker", "worker_x", "--no-vine"])
        self.assertEqual(res_claim.returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(rhizo_dir, "current_task_worker_x.json")), "current_task_worker_x.json must NOT be created on claim")
        self.assertFalse(os.path.exists(os.path.join(rhizo_dir, "current_task.json")), "current_task.json must NOT be created on claim")

        # 4. Task complete
        try:
            res_comp = self.run_rhizo(["task", "complete", "task-purge-test", "--worker", "worker_x", "--skip-gate"])
            self.assertEqual(res_comp.returncode, 0)
        finally:
            seed_file = os.path.join(REPO_ROOT, ".garden", "seeds", "task-purge-test.toml")
            if os.path.exists(seed_file):
                try:
                    os.remove(seed_file)
                except OSError:
                    pass


if __name__ == "__main__":
    unittest.main()
