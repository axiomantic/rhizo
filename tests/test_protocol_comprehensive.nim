# /Users/eek/Development/rhizo/tests/test_protocol_comprehensive.nim
# Consolidated in-process Nim test suite for Core Protocol, Multicast/Broadcast,
# Messaging Banners, Cross-Project Tenancy, Session Pubkey, Hooks, Agy Ear, Audit Tickets, and Routing CLI.

import tripwire
import tripwire/plugins/osproc as nfos
import tripwire/plugins/httpclient as hf
import ./plugins/redis_tripwire
import std/[os, osproc, strutils, json, options, times, unittest]
import config, redis, guide, routing, session_crypto, rhizo
import ./test_helpers

let initialWorkingDir = getCurrentDir()
let testTmpRoot = getTempDir() / ("rhizo_proto_comp_" & $getCurrentProcessId())
let testRedisUrl = getEnv("RHIZO_REDIS_URL", "redis://127.0.0.1:6379")
let testPrefix = "test_rhizo_proto_" & $getCurrentProcessId() & ":"
var suiteCounter = 0

removeDir(testTmpRoot)
createDir(testTmpRoot)

proc nextTmpDir(name: string): string =
  inc suiteCounter
  result = testTmpRoot / (name & "_" & $suiteCounter)
  removeDir(result)
  createDir(result)

proc saveAndInitProtoEnv(fakeHome: string, projectName: string = "test_project", secretVal: string = ""): seq[tuple[k, v: string, present: bool]] =
  let keys = [
    "HOME", "USERPROFILE", "XDG_CONFIG_HOME",
    "RHIZO_REDIS_URL", "RHIZO_VALKEY_URL", "REDIS_URL",
    "RHIZO_PREFIX", "RHIZO_REDIS_PREFIX", "RHIZO_PROJECT",
    "RHIZO_CONFIG", "RHIZO_PROFILE", "RHIZO_SECRET", "RHIZO_SECRET_FILE",
    "RHIZO_ENCRYPT", "RHIZO_CLUSTER", "RHIZO_ALLOW_DRIFT",
    "RHIZO_AGENT_NAME", "RHIZO_AGENT_ID", "RHIZO_SESSION_ID",
    "ANTIGRAVITY_CONVERSATION_ID", "ANTIGRAVITY_AGENTAPI_EXE",
    "RHIZO_SUPPRESS_ACK_WAKE"
  ]
  for k in keys:
    result.add((k, getEnv(k, ""), existsEnv(k)))
    if k notin ["RHIZO_EAR_DISABLED", "RHIZO_TEST"]:
      delEnv(k)
  putEnv("HOME", fakeHome)
  putEnv("USERPROFILE", fakeHome)
  putEnv("XDG_CONFIG_HOME", fakeHome)
  putEnv("RHIZO_REDIS_URL", testRedisUrl)
  putEnv("RHIZO_PREFIX", testPrefix)
  putEnv("RHIZO_REDIS_PREFIX", testPrefix)
  putEnv("RHIZO_PROJECT", projectName)
  putEnv("RHIZO_ALLOW_DRIFT", "1")
  if secretVal.len > 0:
    putEnv("RHIZO_SECRET", secretVal)

proc restoreProtoEnv(saved: seq[tuple[k, v: string, present: bool]]) =
  for item in saved:
    if item.present: putEnv(item.k, item.v)
    else: delEnv(item.k)

proc sha256HexLower(data: string): string =
  computeSha256(data)

suite "Rhizo Core Messaging, Directory, Tags, Reply & Encryption Suite":

  setup:
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  teardown:
    try: setCurrentDir(initialWorkingDir) except CatchableError: discard
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  test "agent registration, who directory filtering, tag management, and close":
    sandbox:
      allow(redisPluginInstance)
      let tmpHome = nextTmpDir("proto_dir")
      let saved = saveAndInitProtoEnv(tmpHome, "test_project")
      defer:
        restoreProtoEnv(saved)
        removeDir(tmpHome)

      check runRhizoInProcess(["open", "nim_test_bot", "backend,worker"]).code == 0

      let rWhoTxt = runRhizoInProcess(["who", "*"])
      check rWhoTxt.code == 0
      check rWhoTxt.outStr.contains("nim_test_bot")
      check rWhoTxt.outStr.contains("ACTIVE")

      let rWhoJson = runRhizoInProcess(["who", "*", "--json"])
      check rWhoJson.code == 0
      let agents = parseJson(rWhoJson.outStr.strip())
      check agents.kind == JArray
      var foundBot = false
      for a in agents:
        if a{"agent"}.getStr("") == "nim_test_bot" or a{"name"}.getStr("") == "nim_test_bot":
          foundBot = true
          check a["status"].getStr() == "ACTIVE"
          check a["state"].getStr() == "IDLE"
      check foundBot

      let rTagFilter = runRhizoInProcess(["who", "backend", "--json"])
      check rTagFilter.code == 0
      check rTagFilter.outStr.contains("nim_test_bot")

      let rMiss = runRhizoInProcess(["who", "nonexistent_tag_xyz", "--json"])
      check rMiss.code == 0
      check not rMiss.outStr.contains("nim_test_bot")

      # Tag mutations + unregistered rejection
      check runRhizoInProcess(["tag", "add", "nim,systems", "nim_test_bot"]).code == 0
      check runRhizoInProcess(["who", "systems", "--json"]).outStr.contains("nim_test_bot")
      check runRhizoInProcess(["tag", "remove", "systems", "nim_test_bot"]).code == 0
      check not runRhizoInProcess(["who", "systems", "--json"]).outStr.contains("nim_test_bot")
      check runRhizoInProcess(["tag", "add", "x", "unregistered_ghost_bot"]).code != 0

      check runRhizoInProcess(["close", "nim_test_bot"]).code == 0

  test "point-to-point send, reply threading, multicast @tag, broadcast, and ping-pong":
    sandbox:
      allow(redisPluginInstance)
      allow(nfos.osprocPluginInstance)
      let tmpHome = nextTmpDir("proto_msg")
      let saved = saveAndInitProtoEnv(tmpHome, "test_project")
      defer:
        restoreProtoEnv(saved)
        removeDir(tmpHome)

      check runRhizoInProcess(["open", "alice", "lead"]).code == 0
      check runRhizoInProcess(["open", "bob", "worker,nim"]).code == 0
      check runRhizoInProcess(["open", "carol", "worker,qa"]).code == 0

      # Direct send + listen + reply threading
      let rSend = runRhizoInProcess(["send", "--to", "bob", "--from", "alice", "--type", "task", "--subject", "Compute Product", "--body", "Compute 15 * 15"])
      check rSend.code == 0

      let rCheckInbox = runRhizoInProcess(["check-inbox", "bob"])
      check rCheckInbox.code == 0
      check rCheckInbox.outStr.strip() == "1"

      # Peek inbox without draining
      let rPeek = runRhizoInProcess(["inbox", "bob", "--peek", "--json"])
      check rPeek.code == 0
      let peekArr = parseJson(rPeek.outStr.strip())
      check peekArr.len == 1
      let msgId = peekArr[0]["id"].getStr()

      let rListenBob = runRhizoInProcess(["listen", "bob", "--timeout", "2"])
      check rListenBob.code == 0
      var bobMsgJson: JsonNode = nil
      for line in rListenBob.outStr.splitLines():
        if line.strip().startsWith("{"):
          bobMsgJson = parseJson(line.strip())
          break
      check bobMsgJson != nil
      check bobMsgJson["subject"].getStr() == "Compute Product"
      check bobMsgJson["body"].getStr() == "Compute 15 * 15"
      check bobMsgJson["type"].getStr() == "task"
      check bobMsgJson["sig"].getStr().len == 64

      let rReply = runRhizoInProcess(["reply", "--to", "alice", "--from", "bob", "--reply-to", msgId, "--subject", "Re: Compute Product", "--body", "Result is 225"])
      check rReply.code == 0

      let rDrainAlice = runRhizoInProcess(["drain", "alice", "--format", "json"])
      check rDrainAlice.code == 0
      let aliceMsgs = parseJson(rDrainAlice.outStr.strip())
      check aliceMsgs.len == 1
      check aliceMsgs[0]["reply_to"].getStr() == msgId
      check aliceMsgs[0]["body"].getStr() == "Result is 225"

      # Multicast --tags worker
      check runRhizoInProcess(["broadcast", "--tags", "worker", "--from", "alice", "--subject", "Multi", "--body", "Hello workers"]).code == 0
      check runRhizoInProcess(["drain", "bob", "--format", "json"]).outStr.contains("Hello workers")
      check runRhizoInProcess(["drain", "carol", "--format", "json"]).outStr.contains("Hello workers")

      # Broadcast
      check runRhizoInProcess(["broadcast", "--from", "alice", "--subject", "Cluster Notice", "--body", "All hands"]).code == 0
      check runRhizoInProcess(["drain", "bob", "--format", "json"]).outStr.contains("All hands")
      check runRhizoInProcess(["drain", "carol", "--format", "json"]).outStr.contains("All hands")

  test "firewall drops forged HMAC, corrupt AES ciphertext, and non-JSON payloads; E2EE roundtrips cleanly":
    sandbox:
      allow(redisPluginInstance)
      allow(nfos.osprocPluginInstance)
      let tmpHome = nextTmpDir("proto_sec")
      let saved = saveAndInitProtoEnv(tmpHome, "test_project")
      defer:
        restoreProtoEnv(saved)
        removeDir(tmpHome)

      check runRhizoInProcess(["open", "sec_bot", "worker"]).code == 0
      let rSec = runRhizoInProcess(["get-secret"])
      check rSec.code == 0
      let secret = rSec.outStr.strip()
      check secret.len == 64

      var client = openRedisClient(testRedisUrl)
      defer: (try: client.close() except CatchableError: discard)

      # 1. Forged HMAC dropped
      let forged = $(%*{
        "id": "forged_01", "from": "attacker", "to": "sec_bot", "type": "task",
        "tags": ["test_project"], "subject": "Attack", "body": "INJECT",
        "timestamp": "2026-09-19T00:00:00Z", "sig": "0".repeat(64), "encrypted": false
      })
      discard client.lPush(testPrefix & "inbox:sec_bot", forged)
      let rForged = runRhizoInProcess(["listen", "sec_bot", "--timeout", "1"])
      check rForged.code == 0
      check rForged.outStr.strip() == ""
      check rForged.errStr.contains("Dropping unauthenticated/tampered message")

      # 2. Corrupted encrypted payload with valid HMAC dropped
      let badCipher = "NOT_VALID_BASE64_AES_CIPHERTEXT"
      let canon = "msg_corrupt_1|sender|sec_bot|task|Corrupt|" & badCipher & "|2026-09-19T00:00:00Z"
      let sig = computeHmacSha256(secret, canon)
      let corruptPayload = $(%*{
        "id": "msg_corrupt_1", "from": "sender", "to": "sec_bot", "type": "task",
        "tags": ["test_project"], "subject": "Corrupt", "body": badCipher,
        "timestamp": "2026-09-19T00:00:00Z", "sig": sig, "encrypted": true
      })
      discard client.lPush(testPrefix & "inbox:sec_bot", corruptPayload)
      let rCorr = runRhizoInProcess(["listen", "sec_bot", "--timeout", "1"])
      check rCorr.code == 0
      check rCorr.outStr.strip() == ""
      check rCorr.errStr.contains("Dropping corrupted/undecryptable message")
      check client.lLen(testPrefix & "inbox:sec_bot") == 0

      # 3. Non-JSON garbage dropped
      discard client.lPush(testPrefix & "inbox:sec_bot", "NOT JSON {{{ GARBAGE")
      let rNonJson = runRhizoInProcess(["listen", "sec_bot", "--timeout", "1"])
      check rNonJson.code == 0
      check rNonJson.outStr.strip() == ""

      # 4. E2EE roundtrip keeps ciphertext opaque in Redis and decrypts cleanly on listen
      putEnv("RHIZO_ENCRYPT", "1")
      let secretBody = "TopSecret_Payload_12345_!@#$"
      check runRhizoInProcess(["send", "--to", "sec_bot", "--from", "sec_bot", "--subject", "Encrypted", "--body", secretBody]).code == 0
      let rawRedis = client.lIndex(testPrefix & "inbox:sec_bot", 0)
      check not rawRedis.contains(secretBody)
      check parseJson(rawRedis)["encrypted"].getBool() == true

      let rE2E = runRhizoInProcess(["listen", "sec_bot", "--timeout", "2"])
      check rE2E.code == 0
      check parseJson(rE2E.outStr.strip())["body"].getStr() == secretBody

      # Argument validation negative controls
      check runRhizoInProcess(["send", "--to", "nobody"]).code == 1
      check runRhizoInProcess(["send", "--subject", "Task", "--body", "Details"]).code == 1
      check runRhizoInProcess(["broadcast"]).code == 1
      check runRhizoInProcess(["reply", "--subject", "Re", "--body", "Done"]).code == 1
      check runRhizoInProcess(["reply", "--to", "alice", "--subject", "Re"]).code == 1

suite "Rhizo Message Banners, Cross-Machine Safety, Tenancy & Zero-Disk JSON Suite":

  setup:
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  teardown:
    try: setCurrentDir(initialWorkingDir) except CatchableError: discard
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  test "banner bifurcation, remote PID safety, cross-project task gate, and zero on-disk JSON":
    sandbox:
      allow(redisPluginInstance)
      allow(nfos.osprocPluginInstance)
      let tmpHome = nextTmpDir("msg_banners")
      let saved = saveAndInitProtoEnv(tmpHome, "test_project")
      defer:
        restoreProtoEnv(saved)
        removeDir(tmpHome)

      check runRhizoInProcess(["open", "alice", "worker"]).code == 0
      check runRhizoInProcess(["open", "bob", "worker"]).code == 0

      # 1. Default send -> conversational coordination banner
      check runRhizoInProcess(["send", "--to", "bob", "--from", "alice", "--subject", "Status Query", "--body", "Sync?"]).code == 0
      let r1 = runRhizoInProcess(["listen", "bob", "2"])
      check r1.code == 0
      check r1.errStr.contains("CONVERSATIONAL COORDINATION")
      check not r1.errStr.contains("IMMEDIATE AUTONOMOUS ACTION REQUIRED")
      check r1.errStr.contains("Do NOT run 'rhizo task claim'")

      # 2. send --task -> autonomous action banner
      check runRhizoInProcess(["send", "--to", "bob", "--from", "alice", "--task", "--subject", "TASK: Build", "--body", "Build telemetry"]).code == 0
      let r2 = runRhizoInProcess(["listen", "bob", "2"])
      check r2.code == 0
      check r2.errStr.contains("IMMEDIATE AUTONOMOUS ACTION REQUIRED")
      check r2.errStr.contains("AUTONOMOUS WORKER MANDATE")

      # 3. broadcast -> cluster awareness banner
      check runRhizoInProcess(["broadcast", "--from", "alice", "--subject", "AUDIT_RATIFIED: Done", "--body", "Merged"]).code == 0
      let r3 = runRhizoInProcess(["listen", "bob", "2"])
      check r3.code == 0
      check r3.errStr.contains("CLUSTER AWARENESS")
      check not r3.errStr.contains("IMMEDIATE AUTONOMOUS ACTION REQUIRED")

      # 4. Cross-machine listener PID not killed / not STALLED
      var client = openRedisClient(testRedisUrl)
      defer: (try: client.close() except CatchableError: discard)
      check runRhizoInProcess(["open", "charlie", "worker"]).code == 0
      discard client.setEx(testPrefix & "listener:charlie", 300, $(%*{
        "pid": 9999999, "host": "remote-node-02", "machine_id": "remote-machine-uuid-9999", "started": getTime().toUnix()
      }))
      let rProbe = runRhizoInProcess(["probe", "charlie", "--json"])
      check rProbe.code == 0
      check parseJson(rProbe.outStr.strip()){"status"}.getStr("") != "STALLED"

      # 5. Cross-project task tenancy gate
      putEnv("RHIZO_PROJECT", "alpha_project")
      check runRhizoInProcess(["open", "alpha_worker", "worker"]).code == 0
      putEnv("RHIZO_PROJECT", "beta_project")
      check runRhizoInProcess(["open", "beta_worker", "worker"]).code == 0
      putEnv("RHIZO_PROJECT", "alpha_project")
      let rDenied = runRhizoInProcess(["send", "--to", "beta_worker", "--from", "alpha_worker", "--type", "task", "--subject", "Cross", "--body", "Go"])
      check rDenied.code != 0
      check rDenied.errStr.contains("Cross-project task assignment denied")
      let rAllowed = runRhizoInProcess(["send", "--to", "beta_worker", "--from", "alpha_worker", "--type", "task", "--cross-project", "beta_project", "--subject", "Cross", "--body", "Go"])
      check rAllowed.code == 0

      # 6. Zero on-disk JSON artifacts
      putEnv("RHIZO_PROJECT", "test_project")
      let rhizoDir = tmpHome / ".config" / "rhizo"
      check runRhizoInProcess(["open", "worker_x", "worker"]).code == 0
      check not fileExists(rhizoDir / "sessions.json")
      check runRhizoInProcess(["session", "set", "sess_test_123", "worker_x"]).code == 0
      check not fileExists(rhizoDir / "sessions.json")
      check runRhizoInProcess(["session", "list", "--json"]).outStr.contains("sess_test_123")
      check runRhizoInProcess(["task", "create", "task-purge-nim", "--title", "Zero Disk Purge"]).code == 0
      check runRhizoInProcess(["task", "claim", "task-purge-nim", "--worker", "worker_x", "--no-vine"]).code == 0
      check not fileExists(rhizoDir / "current_task_worker_x.json")
      check not fileExists(rhizoDir / "current_task.json")
      check runRhizoInProcess(["task", "complete", "task-purge-nim", "--worker", "worker_x", "--skip-gate"]).code == 0

suite "Rhizo Orchestrator Scoping & Session Pubkey Suite":

  setup:
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  teardown:
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  test "@orchestrator and @lead resolve per-project without leakage; receiver resolves session_pubkey from Redis":
    sandbox:
      allow(redisPluginInstance)
      allow(nfos.osprocPluginInstance)
      let tmpHome = nextTmpDir("tenancy")
      let saved = saveAndInitProtoEnv(tmpHome, "proj_alpha")
      defer:
        restoreProtoEnv(saved)
        removeDir(tmpHome)

      var client = openRedisClient(testRedisUrl)
      defer: (try: client.close() except CatchableError: discard)

      putEnv("RHIZO_PROJECT", "proj_alpha")
      check runRhizoInProcess(["open", "alpha_lead", "lead"]).code == 0
      check runRhizoInProcess(["leader", "acquire", "orchestrator:proj_alpha", "--agent", "alpha_lead", "--lease", "300"]).code == 0
      check runRhizoInProcess(["open", "alpha_worker", "worker"]).code == 0

      putEnv("RHIZO_PROJECT", "proj_beta")
      check runRhizoInProcess(["open", "beta_lead", "lead"]).code == 0
      check runRhizoInProcess(["leader", "acquire", "orchestrator:proj_beta", "--agent", "beta_lead", "--lease", "300"]).code == 0
      check runRhizoInProcess(["open", "beta_worker", "worker"]).code == 0

      putEnv("RHIZO_PROJECT", "proj_alpha")
      let rAlpha = runRhizoInProcess(["send", "--to", "@orchestrator", "--from", "alpha_worker", "--subject", "Alpha", "--body", "Done"])
      check rAlpha.code == 0
      check rAlpha.outStr.contains("alpha_lead")
      check parseJson(runRhizoInProcess(["drain", "alpha_lead", "10"]).outStr.strip())[0]["subject"].getStr() == "Alpha"

      putEnv("RHIZO_PROJECT", "proj_omega")
      check runRhizoInProcess(["open", "my_lead", "lead"]).code == 0
      check runRhizoInProcess(["leader", "acquire", "orchestrator:proj_omega", "--agent", "my_lead", "--lease", "300"]).code == 0
      check runRhizoInProcess(["open", "my_worker", "worker"]).code == 0
      let rLead = runRhizoInProcess(["send", "--to", "@lead", "--from", "my_worker", "--subject", "Lead Check", "--body", "Ping"])
      check rLead.code == 0
      check rLead.outStr.contains("my_lead")

      # Missing leader in proj_gamma must NOT leak to alpha_lead/beta_lead
      putEnv("RHIZO_PROJECT", "proj_gamma")
      check runRhizoInProcess(["open", "gamma_worker", "worker"]).code == 0
      let rLeak = runRhizoInProcess(["send", "--to", "@orchestrator", "--from", "gamma_worker", "--subject", "Gamma", "--body", "Leak?"])
      check rLeak.code != 0
      check rLeak.errStr.contains("No active leader found for role @orchestrator in project 'proj_gamma'")
      check client.lLen(testPrefix & "inbox:alpha_lead") == 0

      # Session pubkey binding + omitted wire pubkey verification via Redis
      putEnv("RHIZO_PROJECT", "proj_alpha")
      check runRhizoInProcess(["open", "pub_alice", "worker"]).code == 0
      check runRhizoInProcess(["open", "pub_bob", "worker"]).code == 0
      let pubHex = client.hGet(testPrefix & "agent:pub_alice", "session_pubkey")
      check pubHex.len == 64
      check client.get(testPrefix & "agent:pub_alice:session_pubkey") == pubHex

      let rHb = runRhizoInProcess(["heartbeat", "pub_alice", "--json"])
      check rHb.code == 0
      check parseJson(rHb.outStr.strip())["session_pubkey"].getStr() == pubHex

      check runRhizoInProcess(["send", "--to", "pub_bob", "--from", "pub_alice", "--subject", "Attested", "--body", "Verified"]).code == 0
      var msgNode = parseJson(client.lIndex(testPrefix & "inbox:pub_bob", 0))
      msgNode.delete("session_pubkey")
      client.lSet(testPrefix & "inbox:pub_bob", 0, $msgNode)

      let rListen = runRhizoInProcess(["listen", "pub_bob", "2"])
      check rListen.code == 0
      check not rListen.errStr.contains("WARNING: Message has session_sig but no authoritative public key found")
      for line in rListen.outStr.splitLines():
        if line.strip().startsWith("{"):
          check parseJson(line.strip())["session_verified"].getBool() == true

suite "Rhizo Lifecycle Hooks, Agy Ear, Audit Tickets & Routing CLI Suite":

  setup:
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  teardown:
    try: setCurrentDir(initialWorkingDir) except CatchableError: discard
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  test "hook stop, hook install across harnesses, agy-pre-invocation, agy-post-tool, and agy-stop":
    sandbox:
      allow(redisPluginInstance)
      allow(nfos.osprocPluginInstance)
      let tmpHome = nextTmpDir("hooks_home")
      let projDir = nextTmpDir("hooks_proj")
      let secret = "test-secret-key-32-chars-long!!"
      let saved = saveAndInitProtoEnv(tmpHome, "hooks_proj", secret)
      defer:
        try: setCurrentDir(initialWorkingDir) except CatchableError: discard
        restoreProtoEnv(saved)
        removeDir(tmpHome)
        removeDir(projDir)

      var client = openRedisClient(testRedisUrl)
      defer: (try: client.close() except CatchableError: discard)

      # 1. Native hook stop
      let agent = "test_native_hook_agent"
      check parseJson(runRhizoInProcess(["hook", "stop", "--agent", agent]).outStr.strip()).len == 0
      check runRhizoInProcess(["open", agent, "test"]).code == 0
      let rDead = runRhizoInProcess(["hook", "stop", "--agent", agent])
      check rDead.code == 0
      let jDead = parseJson(rDead.outStr.strip())
      check jDead["decision"].getStr() == "block"
      check jDead["reason"].getStr().contains("listener is DEAD")

      check runRhizoInProcess(["send", "--from", "sender", "--to", agent, "--subject", "Audit Alert", "--body", "CVE-2026-99"]).code == 0
      let rMsg = runRhizoInProcess(["hook", "stop", "--agent", agent])
      check rMsg.code == 0
      let jMsg = parseJson(rMsg.outStr.strip())
      check jMsg["decision"].getStr() == "block"
      check jMsg["reason"].getStr().contains("Audit Alert")
      check jMsg["reason"].getStr().contains("CVE-2026-99")

      # 2. hook install variants
      setCurrentDir(projDir)
      check runRhizoInProcess(["hook", "install", "--codex", "--agent", agent]).code == 0
      let codexHooks = parseJson(readFile(projDir / ".codex" / "hooks.json"))
      check codexHooks["hooks"]["Stop"][0]["command"].getStr().contains("hook codex-stop --agent " & agent)

      check runRhizoInProcess(["hook", "install", "--opencode"]).code == 0
      check fileExists(tmpHome / ".config" / "opencode" / "plugins" / "rhizo-ear.js")
      check runRhizoInProcess(["hook", "install", "--opencode", "--local"]).code == 0
      check fileExists(projDir / ".opencode" / "plugins" / "rhizo-ear.js")

      check runRhizoInProcess(["hook", "install", "--pi"]).code == 0
      check fileExists(tmpHome / ".pi" / "agent" / "extensions" / "rhizo-ear.ts")
      check runRhizoInProcess(["hook", "install", "pi", "--local"]).code == 0
      check fileExists(projDir / ".pi" / "agent" / "extensions" / "rhizo-ear.ts")
      check runRhizoInProcess(["hook", "install", "--harness=opencode", "--local"]).code == 0
      let rBadHarness = runRhizoInProcess(["hook", "install", "--harness=unsupported"])
      check rBadHarness.combined.contains("Error: Unknown harness 'unsupported'")

      check runRhizoInProcess(["hook", "install", "--antigravity", "--local", "--agent", "agy-w"]).code == 0
      let agyHooks = parseJson(readFile(projDir / ".agents" / "hooks.json"))["rhizo"]
      check agyHooks["PreInvocation"][0]["command"].getStr().contains("hook agy-pre-invocation --agent agy-w")
      check agyHooks["PostToolUse"][0]["matcher"].getStr() == "*"
      check agyHooks["Stop"][0]["command"].getStr().contains("hook agy-stop --agent agy-w")

      # 3. agy-pre-invocation
      let preDir = nextTmpDir("pre_inv")
      setCurrentDir(preDir)
      check runRhizoInProcess(["hook", "agy-pre-invocation", "--agent", "pre-a"]).outStr.strip() == "{}"
      writeFile(preDir / ".vine.json", $(%*{"task_id": "task-xyz-123", "strand_path": "/tmp/strand-xyz", "status": "IN_PROGRESS"}))
      let rPre2 = runRhizoInProcess(["hook", "agy-pre-invocation", "--agent", "pre-a"])
      check rPre2.code == 0
      let ephem = parseJson(rPre2.outStr.strip())["injectSteps"][0]["ephemeralMessage"].getStr()
      check ephem.contains("task-xyz-123")
      check ephem.contains("/tmp/strand-xyz")

      # 4. agy-post-tool updates state, activity, last_seen, and active task lease
      let ptAgent = "test-posttool-agent"
      let taskKey = testPrefix & "task:task-agy-lease"
      let agentKey = testPrefix & "agent:" & ptAgent
      discard client.hSet(taskKey, "id", "task-agy-lease")
      discard client.hSet(taskKey, "state", "CLAIMED")
      discard client.hSet(taskKey, "worker", ptAgent)
      discard client.hSet(taskKey, "lease_until", $(getTime().toUnix() + 10))
      discard client.hSet(agentKey, "current_task", "task-agy-lease")
      let ptStdin = $(%*{"toolCall": {"name": "run_command", "arguments": {"CommandLine": "nimble build", "toolSummary": "Build release"}}})
      let rPt = runRhizoInProcess(["hook", "agy-post-tool", "--agent", ptAgent], ptStdin, hasStdin = true)
      check rPt.code == 0
      check rPt.outStr.strip() == "{}"
      check client.hGet(agentKey, "state") == "busy"
      check client.hGet(agentKey, "activity") == "Executing: run_command (Build release)"
      check parseInt(client.hGet(taskKey, "lease_until")) >= getTime().toUnix() + 295

      # 5. agy-stop clean vs unread vs 3-strike thrash valve
      let stopAgent = "test-stop-agent"
      let stopKey = testPrefix & "agent:" & stopAgent
      let stopInbox = testPrefix & "inbox:" & stopAgent
      let thrashKey = testPrefix & "hook_blocks:" & stopAgent
      discard client.hSet(stopKey, "state", "busy")
      discard client.hSet(stopKey, "last_version_notified:rhizo", RhizoVersion)
      check runRhizoInProcess(["hook", "agy-stop", "--agent", stopAgent]).outStr.strip() == "{}"
      check client.hGet(stopKey, "state") == "idle"

      discard client.lPush(stopInbox, $(%*{"id": "m1", "from": "t", "to": stopAgent, "type": "task", "subject": "Work", "body": "Now", "timestamp": "2026-11-09T22:00:00Z"}))
      let rStopUnread = runRhizoInProcess(["hook", "agy-stop", "--agent", stopAgent])
      let jUnread = parseJson(rStopUnread.outStr.strip())
      check jUnread["decision"].getStr() == "continue"
      check jUnread["reason"].getStr().toLowerAscii.contains("unread message")

      discard client.hSet(stopKey, "state", "busy")
      client.setk(thrashKey, "3")
      check runRhizoInProcess(["hook", "agy-stop", "--agent", stopAgent]).outStr.strip() == "{}"
      check client.hGet(stopKey, "state") == "idle"

  test "agy-ear routine ACK suppression, task delivery, woven gate interlock, and per-auditor audit ticket isolation":
    sandbox:
      allow(redisPluginInstance)
      allow(nfos.osprocPluginInstance)
      let tmpHome = nextTmpDir("agy_ear")
      let secret = "test-secret-key-32-chars-long!!"
      let saved = saveAndInitProtoEnv(tmpHome, "ear_proj", secret)
      defer:
        restoreProtoEnv(saved)
        removeDir(tmpHome)

      var client = openRedisClient(testRedisUrl)
      defer: (try: client.close() except CatchableError: discard)

      # 1. agy-ear streaming + routine ACK suppression
      let earAgent = "test-ear-worker"
      let convId = "conv-ear-" & $getCurrentProcessId()
      let logFile = tmpHome / "agentapi.log"
      let mockExe = when defined(windows): tmpHome / "agentapi.py" else: tmpHome / "agentapi"
      when defined(windows):
        writeFile(mockExe, "import sys\nwith open(r\"" & logFile & "\", \"a\", encoding=\"utf-8\") as f:\n    f.write(\" \".join(sys.argv[1:]) + \"\\n\")\n")
      else:
        writeFile(mockExe, "#!/bin/sh\necho \"$@\" >> \"" & logFile & "\"\nexit 0\n")
        setFilePermissions(mockExe, {fpUserRead, fpUserWrite, fpUserExec})

      let agKey = testPrefix & "agent:" & earAgent
      discard client.hSet(agKey, "agy_conversation_id", convId)
      discard client.hSet(agKey, "agy_agentapi_exe", mockExe)
      discard client.hSet(agKey, "last_version_notified:rhizo", RhizoVersion)
      discard client.hSet(testPrefix & "sessions", "agy:" & convId, earAgent)

      putEnv("ANTIGRAVITY_CONVERSATION_ID", convId)
      putEnv("ANTIGRAVITY_AGENTAPI_EXE", mockExe)
      putEnv("RHIZO_SUPPRESS_ACK_WAKE", "1")

      let ackCanon = "msg_ack_01|peer|" & earAgent & "|reply|Task Claimed|ACK claimed|2026-11-09T22:00:00Z"
      discard client.lPush(testPrefix & "inbox:" & earAgent, $(%*{
        "id": "msg_ack_01", "from": "peer", "to": earAgent, "type": "reply",
        "subject": "Task Claimed", "body": "ACK claimed", "timestamp": "2026-11-09T22:00:00Z",
        "sig": computeHmacSha256(secret, ackCanon)
      }))
      check runRhizoInProcess(["listen", earAgent, "--agy-ear", "--timeout", "1", "-q"]).code == 0
      check (not fileExists(logFile) or readFile(logFile).len == 0)

      let taskCanon = "msg_task_01|lead|" & earAgent & "|task|Important Directive: Ship|Execute|2026-11-09T22:00:00Z"
      discard client.lPush(testPrefix & "inbox:" & earAgent, $(%*{
        "id": "msg_task_01", "from": "lead", "to": earAgent, "type": "task", "task_id": "task-core-feat",
        "subject": "Important Directive: Ship", "body": "Execute", "timestamp": "2026-11-09T22:00:00Z",
        "sig": computeHmacSha256(secret, taskCanon)
      }))
      check runRhizoInProcess(["listen", earAgent, "--agy-ear", "--timeout", "1", "-q"]).code == 0
      check fileExists(logFile)
      let logged = readFile(logFile)
      check logged.contains("send-message")
      check logged.contains(convId)
      check client.hGet(agKey, "state") == "busy"
      check client.hGet(agKey, "activity").contains("Delivered: Important Directive: Ship")

      # 2. vine WOVEN interlock allows task complete without --skip-gate
      check runRhizoInProcess(["task", "create", "task-woven-gate", "--title", "Woven Test", "--target", earAgent]).code == 0
      check runRhizoInProcess(["task", "claim", "task-woven-gate", "--worker", earAgent, "--no-vine"]).code == 0
      let wKey = testPrefix & "vine:strand:task-woven-gate"
      discard client.hSet(wKey, "task_id", "task-woven-gate")
      discard client.hSet(wKey, "status", "WOVEN")
      discard client.hSet(wKey, "lifecycle_state", "WOVEN")
      let rComp = runRhizoInProcess(["task", "complete", "task-woven-gate"])
      check rComp.code == 0
      check rComp.outStr.contains("COMPLETED")

      # 3. Audit ticket minted on STRAND_SUBMITTED + per-recipient ticket isolation
      let aud = "remocha-auditor"
      let impl = "remocha-implementer"
      let tId = "task-per-aud-hash-" & $getCurrentProcessId()
      let vineKey = "vine:strand:" & tId
      defer: discard client.del(@[vineKey, testPrefix & "strand:" & tId, testPrefix & "vine:strand:" & tId])

      let c1 = "m_aud_1|lead|" & aud & "|event|STRAND_SUBMITTED: " & tId & "|{\"event\":\"STRAND_SUBMITTED\",\"task_id\":\"" & tId & "\"}|2026-11-12T12:00:00Z"
      discard client.lPush(testPrefix & "inbox:" & aud, $(%*{
        "id": "m_aud_1", "from": "lead", "to": aud, "type": "event", "task_id": tId,
        "subject": "STRAND_SUBMITTED: " & tId,
        "body": "{\"event\":\"STRAND_SUBMITTED\",\"task_id\":\"" & tId & "\"}",
        "timestamp": "2026-11-12T12:00:00Z", "sig": computeHmacSha256(secret, c1)
      }))
      let d1 = parseJson(runRhizoInProcess(["drain", "1", aud, "--format", "json"]).outStr.strip())
      let tkt1 = d1["audit_ticket"].getStr()
      let hash1 = d1["audit_ticket_hash"].getStr()
      check tkt1.len == 16
      check sha256HexLower(tkt1) == hash1

      let c2 = "m_impl_2|lead|" & impl & "|event|STRAND_SUBMITTED: " & tId & "|{\"event\":\"STRAND_SUBMITTED\",\"task_id\":\"" & tId & "\"}|2026-11-12T12:00:01Z"
      discard client.lPush(testPrefix & "inbox:" & impl, $(%*{
        "id": "m_impl_2", "from": "lead", "to": impl, "type": "event", "task_id": tId,
        "subject": "STRAND_SUBMITTED: " & tId,
        "body": "{\"event\":\"STRAND_SUBMITTED\",\"task_id\":\"" & tId & "\"}",
        "timestamp": "2026-11-12T12:00:01Z", "sig": computeHmacSha256(secret, c2)
      }))
      let d2 = parseJson(runRhizoInProcess(["drain", "1", impl, "--format", "json"]).outStr.strip())
      let tkt2 = d2["audit_ticket"].getStr()
      let hash2 = d2["audit_ticket_hash"].getStr()
      check tkt2.len == 16
      check tkt1 != tkt2
      check client.hGet(vineKey, "audit_ticket_hash:" & aud) == hash1
      check client.hGet(vineKey, "audit_ticket_hash:" & impl) == hash2
      check client.hGet(vineKey, "audit_ticket_hash") == hash1

  test "route init, route lint, missing routes file, setup --help, and typo suggestion":
    sandbox:
      allow(hf.httpclientPluginInstance)
      let tmpDir = nextTmpDir("routing_cli")
      let saved = saveAndInitProtoEnv(tmpDir, "routing_proj")
      defer:
        try: setCurrentDir(initialWorkingDir) except CatchableError: discard
        restoreProtoEnv(saved)
        removeDir(tmpDir)

      setCurrentDir(tmpDir)
      let rInit = runRhizoInProcess(["route", "init"])
      check rInit.code == 0
      check fileExists(tmpDir / "rhizo-routes.yaml")
      let rLint = runRhizoInProcess(["route", "lint"])
      check rLint.code == 0
      check rLint.outStr.contains("Route configuration is valid")

      let rBadFile = runRhizoInProcess(["route", "--routes-file=/nonexistent/routes.yaml", "some task"])
      check rBadFile.code == 1
      check (rBadFile.errStr.toLowerAscii.contains("not found") or rBadFile.errStr.toLowerAscii.contains("missing"))

      let rTypo = runRhizoInProcess(["setup"])
      check rTypo.code == 1
      check rTypo.errStr.contains("Did you mean 'rhizo route setup'?")

      let rSetupHelp = runRhizoInProcess(["route", "setup", "--help"])
      check rSetupHelp.code == 0
      check rSetupHelp.outStr.contains("rhizo route setup")
      check rSetupHelp.outStr.contains("--daemon")

      removeDir(testTmpRoot)
