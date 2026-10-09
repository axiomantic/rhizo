# src/rhizo.nim
# High-performance, single-binary inter-assistant communication bus over Redis.
# Embeds Lua scripts at compile time and utilizes EVALSHA caching with automatic EVAL fallback.

import std/[
  os, osproc, strutils, json, openssl, sha1, terminal,
  times, random, options, base64, tables, sets, nativesockets
]
when defined(posix):
  import posix
import config, redis, guide, routing, lexicon, std/[net, asyncdispatch]

proc isPidAlive*(pid: int): bool =
  if pid <= 0: return false
  when defined(posix):
    if kill(Pid(pid), 0) == 0:
      return true
    return errno == EPERM
  elif defined(windows):
    let (outp, code) = execCmdEx("tasklist /FI \"PID eq " & $pid & "\" /NH")
    return code == 0 and $pid in outp
  else:
    return true

proc getHostNameStr*(): string =
  try:
    let h = getHostName()
    if h.len > 0: return h
  except Exception:
    discard
  return getEnv("RHIZO_HOSTNAME", getEnv("HOSTNAME", getEnv("COMPUTERNAME", "localhost")))

# OpenSSL C-bindings for native cryptographic operations
type
  EVP_CIPHER_CTX = pointer
  EVP_CIPHER = pointer

proc HMAC*(evp_md: EVP_MD, key: pointer, key_len: cint, d: cstring, n: csize_t, md: pointer, md_len: ptr cuint): cstring {.cdecl, importc: "HMAC", dynlib: DLLUtilName.}
proc CRYPTO_memcmp*(a: pointer, b: pointer, len: csize_t): cint {.cdecl, importc: "CRYPTO_memcmp", dynlib: DLLUtilName.}
proc RAND_bytes*(buf: pointer, num: cint): cint {.cdecl, importc: "RAND_bytes", dynlib: DLLUtilName.}

proc EVP_CIPHER_CTX_new*(): EVP_CIPHER_CTX {.cdecl, importc: "EVP_CIPHER_CTX_new", dynlib: DLLUtilName.}
proc EVP_CIPHER_CTX_free*(ctx: EVP_CIPHER_CTX) {.cdecl, importc: "EVP_CIPHER_CTX_free", dynlib: DLLUtilName.}
proc EVP_aes_256_cbc*(): EVP_CIPHER {.cdecl, importc: "EVP_aes_256_cbc", dynlib: DLLUtilName.}

proc EVP_EncryptInit_ex*(ctx: EVP_CIPHER_CTX, cipher: EVP_CIPHER, impl: pointer, key: pointer, iv: pointer): cint {.cdecl, importc: "EVP_EncryptInit_ex", dynlib: DLLUtilName.}
proc EVP_EncryptUpdate*(ctx: EVP_CIPHER_CTX, outbuf: pointer, outlen: ptr cint, inbuf: pointer, inlen: cint): cint {.cdecl, importc: "EVP_EncryptUpdate", dynlib: DLLUtilName.}
proc EVP_EncryptFinal_ex*(ctx: EVP_CIPHER_CTX, outbuf: pointer, outlen: ptr cint): cint {.cdecl, importc: "EVP_EncryptFinal_ex", dynlib: DLLUtilName.}

proc EVP_DecryptInit_ex*(ctx: EVP_CIPHER_CTX, cipher: EVP_CIPHER, impl: pointer, key: pointer, iv: pointer): cint {.cdecl, importc: "EVP_DecryptInit_ex", dynlib: DLLUtilName.}
proc EVP_DecryptUpdate*(ctx: EVP_CIPHER_CTX, outbuf: pointer, outlen: ptr cint, inbuf: pointer, inlen: cint): cint {.cdecl, importc: "EVP_DecryptUpdate", dynlib: DLLUtilName.}
proc EVP_DecryptFinal_ex*(ctx: EVP_CIPHER_CTX, outbuf: pointer, outlen: ptr cint): cint {.cdecl, importc: "EVP_DecryptFinal_ex", dynlib: DLLUtilName.}

proc PKCS5_PBKDF2_HMAC*(pass: cstring, passlen: cint, salt: pointer, saltlen: cint, iter: cint, digest: EVP_MD, keylen: cint, outbuf: pointer): cint {.cdecl, importc: "PKCS5_PBKDF2_HMAC", dynlib: DLLUtilName.}

# Compile-time embedded Lua scripts
const
  registerLua*   = staticRead("../scripts/register.lua")
  sendO2oLua*    = staticRead("../scripts/send_o2o.lua")
  multicastLua*  = staticRead("../scripts/multicast.lua")
  directoryLua*  = staticRead("../scripts/directory.lua")
  drainLua*      = staticRead("../scripts/drain.lua")
  tagLua*        = staticRead("../scripts/tag.lua")
  unregisterLua* = staticRead("../scripts/unregister.lua")
  statusLua*     = staticRead("../scripts/status.lua")
  lockLua*       = staticRead("../scripts/lock.lua")
  unlockLua*     = staticRead("../scripts/unlock.lua")
  enqueueLua*    = staticRead("../scripts/enqueue.lua")
  scatterLua*    = staticRead("../scripts/scatter.lua")
  claimLua*      = staticRead("../scripts/claim.lua")
  claimRenewLua* = staticRead("../scripts/claim_renew.lua")
  ackLua*        = staticRead("../scripts/ack.lua")
  blackboardLua* = staticRead("../scripts/blackboard.lua")
  floorLua*      = staticRead("../scripts/floor.lua")
  cancelLua*     = staticRead("../scripts/cancel.lua")
  ballotLua*     = staticRead("../scripts/ballot.lua")
  leaderLua*     = staticRead("../scripts/leader.lua")
  workflowLua*   = staticRead("../scripts/workflow.lua")
  sweepLua*      = staticRead("../scripts/sweep.lua")
  reserveNameLua* = staticRead("../scripts/reserve_name.lua")
  resetLua*      = staticRead("../scripts/reset.lua")
  taskLua*       = staticRead("../scripts/task.lua")
  decisionLua*   = staticRead("../scripts/decision.lua")
  reminderLua*   = staticRead("../scripts/reminder.lua")
  rerouteLua*    = staticRead("../scripts/reroute.lua")
  watchdogInflightLua* = staticRead("../scripts/watchdog_inflight.lua")
  RhizoVersion*  = "0.2.12"

# Cryptographic Helpers
proc computeSha1*(text: string): string =
  ($secureHash(text)).toLowerAscii

# Precomputed SHA1 hashes for Redis EVALSHA caching
let
  registerSha*   = computeSha1(registerLua)
  sendO2oSha*    = computeSha1(sendO2oLua)
  multicastSha*  = computeSha1(multicastLua)
  directorySha*  = computeSha1(directoryLua)
  drainSha*      = computeSha1(drainLua)
  tagSha*        = computeSha1(tagLua)
  unregisterSha* = computeSha1(unregisterLua)
  statusSha*     = computeSha1(statusLua)
  lockSha*       = computeSha1(lockLua)
  unlockSha*     = computeSha1(unlockLua)
  enqueueSha*    = computeSha1(enqueueLua)
  scatterSha*    = computeSha1(scatterLua)
  claimSha*      = computeSha1(claimLua)
  claimRenewSha* = computeSha1(claimRenewLua)
  ackSha*        = computeSha1(ackLua)
  blackboardSha* = computeSha1(blackboardLua)
  floorSha*      = computeSha1(floorLua)
  cancelSha*     = computeSha1(cancelLua)
  ballotSha*     = computeSha1(ballotLua)
  leaderSha*     = computeSha1(leaderLua)
  workflowSha*   = computeSha1(workflowLua)
  sweepSha*      = computeSha1(sweepLua)
  reserveNameSha* = computeSha1(reserveNameLua)
  resetSha*      = computeSha1(resetLua)
  taskSha*       = computeSha1(taskLua)
  decisionSha*   = computeSha1(decisionLua)
  reminderSha*   = computeSha1(reminderLua)
  rerouteSha*    = computeSha1(rerouteLua)
  watchdogInflightSha* = computeSha1(watchdogInflightLua)


proc secureFilePermissions*(path: string) =
  when not defined(windows):
    try:
      setFilePermissions(path, {fpUserRead, fpUserWrite})
    except CatchableError:
      discard

proc setTerminalTitle*(title: string, force: bool = false) =
  try:
    if not force and getEnv("TERM", "") == "dumb": return
    var cleanTitle = ""
    for c in title:
      if c >= ' ' and c != '\x7f': cleanTitle.add(c)
    # Standard ANSI OSC 0 escape sequence: sets both window title and icon/tab name.
    # Write to stderr so stdout remains clean for piping and JSON consumers.
    # Only emit when attached to a TTY (or forced) so captured non-interactive pipes remain 0 bytes.
    if force or isatty(stderr):
      stderr.write("\e]0;" & cleanTitle & "\a")
      stderr.flushFile()
  except CatchableError:
    discard

proc parseRequiredInt*(val, flagName: string): int =
  try:
    return parseInt(val)
  except ValueError:
    stderr.writeLine("Error: Invalid integer for " & flagName & ": '" & val & "'")
    quit(1)

proc sanitizeIdentifier*(raw: string): string =
  var s = raw.strip()
  var changed = true
  while changed and s.len > 0:
    changed = false
    if s.len >= 2:
      if (s.startsWith("\"") and s.endsWith("\"")) or
         (s.startsWith("'") and s.endsWith("'")) or
         (s.startsWith("`") and s.endsWith("`")) or
         (s.startsWith("<") and s.endsWith(">")) or
         (s.startsWith("[") and s.endsWith("]")) or
         (s.startsWith("(") and s.endsWith(")")):
        s = s[1..^2].strip()
        changed = true
        continue

    if s.startsWith("@") or s.startsWith("#"):
      s = s[1..^1].strip()
      changed = true
      continue

    let low = s.toLowerAscii
    var pfxLen = 0
    if low.startsWith("agent:"): pfxLen = 6
    elif low.startsWith("user:"): pfxLen = 5
    elif low.startsWith("bot:"): pfxLen = 4
    elif low.startsWith("inbox:"): pfxLen = 6
    elif low.startsWith("channel:"): pfxLen = 8
    elif low.startsWith("queue:"): pfxLen = 6
    elif low.startsWith("lock:"): pfxLen = 5

    if pfxLen > 0:
      s = s[pfxLen..^1].strip()
      changed = true
      continue

    if s.endsWith(":") or s.endsWith(",") or s.endsWith(";") or s.endsWith("."):
      s = s[0..^2].strip()
      changed = true
      continue

  return s.toLowerAscii

proc currentTaskFilePath*(agentName: string = ""): string =
  let rhizoCfgDir = getHomeDir() / ".config" / "rhizo"
  let cleanName = sanitizeIdentifier(agentName)
  if cleanName.len > 0:
    return rhizoCfgDir / ("current_task_" & cleanName & ".json")
  else:
    return rhizoCfgDir / "current_task.json"

proc getOpenSslExe*(): string =
  let envExe = getEnv("RHIZO_OPENSSL_BIN", getEnv("OPENSSL_BIN", ""))
  if envExe.len > 0 and fileExists(envExe):
    return envExe
  let found = findExe("openssl")
  if found.len > 0:
    return found
  when defined(windows):
    for candidate in [
      r"C:\Program Files\Git\usr\bin\openssl.exe",
      r"C:\Program Files\OpenSSL-Win64\bin\openssl.exe",
      r"C:\OpenSSL-Win64\bin\openssl.exe"
    ]:
      if fileExists(candidate):
        return candidate
  return "openssl"

proc getSecret*(cfg: RhizoConfig = RhizoConfig()): string =
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
    let locSecret = home / ".config" / "rhizo" / "secret"
    let defSecret = if fileExists(rhizoSecret): rhizoSecret elif fileExists(locSecret): locSecret else: rhizoSecret
    if secretFileEnv.len > 0: secretFileEnv else: defSecret
  if fileExists(secretFile):
    return readFile(secretFile).strip()

  createDir(secretFile.splitPath.head)
  var bytes: array[32, uint8]
  discard RAND_bytes(bytes[0].addr, 32)
  var hexSecret = ""
  for b in bytes:
    hexSecret.add(toHex(b.int, 2).toLowerAscii)
  writeFile(secretFile, hexSecret)
  secureFilePermissions(secretFile)
  return hexSecret

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

proc verifyHmac*(secret, data, expectedSig: string): bool =
  if expectedSig.len == 0:
    return false
  let computed = computeHmacSha256(secret, data)
  if computed.len != expectedSig.len:
    return false
  return CRYPTO_memcmp(computed.cstring, expectedSig.cstring, computed.len.csize_t) == 0

proc getOriginHostname*(): string =
  let envH = getEnv("RHIZO_HOSTNAME", "")
  if envH.len > 0: return envH
  var h = ""
  try:
    h = getHostname()
  except:
    discard
  if h.len == 0:
    h = getEnv("HOSTNAME", "")
  return h

proc getPassArg*(cfg: RhizoConfig = RhizoConfig()): string =
  if cfg.secret.len > 0:
    putEnv("RHIZO_SECRET", cfg.secret)
    return "env:RHIZO_SECRET"
  let envSecret = getEnv("RHIZO_SECRET", "")
  if envSecret.len > 0:
    return "env:RHIZO_SECRET"
  let secretFile = if cfg.secretFile.len > 0:
    cfg.secretFile
  else:
    let secretFileEnv = getEnv("RHIZO_SECRET_FILE", "")
    let home = getHomeDir()
    let configDir = home / ".config" / "rhizo"
    if secretFileEnv.len > 0: secretFileEnv else: configDir / "secret"
  if fileExists(secretFile):
    return "file:" & secretFile
  discard getSecret(cfg)
  return "file:" & secretFile

proc encryptAes*(plaintext, secret: string, cfg: RhizoConfig = RhizoConfig()): string =
  var salt: array[8, uint8]
  if RAND_bytes(salt[0].addr, 8) != 1:
    raise newException(ValueError, "Failed to generate cryptographically secure random salt")

  var keyAndIv: array[48, uint8]
  let md = EVP_sha256()
  if PKCS5_PBKDF2_HMAC(secret.cstring, secret.len.cint, salt[0].addr, 8, 10000, md, 48, keyAndIv[0].addr) != 1:
    raise newException(ValueError, "PBKDF2 key derivation failed")

  let keyPtr = keyAndIv[0].addr
  let ivPtr = keyAndIv[32].addr

  let ctx = EVP_CIPHER_CTX_new()
  if ctx == nil:
    raise newException(ValueError, "Failed to create EVP_CIPHER_CTX")
  try:
    if EVP_EncryptInit_ex(ctx, EVP_aes_256_cbc(), nil, keyPtr, ivPtr) != 1:
      raise newException(ValueError, "EVP_EncryptInit_ex failed")

    var cipherBuf = newString(plaintext.len + 32)
    var outLen1: cint = 0
    if EVP_EncryptUpdate(ctx, cipherBuf[0].addr, outLen1.addr, plaintext.cstring, plaintext.len.cint) != 1:
      raise newException(ValueError, "EVP_EncryptUpdate failed")

    var outLen2: cint = 0
    if EVP_EncryptFinal_ex(ctx, cipherBuf[outLen1].addr, outLen2.addr) != 1:
      raise newException(ValueError, "EVP_EncryptFinal_ex failed")

    cipherBuf.setLen(outLen1 + outLen2)

    var rawCombined = "Salted__"
    for b in salt: rawCombined.add(char(b))
    rawCombined.add(cipherBuf)

    return encode(rawCombined)
  finally:
    EVP_CIPHER_CTX_free(ctx)

proc decryptAes*(ciphertext, secret: string, cfg: RhizoConfig = RhizoConfig()): string =
  var raw = ""
  try:
    raw = decode(ciphertext.strip())
  except Exception:
    raise newException(ValueError, "Decryption failed: invalid base64 encoding")

  if raw.len < 16 or not raw.startsWith("Salted__"):
    raise newException(ValueError, "Decryption failed: missing OpenSSL Salted__ header")

  var salt: array[8, uint8]
  for i in 0 ..< 8:
    salt[i] = uint8(raw[8 + i])

  var keyAndIv: array[48, uint8]
  let md = EVP_sha256()
  if PKCS5_PBKDF2_HMAC(secret.cstring, secret.len.cint, salt[0].addr, 8, 10000, md, 48, keyAndIv[0].addr) != 1:
    raise newException(ValueError, "PBKDF2 key derivation failed")

  let keyPtr = keyAndIv[0].addr
  let ivPtr = keyAndIv[32].addr

  let cipherData = raw[16..^1]
  let ctx = EVP_CIPHER_CTX_new()
  if ctx == nil:
    raise newException(ValueError, "Failed to create EVP_CIPHER_CTX")
  try:
    if EVP_DecryptInit_ex(ctx, EVP_aes_256_cbc(), nil, keyPtr, ivPtr) != 1:
      raise newException(ValueError, "EVP_DecryptInit_ex failed")

    var plainBuf = newString(cipherData.len + 32)
    var outLen1: cint = 0
    if EVP_DecryptUpdate(ctx, plainBuf[0].addr, outLen1.addr, cipherData.cstring, cipherData.len.cint) != 1:
      raise newException(ValueError, "EVP_DecryptUpdate failed")

    var outLen2: cint = 0
    if EVP_DecryptFinal_ex(ctx, plainBuf[outLen1].addr, outLen2.addr) != 1:
      raise newException(ValueError, "Decryption failed: bad key or corrupted ciphertext")

    plainBuf.setLen(outLen1 + outLen2)
    return plainBuf
  finally:
    EVP_CIPHER_CTX_free(ctx)

# Configuration Resolution (implemented in src/config.nim)
proc resolveConfig*(cli: CliOverrides = CliOverrides()): RhizoConfig =
  resolveFullConfig(cli)

proc formatRedisValue*(val: RedisValue, cmd: string = ""): string =
  case val.kind
  of vkNil:
    "(nil)"
  of vkStatus, vkString:
    val.strVal
  of vkInteger:
    $val.intVal
  of vkList:
    if cmd.toUpperAscii in ["BRPOP", "BLPOP"] and val.listVal.len >= 2:
      return formatRedisValue(val.listVal[0]) & "\n" & formatRedisValue(val.listVal[1])
    var parts: seq[string] = @[]
    for item in val.listVal:
      parts.add(formatRedisValue(item))
    parts.join("\n")

proc openRedisClient*(redisUrl: string): Redis =
  let parsed = parseRedisUrl(redisUrl)
  result = open(parsed.host, parsed.port.Port)
  if parsed.password.len > 0:
    result.auth(parsed.password)
  if parsed.db != 0:
    discard result.select(parsed.db)

proc connectRedis*(redisUrl: string): Redis =
  try:
    result = openRedisClient(redisUrl)
  except CatchableError as e:
    stderr.writeLine("Redis error: Could not connect to Redis: " & e.msg)
    quit(1)

proc reconnectRedisClientMs*(redisUrl: string, client: var Redis, remainingMs: var int, isForever: bool): bool =
  ## Loops with exponential backoff and full jitter until connection is restored
  ## or until a finite timeout is exhausted. Returns true on successful reconnect,
  ## or false if timeout expired while disconnected.
  randomize()
  if client != nil:
    try: client.close() except CatchableError: discard
    client = nil

  var attempt = 0
  let baseMs = 250
  let capMs = 5000
  let startEpoch = epochTime()
  let initialRemaining = remainingMs

  while isForever or remainingMs > 0:
    let factor = 1 shl min(attempt, 6) # 1, 2, 4, 8, 16, 32, 64
    let maxInterval = min(capMs, baseMs * factor)
    let sleepMs = if maxInterval > baseMs: baseMs + rand(maxInterval - baseMs) else: baseMs + rand(min(100, baseMs))

    if not isForever:
      let elapsedMs = int((epochTime() - startEpoch) * 1000)
      remainingMs = max(0, initialRemaining - elapsedMs)
      if remainingMs <= 0:
        return false

    stderr.writeLine("[RHIZO] Connection severed. Reconnecting (attempt " & $(attempt + 1) & ") in " & $sleepMs & "ms...")
    sleep(sleepMs)

    if not isForever:
      let elapsedMs = int((epochTime() - startEpoch) * 1000)
      remainingMs = max(0, initialRemaining - elapsedMs)
      if remainingMs <= 0:
        return false

    try:
      client = openRedisClient(redisUrl)
      stderr.writeLine("[RHIZO] Connection re-established successfully.")
      return true
    except CatchableError:
      attempt += 1

  return false

proc reconnectRedisClient*(redisUrl: string, client: var Redis, remainingSec: var int, isForever: bool): bool =
  var ms = if isForever: 0 else: remainingSec * 1000
  result = reconnectRedisClientMs(redisUrl, client, ms, isForever)
  if not isForever:
    remainingSec = (ms + 999) div 1000

# Graceful Signal Trapping and Resource Cleanup (TASK-18)
type
  ActiveCleanup = object
    url: string
    key: string

var activeCleanups: seq[ActiveCleanup] = @[]
var isCleaningUp = false

proc registerCleanup*(url, key: string) =
  activeCleanups.add(ActiveCleanup(url: url, key: key))

proc unregisterCleanup*(key: string) =
  for i in countdown(activeCleanups.len - 1, 0):
    if activeCleanups[i].key == key:
      activeCleanups.delete(i)

proc runSignalCleanups*() =
  if isCleaningUp: return
  isCleaningUp = true
  for c in activeCleanups:
    try:
      var client = openRedisClient(c.url)
      defer: (try: client.close() except CatchableError: discard)
      discard client.del(@[c.key])
    except Exception:
      discard

when defined(posix):
  proc handleSignal(sig: cint) {.noconv.} =
    runSignalCleanups()
    quit(128 + int(sig))

  proc installSignalHandlers*() =
    var sa: Sigaction
    sa.sa_handler = handleSignal
    discard sigemptyset(sa.sa_mask)
    sa.sa_flags = 0
    discard sigaction(SIGINT, sa)
    discard sigaction(SIGTERM, sa)
    setControlCHook(proc() {.noconv.} =
      runSignalCleanups()
      quit(130)
    )
else:
  proc installSignalHandlers*() =
    setControlCHook(proc() {.noconv.} =
      runSignalCleanups()
      quit(130)
    )

proc runLuaScript*(redisUrl, scriptText, scriptSha: string, evalArgs: openArray[string]): string =
  var client = connectRedis(redisUrl)
  defer:
    try: client.close() except CatchableError: discard

  var argSeq: seq[string] = @[]
  for a in evalArgs:
    argSeq.add(a)

  try:
    let resp = client.evalSha(scriptSha, @[], argSeq)
    return formatRedisValue(resp)
  except RedisError as e:
    if "NOSCRIPT" in e.msg:
      try:
        let evalResp = client.eval(scriptText, @[], argSeq)
        return formatRedisValue(evalResp)
      except CatchableError as e2:
        stderr.writeLine("Redis error: " & e2.msg)
        quit(1)
    else:
      stderr.writeLine("Redis error: " & e.msg)
      quit(1)
  except CatchableError as e:
    stderr.writeLine("Redis error: " & e.msg)
    quit(1)

# Global Session-to-Agent Mapping
proc sessionsFilePath*(): string =
  let rhizoDir = getHomeDir() / ".config" / "rhizo"
  let rhizoFile = rhizoDir / "sessions.json"
  if fileExists(rhizoFile) or dirExists(rhizoDir):
    return rhizoFile
  let locFile = getHomeDir() / ".config" / "rhizo" / "sessions.json"
  if fileExists(locFile):
    return locFile
  return rhizoFile

proc loadLocalSessionMap*(): JsonNode =
  let p = sessionsFilePath()
  if fileExists(p):
    try:
      let content = readFile(p)
      let parsed = parseJson(content)
      if parsed.kind == JObject:
        return parsed
    except CatchableError:
      discard
  return newJObject()

proc saveLocalSessionMapping*(sessionKey, agentName: string) =
  let p = sessionsFilePath()
  try:
    createDir(p.splitPath.head)
    var m = loadLocalSessionMap()
    var entry = newJObject()
    entry["agent"] = %agentName.toLowerAscii
    entry["updated_at"] = %now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    m[sessionKey] = entry
    writeFile(p, pretty(m) & "\n")
    secureFilePermissions(p)
  except OSError:
    discard

proc removeLocalSessionMapping*(sessionKey: string) =
  let p = sessionsFilePath()
  if fileExists(p):
    try:
      var m = loadLocalSessionMap()
      if m.hasKey(sessionKey):
        m.delete(sessionKey)
        writeFile(p, pretty(m) & "\n")
        secureFilePermissions(p)
    except OSError:
      discard

proc getLocalSessionAgent*(sessionKey: string): string =
  let m = loadLocalSessionMap()
  if m.hasKey(sessionKey):
    let node = m[sessionKey]
    if node.kind == JObject and node.hasKey("agent"):
      return node["agent"].getStr().toLowerAscii
    elif node.kind == JString:
      return node.getStr().toLowerAscii
  return ""

# Redis Session Mapping
proc getRedisSessionMapping*(cfg: RhizoConfig, sessionKey: string): string =
  var client: Redis
  try:
    client = openRedisClient(cfg.redisUrl)
  except CatchableError:
    return ""
  defer:
    try: client.close() except CatchableError: discard
  try:
    let val = client.hGet(cfg.prefix & "sessions", sessionKey)
    if val != redisNil and val.len > 0:
      try:
        let parsed = parseJson(val)
        if parsed.kind == JObject and parsed.hasKey("agent"):
          return parsed["agent"].getStr().toLowerAscii
        elif parsed.kind == JString:
          return parsed.getStr().toLowerAscii
      except CatchableError:
        return val.toLowerAscii
  except CatchableError:
    discard
  return ""

proc setRedisSessionMapping*(cfg: RhizoConfig, sessionKey, agentName: string) =
  var client: Redis
  try:
    client = openRedisClient(cfg.redisUrl)
  except CatchableError:
    return
  defer:
    try: client.close() except CatchableError: discard
  try:
    let normAgent = agentName.toLowerAscii
    var entry = newJObject()
    entry["agent"] = %normAgent
    entry["session_id"] = %sessionKey
    entry["updated_at"] = %now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    discard client.hSet(cfg.prefix & "sessions", sessionKey, $entry)
    discard client.hSet(cfg.prefix & "agent_sessions", normAgent, sessionKey)
  except CatchableError:
    discard

proc removeRedisSessionMapping*(cfg: RhizoConfig, sessionKey: string, agentName: string = "") =
  var client: Redis
  try:
    client = openRedisClient(cfg.redisUrl)
  except CatchableError:
    return
  defer:
    try: client.close() except CatchableError: discard
  try:
    discard client.hDel(cfg.prefix & "sessions", @[sessionKey])
    if agentName.len > 0:
      discard client.hDel(cfg.prefix & "agent_sessions", @[agentName.toLowerAscii])
  except CatchableError:
    discard

# Agent Identity Persistence (User-level fallback for plain shell invocations)
# Note: Workspace-scoped and disk-persisted agent identities are strictly forbidden (GVR-008)
# to prevent cross-agent identity contamination across terminal sessions and workspaces.
# Identity is strictly scoped to the process environment (RHIZO_AGENT_NAME), explicit CLI flags,
# or the harness session ID.
proc currentAgentPath*(): string =
  getHomeDir() / ".config" / "rhizo" / "current_agent"

proc saveCurrentAgent*(name: string) =
  # Deprecated & intentionally disabled (GVR-008). Agent identity is strictly process-scoped.
  # Clean up any lingering legacy file to prevent cross-agent identity contamination.
  try:
    let p = currentAgentPath()
    if fileExists(p):
      removeFile(p)
  except OSError:
    discard

proc loadCurrentAgent*(): string =
  # Deprecated & intentionally disabled (GVR-008). File-persisted identity is prohibited.
  return ""

proc clearCurrentAgent*() =
  try:
    let p = currentAgentPath()
    if fileExists(p):
      removeFile(p)
  except OSError:
    discard


const BareGenericRoles* = [
  "orchestrator", "architect", "auditor", "implementer",
  "worker", "agent", "lead", "reviewer", "tester", "coder", "dev"
]

proc isBareGenericRole*(name: string): bool =
  let lower = name.toLowerAscii
  for r in BareGenericRoles:
    if lower == r: return true
  return false

proc ensureProjectScopedName*(cfg: RhizoConfig, rawName: string): string =
  let norm = sanitizeIdentifier(rawName)
  if norm.len == 0:
    return ""
  if isBareGenericRole(norm):
    let proj = if cfg.project.len > 0 and cfg.project != "default": cfg.project.strip()
               else: getCurrentDir().splitPath.tail
    if proj.len > 0 and not (norm.startsWith(proj & "-") or norm.endsWith("-" & proj)):
      let scoped = sanitizeIdentifier(proj & "-" & norm)
      stderr.writeLine("[NOTICE] Bare generic role '" & norm & "' was automatically scoped to project: @" & scoped)
      return scoped
  return norm

proc getActiveAgentName*(cfg: RhizoConfig, explicitName: string = "", fallbackDefault: bool = false, sessionId: string = "", allowGlobalFallback: bool = false): string =
  if explicitName.len > 0:
    return ensureProjectScopedName(cfg, explicitName)

  # Explicit Session ID resolution (CLI argument --session-id takes precedence over ambient env vars)
  let explicitSid = if sessionId.len > 0: sessionId else: cfg.sessionId
  if explicitSid.len > 0:
    let localAgent = getLocalSessionAgent(explicitSid)
    if localAgent.len > 0:
      return ensureProjectScopedName(cfg, localAgent)
    try:
      let redisAgent = getRedisSessionMapping(cfg, explicitSid)
      if redisAgent.len > 0:
        return ensureProjectScopedName(cfg, redisAgent)
    except CatchableError:
      discard

  if cfg.provenance.hasKey("agent_name") and cfg.provenance["agent_name"].source in {srcCli, srcEnv, srcCustomFile, srcWorkspaceFile, srcUserFile, srcSystemFile}:
    return ensureProjectScopedName(cfg, cfg.agentName)
  let envName = getEnv("RHIZO_AGENT_NAME", getEnv("A2A_NAME", getEnv("MY_NAME", "")))
  if envName.len > 0:
    return ensureProjectScopedName(cfg, envName)

  # Ambient RHIZO_SESSION_ID fallback
  let envSid = getEnv("RHIZO_SESSION_ID", "")
  if envSid.len > 0 and envSid != explicitSid:
    let localAgent = getLocalSessionAgent(envSid)
    if localAgent.len > 0:
      return ensureProjectScopedName(cfg, localAgent)
    try:
      let redisAgent = getRedisSessionMapping(cfg, envSid)
      if redisAgent.len > 0:
        return ensureProjectScopedName(cfg, redisAgent)
    except CatchableError:
      discard

  # Note: Global file fallback (loadCurrentAgent) permanently removed to satisfy GVR-008.

  if fallbackDefault:
    if cfg.agentName.len > 0:
      return ensureProjectScopedName(cfg, cfg.agentName)
    let proj = if cfg.project.len > 0 and cfg.project != "default": cfg.project.strip()
               else: getCurrentDir().splitPath.tail
    return if proj.len > 0: sanitizeIdentifier(proj & "-worker") else: "node-worker"
  return ""

proc getActiveListenerInfo*(cfg: RhizoConfig, name: string): tuple[active: bool, pid: int, host: string] =
  let normName = sanitizeIdentifier(name)
  var client: Redis
  try:
    client = openRedisClient(cfg.redisUrl)
  except CatchableError:
    return (false, 0, "")
  defer:
    try: client.close() except CatchableError: discard

  try:
    let val = client.get(cfg.prefix & "listener:" & normName)
    if val == redisNil or val.len == 0:
      return (false, 0, "")
    let node = parseJson(val)
    let pid = node.getOrDefault("pid").getInt(0)
    let host = node.getOrDefault("host").getStr("")
    let currentHost = getHostNameStr()
    if host == currentHost and pid > 0:
      if not isPidAlive(pid):
        # Stale lock: process is no longer alive on this machine
        discard client.del(@[cfg.prefix & "listener:" & normName])
        return (false, 0, "")
      else:
        return (true, pid, host)
    else:
      return (true, pid, host)
  except CatchableError:
    return (false, 0, "")

proc parseIsoOrUnix*(tsStr: string): int64 =
  if tsStr.len == 0: return 0
  try:
    return parseInt(tsStr)
  except ValueError:
    discard
  try:
    let dt = times.parse(tsStr, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
    return dt.toTime().toUnix()
  except CatchableError:
    discard
  try:
    let dt = times.parse(tsStr, "yyyy-MM-dd'T'HH:mm:sszzz", utc())
    return dt.toTime().toUnix()
  except CatchableError:
    return 0

proc checkSupervisionAttached*(name: string, force: bool = false) =
  if force: return
  when defined(posix):
    var isDetached = false
    var reason = ""
    var st: Stat
    if fstat(cint(1), st) == 0:
      if S_ISREG(st.st_mode):
        isDetached = true
        reason = "stdout is redirected to a regular file (e.g. nohup.out or log redirection)"

    let ppid = getppid()
    if ppid == 1:
      isDetached = true
      reason = "process is orphaned (parent PID is 1 / launchd / init)"
    elif ppid > 1:
      try:
        let (parentCmd, exitCode) = osproc.execCmdEx("ps -p " & $ppid & " -o args=")
        if exitCode == 0:
          let lowerCmd = parentCmd.toLowerAscii
          if (lowerCmd.contains("while ") or lowerCmd.contains("until ")) and (lowerCmd.contains(" do ") or lowerCmd.contains(";do") or lowerCmd.contains("; do") or lowerCmd.contains("\ndo")):
            isDetached = true
            reason = "detected execution inside a bash shell loop ('while' / 'until')"
      except CatchableError:
        discard

    if isDetached:
      if reason.contains("shell loop"):
        stderr.writeLine("Error: 'rhizo listen " & name & "' is running inside a bash loop ('while' / 'until')!")
        stderr.writeLine("Reason: Coding agent harnesses and task tools ONLY receive output when the process finishes.")
        stderr.writeLine("An infinite shell loop prevents the command from returning, trapping payloads inside the subshell")
        stderr.writeLine("transcript and hanging the parent orchestrator indefinitely.")
        stderr.writeLine("")
        stderr.writeLine("Remedy: Run 'rhizo listen " & name & "' as a SINGLE-SHOT command without any shell loop.")
        stderr.writeLine("When a message arrives, the process exits cleanly (code 0) so the harness can wake your agent.")
        stderr.writeLine("If subsequent messages are expected, re-arm 'rhizo listen' in a new task or subsequent turn.")
        stderr.writeLine("If you explicitly require looping for local debugging, pass '--force'.")
      else:
        stderr.writeLine("Error: Unsupervised detachment detected for 'rhizo listen " & name & "'!")
        stderr.writeLine("Reason: " & reason & ".")
        stderr.writeLine("")
        stderr.writeLine("Backgrounding 'rhizo listen' with '&' or redirecting output to a file breaks supervisor")
        stderr.writeLine("contract and will swallow delivered messages. Never run 'nohup rhizo listen &'!")
        stderr.writeLine("")
        stderr.writeLine("Harness-owned alternatives:")
        stderr.writeLine("- OpenCode: Native in-process fiber listens automatically without blocking.")
        stderr.writeLine("- Antigravity: Launch via run_command(CommandLine=\"rhizo listen " & name & "\", IsDaemon=true).")
        stderr.writeLine("- Claude Code / CLI: Run foreground blocking 'rhizo listen " & name & "' inside a background task.")
        stderr.writeLine("- Synchronous: Run 'rhizo listen " & name & "' directly in foreground.")
        stderr.writeLine("If you explicitly require unsupervised execution, pass '--force'.")
      quit(1)

proc parseDurationSec*(s: string): int =
  let trimmed = s.strip().toLowerAscii
  if trimmed.len == 0: return 0
  if trimmed.endsWith("s"):
    return (try: parseInt(trimmed[0..^2]) except ValueError: 0)
  elif trimmed.endsWith("m"):
    return (try: parseInt(trimmed[0..^2]) * 60 except ValueError: 0)
  elif trimmed.endsWith("h"):
    return (try: parseInt(trimmed[0..^2]) * 3600 except ValueError: 0)
  elif trimmed.endsWith("d"):
    return (try: parseInt(trimmed[0..^2]) * 86400 except ValueError: 0)
  else:
    return (try: parseInt(trimmed) except ValueError: 0)

proc doRemind*(cfg: RhizoConfig, action: string, args: openArray[string]): string =
  var evalArgs: seq[string] = @[cfg.prefix, action]
  for a in args: evalArgs.add(a)
  return runLuaScript(cfg.redisUrl, reminderLua, reminderSha, evalArgs)

proc formatRemindersTable*(jsonStr: string): string =
  try:
    let root = parseJson(jsonStr)
    let node = root.getOrDefault("reminders")
    if node == nil or node.kind != JArray or node.len == 0:
      return "No active reminders."
    var rows: seq[(string, string, string, string, string)] = @[]
    for item in node:
      let id = item.getOrDefault("id").getStr("")
      let priority = item.getOrDefault("priority").getStr("NORMAL")
      let scope = item.getOrDefault("scope").getStr("*")
      let ackCount = item.getOrDefault("ack_count").getInt(0)
      let text = item.getOrDefault("text").getStr("")
      rows.add((id, priority, scope, $ackCount, text))
    result = "REMINDER ID     PRIORITY     SCOPE          ACKS    DIRECTIVE / CONSTRAINT\n"
    result.add("--------------------------------------------------------------------------------------\n")
    for (id, prio, sc, acks, txt) in rows:
      result.add(id.alignLeft(16) & prio.alignLeft(13) & sc.alignLeft(15) & acks.alignLeft(8) & txt & "\n")
    result = result.strip()
  except CatchableError:
    return jsonStr

proc evaluatePiggyback*(cfg: RhizoConfig, agentName: string, maxCap: int = 2): JsonNode =
  try:
    let res = runLuaScript(cfg.redisUrl, reminderLua, reminderSha, [cfg.prefix, "evaluate_piggyback", agentName, $maxCap])
    return parseJson(res)
  except CatchableError:
    return newJObject()

proc doRemindTickFallback*(cfg: RhizoConfig): string =
  let res = runLuaScript(cfg.redisUrl, reminderLua, reminderSha, [cfg.prefix, "tick_candidates"])
  let secret = getSecret(cfg)
  var client = connectRedis(cfg.redisUrl)
  defer: (try: client.close() except CatchableError: discard)
  var count = 0
  try:
    let node = parseJson(res)
    let candidates = node.getOrDefault("candidates")
    if candidates != nil and candidates.kind == JArray:
      for c in candidates:
        let toAgent = c.getOrDefault("to").getStr("")
        let remId = c.getOrDefault("rem_id").getStr("")
        let rtext = c.getOrDefault("text").getStr("")
        let prio = c.getOrDefault("priority").getStr("NORMAL")
        let nowSec = getTime().toUnix()
        let msgId = "msg_rem_" & $client.incr(cfg.prefix & "msg_seq")
        let ts = $nowSec
        let subj = "[STANDALONE ADVISORY: " & remId & " (" & prio & ")]"
        let msgType = "reminder"
        let canonical = msgId & "|system:reminder|" & toAgent & "|" & msgType & "|" & subj & "|" & rtext & "|" & ts
        let sig = computeHmacSha256(secret, canonical)
        var env = newJObject()
        env["id"] = %msgId
        env["from"] = %"system:reminder"
        env["to"] = %toAgent
        env["type"] = %msgType
        env["subject"] = %subj
        env["body"] = %rtext
        env["timestamp"] = %ts
        env["sig"] = %sig
        env["reminder_id"] = %remId
        env["priority"] = %prio
        discard client.rPush(cfg.prefix & "inbox:" & toAgent, $env)
        discard client.hSet(cfg.prefix & "agent:" & toAgent & ":reminder_seen", remId, ts)
        inc count
    return $(%*{"dispatched": count})
  except CatchableError as e:
    return $(%*{"dispatched": 0, "error": e.msg})

# Core Operations
proc doRegister*(cfg: RhizoConfig, name, tags: string, ttl: int = -1): string =
  let effectiveTtl = if ttl > 0: ttl elif cfg.heartbeatTtl > 0: cfg.heartbeatTtl else: 150
  return runLuaScript(cfg.redisUrl, registerLua, registerSha, [cfg.prefix, sanitizeIdentifier(name), tags, $effectiveTtl])

proc doCheckInbox*(cfg: RhizoConfig, name: string): int =
  var client = connectRedis(cfg.redisUrl)
  defer:
    try: client.close() except CatchableError: discard
  let inboxKey = cfg.prefix & "inbox:" & sanitizeIdentifier(name)
  try:
    return client.lLen(inboxKey)
  except CatchableError:
    return 0

proc detectHarness*(cfg: RhizoConfig): string =
  let sid = if cfg.sessionId.len > 0: cfg.sessionId else: getEnv("RHIZO_SESSION_ID", "")
  if sid.startsWith("opencode:"): return "opencode"
  if sid.startsWith("pi:"): return "pi"
  if sid.startsWith("claude:"): return "claude"
  if sid.startsWith("codex:"): return "codex"
  if sid.startsWith("agy:"): return "antigravity"
  if sid.startsWith("cursor:"): return "cursor"
  if sid.startsWith("copilot:"): return "copilot"

  if getEnv("OPENCODE_SESSION_ID", "").len > 0: return "opencode"
  if getEnv("PI_SESSION_ID", "").len > 0: return "pi"
  if getEnv("CODEX_SESSION_ID", "").len > 0: return "codex"
  if getEnv("CLAUDE_CODE", "").len > 0 or getEnv("CLAUDE_PROJECT_ROOT", "").len > 0: return "claude"
  if getEnv("ANTIGRAVITY_APP_DIR", "").len > 0: return "antigravity"
  if getEnv("CURSOR_APP", "").len > 0 or getEnv("CURSOR_PROJECT_DIR", "").len > 0: return "cursor"
  if getEnv("GITHUB_COPILOT", "").len > 0: return "copilot"

  return "unknown"

proc doDrain*(cfg: RhizoConfig, name: string, count: int = 50, format: string = "json"): string =
  var client = connectRedis(cfg.redisUrl)
  defer:
    try: client.close() except CatchableError: discard
  var argSeq: seq[string] = @[cfg.prefix, sanitizeIdentifier(name), $count]
  var resp: RedisValue
  try:
    resp = client.evalSha(drainSha, @[], argSeq)
  except RedisError as e:
    if "NOSCRIPT" in e.msg:
      try:
        resp = client.eval(drainLua, @[], argSeq)
      except CatchableError as e2:
        stderr.writeLine("Redis error: " & e2.msg)
        quit(1)
    else:
      stderr.writeLine("Redis error: " & e.msg)
      quit(1)
  except CatchableError as e:
    stderr.writeLine("Redis error: " & e.msg)
    quit(1)

  var rawList: seq[string] = @[]
  if resp.kind == vkList:
    for item in resp.listVal:
      if item.kind in [vkString, vkStatus]:
        rawList.add(item.strVal)

  if format == "raw":
    var rawArr = newJArray()
    for s in rawList:
      try:
        rawArr.add(parseJson(s))
      except CatchableError:
        rawArr.add(%s)
    return $rawArr

  let secret = getSecret(cfg)
  var validMessages: seq[JsonNode] = @[]

  for payloadStr in rawList:
    var parsed: JsonNode
    try:
      parsed = parseJson(payloadStr.strip())
    except JsonParsingError:
      stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping non-JSON payload from inbox")
      continue

    let id = parsed.getOrDefault("id").getStr("")
    let fromAgent = parsed.getOrDefault("from").getStr("")
    let toAgent = parsed.getOrDefault("to").getStr("")
    let msgType = parsed.getOrDefault("type").getStr("")
    let subject = parsed.getOrDefault("subject").getStr("")
    let body = parsed.getOrDefault("body").getStr("")
    let ts = parsed.getOrDefault("timestamp").getStr("")
    let sig = parsed.getOrDefault("sig").getStr("")
    let isEncrypted = parsed.getOrDefault("encrypted").getBool(false)

    # Validate HMAC (accounting for transparent rerouting if present)
    let originalTo = parsed.getOrDefault("original_recipient").getStr(parsed.getOrDefault("rerouted_from").getStr(toAgent))
    let canonical = id & "|" & fromAgent & "|" & originalTo & "|" & msgType & "|" & subject & "|" & body & "|" & ts
    if not verifyHmac(secret, canonical, sig):
      stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping unauthenticated/tampered message (ID: " & id & ")")
      continue

    # Authenticated! Decrypt if required
    if isEncrypted:
      try:
        let decryptedBody = decryptAes(body, secret, cfg)
        parsed["body"] = %decryptedBody
        parsed["encrypted"] = %false
      except ValueError as e:
        stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping corrupted/undecryptable message: " & e.msg & " (ID: " & id & ")")
    let mockOffset = try:
      let v = client.get(cfg.prefix & "mock_time_offset")
      if v != redisNil and v.len > 0: parseInt(v) else: 0
    except CatchableError: 0
    let msgUnix = parseIsoOrUnix(ts)
    if msgUnix > 0:
      let nowSec = getTime().toUnix() + mockOffset
      let elapsedSec = max(0.int64, nowSec - msgUnix)
      let ageHuman = if elapsedSec < 60: $elapsedSec & "s"
                     elif elapsedSec < 3600: $(elapsedSec div 60) & "m"
                     else: $(elapsedSec div 3600) & "h"
      parsed["elapsed_seconds"] = %elapsedSec
      parsed["age_human"] = %ageHuman
      if elapsedSec >= 3600:
        parsed["is_stale"] = %true
        stderr.writeLine("⚠️  [RHIZO WARNING] Stale message drained! Age: " & ageHuman & " (sent at " & ts & ").")
      else:
        parsed["is_stale"] = %false

    validMessages.add(parsed)

  if format == "hook":
    if validMessages.len == 0:
      return ""
    var lines: seq[string] = @[]
    let plural = if validMessages.len == 1: "1 new message" else: $validMessages.len & " new messages"
    lines.add("[RHIZO BUS] " & plural & " received on inbox for '" & name & "':")
    for m in validMessages:
      let fromA = m.getOrDefault("from").getStr("unknown")
      let subj = m.getOrDefault("subject").getStr("")
      let body = m.getOrDefault("body").getStr("")
      let urgency = m.getOrDefault("urgency").getStr("soon")
      let msgType = m.getOrDefault("type").getStr("task")
      let host = m.getOrDefault("host").getStr("")
      var header = "- From @" & fromA
      if host.len > 0: header.add(" [host: " & host & "]")
      if subj.len > 0: header.add(" (subject: \"" & subj & "\")")
      header.add(" [type: " & msgType & ", urgency: " & urgency & "]:")
      lines.add(header)
      lines.add("  " & body.replace("\n", "\n  "))
    if validMessages.len > 0:
      let harness = detectHarness(cfg)
      lines.add("")
      lines.add("[RHIZO NEXT-STEP ACTION]:")
      lines.add("- After completing the task, reply using:")
      lines.add("  rhizo reply --to <sender> --subject \"Re: <subj>\" --body \"<result>\" --reply-to \"<id>\"")
      if harness in ["opencode", "pi"]:
        lines.add("- Note: Extension fiber automatically receives new tasks; DO NOT run a blocking 'rhizo listen'.")
      else:
        lines.add("- If you must immediately await the next task, append --listen:")
        lines.add("  rhizo reply ... --listen")
        if harness == "codex":
          lines.add("- Codex subagents (SKILL.md Step 2b): Re-spawn one-shot listener subagent before concluding turn.")
        elif harness == "antigravity":
          lines.add("- Antigravity (SKILL.md Step 2d): Re-arm reactive listener via run_command or append --listen.")
      lines.add("- If disconnecting or shutting down, unregister cleanly:")
      lines.add("  rhizo close " & name)
      lines.add("- See SKILL.md Step 2 for complete harness-specific integration playbooks.")
    return lines.join("\n")

  if validMessages.len > 0:
    let piggy = evaluatePiggyback(cfg, name, 2)
    let rems = piggy.getOrDefault("reminders")
    if rems != nil and rems.kind == JArray and rems.len > 0:
      for m in validMessages:
        m["reminders"] = rems

  # If caller explicitly asked for 1 message, return single JSON object
  if count == 1:
    if validMessages.len == 1:
      return $validMessages[0]
    else:
      return ""

  # Default for count > 1: return JSON array
  var arr = newJArray()
  for m in validMessages:
    arr.add(m)
  return $arr

proc doUnregister*(cfg: RhizoConfig, name: string): string =
  let normName = name.toLowerAscii
  let saved = loadCurrentAgent()
  if saved.toLowerAscii == normName or normName.len == 0:
    clearCurrentAgent()
  let sid = if cfg.sessionId.len > 0: cfg.sessionId else: getEnv("RHIZO_SESSION_ID", "")
  if sid.len > 0:
    removeLocalSessionMapping(sid)
    removeRedisSessionMapping(cfg, sid, normName)
  try:
    var client = openRedisClient(cfg.redisUrl)
    defer: (try: client.close() except CatchableError: discard)
    discard client.del(@[cfg.prefix & "listener:" & normName])
  except CatchableError:
    discard
  return runLuaScript(cfg.redisUrl, unregisterLua, unregisterSha, [cfg.prefix, normName])

proc cleanupOldTmpFiles*() =
  let tmpDir = getHomeDir() / ".config" / "rhizo" / "tmp"
  if dirExists(tmpDir):
    let nowUnix = getTime().toUnix()
    for kind, path in walkDir(tmpDir):
      if kind == pcFile and path.endsWith(".tmp"):
        try:
          let info = getFileInfo(path)
          if nowUnix - info.lastWriteTime.toUnix() > 3600:
            removeFile(path)
        except OSError:
          discard

proc buildShutdownPayload*(reason: string = "bus shutdown"): string =
  var node = newJObject()
  node["id"] = %("msg_shutdown_" & $getTime().toUnix())
  node["from"] = %"system"
  node["to"] = %"*"
  node["type"] = %"shutdown"
  node["subject"] = %"Shutdown"
  node["body"] = %reason
  node["timestamp"] = %($getTime().toUnix())
  return $node

proc doNuke*(cfg: RhizoConfig, asJson: bool = false): string =
  clearCurrentAgent()
  cleanupOldTmpFiles()
  let shutdownPayload = buildShutdownPayload("rhizo nuke initiated")

  # 1. Notify listeners so BLPOP unblocks immediately
  let notifyRes = runLuaScript(cfg.redisUrl, resetLua, resetSha, [cfg.prefix, "notify", "*", shutdownPayload])
  var closedAgents: seq[string] = @[]
  try:
    let nj = parseJson(notifyRes)
    if nj.hasKey("closed_agents"):
      for a in nj["closed_agents"]:
        closedAgents.add(a.getStr())
  except CatchableError:
    discard

  if closedAgents.len > 0:
    sleep(50)

  # 2. Purge all keys
  let res = runLuaScript(cfg.redisUrl, resetLua, resetSha, [cfg.prefix, "purge", "*", ""])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)

  var deletedCount = 0
  try:
    deletedCount = parseJson(res)["deleted_keys"].getInt()
  except CatchableError:
    discard

  if asJson:
    var j = %*{
      "status": "ok",
      "mode": "nuke",
      "closed_agents": closedAgents,
      "deleted_keys": deletedCount
    }
    return $j
  else:
    return "Nuked namespace '" & cfg.prefix & "': closed " & $closedAgents.len & " agents, deleted " & $deletedCount & " keys."

proc doReset*(cfg: RhizoConfig, optProject: string = "", forceAll: bool = false, asJson: bool = false): string =
  cleanupOldTmpFiles()
  if forceAll:
    return doNuke(cfg, asJson)

  let proj = if optProject.len > 0: optProject.strip().toLowerAscii
             elif cfg.project.len > 0: cfg.project.strip().toLowerAscii
             else: ""

  if proj.len == 0:
    return doNuke(cfg, asJson)

  let saved = loadCurrentAgent()
  if saved.startsWith(proj & "-") or saved == proj:
    clearCurrentAgent()

  let shutdownPayload = buildShutdownPayload("rhizo reset initiated for project " & proj)

  # 1. Notify project listeners so BLPOP unblocks
  let notifyRes = runLuaScript(cfg.redisUrl, resetLua, resetSha, [cfg.prefix, "notify", proj, shutdownPayload])
  var closedAgents: seq[string] = @[]
  try:
    let nj = parseJson(notifyRes)
    if nj.hasKey("closed_agents"):
      for a in nj["closed_agents"]:
        closedAgents.add(a.getStr())
  except CatchableError:
    discard

  if saved.len > 0 and (saved in closedAgents):
    clearCurrentAgent()
    let sid = if cfg.sessionId.len > 0: cfg.sessionId else: getEnv("RHIZO_SESSION_ID", "")
    if sid.len > 0:
      removeLocalSessionMapping(sid)
      removeRedisSessionMapping(cfg, sid, saved)

  if closedAgents.len > 0:
    sleep(50)

  # 2. Purge project keys
  let res = runLuaScript(cfg.redisUrl, resetLua, resetSha, [cfg.prefix, "purge", proj, ""])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)

  var deletedCount = 0
  try:
    deletedCount = parseJson(res)["deleted_keys"].getInt()
  except CatchableError:
    discard

  if asJson:
    var j = %*{
      "status": "ok",
      "mode": "project",
      "project": proj,
      "closed_agents": closedAgents,
      "deleted_keys": deletedCount
    }
    return $j
  else:
    return "Reset project '" & proj & "' in namespace '" & cfg.prefix & "': closed " & $closedAgents.len & " agents, deleted " & $deletedCount & " keys."

proc doTag*(cfg: RhizoConfig, name, action, tags: string): string =
  return runLuaScript(cfg.redisUrl, tagLua, tagSha, [cfg.prefix, name.toLowerAscii, action.toLowerAscii, tags])

proc formatDirectory*(raw: string): string =
  if raw.strip().len == 0:
    return "No agents found."
  var lines = raw.strip().splitLines()
  var rows: seq[(string, string, string, string, string, string)] = @[]
  for line in lines:
    let parts = line.strip().split('|')
    if parts.len >= 3:
      let name = parts[0]
      let isAlive = (parts[1] == "1")
      let tags = parts[2]
      let state = if parts.len > 3 and parts[3].len > 0: parts[3].toUpperAscii else: "IDLE"
      let activity = if parts.len > 4: parts[4].strip() else: ""
      let hasListener = (parts.len > 5 and parts[5] == "1")
      let elapsedSec = if parts.len > 6: (try: parseInt(parts[6].strip()) except ValueError: 0) else: 0

      let statusStr = if isAlive: "ACTIVE"
                      elif elapsedSec < 60: "STALE (" & $elapsedSec & "s)"
                      elif elapsedSec < 3600: "STALE (" & $(elapsedSec div 60) & "m)"
                      else: "STALE (" & $(elapsedSec div 3600) & "h)"

      let listenerStr = if hasListener: "LISTENING"
                        elif isAlive: "DETACHED"
                        else: "NO_LISTENER"

      rows.add((name, statusStr, listenerStr, state, tags, activity))
    elif line.strip().len > 0:
      rows.add((line.strip(), "", "", "", "", ""))

  if rows.len == 0:
    return "No agents found."

  result = "AGENT               STATUS           LISTENER     STATE        TAGS                ACTIVITY\n"
  result.add("------------------------------------------------------------------------------------------------------\n")
  for (name, status, listener, state, tags, activity) in rows:
    result.add(name.alignLeft(20) & status.alignLeft(17) & listener.alignLeft(13) & state.alignLeft(13) & tags.alignLeft(20) & activity & "\n")
  result = result.strip()

proc formatDirectoryJson*(raw: string): string =
  var list = newJArray()
  if raw.strip().len > 0:
    for line in raw.strip().splitLines():
      let parts = line.strip().split('|')
      if parts.len >= 3:
        var obj = newJObject()
        let isAlive = (parts[1] == "1")
        let hasListener = (parts.len > 5 and parts[5] == "1")
        let elapsedSec = if parts.len > 6: (try: parseInt(parts[6].strip()) except ValueError: 0) else: 0

        obj["agent"] = %parts[0]
        obj["status"] = %(if isAlive: "ACTIVE" else: "STALE")
        var tagArr = newJArray()
        if parts[2].len > 0:
          for t in parts[2].split(','):
            let trimmed = t.strip()
            if trimmed.len > 0: tagArr.add(%trimmed)
        obj["tags"] = tagArr
        obj["state"] = %(if parts.len > 3 and parts[3].len > 0: parts[3].toUpperAscii else: "IDLE")
        obj["activity"] = %(if parts.len > 4: parts[4].strip() else: "")
        obj["listener"] = %(if hasListener: "LISTENING" elif isAlive: "DETACHED" else: "NO_LISTENER")
        obj["elapsed_seconds"] = %elapsedSec
        list.add(obj)
  return $list

proc doDirectory*(cfg: RhizoConfig, filterTag: string = "", asJson: bool = false): string =
  let raw = runLuaScript(cfg.redisUrl, directoryLua, directorySha, [cfg.prefix, filterTag.toLowerAscii])
  if asJson:
    return formatDirectoryJson(raw)
  return formatDirectory(raw)

proc doListen*(cfg: RhizoConfig, name: string, timeoutSec: int = -1, notify: bool = false, quiet: bool = false, force: bool = false, continuous: bool = false)
proc doAuditLog*(cfg: RhizoConfig, actor, action, details: string)
proc isCompletionSubject*(subject: string): bool
proc findVineManifestPath*(startDir: string = ""): string
proc checkVineGateInterlock*(taskId: string = "", startDir: string = "", strandPath: string = "", explicitGateToken: string = ""): tuple[passed: bool, token: string, errorMsg: string]
proc doReply*(cfg: RhizoConfig, toAgent, fromAgent, subject, body: string,
             tags: seq[string] = @[], replyTo: string = "", msgId: string = "", customTs: string = "",
             rearmListen: bool = false, listenTimeoutSec: int = -1,
             urgency: string = "soon", format: string = "text", listenAgent: string = "",
             skipGate: bool = false): string
proc doTaskComplete*(cfg: RhizoConfig, taskId: string, worker: string, gateToken: var string,
                     strandPath: string = "", weave: bool = false, skipGate: bool = false): string


proc reserveUniqueName*(cfg: RhizoConfig, optPrefix: string = "", ttlSec: int = 600): tuple[name, prefix, codename: string] =
  randomize()
  let proj = if cfg.project.len > 0 and cfg.project != "default": cfg.project.strip()
             else: getCurrentDir().splitPath.tail
  var pfx = ""
  if optPrefix.len > 0:
    let trimmed = optPrefix.strip()
    if proj.len > 0 and isBareGenericRole(trimmed):
      pfx = proj & "-" & trimmed
    else:
      pfx = trimmed
  elif proj.len > 0:
    pfx = proj
  else:
    pfx = "node"
  if pfx.len == 0:
    pfx = "node"

  let ttl = if ttlSec > 0: ttlSec else: 600

  for attempt in 1 .. 50:
    let idx = rand(CodenameLexicon.low .. CodenameLexicon.high)
    let word = CodenameLexicon[idx]
    let candidate = pfx & "-" & word
    let res = runLuaScript(cfg.redisUrl, reserveNameLua, reserveNameSha, [cfg.prefix, candidate, $ttl])
    if res == "1":
      return (name: candidate, prefix: pfx, codename: word)

  for attempt in 1 .. 25:
    let idx = rand(CodenameLexicon.low .. CodenameLexicon.high)
    let word = CodenameLexicon[idx] & "-" & $rand(10 .. 999)
    let candidate = pfx & "-" & word
    let res = runLuaScript(cfg.redisUrl, reserveNameLua, reserveNameSha, [cfg.prefix, candidate, $ttl])
    if res == "1":
      return (name: candidate, prefix: pfx, codename: word)

  let fallbackWord = "node-" & $getTime().toUnix() & "-" & $rand(100 .. 999)
  let candidate = pfx & "-" & fallbackWord
  discard runLuaScript(cfg.redisUrl, reserveNameLua, reserveNameSha, [cfg.prefix, candidate, $ttl])
  return (name: candidate, prefix: pfx, codename: fallbackWord)

proc doOpen*(cfg: RhizoConfig, optName, optTags: string, rearmListen: bool = false, listenTimeoutSec: int = -1) =
  cleanupOldTmpFiles()
  randomize()
  var client = connectRedis(cfg.redisUrl)
  defer:
    try: client.close() except CatchableError: discard

  var name = ensureProjectScopedName(cfg, optName)
  if name.len == 0:
    let proj = if cfg.project.len > 0 and cfg.project != "default": cfg.project.strip()
               else: getCurrentDir().splitPath.tail
    let reserved = reserveUniqueName(cfg, proj, 600)
    name = sanitizeIdentifier(reserved.name)
    stderr.writeLine("[NOTICE] No agent name specified; atomically reserved project-scoped codename via 'rhizo name': @" & name)
  else:
    try:
      if client.exists(cfg.prefix & "heartbeat:" & name):
        echo "[NOTICE] Re-attaching to existing active agent '" & name & "'"
    except CatchableError:
      discard
  let tags = if optTags.len > 0:
    if optTags.startsWith(cfg.project): optTags else: cfg.project & "," & optTags
  else:
    cfg.project

  saveCurrentAgent(name)
  putEnv("RHIZO_AGENT_NAME", name)
  setTerminalTitle(name)
  let sid = if cfg.sessionId.len > 0: cfg.sessionId else: getEnv("RHIZO_SESSION_ID", "")
  if sid.len > 0:
    saveLocalSessionMapping(sid, name)
    setRedisSessionMapping(cfg, sid, name)

  discard doRegister(cfg, name, tags, cfg.heartbeatTtl)
  try:
    discard client.del(@[cfg.prefix & "held_name:" & name])
  except CatchableError:
    discard
  let backlog = doDrain(cfg, name, 50)

  echo "===================================================="
  echo "[RHIZO BUS] Registered Successfully"
  echo "- Agent Name : ", name
  if sid.len > 0:
    echo "- Session ID : ", sid
  echo "- Project    : ", cfg.project
  echo "- Tags       : ", tags
  echo "- Redis URL  : ", cfg.redisUrl, " (prefix: ", cfg.prefix, ")"
  echo "- Security   : HMAC-SHA256 authenticated (Air-Gap Prompt Firewall)"
  echo "- Engine     : Nim Native (EVALSHA cached)"
  echo "- Status     : Active & Listening on inbox"
  echo "===================================================="

  if backlog.len > 2 and backlog != "[]":
    echo "\n[PENDING BACKLOG]:"
    echo backlog

  if rearmListen:
    let (alreadyListening, existingPid, existingHost) = getActiveListenerInfo(cfg, name)
    if alreadyListening:
      stderr.writeLine("[RHIZO LISTENER] Listener already active for agent '" & name & "' (PID " & $existingPid & " on " & existingHost & "). Skipping duplicate listener.")
    else:
      stderr.writeLine("[RHIZO LISTENER] Entering listening mode for agent '" & name & "'...")
      doListen(cfg, name, listenTimeoutSec)

proc resetWatchdogStreak*(cfg: RhizoConfig, agentName: string) =
  let normName = sanitizeIdentifier(agentName)
  if normName.len == 0: return
  try:
    var client = connectRedis(cfg.redisUrl)
    defer: (try: client.close() except CatchableError: discard)
    discard client.hSet(cfg.prefix & "watchdog:" & normName, "streak", "0")
  except CatchableError: discard

proc findVineManifestPath*(startDir: string = ""): string =
  var cur = if startDir.len > 0:
              try: expandFilename(startDir) except CatchableError: startDir
            else: getCurrentDir()
  while cur.len > 0:
    let candidate = cur / ".vine.json"
    if fileExists(candidate):
      return candidate
    let parent = cur.parentDir()
    if parent == cur or parent.len == 0:
      break
    cur = parent
  return ""

proc isCompletionSubject*(subject: string): bool =
  let s = subject.toLowerAscii().strip()
  if s.len == 0: return false
  if "two-key gate pass" in s or "ready to weave" in s or "ready_to_weave" in s or "ready for weave" in s or "gate pass" in s:
    return true
  if s in ["done", "complete", "completed", "finished"]:
    return true
  if s.endsWith("done") or s.endsWith("complete") or s.endsWith("completed") or s.endsWith("finished"):
    if "task" in s or "work" in s or "stage" in s or "track" in s or "strand" in s or "step" in s or s.startsWith("re:"):
      return true
  if "task done" in s or "task complete" in s or "task completed" in s or "task finished" in s or
     "work done" in s or "work complete" in s or "work completed" in s or
     "weave complete" in s or "weave done" in s or
     "stage complete" in s or "stage done" in s or
     "track complete" in s or "track done" in s:
    return true
  if ("stage" in s or "track" in s or "wave" in s) and ("done" in s or "complete" in s or "completed" in s):
    return true
  if (s.startsWith("done") or s.startsWith("complete") or s.startsWith("finished")) and ("task" in s or "work" in s):
    return true
  return false

proc checkVineGateInterlock*(taskId: string = "", startDir: string = "", strandPath: string = "", explicitGateToken: string = ""): tuple[passed: bool, token: string, errorMsg: string] =
  var manifestPath = ""
  if strandPath.len > 0:
    manifestPath = findVineManifestPath(strandPath)

  if manifestPath.len == 0:
    let localManifest = findVineManifestPath(startDir)
    if localManifest.len > 0 and fileExists(localManifest):
      var vjLocal: JsonNode = nil
      try: vjLocal = parseFile(localManifest) except CatchableError: discard
      if vjLocal != nil:
        let mTaskId = vjLocal.getOrDefault("task_id").getStr("")
        # If the local manifest has a task_id, only apply it if it matches taskId or taskId is empty (e.g. in reply)
        if mTaskId.len == 0 or taskId.len == 0 or mTaskId == taskId:
          manifestPath = localManifest

  # Not in a vine strand -> no gate check required
  if manifestPath.len == 0 or not fileExists(manifestPath):
    return (true, explicitGateToken, "")

  var vj: JsonNode = nil
  try:
    vj = parseFile(manifestPath)
  except CatchableError as e:
    return (false, "", "[VINE GATE ERROR] Failed to parse Vine strand manifest at " & manifestPath & ": " & e.msg)

  let status = vj.getOrDefault("status").getStr("").toUpperAscii()
  let lifecycle = vj.getOrDefault("lifecycle_state").getStr("").toUpperAscii()
  let gatePassedBool = vj.getOrDefault("gate_passed").getBool(false)

  let statusOk = (status in ["READY_TO_WEAVE", "READY_FOR_WEAVE"]) or
                 (lifecycle in ["GATE_PASSED", "READY_TO_WEAVE", "READY_FOR_WEAVE"]) or
                 gatePassedBool

  var token = explicitGateToken
  if token.len == 0:
    token = vj.getOrDefault("gate_token").getStr("")
  if token.len == 0:
    token = vj.getOrDefault("merge_tree_sha").getStr("")

  let tokenOk = (token.len > 0)

  if not (statusOk and tokenOk):
    let currentStatus = if status.len > 0: status elif lifecycle.len > 0: lifecycle else: "UNVERIFIED"
    let msg = "[VINE GATE ERROR] Task cannot be marked complete.\n" &
              "The Two-Key Gate has not been passed in this strand (manifest status: " & currentStatus & ").\n" &
              "Run `vine gate` and resolve all test/merge failures first."
    return (false, "", msg)

  return (true, token, "")

proc doSend*(cfg: RhizoConfig, toAgent, msgType, fromAgent, subject, body: string,
            tags: seq[string] = @[], replyTo: string = "", msgId: string = "", isBroadcast: bool = false,
            customTs: string = "", echoResult: bool = true, rearmListen: bool = false, listenTimeoutSec: int = -1,
            urgency: string = "soon", format: string = "text", listenAgent: string = ""): string =
  randomize()
  let secret = getSecret(cfg)
  let rawCleanTo = sanitizeIdentifier(toAgent)
  let normTo = if toAgent.strip() in ["*", "@*"] or rawCleanTo in ["*", "all", "@all"]: "*"
               elif isBroadcast and rawCleanTo != "*": "@" & rawCleanTo
               else: rawCleanTo
  let normFrom = sanitizeIdentifier(fromAgent)
  resetWatchdogStreak(cfg, normFrom)

  # Causal clearing of current_task on reply or outbound progress message
  if msgType in ["reply", "progress", "complete"]:
    let curTaskFile = currentTaskFilePath(normFrom)
    if fileExists(curTaskFile):
      try: removeFile(curTaskFile) except CatchableError: discard
    let legacyTaskFile = currentTaskFilePath("")
    if fileExists(legacyTaskFile):
      try: removeFile(legacyTaskFile) except CatchableError: discard
    try:
      var client = connectRedis(cfg.redisUrl)
      defer: (try: client.close() except CatchableError: discard)
      discard client.del(@[cfg.prefix & "current_task:" & normFrom])
    except CatchableError:
      discard

  # Dynamic alias resolution (GVR-012)
  var resolvedTo = normTo
  if not (isBroadcast or normTo == "*"):
    try:
      var client = connectRedis(cfg.redisUrl)
      defer: (try: client.close() except CatchableError: discard)
      let aliasVal = client.hGet(cfg.prefix & "aliases", normTo)
      if aliasVal != redisNil and aliasVal.len > 0:
        resolvedTo = sanitizeIdentifier(aliasVal)
    except CatchableError:
      discard

  let id = if msgId.len > 0: msgId else: "msg_" & $getTime().toUnix() & "_" & normFrom & "_" & $rand(1000..9999)
  let ts = if customTs.len > 0: customTs else: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let finalBody = if cfg.encrypt: encryptAes(body, secret, cfg) else: body
  let normUrgency = if urgency.toLowerAscii in ["immediate", "now", "urgent"]: "immediate" else: "soon"

  var effectiveReplyTo = replyTo
  if msgType == "reply":
    if effectiveReplyTo.startsWith("sc_"):
      effectiveReplyTo = "scatter:" & effectiveReplyTo
    elif effectiveReplyTo.len == 0:
      try:
        var client = connectRedis(cfg.redisUrl)
        defer: (try: client.close() except CatchableError: discard)
        let pending = client.get(cfg.prefix & "agent:" & normFrom & ":pending_scatter")
        if pending != redisNil and pending.len > 0:
          effectiveReplyTo = pending
      except CatchableError:
        discard

  # Canonical concatenation for HMAC: id|from|to|type|subject|body|timestamp
  let canonical = id & "|" & normFrom & "|" & resolvedTo & "|" & msgType & "|" & subject & "|" & finalBody & "|" & ts
  let sig = computeHmacSha256(secret, canonical)

  var node = newJObject()
  node["id"] = %id
  node["from"] = %normFrom
  node["to"] = %resolvedTo
  if resolvedTo != normTo:
    node["intended_recipient"] = %normTo
  node["type"] = %msgType
  node["urgency"] = %normUrgency
  let originHost = getOriginHostname()
  if originHost.len > 0:
    node["host"] = %originHost
  if effectiveReplyTo.len > 0:
    node["reply_to"] = %effectiveReplyTo
  else:
    node["reply_to"] = newJNull()

  var tagArray = newJArray()
  for t in tags:
    tagArray.add(%sanitizeIdentifier(t))
  if tagArray.len == 0 and cfg.project.len > 0:
    tagArray.add(%cfg.project.toLowerAscii)
  node["tags"] = tagArray

  node["subject"] = %subject
  node["body"] = %finalBody
  node["timestamp"] = %ts
  node["sig"] = %sig
  node["encrypted"] = %cfg.encrypt

  let msgJson = $node

  let effectiveTtl = if cfg.messageTtl > 0: cfg.messageTtl else: 604800
  let isTargetMulticast = isBroadcast or (tags.len > 0) or (normTo == "*")
  var target = ""
  var res = ""
  if isTargetMulticast:
    if normTo == "*":
      target = "*"
    elif isBroadcast:
      if tags.len > 0:
        var normTags: seq[string] = @[]
        for t in tags: normTags.add(sanitizeIdentifier(t))
        if "*" in normTags or "all" in normTags or "@all" in normTags:
          target = "*"
        elif cfg.project.toLowerAscii in normTags:
          target = normTags.join(",")
        else:
          target = cfg.project.toLowerAscii & "," & normTags.join(",")
      else:
        target = if normTo.len > 0 and normTo != "*": normTo else: "*"
    else:
      target = if normTo.len > 0: normTo else: "*"

    res = runLuaScript(cfg.redisUrl, multicastLua, multicastSha, [cfg.prefix, target, msgJson, $effectiveTtl])
  else:
    let destQueue = if msgType == "reply" and (effectiveReplyTo.startsWith("scatter:") or effectiveReplyTo.startsWith("reply:")): effectiveReplyTo else: resolvedTo
    res = runLuaScript(cfg.redisUrl, sendO2oLua, sendO2oSha, [cfg.prefix, destQueue, msgJson, $effectiveTtl])
    if destQueue.startsWith("scatter:") and resolvedTo.len > 0 and resolvedTo != destQueue:
      discard runLuaScript(cfg.redisUrl, sendO2oLua, sendO2oSha, [cfg.prefix, resolvedTo, msgJson, $effectiveTtl])

  # Record out-of-band audit trail event
  doAuditLog(cfg, normFrom, "message.send", id & " -> " & (if resolvedTo.len > 0: resolvedTo else: target) & " [" & msgType & "] " & subject)

  if echoResult and not rearmListen:
    if format == "raw":
      echo res
    elif format == "json":
      if isTargetMulticast:
        var outObj = newJObject()
        outObj["status"] = %"BROADCAST"
        outObj["id"] = %id
        outObj["scope"] = %target
        outObj["delivered"] = %(try: parseInt(res.strip()) except ValueError: 0)
        echo $outObj
      else:
        var client = connectRedis(cfg.redisUrl)
        defer: (try: client.close() except CatchableError: discard)
        let isAlive = client.exists(cfg.prefix & "heartbeat:" & resolvedTo)
        let hasListener = client.exists(cfg.prefix & "listener:" & resolvedTo)
        let depth = try: client.lLen(cfg.prefix & "inbox:" & resolvedTo) except CatchableError: 0
        var outObj = newJObject()
        outObj["status"] = %"ENQUEUED"
        outObj["id"] = %id
        outObj["recipient"] = %resolvedTo
        if resolvedTo != normTo:
          outObj["alias"] = %normTo
        outObj["recipient_status"] = %(if isAlive: "ACTIVE" else: "OFFLINE")
        outObj["listener_attached"] = %hasListener
        outObj["inbox_depth"] = %depth
        echo $outObj
    else: # text
      if isTargetMulticast:
        let count = try: parseInt(res.strip()) except ValueError: 0
        echo "BROADCAST " & id & " delivered to " & $count & " agents (scope: " & target & ")"
        if count == 1 and target != "*" and (target == cfg.project or target == "@" & cfg.project):
          stderr.writeLine("⚠️  [RHIZO WARNING] Broadcast reached only the sender ('" & normFrom & "'). Target scope was '" & target & "'. Use '--scope all' or pass '--tags' to target other agents.")
      else:
        var client = connectRedis(cfg.redisUrl)
        defer: (try: client.close() except CatchableError: discard)
        let isAlive = client.exists(cfg.prefix & "heartbeat:" & resolvedTo)
        let hasListener = client.exists(cfg.prefix & "listener:" & resolvedTo)
        let depth = try: client.lLen(cfg.prefix & "inbox:" & resolvedTo) except CatchableError: 0
        let statusStr = if isAlive: "ACTIVE" else: "OFFLINE"
        let listenerStr = if hasListener: "LISTENING" else: "NO_LISTENER"
        let aliasNote = if resolvedTo != normTo: " (aliased from @" & normTo & ")" else: ""
        echo "ENQUEUED " & id & " -> " & resolvedTo & aliasNote & " (status: " & statusStr & ", listener: " & listenerStr & ", inbox_depth: " & $depth & ")"
        if not hasListener:
          stderr.writeLine("⚠️  [RHIZO WARNING] Recipient '" & resolvedTo & "' has no active listener attached! Message queued in inbox (depth: " & $depth & "), but will not be processed until a listener is armed.")

  if rearmListen:
    let listenerAgent = if listenAgent.len > 0: listenAgent.toLowerAscii
                        elif normFrom.len > 0: normFrom
                        else: ""
    if listenerAgent.len == 0:
      stderr.writeLine("Error: Cannot listen after send: no agent name identified. Pass '--listen <agent>' or '--from <agent>'.")
      quit(1)
    let (alreadyListening, existingPid, existingHost) = getActiveListenerInfo(cfg, listenerAgent)
    if alreadyListening:
      stderr.writeLine("[RHIZO BUS] Message sent to " & toAgent & ". Active listener already running for " & listenerAgent & " (PID " & $existingPid & " on " & existingHost & "); skipping duplicate listener.")
      return res
    stderr.writeLine("[RHIZO BUS] Message sent to " & toAgent & ". Now listening on inbox for " & listenerAgent & "...")
    doListen(cfg, listenerAgent, listenTimeoutSec)

  return res

proc doReply*(cfg: RhizoConfig, toAgent, fromAgent, subject, body: string,
             tags: seq[string] = @[], replyTo: string = "", msgId: string = "", customTs: string = "",
             rearmListen: bool = false, listenTimeoutSec: int = -1,
             urgency: string = "soon", format: string = "text", listenAgent: string = "",
             skipGate: bool = false): string =
  if isCompletionSubject(subject) and not skipGate:
    let (passed, _, err) = checkVineGateInterlock()
    if not passed:
      stderr.writeLine(err)
      quit(1)
  return doSend(cfg, toAgent, "reply", fromAgent, subject, body, tags, replyTo, msgId, false, customTs,
                echoResult = true, rearmListen = rearmListen, listenTimeoutSec = listenTimeoutSec,
                urgency = urgency, format = format, listenAgent = listenAgent)

proc sendDesktopNotification*(msgNode: JsonNode) =
  try:
    let fromAgent = msgNode.getOrDefault("from").getStr("unknown")
    let subject = msgNode.getOrDefault("subject").getStr("")
    let body = msgNode.getOrDefault("body").getStr("")
    let urgency = msgNode.getOrDefault("urgency").getStr("soon")
    let prefix = if urgency == "immediate": "[URGENT] " else: ""
    let title = "Rhizo: " & prefix & "@" & fromAgent
    let fullText = if subject.len > 0: subject & ": " & body else: body
    let displayBody = if fullText.len > 140: fullText[0..136] & "..." else: fullText

    when defined(macosx) or defined(darwin):
      let escapedTitle = title.replace("\"", "\\\"")
      let escapedBody = displayBody.replace("\"", "\\\"")
      let script = "display notification \"" & escapedBody & "\" with title \"" & escapedTitle & "\""
      discard execCmdEx("osascript -e " & quoteShell(script))
    elif defined(windows):
      let escapedTitle = title.replace("'", "''")
      let escapedBody = displayBody.replace("'", "''")
      let psCmd = "$ws = New-Object -ComObject Wscript.Shell; [void]$ws.Popup('" & escapedBody & "', 3, '" & escapedTitle & "', 64)"
      discard execCmdEx("powershell -NoProfile -Command " & quoteShell(psCmd))
    else:
      discard execCmdEx("notify-send " & quoteShell(title) & " " & quoteShell(displayBody))
  except Exception:
    discard
proc doTask*(cfg: RhizoConfig, action: string, args: openArray[string]): string

proc doListen*(cfg: RhizoConfig, name: string, timeoutSec: int = -1, notify: bool = false, quiet: bool = false, force: bool = false, continuous: bool = false) =
  let name = ensureProjectScopedName(cfg, name)
  setTerminalTitle(name & " (listening)")
  checkSupervisionAttached(name, force or continuous)
  resetWatchdogStreak(cfg, name)
  let secret = getSecret(cfg)
  let inboxKey = cfg.prefix & "inbox:" & name
  let isForever = (timeoutSec <= 0 and (timeoutSec == 0 or cfg.listenTimeout <= 0))
  let hbTtl = if cfg.heartbeatTtl > 0: cfg.heartbeatTtl else: 150
  let pollChunk = min(60, max(1, hbTtl div 2))

  # Initial Heartbeat & Directory Registration
  var client = connectRedis(cfg.redisUrl)
  defer:
    setTerminalTitle(name)
    try: client.close() except CatchableError: discard

  try:
    discard client.setEx(cfg.prefix & "heartbeat:" & name, hbTtl, "1")
  except CatchableError as e:
    stderr.writeLine("Redis error: " & e.msg)
    quit(1)

  try:
    discard client.sadd(cfg.prefix & "active_agents", name)
    let existingTags = client.hGet(cfg.prefix & "agent:" & name, "tags")
    if existingTags == redisNil or existingTags.len == 0:
      let projTag = if cfg.project.len > 0: cfg.project else: "default"
      discard client.hSet(cfg.prefix & "agent:" & name, "tags", projTag)
      discard client.sadd(cfg.prefix & "tag:" & projTag, name)
  except CatchableError as e:
    stderr.writeLine("Redis error: " & e.msg)
    quit(1)

  # Register listener ownership in Redis
  let myPid = getCurrentProcessId()
  let myHost = getHostNameStr()
  var listenerNode = newJObject()
  listenerNode["pid"] = %myPid
  listenerNode["host"] = %myHost
  listenerNode["started"] = %(getTime().toUnix())
  let listenerJson = $listenerNode
  let listenerKey = cfg.prefix & "listener:" & name
  try:
    discard client.setEx(listenerKey, hbTtl, listenerJson)
  except CatchableError as e:
    stderr.writeLine("Redis error: " & e.msg)
    quit(1)
  registerCleanup(cfg.redisUrl, listenerKey)

  let effectiveTimeout = if isForever: 0 elif timeoutSec > 0: timeoutSec else: cfg.listenTimeout
  let startTime = getTime().toUnix()
  var remaining = effectiveTimeout

  try:
    while isForever or remaining > 0:
      let waitSec = if isForever: pollChunk else: min(pollChunk, remaining)
      var popRes: RedisList
      try:
        popRes = client.bRPop(@[inboxKey], waitSec)
      except CatchableError:
        if not reconnectRedisClient(cfg.redisUrl, client, remaining, isForever):
          return # Timeout expired while disconnected
        # Re-register heartbeat & listener lock on new connection
        try:
          discard client.setEx(cfg.prefix & "heartbeat:" & name, hbTtl, "1")
          discard client.sadd(cfg.prefix & "active_agents", name)
          discard client.setEx(listenerKey, hbTtl, listenerJson)
        except CatchableError:
          discard
        continue

      if popRes.len == 0:
        if not isForever:
          let elapsed = int(getTime().toUnix() - startTime)
          remaining = max(0, effectiveTimeout - elapsed)
          if remaining == 0:
            return # Silent zero-token exit

        # Internal chunk timeout: renew heartbeat & listener lock silently in Redis only if still owner
        try:
          discard client.setEx(cfg.prefix & "heartbeat:" & name, hbTtl, "1")
          discard client.sadd(cfg.prefix & "active_agents", name)
          let currentVal = client.get(cfg.prefix & "listener:" & name)
          var isMyLock = false
          if currentVal == redisNil or currentVal.len == 0:
            isMyLock = true
          else:
            try:
              let node = parseJson(currentVal)
              if node.getOrDefault("pid").getInt(0) == myPid and node.getOrDefault("host").getStr("") == myHost:
                isMyLock = true
            except Exception:
              discard
          if isMyLock:
            discard client.setEx(cfg.prefix & "listener:" & name, hbTtl, listenerJson)
        except CatchableError:
          discard
        continue

      if popRes.len < 2:
        continue

      let payloadStr = popRes[1].strip()

      var parsed: JsonNode
      try:
        parsed = parseJson(payloadStr)
      except JsonParsingError:
        stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping non-JSON payload from inbox")
        if not isForever:
          let elapsed = int(getTime().toUnix() - startTime)
          remaining = max(0, effectiveTimeout - elapsed)
        continue

      let id = parsed.getOrDefault("id").getStr("")
      let fromAgent = parsed.getOrDefault("from").getStr("")
      let toAgent = parsed.getOrDefault("to").getStr("")
      let msgType = parsed.getOrDefault("type").getStr("")
      let subject = parsed.getOrDefault("subject").getStr("")
      let body = parsed.getOrDefault("body").getStr("")
      let ts = parsed.getOrDefault("timestamp").getStr("")
      let sig = parsed.getOrDefault("sig").getStr("")
      let isEncrypted = parsed.getOrDefault("encrypted").getBool(false)

      if msgType == "shutdown":
        stderr.writeLine("[RHIZO LISTENER] Received shutdown signal for agent '" & name & "'. Exiting.")
        return

      # Validate HMAC (accounting for transparent rerouting if present)
      let originalTo = parsed.getOrDefault("original_recipient").getStr(parsed.getOrDefault("rerouted_from").getStr(toAgent))
      let canonical = id & "|" & fromAgent & "|" & originalTo & "|" & msgType & "|" & subject & "|" & body & "|" & ts
      if not verifyHmac(secret, canonical, sig):
        stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping unauthenticated/tampered message (ID: " & id & ")")
        if not isForever:
          let elapsed = int(getTime().toUnix() - startTime)
          remaining = max(0, effectiveTimeout - elapsed)
        continue

      # Authenticated! Decrypt if required
      if isEncrypted:
        try:
          let decryptedBody = decryptAes(body, secret, cfg)
          parsed["body"] = %decryptedBody
          parsed["encrypted"] = %false
        except ValueError as e:
          stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping corrupted/undecryptable message: " & e.msg & " (ID: " & id & ")")
          if not isForever:
            let elapsed = int(getTime().toUnix() - startTime)
            remaining = max(0, effectiveTimeout - elapsed)
          continue

      let mockOffset = try:
        let v = client.get(cfg.prefix & "mock_time_offset")
        if v != redisNil and v.len > 0: parseInt(v) else: 0
      except CatchableError: 0
      let msgUnix = parseIsoOrUnix(ts)
      if msgUnix > 0:
        let nowSec = getTime().toUnix() + mockOffset
        let elapsedSec = max(0.int64, nowSec - msgUnix)
        let ageHuman = if elapsedSec < 60: $elapsedSec & "s"
                       elif elapsedSec < 3600: $(elapsedSec div 60) & "m"
                       else: $(elapsedSec div 3600) & "h"
        parsed["elapsed_seconds"] = %elapsedSec
        parsed["age_human"] = %ageHuman
        if elapsedSec >= 3600:
          parsed["is_stale"] = %true
          stderr.writeLine("⚠️  [RHIZO WARNING] Stale message received! Age: " & ageHuman & " (sent at " & ts & "). This message may be obsolete.")
        else:
          parsed["is_stale"] = %false

      let rTo = parsed.getOrDefault("reply_to").getStr("")
      if rTo.startsWith("scatter:"):
        try:
          discard client.setEx(cfg.prefix & "agent:" & name & ":pending_scatter", 600, rTo)
        except CatchableError:
          discard

      let piggy = evaluatePiggyback(cfg, name, 2)
      let rems = piggy.getOrDefault("reminders")
      if rems != nil and rems.kind == JArray and rems.len > 0:
        parsed["reminders"] = rems
        if not quiet and getEnv("RHIZO_QUIET", "0") notin ["1", "true", "yes"]:
          for r in rems:
            let rid = r.getOrDefault("id").getStr("")
            let prio = r.getOrDefault("priority").getStr("NORMAL")
            let rtext = r.getOrDefault("text").getStr("")
            stderr.writeLine("┌─── [ACTIVE ADVISORY: " & rid & " (" & prio & ")] ───────────────────────────────────────")
            stderr.writeLine("│ " & rtext)
            stderr.writeLine("└──────────────────────────────────────────────────────────────────────────")

      if notify:
        sendDesktopNotification(parsed)

      # Record in Unified Work Item State Machine as DELIVERED
      try:
        discard doTask(cfg, "deliver", [id, name, "180", subject, body])
      except CatchableError:
        discard

      # Mirror active delivery to local disk stamp for sub-millisecond hook inspection
      try:
        createDir(getHomeDir() / ".config" / "rhizo")
        writeFile(currentTaskFilePath(name), $parsed)
      except CatchableError:
        discard

      echo $parsed
      flushFile(stdout)

      if continuous:
        continue

      if not quiet and getEnv("RHIZO_QUIET", "0") notin ["1", "true", "yes"]:
        let harness = detectHarness(cfg)
        let replySubj = if subject.toLowerAscii.startsWith("re:"): subject else: "Re: " & subject
        let rawParams = commandLineParams()
        var exactCmd = "rhizo"
        for a in rawParams:
          if a.contains(" ") or a.contains("\""):
            exactCmd.add(" " & quoteShell(a))
          else:
            exactCmd.add(" " & a)

        stderr.writeLine("")
        stderr.writeLine("================================================================================")
        stderr.writeLine("🚨 [RHIZO TASK DELIVERED: IMMEDIATE AUTONOMOUS ACTION REQUIRED] 🚨")
        stderr.writeLine("[RHIZO LIFECYCLE NOTICE]")
        stderr.writeLine("Listener Identity: @" & name & " (this is YOU)")
        stderr.writeLine("Delivered Message: '" & id & "' from @" & fromAgent)
        stderr.writeLine("Subject: " & (if subject.len > 0: subject else: "<no subject>"))
        stderr.writeLine("Detected harness: " & harness)
        stderr.writeLine("Listener Process Status: EXITED (0) after delivering payload")
        stderr.writeLine("")
        stderr.writeLine("AUTONOMOUS WORKER MANDATE (DO NOT REMAIN PASSIVE / DO NOT WAIT FOR OPERATOR):")
        stderr.writeLine("1. EXECUTE NOW: You are an autonomous cluster worker. A directive has been delivered.")
        stderr.writeLine("   DO NOT wait for operator prompt. DO NOT yield your turn with a passive acknowledgment.")
        stderr.writeLine("   Immediately read the message payload above, claim the task, and begin implementation.")
        stderr.writeLine("2. RE-ARM BEFORE TURN-END: The listener has EXITED (0) after delivering this message.")
        stderr.writeLine("   You MUST re-arm your single-shot listener before concluding your turn (or use")
        stderr.writeLine("   'rhizo reply --to " & fromAgent & " ... --listen' when sending your completion report):")
        stderr.writeLine("   Reply Command: rhizo reply --to " & fromAgent & " --subject " & quoteShell(replySubj) & " --body \"...\" --listen")
        stderr.writeLine("   Exact command: " & exactCmd)
        stderr.writeLine("   Re-arm Listen: " & exactCmd)
        stderr.writeLine("   Or if finished: rhizo close " & name)
        stderr.writeLine("Capability-Tier Invocations (SKILL.md Section 3):")
        case harness
        of "opencode", "pi":
          stderr.writeLine("  - Tier 1 (In-Process Extension): In-process extension fiber is active. DO NOT run a blocking 'rhizo listen'.")
        of "antigravity":
          stderr.writeLine("  - Tier 2 (Shell Daemon): Native daemon reactive pattern: run_command(CommandLine=\"" & exactCmd & "\", IsDaemon=true)")
        of "codex":
          stderr.writeLine("  - Tier 3 (Subagent Task): Subagent ear discipline: spawn a background listener subagent to run '" & exactCmd & "'.")
        of "claude", "cursor", "copilot":
          stderr.writeLine("  - Tier 3 (Subagent Task): Task(prompt=\"Execute '" & exactCmd & "'. Block until 1 message arrives and exit immediately.\", background=true)")
        else:
          stderr.writeLine("  - Tier 2 (Daemon Shell): run_command(CommandLine=\"" & exactCmd & "\", IsDaemon=true)")
          stderr.writeLine("  - Tier 3 (Subagent Task): Task(prompt=\"Execute '" & exactCmd & "'. Block until 1 message arrives and exit immediately.\", background=true)")
          stderr.writeLine("  - Tier 4 (Synchronous Shell): Run '" & exactCmd & "' directly in foreground (or 'rhizo check-inbox')")
        stderr.writeLine("  RULE: Never wrap in 'while true' bash loop. Re-arming must be an independent task/turn.")
        stderr.writeLine("================================================================================\n")
        stderr.writeLine("(To silence this notice, pass --quiet / -q, or set RHIZO_QUIET=1)")
      return
  finally:
    unregisterCleanup(listenerKey)
    try:
      let currentVal = client.get(listenerKey)
      if currentVal != redisNil and currentVal.len > 0:
        let node = parseJson(currentVal)
        if node.getOrDefault("pid").getInt(0) == myPid and node.getOrDefault("host").getStr("") == myHost:
          discard client.del(@[listenerKey])
    except Exception:
      discard

proc doStatus*(cfg: RhizoConfig, name, state: string, activity: string = ""): string =
  let effectiveTtl = if cfg.heartbeatTtl > 0: cfg.heartbeatTtl else: 150
  return runLuaScript(cfg.redisUrl, statusLua, statusSha, [cfg.prefix, sanitizeIdentifier(name), state.toLowerAscii, activity, $effectiveTtl])

proc doLock*(cfg: RhizoConfig, lockName: string, ttlSec: int = 30, withFencing: bool = false, rawOutput: bool = false, ownerAgent: string = ""): (string, int) =
  let normLock = sanitizeIdentifier(lockName)
  let owner = if ownerAgent.len > 0: sanitizeIdentifier(ownerAgent) else: sanitizeIdentifier(getActiveAgentName(cfg, ""))
  let fencingArg = if withFencing: "1" else: "0"
  let res = runLuaScript(cfg.redisUrl, lockLua, lockSha, [cfg.prefix, normLock, owner, $ttlSec, fencingArg])
  if res != "0" and not res.startsWith("ERR:"):
    if withFencing:
      let token = res
      if rawOutput:
        return (token, 0)
      else:
        return ("LOCKED " & normLock & " by " & owner & " (fencing: " & token & ")", 0)
    else:
      return ("LOCKED " & normLock & " by " & owner, 0)
  else:
    return ("Error: Lock '" & normLock & "' is already held.", 1)

proc doUnlock*(cfg: RhizoConfig, lockName: string, ownerAgent: string = ""): (string, int) =
  let normLock = sanitizeIdentifier(lockName)
  let owner = if ownerAgent.len > 0: sanitizeIdentifier(ownerAgent) else: sanitizeIdentifier(getActiveAgentName(cfg, ""))
  let res = runLuaScript(cfg.redisUrl, unlockLua, unlockSha, [cfg.prefix, normLock, owner])
  if res == "1":
    return ("UNLOCKED " & normLock, 0)
  else:
    return ("Error: Cannot unlock '" & normLock & "': not owner or lock not found.", 1)

proc doEnqueue*(cfg: RhizoConfig, queueName, msgType, fromAgent, subject, body: string,
                tags: seq[string] = @[], replyTo: string = "", msgId: string = "", customTs: string = ""): string =
  randomize()
  let secret = getSecret(cfg)
  let normQueue = sanitizeIdentifier(queueName)
  let normFrom = sanitizeIdentifier(fromAgent)
  let id = if msgId.len > 0: msgId else: "msg_" & $getTime().toUnix() & "_" & normFrom & "_" & $rand(1000..9999)
  let ts = if customTs.len > 0: customTs else: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let finalBody = if cfg.encrypt: encryptAes(body, secret, cfg) else: body

  let canonical = id & "|" & normFrom & "|queue:" & normQueue & "|" & msgType & "|" & subject & "|" & finalBody & "|" & ts
  let sig = computeHmacSha256(secret, canonical)

  var node = newJObject()
  node["id"] = %id
  node["from"] = %normFrom
  node["to"] = %("queue:" & normQueue)
  node["type"] = %msgType
  let originHost = getOriginHostname()
  if originHost.len > 0:
    node["host"] = %originHost
  if replyTo.len > 0:
    node["reply_to"] = %replyTo
  else:
    node["reply_to"] = newJNull()

  var tagArray = newJArray()
  for t in tags:
    tagArray.add(%t.toLowerAscii)
  if tagArray.len == 0 and cfg.project.len > 0:
    tagArray.add(%cfg.project.toLowerAscii)
  node["tags"] = tagArray

  node["subject"] = %subject
  node["body"] = %finalBody
  node["timestamp"] = %ts
  node["sig"] = %sig
  node["encrypted"] = %cfg.encrypt

  let msgJson = $node
  let effectiveTtl = if cfg.messageTtl > 0: cfg.messageTtl else: 604800
  discard runLuaScript(cfg.redisUrl, enqueueLua, enqueueSha, [cfg.prefix, normQueue, msgJson, $effectiveTtl])
  return id

proc isRunCancelled*(client: Redis, cfg: RhizoConfig, runId: string): bool =
  if runId.len == 0 or client == nil: return false
  let normRunId = runId.toLowerAscii
  try:
    let res = client.get(cfg.prefix & "cancel:" & normRunId)
    if res != redisNil and res.len > 0:
      let parsed = parseJson(res)
      let secret = getSecret(cfg)
      let reason = parsed.getOrDefault("reason").getStr("")
      let byAgent = parsed.getOrDefault("by").getStr("").toLowerAscii
      let ts = parsed.getOrDefault("timestamp").getStr("")
      let sig = parsed.getOrDefault("sig").getStr("")
      let canonical = normRunId & "|" & reason & "|" & byAgent & "|" & ts
      if sig.len > 0 and verifyHmac(secret, canonical, sig):
        return true
  except CatchableError:
    discard
  return false

proc isRunCancelled*(cfg: RhizoConfig, runId: string): bool =
  if runId.len == 0: return false
  var client: Redis
  try:
    client = openRedisClient(cfg.redisUrl)
  except CatchableError:
    return false
  defer:
    try: client.close() except CatchableError: discard
  return isRunCancelled(client, cfg, runId)

proc doWork*(cfg: RhizoConfig, queueName: string, timeoutSec: int = -1, runId: string = "") =
  let normQueue = sanitizeIdentifier(queueName)
  let secret = getSecret(cfg)
  let queueKey = if normQueue.startsWith("dlq:"):
                   cfg.prefix & "queue:dlq:{" & normQueue[4..^1] & "}"
                 else:
                   cfg.prefix & "queue:{" & normQueue & "}"
  let isForever = (timeoutSec <= 0 and (timeoutSec == 0 or cfg.listenTimeout <= 0))
  let effectiveTimeout = if isForever: 0 elif timeoutSec > 0: timeoutSec else: (if cfg.listenTimeout > 0: cfg.listenTimeout else: 60)
  let startTime = getTime().toUnix()
  var remaining = effectiveTimeout

  let workerName = sanitizeIdentifier(getActiveAgentName(cfg, ""))
  let hbTtl = if cfg.heartbeatTtl > 0: cfg.heartbeatTtl else: 150
  let pollChunk = min(60, max(1, hbTtl div 2))

  var client = connectRedis(cfg.redisUrl)
  defer:
    try: client.close() except CatchableError: discard

  if workerName.len > 0:
    try:
      discard client.setEx(cfg.prefix & "heartbeat:" & workerName, hbTtl, "1")
      discard client.sadd(cfg.prefix & "active_agents", workerName)
    except CatchableError as e:
      stderr.writeLine("Redis error: " & e.msg)
      quit(1)

  while isForever or remaining > 0:
    if runId.len > 0 and isRunCancelled(client, cfg, runId):
      stderr.writeLine("Run " & runId & " was cancelled. Worker exiting.")
      return
    let waitSec = if isForever: pollChunk else: min(pollChunk, remaining)
    var popRes: RedisList
    try:
      popRes = client.bRPop(@[queueKey], waitSec)
    except CatchableError:
      if not reconnectRedisClient(cfg.redisUrl, client, remaining, isForever):
        return # Timeout expired while disconnected
      if workerName.len > 0:
        try:
          discard client.setEx(cfg.prefix & "heartbeat:" & workerName, hbTtl, "1")
          discard client.sadd(cfg.prefix & "active_agents", workerName)
        except CatchableError:
          discard
      continue
    if popRes.len == 0:
      if workerName.len > 0:
        try:
          discard client.setEx(cfg.prefix & "heartbeat:" & workerName, hbTtl, "1")
          discard client.sadd(cfg.prefix & "active_agents", workerName)
        except CatchableError:
          discard
      if not isForever:
        let elapsed = int(getTime().toUnix() - startTime)
        remaining = max(0, effectiveTimeout - elapsed)
        if remaining == 0:
          return # Silent zero-token exit
      continue

    if popRes.len < 2:
      continue

    let payloadStr = popRes[1].strip()

    var parsed: JsonNode
    try:
      parsed = parseJson(payloadStr)
    except JsonParsingError:
      stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping non-JSON payload from queue")
      if not isForever:
        let elapsed = int(getTime().toUnix() - startTime)
        remaining = max(0, effectiveTimeout - elapsed)
      continue

    let id = parsed.getOrDefault("id").getStr("")
    let fromAgent = parsed.getOrDefault("from").getStr("")
    let toAgent = parsed.getOrDefault("to").getStr("")
    let msgType = parsed.getOrDefault("type").getStr("")
    let subject = parsed.getOrDefault("subject").getStr("")
    let body = parsed.getOrDefault("body").getStr("")
    let ts = parsed.getOrDefault("timestamp").getStr("")
    let sig = parsed.getOrDefault("sig").getStr("")
    let isEncrypted = parsed.getOrDefault("encrypted").getBool(false)

    # Validate HMAC
    let canonical = id & "|" & fromAgent & "|" & toAgent & "|" & msgType & "|" & subject & "|" & body & "|" & ts
    if not verifyHmac(secret, canonical, sig):
      stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping unauthenticated/tampered message (ID: " & id & ")")
      if not isForever:
        let elapsed = int(getTime().toUnix() - startTime)
        remaining = max(0, effectiveTimeout - elapsed)
      continue

    # Authenticated! Decrypt if required
    if isEncrypted:
      try:
        let decryptedBody = decryptAes(body, secret, cfg)
        parsed["body"] = %decryptedBody
        parsed["encrypted"] = %false
      except ValueError as e:
        stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping corrupted/undecryptable message: " & e.msg & " (ID: " & id & ")")
        if not isForever:
          let elapsed = int(getTime().toUnix() - startTime)
          remaining = max(0, effectiveTimeout - elapsed)
        continue

    echo $parsed
    return

proc doAck*(cfg: RhizoConfig, queueName, taskId: string): int

proc doClaim*(cfg: RhizoConfig, queueName: string, timeoutSec: int = -1, leaseSec: int = 120, rawOutput: bool = false, runId: string = "") =
  let normQueue = sanitizeIdentifier(queueName)
  let secret = getSecret(cfg)
  let workerName = sanitizeIdentifier(getActiveAgentName(cfg, ""))
  let isForever = (timeoutSec <= 0 and (timeoutSec == 0 or cfg.listenTimeout <= 0))
  let effectiveTimeout = if isForever: 0 elif timeoutSec > 0: timeoutSec else: (if cfg.listenTimeout > 0: cfg.listenTimeout else: 60)
  let startTime = epochTime()
  var remainingMs = effectiveTimeout * 1000

  let hbTtl = if cfg.heartbeatTtl > 0: cfg.heartbeatTtl else: 150

  var client = connectRedis(cfg.redisUrl)
  defer:
    try: client.close() except CatchableError: discard

  if workerName.len > 0:
    try:
      discard client.setEx(cfg.prefix & "heartbeat:" & workerName, hbTtl, "1")
      discard client.sadd(cfg.prefix & "active_agents", workerName)
    except CatchableError as e:
      stderr.writeLine("Redis error: " & e.msg)
      quit(1)

  var backoffMs = 250

  while isForever or remainingMs > 0 or effectiveTimeout == 0:
    if runId.len > 0 and isRunCancelled(client, cfg, runId):
      stderr.writeLine("Run " & runId & " was cancelled. Worker exiting.")
      return

    var res = ""
    var exitCode = 0
    try:
      let val = client.evalSha(claimSha, @[], @[cfg.prefix, normQueue, workerName, $leaseSec, "3"])
      res = formatRedisValue(val)
    except RedisError as e:
      if "NOSCRIPT" in e.msg:
        try:
          let val = client.eval(claimLua, @[], @[cfg.prefix, normQueue, workerName, $leaseSec, "3"])
          res = formatRedisValue(val)
        except CatchableError:
          if not reconnectRedisClientMs(cfg.redisUrl, client, remainingMs, isForever):
            return
          continue
      elif e of RedisResponseError:
        res = e.msg; exitCode = 1
      else:
        if not reconnectRedisClientMs(cfg.redisUrl, client, remainingMs, isForever):
          return
        backoffMs = 250
        if workerName.len > 0:
          try:
            discard client.setEx(cfg.prefix & "heartbeat:" & workerName, hbTtl, "1")
            discard client.sadd(cfg.prefix & "active_agents", workerName)
          except CatchableError:
            discard
        continue
    except CatchableError:
      if not reconnectRedisClientMs(cfg.redisUrl, client, remainingMs, isForever):
        return
      backoffMs = 250
      if workerName.len > 0:
        try:
          discard client.setEx(cfg.prefix & "heartbeat:" & workerName, hbTtl, "1")
          discard client.sadd(cfg.prefix & "active_agents", workerName)
        except CatchableError:
          discard
      continue

    if exitCode == 0 and res.len > 0 and res != "(nil)" and res.strip().startsWith("{"):
      backoffMs = 250
      var parsed: JsonNode
      try:
        parsed = parseJson(res.strip())
      except JsonParsingError:
        stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping non-JSON claimed task")
        quit(1)

      let id = parsed.getOrDefault("id").getStr("")

      if runId.len > 0 and isRunCancelled(client, cfg, runId):
        stderr.writeLine("Run " & runId & " was cancelled. Discarding task and exiting.")
        discard doAck(cfg, normQueue, id)
        return

      let fromAgent = parsed.getOrDefault("from").getStr("")
      let toAgent = parsed.getOrDefault("to").getStr("")
      let msgType = parsed.getOrDefault("type").getStr("")
      let subject = parsed.getOrDefault("subject").getStr("")
      let body = parsed.getOrDefault("body").getStr("")
      let ts = parsed.getOrDefault("timestamp").getStr("")
      let sig = parsed.getOrDefault("sig").getStr("")
      let isEncrypted = parsed.getOrDefault("encrypted").getBool(false)

      let canonical = id & "|" & fromAgent & "|" & toAgent & "|" & msgType & "|" & subject & "|" & body & "|" & ts
      if not verifyHmac(secret, canonical, sig):
        stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping unauthenticated/tampered task (ID: " & id & ")")
        quit(1)

      if isEncrypted:
        try:
          let decryptedBody = decryptAes(body, secret, cfg)
          parsed["body"] = %decryptedBody
          parsed["encrypted"] = %false
        except ValueError as e:
          stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping corrupted task: " & e.msg)
          quit(1)

      if rawOutput:
        echo parsed.getOrDefault("body").getStr("")
      else:
        echo $parsed
      return

    if effectiveTimeout == 0:
      return

    if workerName.len > 0:
      try:
        discard client.setEx(cfg.prefix & "heartbeat:" & workerName, hbTtl, "1")
        discard client.sadd(cfg.prefix & "active_agents", workerName)
      except CatchableError:
        discard

    let elapsed = epochTime() - startTime
    remainingMs = max(0, int((float(effectiveTimeout) - elapsed) * 1000))
    if remainingMs <= 0:
      return

    let sleepTime = min(backoffMs, remainingMs)
    sleep(sleepTime)
    backoffMs = min(2000, backoffMs * 2)

proc doAck*(cfg: RhizoConfig, queueName, taskId: string): int =
  let normQueue = sanitizeIdentifier(queueName)
  let resStr = runLuaScript(cfg.redisUrl, ackLua, ackSha, [cfg.prefix, normQueue, taskId])
  var res = 0
  try:
    res = parseInt(resStr.strip())
  except ValueError:
    res = 0

  if res == 1:
    echo "ACK: " & taskId
  else:
    stderr.writeLine("Warning: Task " & taskId & " not found or already acknowledged.")
  return res

proc doClaimRenew*(cfg: RhizoConfig, queueName, taskId: string, leaseSec: int = 120) =
  let normQueue = sanitizeIdentifier(queueName)
  let res = runLuaScript(cfg.redisUrl, claimRenewLua, claimRenewSha, [cfg.prefix, normQueue, taskId, $leaseSec])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  echo res


proc decryptBlackboardValue(raw: string, secret: string, cfg: RhizoConfig, contextMsg: string): string =
  if not raw.startsWith("aes256:"):
    return raw
  let parts = raw.split(":")
  if parts.len >= 3:
    let sig = parts[1]
    let cipher = parts[2..^1].join(":")
    if not verifyHmac(secret, cipher, sig):
      stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping unauthenticated/tampered blackboard entry: " & contextMsg)
      quit(1)
    try:
      return decryptAes(cipher, secret, cfg)
    except ValueError as e:
      stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping corrupted blackboard entry: " & e.msg)
      quit(1)
  elif parts.len == 2:
    try:
      return decryptAes(parts[1], secret, cfg)
    except ValueError as e:
      stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping corrupted blackboard entry: " & e.msg)
      quit(1)
  return raw

proc doBlackboard*(cfg: RhizoConfig, action, room: string, key: string = "", val: string = "", ttlSec: int = -1): string =
  let effectiveTtl = if ttlSec >= 0: ttlSec else: (if cfg.messageTtl > 0: cfg.messageTtl else: 604800)
  let secret = getSecret(cfg)
  var finalVal = val
  if cfg.encrypt and (action == "set" or action == "append") and val.len > 0:
    let cipher = encryptAes(val, secret, cfg)
    let sig = computeHmacSha256(secret, cipher)
    finalVal = "aes256:" & sig & ":" & cipher

  let res = runLuaScript(cfg.redisUrl, blackboardLua, blackboardSha, [cfg.prefix, action, room, key, finalVal, $effectiveTtl])
  if res == "(nil)":
    return ""

  let trimmed = res.strip()
  if action == "get":
    if trimmed.startsWith("aes256:"):
      return decryptBlackboardValue(trimmed, secret, cfg, "room: " & room & ", key: " & key)
    elif trimmed.startsWith("["):
      try:
        let j = parseJson(trimmed)
        if j.kind == JArray:
          var decryptedArr = newJArray()
          for item in j.elems:
            let s = item.getStr("")
            if s.startsWith("aes256:"):
              decryptedArr.add(%decryptBlackboardValue(s, secret, cfg, "room: " & room & ", key: " & key))
            else:
              decryptedArr.add(item)
          return $decryptedArr
      except JsonParsingError:
        discard
    return trimmed

  elif action == "snapshot":
    try:
      var j = parseJson(trimmed)
      if j.hasKey("kv") and j["kv"].kind == JObject:
        var newKv = newJObject()
        for k, v in j["kv"].pairs:
          let s = v.getStr("")
          if s.startsWith("aes256:"):
            newKv[k] = %decryptBlackboardValue(s, secret, cfg, "room: " & room & ", key: " & k)
          else:
            newKv[k] = v
        j["kv"] = newKv

      if j.hasKey("lists") and j["lists"].kind == JObject:
        var newLists = newJObject()
        for lk, lv in j["lists"].pairs:
          if lv.kind == JArray:
            var newArr = newJArray()
            for item in lv.elems:
              let s = item.getStr("")
              if s.startsWith("aes256:"):
                newArr.add(%decryptBlackboardValue(s, secret, cfg, "room: " & room & ", list: " & lk))
              else:
                newArr.add(item)
            newLists[lk] = newArr
          else:
            newLists[lk] = lv
        j["lists"] = newLists
      return $j
    except JsonParsingError:
      return trimmed

  return trimmed

proc doBlackboardLoad*(cfg: RhizoConfig, room, snapshotJson: string, ttlSec: int = 0): string =
  var parsed: JsonNode
  try:
    parsed = parseJson(snapshotJson)
  except JsonParsingError as e:
    stderr.writeLine("ERR: Invalid JSON snapshot for blackboard load: " & e.msg)
    quit(1)

  if parsed.kind != JObject:
    stderr.writeLine("ERR: Invalid JSON snapshot for blackboard load: root must be a JSON object")
    quit(1)

  let secret = getSecret(cfg)
  var toLoad = parsed

  if cfg.encrypt:
    if toLoad.hasKey("kv") and toLoad["kv"].kind == JObject:
      var encKv = newJObject()
      for k, v in toLoad["kv"].pairs:
        let rawStr = if v.kind == JString: v.getStr() else: $v
        let cipher = encryptAes(rawStr, secret, cfg)
        let sig = computeHmacSha256(secret, cipher)
        encKv[k] = %("aes256:" & sig & ":" & cipher)
      toLoad["kv"] = encKv

    if toLoad.hasKey("lists") and toLoad["lists"].kind == JObject:
      var encLists = newJObject()
      for lk, lv in toLoad["lists"].pairs:
        if lv.kind == JArray:
          var encArr = newJArray()
          for item in lv.elems:
            let rawStr = if item.kind == JString: item.getStr() else: $item
            let cipher = encryptAes(rawStr, secret, cfg)
            let sig = computeHmacSha256(secret, cipher)
            encArr.add(%("aes256:" & sig & ":" & cipher))
          encLists[lk] = encArr
        else:
          encLists[lk] = lv
      toLoad["lists"] = encLists

  let effectiveTtl = if ttlSec > 0: ttlSec else: (if cfg.messageTtl > 0: cfg.messageTtl else: 0)
  let res = runLuaScript(cfg.redisUrl, blackboardLua, blackboardSha, [cfg.prefix, "load", room, "", $toLoad, $effectiveTtl])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  return res

proc doFloorRequest*(cfg: RhizoConfig, room, agentName: string, waitSec: int = 0, leaseSec: int = 60) =
  let startTime = getTime().toUnix()
  var remaining = waitSec

  var res = runLuaScript(cfg.redisUrl, floorLua, floorSha, [cfg.prefix, "request", room, agentName, $leaseSec])
  if res == "ACQUIRED":
    echo "ACQUIRED: " & agentName & " holds floor in " & room
    return

  if waitSec <= 0:
    let holder = if res.startsWith("BUSY:"): res[5..^1] else: "unknown"
    stderr.writeLine("Floor in " & room & " is held by " & holder)
    quit(1)

  discard runLuaScript(cfg.redisUrl, floorLua, floorSha, [cfg.prefix, "enqueue_waiter", room, agentName])

  while remaining > 0:
    sleep(150)
    res = runLuaScript(cfg.redisUrl, floorLua, floorSha, [cfg.prefix, "request", room, agentName, $leaseSec])
    if res == "ACQUIRED":
      echo "ACQUIRED: " & agentName & " holds floor in " & room
      return
    let elapsed = int(getTime().toUnix() - startTime)
    remaining = max(0, waitSec - elapsed)

  # Dequeue from waiters list on timeout to prevent stale waiter hijacking subsequent yields
  try:
    var client = openRedisClient(cfg.redisUrl)
    defer: (try: client.close() except CatchableError: discard)
    discard client.lRem(cfg.prefix & "floor:{" & room & "}:waiters", agentName, 0)
  except CatchableError:
    discard

  let holder = if res.startsWith("BUSY:"): res[5..^1] else: "unknown"
  stderr.writeLine("Timeout waiting for floor in " & room & ". Currently held by " & holder)
  quit(1)

proc doFloorYield*(cfg: RhizoConfig, room, agentName: string, force: bool = false, leaseSec: int = 60) =
  let forceArg = if force: "force" else: ""
  let res = runLuaScript(cfg.redisUrl, floorLua, floorSha, [cfg.prefix, "yield", room, agentName, forceArg, $leaseSec])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  echo res

proc doFloorPass*(cfg: RhizoConfig, room, agentName, targetAgent: string, force: bool = false, leaseSec: int = 60) =
  let forceArg = if force: "force" else: ""
  let res = runLuaScript(cfg.redisUrl, floorLua, floorSha, [cfg.prefix, "pass", room, agentName, targetAgent, $leaseSec, forceArg])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  echo res

proc doFloorStatus*(cfg: RhizoConfig, room: string) =
  let res = runLuaScript(cfg.redisUrl, floorLua, floorSha, [cfg.prefix, "status", room])
  echo res

proc doCancelSet*(cfg: RhizoConfig, runId, reason, byAgent: string, ttlSec: int = 3600) =
  let normRunId = runId.toLowerAscii
  let normBy = byAgent.toLowerAscii
  let secret = getSecret(cfg)
  let ts = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let canonical = normRunId & "|" & reason & "|" & normBy & "|" & ts
  let sig = computeHmacSha256(secret, canonical)
  let res = runLuaScript(cfg.redisUrl, cancelLua, cancelSha, [cfg.prefix, "cancel", normRunId, reason, normBy, $ttlSec, ts, sig])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  var n = newJObject()
  n["status"] = %"cancelled"
  n["run_id"] = %normRunId
  n["reason"] = %reason
  n["by"] = %normBy
  n["timestamp"] = %ts
  n["sig"] = %sig
  n["cancelled"] = %true
  echo $n

proc doCancelCheck*(cfg: RhizoConfig, runId: string, rawOutput: bool = false, exitCodeOnUncancelled: bool = false) =
  let normRunId = runId.toLowerAscii
  let res = runLuaScript(cfg.redisUrl, cancelLua, cancelSha, [cfg.prefix, "check", normRunId])
  if res.len == 0 or res == "(nil)":
    if exitCodeOnUncancelled:
      quit(1)
    return

  try:
    let parsed = parseJson(res)
    let secret = getSecret(cfg)
    let reason = parsed.getOrDefault("reason").getStr("")
    let byAgent = parsed.getOrDefault("by").getStr("").toLowerAscii
    let ts = parsed.getOrDefault("timestamp").getStr("")
    let sig = parsed.getOrDefault("sig").getStr("")
    let canonical = normRunId & "|" & reason & "|" & byAgent & "|" & ts

    if sig.len == 0 or not verifyHmac(secret, canonical, sig):
      stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping unauthenticated/tampered cancellation token (run_id: " & normRunId & ")")
      if exitCodeOnUncancelled:
        quit(1)
      return

    if rawOutput:
      echo reason
    else:
      echo res
  except JsonParsingError:
    if exitCodeOnUncancelled:
      quit(1)
    return

proc doCancelClear*(cfg: RhizoConfig, runId: string) =
  let normRunId = runId.toLowerAscii
  let res = runLuaScript(cfg.redisUrl, cancelLua, cancelSha, [cfg.prefix, "clear", normRunId])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  echo res

proc doBallotOpen*(cfg: RhizoConfig, ballotId, options, voters: string, ttlSec: int = 3600) =
  let normBallotId = ballotId.toLowerAscii
  let ts = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let res = runLuaScript(cfg.redisUrl, ballotLua, ballotSha, [cfg.prefix, "open", normBallotId, options, voters, $ttlSec, ts])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  echo res

proc doBallotCast*(cfg: RhizoConfig, ballotId, voter, choice: string) =
  let normBallotId = ballotId.toLowerAscii
  let normVoter = voter.toLowerAscii
  let secret = getSecret(cfg)
  let ts = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let canonical = normVoter & "|" & normBallotId & "|" & choice & "|" & ts
  let sig = computeHmacSha256(secret, canonical)
  let res = runLuaScript(cfg.redisUrl, ballotLua, ballotSha, [cfg.prefix, "cast", normBallotId, normVoter, choice, sig, ts])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  echo res

proc doBallotTally*(cfg: RhizoConfig, ballotId: string, closeBallot: bool = false, rawOutput: bool = false) =
  let normBallotId = ballotId.toLowerAscii
  let closeArg = if closeBallot: "close" else: ""
  let res = runLuaScript(cfg.redisUrl, ballotLua, ballotSha, [cfg.prefix, "tally", normBallotId, closeArg])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)

  var parsed: JsonNode
  try:
    parsed = parseJson(res)
  except JsonParsingError:
    echo res
    return

  let secret = getSecret(cfg)
  var verifiedTally = newJObject()
  var verifiedTotal = 0

  if parsed.hasKey("tally") and parsed["tally"].kind == JObject:
    for k, _ in parsed["tally"].pairs:
      verifiedTally[k] = %0

  if parsed.hasKey("votes") and parsed["votes"].kind == JObject:
    for voter, vInfo in parsed["votes"].pairs:
      let choice = vInfo.getOrDefault("choice").getStr("")
      let sigEntry = vInfo.getOrDefault("sig_entry").getStr("")
      var valid = false
      if sigEntry.len > 0 and "|" in sigEntry:
        let p = sigEntry.split("|")
        if p.len >= 2:
          let sig = p[0]
          let ts = p[1..^1].join("|")
          let canonical = voter.toLowerAscii & "|" & normBallotId & "|" & choice & "|" & ts
          if verifyHmac(secret, canonical, sig):
            valid = true

      if valid:
        verifiedTotal.inc
        let curr = verifiedTally.getOrDefault(choice).getInt(0)
        verifiedTally[choice] = %(curr + 1)
      else:
        stderr.writeLine("[RHIZO SECURITY] WARNING: Discarding unauthenticated/tampered vote from voter: " & voter)

    parsed["total_votes"] = %verifiedTotal
    parsed["tally"] = verifiedTally

    var maxCount = -1
    var winner = ""
    for k, v in verifiedTally.pairs:
      let cnt = v.getInt(0)
      if cnt > maxCount:
        maxCount = cnt
        winner = k
    parsed["winner"] = %winner
    parsed.delete("votes")

  if rawOutput:
    echo parsed.getOrDefault("winner").getStr("")
  else:
    echo $parsed

proc doBallotStatus*(cfg: RhizoConfig, ballotId: string) =
  let normBallotId = ballotId.toLowerAscii
  let res = runLuaScript(cfg.redisUrl, ballotLua, ballotSha, [cfg.prefix, "status", normBallotId])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  echo res

proc doLeaderAcquire*(cfg: RhizoConfig, role, agentName: string, leaseSec: int = 30) =
  let normRole = role.toLowerAscii
  let normAgent = agentName.toLowerAscii
  let secret = getSecret(cfg)
  let ts = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let canonical = normRole & "|" & normAgent & "|" & ts & "|" & $leaseSec
  let sig = computeHmacSha256(secret, canonical)
  var res = runLuaScript(cfg.redisUrl, leaderLua, leaderSha, [cfg.prefix, "acquire", normRole, normAgent, $leaseSec, ts, sig])
  if res.startsWith("HELD:"):
    var existing = ""
    try:
      var client = openRedisClient(cfg.redisUrl)
      defer: (try: client.close() except CatchableError: discard)
      let val = client.get(cfg.prefix & "leader:{" & normRole & "}")
      if val != redisNil:
        existing = val
    except CatchableError:
      discard
    if existing.len > 0:
      try:
        let parsed = parseJson(existing)
        let exLeader = parsed.getOrDefault("leader").getStr("").toLowerAscii
        let exTs = parsed.getOrDefault("acquired_at").getStr("")
        let exLease = parsed.getOrDefault("lease_sec").getInt(0)
        let exSig = parsed.getOrDefault("sig").getStr("")
        let exCanonical = normRole & "|" & exLeader & "|" & exTs & "|" & $exLease
        if exSig.len == 0 or not verifyHmac(secret, exCanonical, exSig):
          stderr.writeLine("[RHIZO SECURITY] WARNING: Preempting unauthenticated/forged leader key for role: " & normRole)
          res = runLuaScript(cfg.redisUrl, leaderLua, leaderSha, [cfg.prefix, "acquire", normRole, normAgent, $leaseSec, ts, sig, "force"])
      except JsonParsingError:
        stderr.writeLine("[RHIZO SECURITY] WARNING: Preempting corrupt leader key for role: " & normRole)
        res = runLuaScript(cfg.redisUrl, leaderLua, leaderSha, [cfg.prefix, "acquire", normRole, normAgent, $leaseSec, ts, sig, "force"])

  if res.startsWith("HELD:") or res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  echo res

proc doLeaderRenew*(cfg: RhizoConfig, role, agentName: string, leaseSec: int = 30) =
  let normRole = role.toLowerAscii
  let normAgent = agentName.toLowerAscii
  let secret = getSecret(cfg)
  let ts = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let canonical = normRole & "|" & normAgent & "|" & ts & "|" & $leaseSec
  let sig = computeHmacSha256(secret, canonical)
  let res = runLuaScript(cfg.redisUrl, leaderLua, leaderSha, [cfg.prefix, "renew", normRole, normAgent, $leaseSec, ts, sig])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  echo res

proc doLeaderResign*(cfg: RhizoConfig, role, agentName: string) =
  let normRole = role.toLowerAscii
  let normAgent = agentName.toLowerAscii
  let res = runLuaScript(cfg.redisUrl, leaderLua, leaderSha, [cfg.prefix, "resign", normRole, normAgent])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  echo res

proc doLeaderStatus*(cfg: RhizoConfig, role: string) =
  let normRole = role.toLowerAscii
  let res = runLuaScript(cfg.redisUrl, leaderLua, leaderSha, [cfg.prefix, "status", normRole])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)

  try:
    let parsed = parseJson(res)
    let secret = getSecret(cfg)
    let leader = parsed.getOrDefault("leader").getStr("").toLowerAscii
    let status = parsed.getOrDefault("status").getStr("")
    if status == "active" and leader.len > 0:
      let exTs = parsed.getOrDefault("acquired_at").getStr("")
      let exLease = parsed.getOrDefault("lease_sec").getInt(0)
      let exSig = parsed.getOrDefault("sig").getStr("")
      let canonical = normRole & "|" & leader & "|" & exTs & "|" & $exLease
      if exSig.len == 0 or not verifyHmac(secret, canonical, exSig):
        stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping unauthenticated/tampered leader key for role: " & normRole)
        var vacant = newJObject()
        vacant["role"] = %normRole
        vacant["leader"] = %""
        vacant["status"] = %"vacant"
        vacant["ttl"] = %0
        echo $vacant
        return
    echo res
  except JsonParsingError:
    echo res

proc doWorkflowDefine*(cfg: RhizoConfig, flowId, steps, deps: string, ttlSec: int = 86400) =
  let ts = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let res = runLuaScript(cfg.redisUrl, workflowLua, workflowSha, [cfg.prefix, "define", flowId, steps, deps, $ttlSec, ts])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  echo res

proc doWorkflowNext*(cfg: RhizoConfig, flowId: string, rawOutput: bool = false) =
  let res = runLuaScript(cfg.redisUrl, workflowLua, workflowSha, [cfg.prefix, "next", flowId])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  if rawOutput:
    try:
      let n = parseJson(res)
      if n.hasKey("ready"):
        for item in n["ready"]:
          echo item.getStr()
    except CatchableError:
      echo res
  else:
    echo res

proc doWorkflowResolve*(cfg: RhizoConfig, flowId, step, output: string, rawOutput: bool = false) =
  let ts = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let secret = getSecret(cfg)
  var finalOutput = output
  if cfg.encrypt and output.len > 0:
    finalOutput = "aes256:" & encryptAes(output, secret, cfg)
  let res = runLuaScript(cfg.redisUrl, workflowLua, workflowSha, [cfg.prefix, "resolve", flowId, step, finalOutput, ts])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  if rawOutput:
    try:
      let n = parseJson(res)
      if n.hasKey("unlocked"):
        for item in n["unlocked"]:
          echo item.getStr()
    except CatchableError:
      echo res
  else:
    echo res

proc doWorkflowFail*(cfg: RhizoConfig, flowId, step, reason: string) =
  let res = runLuaScript(cfg.redisUrl, workflowLua, workflowSha, [cfg.prefix, "fail", flowId, step, reason])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  echo res

proc doWorkflowStatus*(cfg: RhizoConfig, flowId: string, rawOutput: bool = false) =
  let res = runLuaScript(cfg.redisUrl, workflowLua, workflowSha, [cfg.prefix, "status", flowId])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)

  var parsed: JsonNode
  try:
    parsed = parseJson(res)
    let secret = getSecret(cfg)
    if parsed.hasKey("steps") and parsed["steps"].kind == JObject:
      for stepName, stepObj in parsed["steps"].pairs:
        if stepObj.hasKey("output"):
          let outStr = stepObj["output"].getStr("")
          if outStr.startsWith("aes256:"):
            try:
              stepObj["output"] = %decryptAes(outStr[7..^1], secret, cfg)
            except ValueError:
              discard
  except JsonParsingError:
    if rawOutput:
      echo res
    else:
      echo res
    return

  if rawOutput:
    try:
      if parsed.hasKey("status"):
        echo parsed["status"].getStr()
      else:
        echo $parsed
    except CatchableError:
      echo res
  else:
    echo $parsed

proc doWorkflowExport*(cfg: RhizoConfig, flowId: string, outputFile: string = "") =
  let res = runLuaScript(cfg.redisUrl, workflowLua, workflowSha, [cfg.prefix, "status", flowId])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)

  var parsed: JsonNode
  try:
    parsed = parseJson(res)
    let secret = getSecret(cfg)
    if parsed.hasKey("steps") and parsed["steps"].kind == JObject:
      for stepName, stepObj in parsed["steps"].pairs:
        if stepObj.hasKey("output"):
          let outStr = stepObj["output"].getStr("")
          if outStr.startsWith("aes256:"):
            try:
              stepObj["output"] = %decryptAes(outStr[7..^1], secret, cfg)
            except ValueError:
              discard
  except JsonParsingError:
    stderr.writeLine("ERR: Failed to parse workflow state: " & res)
    quit(1)

  let formatted = $parsed
  if outputFile.len > 0:
    try:
      writeFile(outputFile, formatted)
      echo "OK"
    except CatchableError as e:
      stderr.writeLine("Error writing workflow export to file '" & outputFile & "': " & e.msg)
      quit(1)
  else:
    echo formatted

proc doWorkflowImport*(cfg: RhizoConfig, flowId, fileOrJson: string, ttlSec: int = 0) =
  var rawJson = fileOrJson
  if fileExists(fileOrJson):
    try:
      rawJson = readFile(fileOrJson)
    except CatchableError as e:
      stderr.writeLine("Error reading workflow file '" & fileOrJson & "': " & e.msg)
      quit(1)
  elif fileOrJson.startsWith("@") and fileExists(fileOrJson[1..^1]):
    try:
      rawJson = readFile(fileOrJson[1..^1])
    except CatchableError as e:
      stderr.writeLine("Error reading workflow file '" & fileOrJson[1..^1] & "': " & e.msg)
      quit(1)

  var parsed: JsonNode
  try:
    parsed = parseJson(rawJson)
  except JsonParsingError as e:
    stderr.writeLine("ERR: Invalid JSON workflow payload: " & e.msg)
    quit(1)

  if parsed.kind != JObject or not parsed.hasKey("steps") or not parsed.hasKey("status"):
    stderr.writeLine("ERR: Invalid JSON workflow payload: must contain 'steps' and 'status'")
    quit(1)

  if cfg.encrypt:
    let secret = getSecret(cfg)
    if parsed.hasKey("steps") and parsed["steps"].kind == JObject:
      for stepName, stepObj in parsed["steps"].pairs:
        if stepObj.hasKey("output"):
          let outStr = stepObj["output"].getStr("")
          if outStr.len > 0 and not outStr.startsWith("aes256:"):
            stepObj["output"] = %("aes256:" & encryptAes(outStr, secret, cfg))

  let res = runLuaScript(cfg.redisUrl, workflowLua, workflowSha, [cfg.prefix, "import", flowId, $parsed, $ttlSec])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)
  echo res

proc doSweep*(cfg: RhizoConfig, dryRun: bool = false, rawOutput: bool = false) =
  let action = if dryRun: "audit" else: "prune"
  let dryRunArg = if dryRun: "1" else: "0"
  let res = runLuaScript(cfg.redisUrl, sweepLua, sweepSha, [cfg.prefix, action, dryRunArg])
  if res.startsWith("ERR:"):
    stderr.writeLine(res)
    quit(1)

  var prunedAgents: seq[string] = @[]
  var prunedListeners: seq[string] = @[]
  var foreignListeners: seq[JsonNode] = @[]
  let currentHost = getHostNameStr()

  try:
    let n = parseJson(res)
    if n.hasKey("dead_agents"):
      for a in n["dead_agents"]:
        prunedAgents.add(a.getStr())
    if n.hasKey("listeners"):
      var keysToDelete: seq[string] = @[]
      for l in n["listeners"]:
        let agent = l["agent"].getStr()
        let lKey = l["key"].getStr()
        let dataStr = l["data"].getStr()
        if dataStr.len > 0:
          try:
            let lockData = parseJson(dataStr)
            let host = lockData.getOrDefault("host").getStr()
            let pid = lockData.getOrDefault("pid").getInt()
            if host == currentHost:
              if pid > 0 and not isPidAlive(pid):
                prunedListeners.add(agent)
                if not dryRun:
                  keysToDelete.add(lKey)
            else:
              foreignListeners.add(%*{
                "agent": agent,
                "host": host,
                "pid": pid,
                "status": "foreign_active"
              })
          except CatchableError:
            discard
      if not dryRun and keysToDelete.len > 0:
        try:
          var client = openRedisClient(cfg.redisUrl)
          defer: (try: client.close() except CatchableError: discard)
          discard client.del(keysToDelete)
        except CatchableError:
          discard
  except CatchableError as e:
    stderr.writeLine("Error parsing sweep results: " & e.msg)
    quit(1)

  if rawOutput:
    var msg = "Pruned " & $prunedAgents.len & " dead agents, " & $prunedListeners.len & " stale listeners."
    if foreignListeners.len > 0:
      msg.add(" Skipped " & $foreignListeners.len & " foreign host listeners.")
    echo msg
  else:
    var outObj = %*{
      "pruned_agents": %prunedAgents,
      "pruned_listeners": %prunedListeners,
      "foreign_listeners": %foreignListeners,
      "dry_run": %dryRun
    }
    echo $outObj

proc doRequest*(cfg: RhizoConfig, toAgent, fromAgent, subject, body: string, timeoutSec: int = 30, rawOutput: bool = false, urgency: string = "soon") =
  randomize()
  let secret = getSecret(cfg)
  let normTo = toAgent.toLowerAscii
  let normFrom = fromAgent.toLowerAscii
  let reqId = "req_" & $getTime().toUnix() & "_" & normFrom & "_" & $rand(1000..9999)
  let replyQueue = "reply:" & reqId
  let replyInboxKey = cfg.prefix & "inbox:" & replyQueue

  discard doSend(cfg, normTo, "task", normFrom, subject, body, tags = @[], replyTo = replyQueue, msgId = reqId, isBroadcast = false, echoResult = false, urgency = urgency)

  var client = connectRedis(cfg.redisUrl)
  defer:
    try: client.close() except CatchableError: discard

  let startTime = getTime().toUnix()
  var remaining = timeoutSec

  while remaining > 0:
    var popRes: RedisList
    try:
      popRes = client.bRPop(@[replyInboxKey], remaining)
    except CatchableError as e:
      stderr.writeLine("Redis error: " & e.msg)
      quit(1)

    if popRes.len == 0 or popRes.len < 2:
      stderr.writeLine("Error: Request timed out waiting for reply from " & toAgent)
      quit(1)

    let payloadStr = popRes[1].strip()

    var parsed: JsonNode
    try:
      parsed = parseJson(payloadStr)
    except JsonParsingError:
      stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping non-JSON payload from reply inbox")
      let elapsed = int(getTime().toUnix() - startTime)
      remaining = max(0, timeoutSec - elapsed)
      continue

    let id = parsed.getOrDefault("id").getStr("")
    let sender = parsed.getOrDefault("from").getStr("")
    let toTarget = parsed.getOrDefault("to").getStr("")
    let msgType = parsed.getOrDefault("type").getStr("")
    let subj = parsed.getOrDefault("subject").getStr("")
    let bdy = parsed.getOrDefault("body").getStr("")
    let ts = parsed.getOrDefault("timestamp").getStr("")
    let sig = parsed.getOrDefault("sig").getStr("")
    let isEncrypted = parsed.getOrDefault("encrypted").getBool(false)

    # Validate HMAC
    let canonical = id & "|" & sender & "|" & toTarget & "|" & msgType & "|" & subj & "|" & bdy & "|" & ts
    if not verifyHmac(secret, canonical, sig):
      stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping unauthenticated/tampered reply (ID: " & id & ")")
      let elapsed = int(getTime().toUnix() - startTime)
      remaining = max(0, timeoutSec - elapsed)
      continue

    # Authenticated! Decrypt if required
    if isEncrypted:
      try:
        let decryptedBody = decryptAes(bdy, secret, cfg)
        parsed["body"] = %decryptedBody
        parsed["encrypted"] = %false
      except ValueError as e:
        stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping corrupted/undecryptable reply: " & e.msg & " (ID: " & id & ")")
        let elapsed = int(getTime().toUnix() - startTime)
        remaining = max(0, timeoutSec - elapsed)
        continue

    if rawOutput:
      echo parsed.getOrDefault("body").getStr("")
    else:
      echo $parsed
    return

  stderr.writeLine("Error: Request timed out waiting for reply from " & toAgent)
  quit(1)

proc doScatter*(cfg: RhizoConfig, targets, fromAgent, subject, body: string,
               quorum: int = -1, timeoutSec: int = 30, rawOutput: bool = false, urgency: string = "soon") =
  randomize()
  let secret = getSecret(cfg)
  let normTargets = targets.toLowerAscii
  let normFrom = fromAgent.toLowerAscii
  let scatterId = "sc_" & $getTime().toUnix() & "_" & normFrom & "_" & $rand(1000..9999)
  let replyQueue = "scatter:" & scatterId
  let replyInboxKey = cfg.prefix & "inbox:" & replyQueue
  let normUrgency = if urgency.toLowerAscii in ["immediate", "now", "urgent"]: "immediate" else: "soon"

  let ts = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let finalBody = if cfg.encrypt: encryptAes(body, secret, cfg) else: body
  let canonical = scatterId & "|" & normFrom & "|" & normTargets & "|task|" & subject & "|" & finalBody & "|" & ts
  let sig = computeHmacSha256(secret, canonical)

  var node = newJObject()
  node["id"] = %scatterId
  node["from"] = %normFrom
  node["to"] = %normTargets
  node["type"] = %"task"
  node["urgency"] = %normUrgency
  node["reply_to"] = %replyQueue
  let originHost = getOriginHostname()
  if originHost.len > 0:
    node["host"] = %originHost
  node["tags"] = newJArray()
  node["subject"] = %subject
  node["body"] = %finalBody
  node["timestamp"] = %ts
  node["sig"] = %sig
  node["encrypted"] = %cfg.encrypt

  let msgJson = $node
  let effectiveTtl = if cfg.messageTtl > 0: cfg.messageTtl else: 300

  let deliveredStr = runLuaScript(cfg.redisUrl, scatterLua, scatterSha, [cfg.prefix, normTargets, msgJson, $effectiveTtl])
  var delivered = 0
  try:
    delivered = parseInt(deliveredStr.strip())
  except ValueError:
    delivered = 0

  let effectiveQuorum = if delivered <= 0:
                          0
                        elif quorum >= 0:
                          min(quorum, delivered)
                        else:
                          delivered

  var collectedReplies: seq[JsonNode] = @[]
  var seenSenders = initHashSet[string]()

  if effectiveQuorum > 0 and delivered > 0:
    var client = connectRedis(cfg.redisUrl)
    defer:
      try: client.close() except CatchableError: discard

    try:
      discard client.expire(replyInboxKey, timeoutSec + 60)
    except CatchableError:
      discard
    let startTime = getTime().toUnix()
    var remaining = timeoutSec
    stderr.writeLine("[RHIZO SCATTER] Dispatched task '" & scatterId & "' to " & $delivered & " agents. Waiting for quorum (" & $effectiveQuorum & "/" & $delivered & ") with timeout " & $timeoutSec & "s...")

    while collectedReplies.len < effectiveQuorum and remaining > 0:
      var popRes: RedisList
      try:
        popRes = client.bRPop(@[replyInboxKey], remaining)
      except CatchableError as e:
        stderr.writeLine("Redis error: " & e.msg)
        break

      if popRes.len == 0 or popRes.len < 2:
        break

      let payloadStr = popRes[1].strip()
      var parsed: JsonNode
      try:
        parsed = parseJson(payloadStr)
      except JsonParsingError:
        stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping non-JSON payload from scatter inbox")
        let elapsed = int(getTime().toUnix() - startTime)
        remaining = max(0, timeoutSec - elapsed)
        continue

      let id = parsed.getOrDefault("id").getStr("")
      let sender = parsed.getOrDefault("from").getStr("")
      let toTarget = parsed.getOrDefault("to").getStr("")
      let msgType = parsed.getOrDefault("type").getStr("")
      let subj = parsed.getOrDefault("subject").getStr("")
      let bdy = parsed.getOrDefault("body").getStr("")
      let rts = parsed.getOrDefault("timestamp").getStr("")
      let rsig = parsed.getOrDefault("sig").getStr("")
      let isEncrypted = parsed.getOrDefault("encrypted").getBool(false)

      # Validate HMAC
      let rCanonical = id & "|" & sender & "|" & toTarget & "|" & msgType & "|" & subj & "|" & bdy & "|" & rts
      if not verifyHmac(secret, rCanonical, rsig):
        stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping unauthenticated/tampered reply (ID: " & id & ")")
        let elapsed = int(getTime().toUnix() - startTime)
        remaining = max(0, timeoutSec - elapsed)
        continue

      if isEncrypted:
        try:
          let decryptedBody = decryptAes(bdy, secret, cfg)
          parsed["body"] = %decryptedBody
          parsed["encrypted"] = %false
        except ValueError as e:
          stderr.writeLine("[RHIZO SECURITY] WARNING: Dropping corrupted/undecryptable reply: " & e.msg & " (ID: " & id & ")")
          let elapsed = int(getTime().toUnix() - startTime)
          remaining = max(0, timeoutSec - elapsed)
          continue

      let normSender = sender.toLowerAscii
      if not seenSenders.contains(normSender):
        seenSenders.incl(normSender)
        collectedReplies.add(parsed)
        stderr.writeLine("[RHIZO SCATTER] Reply received from '" & sender & "' [" & $collectedReplies.len & "/" & $effectiveQuorum & "]")

      let elapsed = int(getTime().toUnix() - startTime)
      remaining = max(0, timeoutSec - elapsed)

    try:
      discard client.del(@[replyInboxKey])
    except CatchableError:
      discard

    if collectedReplies.len < effectiveQuorum:
      stderr.writeLine("⚠️  [RHIZO WARNING] Scatter timed out after " & $timeoutSec & "s. Quorum not reached: " & $collectedReplies.len & "/" & $effectiveQuorum & " replies received.")

  if rawOutput:
    for r in collectedReplies:
      echo r["body"].getStr("")
  else:
    var resArr = newJArray()
    for r in collectedReplies:
      resArr.add(r)
    echo $resArr

proc doPub*(cfg: RhizoConfig, channel, message: string): string =
  let normChan = sanitizeIdentifier(channel)
  let fullChan = cfg.prefix & "channel:" & normChan
  var client = connectRedis(cfg.redisUrl)
  defer:
    try: client.close() except CatchableError: discard
  try:
    let receivers = client.publish(fullChan, message)
    return $receivers
  except CatchableError as e:
    stderr.writeLine("Redis error: " & e.msg)
    quit(1)

proc doSub*(cfg: RhizoConfig, channel: string, timeoutSec: int = -1) =
  let normChan = sanitizeIdentifier(channel)
  let fullChan = cfg.prefix & "channel:" & normChan
  proc asyncSub(): Future[string] {.async.} =
    let parsed = parseRedisUrl(cfg.redisUrl)
    let r = await openAsync(parsed.host, parsed.port.Port)
    if parsed.password.len > 0:
      await r.auth(parsed.password)
    if parsed.db != 0:
      discard await r.select(parsed.db)
    await r.subscribe(fullChan)
    if timeoutSec > 0:
      let msgFut = r.nextMessage()
      if await withTimeout(msgFut, timeoutSec * 1000):
        let msg = msgFut.read()
        try:
          await r.close()
        except CatchableError:
          discard
        return msg.message
      else:
        try:
          await r.close()
        except CatchableError:
          discard
        return ""
    else:
      let msg = await r.nextMessage()
      try:
        await r.close()
      except CatchableError:
        discard
      return msg.message

  try:
    let res = waitFor asyncSub()
    if res.len > 0:
      echo res
  except CatchableError as e:
    stderr.writeLine("Redis error: " & e.msg)
    quit(1)

proc resolveVal(val: string): string =
  if val.startsWith("@") and val.len > 1 and fileExists(val[1..^1]):
    try:
      return readFile(val[1..^1])
    except CatchableError:
      return val
  return val

proc doTask*(cfg: RhizoConfig, action: string, args: openArray[string]): string =
  var evalArgs: seq[string] = @[cfg.prefix, action]
  for a in args: evalArgs.add(a)
  return runLuaScript(cfg.redisUrl, taskLua, taskSha, evalArgs)

proc formatTasksTable*(jsonStr: string): string =
  try:
    let node = parseJson(jsonStr)
    if node.kind != JArray or node.len == 0:
      return "No tasks found."
    var rows: seq[(string, string, string, string, string)] = @[]
    for item in node:
      let id = item.getOrDefault("id").getStr("")
      let title = item.getOrDefault("title").getStr("")
      let state = item.getOrDefault("state").getStr("UNASSIGNED")
      let owner = item.getOrDefault("owner").getStr("-")
      let lease = try: parseInt(item.getOrDefault("lease_until").getStr("0")) except ValueError: 0
      let delivery = try: parseInt(item.getOrDefault("delivery_until").getStr("0")) except ValueError: 0
      let nowSec = getTime().toUnix()
      var remSec = "-"
      if state in ["IN_PROGRESS", "CLAIMED"] and lease > nowSec:
        remSec = $(lease - nowSec) & "s (lease)"
      elif state == "DELIVERED" and delivery > nowSec:
        remSec = $(delivery - nowSec) & "s (claim)"
      rows.add((id, if owner.len > 0: owner else: "-", state, remSec, title))
    result = "TASK ID              OWNER           STATE            LEASE/TIMEOUT      TITLE\n"
    result.add("----------------------------------------------------------------------------------------------------\n")
    for (id, owner, state, rem, title) in rows:
      result.add(id.alignLeft(21) & owner.alignLeft(16) & state.alignLeft(17) & rem.alignLeft(19) & title & "\n")
    result = result.strip()
  except CatchableError:
    return jsonStr

proc doTaskComplete*(cfg: RhizoConfig, taskId: string, worker: string, gateToken: var string,
                     strandPath: string = "", weave: bool = false, skipGate: bool = false): string =
  if not skipGate:
    let (passed, verifiedToken, err) = checkVineGateInterlock(taskId, "", strandPath, gateToken)
    if not passed:
      stderr.writeLine(err)
      quit(1)
    if gateToken.len == 0 and verifiedToken.len > 0:
      gateToken = verifiedToken

    if weave:
      stderr.writeLine("[VINE] Fast-forward weaving strand into trunk...")
      let weaveCmd = if strandPath.len > 0: "vine weave --dir " & quoteShell(strandPath) else: "vine weave"
      let (wOut, wCode) = execCmdEx(weaveCmd)
      if wCode != 0:
        stderr.writeLine("Error: Vine weave failed: " & wOut)
        quit(1)
      stderr.writeLine("[VINE] Trunk weave complete.")

  let res = doTask(cfg, "complete", [taskId, worker, gateToken])
  if res.startsWith("ERR"):
    stderr.writeLine(res)
    quit(1)

  # Clear local mirror
  let curTaskFile = currentTaskFilePath(worker)
  if fileExists(curTaskFile):
    try: removeFile(curTaskFile) except CatchableError: discard
  let legacyTaskFile = currentTaskFilePath("")
  if fileExists(legacyTaskFile):
    try: removeFile(legacyTaskFile) except CatchableError: discard

  doAuditLog(cfg, worker, "task.complete", taskId & (if gateToken.len > 0: " (" & gateToken & ")" else: ""))
  return res

proc doDecision*(cfg: RhizoConfig, action: string, args: openArray[string]): string =
  var evalArgs: seq[string] = @[cfg.prefix, action]
  for a in args: evalArgs.add(a)
  return runLuaScript(cfg.redisUrl, decisionLua, decisionSha, evalArgs)

proc formatDecisionsTable*(jsonStr: string): string =
  try:
    let node = parseJson(jsonStr)
    if node.kind != JArray or node.len == 0:
      return "No decisions found."
    var rows: seq[(string, string, string, string, string)] = @[]
    for item in node:
      let id = item.getOrDefault("id").getStr("")
      let title = item.getOrDefault("title").getStr("")
      let status = item.getOrDefault("status").getStr("PROPOSED")
      let ruledBy = item.getOrDefault("ruled_by").getStr("-")
      let propBy = item.getOrDefault("proposed_by").getStr("-")
      rows.add((id, status, if ruledBy.len > 0: ruledBy else: "-", if propBy.len > 0: propBy else: "-", title))
    result = "DECISION ID          STATUS        RULED BY    PROPOSED BY   TITLE\n"
    result.add("---------------------------------------------------------------------------------\n")
    for (id, status, ruled, prop, title) in rows:
      result.add(id.alignLeft(21) & status.alignLeft(14) & ruled.alignLeft(12) & prop.alignLeft(14) & title & "\n")
    result = result.strip()
  except CatchableError:
    return jsonStr

proc doAuditLog*(cfg: RhizoConfig, actor, action, details: string) =
  try:
    var client = connectRedis(cfg.redisUrl)
    defer: (try: client.close() except CatchableError: discard)
    var node = newJObject()
    node["timestamp"] = %(now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"))
    node["actor"] = %actor
    node["action"] = %action
    node["details"] = %details
    discard client.lPush(cfg.prefix & "audit_trail", $node)
    client.lTrim(cfg.prefix & "audit_trail", 0, 999)
  except CatchableError:
    discard

proc doAuditList*(cfg: RhizoConfig, limit: int = 50): string =
  try:
    var client = connectRedis(cfg.redisUrl)
    defer: (try: client.close() except CatchableError: discard)
    var list = newJArray()
    let items = client.lRange(cfg.prefix & "audit_trail", 0, limit - 1)
    for it in items:
      try:
        list.add(parseJson(it))
      except CatchableError:
        discard
    return $list
  except CatchableError:
    return "[]"

proc formatAuditTable*(jsonStr: string): string =
  try:
    let node = parseJson(jsonStr)
    if node.kind != JArray or node.len == 0:
      return "No audit events recorded."
    var rows: seq[(string, string, string, string)] = @[]
    for item in node:
      let ts = item.getOrDefault("timestamp").getStr("")
      let actor = item.getOrDefault("actor").getStr("")
      let action = item.getOrDefault("action").getStr("")
      let details = item.getOrDefault("details").getStr("")
      rows.add((ts, actor, action, details))
    result = "TIMESTAMP                 ACTOR           ACTION          DETAILS\n"
    result.add("------------------------------------------------------------------------------------------------\n")
    for (ts, actor, action, details) in rows:
      result.add(ts.alignLeft(26) & actor.alignLeft(16) & action.alignLeft(16) & details & "\n")
    result = result.strip()
  except CatchableError:
    return jsonStr

proc doHistory*(cfg: RhizoConfig, targetAgent: string = "", limit: int = 50, jsonOutput: bool = false): string =
  var client = connectRedis(cfg.redisUrl)
  defer: (try: client.close() except CatchableError: discard)

  var resultList = newJArray()
  let normTarget = sanitizeIdentifier(targetAgent)
  let effectiveLimit = if limit > 0: limit else: 50

  if normTarget.len > 0:
    # 1. Non-destructively peek into inbox:<agent> using LRANGE
    let inboxItems = try: client.lRange(cfg.prefix & "inbox:" & normTarget, 0, effectiveLimit - 1) except CatchableError: @[]
    for item in inboxItems:
      try:
        var node = parseJson(item)
        node["source"] = %"inbox"
        resultList.add(node)
      except CatchableError:
        var rawNode = newJObject()
        rawNode["raw"] = %item
        rawNode["source"] = %"inbox"
        resultList.add(rawNode)

    # 2. Also search audit_trail for matching events
    let auditItems = try: client.lRange(cfg.prefix & "audit_trail", 0, effectiveLimit - 1) except CatchableError: @[]
    for item in auditItems:
      try:
        let node = parseJson(item)
        let actor = node.getOrDefault("actor").getStr("").toLowerAscii
        let details = node.getOrDefault("details").getStr("").toLowerAscii
        if actor == normTarget or details.contains(normTarget):
          var aNode = node
          aNode["source"] = %"audit"
          resultList.add(aNode)
      except CatchableError: discard
  else:
    # Cluster-wide audit trail
    let auditItems = try: client.lRange(cfg.prefix & "audit_trail", 0, effectiveLimit - 1) except CatchableError: @[]
    for item in auditItems:
      try:
        var node = parseJson(item)
        node["source"] = %"audit"
        resultList.add(node)
      except CatchableError: discard

  if jsonOutput:
    return $resultList

  if resultList.len == 0:
    return if normTarget.len > 0: "No history found for agent '" & normTarget & "'." else: "No audit events recorded."

  # Render formatted table
  var outStr = "TIMESTAMP                 SOURCE   ACTOR/FROM      TARGET/TO       TYPE/ACTION     DETAILS/SUBJECT\n"
  outStr.add("------------------------------------------------------------------------------------------------------------------\n")
  for item in resultList:
    let src = item.getOrDefault("source").getStr("inbox")
    let ts = item.getOrDefault("timestamp").getStr("-")
    let actor = if item.hasKey("from"): item["from"].getStr("") elif item.hasKey("actor"): item["actor"].getStr("") else: "-"
    let target = if item.hasKey("to"): item["to"].getStr("") else: "-"
    let action = if item.hasKey("type"): item["type"].getStr("") elif item.hasKey("action"): item["action"].getStr("") else: "-"
    let details = if item.hasKey("subject"): item["subject"].getStr("") elif item.hasKey("details"): item["details"].getStr("") else: item.getOrDefault("body").getStr("")
    outStr.add(ts.alignLeft(26) & src.alignLeft(9) & actor.alignLeft(16) & target.alignLeft(16) & action.alignLeft(16) & details & "\n")
  return outStr.strip()

proc doProbe*(cfg: RhizoConfig, agentName: string, jsonOutput: bool = false): string =
  let normName = sanitizeIdentifier(agentName)
  if normName.len == 0:
    return "Error: Missing required agent name for probe. Usage: rhizo probe <agent> [--json]"

  var client = connectRedis(cfg.redisUrl)
  defer: (try: client.close() except CatchableError: discard)

  var probeTarget = normName
  let aliasVal = try: client.hGet(cfg.prefix & "aliases", normName) except CatchableError: redisNil
  var isAlias = false
  if aliasVal != redisNil and aliasVal.len > 0:
    probeTarget = sanitizeIdentifier(aliasVal)
    isAlias = true

  let isAlive = client.exists(cfg.prefix & "heartbeat:" & probeTarget)
  let hbTtl = if isAlive: client.ttl(cfg.prefix & "heartbeat:" & probeTarget) else: -1
  let lastSeen = client.hGet(cfg.prefix & "agent:" & probeTarget, "last_seen")
  let listenerVal = client.get(cfg.prefix & "listener:" & probeTarget)
  let inboxDepth = try: client.lLen(cfg.prefix & "inbox:" & probeTarget) except CatchableError: 0

  var hasListener = false
  var listenerPid = 0
  var listenerHost = ""
  var pidAlive = false

  if listenerVal != redisNil and listenerVal.len > 0:
    try:
      let lNode = parseJson(listenerVal)
      hasListener = true
      listenerPid = lNode.getOrDefault("pid").getInt(0)
      listenerHost = lNode.getOrDefault("host").getStr("")
      if listenerHost == getHostNameStr() and listenerPid > 0:
        pidAlive = isPidAlive(listenerPid)
      else:
        pidAlive = true
    except CatchableError:
      discard

  var status = "HEALTHY"
  var issues: seq[string] = @[]

  if not isAlive:
    status = "OFFLINE"
    issues.add("Heartbeat expired (process not reporting heartbeat)")
  elif not hasListener:
    status = "NO_LISTENER"
    issues.add("No listener registered in Redis")
  elif not pidAlive:
    status = "STALLED"
    issues.add("Listener PID " & $listenerPid & " is dead on host " & listenerHost)

  if inboxDepth > 0 and (not hasListener or not pidAlive or not isAlive):
    status = "STALLED"
    issues.add("Inbox has " & $inboxDepth & " unread messages waiting with no active listener")

  if jsonOutput:
    var j = newJObject()
    j["agent"] = %normName
    if isAlias:
      j["alias_of"] = %probeTarget
    j["status"] = %status
    j["heartbeat_active"] = %isAlive
    j["heartbeat_ttl_sec"] = %hbTtl
    j["last_seen"] = %(if lastSeen != redisNil: lastSeen else: "")
    j["listener_registered"] = %hasListener
    j["listener_pid"] = %listenerPid
    j["listener_host"] = %listenerHost
    j["listener_pid_alive"] = %pidAlive
    j["inbox_depth"] = %inboxDepth
    var jIssues = newJArray()
    for iss in issues: jIssues.add(%iss)
    j["issues"] = jIssues
    return $j

  var outStr = "====================================================\n"
  if isAlias:
    outStr.add("RHIZO AGENT HEALTH PROBE: @" & normName & " (alias for @" & probeTarget & ")\n")
  else:
    outStr.add("RHIZO AGENT HEALTH PROBE: @" & normName & "\n")
  outStr.add("====================================================\n")
  outStr.add("Health Status      : " & status & "\n")
  outStr.add("Heartbeat Active   : " & (if isAlive: "YES (TTL: " & $hbTtl & "s)" else: "NO (OFFLINE)") & "\n")
  if lastSeen != redisNil and lastSeen.len > 0:
    outStr.add("Last Seen          : " & lastSeen & "\n")
  outStr.add("Listener Registered: " & (if hasListener: "YES (Host: " & listenerHost & ", PID: " & $listenerPid & ")" else: "NO") & "\n")
  if hasListener and listenerHost == getHostNameStr():
    outStr.add("Listener Process   : " & (if pidAlive: "ALIVE (PID " & $listenerPid & ")" else: "DEAD / ZOMBIE (PID " & $listenerPid & ")") & "\n")
  outStr.add("Unread Inbox Depth : " & $inboxDepth & " messages\n")
  if issues.len > 0:
    outStr.add("----------------------------------------------------\n")
    outStr.add("⚠️  ISSUES DETECTED:\n")
    for iss in issues:
      outStr.add("  - " & iss & "\n")
    outStr.add("RECOMMENDED ACTION:\n")
    if not hasListener or not pidAlive:
      outStr.add("  Run: rhizo listen " & normName & "\n")
    if not isAlive:
      outStr.add("  Run: rhizo open " & normName & "\n")
  outStr.add("====================================================")
  return outStr

proc doAliasSet*(cfg: RhizoConfig, aliasName, canonicalName: string): string =
  let normAlias = sanitizeIdentifier(aliasName)
  let normCanon = sanitizeIdentifier(canonicalName)
  var client = connectRedis(cfg.redisUrl)
  defer: (try: client.close() except CatchableError: discard)
  discard client.hSet(cfg.prefix & "aliases", normAlias, normCanon)
  return "ALIAS: @" & normAlias & " -> @" & normCanon

proc doAliasGet*(cfg: RhizoConfig, aliasName: string): string =
  let normAlias = sanitizeIdentifier(aliasName)
  var client = connectRedis(cfg.redisUrl)
  defer: (try: client.close() except CatchableError: discard)
  let val = client.hGet(cfg.prefix & "aliases", normAlias)
  if val == redisNil or val.len == 0:
    return ""
  return val

proc doAliasDel*(cfg: RhizoConfig, aliasName: string): bool =
  let normAlias = sanitizeIdentifier(aliasName)
  var client = connectRedis(cfg.redisUrl)
  defer: (try: client.close() except CatchableError: discard)
  let count = client.hDel(cfg.prefix & "aliases", @[normAlias])
  return count > 0

proc doAliasList*(cfg: RhizoConfig, jsonOutput: bool = false): string =
  var client = connectRedis(cfg.redisUrl)
  defer: (try: client.close() except CatchableError: discard)
  let rawList = client.hGetAll(cfg.prefix & "aliases")
  var map = newJObject()
  var rows: seq[(string, string)] = @[]
  var idx = 0
  while idx + 1 < rawList.len:
    let k = rawList[idx]
    let v = rawList[idx + 1]
    map[k] = %v
    rows.add((k, v))
    idx += 2
  if jsonOutput:
    return $map
  if rows.len == 0:
    return "No aliases registered."
  var outStr = "ALIAS                 CANONICAL RECIPIENT\n"
  outStr.add("----------------------------------------------------\n")
  for (k, v) in rows:
    outStr.add(k.alignLeft(22) & v & "\n")
  return outStr.strip()

proc doReroute*(cfg: RhizoConfig, fromAgent, toAgent: string, mode: string = "all", jsonOutput: bool = false): string =
  let normFrom = sanitizeIdentifier(fromAgent)
  let normTo = sanitizeIdentifier(toAgent)
  if normFrom.len == 0 or normTo.len == 0:
    return "ERR: Both source and destination agent names are required"
  if normFrom == normTo:
    return "ERR: Source and destination agents must be different"

  let res = runLuaScript(cfg.redisUrl, rerouteLua, rerouteSha, [cfg.prefix, normFrom, normTo, mode])
  if jsonOutput:
    return res

  try:
    let node = parseJson(res)
    let count = node.getOrDefault("count").getInt(0)
    let status = node.getOrDefault("status").getStr("")
    if status == "EMPTY":
      return "No messages to reroute in inbox for @" & normFrom & "."
    return "Rerouted " & $count & " message(s) from @" & normFrom & " to @" & normTo & " (status: " & status & ")."
  except CatchableError:
    return res

proc doPoke*(cfg: RhizoConfig, targetAgent: string, optCmd: string = "", force: bool = false, dryRun: bool = false, jsonOut: bool = false): string =
  let scopedTarget = ensureProjectScopedName(cfg, targetAgent)
  let cmd = if optCmd.len > 0: optCmd else: "rhizo listen " & scopedTarget

  # Probe check unless forced or dry-run
  if not force and not dryRun:
    let probeRes = doProbe(cfg, scopedTarget, jsonOutput = true)
    try:
      let pJson = parseJson(probeRes)
      let listenerStatus = pJson.getOrDefault("status").getStr("")
      let hasListener = pJson.getOrDefault("listener_registered").getBool(false)
      let pidAlive = pJson.getOrDefault("listener_pid_alive").getBool(false)
      let inboxDepth = pJson.getOrDefault("inbox_depth").getInt(0)
      if hasListener and pidAlive and inboxDepth == 0 and listenerStatus == "HEALTHY":
        if jsonOut:
          var resObj = newJObject()
          resObj["target"] = %scopedTarget
          resObj["status"] = %"SKIPPED"
          resObj["reason"] = %"ALREADY_LISTENING"
          resObj["message"] = %("@" & scopedTarget & " is already actively listening with 0 unread messages. Use --force to poke anyway.")
          return $resObj
        else:
          return "[POKE] Skipped @" & scopedTarget & ": already actively listening with 0 unread messages (use --force to poke anyway)."
    except CatchableError:
      discard

  var methodFound = "NOT_FOUND"
  var windowName = ""
  var pokeDetails = ""

  # 1. Check tmux if running
  try:
    let (tmuxCheck, code) = execCmdEx("command -v tmux")
    if code == 0:
      let (panesOut, pCode) = execCmdEx("tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}:#{window_name}:#{pane_title}'")
      if pCode == 0 and panesOut.len > 0:
        for line in panesOut.splitLines:
          let parts = line.split(":")
          if parts.len >= 3:
            let targetPane = parts[0] & ":" & parts[1]
            let winName = parts[2]
            let paneTitle = if parts.len >= 4: parts[3] else: ""
            if scopedTarget.toLowerAscii in winName.toLowerAscii or
               targetAgent.toLowerAscii in winName.toLowerAscii or
               scopedTarget.toLowerAscii in paneTitle.toLowerAscii or
               targetAgent.toLowerAscii in paneTitle.toLowerAscii:
              methodFound = "tmux"
              windowName = winName
              if not dryRun:
                discard execCmdEx("tmux send-keys -t " & quoteShell(targetPane) & " " & quoteShell(cmd) & " C-m")
              pokeDetails = "tmux pane " & targetPane & " (" & winName & ")"
              break
  except CatchableError:
    discard

  # 2. On macOS, check Ghostty, Terminal, iTerm2, and System Events
  when defined(macosx) or defined(darwin):
    if methodFound == "NOT_FOUND":
      let appleScript = """
on run argv
  set target to item 1 of argv
  set cmd to item 2 of argv
  set isDry to (item 3 of argv = "true")

  tell application "System Events"
    set runningProcs to name of every process whose background only is false
  end tell

  -- 1. Ghostty
  if runningProcs contains "ghostty" or runningProcs contains "Ghostty" then
    try
      tell application "Ghostty"
        repeat with w in windows
          if (name of w contains target) then
            if not isDry then
              set term to focused terminal of selected tab of w
              input text cmd to term
              send key "enter" to term
            end if
            return "ghostty::" & (name of w)
          end if
        end repeat
      end tell
    end try
  end if

  -- 2. Terminal.app
  if runningProcs contains "Terminal" then
    try
      tell application "Terminal"
        repeat with w in windows
          if (name of w contains target) or (custom title of current settings of selected tab of w contains target) then
            if not isDry then
              do script cmd in selected tab of w
            end if
            return "terminal::" & (name of w)
          end if
        end repeat
      end tell
    end try
  end if

  -- 3. iTerm2
  if runningProcs contains "iTerm2" or runningProcs contains "iTerm" then
    try
      tell application "iTerm2"
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              if (name of s contains target) then
                if not isDry then
                  tell s to write text cmd
                end if
                return "iterm2::" & (name of s)
              end if
            end repeat
          end repeat
        end repeat
      end tell
    end try
  end if

  -- 4. Dedicated Terminal Emulators and GUI Windows via System Events
  set termEmulators to {"alacritty", "kitty", "wezterm", "hyper", "warp"}
  repeat with pName in runningProcs
    try
      set pLower to pName as text
      set isTerm to false
      repeat with termApp in termEmulators
        if pLower contains termApp then set isTerm to true
      end repeat

      tell application "System Events"
        tell process pName
          repeat with w in (every window)
            if (name of w contains target) then
              if not isDry then
                set frontmost to true
                perform action "AXRaise" of w
                if isTerm then
                  keystroke cmd & return
                else
                  display notification "Worker @" & target & " directive: " & cmd with title "Rhizo Doorbell Wakeup"
                end if
              end if
              return (pName as text) & "::" & (name of w)
            end if
          end repeat
        end tell
      end tell
    end try
  end repeat

  return "NOT_FOUND"
end run
"""
      try:
        let isDryStr = if dryRun: "true" else: "false"
        let (asOut, asCode) = execCmdEx("osascript -e " & quoteShell(appleScript) & " " & quoteShell(scopedTarget) & " " & quoteShell(cmd) & " " & quoteShell(isDryStr))
        let trimmed = asOut.strip()
        if asCode == 0 and trimmed != "NOT_FOUND" and trimmed.contains("::"):
          let parts = trimmed.split("::", 1)
          methodFound = parts[0]
          windowName = parts[1]
          pokeDetails = methodFound & " window '" & windowName & "'"
        elif asCode == 0 and trimmed == "NOT_FOUND" and scopedTarget != targetAgent:
          let (asOut2, asCode2) = execCmdEx("osascript -e " & quoteShell(appleScript) & " " & quoteShell(targetAgent) & " " & quoteShell(cmd) & " " & quoteShell(isDryStr))
          let trimmed2 = asOut2.strip()
          if asCode2 == 0 and trimmed2 != "NOT_FOUND" and trimmed2.contains("::"):
            let parts = trimmed2.split("::", 1)
            methodFound = parts[0]
            windowName = parts[1]
            pokeDetails = methodFound & " window '" & windowName & "'"
      except CatchableError:
        discard

  var resObj = newJObject()
  resObj["target"] = %scopedTarget
  resObj["command"] = %cmd
  resObj["method"] = %methodFound
  resObj["window"] = %windowName
  resObj["dry_run"] = %dryRun

  if methodFound != "NOT_FOUND":
    resObj["status"] = if dryRun: %"FOUND" else: %"POKED"
    let actionWord = if dryRun: "Found target" else: "Poked @" & scopedTarget
    resObj["message"] = %(actionWord & " in " & pokeDetails & " with doorbell: " & cmd)
    if jsonOut:
      return $resObj
    else:
      let checkMark = if dryRun: "ℹ" else: "✓"
      return checkMark & " [POKE] " & (if dryRun: "Found window for @" & scopedTarget else: "Poked @" & scopedTarget) & " via " & methodFound & "\n" &
             "  Window  : " & windowName & "\n" &
             "  Command : " & cmd
  else:
    resObj["status"] = %"NOT_FOUND"
    resObj["message"] = %("Could not find an active window/tab matching @" & scopedTarget & " or '" & targetAgent & "'.")
    if jsonOut:
      return $resObj
    else:
      return "⚠️ [POKE] Window not found for @" & scopedTarget & "\n" &
             "  Ensure worker's window or tab title contains the agent codename (e.g. via 'rhizo open " & scopedTarget & "')."

proc doWatchdogCheck*(cfg: RhizoConfig, agentNameParam: string = "", jsonOutput: bool = false, expectListening: bool = false, streakOverride: int = -1): tuple[output: string, exitCode: int] =
  var normName = sanitizeIdentifier(agentNameParam)
  if normName.len == 0:
    normName = sanitizeIdentifier(getActiveAgentName(cfg, ""))
  if normName.len == 0:
    let sessPath = getHomeDir() / ".config" / "rhizo" / "sessions.json"
    if fileExists(sessPath):
      try:
        let sNode = parseFile(sessPath)
        if sNode.kind == JObject:
          for k, v in sNode:
            if v.kind == JObject and v.getOrDefault("status").getStr("") == "active":
              normName = sanitizeIdentifier(v.getOrDefault("agent").getStr(""))
              if normName.len > 0: break
            elif v.kind == JString and v.getStr("").len > 0:
              normName = sanitizeIdentifier(v.getStr(""))
              break
      except CatchableError: discard

  if normName.len == 0:
    let errStr = "Error: Missing required agent name for watchdog check. Usage: rhizo watchdog [check] [--agent <name>] [--json]"
    if jsonOutput:
      var j = newJObject()
      j["error"] = %errStr
      return ($j, 1)
    return (errStr, 1)

  var client = connectRedis(cfg.redisUrl)
  defer: (try: client.close() except CatchableError: discard)

  var probeTarget = normName
  let aliasVal = try: client.hGet(cfg.prefix & "aliases", normName) except CatchableError: redisNil
  var isAlias = false
  if aliasVal != redisNil and aliasVal.len > 0:
    probeTarget = sanitizeIdentifier(aliasVal)
    isAlias = true

  let isAlive = client.exists(cfg.prefix & "heartbeat:" & probeTarget)
  let listenerVal = client.get(cfg.prefix & "listener:" & probeTarget)
  let inboxDepth = try: client.lLen(cfg.prefix & "inbox:" & probeTarget) except CatchableError: 0

  var hasListener = false
  var listenerPid = 0
  var listenerHost = ""
  var pidAlive = false

  if listenerVal != redisNil and listenerVal.len > 0:
    try:
      let lNode = parseJson(listenerVal)
      hasListener = true
      listenerPid = lNode.getOrDefault("pid").getInt(0)
      listenerHost = lNode.getOrDefault("host").getStr("")
      if listenerHost == getHostNameStr() and listenerPid > 0:
        pidAlive = isPidAlive(listenerPid)
      else:
        pidAlive = true
    except CatchableError:
      discard

  let listenerActive = hasListener and pidAlive

  var tasksInFlight = 0
  # 1. Count active/queued tasks in Redis
  try:
    let inflightRes = runLuaScript(cfg.redisUrl, watchdogInflightLua, watchdogInflightSha, [cfg.prefix])
    tasksInFlight += parseInt(inflightRes.strip())
  except CatchableError:
    discard

  # 2. Check local .vine.json for active strands in workspace
  if fileExists(".vine.json"):
    try:
      let vj = parseFile(".vine.json")
      if vj.hasKey("strands") and vj["strands"].kind == JObject:
        for sname, sobj in vj["strands"]:
          let st = sobj.getOrDefault("status").getStr("")
          if st in ["PROVISIONED", "ACTIVE", "READY_FOR_WEAVE", "GATE_EVALUATING", "GATE_FAILED"]:
            inc tasksInFlight
    except CatchableError:
      discard

  # 3. Check sessions.json for active tasks
  let sessPath = getHomeDir() / ".config" / "rhizo" / "sessions.json"
  if fileExists(sessPath):
    try:
      let sNode = parseFile(sessPath)
      if sNode.kind == JObject:
        for k, v in sNode:
          if v.kind == JObject:
            let st = v.getOrDefault("status").getStr("")
            let tid = v.getOrDefault("task_id").getStr("")
            if st != "closed" and tid.len > 0:
              inc tasksInFlight
    except CatchableError:
      discard

  var status = "OK"
  var substatus = "LISTENING"
  var actionRequired = false
  var exitCode = 0
  var recommendedCommand = "none"
  var message = ""
  let watchdogKey = cfg.prefix & "watchdog:" & probeTarget
  var currentStreak = 0
  var recommendedCadence = 900
  var nextAction = "SCHEDULE_TIMER"

  if inboxDepth > 0:
    status = "ACTION_REQUIRED"
    substatus = "UNREAD_MESSAGES"
    actionRequired = true
    exitCode = 2
    recommendedCadence = 900
    nextAction = "SCHEDULE_TIMER"
    recommendedCommand = if not listenerActive: "rhizo listen " & normName else: "rhizo drain 10 " & normName
    message = "Agent @" & normName & " has " & $inboxDepth & " unread message(s) waiting in inbox."
    try: discard client.hSet(watchdogKey, "streak", "0") except CatchableError: discard
  elif not listenerActive:
    if expectListening or tasksInFlight > 0:
      status = "ACTION_REQUIRED"
      substatus = "REARM_LISTENER"
      actionRequired = true
      exitCode = 2
      recommendedCadence = 900
      nextAction = "SCHEDULE_TIMER"
      recommendedCommand = "rhizo listen " & normName
      message = "Agent @" & normName & " has " & $tasksInFlight & " in-flight task(s), but listener is dead or not running."
      try: discard client.hSet(watchdogKey, "streak", "0") except CatchableError: discard
    else:
      status = "STAND_DOWN"
      substatus = "IDLE"
      actionRequired = false
      exitCode = 0
      recommendedCadence = 0
      nextAction = "STAND_DOWN"
      recommendedCommand = "none"
      message = "Agent @" & normName & " is idle with zero unread messages and zero in-flight tasks. Listener not required."
      try: discard client.hSet(watchdogKey, "streak", "0") except CatchableError: discard
  else:
    if streakOverride >= 0:
      currentStreak = streakOverride
    else:
      try:
        let sVal = client.hGet(watchdogKey, "streak")
        if sVal != redisNil and sVal.len > 0:
          currentStreak = parseInt(sVal)
      except CatchableError:
        currentStreak = 0

    inc currentStreak

    if currentStreak == 1:
      recommendedCadence = 1800 # 30m
      status = "OK"
      substatus = "LISTENING"
      exitCode = 0
      nextAction = "SCHEDULE_TIMER"
      message = "Agent @" & normName & " listener is active and healthy (PID " & $listenerPid & " on " & listenerHost & "). Quiescent streak: 1/4 (next check in 30m)."
    elif currentStreak == 2:
      recommendedCadence = 3600 # 60m
      status = "OK"
      substatus = "LISTENING"
      exitCode = 0
      nextAction = "SCHEDULE_TIMER"
      message = "Agent @" & normName & " listener is active and healthy (PID " & $listenerPid & " on " & listenerHost & "). Quiescent streak: 2/4 (next check in 60m)."
    elif currentStreak == 3:
      recommendedCadence = 7200 # 120m
      status = "OK"
      substatus = "LISTENING"
      exitCode = 0
      nextAction = "SCHEDULE_TIMER"
      message = "Agent @" & normName & " listener is active and healthy (PID " & $listenerPid & " on " & listenerHost & "). Quiescent streak: 3/4 (next check in 120m)."
    else:
      # currentStreak >= 4: Max streak reached!
      status = "STAND_DOWN"
      substatus = "MAX_STREAK_REACHED"
      actionRequired = false
      exitCode = 0
      recommendedCadence = 0
      nextAction = "STAND_DOWN"
      message = "Agent @" & normName & " listener has remained continuously stable and idle across " & $currentStreak & " checks. Watchdog standing down."

    try:
      discard client.hSet(watchdogKey, "streak", $currentStreak)
      discard client.hSet(watchdogKey, "last_check", $int(getTime().toUnix()))
      discard client.hSet(watchdogKey, "cadence", $recommendedCadence)
      discard client.expire(watchdogKey, 86400)
    except CatchableError: discard

  if jsonOutput:
    var j = newJObject()
    j["agent"] = %normName
    if isAlias:
      j["alias_of"] = %probeTarget
    j["status"] = %status
    j["substatus"] = %substatus
    j["listener_active"] = %listenerActive
    j["listener_registered"] = %hasListener
    j["listener_pid"] = %listenerPid
    j["listener_host"] = %listenerHost
    j["listener_pid_alive"] = %pidAlive
    j["heartbeat_active"] = %isAlive
    j["inbox_depth"] = %inboxDepth
    j["tasks_in_flight"] = %tasksInFlight
    j["action_required"] = %actionRequired
    j["recommended_command"] = %recommendedCommand
    j["streak"] = %currentStreak
    j["max_streak"] = %4
    j["recommended_cadence"] = %recommendedCadence
    j["next_action"] = %nextAction
    j["message"] = %message
    return ($j, exitCode)

  var outStr = "====================================================\n"
  if isAlias:
    outStr.add("RHIZO WATCHDOG CHECK: @" & normName & " (alias for @" & probeTarget & ")\n")
  else:
    outStr.add("RHIZO WATCHDOG CHECK: @" & normName & "\n")
  outStr.add("====================================================\n")
  outStr.add("Status             : " & status & " (" & substatus & ")\n")
  outStr.add("Listener Active    : " & (if listenerActive: "YES (PID " & $listenerPid & " on " & listenerHost & ")" else: "NO") & "\n")
  outStr.add("Inbox Depth        : " & $inboxDepth & " messages\n")
  outStr.add("Tasks In Flight    : " & $tasksInFlight & "\n")
  outStr.add("Quiescent Streak   : " & $currentStreak & "/4\n")
  if recommendedCadence > 0:
    outStr.add("Recommended Cadence: " & $(recommendedCadence div 60) & " minutes (" & $recommendedCadence & "s)\n")
  else:
    outStr.add("Recommended Cadence: none (stand down)\n")
  outStr.add("Next Action        : " & nextAction & "\n")
  outStr.add("Action Required    : " & (if actionRequired: "YES" else: "NO") & "\n")
  if recommendedCommand != "none":
    outStr.add("Recommended Command: " & recommendedCommand & "\n")
  outStr.add("Details            : " & message & "\n")
  outStr.add("====================================================")
  return (outStr, exitCode)

proc doWatchdogReset*(cfg: RhizoConfig, agentNameParam: string = "", jsonOutput: bool = false): tuple[output: string, exitCode: int] =
  var normName = sanitizeIdentifier(agentNameParam)
  if normName.len == 0:
    normName = sanitizeIdentifier(getActiveAgentName(cfg, ""))
  if normName.len == 0:
    let sessPath = getHomeDir() / ".config" / "rhizo" / "sessions.json"
    if fileExists(sessPath):
      try:
        let sNode = parseFile(sessPath)
        if sNode.kind == JObject:
          for k, v in sNode:
            if v.kind == JObject and v.getOrDefault("status").getStr("") == "active":
              normName = sanitizeIdentifier(v.getOrDefault("agent").getStr(""))
              if normName.len > 0: break
            elif v.kind == JString and v.getStr("").len > 0:
              normName = sanitizeIdentifier(v.getStr(""))
              break
      except CatchableError: discard

  if normName.len == 0:
    let errStr = "Error: Missing required agent name for watchdog reset. Usage: rhizo watchdog reset [--agent <name>] [--json]"
    if jsonOutput:
      var j = newJObject()
      j["error"] = %errStr
      return ($j, 1)
    return (errStr, 1)

  var client = connectRedis(cfg.redisUrl)
  defer: (try: client.close() except CatchableError: discard)

  var probeTarget = normName
  let aliasVal = try: client.hGet(cfg.prefix & "aliases", normName) except CatchableError: redisNil
  if aliasVal != redisNil and aliasVal.len > 0:
    probeTarget = sanitizeIdentifier(aliasVal)

  let watchdogKey = cfg.prefix & "watchdog:" & probeTarget
  try:
    discard client.hSet(watchdogKey, "streak", "0")
    discard client.hSet(watchdogKey, "last_reset", $int(getTime().toUnix()))
  except CatchableError as e:
    let errStr = "Failed to reset watchdog streak: " & e.msg
    if jsonOutput:
      var j = newJObject()
      j["error"] = %errStr
      return ($j, 1)
    return (errStr, 1)

  if jsonOutput:
    var j = newJObject()
    j["agent"] = %normName
    j["status"] = %"OK"
    j["streak"] = %0
    j["recommended_cadence"] = %900
    j["next_action"] = %"SCHEDULE_TIMER"
    j["message"] = %("Watchdog streak reset to 0 for @" & normName & ". Next timer should use base 15m (900s).")
    return ($j, 0)

  return ("Watchdog streak reset to 0 for @" & normName & " (base cadence: 15m / 900s).", 0)

proc doHookCodexStop*(cfg: RhizoConfig, agentNameParam: string = "", expectWorker: bool = false): string =
  var normName = sanitizeIdentifier(agentNameParam)
  if normName.len == 0:
    normName = sanitizeIdentifier(getActiveAgentName(cfg, ""))
  if normName.len == 0:
    let sessPath = getHomeDir() / ".config" / "rhizo" / "sessions.json"
    if fileExists(sessPath):
      try:
        let sNode = parseFile(sessPath)
        if sNode.kind == JObject:
          for k, v in sNode:
            if v.kind == JObject and v.getOrDefault("status").getStr("") == "active":
              normName = sanitizeIdentifier(v.getOrDefault("agent").getStr(""))
              if normName.len > 0: break
            elif v.kind == JString and v.getStr("").len > 0:
              normName = sanitizeIdentifier(v.getStr(""))
              break
      except CatchableError: discard

  # Fail-open if no agent can be resolved
  if normName.len == 0:
    return "{}"

  var client: Redis
  try:
    client = connectRedis(cfg.redisUrl)
  except CatchableError:
    return "{}"
  defer:
    try: client.close() except CatchableError: discard

  var probeTarget = normName
  let aliasVal = try: client.hGet(cfg.prefix & "aliases", normName) except CatchableError: redisNil
  if aliasVal != redisNil and aliasVal.len > 0:
    probeTarget = sanitizeIdentifier(aliasVal)

  let inboxKey = cfg.prefix & "inbox:" & probeTarget
  let inboxDepth = try:
    client.lLen(inboxKey)
  except CatchableError:
    0

  # Thrash valve to prevent trapping turns forever:
  let thrashKey = cfg.prefix & "hook_blocks:" & probeTarget
  var blockCount = 0
  try:
    let bVal = client.get(thrashKey)
    if bVal != redisNil and bVal.len > 0:
      blockCount = parseInt(bVal)
  except CatchableError:
    blockCount = 0

  if blockCount >= 3:
    return "{}"

  # 0. Active unacknowledged work item check (Local stamp + Redis state)
  let agentTaskFile = currentTaskFilePath(probeTarget)
  let legacyTaskFile = currentTaskFilePath("")
  var pendingTaskPayload = ""
  if fileExists(agentTaskFile):
    try:
      let rawStamp = readFile(agentTaskFile).strip()
      let sNode = parseJson(rawStamp)
      let owner = sNode.getOrDefault("owner").getStr(sNode.getOrDefault("target").getStr(sNode.getOrDefault("to").getStr("")))
      if owner.len == 0 or sanitizeIdentifier(owner) == probeTarget:
        pendingTaskPayload = rawStamp
    except CatchableError: discard
  elif fileExists(legacyTaskFile):
    try:
      let rawStamp = readFile(legacyTaskFile).strip()
      let sNode = parseJson(rawStamp)
      let owner = sNode.getOrDefault("owner").getStr(sNode.getOrDefault("target").getStr(sNode.getOrDefault("to").getStr("")))
      if owner.len == 0 or sanitizeIdentifier(owner) == probeTarget:
        pendingTaskPayload = rawStamp
    except CatchableError: discard

  if pendingTaskPayload.len == 0:
    let cTaskStr = doTask(cfg, "current", [probeTarget])
    if cTaskStr.len > 0 and cTaskStr != "{}":
      pendingTaskPayload = cTaskStr

  if pendingTaskPayload.len > 0:
    try:
      let tNode = parseJson(pendingTaskPayload)
      let tState = tNode.getOrDefault("state").getStr("DELIVERED")
      if tState in ["DELIVERED", "CLAIMED", "IN_PROGRESS"]:
        let tid = tNode.getOrDefault("id").getStr("")
        let tTitle = tNode.getOrDefault("title").getStr(tNode.getOrDefault("subject").getStr(""))
        let tSpec = tNode.getOrDefault("spec").getStr(tNode.getOrDefault("body").getStr(""))
        
        let newCount = client.incr(thrashKey)
        if newCount == 1:
          discard client.expire(thrashKey, 60)

        var reason = "🚨 [CRITICAL RHIZO INTERLOCK] You have an UNACKNOWLEDGED ACTIVE TASK waiting for execution (@" & normName & ")!\n\n"
        reason.add("Task ID: " & tid & "\n")
        reason.add("Title: " & tTitle & "\n")
        reason.add("State: " & tState & "\n")
        if tSpec.len > 0:
          reason.add("Instructions / Spec:\n" & tSpec & "\n\n")
        reason.add("MANDATORY DIRECTIVE: You are an autonomous cluster worker. DO NOT yield your turn with unhandled tasks! Claim the task ('rhizo task claim " & tid & "'), execute in your Vine strand, verify with 'vine gate', and rearm your listener ('rhizo listen " & normName & "') before completing your turn.")

        var jOut = newJObject()
        jOut["decision"] = %"block"
        jOut["reason"] = %reason
        return $jOut
    except CatchableError: discard

  # 1. Unread inbox backlog
  if inboxDepth > 0:
    try:
      let newCount = client.incr(thrashKey)
      if newCount == 1:
        discard client.expire(thrashKey, 60)
    except CatchableError: discard

    let messagesText = doDrain(cfg, probeTarget, 10, "hook")
    var reason = "🚨 [CRITICAL RHIZO INTERLOCK] You have " & $inboxDepth & " unread message(s) waiting in your Rhizo inbox (@" & normName & ")!\n\n"
    if messagesText.len > 0:
      reason.add(messagesText & "\n\n")
    reason.add("MANDATORY DIRECTIVE: You are an autonomous cluster worker. DO NOT yield your turn with unhandled messages! Read the tasks above, execute them immediately in your Vine strand, and rearm your listener ('rhizo listen " & normName & "') before completing your turn.")
    
    var jOut = newJObject()
    jOut["decision"] = %"block"
    jOut["reason"] = %reason
    return $jOut

  # 2. Dead listener check for registered agents
  let agentKey = cfg.prefix & "agent:" & probeTarget
  let heartbeatKey = cfg.prefix & "heartbeat:" & probeTarget
  let isRegistered = try:
    client.exists(heartbeatKey) or client.exists(agentKey)
  except CatchableError:
    false

  if isRegistered:
    let listenerKey = cfg.prefix & "listener:" & probeTarget
    let listenerVal = try: client.get(listenerKey) except CatchableError: redisNil
    var listenerActive = false
    if listenerVal != redisNil and listenerVal.len > 0:
      try:
        let lNode = parseJson(listenerVal)
        let pid = lNode.getOrDefault("pid").getInt(0)
        let host = lNode.getOrDefault("host").getStr("")
        let myHost = getHostName()
        if host == myHost and pid > 0:
          listenerActive = isPidAlive(pid)
        else:
          listenerActive = true
      except CatchableError:
        listenerActive = false

    if not listenerActive:
      try:
        let newCount = client.incr(thrashKey)
        if newCount == 1:
          discard client.expire(thrashKey, 60)
      except CatchableError: discard

      var reason = "🚨 [CRITICAL RHIZO INTERLOCK] Your listener is DEAD! You are registered in the cluster as @" & normName & ".\n"
      reason.add("Under the Turn-End Listener Invariant, you MUST NEVER yield your turn without leaving an active background listener running.\n")
      reason.add("If you yield without a listener, you will become deaf to peer updates and incoming task dispatches.\n\n")
      reason.add("ACTION REQUIRED RIGHT NOW: Launch a background listener before concluding your turn:\n")
      reason.add("  Command: rhizo listen " & normName & "\n")
      reason.add("  Capability Tier: In Codex/Claude, spawn a background subagent to run 'rhizo listen " & normName & "'. In Antigravity, use run_command(..., IsDaemon=true).")

      var jOut = newJObject()
      jOut["decision"] = %"block"
      jOut["reason"] = %reason
      return $jOut

  try:
    discard client.del(@[thrashKey])
  except CatchableError: discard

  return "{}"

proc doHookInstall*(cfg: RhizoConfig, targetHarness: string = "codex", agentNameParam: string = "", isGlobal: bool = false): string =
  var normName = sanitizeIdentifier(agentNameParam)
  if normName.len == 0:
    normName = sanitizeIdentifier(getActiveAgentName(cfg, ""))

  let exePath = getAppFilename()
  let targetCmd = if normName.len > 0:
    "sh -c 'export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:$PATH\"; " & quoteShell(exePath) & " hook codex-stop --agent " & normName & "'"
  else:
    "sh -c 'export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:$PATH\"; " & quoteShell(exePath) & " hook codex-stop'"

  case targetHarness.toLowerAscii
  of "codex":
    let targetDir = if isGlobal:
      getHomeDir() / ".codex"
    else:
      getCurrentDir() / ".codex"
    createDir(targetDir)
    let hooksFile = targetDir / "hooks.json"
    
    var rootNode = newJObject()
    if fileExists(hooksFile):
      try:
        rootNode = parseFile(hooksFile)
      except CatchableError:
        rootNode = newJObject()

    if not rootNode.hasKey("hooks") or rootNode["hooks"].kind != JObject:
      rootNode["hooks"] = newJObject()

    var stopHooks = newJArray()
    if rootNode["hooks"].hasKey("Stop") and rootNode["hooks"]["Stop"].kind == JArray:
      stopHooks = rootNode["hooks"]["Stop"]

    var alreadyRegistered = false
    for item in stopHooks:
      if item.kind == JObject:
        let cmd = item.getOrDefault("command").getStr("")
        if "rhizo hook" in cmd or "codex_stop_hook" in cmd:
          alreadyRegistered = true
          item["command"] = %targetCmd
          break
        if item.hasKey("hooks") and item["hooks"].kind == JArray:
          for subItem in item["hooks"]:
            if subItem.kind == JObject:
              let subCmd = subItem.getOrDefault("command").getStr("")
              if "rhizo hook" in subCmd or "codex_stop_hook" in subCmd:
                alreadyRegistered = true
                subItem["command"] = %targetCmd
                break

    if not alreadyRegistered:
      var entry = newJObject()
      entry["type"] = %"command"
      entry["command"] = %targetCmd
      stopHooks.add(entry)

    rootNode["hooks"]["Stop"] = stopHooks
    writeFile(hooksFile, pretty(rootNode, 2) & "\n")
    return "✓ Successfully installed Rhizo Stop hook in " & hooksFile & "\n  Command: " & targetCmd

  of "claude":
    let settingsFile = getHomeDir() / ".claude" / "settings.json"
    var rootNode = newJObject()
    if fileExists(settingsFile):
      try:
        rootNode = parseFile(settingsFile)
      except CatchableError:
        rootNode = newJObject()

    if not rootNode.hasKey("hooks") or rootNode["hooks"].kind != JObject:
      rootNode["hooks"] = newJObject()

    var stopHooks = newJArray()
    if rootNode["hooks"].hasKey("Stop") and rootNode["hooks"]["Stop"].kind == JArray:
      stopHooks = rootNode["hooks"]["Stop"]

    var alreadyRegistered = false
    for item in stopHooks:
      if item.kind == JObject:
        if item.hasKey("hooks") and item["hooks"].kind == JArray:
          for subItem in item["hooks"]:
            if subItem.kind == JObject and "rhizo hook" in subItem.getOrDefault("command").getStr(""):
              alreadyRegistered = true
              subItem["command"] = %targetCmd
              break

    if not alreadyRegistered:
      var hookObj = newJObject()
      hookObj["type"] = %"command"
      hookObj["command"] = %targetCmd
      hookObj["timeout"] = %10
      hookObj["rhizo_managed"] = %true

      var wrapper = newJObject()
      var arr = newJArray()
      arr.add(hookObj)
      wrapper["hooks"] = arr
      stopHooks.add(wrapper)

    rootNode["hooks"]["Stop"] = stopHooks
    writeFile(settingsFile, pretty(rootNode, 2) & "\n")
    return "✓ Successfully installed Rhizo Stop hook in " & settingsFile & "\n  Command: " & targetCmd

  else:
    return "Error: Unknown harness '" & targetHarness & "'. Supported: codex, claude"

# Main Entrypoint / CLI Router
proc main() =
  installSignalHandlers()
  randomize()
  let rawArgs = commandLineParams()
  var cli: CliOverrides
  var positionalArgs: seq[string] = @[]

  var i = 0
  while i < rawArgs.len:
    let a = rawArgs[i]
    if a.startsWith("--profile="):
      cli.profile = a[10..^1]
    elif a == "--profile" and i + 1 < rawArgs.len:
      cli.profile = rawArgs[i+1]; inc i
    elif a.startsWith("--config="):
      cli.configFile = a[9..^1]
    elif a == "--config" and i + 1 < rawArgs.len:
      cli.configFile = rawArgs[i+1]; inc i
    elif a.startsWith("--redis-url="):
      cli.redisUrl = a[12..^1]
    elif a.startsWith("--valkey-url="):
      cli.redisUrl = a[13..^1]
    elif (a == "--redis-url" or a == "--valkey-url" or a == "-u") and i + 1 < rawArgs.len:
      cli.redisUrl = rawArgs[i+1]; inc i
    elif a.startsWith("-u="):
      cli.redisUrl = a[3..^1]
    elif a.startsWith("--prefix="):
      cli.prefix = a[9..^1]
    elif a == "--prefix" and i + 1 < rawArgs.len and not rawArgs[i+1].startsWith("-"):
      cli.prefix = rawArgs[i+1]; inc i
    elif a.startsWith("--project="):
      cli.project = a[10..^1]
    elif a == "--project":
      let isConfigInit = ("config" in rawArgs) and ("init" in rawArgs)
      if not isConfigInit and i + 1 < rawArgs.len and not rawArgs[i+1].startsWith("-"):
        cli.project = rawArgs[i+1]; inc i
      else:
        positionalArgs.add(a)
    elif a.startsWith("--agent-name="):
      cli.agentName = a[13..^1]
    elif a == "--agent-name" and i + 1 < rawArgs.len and not rawArgs[i+1].startsWith("-"):
      cli.agentName = rawArgs[i+1]; inc i
    elif a.startsWith("--session-id="):
      cli.sessionId = a[13..^1]
    elif (a == "--session-id" or a == "-s") and i + 1 < rawArgs.len and not rawArgs[i+1].startsWith("-"):
      cli.sessionId = rawArgs[i+1]; inc i
    elif a.startsWith("--secret="):
      cli.secret = a[9..^1]
    elif a == "--secret" and i + 1 < rawArgs.len and not rawArgs[i+1].startsWith("-"):
      cli.secret = rawArgs[i+1]; inc i
    elif a.startsWith("--secret-file="):
      cli.secretFile = a[14..^1]
    elif a == "--secret-file" and i + 1 < rawArgs.len and not rawArgs[i+1].startsWith("-"):
      cli.secretFile = rawArgs[i+1]; inc i
    elif a == "--encrypt":
      cli.encrypt = some(true)
    elif a == "--no-encrypt":
      cli.encrypt = some(false)
    elif a == "--cluster":
      cli.cluster = some(true)
    elif a == "--no-cluster":
      cli.cluster = some(false)
    elif a.startsWith("--timeout="):
      cli.timeout = some(parseRequiredInt(a[10..^1], "--timeout"))
    elif a == "--timeout" and i + 1 < rawArgs.len:
      cli.timeout = some(parseRequiredInt(rawArgs[i+1], "--timeout"))
      inc i
    else:
      positionalArgs.add(a)
    inc i

  let cfg = resolveConfig(cli)
  var args = positionalArgs

  if "-v" in rawArgs or "--version" in rawArgs or (args.len > 0 and args[0].toLowerAscii == "version"):
    echo "rhizo " & RhizoVersion
    return

  if args.len == 0 or args[0] in ["-h", "--help", "help"]:
    echo "Rhizo " & RhizoVersion & " - High Performance Inter-Assistant Redis Bus (Nim Native)"
    echo "Usage:"
    echo "  rhizo version"
    echo "  rhizo name [prefix] [--ttl <sec>] [--json]"
    echo "  rhizo open [name] [tags] [--listen/-l]"
    echo "  rhizo listen [name] [--timeout <sec>] [--force/-f] [--notify/-n] [--quiet/-q] (default timeout: 0 / infinite)"
    echo "  rhizo send --to <agent> [--type task|query|reply|status] --subject <subj> --body <body> [--listen/-l]"
    echo "  rhizo reply --to <agent> --subject <subj> --body <body> [--reply-to <id>] [--listen/-l]"
    echo "  rhizo broadcast [--tags <tags>] --subject <subj> --body <body>"
    echo "  rhizo request --to <agent> --subject <subj> --body <body> [--timeout 30] [--raw]"
    echo "  rhizo scatter --targets <@tag|agents|*> --subject <subj> --body <body> [--quorum N] [--timeout 30] [--raw]"
    echo "  rhizo enqueue <queue_name> --subject <subj> --body <body>"
    echo "  rhizo enqueue --route <task_text> [--routes-file <file>] [--service-url <url>] [--model <model>] [--api-key <key>]"
    echo "  rhizo route <task_text> [--routes-file <file>] [--service-url <url>] [--model <model>] [--api-key <key>]"
    echo "  rhizo route <lint|check> [--routes-file <file>] [--check-service]"
    echo "  rhizo route init [--global] [--force]"
    echo "  rhizo work <queue_name> [--timeout <sec>] [--run-id <id>] (default timeout: 0 / infinite)"
    echo "  rhizo claim <queue_name> [--timeout <sec>] [--lease 120] [--run-id <id>] [--raw]"
    echo "  rhizo ack <queue_name> <task_id>"
    echo "  rhizo blackboard <set|get|append|snapshot|load|delete|clear> <room> [key] [value]"
    echo "  rhizo floor <request|yield|pass|status> <room> [args...]"
    echo "  rhizo cancel <run_id> [--reason <reason>] | check <run_id> | clear <run_id>"
    echo "  rhizo ballot <open|cast|tally|status> <ballot_id> [args...]"
    echo "  rhizo leader <acquire|renew|resign|status> <role> [args...]"
    echo "  rhizo workflow <define|next|resolve|fail|status|export|import> <flow_id> [args...]"
    echo "  rhizo status <idle|busy|error> [activity_text] [name] [--listen/-l]"
    echo "  rhizo lock <lock_name> [ttl_sec] [--fencing] [--raw]"
    echo "  rhizo unlock <lock_name>"
    echo "  rhizo pub <channel> <message>"
    echo "  rhizo sub <channel> [timeout_sec]"
    echo "  rhizo who [-a|--all] [--json] [filter_tag]"
    echo "  rhizo probe <agent> [--json]"
    echo "  rhizo poke <agent> [--cmd <command>] [--force/-f] [--dry-run/-n] [--json]"
    echo "  rhizo title [name]"
    echo "  rhizo watchdog [check|reset] [agent] [--agent <name>] [--expect-listening] [--streak <N>] [--json]"
    echo "  rhizo sweep [--dry-run] [--raw]"
    echo "  rhizo tag <add|remove|set> <tags> [name]"
    echo "  rhizo check-inbox [name]"
    echo "  rhizo drain [count] [name] [--format json|hook|raw] [--hook]"
    echo "  rhizo ping [--json]"
    echo "  rhizo close [name]"
    echo "  rhizo reset [project] [--all/-a] [--json]"
    echo "  rhizo nuke [--json]"
    echo "  rhizo get-secret"
    echo "  rhizo config <show|get|path|init>"
    echo "  rhizo guide <install|uninstall|check> [path]"
    echo ""
    echo "Global Options:"
    echo "  --version, -v         Print version and exit"
    echo "  --profile <name>      Select configuration profile from config file"
    echo "  --config <file>       Explicit configuration file path"
    echo "  --redis-url, --valkey-url, -u <url> Redis / Valkey connection endpoint"
    echo "  --prefix <pfx>        Key namespace prefix"
    echo "  --project <proj>      Project isolation group"
    echo "  --encrypt             Enable AES-256-CBC payload encryption"
    echo "  --cluster             Enable Redis Cluster hash tag compatibility"
    return

  let subcmd = args[0].toLowerAscii
  case subcmd
  of "config":
    let action = if args.len > 1: args[1].toLowerAscii else: "show"
    case action
    of "show":
      var isJson = ("--json" in rawArgs) or ("-j" in rawArgs)
      for i, a in rawArgs:
        if a == "--format" and i + 1 < rawArgs.len and rawArgs[i+1].toLowerAscii == "json":
          isJson = true
        elif a.toLowerAscii.startsWith("--format=json"):
          isJson = true
      if isJson:
        echo formatConfigJson(cfg)
      else:
        echo formatConfigTable(cfg)
    of "get":
      if args.len < 3:
        stderr.writeLine("Usage: rhizo config get <key>")
        quit(1)
      let key = args[2].toLowerAscii.replace("-", "_")
      case key
      of "redis_url", "url": echo cfg.redisUrl
      of "prefix": echo cfg.prefix
      of "project": echo cfg.project
      of "agent_name", "agent": echo cfg.agentName
      of "secret": echo cfg.secret
      of "secret_file": echo cfg.secretFile
      of "encrypt": echo $cfg.encrypt
      of "cluster": echo $cfg.cluster
      of "heartbeat_ttl", "heartbeat": echo $cfg.heartbeatTtl
      of "message_ttl", "ttl": echo $cfg.messageTtl
      of "listen_timeout", "timeout": echo $cfg.listenTimeout
      of "profile": echo cfg.profile
      of "config_file", "config": echo cfg.activeConfigFile
      else:
        stderr.writeLine("Error: Unknown configuration key: " & key)
        quit(1)
    of "path", "paths":
      echo formatConfigPaths()
    of "init":
      var target = "workspace"
      var force = false
      var i = 2
      while i < args.len:
        let a = args[i]
        if a in ["-f", "--force"]:
          force = true
        elif a.toLowerAscii in ["--user", "-u", "user"]:
          target = "user"
        elif a.toLowerAscii in ["--project", "-p", "project", "--workspace", "-w", "workspace"]:
          target = "workspace"
        elif not a.startsWith("-"):
          target = a
        inc i
      let res = initConfigFile(target, force)
      if res.startsWith("Error:"):
        stderr.writeLine(res)
        quit(1)
      echo res
    else:
      stderr.writeLine("Unknown config action: " & action)
      stderr.writeLine("Usage: rhizo config <show|get|path|init>")
      quit(1)

  of "name", "assign-name", "reserve-name":
    var prefix = ""
    var ttlSec = 600
    var isJson = ("--json" in rawArgs) or ("-j" in rawArgs)
    for idx, a in rawArgs:
      if a == "--format" and idx + 1 < rawArgs.len and rawArgs[idx+1].toLowerAscii == "json":
        isJson = true
      elif a.toLowerAscii.startsWith("--format=json"):
        isJson = true

    var i = 1
    while i < args.len:
      let a = args[i]
      if a in ["--json", "-j"]:
        isJson = true
      elif a.startsWith("--ttl="):
        ttlSec = parseRequiredInt(a[6..^1], "--ttl")
      elif a == "--ttl" and i + 1 < args.len:
        ttlSec = parseRequiredInt(args[i+1], "--ttl")
        inc i
      elif a.startsWith("--prefix="):
        prefix = a[9..^1]
      elif a == "--prefix" and i + 1 < args.len:
        prefix = args[i+1]
        inc i
      elif not a.startsWith("-"):
        if prefix.len == 0:
          prefix = a
      inc i

    let res = reserveUniqueName(cfg, prefix, ttlSec)
    if isJson:
      var j = %*{
        "name": res.name,
        "prefix": res.prefix,
        "codename": res.codename,
        "ttl": ttlSec,
        "held": true
      }
      echo $j
    else:
      echo res.name

  of "open", "register":
    var name = ""
    var tags = ""
    var rearmListen = false
    var listenTimeout = -1
    var i = 1
    while i < args.len:
      let a = args[i]
      if a in ["--listen", "-l"]:
        rearmListen = true
      elif a.startsWith("--listen="):
        rearmListen = true
        try: listenTimeout = parseInt(a[9..^1])
        except ValueError:
          stderr.writeLine("Error: Invalid integer for --listen: '" & a[9..^1] & "'")
          quit(1)
      elif a.startsWith("--listen-timeout="):
        rearmListen = true
        try: listenTimeout = parseInt(a[17..^1])
        except ValueError:
          stderr.writeLine("Error: Invalid integer for --listen-timeout: '" & a[17..^1] & "'")
          quit(1)
      elif a == "--listen-timeout" and i + 1 < args.len:
        rearmListen = true
        try: listenTimeout = parseInt(args[i+1])
        except ValueError:
          stderr.writeLine("Error: Invalid integer for --listen-timeout: '" & args[i+1] & "'")
          quit(1)
        inc i
      elif not a.startsWith("-"):
        if name.len == 0: name = a
        elif tags.len == 0: tags = a
      inc i
    doOpen(cfg, name, tags, rearmListen, listenTimeout)

  of "listen":
    var explicitName = ""
    var timeout = cfg.listenTimeout
    var forceListen = false
    var notify = false
    var quiet = false
    var continuous = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if a in ["--force", "-f"]:
        forceListen = true
      elif a in ["--notify", "-n"]:
        notify = true
      elif a in ["--quiet", "-q", "--no-postamble"]:
        quiet = true
      elif a in ["--continuous", "--daemon", "-c"]:
        continuous = true
      elif a in ["--once"]:
        continuous = false
      elif not a.startsWith("-"):
        try:
          timeout = parseInt(a)
        except ValueError:
          if explicitName == "": explicitName = sanitizeIdentifier(a)
      inc i

    var name = getActiveAgentName(cfg, explicitName, fallbackDefault = false)
    if name.len == 0:
      stderr.writeLine("Error: No agent name specified. Run 'rhizo open <name>', pass the agent name ('rhizo listen <name>'), or export RHIZO_AGENT_NAME=<name>.")
      quit(1)
    else:
      name = ensureProjectScopedName(cfg, name)

    if not forceListen:
      let (alreadyListening, existingPid, existingHost) = getActiveListenerInfo(cfg, name)
      if alreadyListening:
        stderr.writeLine("Error: Listener already active for agent '" & name & "' (PID " & $existingPid & " on " & existingHost & "). Refusing to start duplicate listener.")
        quit(1)

    doListen(cfg, name, timeout, notify, quiet, forceListen, continuous)

  of "send", "broadcast", "reply":
    let isBroadcast = (subcmd == "broadcast")
    let isReply = (subcmd == "reply")
    var toAgent = ""
    var msgType = if isReply: "reply" else: "task"
    var fromAgent = ""
    var subject = ""
    var body = ""
    var tags: seq[string] = @[]
    var replyTo = ""
    var msgId = ""
    var customTs = ""
    var rearmListen = false
    var listenTimeout = -1
    var listenAgent = ""
    var urgency = "soon"
    var format = "text"
    var skipGate = false

    var i = 1
    while i < args.len:
      let a = args[i]
      if a.startsWith("--to="): toAgent = a[5..^1]
      elif a == "--to" and i + 1 < args.len: toAgent = args[i+1]; inc i
      elif a.startsWith("--type="): msgType = a[7..^1]
      elif a == "--type" and i + 1 < args.len: msgType = args[i+1]; inc i
      elif a.startsWith("--from="): fromAgent = a[7..^1]
      elif a == "--from" and i + 1 < args.len: fromAgent = args[i+1]; inc i
      elif a.startsWith("--subject="): subject = a[10..^1]
      elif a == "--subject" and i + 1 < args.len: subject = args[i+1]; inc i
      elif a.startsWith("--body="): body = resolveVal(a[7..^1])
      elif a == "--body" and i + 1 < args.len: body = resolveVal(args[i+1]); inc i
      elif a in ["--immediate", "-i"]: urgency = "immediate"
      elif a == "--soon": urgency = "soon"
      elif a == "--json": format = "json"
      elif a == "--raw": format = "raw"
      elif a == "--skip-gate": skipGate = true
      elif a.startsWith("--urgency="): urgency = a[10..^1]
      elif a == "--urgency" and i + 1 < args.len: urgency = args[i+1]; inc i
      elif a.startsWith("--delivery="): urgency = a[11..^1]
      elif a == "--delivery" and i + 1 < args.len: urgency = args[i+1]; inc i
      elif a.startsWith("--tags="):
        for t in a[7..^1].split(','):
          if t.strip().len > 0: tags.add(t.strip())
      elif a == "--tags" and i + 1 < args.len:
        for t in args[i+1].split(','):
          if t.strip().len > 0: tags.add(t.strip())
        inc i
      elif a.startsWith("--reply-to="): replyTo = a[11..^1]
      elif a.startsWith("--reply_to="): replyTo = a[11..^1]
      elif (a == "--reply-to" or a == "--reply_to") and i + 1 < args.len: replyTo = args[i+1]; inc i
      elif a.startsWith("--id="): msgId = a[5..^1]
      elif a == "--id" and i + 1 < args.len: msgId = args[i+1]; inc i
      elif a.startsWith("--timestamp="): customTs = a[12..^1]
      elif a == "--timestamp" and i + 1 < args.len: customTs = args[i+1]; inc i
      elif a.startsWith("--listen-agent="):
        rearmListen = true
        listenAgent = sanitizeIdentifier(a[15..^1])
      elif a == "--listen-agent" and i + 1 < args.len:
        rearmListen = true
        listenAgent = sanitizeIdentifier(args[i+1]); inc i
      elif a.startsWith("--listen="):
        rearmListen = true
        let val = a[9..^1]
        try:
          listenTimeout = parseInt(val)
        except ValueError:
          listenAgent = sanitizeIdentifier(val)
      elif a in ["--listen", "-l"]:
        rearmListen = true
      elif a.startsWith("--listen-timeout="):
        rearmListen = true
        listenTimeout = parseRequiredInt(a[17..^1], "--listen-timeout")
      elif a == "--listen-timeout" and i + 1 < args.len:
        rearmListen = true
        listenTimeout = parseRequiredInt(args[i+1], "--listen-timeout")
        inc i
      elif not a.startsWith("-"):
        # Positional arguments fallback: <to> <subject> <body>
        if toAgent == "": toAgent = a
        elif subject == "": subject = a
        elif body == "": body = a
      inc i

    # Identity resolution for sender: strictly process-bound, no silent cross-agent current_agent leakage (GVR-008)
    if fromAgent.len == 0:
      fromAgent = getActiveAgentName(cfg, fromAgent, fallbackDefault = false, sessionId = cfg.sessionId, allowGlobalFallback = false)
    if fromAgent.len == 0:
      if fileExists(".vine.json"):
        try:
          let vj = parseJson(readFile(".vine.json"))
          let w = vj.getOrDefault("worker").getStr(vj.getOrDefault("agent").getStr(""))
          if w.len > 0: fromAgent = w
        except CatchableError: discard
    if fromAgent.len == 0:
      stderr.writeLine("Error: Cannot determine sender identity. Pass '--from <agent>' or export 'RHIZO_AGENT_NAME=<agent>'.")
      quit(1)

    if isBroadcast and toAgent == "":
      if tags.len > 0:
        if "*" in tags or "@all" in tags:
          toAgent = "*"
        else:
          toAgent = "@" & tags.join(",")
      else:
        toAgent = "*"

    if (not isBroadcast and toAgent.len == 0) or subject.len == 0 or body.len == 0:
      if not isBroadcast and toAgent.len == 0:
        stderr.writeLine("Error: Missing required argument '--to <recipient>'.")
        if isReply:
          stderr.writeLine("Usage: rhizo reply --to <recipient> --subject <subj> --body <body> [--reply-to <id>] [--listen/-l] [--immediate|--soon] [--skip-gate]")
        else:
          stderr.writeLine("Usage: rhizo send --to <recipient> --subject <subj> --body <body> [--listen/-l] [--immediate|--soon] [--skip-gate]")
      else:
        stderr.writeLine("Error: Missing required arguments. --subject and --body are required.")
        if isReply:
          stderr.writeLine("Usage: rhizo reply --to <recipient> --subject <subj> --body <body> [--reply-to <id>] [--listen/-l] [--immediate|--soon] [--skip-gate]")
        elif not isBroadcast:
          stderr.writeLine("Usage: rhizo send --to <recipient> --subject <subj> --body <body> [--listen/-l] [--immediate|--soon] [--skip-gate]")
        else:
          stderr.writeLine("Usage: rhizo broadcast [--tags <tags>] --subject <subj> --body <body> [--immediate|--soon]")
      quit(1)

    if not isBroadcast and toAgent.len > 0 and not toAgent.startsWith("@") and toAgent != "*":
      toAgent = ensureProjectScopedName(cfg, toAgent)
    if listenAgent.len > 0:
      listenAgent = ensureProjectScopedName(cfg, listenAgent)

    if isReply:
      discard doReply(cfg, toAgent, fromAgent, subject, body, tags, replyTo, msgId, customTs, rearmListen, listenTimeout, urgency, format, listenAgent, skipGate)
    else:
      if subcmd == "send" and isCompletionSubject(subject) and not skipGate:
        let (passed, _, err) = checkVineGateInterlock()
        if not passed:
          stderr.writeLine(err)
          quit(1)
      discard doSend(cfg, toAgent, msgType, fromAgent, subject, body, tags, replyTo, msgId, isBroadcast, customTs, echoResult = true, rearmListen = rearmListen, listenTimeoutSec = listenTimeout, urgency = urgency, format = format, listenAgent = listenAgent)

  of "who":
    var filterTag = cfg.project
    var jsonOutput = false
    var showAll = false

    var i = 1
    while i < args.len:
      let a = args[i]
      if a in ["-a", "--all", "*", "@all"]:
        showAll = true
      elif a in ["--json", "-j"]:
        jsonOutput = true
      elif not a.startsWith("-"):
        filterTag = a
      inc i

    if showAll:
      filterTag = "*"
    echo doDirectory(cfg, filterTag, jsonOutput)

  of "tag":
    if args.len < 3:
      stderr.writeLine("Error: Missing arguments for tag command.")
      stderr.writeLine("Usage: rhizo tag <add|remove|set> <tags> [name]")
      quit(1)
    let action = args[1].toLowerAscii
    if action notin ["add", "remove", "set"]:
      stderr.writeLine("Error: Invalid tag action '" & args[1] & "'. Expected add, remove, or set.")
      stderr.writeLine("Usage: rhizo tag <add|remove|set> <tags> [name]")
      quit(1)
    let tags = args[2]
    let explicitName = if args.len > 3: args[3] else: ""
    let name = getActiveAgentName(cfg, explicitName, fallbackDefault = false)
    if name.len == 0:
      stderr.writeLine("Error: No agent name specified. Run 'rhizo open <name>', pass the agent name, or export RHIZO_AGENT_NAME=<name>.")
      quit(1)
    echo doTag(cfg, name, action, tags)

  of "check-inbox":
    let explicitName = if args.len > 1: args[1] else: ""
    let name = getActiveAgentName(cfg, explicitName, fallbackDefault = false)
    if name.len == 0:
      stderr.writeLine("Error: No agent name specified. Run 'rhizo open <name>', pass the agent name, or export RHIZO_AGENT_NAME=<name>.")
      quit(1)
    let count = doCheckInbox(cfg, name)
    echo count
    if count > 0:
      quit(0)
    else:
      quit(1)

  of "drain":
    var count = 50
    var explicitName = ""
    var format = "json"
    var positionalIdx = 0
    var i = 1
    while i < args.len:
      let a = args[i]
      if a.startsWith("--format="):
        format = a[9..^1].toLowerAscii
      elif a in ["--hook", "-H"]:
        format = "hook"
      elif a in ["--json", "-j"]:
        format = "json"
      elif a == "--raw":
        format = "raw"
      elif a.startsWith("--agent="):
        explicitName = a[8..^1]
      elif (a == "--agent" or a == "-a") and i + 1 < args.len:
        explicitName = args[i+1]
        inc i
      elif a.startsWith("--count="):
        count = parseRequiredInt(a[8..^1], "--count")
      elif (a == "--count" or a == "-c") and i + 1 < args.len:
        count = parseRequiredInt(args[i+1], "--count")
        inc i
      elif not a.startsWith("-"):
        inc positionalIdx
        if positionalIdx == 1:
          try:
            count = parseInt(a)
          except ValueError:
            var isKnownAgent = false
            try:
              var client = connectRedis(cfg.redisUrl)
              defer: (try: client.close() except CatchableError: discard)
              if client.sIsMember(cfg.prefix & "active_agents", a.toLowerAscii) == 1 or client.exists(cfg.prefix & "agent:" & a.toLowerAscii):
                isKnownAgent = true
            except CatchableError:
              discard
            if isKnownAgent:
              explicitName = a.toLowerAscii
            else:
              stderr.writeLine("Error: Invalid count '" & a & "' for drain command. Expected an integer.")
              stderr.writeLine("Usage: rhizo drain [count] [name]")
              quit(1)
        elif positionalIdx == 2:
          if explicitName.len == 0:
            explicitName = a.toLowerAscii
          else:
            try:
              count = parseInt(a)
            except ValueError:
              stderr.writeLine("Error: Invalid count '" & a & "' for drain command. Expected an integer.")
              quit(1)
      inc i

    let name = getActiveAgentName(cfg, explicitName, fallbackDefault = false)
    if name.len == 0:
      stderr.writeLine("Error: No agent name specified. Run 'rhizo open <name>', pass the agent name, or export RHIZO_AGENT_NAME=<name>.")
      quit(1)
    let output = doDrain(cfg, name, count, format)
    if format == "hook" and output.len == 0:
      discard
    else:
      echo output

  of "close", "unregister":
    let explicitName = if args.len > 1: args[1] else: ""
    let name = getActiveAgentName(cfg, explicitName, fallbackDefault = false)
    let sid = if cfg.sessionId.len > 0: cfg.sessionId else: getEnv("RHIZO_SESSION_ID", "")
    if sid.len > 0:
      removeLocalSessionMapping(sid)
      removeRedisSessionMapping(cfg, sid, name)
    if name.len > 0:
      echo doUnregister(cfg, name)
    else:
      echo "OK"

  of "nuke":
    var isJson = ("--json" in rawArgs) or ("-j" in rawArgs)
    for idx, a in rawArgs:
      if a == "--format" and idx + 1 < rawArgs.len and rawArgs[idx+1].toLowerAscii == "json":
        isJson = true
      elif a.toLowerAscii.startsWith("--format=json"):
        isJson = true
    echo doNuke(cfg, isJson)

  of "reset":
    var targetProject = ""
    var forceAll = ("--all" in rawArgs) or ("-a" in rawArgs)
    var isJson = ("--json" in rawArgs) or ("-j" in rawArgs)
    for idx, a in rawArgs:
      if a == "--format" and idx + 1 < rawArgs.len and rawArgs[idx+1].toLowerAscii == "json":
        isJson = true
      elif a.toLowerAscii.startsWith("--format=json"):
        isJson = true

    var i = 1
    while i < args.len:
      let a = args[i]
      if a in ["--all", "-a"]:
        forceAll = true
      elif a in ["--json", "-j"]:
        isJson = true
      elif not a.startsWith("-"):
        if targetProject.len == 0:
          targetProject = a
      inc i
    echo doReset(cfg, targetProject, forceAll, isJson)

  of "ping":
    var isJson = ("--json" in rawArgs) or ("-j" in rawArgs)
    for idx, a in rawArgs:
      if a == "--format" and idx + 1 < rawArgs.len and rawArgs[idx+1].toLowerAscii == "json":
        isJson = true
      elif a.toLowerAscii.startsWith("--format=json"):
        isJson = true
    let t0 = epochTime()
    var client: Redis
    try:
      client = openRedisClient(cfg.redisUrl)
    except CatchableError as e:
      if isJson:
        var j = %*{
          "status": "error",
          "error": "Could not connect to Redis: " & e.msg,
          "redis_url": cfg.redisUrl
        }
        echo $j
      else:
        stderr.writeLine("Redis error: Could not connect to Redis: " & e.msg)
      quit(1)
    defer: (try: client.close() except CatchableError: discard)

    try:
      let reply = client.ping()
      let latencyMs = ((epochTime() - t0) * 1000)
      if isJson:
        var j = %*{
          "status": "ok",
          "reply": $reply,
          "latency_ms": latencyMs.formatFloat(ffDecimal, 2),
          "redis_url": cfg.redisUrl
        }
        echo $j
      else:
        echo $reply
    except CatchableError as e:
      if isJson:
        var j = %*{
          "status": "error",
          "error": e.msg,
          "redis_url": cfg.redisUrl
        }
        echo $j
      else:
        stderr.writeLine("Redis error: " & e.msg)
      quit(1)

  of "session":
    if args.len < 2:
      stderr.writeLine("Usage: rhizo session <set|get|remove|list> [args...]")
      stderr.writeLine("  rhizo session set <prefix:session_id> <agent_name>")
      stderr.writeLine("  rhizo session get <prefix:session_id>")
      stderr.writeLine("  rhizo session remove <prefix:session_id>")
      stderr.writeLine("  rhizo session list [--json]")
      quit(1)

    let action = args[1].toLowerAscii
    case action
    of "set":
      if args.len < 4:
        stderr.writeLine("Error: 'rhizo session set' requires <session_key> and <agent_name>")
        stderr.writeLine("Example: rhizo session set opencode:ses_123 worker-agent")
        quit(1)
      let key = args[2]
      let agent = args[3]
      saveLocalSessionMapping(key, agent)
      setRedisSessionMapping(cfg, key, agent)
      echo "OK [session] " & key & " -> " & agent

    of "get":
      if args.len < 3:
        stderr.writeLine("Error: 'rhizo session get' requires <session_key>")
        quit(1)
      let key = args[2]
      var agent = getLocalSessionAgent(key)
      if agent.len == 0:
        agent = getRedisSessionMapping(cfg, key)
      if agent.len == 0:
        stderr.writeLine("Error: Session key not found: " & key)
        quit(1)
      echo agent

    of "remove", "rm", "del", "clear":
      if args.len < 3:
        stderr.writeLine("Error: 'rhizo session remove' requires <session_key>")
        quit(1)
      let key = args[2]
      let agent = getLocalSessionAgent(key)
      removeLocalSessionMapping(key)
      removeRedisSessionMapping(cfg, key, agent)
      echo "OK [session] removed " & key

    of "list", "ls":
      let asJson = ("--json" in args) or ("-j" in args)
      var sessions = loadLocalSessionMap()

      # Merge with Redis sessions if Redis is reachable
      try:
        var client = openRedisClient(cfg.redisUrl)
        defer: (try: client.close() except CatchableError: discard)
        let redisSessions = client.hGetAll(cfg.prefix & "sessions")
        var idx = 0
        while idx < redisSessions.len:
          let k = redisSessions[idx]
          let v = if idx + 1 < redisSessions.len: redisSessions[idx+1] else: ""
          if not sessions.hasKey(k) and v.len > 0:
            try:
              sessions[k] = parseJson(v)
            except CatchableError:
              var obj = newJObject()
              obj["agent"] = %v
              sessions[k] = obj
          idx += 2
      except CatchableError:
        discard

      if asJson:
        echo $sessions
      else:
        if sessions.len == 0:
          echo "No active sessions registered."
        else:
          echo "SESSION ID".alignLeft(32) & " " & "AGENT NAME".alignLeft(24) & " " & "UPDATED AT"
          echo "-".repeat(32) & " " & "-".repeat(24) & " " & "-".repeat(20)
          for k, v in sessions.pairs:
            let agent = if v.kind == JObject and v.hasKey("agent"): v["agent"].getStr() elif v.kind == JString: v.getStr() else: ""
            let ts = if v.kind == JObject and v.hasKey("updated_at"): v["updated_at"].getStr() else: "-"
            echo k.alignLeft(32) & " " & agent.alignLeft(24) & " " & ts

    else:
      stderr.writeLine("Error: Unknown session action '" & action & "'. Valid actions: set, get, remove, list.")
      quit(1)

  of "get-secret":
    echo getSecret(cfg)

  of "request":
    var toAgent = ""
    var fromAgent = getActiveAgentName(cfg, "", fallbackDefault = true)
    var subject = ""
    var body = ""
    var timeout = if cfg.listenTimeout > 0: cfg.listenTimeout else: 30
    var rawOutput = false
    var urgency = "soon"

    var i = 1
    while i < args.len:
      let a = args[i]
      if a.startsWith("--to="): toAgent = a[5..^1]
      elif a == "--to" and i + 1 < args.len: toAgent = args[i+1]; inc i
      elif a.startsWith("--from="): fromAgent = a[7..^1]
      elif a == "--from" and i + 1 < args.len: fromAgent = args[i+1]; inc i
      elif a.startsWith("--subject="): subject = a[10..^1]
      elif a == "--subject" and i + 1 < args.len: subject = args[i+1]; inc i
      elif a.startsWith("--body="): body = resolveVal(a[7..^1])
      elif a == "--body" and i + 1 < args.len: body = resolveVal(args[i+1]); inc i
      elif a in ["--immediate", "-i"]: urgency = "immediate"
      elif a == "--soon": urgency = "soon"
      elif a.startsWith("--urgency="): urgency = a[10..^1]
      elif a == "--urgency" and i + 1 < args.len: urgency = args[i+1]; inc i
      elif a.startsWith("--delivery="): urgency = a[11..^1]
      elif a == "--delivery" and i + 1 < args.len: urgency = args[i+1]; inc i
      elif a.startsWith("--timeout="):
        timeout = parseRequiredInt(a[10..^1], "--timeout")
      elif a == "--timeout" and i + 1 < args.len:
        timeout = parseRequiredInt(args[i+1], "--timeout")
        inc i
      elif a in ["--raw", "-r"]:
        rawOutput = true
      elif not a.startsWith("-"):
        if toAgent == "": toAgent = a
        elif subject == "": subject = a
        elif body == "": body = a
      inc i

    if toAgent.len == 0 or subject.len == 0 or body.len == 0:
      stderr.writeLine("Error: Missing required arguments. --to, --subject, and --body are required.")
      stderr.writeLine("Usage: rhizo request --to <agent> --subject <subj> --body <body> [--timeout 30] [--raw] [--immediate|--soon]")
      quit(1)

    doRequest(cfg, toAgent, fromAgent, subject, body, timeout, rawOutput, urgency = urgency)

  of "scatter":
    var targets = ""
    var subject = ""
    var body = ""
    var quorum = -1
    var timeout = if cfg.listenTimeout > 0: cfg.listenTimeout else: 30
    var rawOutput = false
    var urgency = "soon"
    var fromAgent = getActiveAgentName(cfg, "", fallbackDefault = true)

    var i = 1
    while i < args.len:
      let a = args[i]
      if a.startsWith("--targets="): targets = a[10..^1]
      elif a == "--targets" and i + 1 < args.len: targets = args[i+1]; inc i
      elif a.startsWith("--target="): targets = a[9..^1]
      elif a == "--target" and i + 1 < args.len: targets = args[i+1]; inc i
      elif a.startsWith("--subject="): subject = a[10..^1]
      elif a == "--subject" and i + 1 < args.len: subject = args[i+1]; inc i
      elif a.startsWith("--body="): body = resolveVal(a[7..^1])
      elif a == "--body" and i + 1 < args.len: body = resolveVal(args[i+1]); inc i
      elif a in ["--immediate", "-i"]: urgency = "immediate"
      elif a == "--soon": urgency = "soon"
      elif a.startsWith("--urgency="): urgency = a[10..^1]
      elif a == "--urgency" and i + 1 < args.len: urgency = args[i+1]; inc i
      elif a.startsWith("--delivery="): urgency = a[11..^1]
      elif a == "--delivery" and i + 1 < args.len: urgency = args[i+1]; inc i
      elif a.startsWith("--quorum="):
        quorum = parseRequiredInt(a[9..^1], "--quorum")
      elif a == "--quorum" and i + 1 < args.len:
        quorum = parseRequiredInt(args[i+1], "--quorum")
        inc i
      elif a.startsWith("--timeout="):
        timeout = parseRequiredInt(a[10..^1], "--timeout")
      elif a == "--timeout" and i + 1 < args.len:
        timeout = parseRequiredInt(args[i+1], "--timeout")
        inc i
      elif a == "--raw": rawOutput = true
      elif a.startsWith("--from="): fromAgent = a[7..^1]
      elif a == "--from" and i + 1 < args.len: fromAgent = args[i+1]; inc i
      elif not a.startsWith("-"):
        if targets == "": targets = a
        elif subject == "": subject = a
        elif body == "": body = a
      inc i

    if targets.len == 0 or subject.len == 0 or body.len == 0:
      stderr.writeLine("Error: Missing required arguments for scatter.")
      stderr.writeLine("Usage: rhizo scatter --targets <@tag|agent1,agent2|*> --subject <subj> --body <body> [--quorum N] [--timeout sec] [--raw] [--immediate|--soon]")
      quit(1)

    doScatter(cfg, targets, fromAgent, subject, body, quorum, timeout, rawOutput, urgency = urgency)

  of "enqueue":
    var isRoute = false
    var routesFilePath = ""
    var serviceUrl = ""
    var modelOverride = ""
    var apiKeyOverride = ""
    var routeTimeout = ""
    var j = 0
    while j < args.len:
      let a = args[j]
      if a == "--route": isRoute = true
      elif a.startsWith("--routes-file="): routesFilePath = a[14..^1]
      elif a.startsWith("--routes_file="): routesFilePath = a[14..^1]
      elif (a == "--routes-file" or a == "--routes_file") and j + 1 < args.len:
        routesFilePath = args[j+1]; inc j
      elif a.startsWith("--service-url=") or a.startsWith("--service_url="): serviceUrl = a[14..^1]
      elif (a == "--service-url" or a == "--service_url") and j + 1 < args.len:
        serviceUrl = args[j+1]; inc j
      elif a.startsWith("--systemone-url=") or a.startsWith("--systemone_url="): serviceUrl = a[16..^1]
      elif (a == "--systemone-url" or a == "--systemone_url") and j + 1 < args.len:
        serviceUrl = args[j+1]; inc j
      elif a.startsWith("--laya-url=") or a.startsWith("--laya_url="): serviceUrl = a[11..^1]
      elif (a == "--laya-url" or a == "--laya_url" or a == "-s") and j + 1 < args.len:
        serviceUrl = args[j+1]; inc j
      elif a.startsWith("--model="): modelOverride = a[8..^1]
      elif (a == "--model" or a == "-m") and j + 1 < args.len:
        modelOverride = args[j+1]; inc j
      elif a.startsWith("--api-key=") or a.startsWith("--api_key="): apiKeyOverride = a[10..^1]
      elif (a == "--api-key" or a == "--api_key" or a == "-k") and j + 1 < args.len:
        apiKeyOverride = args[j+1]; inc j
      elif a.startsWith("--route-timeout="): routeTimeout = a[16..^1]
      elif a.startsWith("--route_timeout="): routeTimeout = a[16..^1]
      elif a.startsWith("--timeout="): routeTimeout = a[10..^1]
      elif (a == "--route-timeout" or a == "--route_timeout" or a == "--timeout" or a == "-t") and j + 1 < args.len:
        routeTimeout = args[j+1]; inc j
      inc j

    if isRoute:
      var routesCfg: RoutingConfig
      try:
        routesCfg = loadEffectiveRoutesConfig(routesFilePath)
      except CatchableError as e:
        stderr.writeLine("Error: Failed to parse route configuration: " & e.msg)
        quit(1)

      if serviceUrl.len > 0: routesCfg.service.url = serviceUrl
      if modelOverride.len > 0: routesCfg.service.model = modelOverride
      if apiKeyOverride.len > 0: routesCfg.service.apiKey = apiKeyOverride
      if routeTimeout.len > 0:
        try: routesCfg.service.timeoutSeconds = parseFloat(routeTimeout)
        except ValueError: discard

      var msgType = "task"
      var fromAgent = getActiveAgentName(cfg, "", fallbackDefault = true)
      var subject = ""
      var body = ""
      var tags: seq[string] = @[]
      var replyTo = ""
      var msgId = ""
      var customTs = ""
      var positionalText = ""

      var i = 1
      while i < args.len:
        let a = args[i]
        if a == "--route": discard
        elif a.startsWith("--routes-file=") or a.startsWith("--routes_file="): discard
        elif (a == "--routes-file" or a == "--routes_file") and i + 1 < args.len: inc i
        elif a.startsWith("--service-url=") or a.startsWith("--service_url="): discard
        elif (a == "--service-url" or a == "--service_url") and i + 1 < args.len: inc i
        elif a.startsWith("--systemone-url=") or a.startsWith("--systemone_url="): discard
        elif (a == "--systemone-url" or a == "--systemone_url") and i + 1 < args.len: inc i
        elif a.startsWith("--laya-url=") or a.startsWith("--laya_url="): discard
        elif (a == "--laya-url" or a == "--laya_url" or a == "-s") and i + 1 < args.len: inc i
        elif a.startsWith("--model="): discard
        elif (a == "--model" or a == "-m") and i + 1 < args.len: inc i
        elif a.startsWith("--api-key=") or a.startsWith("--api_key="): discard
        elif (a == "--api-key" or a == "--api_key" or a == "-k") and i + 1 < args.len: inc i
        elif a.startsWith("--route-timeout=") or a.startsWith("--route_timeout="): discard
        elif a.startsWith("--timeout="): discard
        elif (a == "--route-timeout" or a == "--route_timeout" or a == "--timeout" or a == "-t") and i + 1 < args.len: inc i
        elif a.startsWith("--type="): msgType = a[7..^1]
        elif a == "--type" and i + 1 < args.len: msgType = args[i+1]; inc i
        elif a.startsWith("--from="): fromAgent = a[7..^1]
        elif a == "--from" and i + 1 < args.len: fromAgent = args[i+1]; inc i
        elif a.startsWith("--subject="): subject = a[10..^1]
        elif a == "--subject" and i + 1 < args.len: subject = args[i+1]; inc i
        elif a.startsWith("--body="): body = resolveVal(a[7..^1])
        elif a == "--body" and i + 1 < args.len: body = resolveVal(args[i+1]); inc i
        elif a.startsWith("--tags="):
          for t in a[7..^1].split(','):
            if t.strip().len > 0: tags.add(t.strip())
        elif a == "--tags" and i + 1 < args.len:
          for t in args[i+1].split(','):
            if t.strip().len > 0: tags.add(t.strip())
          inc i
        elif a.startsWith("--reply-to=") or a.startsWith("--reply_to="): replyTo = a[11..^1]
        elif (a == "--reply-to" or a == "--reply_to") and i + 1 < args.len: replyTo = args[i+1]; inc i
        elif a.startsWith("--id="): msgId = a[5..^1]
        elif a == "--id" and i + 1 < args.len: msgId = args[i+1]; inc i
        elif a.startsWith("--timestamp="): customTs = a[12..^1]
        elif a == "--timestamp" and i + 1 < args.len: customTs = args[i+1]; inc i
        elif not a.startsWith("-"):
          if positionalText.len == 0: positionalText = a
          else: positionalText.add(" " & a)
        inc i

      if body.len == 0 and positionalText.len > 0:
        body = positionalText

      if body.len == 0:
        stderr.writeLine("Error: Missing task description to route. Provide task text or --body <body>.")
        quit(1)

      if subject.len == 0:
        let lines = body.strip().splitLines()
        if lines.len > 0: subject = lines[0].strip()
        if subject.len > 80: subject = subject[0 .. 79] & "..."
        if subject.len == 0: subject = "Routed Task"

      var decision: RoutingDecision
      try:
        decision = routeTask(routesCfg, body)
      except CatchableError as e:
        stderr.writeLine("Error: Routing failed: " & e.msg)
        quit(2)

      var finalTags = tags
      for t in decision.tags:
        if t notin finalTags: finalTags.add(t)

      let id = doEnqueue(cfg, decision.targetQueue, msgType, fromAgent, subject, body, finalTags, replyTo, msgId, customTs)
      echo id
    else:
      if args.len < 2:
        stderr.writeLine("Error: Missing queue name.")
        stderr.writeLine("Usage: rhizo enqueue <queue_name> --subject <subj> --body <body>")
        quit(1)
      let queueName = args[1]
      var msgType = "task"
      var fromAgent = getActiveAgentName(cfg, "", fallbackDefault = true)
      var subject = ""
      var body = ""
      var tags: seq[string] = @[]
      var replyTo = ""
      var msgId = ""
      var customTs = ""

      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--type="): msgType = a[7..^1]
        elif a == "--type" and i + 1 < args.len: msgType = args[i+1]; inc i
        elif a.startsWith("--from="): fromAgent = a[7..^1]
        elif a == "--from" and i + 1 < args.len: fromAgent = args[i+1]; inc i
        elif a.startsWith("--subject="): subject = a[10..^1]
        elif a == "--subject" and i + 1 < args.len: subject = args[i+1]; inc i
        elif a.startsWith("--body="): body = resolveVal(a[7..^1])
        elif a == "--body" and i + 1 < args.len: body = resolveVal(args[i+1]); inc i
        elif a.startsWith("--tags="):
          for t in a[7..^1].split(','):
            if t.strip().len > 0: tags.add(t.strip())
        elif a == "--tags" and i + 1 < args.len:
          for t in args[i+1].split(','):
            if t.strip().len > 0: tags.add(t.strip())
          inc i
        elif a.startsWith("--reply-to=") or a.startsWith("--reply_to="): replyTo = a[11..^1]
        elif (a == "--reply-to" or a == "--reply_to") and i + 1 < args.len: replyTo = args[i+1]; inc i
        elif a.startsWith("--id="): msgId = a[5..^1]
        elif a == "--id" and i + 1 < args.len: msgId = args[i+1]; inc i
        elif a.startsWith("--timestamp="): customTs = a[12..^1]
        elif a == "--timestamp" and i + 1 < args.len: customTs = args[i+1]; inc i
        elif not a.startsWith("-"):
          if subject == "": subject = a
          elif body == "": body = a
        inc i

      if subject.len == 0 or body.len == 0:
        stderr.writeLine("Error: Missing required arguments. --subject and --body are required.")
        stderr.writeLine("Usage: rhizo enqueue <queue_name> --subject <subj> --body <body>")
        quit(1)

      let id = doEnqueue(cfg, queueName, msgType, fromAgent, subject, body, tags, replyTo, msgId, customTs)
      echo id

  of "route":
    if args.len < 2:
      stderr.writeLine("Error: Missing task text or sub-command (init / lint / check).")
      stderr.writeLine("Usage:")
      stderr.writeLine("  rhizo route <task_text> [--routes-file <file>] [--service-url <url>] [--model <model>] [--api-key <key>]")
      stderr.writeLine("  rhizo route lint [--routes-file <file>] [--check-service]")
      stderr.writeLine("  rhizo route init [--global] [--force]")
      quit(1)

    var routesFilePath = ""
    var serviceUrl = ""
    var modelOverride = ""
    var apiKeyOverride = ""
    var routeTimeout = ""
    var checkService = false
    var isLint = false
    var isInit = false
    var isGlobal = false
    var forceOverwrite = false
    var taskText = ""

    var i = 1
    while i < args.len:
      let a = args[i]
      if a in ["lint", "check"]:
        isLint = true
      elif a in ["init", "scaffold"]:
        isInit = true
      elif a in ["--global", "-g"]:
        isGlobal = true
      elif a in ["--force", "-f"]:
        forceOverwrite = true
      elif a in ["--check-service", "--check_service", "--ping"]:
        checkService = true
      elif a.startsWith("--routes-file="): routesFilePath = a[14..^1]
      elif a.startsWith("--routes_file="): routesFilePath = a[14..^1]
      elif (a == "--routes-file" or a == "--routes_file") and i + 1 < args.len:
        routesFilePath = args[i+1]; inc i
      elif a.startsWith("--service-url=") or a.startsWith("--service_url="): serviceUrl = a[14..^1]
      elif (a == "--service-url" or a == "--service_url") and i + 1 < args.len:
        serviceUrl = args[i+1]; inc i
      elif a.startsWith("--systemone-url=") or a.startsWith("--systemone_url="): serviceUrl = a[16..^1]
      elif (a == "--systemone-url" or a == "--systemone_url") and i + 1 < args.len:
        serviceUrl = args[i+1]; inc i
      elif a.startsWith("--laya-url=") or a.startsWith("--laya_url="): serviceUrl = a[11..^1]
      elif (a == "--laya-url" or a == "--laya_url" or a == "-s") and i + 1 < args.len:
        serviceUrl = args[i+1]; inc i
      elif a.startsWith("--model="): modelOverride = a[8..^1]
      elif (a == "--model" or a == "-m") and i + 1 < args.len:
        modelOverride = args[i+1]; inc i
      elif a.startsWith("--api-key=") or a.startsWith("--api_key="): apiKeyOverride = a[10..^1]
      elif (a == "--api-key" or a == "--api_key" or a == "-k") and i + 1 < args.len:
        apiKeyOverride = args[i+1]; inc i
      elif a.startsWith("--route-timeout="): routeTimeout = a[16..^1]
      elif a.startsWith("--route_timeout="): routeTimeout = a[16..^1]
      elif a.startsWith("--timeout="): routeTimeout = a[10..^1]
      elif (a == "--route-timeout" or a == "--route_timeout" or a == "--timeout" or a == "-t") and i + 1 < args.len:
        routeTimeout = args[i+1]; inc i
      elif not a.startsWith("-"):
        if taskText.len == 0: taskText = a
        else: taskText.add(" " & a)
      inc i

    if isInit:
      let targetFile = if isGlobal:
        getHomeDir() / ".config" / "rhizo" / "routes.yaml"
      else:
        getCurrentDir() / "rhizo-routes.yaml"

      let targetDir = targetFile.splitPath.head
      if fileExists(targetFile) and not forceOverwrite:
        echo "Notice: Route configuration already exists at: " & targetFile
        echo "Use --force to overwrite."
        quit(0)

      createDir(targetDir)
      writeFile(targetFile, StarterRouteTemplate)
      echo "✓ Initialized route configuration at: " & targetFile
      echo "  Scope: " & (if isGlobal: "Global user fallback (~/.config/rhizo/routes.yaml)" else: "Project root (./rhizo-routes.yaml)")
      echo "  Note: System 1 routing is optional. Core queueing, messaging, and locking operate directly over Redis."
      echo "  Verify configuration: rhizo route lint --check-service"
      quit(0)

    if isLint:
      let (valid, errors, warnings, pathDesc) = lintEffectiveRoutesConfig(routesFilePath, checkService = checkService)
      if valid:
        var routesCfg: RoutingConfig
        try:
          routesCfg = loadEffectiveRoutesConfig(routesFilePath)
        except CatchableError: discard

        if serviceUrl.len > 0: routesCfg.service.url = serviceUrl
        if modelOverride.len > 0: routesCfg.service.model = modelOverride
        if apiKeyOverride.len > 0: routesCfg.service.apiKey = apiKeyOverride
        if routeTimeout.len > 0:
          try: routesCfg.service.timeoutSeconds = parseFloat(routeTimeout)
          except ValueError: discard

        var qList: seq[string] = @[]
        for qid, qc in routesCfg.questions:
          qList.add(qid & " [" & qc.qType & "]")
        var rList: seq[string] = @[]
        for r in routesCfg.routes:
          rList.add(r.name)

        echo "✓ Route configuration is valid: " & pathDesc
        echo "  Questions (" & $qList.len & "): " & qList.join(", ")
        echo "  Routes (" & $rList.len & "): " & rList.join(", ")
        echo "  Service: " & routesCfg.service.url & " (timeout: " & $routesCfg.service.timeoutSeconds & "s)"
        if routesCfg.service.model.len > 0:
          echo "  Model: " & routesCfg.service.model
        if routesCfg.service.apiKey.len > 0:
          echo "  API Key: [configured]"
        echo "  Limits: " & $routesCfg.limits.overflowStrategy & " (chunk: " & $routesCfg.limits.chunkSize &
             ", overlap: " & $routesCfg.limits.chunkOverlap & ", max_chunks: " & $routesCfg.limits.maxChunks & ")"
        if checkService:
          echo "  ✓ System 1 service check passed"
        if warnings.len > 0:
          echo "Warnings:"
          for w in warnings: echo "  ! " & w
        quit(0)
      else:
        stderr.writeLine("✗ Route configuration failed validation: " & pathDesc)
        stderr.writeLine("Errors:")
        for e in errors:
          stderr.writeLine("  - " & e)
        if warnings.len > 0:
          stderr.writeLine("Warnings:")
          for w in warnings:
            stderr.writeLine("  ! " & w)
        quit(1)

    # Dry-run task routing
    if taskText.len == 0:
      stderr.writeLine("Error: Missing task text to route.")
      stderr.writeLine("Usage: rhizo route <task_text> [--routes-file <file>] [--service-url <url>] [--model <model>] [--api-key <key>]")
      quit(1)

    var routesCfg: RoutingConfig
    try:
      routesCfg = loadEffectiveRoutesConfig(routesFilePath)
    except CatchableError as e:
      stderr.writeLine("Error: Failed to parse route configuration: " & e.msg)
      quit(1)

    if serviceUrl.len > 0: routesCfg.service.url = serviceUrl
    if modelOverride.len > 0: routesCfg.service.model = modelOverride
    if apiKeyOverride.len > 0: routesCfg.service.apiKey = apiKeyOverride
    if routeTimeout.len > 0:
      try: routesCfg.service.timeoutSeconds = parseFloat(routeTimeout)
      except ValueError: discard

    var decision: RoutingDecision
    try:
      decision = routeTask(routesCfg, taskText)
    except CatchableError as e:
      stderr.writeLine("Error: Routing failed: " & e.msg)
      quit(2)

    var tagsArr = newJArray()
    for t in decision.tags: tagsArr.add(%t)

    var outObj = %*{
      "matched_rule": decision.matchedRule,
      "target": {
        "queue": decision.targetQueue,
        "tags": tagsArr,
        "lease_seconds": decision.leaseSeconds
      },
      "answers": decision.rawAnswers,
      "aggregation": decision.aggregationMetadata
    }
    echo pretty(outObj)
    quit(0)

  of "work":
    if args.len < 2:
      stderr.writeLine("Error: Missing queue name.")
      stderr.writeLine("Usage: rhizo work <queue_name> [timeout_sec] [--run-id <run_id>]")
      quit(1)
    let queueName = args[1]
    var timeout = -1
    var runId = ""
    var i = 2
    while i < args.len:
      let a = args[i]
      if a.startsWith("--run-id="):
        runId = a[9..^1]
      elif a == "--run-id" and i + 1 < args.len:
        runId = args[i+1]
        inc i
      elif not a.startsWith("-"):
        timeout = parseRequiredInt(a, "timeout")
      inc i
    doWork(cfg, queueName, timeout, runId)

  of "claim":
    if args.len < 2:
      stderr.writeLine("Error: Missing queue name.")
      stderr.writeLine("Usage: rhizo claim <queue_name> [timeout_sec] [--lease 120] [--raw] [--run-id <run_id>]")
      stderr.writeLine("       rhizo claim renew <queue_name> <task_id> [--lease 120]")
      quit(1)

    if args[1] == "renew":
      if args.len < 4:
        stderr.writeLine("Error: Missing queue name or task ID for claim renew.")
        stderr.writeLine("Usage: rhizo claim renew <queue_name> <task_id> [--lease 120]")
        quit(1)
      let queueName = args[2]
      let taskId = args[3]
      var lease = 120
      var i = 4
      while i < args.len:
        let a = args[i]
        if a.startsWith("--lease="):
          lease = parseRequiredInt(a[8..^1], "--lease")
        elif a == "--lease" and i + 1 < args.len:
          lease = parseRequiredInt(args[i+1], "--lease")
          inc i
        inc i
      doClaimRenew(cfg, queueName, taskId, lease)
    else:
      let queueName = args[1]
      var timeout = -1
      var lease = 120
      var rawOutput = false
      var runId = ""

      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--lease="):
          lease = parseRequiredInt(a[8..^1], "--lease")
        elif a == "--lease" and i + 1 < args.len:
          lease = parseRequiredInt(args[i+1], "--lease")
          inc i
        elif a.startsWith("--timeout="):
          timeout = parseRequiredInt(a[10..^1], "--timeout")
        elif a == "--timeout" and i + 1 < args.len:
          timeout = parseRequiredInt(args[i+1], "--timeout")
          inc i
        elif a.startsWith("--run-id="):
          runId = a[9..^1]
        elif a == "--run-id" and i + 1 < args.len:
          runId = args[i+1]
          inc i
        elif a == "--raw":
          rawOutput = true
        elif not a.startsWith("-"):
          timeout = parseRequiredInt(a, "timeout")
        inc i

      doClaim(cfg, queueName, timeout, lease, rawOutput, runId)

  of "ack":
    if args.len < 3:
      stderr.writeLine("Error: Missing queue name or task ID.")
      stderr.writeLine("Usage: rhizo ack <queue_name> <task_id>")
      quit(1)
    let queueName = args[1]
    let taskId = args[2]
    discard doAck(cfg, queueName, taskId)

  of "blackboard":
    if args.len < 3:
      stderr.writeLine("Usage: rhizo blackboard <set|get|rev|append|snapshot|load|delete|clear> <room> [args...]")
      quit(1)
    let action = args[1].toLowerAscii
    let room = args[2]
    var key = ""
    var val = ""
    var ttlSec = -1

    var posArgs: seq[string] = @[]
    var i = 3
    while i < args.len:
      let a = args[i]
      if a.startsWith("--ttl="):
        ttlSec = parseRequiredInt(a[6..^1], "--ttl")
      elif a == "--ttl" and i + 1 < args.len:
        ttlSec = parseRequiredInt(args[i+1], "--ttl"); inc i
      elif not a.startsWith("-"):
        posArgs.add(a)
      inc i

    if posArgs.len > 0: key = posArgs[0]
    if posArgs.len > 1: val = posArgs[1]

    case action
    of "set":
      if key.len == 0 or val.len == 0:
        stderr.writeLine("Usage: rhizo blackboard set <room> <key> <json_value> [--ttl <sec>]")
        quit(1)
      let res = doBlackboard(cfg, "set", room, key, resolveVal(val), ttlSec)
      echo res
    of "get":
      if key.len == 0:
        stderr.writeLine("Usage: rhizo blackboard get <room> <key>")
        quit(1)
      let res = doBlackboard(cfg, "get", room, key)
      if res.len > 0:
        echo res
    of "rev":
      if key.len == 0:
        stderr.writeLine("Usage: rhizo blackboard rev <room> <key>")
        quit(1)
      let res = doBlackboard(cfg, "rev", room, key)
      echo res
    of "append":
      if key.len == 0 or val.len == 0:
        stderr.writeLine("Usage: rhizo blackboard append <room> <list_key> <entry> [--ttl <sec>]")
        quit(1)
      let res = doBlackboard(cfg, "append", room, key, resolveVal(val), ttlSec)
      echo res
    of "snapshot", "dump":
      let res = doBlackboard(cfg, "snapshot", room)
      if key.len > 0:
        try:
          writeFile(key, res)
          echo "OK"
        except CatchableError as e:
          stderr.writeLine("Error writing snapshot to file '" & key & "': " & e.msg)
          quit(1)
      else:
        echo res
    of "load", "restore":
      if key.len == 0:
        stderr.writeLine("Usage: rhizo blackboard load <room> <file_or_json> [--ttl <sec>]")
        quit(1)
      var snapshotJson = key
      if fileExists(key):
        try:
          snapshotJson = readFile(key)
        except CatchableError as e:
          stderr.writeLine("Error reading snapshot file '" & key & "': " & e.msg)
          quit(1)
      elif key.startsWith("@") and fileExists(key[1..^1]):
        try:
          snapshotJson = readFile(key[1..^1])
        except CatchableError as e:
          stderr.writeLine("Error reading snapshot file '" & key[1..^1] & "': " & e.msg)
          quit(1)
      let res = doBlackboardLoad(cfg, room, snapshotJson, if ttlSec > 0: ttlSec else: 0)
      echo res
    of "delete", "del":
      if key.len == 0:
        stderr.writeLine("Usage: rhizo blackboard delete <room> <key>")
        quit(1)
      let res = doBlackboard(cfg, "delete", room, key)
      echo res
    of "clear":
      let res = doBlackboard(cfg, "clear", room)
      echo res
    else:
      stderr.writeLine("Unknown blackboard action: " & action)
      stderr.writeLine("Usage: rhizo blackboard <set|get|rev|append|snapshot|load|delete|clear> <room> [args...]")
      quit(1)

  of "floor":
    if args.len < 3:
      stderr.writeLine("Usage: rhizo floor <request|yield|pass|status> <room> [args...]")
      quit(1)
    let action = args[1].toLowerAscii
    let room = args[2]
    var agentName = getActiveAgentName(cfg, "", fallbackDefault = false)

    case action
    of "request":
      var waitSec = 0
      var leaseSec = 60
      var i = 3
      while i < args.len:
        let a = args[i]
        if a.startsWith("--lease="):
          leaseSec = parseRequiredInt(a[8..^1], "--lease")
        elif a == "--lease" and i + 1 < args.len:
          leaseSec = parseRequiredInt(args[i+1], "--lease")
          inc i
        elif a.startsWith("--wait="):
          waitSec = parseRequiredInt(a[7..^1], "--wait")
        elif a == "--wait" and i + 1 < args.len:
          waitSec = parseRequiredInt(args[i+1], "--wait")
          inc i
        elif not a.startsWith("-"):
          waitSec = parseRequiredInt(a, "wait")
        inc i
      if agentName.len == 0:
        agentName = getActiveAgentName(cfg, "", fallbackDefault = false)
      if agentName.len == 0:
        stderr.writeLine("Error: No agent name specified. Run 'rhizo open <name>', pass the agent name, or export RHIZO_AGENT_NAME=<name>.")
        quit(1)
      doFloorRequest(cfg, room, agentName, waitSec, leaseSec)

    of "yield":
      var force = false
      var leaseSec = 60
      var i = 3
      while i < args.len:
        let a = args[i]
        if a in ["--force", "-f"]: force = true
        elif a.startsWith("--lease="):
          leaseSec = parseRequiredInt(a[8..^1], "--lease")
        inc i
      if agentName.len == 0:
        agentName = getActiveAgentName(cfg, "", fallbackDefault = false)
      if agentName.len == 0:
        stderr.writeLine("Error: No agent name specified. Run 'rhizo open <name>', pass the agent name, or export RHIZO_AGENT_NAME=<name>.")
        quit(1)
      doFloorYield(cfg, room, agentName, force, leaseSec)

    of "pass":
      var targetAgent = ""
      var force = false
      var leaseSec = 60
      var i = 3
      while i < args.len:
        let a = args[i]
        if a.startsWith("--to="): targetAgent = a[5..^1]
        elif a == "--to" and i + 1 < args.len: targetAgent = args[i+1]; inc i
        elif a in ["--force", "-f"]: force = true
        elif a.startsWith("--lease="):
          leaseSec = parseRequiredInt(a[8..^1], "--lease")
        elif not a.startsWith("-"):
          if targetAgent.len == 0: targetAgent = a
        inc i
      if targetAgent.len == 0:
        stderr.writeLine("Error: Missing target agent for floor pass. Use --to <agent>.")
        quit(1)
      if agentName.len == 0:
        agentName = getActiveAgentName(cfg, "", fallbackDefault = false)
      if agentName.len == 0:
        stderr.writeLine("Error: No agent name specified. Run 'rhizo open <name>', pass the agent name, or export RHIZO_AGENT_NAME=<name>.")
        quit(1)
      doFloorPass(cfg, room, agentName, targetAgent, force, leaseSec)

    of "status", "show":
      doFloorStatus(cfg, room)

    else:
      stderr.writeLine("Unknown floor action: " & action)
      stderr.writeLine("Usage: rhizo floor <request|yield|pass|status> <room> [args...]")
      quit(1)

  of "cancel":
    if args.len < 2:
      stderr.writeLine("Error: Missing run_id or cancel subcommand.")
      stderr.writeLine("Usage:")
      stderr.writeLine("  rhizo cancel <run_id> [--reason <reason>] [--by <agent>] [--ttl <sec>]")
      stderr.writeLine("  rhizo cancel check <run_id> [--raw] [--exit-code]")
      stderr.writeLine("  rhizo cancel clear <run_id>")
      quit(1)

    var action = ""
    var runId = ""
    var reason = "Cancelled by orchestrator"
    var byAgent = getActiveAgentName(cfg, "", fallbackDefault = true)
    var ttlSec = 3600
    var rawOutput = false
    var exitCodeOnUncancelled = false

    if args[1] in ["check", "status"]:
      action = "check"
      if args.len > 2: runId = args[2]
      var i = 3
      while i < args.len:
        let a = args[i]
        if a in ["--raw", "-r"]: rawOutput = true
        elif a in ["--exit-code", "-e"]: exitCodeOnUncancelled = true
        elif not a.startsWith("-") and runId.len == 0: runId = a
        inc i
    elif args[1] in ["clear", "reset"]:
      action = "clear"
      if args.len > 2: runId = args[2]
      var i = 3
      while i < args.len:
        let a = args[i]
        if not a.startsWith("-") and runId.len == 0: runId = a
        inc i
    else:
      runId = args[1]
      var i = 2
      while i < args.len:
        let a = args[i]
        if a == "--check": action = "check"
        elif a == "--clear": action = "clear"
        elif a in ["--raw", "-r"]: rawOutput = true
        elif a in ["--exit-code", "-e"]: exitCodeOnUncancelled = true
        elif a.startsWith("--reason="): reason = a[9..^1]
        elif a == "--reason" and i + 1 < args.len: reason = args[i+1]; inc i
        elif a.startsWith("--by="): byAgent = a[5..^1]
        elif a == "--by" and i + 1 < args.len: byAgent = args[i+1]; inc i
        elif a.startsWith("--ttl="):
          ttlSec = parseRequiredInt(a[6..^1], "--ttl")
        elif a == "--ttl" and i + 1 < args.len:
          ttlSec = parseRequiredInt(args[i+1], "--ttl"); inc i
        elif not a.startsWith("-") and reason == "Cancelled by orchestrator":
          reason = a
        inc i

    if runId.len == 0:
      stderr.writeLine("Error: Missing run_id.")
      quit(1)

    case action
    of "check":
      doCancelCheck(cfg, runId, rawOutput, exitCodeOnUncancelled)
    of "clear":
      doCancelClear(cfg, runId)
    else:
      doCancelSet(cfg, runId, reason, byAgent, ttlSec)

  of "ballot":
    if args.len < 3:
      stderr.writeLine("Error: Missing ballot subcommand or ballot_id.")
      stderr.writeLine("Usage:")
      stderr.writeLine("  rhizo ballot open <ballot_id> --options <opt1,opt2> [--voters <v1,v2>] [--ttl sec]")
      stderr.writeLine("  rhizo ballot cast <ballot_id> --vote <choice> [--voter <agent>]")
      stderr.writeLine("  rhizo ballot tally <ballot_id> [--close] [--raw]")
      stderr.writeLine("  rhizo ballot status <ballot_id>")
      quit(1)

    let action = args[1].toLowerAscii
    let ballotId = args[2]

    case action
    of "open":
      var options = ""
      var voters = "*"
      var ttlSec = 3600
      var i = 3
      while i < args.len:
        let a = args[i]
        if a.startsWith("--options="): options = a[10..^1]
        elif a == "--options" and i + 1 < args.len: options = args[i+1]; inc i
        elif a.startsWith("--voters="): voters = a[9..^1]
        elif a == "--voters" and i + 1 < args.len: voters = args[i+1]; inc i
        elif a.startsWith("--ttl="):
          ttlSec = parseRequiredInt(a[6..^1], "--ttl")
        elif a == "--ttl" and i + 1 < args.len:
          ttlSec = parseRequiredInt(args[i+1], "--ttl"); inc i
        elif not a.startsWith("-") and options == "":
          options = a
        inc i
      if options.len == 0:
        stderr.writeLine("Error: Missing --options for ballot open.")
        quit(1)
      doBallotOpen(cfg, ballotId, options, voters, ttlSec)

    of "cast", "vote":
      var choice = ""
      var voter = ""
      var i = 3
      while i < args.len:
        let a = args[i]
        if a.startsWith("--vote="): choice = a[7..^1]
        elif a == "--vote" and i + 1 < args.len: choice = args[i+1]; inc i
        elif a.startsWith("--choice="): choice = a[9..^1]
        elif a == "--choice" and i + 1 < args.len: choice = args[i+1]; inc i
        elif a.startsWith("--voter="): voter = a[8..^1]
        elif a == "--voter" and i + 1 < args.len: voter = args[i+1]; inc i
        elif not a.startsWith("-") and choice == "":
          choice = a
        inc i
      if choice.len == 0:
        stderr.writeLine("Error: Missing --vote for ballot cast.")
        quit(1)
      if voter.len == 0:
        voter = getActiveAgentName(cfg, "", fallbackDefault = false)
      if voter.len == 0:
        stderr.writeLine("Error: No voter name specified. Pass --voter <name>, run 'rhizo open <name>', or export RHIZO_AGENT_NAME=<name>.")
        quit(1)
      doBallotCast(cfg, ballotId, voter, choice)

    of "tally":
      var closeBallot = false
      var rawOutput = false
      var i = 3
      while i < args.len:
        let a = args[i]
        if a in ["--close", "-c"]: closeBallot = true
        elif a in ["--raw", "-r"]: rawOutput = true
        inc i
      doBallotTally(cfg, ballotId, closeBallot, rawOutput)

    of "status", "show":
      doBallotStatus(cfg, ballotId)

    else:
      stderr.writeLine("Unknown ballot action: " & action)
      stderr.writeLine("Usage: rhizo ballot <open|cast|tally|status> <ballot_id> [args...]")
      quit(1)

  of "leader":
    if args.len < 3:
      stderr.writeLine("Error: Missing leader action or role name.")
      stderr.writeLine("Usage:")
      stderr.writeLine("  rhizo leader acquire <role> [--lease <sec>] [--agent <name>]")
      stderr.writeLine("  rhizo leader renew <role> [--lease <sec>] [--agent <name>]")
      stderr.writeLine("  rhizo leader resign <role> [--agent <name>]")
      stderr.writeLine("  rhizo leader status <role>")
      quit(1)

    let action = args[1].toLowerAscii
    let role = args[2]

    var agentName = ""
    var leaseSec = 30

    var i = 3
    while i < args.len:
      let a = args[i]
      if a.startsWith("--agent="): agentName = a[8..^1]
      elif a == "--agent" and i + 1 < args.len: agentName = args[i+1]; inc i
      elif a.startsWith("--lease="):
        leaseSec = parseRequiredInt(a[8..^1], "--lease")
      elif a == "--lease" and i + 1 < args.len:
        leaseSec = parseRequiredInt(args[i+1], "--lease"); inc i
      elif not a.startsWith("-"):
        leaseSec = parseRequiredInt(a, "lease")
      inc i

    if agentName.len == 0:
      agentName = getActiveAgentName(cfg, "", fallbackDefault = false)
    if agentName.len == 0 and action in ["acquire", "elect", "renew", "heartbeat", "resign", "release", "yield"]:
      stderr.writeLine("Error: No agent name specified. Pass --agent <name>, run 'rhizo open <name>', or export RHIZO_AGENT_NAME=<name>.")
      quit(1)

    case action
    of "acquire", "elect":
      doLeaderAcquire(cfg, role, agentName, leaseSec)
    of "renew", "heartbeat":
      doLeaderRenew(cfg, role, agentName, leaseSec)
    of "resign", "release", "yield":
      doLeaderResign(cfg, role, agentName)
    of "status", "show":
      doLeaderStatus(cfg, role)
    else:
      stderr.writeLine("Unknown leader action: " & action)
      stderr.writeLine("Usage: rhizo leader <acquire|renew|resign|status> <role> [args...]")
      quit(1)

  of "workflow", "dag":
    if args.len < 3:
      stderr.writeLine("Error: Missing workflow action or flow ID.")
      stderr.writeLine("Usage:")
      stderr.writeLine("  rhizo workflow define <flow_id> --steps <s1,s2,...> [--deps <c:p1,p2;...>] [--ttl <sec>]")
      stderr.writeLine("  rhizo workflow next <flow_id> [--raw]")
      stderr.writeLine("  rhizo workflow resolve <flow_id> <step> [--output <msg>] [--raw]")
      stderr.writeLine("  rhizo workflow fail <flow_id> <step> [--reason <msg>]")
      stderr.writeLine("  rhizo workflow status <flow_id> [--raw]")
      stderr.writeLine("  rhizo workflow export <flow_id> [output_file]")
      stderr.writeLine("  rhizo workflow import <flow_id> <file_or_json> [--ttl <sec>]")
      quit(1)

    let action = args[1].toLowerAscii
    let flowId = args[2]

    var steps = ""
    var deps = ""
    var ttlSec = 86400
    var stepName = ""
    var outputMsg = ""
    var reasonMsg = ""
    var rawOutput = false

    var posArgs: seq[string] = @[]
    var i = 3
    while i < args.len:
      let a = args[i]
      if a.startsWith("--steps="): steps = a[8..^1]
      elif a == "--steps" and i + 1 < args.len: steps = args[i+1]; inc i
      elif a.startsWith("--deps="): deps = a[7..^1]
      elif a == "--deps" and i + 1 < args.len: deps = args[i+1]; inc i
      elif a.startsWith("--ttl="):
        ttlSec = parseRequiredInt(a[6..^1], "--ttl")
      elif a == "--ttl" and i + 1 < args.len:
        ttlSec = parseRequiredInt(args[i+1], "--ttl"); inc i
      elif a.startsWith("--output="): outputMsg = a[9..^1]
      elif a == "--output" and i + 1 < args.len: outputMsg = args[i+1]; inc i
      elif a.startsWith("--reason="): reasonMsg = a[9..^1]
      elif a == "--reason" and i + 1 < args.len: reasonMsg = args[i+1]; inc i
      elif a == "--raw": rawOutput = true
      elif not a.startsWith("-"):
        posArgs.add(a)
      inc i

    case action
    of "define", "create":
      doWorkflowDefine(cfg, flowId, steps, deps, ttlSec)
    of "next", "ready":
      doWorkflowNext(cfg, flowId, rawOutput)
    of "resolve", "complete":
      if posArgs.len > 0: stepName = posArgs[0]
      if stepName.len == 0:
        stderr.writeLine("Error: Missing step name to resolve.")
        quit(1)
      doWorkflowResolve(cfg, flowId, stepName, outputMsg, rawOutput)
    of "fail":
      if posArgs.len > 0: stepName = posArgs[0]
      if stepName.len == 0:
        stderr.writeLine("Error: Missing step name to fail.")
        quit(1)
      doWorkflowFail(cfg, flowId, stepName, reasonMsg)
    of "status", "show":
      doWorkflowStatus(cfg, flowId, rawOutput)
    of "export", "dump":
      let outPath = if posArgs.len > 0: posArgs[0] else: ""
      doWorkflowExport(cfg, flowId, outPath)
    of "import", "load":
      let inPayload = if posArgs.len > 0: posArgs[0] else: ""
      if inPayload.len == 0:
        stderr.writeLine("Error: Missing workflow payload or file to import.")
        stderr.writeLine("Usage: rhizo workflow import <flow_id> <file_or_json> [--ttl <sec>]")
        quit(1)
      doWorkflowImport(cfg, flowId, inPayload, ttlSec)
    else:
      stderr.writeLine("Unknown workflow action: " & action)
      stderr.writeLine("Usage: rhizo workflow <define|next|resolve|fail|status|export|import> <flow_id> [args...]")
      quit(1)

  of "sweep":
    var dryRun = false
    var rawOutput = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if a == "--dry-run" or a == "-n": dryRun = true
      elif a == "--raw": rawOutput = true
      inc i
    doSweep(cfg, dryRun, rawOutput)

  of "status":
    var state = ""
    var activity = ""
    var explicitName = ""
    var rearmListen = false
    var listenTimeout = -1
    var i = 1
    while i < args.len:
      let a = args[i]
      if a in ["--listen", "-l"]:
        rearmListen = true
      elif a.startsWith("--listen="):
        rearmListen = true
        try: listenTimeout = parseInt(a[9..^1])
        except ValueError:
          stderr.writeLine("Error: Invalid integer for --listen: '" & a[9..^1] & "'")
          quit(1)
      elif a.startsWith("--listen-timeout="):
        rearmListen = true
        try: listenTimeout = parseInt(a[17..^1])
        except ValueError:
          stderr.writeLine("Error: Invalid integer for --listen-timeout: '" & a[17..^1] & "'")
          quit(1)
      elif a == "--listen-timeout" and i + 1 < args.len:
        rearmListen = true
        try: listenTimeout = parseInt(args[i+1])
        except ValueError:
          stderr.writeLine("Error: Invalid integer for --listen-timeout: '" & args[i+1] & "'")
          quit(1)
        inc i
      elif not a.startsWith("-"):
        if state.len == 0: state = a
        elif activity.len == 0: activity = a
        elif explicitName.len == 0: explicitName = a
      inc i

    if state.len == 0:
      stderr.writeLine("Error: Missing state argument for status command.")
      stderr.writeLine("Usage: rhizo status <idle|busy|error> [activity_text] [name] [--listen/-l]")
      quit(1)

    let name = getActiveAgentName(cfg, explicitName, fallbackDefault = false)
    if name.len == 0:
      stderr.writeLine("Error: No agent name specified. Run 'rhizo open <name>', pass the agent name, or export RHIZO_AGENT_NAME=<name>.")
      quit(1)

    let res = doStatus(cfg, name, state, activity)
    if not rearmListen:
      echo res
    else:
      stderr.writeLine("[RHIZO STATUS] " & res)
      let (alreadyListening, existingPid, existingHost) = getActiveListenerInfo(cfg, name)
      if alreadyListening:
        stderr.writeLine("[RHIZO LISTENER] Listener already active for agent '" & name & "' (PID " & $existingPid & " on " & existingHost & "). Skipping duplicate listener.")
      else:
        stderr.writeLine("[RHIZO LISTENER] Entering listening mode for agent '" & name & "'...")
        doListen(cfg, name, listenTimeout)

  of "lock":
    if args.len < 2:
      stderr.writeLine("Error: Missing lock name.")
      stderr.writeLine("Usage: rhizo lock <lock_name> [ttl_sec] [--fencing] [--raw]")
      quit(1)
    let lockName = args[1]
    var ttl = 30
    var withFencing = false
    var rawOutput = false
    var i = 2
    while i < args.len:
      let a = args[i]
      if a == "--fencing" or a == "-f": withFencing = true
      elif a == "--raw": rawOutput = true
      elif not a.startsWith("-"):
        ttl = parseRequiredInt(a, "lock ttl")
      inc i
    let (msg, code) = doLock(cfg, lockName, ttl, withFencing, rawOutput)
    if code != 0:
      stderr.writeLine(msg)
      quit(code)
    echo msg

  of "unlock":
    if args.len < 2:
      stderr.writeLine("Error: Missing lock name.")
      stderr.writeLine("Usage: rhizo unlock <lock_name>")
      quit(1)
    let lockName = args[1]
    let (msg, code) = doUnlock(cfg, lockName)
    if code != 0:
      stderr.writeLine(msg)
      quit(code)
    echo msg

  of "pub", "publish":
    if args.len < 3:
      stderr.writeLine("Error: Missing arguments for pub command.")
      stderr.writeLine("Usage: rhizo pub <channel> <message>")
      quit(1)
    let channel = args[1]
    let message = args[2]
    echo doPub(cfg, channel, message)

  of "sub", "subscribe":
    if args.len < 2:
      stderr.writeLine("Error: Missing channel name for sub command.")
      stderr.writeLine("Usage: rhizo sub <channel> [timeout_sec]")
      quit(1)
    let channel = args[1]
    var timeout = -1
    if args.len > 2:
      timeout = parseRequiredInt(args[2], "sub timeout")
    doSub(cfg, channel, timeout)

  of "guide":
    if args.len < 2:
      stderr.writeLine("Error: Missing guide action.")
      stderr.writeLine("Usage: rhizo guide <install|uninstall|check> [path]")
      quit(1)
    let action = args[1].toLowerAscii
    let target = if args.len > 2: args[2] else: "AGENTS.md"
    case action
    of "install", "i", "add":
      let (ok, msg) = installGuide(target)
      if ok:
        echo msg
      else:
        stderr.writeLine(msg)
        quit(1)
    of "uninstall", "u", "remove", "rm":
      let (ok, msg) = uninstallGuide(target)
      if ok:
        echo msg
      else:
        stderr.writeLine(msg)
        quit(1)
    of "check", "status":
      let st = checkGuide(target)
      case st
      of gsInstalled:
        echo "[INSTALLED] Rhizo Guide is installed in: " & target
      of gsNotFound:
        echo "[NOT FOUND] Rhizo Guide not found in: " & target
      of gsMalformed:
        stderr.writeLine("[MALFORMED] Unbalanced markers found in: " & target)
        quit(1)
      of gsFileMissing:
        echo "[MISSING] Target file does not exist: " & target
    else:
      stderr.writeLine("Error: Unknown guide action: '" & action & "'")
      stderr.writeLine("Usage: rhizo guide <install|uninstall|check> [path]")
      quit(1)

  of "task":
    if args.len < 2:
      stderr.writeLine("Usage: rhizo task <create|claim|progress|gate-report|complete|yield|current|sweep|get|list> [args...]")
      quit(1)
    let action = args[1].toLowerAscii
    case action
    of "create":
      var taskId = ""
      var title = ""
      var deliverable = ""
      var spec = ""
      var dependsOn = ""
      var target = ""
      var fencingKeys = ""
      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--title="): title = a[8..^1]
        elif a == "--title" and i + 1 < args.len: title = args[i+1]; inc i
        elif a.startsWith("--deliverable="): deliverable = a[14..^1]
        elif a == "--deliverable" and i + 1 < args.len: deliverable = args[i+1]; inc i
        elif a.startsWith("--spec="): spec = resolveVal(a[7..^1])
        elif a == "--spec" and i + 1 < args.len: spec = resolveVal(args[i+1]); inc i
        elif a.startsWith("--depends-on="): dependsOn = a[13..^1]
        elif a == "--depends-on" and i + 1 < args.len: dependsOn = args[i+1]; inc i
        elif a.startsWith("--target="): target = a[9..^1]
        elif a == "--target" and i + 1 < args.len: target = args[i+1]; inc i
        elif a.startsWith("--fencing-keys="): fencingKeys = a[15..^1]
        elif a == "--fencing-keys" and i + 1 < args.len: fencingKeys = args[i+1]; inc i
        elif not a.startsWith("-"):
          if taskId.len == 0: taskId = a
          elif title.len == 0: title = a
        inc i
      if taskId.len == 0:
        stderr.writeLine("Error: Missing task id. Usage: rhizo task create <id> --title <title> [--deliverable <deliv>] [--spec <spec>] [--depends-on <ids>] [--target <worker|queue>]")
        quit(1)
      let res = doTask(cfg, "create", [taskId, title, deliverable, spec, dependsOn, target, fencingKeys])
      if res.startsWith("ERR"):
        stderr.writeLine(res)
        quit(1)
      doAuditLog(cfg, getActiveAgentName(cfg, fallbackDefault = true), "task.create", taskId & " - " & title)
      try:
        let node = parseJson(res)
        let st = node.getOrDefault("state").getStr("QUEUED")
        echo "CREATED task '" & taskId & "' (state: " & st & ")"
      except CatchableError:
        echo "CREATED task '" & taskId & "'"

    of "claim":
      var taskId = ""
      var worker = ""
      var leaseSec = 300
      var strandPath = ""
      var noVine = false
      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--worker="): worker = a[9..^1]
        elif a == "--worker" and i + 1 < args.len: worker = args[i+1]; inc i
        elif a.startsWith("--lease="): leaseSec = parseRequiredInt(a[8..^1], "--lease")
        elif a == "--lease" and i + 1 < args.len: leaseSec = parseRequiredInt(args[i+1], "--lease"); inc i
        elif a.startsWith("--strand="): strandPath = a[9..^1]
        elif a == "--strand" and i + 1 < args.len: strandPath = args[i+1]; inc i
        elif a == "--no-vine": noVine = true
        elif not a.startsWith("-"):
          if taskId.len == 0: taskId = a
          elif worker.len == 0: worker = a
        inc i
      if taskId.len == 0:
        stderr.writeLine("Error: Missing task id. Usage: rhizo task claim <id> [--worker <worker>] [--lease <sec>] [--strand <path>] [--no-vine]")
        quit(1)
      if worker.len == 0:
        worker = getActiveAgentName(cfg, fallbackDefault = true)
      if worker.len == 0:
        stderr.writeLine("Error: Cannot determine worker name for task claim. Pass '--worker <name>' or export RHIZO_AGENT_NAME=<name>.")
        quit(1)

      # Auto-provision Vine strand if vine is available and not disabled
      if not noVine and strandPath.len == 0 and findExe("vine").len > 0:
        let (vOut, vCode) = execCmdEx("vine new " & quoteShell(taskId))
        if vCode == 0:
          strandPath = ".vine/strands/" & taskId
          stderr.writeLine("[VINE] Provisioned isolated strand: " & strandPath)
        else:
          stderr.writeLine("[VINE NOTICE] vine new failed or skipped: " & vOut.strip())

      let res = doTask(cfg, "claim", [taskId, worker, $leaseSec, strandPath])
      if res.startsWith("ERR"):
        stderr.writeLine(res)
        quit(1)

      # Mirror claimed task locally
      try:
        createDir(getHomeDir() / ".config" / "rhizo")
        var tObj = newJObject()
        tObj["id"] = %taskId
        tObj["owner"] = %worker
        tObj["state"] = %"IN_PROGRESS"
        tObj["lease_sec"] = %leaseSec
        tObj["strand_path"] = %strandPath
        writeFile(currentTaskFilePath(worker), $tObj)
      except CatchableError: discard

      doAuditLog(cfg, worker, "task.claim", taskId & " (lease " & $leaseSec & "s)")
      if strandPath.len > 0:
        echo "CLAIMED task '" & taskId & "' for worker '" & worker & "' (lease: " & $leaseSec & "s, strand: " & strandPath & ")"
      else:
        echo "CLAIMED task '" & taskId & "' for worker '" & worker & "' (lease: " & $leaseSec & "s)"

    of "progress":
      var taskId = ""
      var progressText = ""
      var renewSec = 300
      var worker = ""
      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--progress="): progressText = a[11..^1]
        elif a == "--progress" and i + 1 < args.len: progressText = args[i+1]; inc i
        elif a.startsWith("--renew="): renewSec = parseRequiredInt(a[8..^1], "--renew")
        elif a == "--renew" and i + 1 < args.len: renewSec = parseRequiredInt(args[i+1], "--renew"); inc i
        elif a.startsWith("--worker="): worker = a[9..^1]
        elif a == "--worker" and i + 1 < args.len: worker = args[i+1]; inc i
        elif not a.startsWith("-"):
          if taskId.len == 0: taskId = a
          elif progressText.len == 0: progressText = a
        inc i
      if taskId.len == 0:
        stderr.writeLine("Error: Missing task id. Usage: rhizo task progress <id> --progress <text> [--renew <sec>]")
        quit(1)
      if worker.len == 0:
        worker = getActiveAgentName(cfg, fallbackDefault = true)
      let res = doTask(cfg, "progress", [taskId, worker, progressText, $renewSec])
      if res.startsWith("ERR"):
        stderr.writeLine(res)
        quit(1)
      doAuditLog(cfg, worker, "task.progress", taskId & ": " & progressText)
      echo "UPDATED progress on task '" & taskId & "'"

    of "gate-report":
      var taskId = ""
      var worker = ""
      var gateToken = ""
      var strandPath = ""
      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--worker="): worker = a[9..^1]
        elif a == "--worker" and i + 1 < args.len: worker = args[i+1]; inc i
        elif a.startsWith("--gate-token="): gateToken = a[13..^1]
        elif a == "--gate-token" and i + 1 < args.len: gateToken = args[i+1]; inc i
        elif a.startsWith("--token="): gateToken = a[8..^1]
        elif a == "--token" and i + 1 < args.len: gateToken = args[i+1]; inc i
        elif a.startsWith("--strand="): strandPath = a[9..^1]
        elif a == "--strand" and i + 1 < args.len: strandPath = args[i+1]; inc i
        elif not a.startsWith("-"):
          if taskId.len == 0: taskId = a
          elif gateToken.len == 0: gateToken = a
        inc i
      if taskId.len == 0 or gateToken.len == 0:
        stderr.writeLine("Error: Missing task id or gate token. Usage: rhizo task gate-report <id> --token <token> [--strand <path>]")
        quit(1)
      if worker.len == 0:
        worker = getActiveAgentName(cfg, fallbackDefault = true)
      let res = doTask(cfg, "gate-report", [taskId, worker, gateToken, strandPath])
      if res.startsWith("ERR"):
        stderr.writeLine(res)
        quit(1)
      echo "REPORTED gate pass for task '" & taskId & "' (token: " & gateToken & ", state: READY_TO_WEAVE)"

    of "complete":
      var taskId = ""
      var worker = ""
      var gateToken = ""
      var weave = false
      var skipGate = false
      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--worker="): worker = a[9..^1]
        elif a == "--worker" and i + 1 < args.len: worker = args[i+1]; inc i
        elif a.startsWith("--gate-token="): gateToken = a[13..^1]
        elif a == "--gate-token" and i + 1 < args.len: gateToken = args[i+1]; inc i
        elif a == "--weave": weave = true
        elif a == "--skip-gate": skipGate = true
        elif not a.startsWith("-"):
          if taskId.len == 0: taskId = a
        inc i
      if taskId.len == 0:
        stderr.writeLine("Error: Missing task id. Usage: rhizo task complete <id> [--weave] [--skip-gate]")
        quit(1)
      if worker.len == 0:
        worker = getActiveAgentName(cfg, fallbackDefault = true)

      # Check Vine Two-Key gate if strand was registered
      let taskDataStr = doTask(cfg, "get", [taskId])
      var strandPath = ""
      try:
        let td = parseJson(taskDataStr)
        strandPath = td.getOrDefault("strand_path").getStr("")
      except CatchableError:
        discard

      let res = doTaskComplete(cfg, taskId, worker, gateToken, strandPath, weave, skipGate)
      try:
        let cNode = parseJson(res)
        let unblockedCount = cNode.getOrDefault("unblocked_count").getInt(0)
        if unblockedCount > 0:
          echo "COMPLETED task '" & taskId & "' (automatically unblocked " & $unblockedCount & " dependent task(s))"
        else:
          echo "COMPLETED task '" & taskId & "'"
      except CatchableError:
        echo "COMPLETED task '" & taskId & "'"

    of "yield", "abandon":
      var taskId = ""
      var worker = ""
      var reason = ""
      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--reason="): reason = a[9..^1]
        elif a == "--reason" and i + 1 < args.len: reason = args[i+1]; inc i
        elif a.startsWith("--worker="): worker = a[9..^1]
        elif a == "--worker" and i + 1 < args.len: worker = args[i+1]; inc i
        elif not a.startsWith("-"):
          if taskId.len == 0: taskId = a
          elif reason.len == 0: reason = a
        inc i
      if taskId.len == 0:
        stderr.writeLine("Error: Missing task id. Usage: rhizo task yield <id> [--reason <reason>]")
        quit(1)
      if worker.len == 0:
        worker = getActiveAgentName(cfg, fallbackDefault = true)
      let res = doTask(cfg, "yield", [taskId, worker, reason])
      if res.startsWith("ERR"):
        stderr.writeLine(res)
        quit(1)

      let yieldTaskFile = currentTaskFilePath(worker)
      if fileExists(yieldTaskFile):
        try: removeFile(yieldTaskFile) except CatchableError: discard
      let legacyYieldFile = currentTaskFilePath("")
      if fileExists(legacyYieldFile):
        try: removeFile(legacyYieldFile) except CatchableError: discard

      doAuditLog(cfg, worker, "task.yield", taskId & (if reason.len > 0: ": " & reason else: ""))
      echo "YIELDED task '" & taskId & "'"

    of "current":
      var worker = ""
      var jsonOut = false
      var i = 2
      while i < args.len:
        let a = args[i]
        if a == "--json": jsonOut = true
        elif a.startsWith("--worker="): worker = a[9..^1]
        elif a == "--worker" and i + 1 < args.len: worker = args[i+1]; inc i
        elif not a.startsWith("-"):
          if worker.len == 0: worker = a
        inc i
      if worker.len == 0:
        worker = getActiveAgentName(cfg, fallbackDefault = true)
      let res = doTask(cfg, "current", [worker])
      if jsonOut:
        echo res
      else:
        try:
          let node = parseJson(res)
          if node.len == 0:
            echo "No active task for @" & worker & "."
          else:
            echo "Active Task for @" & worker & ":"
            for k, v in node.pairs:
              echo "  " & k.alignLeft(16) & ": " & v.getStr($v)
        except CatchableError:
          echo res

    of "sweep":
      var jsonOut = false
      for a in args[2..^1]:
        if a == "--json": jsonOut = true
      let res = doTask(cfg, "sweep", [])
      if jsonOut:
        echo res
      else:
        try:
          let node = parseJson(res)
          if node.len == 0:
            echo "Zero stalled tasks found. All task leases healthy."
          else:
            echo "Swept " & $node.len & " stalled/orphaned task(s):"
            for item in node:
              echo "  Task: " & item.getOrDefault("id").getStr("") & " -> " & item.getOrDefault("new_state").getStr("")
        except CatchableError:
          echo res

    of "get":
      if args.len < 3:
        stderr.writeLine("Usage: rhizo task get <id> [--json]")
        quit(1)
      let taskId = args[2]
      var jsonOut = false
      for a in args[3..^1]:
        if a == "--json": jsonOut = true
      let res = doTask(cfg, "get", [taskId])
      if jsonOut:
        echo res
      else:
        try:
          let node = parseJson(res)
          if node.len == 0:
            echo "Task '" & taskId & "' not found."
          else:
            for k, v in node.pairs:
              echo k.alignLeft(16) & ": " & v.getStr($v)
        except CatchableError:
          echo res

    of "list":
      var jsonOut = false
      var stateFilter = ""
      var i = 2
      while i < args.len:
        let a = args[i]
        if a == "--json": jsonOut = true
        elif a.startsWith("--state="): stateFilter = a[8..^1]
        elif a == "--state" and i + 1 < args.len: stateFilter = args[i+1]; inc i
        inc i
      let res = doTask(cfg, "list", [stateFilter])
      if jsonOut:
        echo res
      else:
        echo formatTasksTable(res)

    else:
      stderr.writeLine("Unknown task action: '" & action & "'. Valid actions: create, claim, progress, gate-report, complete, yield, current, sweep, get, list")
      quit(1)

  of "decision":
    if args.len < 2:
      stderr.writeLine("Usage: rhizo decision <propose|approve|reject|verify|get|list> [args...]")
      quit(1)
    let action = args[1].toLowerAscii
    case action
    of "propose":
      var decId = ""
      var title = ""
      var summary = ""
      var proposedBy = ""
      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--title="): title = a[8..^1]
        elif a == "--title" and i + 1 < args.len: title = args[i+1]; inc i
        elif a.startsWith("--summary="): summary = resolveVal(a[10..^1])
        elif a == "--summary" and i + 1 < args.len: summary = resolveVal(args[i+1]); inc i
        elif a.startsWith("--by="): proposedBy = a[5..^1]
        elif a == "--by" and i + 1 < args.len: proposedBy = args[i+1]; inc i
        elif not a.startsWith("-"):
          if decId.len == 0: decId = a
          elif title.len == 0: title = a
        inc i
      if decId.len == 0:
        stderr.writeLine("Error: Missing decision id. Usage: rhizo decision propose <id> --title <title> [--summary <sum>]")
        quit(1)
      if proposedBy.len == 0:
        proposedBy = getActiveAgentName(cfg, fallbackDefault = true)
      let res = doDecision(cfg, "propose", [decId, title, summary, proposedBy])
      if res.startsWith("ERR"):
        stderr.writeLine(res)
        quit(1)
      doAuditLog(cfg, proposedBy, "decision.propose", decId & " - " & title)
      echo "PROPOSED decision '" & decId & "'"

    of "approve":
      var decId = ""
      var note = ""
      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--note="): note = a[7..^1]
        elif a == "--note" and i + 1 < args.len: note = args[i+1]; inc i
        elif not a.startsWith("-"):
          if decId.len == 0: decId = a
          elif note.len == 0: note = a
        inc i
      if decId.len == 0:
        stderr.writeLine("Error: Missing decision id. Usage: rhizo decision approve <id> [--note <note>]")
        quit(1)
      let res = doDecision(cfg, "approve", [decId, note])
      if res.startsWith("ERR"):
        stderr.writeLine(res)
        quit(1)
      doAuditLog(cfg, "operator", "decision.approve", decId & (if note.len > 0: ": " & note else: ""))
      echo "APPROVED decision '" & decId & "' by operator"

    of "reject":
      var decId = ""
      var reason = ""
      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--reason="): reason = a[9..^1]
        elif a == "--reason" and i + 1 < args.len: reason = args[i+1]; inc i
        elif not a.startsWith("-"):
          if decId.len == 0: decId = a
          elif reason.len == 0: reason = a
        inc i
      if decId.len == 0:
        stderr.writeLine("Error: Missing decision id. Usage: rhizo decision reject <id> [--reason <reason>]")
        quit(1)
      let res = doDecision(cfg, "reject", [decId, reason])
      if res.startsWith("ERR"):
        stderr.writeLine(res)
        quit(1)
      doAuditLog(cfg, "operator", "decision.reject", decId & (if reason.len > 0: ": " & reason else: ""))
      echo "REJECTED decision '" & decId & "' by operator"

    of "verify":
      if args.len < 3:
        stderr.writeLine("Usage: rhizo decision verify <id>")
        quit(1)
      let decId = args[2]
      let status = doDecision(cfg, "verify", [decId]).strip()
      echo status
      if status == "APPROVED":
        quit(0)
      else:
        quit(1)

    of "get":
      if args.len < 3:
        stderr.writeLine("Usage: rhizo decision get <id> [--json]")
        quit(1)
      let decId = args[2]
      var jsonOut = false
      for a in args[3..^1]:
        if a == "--json": jsonOut = true
      let res = doDecision(cfg, "get", [decId])
      if jsonOut:
        echo res
      else:
        try:
          let node = parseJson(res)
          if node.len == 0:
            echo "Decision '" & decId & "' not found."
          else:
            for k, v in node.pairs:
              echo k.alignLeft(16) & ": " & v.getStr($v)
        except CatchableError:
          echo res

    of "list":
      var jsonOut = false
      for a in args[2..^1]:
        if a == "--json": jsonOut = true
      let res = doDecision(cfg, "list", [])
      if jsonOut:
        echo res
      else:
        echo formatDecisionsTable(res)

    else:
      stderr.writeLine("Unknown decision action: '" & action & "'. Valid actions: propose, approve, reject, verify, get, list")
      quit(1)

  of "audit":
    if args.len < 2:
      stderr.writeLine("Usage: rhizo audit <log|list> [args...]")
      quit(1)
    let action = args[1].toLowerAscii
    case action
    of "log":
      var actionName = ""
      var details = ""
      var actor = ""
      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--action="): actionName = a[9..^1]
        elif a == "--action" and i + 1 < args.len: actionName = args[i+1]; inc i
        elif a.startsWith("--details="): details = a[10..^1]
        elif a == "--details" and i + 1 < args.len: details = args[i+1]; inc i
        elif a.startsWith("--actor="): actor = a[8..^1]
        elif a == "--actor" and i + 1 < args.len: actor = args[i+1]; inc i
        elif not a.startsWith("-"):
          if actionName.len == 0: actionName = a
          elif details.len == 0: details = a
        inc i
      if actionName.len == 0:
        stderr.writeLine("Error: Missing action name. Usage: rhizo audit log --action <name> --details <details> [--actor <actor>]")
        quit(1)
      if actor.len == 0:
        actor = getActiveAgentName(cfg, fallbackDefault = true)
      doAuditLog(cfg, actor, actionName, details)
      echo "AUDIT LOGGED: " & actionName

    of "list":
      var limit = 50
      var jsonOut = false
      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--limit="): limit = parseRequiredInt(a[8..^1], "--limit")
        elif a == "--limit" and i + 1 < args.len: limit = parseRequiredInt(args[i+1], "--limit"); inc i
        elif a == "--json": jsonOut = true
        inc i
      let res = doAuditList(cfg, limit)
      if jsonOut:
        echo res
      else:
        echo formatAuditTable(res)

    else:
      stderr.writeLine("Unknown audit action: '" & action & "'. Valid actions: log, list")
      quit(1)

  of "time":
    if args.len < 2:
      stderr.writeLine("Usage: rhizo time <advance|reset|get> [seconds]")
      quit(1)
    let action = args[1].toLowerAscii
    var client = connectRedis(cfg.redisUrl)
    defer:
      try: client.close() except CatchableError: discard
    case action
    of "advance":
      if args.len < 3:
        stderr.writeLine("Error: Missing seconds to advance. Usage: rhizo time advance <seconds>")
        quit(1)
      let sec = parseRequiredInt(args[2], "time advance seconds")
      let key = cfg.prefix & "mock_time_offset"
      let cur = try:
        let v = client.get(key)
        if v != redisNil and v.len > 0: parseInt(v) else: 0
      except CatchableError: 0
      let nextVal = cur + sec
      client.setk(key, $nextVal)
      echo $nextVal
    of "reset":
      discard client.del(@[cfg.prefix & "mock_time_offset"])
      echo "0"
    of "get":
      let cur = try:
        let v = client.get(cfg.prefix & "mock_time_offset")
        if v != redisNil and v.len > 0: v else: "0"
      except CatchableError: "0"
      echo cur
    else:
      stderr.writeLine("Unknown time action: " & action)
      quit(1)

  of "remind", "reminder":
    if args.len < 2:
      stderr.writeLine("Usage: rhizo remind <add|dismiss|ack|get|list|tick> [args...]")
      quit(1)
    let action = args[1].toLowerAscii
    case action
    of "add":
      var text = ""
      var priority = "NORMAL"
      var cadenceSec = 900
      var ttlSec = 0
      var scope = "*"
      var target = ""
      var author = ""
      var oncePerAgent = false
      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--priority="): priority = a[11..^1]
        elif a == "--priority" and i + 1 < args.len: priority = args[i+1]; inc i
        elif a.startsWith("--cadence="): cadenceSec = parseDurationSec(a[10..^1])
        elif a == "--cadence" and i + 1 < args.len: cadenceSec = parseDurationSec(args[i+1]); inc i
        elif a.startsWith("--ttl="): ttlSec = parseDurationSec(a[6..^1])
        elif a == "--ttl" and i + 1 < args.len: ttlSec = parseDurationSec(args[i+1]); inc i
        elif a.startsWith("--scope="): scope = a[8..^1]
        elif a == "--scope" and i + 1 < args.len: scope = args[i+1]; inc i
        elif a.startsWith("--target="): target = a[9..^1]
        elif a == "--target" and i + 1 < args.len: target = args[i+1]; inc i
        elif a.startsWith("--by="): author = a[5..^1]
        elif a == "--by" and i + 1 < args.len: author = args[i+1]; inc i
        elif a in ["--once", "--once-per-agent"]: oncePerAgent = true
        elif not a.startsWith("-"):
          if text.len == 0: text = a
          else: text.add(" " & a)
        inc i
      if text.len == 0:
        stderr.writeLine("Error: Missing reminder text. Usage: rhizo remind add <text> [--priority <prio>] [--cadence <sec>] [--ttl <sec>]")
        quit(1)
      if author.len == 0:
        author = getActiveAgentName(cfg, fallbackDefault = true)
      if author.len == 0:
        author = "operator"
      let res = doRemind(cfg, "add", [text, priority, author, scope, target, $cadenceSec, $ttlSec, if oncePerAgent: "true" else: "false"])
      echo res

    of "dismiss":
      if args.len < 3:
        stderr.writeLine("Error: Missing reminder id. Usage: rhizo remind dismiss <id>")
        quit(1)
      let remId = args[2]
      let res = doRemind(cfg, "dismiss", [remId])
      echo res

    of "ack":
      if args.len < 3:
        stderr.writeLine("Error: Missing reminder id. Usage: rhizo remind ack <id> [--agent <name>]")
        quit(1)
      let remId = args[2]
      var agentName = ""
      var i = 3
      while i < args.len:
        let a = args[i]
        if a.startsWith("--agent="): agentName = a[8..^1]
        elif a == "--agent" and i + 1 < args.len: agentName = args[i+1]; inc i
        inc i
      if agentName.len == 0:
        agentName = getActiveAgentName(cfg, fallbackDefault = true)
      if agentName.len == 0:
        agentName = "operator"
      let res = doRemind(cfg, "ack", [remId, agentName])
      echo res

    of "get":
      if args.len < 3:
        stderr.writeLine("Error: Missing reminder id. Usage: rhizo remind get <id> [--json]")
        quit(1)
      let remId = args[2]
      var jsonOut = false
      for a in args[3..^1]:
        if a == "--json": jsonOut = true
      let res = doRemind(cfg, "get", [remId])
      if jsonOut:
        echo res
      else:
        try:
          let node = parseJson(res)
          if node.len == 0 or node.getOrDefault("status").getStr("") == "ERROR":
            echo "Reminder '" & remId & "' not found."
          else:
            for k, v in node.pairs:
              echo k.alignLeft(16) & ": " & (if v.kind == JString: v.getStr() else: $v)
        except CatchableError:
          echo res

    of "list":
      var forAgent = ""
      var scopeFilter = ""
      var jsonOut = false
      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--for="): forAgent = a[6..^1]
        elif a == "--for" and i + 1 < args.len: forAgent = args[i+1]; inc i
        elif a.startsWith("--scope="): scopeFilter = a[8..^1]
        elif a == "--scope" and i + 1 < args.len: scopeFilter = args[i+1]; inc i
        elif a == "--json": jsonOut = true
        inc i
      let res = doRemind(cfg, "list", [forAgent, scopeFilter])
      if jsonOut:
        echo res
      else:
        echo formatRemindersTable(res)

    of "tick":
      var jsonOut = false
      for a in args[2..^1]:
        if a == "--json": jsonOut = true
      let res = doRemindTickFallback(cfg)
      if jsonOut:
        echo res
      else:
        try:
          let node = parseJson(res)
          let dispatched = node.getOrDefault("dispatched").getInt(0)
          echo "Dispatched " & $dispatched & " fallback standalone reminder(s)."
        except CatchableError:
          echo res

    else:
      stderr.writeLine("Unknown remind action: '" & action & "'. Valid actions: add, dismiss, ack, get, list, tick")
      quit(1)

  of "history", "log":
    var targetAgent = ""
    var limit = 50
    var jsonOut = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if a in ["--json", "-j"]:
        jsonOut = true
      elif a.startsWith("--limit="):
        limit = parseRequiredInt(a[8..^1], "--limit")
      elif a == "--limit" and i + 1 < args.len:
        limit = parseRequiredInt(args[i+1], "--limit")
        inc i
      elif not a.startsWith("-"):
        if targetAgent.len == 0: targetAgent = a
      inc i
    echo doHistory(cfg, targetAgent, limit, jsonOut)

  of "probe":
    var targetAgent = ""
    var jsonOut = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if a in ["--json", "-j"]:
        jsonOut = true
      elif not a.startsWith("-"):
        if targetAgent.len == 0: targetAgent = a
      inc i
    if targetAgent.len == 0:
      stderr.writeLine("Usage: rhizo probe <agent> [--json]")
      quit(1)
    echo doProbe(cfg, targetAgent, jsonOut)

  of "watchdog":
    var subaction = "check"
    var targetAgent = ""
    var jsonOut = false
    var expectListening = false
    var streakOverride = -1
    var i = 1
    while i < args.len:
      let a = args[i]
      if a in ["check", "status", "reset"]:
        subaction = a
      elif a in ["--json", "-j"]:
        jsonOut = true
      elif a in ["--expect-listening", "-e"]:
        expectListening = true
      elif a.startsWith("--streak="):
        try: streakOverride = parseInt(a[9..^1]) except CatchableError: discard
      elif a in ["--streak", "-s"] and i + 1 < args.len:
        try: streakOverride = parseInt(args[i+1]) except CatchableError: discard
        inc i
      elif a.startsWith("--agent="):
        targetAgent = a[8..^1]
      elif a in ["--agent", "-a"] and i + 1 < args.len:
        targetAgent = args[i+1]
        inc i
      elif not a.startsWith("-"):
        if a in ["check", "status", "reset"]:
          subaction = a
        elif targetAgent.len == 0:
          targetAgent = a
      inc i
    if subaction == "reset":
      let (resOutput, resExitCode) = doWatchdogReset(cfg, targetAgent, jsonOut)
      echo resOutput
      if resExitCode != 0:
        quit(resExitCode)
    else:
      let (resOutput, resExitCode) = doWatchdogCheck(cfg, targetAgent, jsonOut, expectListening, streakOverride)
      echo resOutput
      if resExitCode != 0:
        quit(resExitCode)

  of "alias":
    if args.len < 2:
      stderr.writeLine("Usage: rhizo alias <set|get|list|del> [args...]")
      quit(1)
    let action = args[1].toLowerAscii
    case action
    of "set":
      if args.len < 4:
        stderr.writeLine("Usage: rhizo alias set <alias> <canonical_name>")
        quit(1)
      echo doAliasSet(cfg, args[2], args[3])
    of "get":
      if args.len < 3:
        stderr.writeLine("Usage: rhizo alias get <alias>")
        quit(1)
      let canon = doAliasGet(cfg, args[2])
      if canon.len == 0:
        stderr.writeLine("Alias '" & args[2] & "' not found.")
        quit(1)
      echo canon
    of "del", "delete", "rm":
      if args.len < 3:
        stderr.writeLine("Usage: rhizo alias del <alias>")
        quit(1)
      if doAliasDel(cfg, args[2]):
        echo "Deleted alias '" & args[2] & "'"
      else:
        stderr.writeLine("Alias '" & args[2] & "' not found.")
        quit(1)
    of "list", "ls":
      var jsonOut = false
      for a in args[2..^1]:
        if a in ["--json", "-j"]: jsonOut = true
      echo doAliasList(cfg, jsonOut)
    else:
      stderr.writeLine("Unknown alias action: '" & action & "'. Valid actions: set, get, del, list")
      quit(1)

  of "reroute":
    var positional: seq[string] = @[]
    var mode = "all"
    var jsonOut = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if a in ["--json", "-j"]:
        jsonOut = true
      elif a in ["--all", "--unread"]:
        mode = a[2..^1]
      elif a.startsWith("-"):
        discard
      else:
        positional.add(a)
      inc i
    if positional.len < 2:
      stderr.writeLine("Usage: rhizo reroute <from_agent> <to_agent> [--all|--unread] [--json]")
      quit(1)
    let fromAgent = positional[0]
    let toAgent = positional[1]
    echo doReroute(cfg, fromAgent, toAgent, mode, jsonOut)

  of "hook":
    if args.len < 2:
      stderr.writeLine("Usage: rhizo hook <codex-stop|install> [options]")
      quit(1)
    let action = args[1].toLowerAscii
    case action
    of "codex-stop", "stop":
      var targetAgent = ""
      var expectWorker = false
      var i = 2
      while i < args.len:
        let a = args[i]
        if a.startsWith("--agent="):
          targetAgent = a[8..^1]
        elif a in ["--agent", "-a"] and i + 1 < args.len:
          targetAgent = args[i+1]
          inc i
        elif a in ["--expect-worker", "-w"]:
          expectWorker = true
        elif not a.startsWith("-") and targetAgent.len == 0:
          targetAgent = a
        inc i
      let res = doHookCodexStop(cfg, targetAgent, expectWorker)
      echo res
    of "install":
      var harness = "codex"
      var targetAgent = ""
      var isGlobal = false
      var i = 2
      while i < args.len:
        let a = args[i]
        if a in ["--codex"]:
          harness = "codex"
        elif a in ["--claude"]:
          harness = "claude"
        elif a in ["--global", "-g"]:
          isGlobal = true
        elif a.startsWith("--agent="):
          targetAgent = a[8..^1]
        elif a in ["--agent", "-a"] and i + 1 < args.len:
          targetAgent = args[i+1]
          inc i
        elif not a.startsWith("-") and targetAgent.len == 0:
          targetAgent = a
        inc i
      let res = doHookInstall(cfg, harness, targetAgent, isGlobal)
      echo res
    else:
      stderr.writeLine("Error: Unknown hook action: '" & action & "'. Valid actions: codex-stop, install")
      quit(1)

  of "title":
    var agentName = ""
    var i = 1
    while i < args.len:
      let a = args[i]
      if not a.startsWith("-") and agentName.len == 0:
        agentName = a
      inc i
    if agentName.len == 0:
      agentName = getActiveAgentName(cfg, fallbackDefault = true)
    if agentName.len == 0:
      agentName = "rhizo"
    let scopedName = ensureProjectScopedName(cfg, agentName)
    setTerminalTitle(scopedName, force = true)
    echo "Terminal title set to: " & scopedName

  of "poke", "nudge", "wake":
    var targetAgent = ""
    var optCmd = ""
    var force = false
    var dryRun = false
    var jsonOut = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if a in ["--force", "-f"]:
        force = true
      elif a in ["--dry-run", "-n"]:
        dryRun = true
      elif a in ["--json", "-j"]:
        jsonOut = true
      elif a.startsWith("--cmd="):
        optCmd = a[6..^1]
      elif a in ["--cmd", "--command"] and i + 1 < args.len:
        optCmd = args[i+1]
        inc i
      elif not a.startsWith("-") and targetAgent.len == 0:
        targetAgent = a
      inc i
    if targetAgent.len == 0:
      stderr.writeLine("Usage: rhizo poke <agent> [--cmd <command>] [--force/-f] [--dry-run/-n] [--json]")
      quit(1)
    echo doPoke(cfg, targetAgent, optCmd, force, dryRun, jsonOut)

  else:
    var suggestion = ""
    let lowCmd = subcmd.toLowerAscii
    if lowCmd in ["names", "agents", "list", "ls", "roster", "whoami"]:
      suggestion = "who"
    elif lowCmd in ["msg", "tell", "push", "post"]:
      suggestion = "send"
    elif lowCmd in ["hear", "read", "tail", "follow"]:
      suggestion = "listen"
    elif lowCmd in ["tasks", "todo"]:
      suggestion = "task"
    elif lowCmd in ["decisions", "vote", "ruling", "judge"]:
      suggestion = "decision"
    elif lowCmd in ["audit_trail", "logs", "trail"]:
      suggestion = "audit"
    elif lowCmd in ["pop", "consume"]:
      suggestion = "drain"
    elif lowCmd in ["clean", "gc", "purge"]:
      suggestion = "sweep"
    elif lowCmd in ["reminders", "sticky", "banner", "advisory", "notice", "alert", "warn"]:
      suggestion = "remind"
    elif lowCmd in ["aliases", "redirect"]:
      suggestion = "alias"
    elif lowCmd in ["forward", "move-inbox", "transfer"]:
      suggestion = "reroute"
    elif lowCmd in ["poke", "wake", "nudge", "bell", "doorbell"]:
      suggestion = "poke"

    if suggestion.len > 0:
      stderr.writeLine("Error: Unknown subcommand '" & subcmd & "'. Did you mean 'rhizo " & suggestion & "'?")
    else:
      stderr.writeLine("Error: Unknown subcommand: " & subcmd)
    quit(1)

when isMainModule:
  main()
