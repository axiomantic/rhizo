# src/upgrade_notify.nim
# Protocol Upgrade Notification & Session Watermark Engine for Rhizo.
# Manages session-specific upgrade state in Redis (last_version_notified:rhizo),
# dual-delivery (proactive push to active inboxes + reactive pull CLI rider),
# and changelog diff formatting.

import std/[strutils, os, times, json, openssl, random, net]
import config, redis, changelog_data, update

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
  ## Proactive Push: Notifies all active sessions whose watermark is older than currentVer
  ## so each session's LLM re-reads the updated skill and re-arms its listener.
  ## Explicitly instructs sessions NOT to run npm install or claim tasks.
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

  for agent in activeAgents:
    let agentName = agent.toLowerAscii.strip()
    if agentName.len == 0 or (normExclude.len > 0 and agentName == normExclude): continue

    let agentKey = cfg.prefix & "agent:" & agentName
    let lastNotifiedVer = try:
      let v = client.hGet(agentKey, "last_version_notified:rhizo")
      if v != redisNil: v.strip() else: ""
    except CatchableError: ""

    let needsNotify = force or (lastNotifiedVer.len == 0) or
                      (lastNotifiedVer != currentVer and isNewerSemver(currentVer, lastNotifiedVer))
    if not needsNotify:
      continue

    # Compute changelog diff and upgrade body
    let fromVer = lastNotifiedVer
    let guidanceBody = formatUpgradeGuidance("rhizo", fromVer, currentVer)
    let subject = "PROTOCOL_UPGRADE: rhizo " & (if fromVer.len > 0: fromVer else: "unrecorded") & " -> " & currentVer
    let msgId = "msg_upgrade_" & $nowSec & "_" & agentName & "_" & $rand(1000..9999)

    # Construct and sign notice
    let canonical = msgId & "|system:upgrade|" & agentName & "|notice|" & subject & "|" & guidanceBody & "|" & nowIso
    let sig = try: computeHmacSha256(secret, canonical) except Exception: ""

    var msgObj = newJObject()
    msgObj["id"] = %msgId
    msgObj["from"] = %"system:upgrade"
    msgObj["to"] = %agentName
    msgObj["type"] = %"notice"
    msgObj["urgency"] = %"soon"
    msgObj["subject"] = %subject
    msgObj["body"] = %guidanceBody
    msgObj["timestamp"] = %nowIso
    msgObj["sig"] = %sig
    msgObj["encrypted"] = %false

    let msgJson = $msgObj
    let inboxKey = cfg.prefix & "inbox:" & agentName
    let chanKey = cfg.prefix & "channel:" & agentName

    try:
      # Push to inbox (FIFO)
      discard client.lPush(inboxKey, msgJson)
      # Wake blocking listeners
      discard client.publish(chanKey, msgJson)
      # Atomically update session watermark in Redis
      discard client.hSet(agentKey, "last_version_notified:rhizo", currentVer)
      discard client.hSet(agentKey, "last_version_notified_at:rhizo", nowIso)
      inc notifiedCount
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
