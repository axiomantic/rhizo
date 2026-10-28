import json
import os
import shutil
import stat
import subprocess
import tempfile
import time
import unittest
import redis

REDIS_URL = os.environ.get("RHIZO_REDIS_URL", "redis://127.0.0.1:6379")
TEST_PREFIX = os.environ.get("RHIZO_REDIS_PREFIX", f"rhizo_test_crypto_{os.getpid()}:")
if os.name == "nt":
    BIN_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bin", "rhizo.exe"))
else:
    BIN_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bin", "rhizo"))


class TestSessionCrypto(unittest.TestCase):
    def setUp(self):
        self.test_home = tempfile.mkdtemp(prefix="rhizo_crypto_home_")
        self.env = os.environ.copy()
        self.env["HOME"] = self.test_home
        self.env["USERPROFILE"] = self.test_home
        self.env["RHIZO_REDIS_URL"] = REDIS_URL
        self.env["RHIZO_REDIS_PREFIX"] = TEST_PREFIX
        self.env["RHIZO_PROJECT"] = "crypto_project"
        self.env["RHIZO_ALLOW_DRIFT"] = "1"
        self.r = redis.Redis.from_url(REDIS_URL, decode_responses=True, protocol=2)
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
            env=cmd_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
        )

    def test_ephemeral_keypair_generation_on_open(self):
        """rhizo open generates an Ed25519 keypair, writes private key to ~/.config/rhizo/sessions/<agent>.key (0600), and records session_pubkey in Redis."""
        res = self.run_rhizo(["open", "alice", "core,protocol"])
        self.assertEqual(res.returncode, 0, f"open failed: {res.stderr}")
        self.assertIn("Ed25519 Session Keypair Active", res.stdout)

        # Verify Redis session_pubkey
        pubkey = self.r.hget(f"{TEST_PREFIX}agent:alice", "session_pubkey")
        self.assertIsNotNone(pubkey)
        self.assertEqual(len(pubkey), 64, "Public key must be 32 bytes (64 hex characters)")

        # Verify disk private key file
        key_path = os.path.join(self.test_home, ".config", "rhizo", "sessions", "alice.key")
        self.assertTrue(os.path.isfile(key_path), f"Private key file not found at {key_path}")
        with open(key_path, "r") as f:
            privkey = f.read().strip()
        self.assertEqual(len(privkey), 64, "Private key seed must be 32 bytes (64 hex characters)")

        # Verify 0600 POSIX permissions
        if os.name != "nt":
            mode = stat.S_IMODE(os.stat(key_path).st_mode)
            self.assertEqual(mode, 0o600, f"Expected 0600 file permissions, got {oct(mode)}")

    def test_signed_message_transmission_and_verification(self):
        """Messages sent by an agent contain session_sig and are verified by recipient against authorative Redis session_pubkey."""
        self.run_rhizo(["open", "alice", "test"])
        self.run_rhizo(["open", "bob", "test"])

        alice_pub = self.r.hget(f"{TEST_PREFIX}agent:alice", "session_pubkey")

        # Alice sends to Bob
        res = self.run_rhizo(
            ["send", "--to", "bob", "--subject", "Task Directive", "--body", "Execute Phase 1"],
            env_overrides={"RHIZO_AGENT_NAME": "alice"}
        )
        self.assertEqual(res.returncode, 0, f"send failed: {res.stderr}")

        # Bob drains the message
        res_drain = self.run_rhizo(
            ["drain", "1", "bob"],
            env_overrides={"RHIZO_AGENT_NAME": "bob"}
        )
        self.assertEqual(res_drain.returncode, 0, f"drain failed: {res_drain.stderr}")
        msg = json.loads(res_drain.stdout.strip())

        self.assertIn("session_sig", msg)
        self.assertEqual(len(msg["session_sig"]), 128, "Ed25519 signature must be 64 bytes (128 hex chars)")
        self.assertEqual(msg.get("session_pubkey"), alice_pub)
        self.assertTrue(msg.get("session_verified"), "Recipient must mark message session_verified: True")

    def test_tampered_payload_rejected_by_drain(self):
        """Tampering with message body or fields invalidates session signature and causes receiver to drop it."""
        self.run_rhizo(["open", "alice", "test"])
        self.run_rhizo(["open", "bob", "test"])

        # Send valid message
        self.run_rhizo(
            ["send", "--to", "bob", "--subject", "Valid Subj", "--body", "Original Body"],
            env_overrides={"RHIZO_AGENT_NAME": "alice"}
        )

        # Inspect and tamper raw message in Redis inbox
        inbox_key = f"{TEST_PREFIX}inbox:bob"
        raw_msg = self.r.rpop(inbox_key)
        self.assertIsNotNone(raw_msg)
        msg_obj = json.loads(raw_msg)

        # Tamper body
        msg_obj["body"] = "MALICIOUS FORGERY"
        self.r.lpush(inbox_key, json.dumps(msg_obj))

        # Drain should reject tampered message (either via HMAC or session signature)
        res_drain = self.run_rhizo(
            ["drain", "1", "bob"],
            env_overrides={"RHIZO_AGENT_NAME": "bob"}
        )
        self.assertIn(res_drain.stdout.strip(), ["", "[]"], "Tampered message must be dropped and never delivered")

    def test_forged_session_signature_rejected(self):
        """Forged session_sig on an otherwise well-formed envelope is rejected."""
        self.run_rhizo(["open", "alice", "test"])
        self.run_rhizo(["open", "bob", "test"])

        self.run_rhizo(
            ["send", "--to", "bob", "--subject", "Subj", "--body", "Content"],
            env_overrides={"RHIZO_AGENT_NAME": "alice"}
        )

        inbox_key = f"{TEST_PREFIX}inbox:bob"
        raw_msg = self.r.rpop(inbox_key)
        msg_obj = json.loads(raw_msg)

        # Corrupt signature
        sig = msg_obj["session_sig"]
        corrupted_sig = ("0" if sig[0] != "0" else "1") + sig[1:]
        msg_obj["session_sig"] = corrupted_sig
        self.r.lpush(inbox_key, json.dumps(msg_obj))

        res_drain = self.run_rhizo(
            ["drain", "1", "bob"],
            env_overrides={"RHIZO_AGENT_NAME": "bob"}
        )
        self.assertIn(res_drain.stdout.strip(), ["", "[]"], "Forged signature message must be dropped")

    def test_cross_session_signature_rejected(self):
        """A signature created by agent B's session key cannot impersonate agent A."""
        self.run_rhizo(["open", "alice", "test"])
        self.run_rhizo(["open", "bob", "test"])
        self.run_rhizo(["open", "eve", "test"])

        # Eve sends a message claiming to be Alice
        eve_key_path = os.path.join(self.test_home, ".config", "rhizo", "sessions", "eve.key")
        with open(eve_key_path, "r") as f:
            eve_priv = f.read().strip()

        # Generate envelope where from='alice' but signed by eve's privkey
        res = self.run_rhizo(
            ["send", "--to", "bob", "--subject", "Spoof", "--body", "From Fake Alice"],
            env_overrides={"RHIZO_AGENT_NAME": "alice", "RHIZO_SESSION_PRIVKEY": eve_priv}
        )

        # Bob verifies against Alice's public key from Redis -> signature fails -> dropped
        res_drain = self.run_rhizo(
            ["drain", "1", "bob"],
            env_overrides={"RHIZO_AGENT_NAME": "bob"}
        )
        self.assertIn(res_drain.stdout.strip(), ["", "[]"], "Cross-session spoofed message must be dropped")

    def test_session_key_rotation_on_reopen(self):
        """Calling rhizo open on an existing agent generates a fresh ephemeral keypair and updates Redis."""
        self.run_rhizo(["open", "alice", "test"])
        pub_1 = self.r.hget(f"{TEST_PREFIX}agent:alice", "session_pubkey")
        key_path = os.path.join(self.test_home, ".config", "rhizo", "sessions", "alice.key")
        with open(key_path, "r") as f:
            priv_1 = f.read().strip()

        # Re-open session
        self.run_rhizo(["open", "alice", "test"])
        pub_2 = self.r.hget(f"{TEST_PREFIX}agent:alice", "session_pubkey")
        with open(key_path, "r") as f:
            priv_2 = f.read().strip()

        self.assertNotEqual(pub_1, pub_2, "Public key must rotate on new rhizo open")
        self.assertNotEqual(priv_1, priv_2, "Private key must rotate on new rhizo open")

    def test_lock_attestation_and_verification(self):
        """rhizo lock signs the lock acquisition with session key; rhizo lock verify verifies attestation."""
        self.run_rhizo(["open", "alice", "test"])

        res_lock = self.run_rhizo(
            ["lock", "build_mutex", "60"],
            env_overrides={"RHIZO_AGENT_NAME": "alice"}
        )
        self.assertEqual(res_lock.returncode, 0, f"lock failed: {res_lock.stderr}")
        self.assertIn("LOCKED", res_lock.stdout)

        # Verification succeeds
        res_ver = self.run_rhizo(["lock", "verify", "build_mutex"])
        self.assertEqual(res_ver.returncode, 0)
        self.assertIn("VERIFIED", res_ver.stdout)
        self.assertIn("alice", res_ver.stdout)

        # Tampering with lock:sig causes verify failure
        sig_key = f"{TEST_PREFIX}lock:sig:{{crypto_project:build_mutex}}"
        self.r.set(sig_key, "00" * 64)
        res_tampered = self.run_rhizo(["lock", "verify", "build_mutex"])
        self.assertNotEqual(res_tampered.returncode, 0)
        self.assertIn("FORGERY", res_tampered.stdout)

        # Unlock clears signature key
        res_unlock = self.run_rhizo(
            ["unlock", "build_mutex"],
            env_overrides={"RHIZO_AGENT_NAME": "alice"}
        )
        self.assertEqual(res_unlock.returncode, 0)
        self.assertIsNone(self.r.get(sig_key))

    def test_task_claim_attestation_and_verification(self):
        """rhizo task claim signs task claim with session key; rhizo task verify validates signature."""
        self.run_rhizo(["open", "worker_1", "worker"])

        # Create task
        res_create = self.run_rhizo(["task", "create", "task_sec_99", "--title", "Security Task"])
        self.assertEqual(res_create.returncode, 0)

        # Worker claims task
        res_claim = self.run_rhizo(
            ["task", "claim", "task_sec_99", "--worker", "worker_1", "--no-vine"],
            env_overrides={"RHIZO_AGENT_NAME": "worker_1"}
        )
        self.assertEqual(res_claim.returncode, 0, f"claim failed: {res_claim.stderr}")

        # Verification succeeds
        res_ver = self.run_rhizo(["task", "verify", "task_sec_99"])
        self.assertEqual(res_ver.returncode, 0)
        self.assertIn("VERIFIED", res_ver.stdout)
        self.assertIn("worker_1", res_ver.stdout)

        # Tampering with claim_sig in task hash causes verify failure
        self.r.hset(f"{TEST_PREFIX}task:task_sec_99", "claim_sig", "ab" * 64)
        res_tampered = self.run_rhizo(["task", "verify", "task_sec_99"])
        self.assertNotEqual(res_tampered.returncode, 0)
        self.assertIn("FORGERY", res_tampered.stdout)

    def test_probe_displays_session_pubkey(self):
        """rhizo probe displays the registered session public key."""
        self.run_rhizo(["open", "alice", "test"])
        pubkey = self.r.hget(f"{TEST_PREFIX}agent:alice", "session_pubkey")

        # JSON probe
        res_probe_json = self.run_rhizo(["probe", "alice", "--json"])
        self.assertEqual(res_probe_json.returncode, 0)
        obj = json.loads(res_probe_json.stdout.strip())
        self.assertEqual(obj.get("session_pubkey"), pubkey)

        # Text probe
        res_probe_txt = self.run_rhizo(["probe", "alice"])
        self.assertEqual(res_probe_txt.returncode, 0)
        self.assertIn("Session Pubkey", res_probe_txt.stdout)
        self.assertIn(pubkey, res_probe_txt.stdout)


if __name__ == "__main__":
    unittest.main()
