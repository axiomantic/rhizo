import json
import os
import subprocess
import unittest
import redis

import sys

REDIS_URL = os.environ.get("RHIZO_REDIS_URL", "redis://127.0.0.1:6379")
if sys.platform == "win32":
    BIN_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bin", "rhizo.exe"))
    if not os.path.isfile(BIN_PATH):
        BIN_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bin", "rhizo.exe"))
else:
    BIN_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bin", "rhizo"))
    if not os.path.isfile(BIN_PATH):
        BIN_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bin", "rhizo"))

TEST_PREFIX = "test_rhizo_name:"

class TestRhizoNameReservation(unittest.TestCase):
    def setUp(self):
        self.r = redis.Redis.from_url(REDIS_URL, decode_responses=True, protocol=2)
        res = self.run_rhizo(["nuke"])
        self.assertEqual(res.returncode, 0, f"Nuke failed in setUp: {res.stderr}")

    def tearDown(self):
        res = self.run_rhizo(["nuke"])
        self.assertEqual(res.returncode, 0, f"Nuke failed in tearDown: {res.stderr}")
        self.r.close()

    def run_rhizo(self, args):
        cmd = [BIN_PATH, "--prefix", TEST_PREFIX, "--redis-url", REDIS_URL] + args
        res = subprocess.run(cmd, capture_output=True, text=True)
        return res

    def test_rhizo_name_basic(self):
        res = self.run_rhizo(["name"])
        self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
        name = res.stdout.strip()
        self.assertTrue(len(name) > 0)
        # Should be held in Redis
        held_key = f"{TEST_PREFIX}held_name:{name}"
        self.assertEqual(self.r.get(held_key), "1")
        ttl = self.r.ttl(held_key)
        self.assertGreater(ttl, 550)
        self.assertLessEqual(ttl, 600)

    def test_rhizo_name_json_and_custom_prefix(self):
        res = self.run_rhizo(["name", "myproj", "--ttl", "300", "--json"])
        self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
        data = json.loads(res.stdout.strip())
        self.assertTrue(data["name"].startswith("myproj-"))
        self.assertEqual(data["prefix"], "myproj")
        self.assertEqual(data["ttl"], 300)
        self.assertTrue(data["held"])
        self.assertEqual(data["name"], f"myproj-{data['codename']}")

        held_key = f"{TEST_PREFIX}held_name:{data['name']}"
        self.assertEqual(self.r.get(held_key), "1")
        ttl = self.r.ttl(held_key)
        self.assertGreater(ttl, 250)
        self.assertLessEqual(ttl, 300)

    def test_rhizo_name_no_collisions(self):
        names = set()
        for _ in range(5):
            res = self.run_rhizo(["name", "batch"])
            self.assertEqual(res.returncode, 0)
            name = res.stdout.strip()
            self.assertNotIn(name, names)
            names.add(name)
            self.assertEqual(self.r.get(f"{TEST_PREFIX}held_name:{name}"), "1")

    def test_rhizo_open_clears_held_name(self):
        # 1. Reserve name
        res = self.run_rhizo(["name", "openproc"])
        name = res.stdout.strip()
        held_key = f"{TEST_PREFIX}held_name:{name}"
        self.assertEqual(self.r.get(held_key), "1")

        # 2. Open registration
        open_res = self.run_rhizo(["open", name, "worker"])
        self.assertEqual(open_res.returncode, 0)

        # 3. held_name key is deleted, agent is in active_agents and has heartbeat
        self.assertIsNone(self.r.get(held_key))
        self.assertTrue(self.r.sismember(f"{TEST_PREFIX}active_agents", name))
        self.assertEqual(self.r.get(f"{TEST_PREFIX}heartbeat:{name}"), "1")
        # Cleanup handled automatically by tearDown rhizo reset

    def test_rhizo_bare_open_auto_assigns_lexicon_name(self):
        # Bare open without name argument
        open_res = self.run_rhizo(["open"])
        self.assertEqual(open_res.returncode, 0)
        self.assertIn("Registered Successfully", open_res.stdout)

        # Find registered agent
        agents = list(self.r.smembers(f"{TEST_PREFIX}active_agents"))
        self.assertEqual(len(agents), 1)
        name = agents[0]
        # Should not have held_name left over
        self.assertIsNone(self.r.get(f"{TEST_PREFIX}held_name:{name}"))
        self.assertEqual(self.r.get(f"{TEST_PREFIX}heartbeat:{name}"), "1")
        # Cleanup handled automatically by tearDown rhizo reset

    def test_rhizo_nuke(self):
        # 1. Register agents and reserve codenames across multiple projects
        self.run_rhizo(["open", "agent_alpha", "worker"])
        self.run_rhizo(["open", "agent_beta", "worker"])
        self.run_rhizo(["name", "held_candidate"])
        self.run_rhizo(["name", "other_candidate"])
        self.assertTrue(len(self.r.keys(f"{TEST_PREFIX}*")) >= 4)

        # 2. Nuke with JSON format
        res = self.run_rhizo(["nuke", "--json"])
        self.assertEqual(res.returncode, 0)
        data = json.loads(res.stdout.strip())
        self.assertEqual(data["status"], "ok")
        self.assertEqual(data["mode"], "nuke")
        self.assertIn("agent_alpha", data["closed_agents"])
        self.assertIn("agent_beta", data["closed_agents"])
        self.assertGreater(data["deleted_keys"], 0)

        # 3. Keyspace is completely empty
        self.assertEqual(len(self.r.keys(f"{TEST_PREFIX}*")), 0)

    def test_rhizo_reset_project_scoped(self):
        # 1. Register agents in different projects
        self.run_rhizo(["open", "alpha_agent", "worker", "--project", "alpha_proj"])
        self.run_rhizo(["open", "beta_agent", "worker", "--project", "beta_proj"])
        self.run_rhizo(["name", "alpha_proj"])
        self.run_rhizo(["name", "beta_proj"])

        # 2. Reset only alpha_proj
        res = self.run_rhizo(["reset", "alpha_proj", "--json"])
        self.assertEqual(res.returncode, 0)
        data = json.loads(res.stdout.strip())
        self.assertEqual(data["status"], "ok")
        self.assertIn("alpha_agent", data["closed_agents"])
        self.assertNotIn("beta_agent", data["closed_agents"])

        # 3. beta_agent is still active
        self.assertTrue(self.r.sismember(f"{TEST_PREFIX}active_agents", "beta_agent"))
        self.assertEqual(self.r.get(f"{TEST_PREFIX}heartbeat:beta_agent"), "1")

        # 4. Reset --all clears remaining project
        res_all = self.run_rhizo(["reset", "--all", "--json"])
        self.assertEqual(res_all.returncode, 0)
        self.assertEqual(len(self.r.keys(f"{TEST_PREFIX}*")), 0)

if __name__ == "__main__":
    unittest.main()
