# /Users/eek/Development/rhizo/tests/test_coordination_and_security.nim
# Consolidated in-process Nim test suite for Pulse cron scheduler, Ed25519 session
# cryptography, Strand Lua 3-key lifecycle & cluster slot affinity, Vine strand claim
# provisioning, distributed lock fencing, WISM, watchdog, supervision checks, and role separation.

import tripwire
import tripwire/plugins/osproc as nfos
import tripwire/plugins/httpclient as hf
import ./plugins/redis_tripwire
import std/[os, strutils, json, options, times, sets, unittest]
import config, redis, rhizo
import ./test_helpers

let initialWorkingDir = getCurrentDir()
let testTmpRoot = getTempDir() / ("rhizo_coord_sec_" & $getCurrentProcessId())
let testRedisUrl = getEnv("RHIZO_REDIS_URL", "redis://127.0.0.1:6379")
let testPrefix = "test_rhizo_cs_" & $getCurrentProcessId() & ":"
let rhizoRepoRoot = parentDir(currentSourcePath().parentDir())
var suiteCounter = 0

removeDir(testTmpRoot)
createDir(testTmpRoot)

proc nextTmpDir(name: string): string =
  inc suiteCounter
  result = testTmpRoot / (name & "_" & $suiteCounter)
  removeDir(result)
  createDir(result)

proc saveAndInitCoordEnv(fakeHome: string, projectName: string = "test_project"): seq[tuple[k, v: string, present: bool]] =
  let keys = [
    "HOME", "USERPROFILE", "XDG_CONFIG_HOME", "APPDATA", "PATH",
    "RHIZO_REDIS_URL", "RHIZO_VALKEY_URL", "REDIS_URL",
    "RHIZO_PREFIX", "RHIZO_REDIS_PREFIX", "RHIZO_PROJECT",
    "RHIZO_CONFIG", "RHIZO_PROFILE", "RHIZO_SECRET", "RHIZO_SECRET_FILE",
    "RHIZO_ENCRYPT", "RHIZO_CLUSTER", "RHIZO_ALLOW_DRIFT",
    "RHIZO_AGENT_NAME", "RHIZO_AGENT_ID", "RHIZO_SESSION_ID",
    "RHIZO_SESSION_PRIVKEY", "RHIZO_ALLOW_ROLE_IDS",
    "ANTIGRAVITY_CONVERSATION_ID", "OPENCODE_SESSION_ID",
    "PI_SESSION_ID", "CODEX_SESSION_ID"
  ]
  for k in keys:
    result.add((k, getEnv(k, ""), existsEnv(k)))
    if k notin ["PATH", "RHIZO_EAR_DISABLED", "RHIZO_TEST"]:
      delEnv(k)
  putEnv("HOME", fakeHome)
  putEnv("USERPROFILE", fakeHome)
  putEnv("XDG_CONFIG_HOME", fakeHome)
  putEnv("APPDATA", fakeHome)
  putEnv("RHIZO_REDIS_URL", testRedisUrl)
  putEnv("RHIZO_PREFIX", testPrefix)
  putEnv("RHIZO_REDIS_PREFIX", testPrefix)
  putEnv("RHIZO_PROJECT", projectName)
  putEnv("RHIZO_ALLOW_DRIFT", "1")

proc restoreCoordEnv(saved: seq[tuple[k, v: string, present: bool]]) =
  for item in saved:
    if item.present: putEnv(item.k, item.v)
    else: delEnv(item.k)

proc evalStrandLua(client: Redis, luaScript: string, args: openArray[string]): tuple[ok: bool, output: string] =
  var fullArgs = @[testPrefix]
  for a in args: fullArgs.add(a)
  try:
    let res = client.eval(luaScript, @[], fullArgs)
    result = (true, formatRedisValue(res))
  except CatchableError as e:
    result = (false, e.msg)

suite "Rhizo Pulse Cron Scheduler & Mock Time Suite":

  setup:
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  teardown:
    try: setCurrentDir(initialWorkingDir) except CatchableError: discard
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  test "pulse add, list, remove, cron advancement, queue claim/ack, zero duplicates, and monotonic fencing":
    sandbox:
      allow(redisPluginInstance)
      allow(nfos.osprocPluginInstance)
      let tmpHome = nextTmpDir("pulse_home")
      let saved = saveAndInitCoordEnv(tmpHome, "pulse_project")
      defer:
        restoreCoordEnv(saved)
        removeDir(tmpHome)

      var client = openRedisClient(testRedisUrl)
      defer: (try: client.close() except CatchableError: discard)

      # 1. Add, list, duplicate fail, remove
      let rAdd = runRhizoInProcess([
        "pulse", "add", "heartbeat-01", "*/5 * * * *",
        "--queue", "tasks", "--body", "Worker Heartbeat", "--title", "Heartbeat Monitor"
      ])
      check rAdd.code == 0
      check rAdd.outStr.contains("registered successfully")

      let rList = runRhizoInProcess(["pulse", "list", "--json"])
      check rList.code == 0
      let listJson = parseJson(rList.outStr.strip())
      check listJson["status"].getStr() == "OK"
      check listJson["pulses"].len == 1
      let p0 = listJson["pulses"][0]
      check p0["id"].getStr() == "heartbeat-01"
      check p0["cron"].getStr() == "*/5 * * * *"
      check p0["queue"].getStr() == "tasks"
      check p0["body"].getStr() == "Worker Heartbeat"
      check p0["title"].getStr() == "Heartbeat Monitor"
      check p0["total_ticks"].getInt() == 0
      check p0["status"].getStr() == "ACTIVE"
      check p0["next_run"].getBiggestInt() > 0

      let rDup = runRhizoInProcess([
        "pulse", "add", "heartbeat-01", "*/10 * * * *", "--queue", "other", "--body", "Dup"
      ])
      check rDup.code != 0
      check rDup.combined.contains("already exists")

      let rRem = runRhizoInProcess(["pulse", "remove", "heartbeat-01"])
      check rRem.code == 0
      check rRem.outStr.contains("removed successfully")
      check runRhizoInProcess(["pulse", "list"]).outStr.contains("No active pulses registered.")
      check runRhizoInProcess(["pulse", "remove", "non-existent-pulse"]).code != 0

      # 2. @every 30s + time advance + monotonic fencing tokens
      check runRhizoInProcess([
        "pulse", "add", "fast-pulse", "@every 30s",
        "--queue", "fast_jobs", "--body", "Fast job payload", "--title", "Fast Pulse 30s"
      ]).code == 0
      let initialNextRun = parseJson(runRhizoInProcess(["pulse", "list", "--json"]).outStr.strip())["pulses"][0]["next_run"].getBiggestInt()
      check runRhizoInProcess(["pulse", "tick"]).outStr.contains("No due pulses to tick")

      check runRhizoInProcess(["time", "advance", "35"]).code == 0
      let rTick1 = runRhizoInProcess(["pulse", "tick", "--json"])
      check rTick1.code == 0
      let tick1 = parseJson(rTick1.outStr.strip())
      check tick1["ticked"].getInt() == 1
      check tick1["pulses"][0]["id"].getStr() == "fast-pulse"
      check tick1["pulses"][0]["total_ticks"].getInt() == 1
      check tick1["pulses"][0]["next_run"].getBiggestInt() > initialNextRun

      # Immediate second tick before advancing again -> not due
      check runRhizoInProcess(["pulse", "tick", "--json"]).outStr.contains("\"ticked\":0")

      check runRhizoInProcess(["time", "advance", "35"]).code == 0
      let tick2 = parseJson(runRhizoInProcess(["pulse", "tick", "--json"]).outStr.strip())
      check tick2["ticked"].getInt() == 1
      check tick2["pulses"][0]["total_ticks"].getInt() == 2
      check tick2["pulses"][0]["fencing_token"].getInt() == 2

      # 3. --immediate + claim + ack + zero duplicate ticks + fencing progression
      check runRhizoInProcess([
        "pulse", "add", "db-vacuum", "0 0 * * *",
        "--queue", "scheduled_tasks", "--body", "Execute database vacuum",
        "--title", "Nightly DB Vacuum", "--immediate"
      ]).code == 0
      let rTickImm = runRhizoInProcess(["pulse", "tick"])
      check rTickImm.code == 0
      check rTickImm.outStr.contains("Ticked and enqueued 1 pulse(s)")

      putEnv("RHIZO_AGENT_NAME", "pulse_worker_1")
      let rClaim = runRhizoInProcess(["claim", "scheduled_tasks", "--timeout", "2"])
      check rClaim.code == 0
      let claimed = parseJson(rClaim.outStr.strip())
      check claimed["type"].getStr() == "pulse"
      check claimed["to"].getStr() == "queue:scheduled_tasks"
      check claimed["subject"].getStr() == "Nightly DB Vacuum"
      check claimed["body"].getStr() == "Execute database vacuum"
      check claimed["from"].getStr() == "system:pulse"
      check claimed["sig"].getStr().len > 0

      let rAck = runRhizoInProcess(["ack", "scheduled_tasks", claimed["id"].getStr()])
      check rAck.code == 0
      check rAck.outStr.contains("ACK:")

      for i in 0 ..< 5:
        check runRhizoInProcess([
          "pulse", "add", "ha-pulse-" & $i, "@every 60s",
          "--queue", "ha_sink", "--body", "Payload " & $i, "--immediate"
        ]).code == 0
      let tickHa = parseJson(runRhizoInProcess(["pulse", "tick", "--json"]).outStr.strip())
      check tickHa["ticked"].getInt() == 5
      check client.lLen(testPrefix & "queue:{ha_sink}") == 5
      check parseJson(runRhizoInProcess(["pulse", "tick", "--json"]).outStr.strip())["ticked"].getInt() == 0

      cleanupRedisPrefix(testRedisUrl, testPrefix)
      check runRhizoInProcess([
        "pulse", "add", "fence-pulse", "@every 10s",
        "--queue", "fenced_queue", "--body", "Fence", "--immediate"
      ]).code == 0
      var tokens: seq[int] = @[]
      for cycle in 0 ..< 3:
        if cycle > 0:
          check runRhizoInProcess(["time", "advance", "15"]).code == 0
        let tNode = parseJson(runRhizoInProcess(["pulse", "tick", "--json"]).outStr.strip())
        check tNode["ticked"].getInt() == 1
        tokens.add(tNode["pulses"][0]["fencing_token"].getInt())
      check tokens[0] < tokens[1] and tokens[1] < tokens[2]

suite "Rhizo Session Cryptographic Attestation Suite":

  setup:
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  teardown:
    try: setCurrentDir(initialWorkingDir) except CatchableError: discard
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  test "Ed25519 keygen 0600, signed send/drain, tamper/forgery/spoof rejection, rotation, lock/task verify, and probe":
    sandbox:
      allow(redisPluginInstance)
      let tmpHome = nextTmpDir("crypto_home")
      let saved = saveAndInitCoordEnv(tmpHome, "crypto_project")
      defer:
        restoreCoordEnv(saved)
        removeDir(tmpHome)

      var client = openRedisClient(testRedisUrl)
      defer: (try: client.close() except CatchableError: discard)

      check runRhizoInProcess(["open", "alice", "crypto,test"]).code == 0
      check runRhizoInProcess(["open", "bob", "crypto,test"]).code == 0
      check runRhizoInProcess(["open", "eve", "crypto,test"]).code == 0

      let aliceKeyPath = tmpHome / ".config" / "rhizo" / "sessions" / "alice.key"
      check fileExists(aliceKeyPath)
      let perms = getFilePermissions(aliceKeyPath)
      check fpUserRead in perms
      check fpUserWrite in perms
      when not defined(windows):
        check fpGroupRead notin perms
        check fpOthersRead notin perms

      let alicePub = client.hGet(testPrefix & "agent:alice", "session_pubkey")
      check alicePub.len == 64

      # 1. Valid signed send + drain
      putEnv("RHIZO_AGENT_NAME", "alice")
      check runRhizoInProcess(["send", "--to", "bob", "--subject", "Signed Hello", "--body", "Crypto body"]).code == 0
      let rawSigned = parseJson(client.lIndex(testPrefix & "inbox:bob", 0))
      check rawSigned["session_sig"].getStr().len == 128
      check rawSigned["session_pubkey"].getStr() == alicePub

      let rDrainOk = runRhizoInProcess(["drain", "1", "bob"])
      check rDrainOk.code == 0
      let dOk = parseJson(rDrainOk.outStr.strip())
      check dOk["session_verified"].getBool() == true

      # 2. Corrupt session_sig dropped
      check runRhizoInProcess(["send", "--to", "bob", "--subject", "Corrupt Sig", "--body", "Body"]).code == 0
      var msgCorrupt = parseJson(client.rPop(testPrefix & "inbox:bob"))
      let origSig = msgCorrupt["session_sig"].getStr()
      let badSig = (if origSig[0] != '0': "0" else: "1") & origSig[1..^1]
      msgCorrupt["session_sig"] = %badSig
      discard client.lPush(testPrefix & "inbox:bob", $msgCorrupt)
      let rDropSig = runRhizoInProcess(["drain", "1", "bob"])
      check rDropSig.outStr.strip() in ["", "[]"]

      # 3. Tampered body dropped
      check runRhizoInProcess(["send", "--to", "bob", "--subject", "Tamper", "--body", "Original"]).code == 0
      var msgTamper = parseJson(client.rPop(testPrefix & "inbox:bob"))
      msgTamper["body"] = %"Evil"
      discard client.lPush(testPrefix & "inbox:bob", $msgTamper)
      check runRhizoInProcess(["drain", "1", "bob"]).outStr.strip() in ["", "[]"]

      # 4. Cross-session key spoof rejected
      let evePriv = readFile(tmpHome / ".config" / "rhizo" / "sessions" / "eve.key").strip()
      putEnv("RHIZO_SESSION_PRIVKEY", evePriv)
      check runRhizoInProcess(["send", "--to", "bob", "--subject", "Spoof", "--body", "From Fake Alice"]).code == 0
      delEnv("RHIZO_SESSION_PRIVKEY")
      check runRhizoInProcess(["drain", "1", "bob"]).outStr.strip() in ["", "[]"]

      # 5. Key rotation on re-open
      let priv1 = readFile(aliceKeyPath).strip()
      check runRhizoInProcess(["open", "alice", "crypto,test"]).code == 0
      let alicePub2 = client.hGet(testPrefix & "agent:alice", "session_pubkey")
      let priv2 = readFile(aliceKeyPath).strip()
      check alicePub2 != alicePub
      check priv2 != priv1

      # 6. Lock attestation + verify + forgery detection + unlock cleanup
      putEnv("RHIZO_AGENT_NAME", "alice")
      let rLock = runRhizoInProcess(["lock", "build_mutex", "60"])
      check rLock.code == 0
      check rLock.outStr.contains("LOCKED")
      let rLockVer = runRhizoInProcess(["lock", "verify", "build_mutex"])
      check rLockVer.code == 0
      check rLockVer.outStr.contains("VERIFIED")
      check rLockVer.outStr.contains("alice")

      let lockSigKey = testPrefix & "lock:sig:{crypto_project:build_mutex}"
      client.setk(lockSigKey, "00".repeat(64))
      let rLockForge = runRhizoInProcess(["lock", "verify", "build_mutex"])
      check rLockForge.code != 0
      check rLockForge.outStr.contains("FORGERY")

      check runRhizoInProcess(["unlock", "build_mutex"]).code == 0
      check client.get(lockSigKey) == redisNil

      # 7. Task claim attestation + verify + forgery detection
      check runRhizoInProcess(["open", "worker_1", "worker"]).code == 0
      check runRhizoInProcess(["task", "create", "task_sec_99", "--title", "Security Task"]).code == 0
      putEnv("RHIZO_AGENT_NAME", "worker_1")
      check runRhizoInProcess(["task", "claim", "task_sec_99", "--worker", "worker_1", "--no-vine"]).code == 0
      let rTaskVer = runRhizoInProcess(["task", "verify", "task_sec_99"])
      check rTaskVer.code == 0
      check rTaskVer.outStr.contains("VERIFIED")
      check rTaskVer.outStr.contains("worker_1")

      discard client.hSet(testPrefix & "task:task_sec_99", "claim_sig", "ab".repeat(64))
      let rTaskForge = runRhizoInProcess(["task", "verify", "task_sec_99"])
      check rTaskForge.code != 0
      check rTaskForge.outStr.contains("FORGERY")

      # 8. probe displays session_pubkey in JSON and text
      let rProbeJson = runRhizoInProcess(["probe", "alice", "--json"])
      check rProbeJson.code == 0
      check parseJson(rProbeJson.outStr.strip())["session_pubkey"].getStr() == alicePub2
      let rProbeTxt = runRhizoInProcess(["probe", "alice"])
      check rProbeTxt.code == 0
      check rProbeTxt.outStr.contains("Session Pubkey")
      check rProbeTxt.outStr.contains(alicePub2)

suite "Rhizo Strand Lua Lifecycle & Cluster Slot Affinity Suite":

  setup:
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  teardown:
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  test "scripts/strand.lua full 3-key lifecycle and multi-key cluster hash tags":
    sandbox:
      allow(redisPluginInstance)
      let strandLua = readFile(rhizoRepoRoot / "scripts" / "strand.lua")
      var client = openRedisClient(testRedisUrl)
      defer: (try: client.close() except CatchableError: discard)

      # 1. create + duplicate rejection
      let (ok1, out1) = evalStrandLua(client, strandLua, [
        "create", "task-foo-01", "rhizo", "/workspaces/rhizo/task-foo-01/rhizo",
        "strand/task-foo-01", "main", "commit_abc123", "alice", "pubkey_alice_999",
        "rhizo-orchestrator", "/canonical/rhizo"
      ])
      check ok1
      let d1 = parseJson(out1)
      check d1["status"].getStr() == "OK"
      check d1["state"].getStr() == "PROVISIONED"
      check client.sismember(testPrefix & "strands", "task-foo-01") == 1
      check client.sismember(testPrefix & "strands:state:provisioned", "task-foo-01") == 1

      let (okDup, outDup) = evalStrandLua(client, strandLua, [
        "create", "task-foo-01", "rhizo", "/path", "branch", "main", "c1", "alice"
      ])
      check not okDup
      check outDup.contains("already exists")

      # 2. submit + duplicate submit + self-ratify rejection + heartbeat lease + anti-blink floor + weave gate
      check evalStrandLua(client, strandLua, ["create", "task-blink-01", "rhizo", "/path", "strand/blink-01", "main", "c1", "alice", "pubkey_alice"]).ok
      let (okSub, outSub) = evalStrandLua(client, strandLua, ["submit", "task-blink-01", "gate_token_ok", "alice", "pubkey_alice", "head_commit_789"])
      check okSub
      check parseJson(outSub)["state"].getStr() == "SUBMITTED"
      check not evalStrandLua(client, strandLua, ["submit", "task-blink-01", "gate_token_2", "alice"]).output.contains("OK")
      check not evalStrandLua(client, strandLua, ["weave", "task-blink-01", "merge_sha_1", "orchestrator"]).ok

      discard client.setEx(testPrefix & "heartbeat:alice", 120, "1")
      let rSelf1 = evalStrandLua(client, strandLua, ["ratify", "task-blink-01", "pubkey_alice", "alice", "audit_tok", "Approved", "0"])
      check not rSelf1.ok
      check rSelf1.output.contains("auditor_pubkey cannot match author_pubkey")

      let rSelf2 = evalStrandLua(client, strandLua, ["ratify", "task-blink-01", "pubkey_diff", "alice", "audit_tok", "Approved", "0"])
      check not rSelf2.ok
      check rSelf2.output.contains("auditor cannot match author")

      let rNoHb = evalStrandLua(client, strandLua, ["ratify", "task-blink-01", "pubkey_bob", "bob", "audit_tok", "Approved", "0"])
      check not rNoHb.ok
      check rNoHb.output.contains("does not hold an active heartbeat lease")

      discard client.setEx(testPrefix & "heartbeat:bob", 120, "1")
      let rBlink = evalStrandLua(client, strandLua, ["ratify", "task-blink-01", "pubkey_bob", "bob", "audit_tok", "Approved", "30"])
      check not rBlink.ok
      check rBlink.output.contains("Anti-blink temporal floor violation")

      client.setk(testPrefix & "mock_time_offset", "35")
      let rRat = evalStrandLua(client, strandLua, ["ratify", "task-blink-01", "pubkey_bob", "bob", "audit_token_verified", "Thoroughly tested", "30"])
      check rRat.ok
      check parseJson(rRat.output)["state"].getStr() == "RATIFIED"

      let rWeave = evalStrandLua(client, strandLua, ["weave", "task-blink-01", "merge_sha_final", "orchestrator"])
      check rWeave.ok
      check parseJson(rWeave.output)["state"].getStr() == "WOVEN"

      # 3. reject & resubmit + list & get
      check evalStrandLua(client, strandLua, ["create", "task-rej-01", "rhizo", "/path", "strand/rej-01", "main", "c1", "alice", "pk_a"]).ok
      check evalStrandLua(client, strandLua, ["submit", "task-rej-01", "tok1", "alice", "pk_a"]).ok
      let rRej = evalStrandLua(client, strandLua, ["reject", "task-rej-01", "pk_c", "charlie", "Missing negative controls"])
      check rRej.ok
      check parseJson(rRej.output)["state"].getStr() == "REJECTED"
      check client.sismember(testPrefix & "strands:state:rejected", "task-rej-01") == 1

      let rResub = evalStrandLua(client, strandLua, ["submit", "task-rej-01", "tok2", "alice", "pk_a", "head_v2"])
      check rResub.ok
      check parseJson(rResub.output)["state"].getStr() == "SUBMITTED"

      let rGet = evalStrandLua(client, strandLua, ["get", "task-rej-01"])
      check rGet.ok
      check parseJson(rGet.output)["strand"]["id"].getStr() == "task-rej-01"
      let rListSub = evalStrandLua(client, strandLua, ["list", "submitted"])
      check rListSub.ok
      check parseJson(rListSub.output)["count"].getInt() == 1

      # 4. Multi-key Redis Cluster hash tag slot affinity across Lua scripts
      check readFile(rhizoRepoRoot / "scripts" / "claim.lua").contains("queue:{")
      check readFile(rhizoRepoRoot / "scripts" / "claim.lua").contains("leases:{")
      check readFile(rhizoRepoRoot / "scripts" / "floor.lua").contains("floor:{")
      check readFile(rhizoRepoRoot / "scripts" / "ballot.lua").contains("ballot:{")
      check readFile(rhizoRepoRoot / "scripts" / "workflow.lua").contains("workflow:{")
      check readFile(rhizoRepoRoot / "scripts" / "blackboard.lua").contains("blackboard:{")

suite "Rhizo Task Claim Strand Provisioning Suite":

  setup:
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  teardown:
    try: setCurrentDir(initialWorkingDir) except CatchableError: discard
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  test "mock vine success with spaces, --strand override, --no-vine, and failure rollback":
    sandbox:
      allow(redisPluginInstance)
      allow(nfos.osprocPluginInstance)
      let tmpDir = nextTmpDir("claim_strand")
      let binDir = tmpDir / "bin"
      let homeDir = tmpDir / "home"
      let customWs = tmpDir / "custom spaces workspace" / "task-101" / "proj"
      let explicitDir = tmpDir / "explicit_dir"
      createDir(binDir)
      createDir(homeDir)
      createDir(customWs)
      createDir(explicitDir)

      let saved = saveAndInitCoordEnv(homeDir, "strand_proj")
      let origPath = getEnv("PATH", "")
      putEnv("PATH", binDir & $PathSep & origPath)
      defer:
        putEnv("PATH", origPath)
        restoreCoordEnv(saved)
        try: setCurrentDir(initialWorkingDir) except CatchableError: discard
        removeDir(tmpDir)

      proc writeMockVine(mode: string, customPath: string = "") =
        when defined(windows):
          let escapedPath = customPath.replace("\\", "\\\\")
          var script = "@echo off\r\n"
          if mode == "success":
            script.add("if \"%~1\"==\"new\" (\r\n  echo {\"status\":\"created\",\"task_id\":\"%~2\",\"strand_path\":\"" & escapedPath & "\"}\r\n  exit /b 0\r\n)\r\nexit /b 1\r\n")
          elif mode == "fail":
            script.add("echo Fatal: workspace allocation failed 1>&2\r\nexit /b 1\r\n")
          elif mode == "invalid_json":
            script.add("echo Not JSON at all\r\nexit /b 0\r\n")
          elif mode == "missing_path":
            script.add("echo {\"status\":\"created\"}\r\nexit /b 0\r\n")
          elif mode == "ghost_path":
            script.add("echo {\"status\":\"created\",\"strand_path\":\"" & escapedPath & "\"}\r\nexit /b 0\r\n")
          writeFile(binDir / "vine.cmd", script)
          writeFile(binDir / "vine.bat", script)
        else:
          let vineExe = binDir / "vine"
          var script = "#!/bin/sh\n"
          if mode == "success":
            script.add("if [ \"$1\" = \"new\" ]; then\n  printf '{\"status\":\"created\",\"task_id\":\"%s\",\"strand_path\":\"%s\"}\\n' \"$2\" \"" & customPath & "\"\n  exit 0\nfi\nexit 1\n")
          elif mode == "fail":
            script.add("echo \"Fatal: workspace allocation failed\" >&2\nexit 1\n")
          elif mode == "invalid_json":
            script.add("echo \"Not JSON at all\"\nexit 0\n")
          elif mode == "missing_path":
            script.add("echo '{\"status\":\"created\"}'\nexit 0\n")
          elif mode == "ghost_path":
            script.add("printf '{\"status\":\"created\",\"strand_path\":\"%s\"}\\n' \"" & customPath & "\"\nexit 0\n")
          writeFile(vineExe, script)
          setFilePermissions(vineExe, {fpUserRead, fpUserWrite, fpUserExec})

      setCurrentDir(tmpDir)

      # 1. Mock vine success with spaces in path
      writeMockVine("success", customWs)
      putEnv("RHIZO_AGENT_NAME", "test-worker-1")
      check runRhizoInProcess(["task", "create", "task-101", "--title", "Strand Space Test"]).code == 0
      let rClaim1 = runRhizoInProcess(["task", "claim", "task-101", "--lease", "600"])
      check rClaim1.code == 0
      check rClaim1.outStr.contains(customWs.lastPathPart)
      check rClaim1.errStr.contains("[VINE] Provisioned isolated strand:")
      let g1 = parseJson(runRhizoInProcess(["task", "get", "task-101", "--json"]).outStr.strip())
      check g1["state"].getStr() == "IN_PROGRESS"
      check g1["owner"].getStr() == "test-worker-1"
      check g1["strand_path"].getStr() == expandFilename(customWs)

      # 2. Explicit --strand valid & non-existent negative control
      putEnv("RHIZO_AGENT_NAME", "test-worker-2")
      check runRhizoInProcess(["task", "create", "task-102", "--title", "Override Test"]).code == 0
      check runRhizoInProcess(["task", "claim", "task-102", "--strand", explicitDir]).code == 0
      check parseJson(runRhizoInProcess(["task", "get", "task-102", "--json"]).outStr.strip())["strand_path"].getStr() == expandFilename(explicitDir)

      check runRhizoInProcess(["task", "create", "task-103", "--title", "Bad Strand"]).code == 0
      let rBad = runRhizoInProcess(["task", "claim", "task-103", "--strand", tmpDir / "does_not_exist"])
      check rBad.code != 0
      check rBad.errStr.contains("Specified strand path does not exist on disk")

      # 3. --no-vine
      putEnv("RHIZO_AGENT_NAME", "test-worker-3")
      check runRhizoInProcess(["task", "create", "task-104", "--title", "No Vine"]).code == 0
      let rNoVine = runRhizoInProcess(["task", "claim", "task-104", "--no-vine"])
      check rNoVine.code == 0
      check rNoVine.outStr.contains("CLAIMED task 'task-104' for worker 'test-worker-3'")
      check parseJson(runRhizoInProcess(["task", "get", "task-104", "--json"]).outStr.strip())["strand_path"].getStr() == ""

      # 4. Failure modes leave task QUEUED and unowned
      putEnv("RHIZO_AGENT_NAME", "test-worker-4")
      check runRhizoInProcess(["task", "create", "task-105", "--title", "Fail Test"]).code == 0

      writeMockVine("fail")
      let rFail1 = runRhizoInProcess(["task", "claim", "task-105"])
      check rFail1.code != 0
      check rFail1.errStr.contains("Fatal: workspace allocation failed")
      let gFail = parseJson(runRhizoInProcess(["task", "get", "task-105", "--json"]).outStr.strip())
      check gFail["state"].getStr() == "QUEUED"
      check gFail["owner"].getStr() == ""

      writeMockVine("invalid_json")
      let rFail2 = runRhizoInProcess(["task", "claim", "task-105"])
      check rFail2.code != 0
      check rFail2.errStr.contains("Failed to parse Vine output as JSON")

      writeMockVine("missing_path")
      let rFail3 = runRhizoInProcess(["task", "claim", "task-105"])
      check rFail3.code != 0
      check rFail3.errStr.contains("Vine output missing valid 'strand_path'")

      writeMockVine("ghost_path", tmpDir / "ghost_strand")
      let rFail4 = runRhizoInProcess(["task", "claim", "task-105"])
      check rFail4.code != 0
      check rFail4.errStr.contains("Provisioned strand path does not exist on disk")

suite "Rhizo Coordination Invariants, WISM, Watchdog & Role Separation Suite":

  setup:
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  teardown:
    try: setCurrentDir(initialWorkingDir) except CatchableError: discard
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  test "detachment guard, distributed lock fencing, WISM DAG, ruling ledger, reminders, watchdog, and role separation":
    sandbox:
      allow(redisPluginInstance)
      allow(nfos.osprocPluginInstance)
      let tmpHome = nextTmpDir("coord_home")
      let saved = saveAndInitCoordEnv(tmpHome, "coord_project")
      defer:
        restoreCoordEnv(saved)
        removeDir(tmpHome)

      var client = openRedisClient(testRedisUrl)
      defer: (try: client.close() except CatchableError: discard)

      # 1. Supervision detachment regular-file stdout guard + --force negative control
      when defined(posix):
        let rDetach = runRhizoInProcessFileStdout(["listen", "detached_worker", "2"])
        check rDetach.code != 0
        check rDetach.errStr.contains("Unsupervised detachment detected")
        check rDetach.errStr.contains("breaks supervisor")
        check runRhizoInProcess(["open", "detached_worker", "worker"]).code == 0
        putEnv("RHIZO_AGENT_NAME", "tester")
        check runRhizoInProcess(["send", "--to", "detached_worker", "--from", "tester", "--subject", "init", "--body", "ok"]).code == 0
        check runRhizoInProcessFileStdout(["listen", "detached_worker", "1", "--force"]).code == 0
        delEnv("RHIZO_AGENT_NAME")

      # 2. Distributed lock mutual exclusion, unauthorized unlock, TTL, and monotonic --fencing
      check runRhizoInProcess(["lock"]).errStr.contains("Error: Missing lock name.")
      check runRhizoInProcess(["unlock"]).errStr.contains("Error: Missing lock name.")
      let rL1 = runRhizoInProcess(["--agent-name=agent_lock_owner", "lock", "deploy_mutex_test", "10"])
      check rL1.code == 0
      check rL1.outStr.contains("LOCKED coord_project:deploy_mutex_test by agent_lock_owner")
      check client.ttl(testPrefix & "lock:{coord_project:deploy_mutex_test}") in 7..10

      let rConflict = runRhizoInProcess(["--agent-name=intruder_agent", "lock", "deploy_mutex_test", "10"])
      check rConflict.code == 1
      check rConflict.errStr.contains("already held")
      check runRhizoInProcess(["--agent-name=intruder_agent", "unlock", "deploy_mutex_test"]).code == 1
      check runRhizoInProcess(["--agent-name=agent_lock_owner", "unlock", "deploy_mutex_test"]).code == 0

      let tok1 = parseInt(runRhizoInProcess(["--agent-name=agent_lock_owner", "lock", "deploy_mutex_test", "10", "--fencing", "--raw"]).outStr.strip())
      check runRhizoInProcess(["--agent-name=agent_lock_owner", "unlock", "deploy_mutex_test"]).code == 0
      let tok2 = parseInt(runRhizoInProcess(["--agent-name=agent_lock_owner", "lock", "deploy_mutex_test", "10", "--fencing", "--raw"]).outStr.strip())
      check runRhizoInProcess(["--agent-name=agent_lock_owner", "unlock", "deploy_mutex_test"]).code == 0
      check tok2 == tok1 + 1

      # 3. Scatter reply correlation
      check runRhizoInProcess(["open", "scatter_w1", "team"]).code == 0
      let rSc = runRhizoInProcess([
        "reply", "--to", "lead", "--reply-to", "sc_99999_lead_1234",
        "--from", "scatter_w1", "--subject", "Re: Status", "--body", "Report 100% complete"
      ])
      check rSc.code == 0
      check client.rPop(testPrefix & "inbox:scatter:sc_99999_lead_1234").contains("Report 100% complete")

      # 4. Single-active-lease invariant + WISM DAG dependency unblocking
      check runRhizoInProcess(["task", "create", "wism-task-1", "--title", "Parent Foundation"]).code == 0
      check runRhizoInProcess(["task", "create", "wism-task-2", "--title", "Child Dependent", "--depends-on", "wism-task-1"]).code == 0
      check parseJson(runRhizoInProcess(["task", "get", "wism-task-2", "--json"]).outStr.strip())["state"].getStr() == "BLOCKED"

      let rBlockedClaim = runRhizoInProcess(["task", "claim", "wism-task-2", "--worker", "wism-child", "--no-vine"])
      check rBlockedClaim.code != 0
      check rBlockedClaim.errStr.contains("BLOCKED by incomplete dependencies")

      check runRhizoInProcess(["task", "claim", "wism-task-1", "--worker", "wism-parent", "--lease", "60", "--no-vine"]).code == 0
      check runRhizoInProcess(["task", "create", "wism-extra", "--title", "Extra"]).code == 0
      let rMultiLease = runRhizoInProcess(["task", "claim", "wism-extra", "--worker", "wism-parent", "--no-vine"])
      check rMultiLease.code != 0
      check rMultiLease.errStr.contains("already holds active lease")

      check runRhizoInProcess(["task", "yield", "wism-task-1", "--worker", "wism-parent", "--reason", "handoff"]).code == 0
      check runRhizoInProcess(["task", "claim", "wism-task-1", "--worker", "wism-parent", "--lease", "60", "--no-vine"]).code == 0
      check runRhizoInProcess(["task", "complete", "wism-task-1", "--worker", "wism-parent"]).code == 0

      check runRhizoInProcess(["task", "claim", "wism-task-1", "--worker", "wism-parent", "--no-vine"]).errStr.contains("already COMPLETED")
      check parseJson(runRhizoInProcess(["task", "get", "wism-task-2", "--json"]).outStr.strip())["state"].getStr() == "QUEUED"

      check runRhizoInProcess(["task", "claim", "wism-task-2", "--worker", "wism-child", "--lease", "60", "--no-vine"]).code == 0
      check parseJson(runRhizoInProcess(["task", "current", "wism-child", "--json"]).outStr.strip())["state"].getStr() == "IN_PROGRESS"
      check runRhizoInProcess(["task", "progress", "wism-task-2", "Implemented tests", "--worker", "wism-child"]).code == 0
      check runRhizoInProcess(["task", "gate-report", "wism-task-2", "--gate-token", "GATE-OK-SHA-999", "--worker", "wism-child"]).code == 0
      check parseJson(runRhizoInProcess(["task", "get", "wism-task-2", "--json"]).outStr.strip())["state"].getStr() == "READY_TO_WEAVE"
      check runRhizoInProcess(["task", "complete", "wism-task-2", "--worker", "wism-child"]).code == 0
      check runRhizoInProcess(["task", "current", "wism-child", "--json"]).outStr.strip() == "{}"

      # 5. Operator ruling ledger + audit trail + reminders
      check runRhizoInProcess(["decision", "propose", "dec-arch-01", "--title", "Enable Rift Strands", "--by", "architect"]).code == 0
      let rDec1 = runRhizoInProcess(["decision", "verify", "dec-arch-01"])
      check rDec1.code == 1
      check rDec1.outStr.strip() == "PROPOSED"
      check runRhizoInProcess(["decision", "approve", "dec-arch-01", "--note", "Approved"]).code == 0
      let rDec2 = runRhizoInProcess(["decision", "verify", "dec-arch-01"])
      check rDec2.code == 0
      check rDec2.outStr.strip() == "APPROVED"

      let auditOut = runRhizoInProcess(["audit", "list", "--json"]).outStr
      check auditOut.contains("task.create")
      check auditOut.contains("decision.propose")
      check auditOut.contains("decision.approve")

      let remJson = parseJson(runRhizoInProcess([
        "remind", "add", "Must use vine strands", "--priority", "CRITICAL", "--cadence", "15m", "--ttl", "2h", "--by", "operator"
      ]).outStr.strip())
      check remJson["status"].getStr() == "OK"
      let remId = remJson["id"].getStr()
      let rListRem = parseJson(runRhizoInProcess(["remind", "list", "--for", "worker_alpha", "--json"]).outStr.strip())
      check rListRem["total"].getInt() == 1
      check rListRem["reminders"][0]["due_for_target"].getBool() == true
      check runRhizoInProcess(["remind", "ack", remId, "--agent", "worker_alpha"]).code == 0
      check runRhizoInProcess(["remind", "dismiss", remId]).code == 0
      check parseJson(runRhizoInProcess(["remind", "list", "--json"]).outStr.strip())["total"].getInt() == 0

      # 6. Watchdog liveness states & stepped backoff streaks
      let wdAgent = "watchdog-agent-1"
      let rWdIdle = runRhizoInProcess(["watchdog", "check", "--agent", wdAgent, "--json"])
      check rWdIdle.code == 0
      check parseJson(rWdIdle.outStr.strip())["substatus"].getStr() == "IDLE"

      check runRhizoInProcess(["send", "--to", wdAgent, "--subject", "Wake", "--body", "Work", "--from", "sender-1"]).code == 0
      let rWdUnread = runRhizoInProcess(["watchdog", "check", "--agent", wdAgent, "--json"])
      check rWdUnread.code == 2
      check parseJson(rWdUnread.outStr.strip())["substatus"].getStr() == "UNREAD_MESSAGES"
      check runRhizoInProcess(["drain", "1", wdAgent, "--json"]).code == 0

      check runRhizoInProcess(["enqueue", "render_queue", "--subject", "Frame", "--body", "{\"id\":\"t-100\"}"]).code == 0
      let rWdRearm = runRhizoInProcess(["watchdog", "check", "--agent", wdAgent, "--json"])
      check rWdRearm.code == 2
      check parseJson(rWdRearm.outStr.strip())["substatus"].getStr() == "REARM_LISTENER"
      discard client.del(@[testPrefix & "queue:render_queue", testPrefix & "queue:{render_queue}"])

      check runRhizoInProcess(["watchdog", "check", "--agent", wdAgent, "--expect-listening", "--json"]).code == 2

      discard client.setEx(testPrefix & "listener:" & wdAgent, 60, $(%*{"pid": getCurrentProcessId(), "host": "127.0.0.1", "started": getTime().toUnix()}))
      for (streakIdx, expectedCadence) in [(1, 1800), (2, 3600), (3, 7200)]:
        let rOk = runRhizoInProcess(["watchdog", "check", "--agent", wdAgent, "--json"])
        check rOk.code == 0
        let jOk = parseJson(rOk.outStr.strip())
        check jOk["streak"].getInt() == streakIdx
        check jOk["recommended_cadence"].getInt() == expectedCadence
      let rMax = runRhizoInProcess(["watchdog", "check", "--agent", wdAgent, "--json"])
      check parseJson(rMax.outStr.strip())["substatus"].getStr() == "MAX_STREAK_REACHED"
      check runRhizoInProcess(["watchdog", "reset", "--agent", wdAgent, "--json"]).code == 0

      # 7. Fail-fast identity, strict integer validation, unknown flags (exit 2), aliases & role-as-id separation
      check runRhizoInProcess(["open"]).code == 1
      check runRhizoInProcess(["listen"]).code == 1
      check runRhizoInProcess(["close"]).code == 1
      check runRhizoInProcess(["session", "register", "dummy"]).code == 1
      check runRhizoInProcess(["send", "--bogus-flag-xyz"]).code == 2
      check runRhizoInProcess(["open", "--bogus-flag-xyz"]).code == 2
      check runRhizoInProcess(["task", "claim", "t-1", "--bogus-flag-xyz"]).code == 2

      check runRhizoInProcess(["lock", "test_lock", "not_a_number"]).code == 1
      check runRhizoInProcess(["claim", "test_q", "--lease", "bad_lease"]).code == 1
      check runRhizoInProcess(["scatter", "--targets", "a", "--subject", "s", "--body", "b", "--quorum", "bad_quorum"]).code == 1
      check runRhizoInProcess(["sub", "test_chan", "bad_timeout"]).code == 1

      for badRole in ["architect", "anynng-architect", "myproj-orchestrator", "extrudel-auditor"]:
        let rRole = runRhizoInProcess(["open", badRole])
        check rRole.code == 1
        check rRole.errStr.contains("ERR_ROLE_AS_ID")

      check runRhizoInProcess(["open", "architect", "--allow-role-id"]).code == 0
      putEnv("RHIZO_ALLOW_ROLE_IDS", "1")
      check runRhizoInProcess(["open", "anynng-architect"]).code == 0
      delEnv("RHIZO_ALLOW_ROLE_IDS")

      check runRhizoInProcess(["open", "u-rec-1", "worker"]).code == 0
      check runRhizoInProcess(["open", "u-snd-1", "--role", "architect"]).code == 0
      check runRhizoInProcess(["open", "--id", "u-id-1", "--role", "verifier"]).code == 0
      check client.hGet(testPrefix & "agent:u-snd-1", "role") == "architect"
      check client.hGet(testPrefix & "agent:u-id-1", "role") == "verifier"

      let rAlias = runRhizoInProcess([
        "send", "--recipient", "u-rec-1", "--sender", "u-snd-1",
        "--title", "AliasSubject", "--message", "AliasBody", "--json"
      ])
      check rAlias.code == 0
      check runRhizoInProcess(["drain", "u-rec-1", "--json"]).outStr.contains("AliasBody")

      removeDir(testTmpRoot)
