import std/[unittest, os, strutils, json, tables, times, algorithm, sets]
import config, redis, upgrade_notify

suite "Upgrade Notification System Throttling":
  setup:
    var cfg = resolveFullConfig()
    cfg.prefix = "test_upgrade_throttling:"
    var client = openRedisClient(cfg.redisUrl)

    # Clean up any test keys
    let testKeys = client.keys(cfg.prefix & "*")
    if testKeys.len > 0:
      discard client.del(testKeys)

  teardown:
    let testKeys = client.keys(cfg.prefix & "*")
    if testKeys.len > 0:
      discard client.del(testKeys)
    try: client.close() except CatchableError: discard

  test "Candidate sorting prioritizes idle > busy, listener > detached, lastSeen descending":
    var candidates = @[
      AgentUpgradeCandidate(name: "busy-recent", systemId: "sys-1", lastSeen: 1000, isBusy: true, hasListener: true, lastNotifiedVer: "0.2.27"),
      AgentUpgradeCandidate(name: "idle-old", systemId: "sys-1", lastSeen: 100, isBusy: false, hasListener: true, lastNotifiedVer: "0.2.27"),
      AgentUpgradeCandidate(name: "idle-recent", systemId: "sys-1", lastSeen: 500, isBusy: false, hasListener: true, lastNotifiedVer: "0.2.27"),
      AgentUpgradeCandidate(name: "idle-no-listener", systemId: "sys-1", lastSeen: 900, isBusy: false, hasListener: false, lastNotifiedVer: "0.2.27")
    ]

    sort(candidates, proc(a, b: AgentUpgradeCandidate): int =
      if a.isBusy != b.isBusy:
        return if not a.isBusy: -1 else: 1
      if a.hasListener != b.hasListener:
        return if a.hasListener: -1 else: 1
      if a.lastSeen != b.lastSeen:
        return if a.lastSeen > b.lastSeen: -1 else: 1
      return cmp(a.name, b.name)
    )

    # Expected order:
    # 1. idle-recent (idle, hasListener, lastSeen: 500)
    # 2. idle-old (idle, hasListener, lastSeen: 100)
    # 3. idle-no-listener (idle, no listener, lastSeen: 900)
    # 4. busy-recent (busy)
    check candidates[0].name == "idle-recent"
    check candidates[1].name == "idle-old"
    check candidates[2].name == "idle-no-listener"
    check candidates[3].name == "busy-recent"

  test "At most ONE worker per system is notified, others updated silently":
    let agents = ["alpha-worker-1", "alpha-worker-2", "alpha-worker-3"]
    let sysId = "machine-alpha-123"

    for i, a in agents:
      discard client.sAdd(cfg.prefix & "active_agents", a)
      let key = cfg.prefix & "agent:" & a
      discard client.hSet(key, "machine_id", sysId)
      discard client.hSet(key, "host", "alpha.local")
      discard client.hSet(key, "last_version_notified:rhizo", "0.2.27")
      discard client.hSet(key, "last_seen", $(100 + i * 100))
      discard client.hSet(key, "state", "idle")
      discard client.hSet(key, "current_task", "")
      # Add active listener for all
      discard client.setEx(cfg.prefix & "listener:" & a, 60, "{\"pid\": 1234}")

    # alpha-worker-3 has highest last_seen (300)
    let notified = notifyClusterOfUpgrade(cfg, "0.2.28")
    check notified == 1

    # Check inboxes
    let inbox1Len = client.lLen(cfg.prefix & "inbox:alpha-worker-1")
    let inbox2Len = client.lLen(cfg.prefix & "inbox:alpha-worker-2")
    let inbox3Len = client.lLen(cfg.prefix & "inbox:alpha-worker-3")

    check inbox1Len == 0
    check inbox2Len == 0
    check inbox3Len == 1

    # Verify message payload delivered to alpha-worker-3 has type "notice"
    let msgRaw = client.rPop(cfg.prefix & "inbox:alpha-worker-3")
    check msgRaw != redisNil
    let msgJson = parseJson(msgRaw)
    check msgJson["type"].getStr() == "notice"
    check "PROTOCOL_UPGRADE" in msgJson["subject"].getStr()

    # All three workers MUST have their session watermarks advanced to 0.2.28!
    for a in agents:
      let v = client.hGet(cfg.prefix & "agent:" & a, "last_version_notified:rhizo")
      check v == "0.2.28"

  test "Multiple systems each get exactly one notification":
    # 2 agents on sys-1, 2 agents on sys-2
    let sys1Agents = ["node1-a", "node1-b"]
    let sys2Agents = ["node2-a", "node2-b"]

    for i, a in sys1Agents:
      discard client.sAdd(cfg.prefix & "active_agents", a)
      let key = cfg.prefix & "agent:" & a
      discard client.hSet(key, "machine_id", "sys-1")
      discard client.hSet(key, "last_version_notified:rhizo", "0.2.27")
      discard client.hSet(key, "last_seen", $(100 + i * 50))
      discard client.hSet(key, "state", "idle")

    for i, a in sys2Agents:
      discard client.sAdd(cfg.prefix & "active_agents", a)
      let key = cfg.prefix & "agent:" & a
      discard client.hSet(key, "machine_id", "sys-2")
      discard client.hSet(key, "last_version_notified:rhizo", "0.2.27")
      discard client.hSet(key, "last_seen", $(200 + i * 50))
      discard client.hSet(key, "state", "idle")

    let notified = notifyClusterOfUpgrade(cfg, "0.2.28")
    check notified == 2

    # Exactly 1 on sys-1 (node1-b with higher last_seen)
    check client.lLen(cfg.prefix & "inbox:node1-a") == 0
    check client.lLen(cfg.prefix & "inbox:node1-b") == 1

    # Exactly 1 on sys-2 (node2-b with higher last_seen)
    check client.lLen(cfg.prefix & "inbox:node2-a") == 0
    check client.lLen(cfg.prefix & "inbox:node2-b") == 1

    # All 4 watermarks updated
    for a in sys1Agents:
      check client.hGet(cfg.prefix & "agent:" & a, "last_version_notified:rhizo") == "0.2.28"
    for a in sys2Agents:
      check client.hGet(cfg.prefix & "agent:" & a, "last_version_notified:rhizo") == "0.2.28"

  test "Caller already on currentVer silences all other workers on caller system":
    let callerMid = getMachineId()
    let callerAgent = "caller-orchestrator"
    let localWorker = "local-worker-1"

    discard client.sAdd(cfg.prefix & "active_agents", callerAgent)
    discard client.hSet(cfg.prefix & "agent:" & callerAgent, "machine_id", callerMid)
    discard client.hSet(cfg.prefix & "agent:" & callerAgent, "last_version_notified:rhizo", "0.2.28")

    discard client.sAdd(cfg.prefix & "active_agents", localWorker)
    discard client.hSet(cfg.prefix & "agent:" & localWorker, "machine_id", callerMid)
    discard client.hSet(cfg.prefix & "agent:" & localWorker, "last_version_notified:rhizo", "0.2.27")

    # When caller invokes notifyClusterOfUpgrade with excludeAgent = callerAgent
    let notified = notifyClusterOfUpgrade(cfg, "0.2.28", excludeAgent = callerAgent)

    # 0 notifications sent because caller's machine was already upgraded!
    check notified == 0
    check client.lLen(cfg.prefix & "inbox:" & localWorker) == 0

    # But localWorker's watermark was updated silently to 0.2.28!
    check client.hGet(cfg.prefix & "agent:" & localWorker, "last_version_notified:rhizo") == "0.2.28"
