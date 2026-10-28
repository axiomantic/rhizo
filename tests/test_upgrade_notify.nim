import std/[unittest, os, strutils, json, tables, times, sets]
import config, redis, upgrade_notify, changelog_data

suite "Protocol Upgrade Notification Suite":
  setup:
    var cfg = resolveFullConfig()
    cfg.prefix = "test_upgrade_notify:"
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

  test "Upgrade guidance explicitly forbids npm install, task claiming, and replies":
    let guidance = formatUpgradeGuidance("rhizo", "0.2.28", "0.2.30")
    check "PROTOCOL UPGRADE NOTICE" in guidance
    check "Re-read updated core skill (mandatory)" in guidance
    check "DO NOT run 'npm install'" in guidance
    check "DO NOT claim a task" in guidance
    check "DO NOT reply to this notice" in guidance
    check "0.2.30" in guidance

  test "All active agents with older watermarks receive upgrade notice to re-read skills":
    let agents = ["worker-alpha", "worker-beta", "worker-gamma"]

    for i, a in agents:
      discard client.sAdd(cfg.prefix & "active_agents", a)
      let key = cfg.prefix & "agent:" & a
      discard client.hSet(key, "last_version_notified:rhizo", "0.2.28")
      discard client.hSet(key, "state", "idle")
      discard client.setEx(cfg.prefix & "listener:" & a, 60, "{\"pid\": 1234}")

    let notified = notifyClusterOfUpgrade(cfg, "0.2.30")
    check notified == 3

    # All three workers receive an inbox message so their LLMs wake up and re-read the skill!
    for a in agents:
      let inboxLen = client.lLen(cfg.prefix & "inbox:" & a)
      check inboxLen == 1
      let raw = client.rPop(cfg.prefix & "inbox:" & a)
      check raw != redisNil
      let j = parseJson(raw)
      check j["type"].getStr() == "notice"
      check "PROTOCOL_UPGRADE" in j["subject"].getStr()
      check "DO NOT run 'npm install'" in j["body"].getStr()
      check "Re-read updated core skill" in j["body"].getStr()

      # Watermark is updated
      check client.hGet(cfg.prefix & "agent:" & a, "last_version_notified:rhizo") == "0.2.30"

  test "Calling session (excludeAgent) is skipped and already updated agents are skipped":
    discard client.sAdd(cfg.prefix & "active_agents", "caller-orchestrator")
    discard client.hSet(cfg.prefix & "agent:caller-orchestrator", "last_version_notified:rhizo", "0.2.30")

    discard client.sAdd(cfg.prefix & "active_agents", "already-updated-worker")
    discard client.hSet(cfg.prefix & "agent:already-updated-worker", "last_version_notified:rhizo", "0.2.30")

    discard client.sAdd(cfg.prefix & "active_agents", "lagging-worker")
    discard client.hSet(cfg.prefix & "agent:lagging-worker", "last_version_notified:rhizo", "0.2.28")

    let notified = notifyClusterOfUpgrade(cfg, "0.2.30", excludeAgent = "caller-orchestrator")
    check notified == 1

    check client.lLen(cfg.prefix & "inbox:caller-orchestrator") == 0
    check client.lLen(cfg.prefix & "inbox:already-updated-worker") == 0
    check client.lLen(cfg.prefix & "inbox:lagging-worker") == 1
