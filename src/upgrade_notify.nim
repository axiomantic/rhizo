# src/upgrade_notify.nim
# Protocol Upgrade Notification & Session Watermark Engine for Rhizo.
# Manages session-specific upgrade state in Redis (last_version_notified:rhizo),
# dual-delivery (proactive push to active inboxes + reactive pull CLI rider),
# and changelog diff formatting.

import std/[strutils, os, times, json, openssl, random, net, tables, algorithm, sets]
import config, redis, changelog_data, update

type
  AgentUpgradeCandidate* = object
    name*: string
    systemId*: string
    lastSeen*: int64
    isBusy*: bool
    hasListener*: bool
    lastNotifiedVer*: string

proc HMAC*(evp_md: EVP_MD, key: pointer, key_len: cint, d: cstring, n: csize_t, md: pointer, md_len: ptr cuint): cstring {.cdecl, importc: "HMAC", dynlib: DLLUtilName.}

proc computeHmacSha256*(secret, data: string): string =
  var md: array[64, uint8]
  var mdLen: cuint = 0
  let mdPtr = EVP_sha256()
  let hmacRes = HMAC(mdPtr, secret.cstring, secret.len.cint, data.cstring, data.len.csize_t, md[0].addr, mdLen.addr)
  if hmacRes == nil:
    raise newException(ValueError, "OpenSSL HMAC-SHA256 computation failed")
  result = newStringOfCap(mdLen.int * 2)
  for i in 0 ..< mdLen.int:
    result.add(toHex(md[i].int, 2).toLowerAscii)

proc getSecret*(cfg: RhizoConfig): string =
  if cfg.secret.len > 0:
    return cfg.secret
  let envSecret = getEnv("RHIZO_SECRET", "")
  if envSecret.len > 0:
    return envSecret
  let secretFile = if cfg.secretFile.len > 0:
    cfg.secretFile
  else:
    let secretFileEnv = getEnv("RHIZO_SECRET_FILE", "")
    let home = getHomeDir()
    let rhizoSecret = home / ".config" / "rhizo" / "secret"
    if secretFileEnv.len > 0: secretFileEnv else: rhizoSecret
  if fileExists(secretFile):
    try:
      return readFile(secretFile).strip()
    except CatchableError:
      discard
  return ""

proc openRedisClient*(redisUrl: string): Redis =
  let parsed = parseRedisUrl(redisUrl)
  result = open(parsed.host, parsed.port.Port)
  if parsed.password.len > 0:
    result.auth(parsed.password)
  if parsed.db != 0:
    discard result.select(parsed.db)

proc isMachineOutputContext*(rawArgs: seq[string]): bool =
  ## Returns true if current invocation is a machine-parseable, non-interactive,
  ## or completion context where prompt riders and version state advancement MUST NOT occur.
  for a in rawArgs:
    let low = a.toLowerAscii
    if low in ["--json", "-j", "--version", "-v", "--help", "-h", "help", "version", "ping"]:
      return true
    if low.startsWith("--json=") or low.startsWith("--format=json") or low == "--format=json":
      return true
    if low.startsWith("--complete") or low.startsWith("--status=complete"):
      return true
    if low in ["--compgen", "--bash-completion", "--zsh-completion"]:
      return true
  return false

proc isAutonomousModeActive*(): bool =
  if getEnv("AUTONOMOUS_MODE", "") in ["1", "true", "yes"]:
    return true
  if getEnv("RHIZO_ALLOW_DRIFT", "") in ["1", "true", "yes"]:
    return true
  if getEnv("RHIZO_TEST", "") in ["1", "true", "yes"]:
    return true
  if fileExists(".autonomous"):
    return true
  return false

proc notifyClusterOfUpgrade*(
  cfg: RhizoConfig,
  currentVer: string,
  force: bool = false,
  excludeAgent: string = ""
): int =
  ## Proactive Push: Notifies AT MOST ONE worker per system/machine (the most recently
  ## active, available idle worker), and advances session watermarks silently for all
  ## other workers on that system to eliminate multi-agent wakeup thrashes.
  ## Returns number of agents notified.
  var notifiedCount = 0
  var client: Redis
  try:
    client = openRedisClient(cfg.redisUrl)
  except CatchableError:
    return 0

  defer:
    try: client.close() except CatchableError: discard

  let activeAgents = try: client.sMembers(cfg.prefix & "active_agents") except CatchableError: @[]
  if activeAgents.len == 0:
    return 0

  let nowIso = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let nowSec = getTime().toUnix()
  let secret = getSecret(cfg)
  let normExclude = excludeAgent.toLowerAscii.strip()
  let myMid = getMachineId()

  # 1. Collect metadata for all active agents and group by systemId
  var agentsBySystem = initTable[string, seq[AgentUpgradeCandidate]]()
  var systemsAlreadyUpgraded = initHashSet[string]()

  for agent in activeAgents:
    let agentName = agent.toLowerAscii.strip()
    if agentName.len == 0: continue

    let agentKey = cfg.prefix & "agent:" & agentName
    var lastNotifiedVer = ""
    var mid = ""
    var host = ""
    var lastSeen: int64 = 0
    var isBusy = false
    var hasListener = false

    try:
      let meta = client.hMGet(agentKey, @["last_version_notified:rhizo", "machine_id", "host", "last_seen", "state", "current_task"])
      if meta.len >= 1 and meta[0] != redisNil: lastNotifiedVer = meta[0].strip()
      if meta.len >= 2 and meta[1] != redisNil: mid = meta[1].strip()
      if meta.len >= 3 and meta[2] != redisNil: host = meta[2].strip()
      if meta.len >= 4 and meta[3] != redisNil:
        try: lastSeen = parseBiggestInt(meta[3].strip()) except CatchableError: lastSeen = 0
      if meta.len >= 5 and meta[4] != redisNil:
        let st = meta[4].toUpperAscii()
        if st.startsWith("BUSY") or st.contains("BUSY"): isBusy = true
      if meta.len >= 6 and meta[5] != redisNil and meta[5].strip().len > 0:
        isBusy = true
    except CatchableError:
      discard

    # Check listener key
    let listenerKey = cfg.prefix & "listener:" & agentName
    let listenerVal = try: client.get(listenerKey) except CatchableError: redisNil
    if listenerVal != redisNil and listenerVal.len > 0:
      hasListener = true
      if mid.len == 0 or host.len == 0:
        try:
          let lnode = parseJson(listenerVal)
          if mid.len == 0: mid = lnode.getOrDefault("machine_id").getStr("")
          if host.len == 0: host = lnode.getOrDefault("host").getStr("")
        except CatchableError:
          discard

    let sysId = if mid.len > 0: mid elif host.len > 0: host else: myMid

    # If this agent is the excluded caller (e.g. caller who ran the command or whose session was already updated):
    if normExclude.len > 0 and agentName == normExclude:
      # If caller's watermark is already at currentVer, this system has already been upgraded!
      if lastNotifiedVer == currentVer:
        systemsAlreadyUpgraded.incl(sysId)
      continue

    # If this agent already has currentVer, record that this system is already upgraded
    if lastNotifiedVer == currentVer and not force:
      systemsAlreadyUpgraded.incl(sysId)

    let candidate = AgentUpgradeCandidate(
      name: agentName,
      systemId: sysId,
      lastSeen: lastSeen,
      isBusy: isBusy,
      hasListener: hasListener,
      lastNotifiedVer: lastNotifiedVer
    )

    if not agentsBySystem.hasKey(sysId):
      agentsBySystem[sysId] = @[]
    agentsBySystem[sysId].add(candidate)

  # 2. For each system, notify AT MOST ONE worker (the most recently active one),
  # and advance watermarks silently for all others on that system.
  for sysId, candidates in agentsBySystem:
    # If this system is already marked as upgraded (e.g. caller or a worker already has currentVer),
    # advance any lagging workers on this system silently without spamming their inboxes or waking them.
    if systemsAlreadyUpgraded.contains(sysId) and not force:
      for c in candidates:
        if c.lastNotifiedVer != currentVer:
          let agentKey = cfg.prefix & "agent:" & c.name
          try:
            discard client.hSet(agentKey, "last_version_notified:rhizo", currentVer)
            discard client.hSet(agentKey, "last_version_notified_at:rhizo", nowIso)
          except CatchableError: discard
      continue

    # Filter candidates that actually need notification
    var unnotified: seq[AgentUpgradeCandidate] = @[]
    for c in candidates:
      let needsNotify = force or (c.lastNotifiedVer.len == 0) or
                        (c.lastNotifiedVer != currentVer and isNewerSemver(currentVer, c.lastNotifiedVer))
      if needsNotify:
        unnotified.add(c)

    if unnotified.len == 0:
      continue

    # Sort candidates by:
    # 1. Not busy first (prefer idle worker over busy worker)
    # 2. Has listener first (prefer actively listening process over detached)
    # 3. Last seen descending (most recently active worker first)
    sort(unnotified, proc(a, b: AgentUpgradeCandidate): int =
      if a.isBusy != b.isBusy:
        return if not a.isBusy: -1 else: 1
      if a.hasListener != b.hasListener:
        return if a.hasListener: -1 else: 1
      if a.lastSeen != b.lastSeen:
        return if a.lastSeen > b.lastSeen: -1 else: 1
      return cmp(a.name, b.name)
    )

    # Pick the top candidate: the most recently active, available worker on this system!
    let target = unnotified[0]

    # Deliver notification message to the chosen target worker
    let fromVer = target.lastNotifiedVer
    let guidanceBody = formatUpgradeGuidance("rhizo", fromVer, currentVer)
    let subject = "PROTOCOL_UPGRADE: rhizo " & (if fromVer.len > 0: fromVer else: "unrecorded") & " -> " & currentVer
    let msgId = "msg_upgrade_" & $nowSec & "_" & target.name & "_" & $rand(1000..9999)

    let canonical = msgId & "|system:upgrade|" & target.name & "|notice|" & subject & "|" & guidanceBody & "|" & nowIso
    let sig = try: computeHmacSha256(secret, canonical) except Exception: ""

    var msgObj = newJObject()
    msgObj["id"] = %msgId
    msgObj["from"] = %"system:upgrade"
    msgObj["to"] = %target.name
    msgObj["type"] = %"notice"
    msgObj["urgency"] = %"soon"
    msgObj["subject"] = %subject
    msgObj["body"] = %guidanceBody
    msgObj["timestamp"] = %nowIso
    msgObj["sig"] = %sig
    msgObj["encrypted"] = %false

    let msgJson = $msgObj
    let targetInboxKey = cfg.prefix & "inbox:" & target.name
    let targetChanKey = cfg.prefix & "channel:" & target.name
    let targetAgentKey = cfg.prefix & "agent:" & target.name

    try:
      discard client.lPush(targetInboxKey, msgJson)
      discard client.publish(targetChanKey, msgJson)
      discard client.hSet(targetAgentKey, "last_version_notified:rhizo", currentVer)
      discard client.hSet(targetAgentKey, "last_version_notified_at:rhizo", nowIso)
      inc notifiedCount
    except CatchableError:
      discard

    # For all OTHER workers on this system, advance their watermark silently
    # so they are marked as current and will NOT wake up or thrash tokens!
    for i in 1 ..< unnotified.len:
      let other = unnotified[i]
      let otherAgentKey = cfg.prefix & "agent:" & other.name
      try:
        discard client.hSet(otherAgentKey, "last_version_notified:rhizo", currentVer)
        discard client.hSet(otherAgentKey, "last_version_notified_at:rhizo", nowIso)
      except CatchableError:
        discard

  return notifiedCount

proc checkAndEmitPullUpgradeRider*(
  cfg: RhizoConfig,
  callerAgent: string,
  currentVer: string,
  rawArgs: seq[string] = @[]
): bool =
  ## Reactive Pull: For interactive CLI commands (rhizo claim, send, reply, inbox),
  ## inspects caller's session watermark and emits a structured upgrade rider if unnotified.
  ## Advances last_version_notified:rhizo in Redis only upon actual emission.
  if callerAgent.len == 0 or isMachineOutputContext(rawArgs) or isAutonomousModeActive():
    return false

  var client: Redis
  try:
    client = openRedisClient(cfg.redisUrl)
  except CatchableError:
    return false

  defer:
    try: client.close() except CatchableError: discard

  let normCaller = callerAgent.toLowerAscii.strip()
  let agentKey = cfg.prefix & "agent:" & normCaller

  let lastNotifiedVer = try:
    let v = client.hGet(agentKey, "last_version_notified:rhizo")
    if v != redisNil: v.strip() else: ""
  except CatchableError: ""

  let needsNotify = (lastNotifiedVer.len == 0) or (lastNotifiedVer != currentVer and isNewerSemver(currentVer, lastNotifiedVer))
  if not needsNotify:
    return false

  let fromVer = lastNotifiedVer
  let guidance = formatUpgradeGuidance("rhizo", fromVer, currentVer)
  let nowIso = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

  # Emit structured rider to stderr
  stderr.writeLine("")
  stderr.writeLine("<!-- RHIZO_PROTOCOL_UPGRADE_RIDER -->")
  stderr.writeLine(guidance)
  stderr.writeLine("<!-- END_RHIZO_PROTOCOL_UPGRADE_RIDER -->")
  stderr.writeLine("")

  # Advance session watermark
  try:
    discard client.hSet(agentKey, "last_version_notified:rhizo", currentVer)
    discard client.hSet(agentKey, "last_version_notified_at:rhizo", nowIso)
  except CatchableError:
    discard

  return true
