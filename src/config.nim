# src/config.nim
# Tiered configuration engine for Rhizo.
# Handles cascading resolution across CLI flags, env vars, workspace TOML,
# user config, system config, defaults, and named profiles.

import std/[os, strutils, tables, json, options, uri, sets]

# Universal Redis / Valkey URL parser
proc parseRedisUrl*(rawUrl: string): tuple[host: string, port: int, password: string, db: int, tls: bool] =
  result.host = "127.0.0.1"
  result.port = 6379
  result.password = ""
  result.db = 0
  result.tls = false

  if rawUrl.len == 0:
    return

  var s = rawUrl.strip()
  if s.startsWith("rediss://"):
    result.tls = true
    s = "http://" & s[9..^1]
  elif s.startsWith("valkeys://"):
    result.tls = true
    s = "http://" & s[10..^1]
  elif s.startsWith("redis://"):
    s = "http://" & s[8..^1]
  elif s.startsWith("valkey://"):
    s = "http://" & s[9..^1]
  elif "://" in s:
    let scheme = s.split("://", 1)[0]
    raise newException(ValueError, "Invalid Redis/Valkey URL scheme '" & scheme & "'. Must be redis://, rediss://, valkey://, or valkeys://")
  else:
    s = "http://" & s

  let u = parseUri(s)
  if u.hostname.len > 0:
    result.host = u.hostname
  if u.port.len > 0:
    try:
      result.port = parseInt(u.port)
    except ValueError:
      raise newException(ValueError, "Invalid port in Redis/Valkey URL: '" & u.port & "'")
  if u.password.len > 0:
    result.password = u.password
  if u.path.len > 1:
    try:
      result.db = parseInt(u.path[1..^1])
    except ValueError:
      raise newException(ValueError, "Invalid database index in Redis/Valkey URL: '" & u.path[1..^1] & "'")

type
  SettingSource* = enum
    srcDefault,
    srcSystemFile,
    srcUserFile,
    srcWorkspaceFile,
    srcWorkspaceLocalFile,
    srcCustomFile,
    srcEnv,
    srcCli

  ProvenanceEntry* = object
    key*: string
    value*: string
    source*: SettingSource
    detail*: string

  RhizoConfig* = object
    redisUrl*: string
    prefix*: string
    project*: string
    agentName*: string
    sessionId*: string
    secret*: string
    secretFile*: string
    encrypt*: bool
    cluster*: bool
    heartbeatTtl*: int
    messageTtl*: int
    listenTimeout*: int
    profile*: string
    activeConfigFile*: string
    provenance*: Table[string, ProvenanceEntry]
    forceSteal*: bool
    allowDrift*: bool
    allProjects*: bool
    globalLock*: bool
    crossProject*: string

proc sourceLabel*(s: SettingSource): string =
  case s
  of srcDefault: "default"
  of srcSystemFile: "system config"
  of srcUserFile: "user config"
  of srcWorkspaceFile: "workspace config"
  of srcWorkspaceLocalFile: "local workspace config"
  of srcCustomFile: "custom file"
  of srcEnv: "environment"
  of srcCli: "cli flag"

# Strip surrounding single or double quotes and unescape
proc unquote*(s: string): string =
  let t = s.strip()
  if (t.startsWith("\"") and t.endsWith("\"")) or (t.startsWith("'") and t.endsWith("'")):
    if t.len >= 2:
      let inner = t[1 .. ^2]
      if t.startsWith("'"):
        return inner
      # Double-quoted string: parse escape sequences character-by-character
      var res = ""
      var i = 0
      while i < inner.len:
        if inner[i] == '\\' and i + 1 < inner.len:
          case inner[i+1]
          of 'n': res.add('\n'); i += 2
          of 'r': res.add('\r'); i += 2
          of 't': res.add('\t'); i += 2
          of '"': res.add('"'); i += 2
          of '\\': res.add('\\'); i += 2
          else:
            res.add(inner[i+1])
            i += 2
        else:
          res.add(inner[i])
          inc i
      return res
  return t

# Expand tilde in path
proc expandPathSafe*(p: string): string =
  if p.startsWith("~" & $DirSep) or p.startsWith("~/") or p == "~":
    let home = getHomeDir()
    let rest = p[1..^1].strip(chars = {'/', '\\', DirSep})
    if rest.len == 0:
      return normalizedPath(home)
    return normalizedPath(home / rest)
  return p

# Standard configuration paths
proc getSystemConfigPath*(): string =
  when defined(windows):
    return getEnv("ProgramData", r"C:\ProgramData") / "rhizo" / "config.toml"
  elif defined(macosx):
    return "/Library/Application Support/rhizo/config.toml"
  else:
    return "/etc/rhizo/config.toml"

proc getUserConfigPath*(): string =
  when defined(windows):
    return getEnv("APPDATA", getHomeDir() / "AppData" / "Roaming") / "rhizo" / "config.toml"
  elif defined(macosx):
    let rApp = getHomeDir() / "Library" / "Application Support" / "rhizo" / "config.toml"
    if fileExists(rApp): return rApp
    return getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config") / "rhizo" / "config.toml"
  else:
    return getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config") / "rhizo" / "config.toml"

# Find the workspace or project directory containing configs or git root
proc findWorkspaceDir*(startDir: string = getCurrentDir()): string =
  var cur = startDir
  while true:
    for candidate in [".rhizo.local.toml", "rhizo.local.toml", ".rhizo.toml", "rhizo.toml",
                      ".rhizo.local.json", "rhizo.local.json", ".rhizo.json",
                      ".env.local", ".env", "rhizo-routes.yaml", "rhizo-routes.local.yaml",
                      "AGENTS.md"]:
      let p = cur / candidate
      if fileExists(p):
        return cur
    if dirExists(cur / ".git") or fileExists(cur / ".git"):
      return cur
    let parent = cur.parentDir()
    if parent == cur or parent.len == 0:
      break
    cur = parent
  return startDir

proc findGitOrWorkspaceRoot*(startDir: string = getCurrentDir()): string =
  var cur = startDir
  while true:
    if dirExists(cur / ".git") or fileExists(cur / ".git"):
      return cur
    for candidate in [".rhizo.local.toml", "rhizo.local.toml", ".rhizo.toml", "rhizo.toml",
                      "garden.toml", "vine.toml", "AGENTS.md"]:
      let p = cur / candidate
      if fileExists(p):
        return cur
    let parent = cur.parentDir()
    if parent == cur or parent.len == 0:
      break
    cur = parent
  return ""

# Walk up from current directory to find workspace configuration or git root
proc findWorkspaceConfigPath*(startDir: string = getCurrentDir()): string =
  var cur = startDir
  while true:
    for candidate in [".rhizo.toml", "rhizo.toml",
                      ".rhizo.json", ".rhizo.local.toml", "rhizo.local.toml",
                      ".rhizo.local.json", "rhizo.local.json",
                      ".env", "AGENTS.md"]:
      let p = cur / candidate
      if fileExists(p):
        return p
    # Check if .git directory exists here; stop walking up past git root
    if dirExists(cur / ".git") or fileExists(cur / ".git"):
      break
    let parent = cur.parentDir()
    if parent == cur or parent.len == 0:
      break
    cur = parent
  return ""

# Find uncommitted local workspace configuration file if present
proc findWorkspaceLocalConfigPath*(wsConfigPath: string = "", startDir: string = getCurrentDir()): string =
  let dir = if wsConfigPath.len > 0: wsConfigPath.splitPath.head else: findWorkspaceDir(startDir)
  for candidate in [".rhizo.local.toml", "rhizo.local.toml",
                    ".rhizo.local.json", "rhizo.local.json"]:
    let p = dir / candidate
    if fileExists(p):
      return p
  return ""

# Lightweight TOML parser supporting sections, key-value strings, ints, bools
type TomlTable = Table[string, Table[string, string]]

proc parseSimpleToml*(content: string): TomlTable =
  result = initTable[string, Table[string, string]]()
  result[""] = initTable[string, string]()
  var curSection = ""

  for rawLine in content.splitLines():
    var line = rawLine.strip()
    if line.len == 0 or line.startsWith("#") or line.startsWith(";"):
      continue

    # Remove inline comments if not inside quotes
    var inQuotes = false
    var cleanLine = ""
    for c in line:
      if c == '"' or c == '\'': inQuotes = not inQuotes
      elif c == '#' and not inQuotes: break
      cleanLine.add(c)
    cleanLine = cleanLine.strip()
    if cleanLine.len == 0: continue

    # Section header: [section] or [profiles.name]
    if cleanLine.startsWith("[") and cleanLine.endsWith("]"):
      curSection = cleanLine[1 .. ^2].strip().toLowerAscii
      if not result.hasKey(curSection):
        result[curSection] = initTable[string, string]()
      continue

    # Key = Value
    let eqIdx = cleanLine.find('=')
    if eqIdx > 0:
      let key = cleanLine[0 ..< eqIdx].strip().toLowerAscii
      let val = cleanLine[eqIdx + 1 .. ^1].strip().unquote()
      if not result.hasKey(curSection):
        result[curSection] = initTable[string, string]()
      result[curSection][key] = val

proc parseSimpleEnv*(content: string): Table[string, string] =
  result = initTable[string, string]()
  for rawLine in content.splitLines():
    var s = rawLine.strip()
    if s.len == 0 or s.startsWith("#") or s.startsWith(";"): continue
    if s.startsWith("export "):
      s = s[7..^1].strip()
    let eqIdx = s.find('=')
    if eqIdx > 0:
      let k = s[0 ..< eqIdx].strip()
      var v = s[eqIdx + 1 .. ^1].strip()
      if (v.startsWith("\"") and v.endsWith("\"")) or (v.startsWith("'") and v.endsWith("'")):
        v = unquote(v)
      else:
        let hashIdx = v.find('#')
        if hashIdx >= 0:
          v = v[0 ..< hashIdx].strip()
        v = unquote(v)
      result[k] = v

var gInitialEnvKeys: HashSet[string] = initHashSet[string]()
var gDotEnvLoaded* = false

proc initInitialEnvKeys*() =
  if gInitialEnvKeys.len == 0:
    for pair in envPairs():
      gInitialEnvKeys.incl(pair.key)

proc loadDotEnvFile*(path: string) =
  if not fileExists(path): return
  initInitialEnvKeys()
  try:
    let content = readFile(path)
    let dict = parseSimpleEnv(content)
    for k, v in dict:
      if k notin gInitialEnvKeys:
        putEnv(k, v)
  except CatchableError:
    discard

proc loadDotEnv*(startDir: string = getCurrentDir()) =
  let wsDir = findWorkspaceDir(startDir)
  # Precedence cascade: .env -> .rhizo.env -> .env.local -> .rhizo.env.local
  # Later files override earlier files for variables not locked by initial system environment.
  for cand in [".env", ".rhizo.env", ".env.local", ".rhizo.env.local"]:
    let p = wsDir / cand
    if fileExists(p):
      loadDotEnvFile(p)
  gDotEnvLoaded = true

proc parseAgentsMd*(content: string): Table[string, string] =
  result = initTable[string, string]()
  for line in content.splitLines():
    let low = line.toLowerAscii.strip()
    for prefix in ["rhizo_redis_url", "rhizo_redis_prefix", "rhizo_project", "rhizo_agent_name"]:
      if low.startsWith(prefix & ":") or low.startsWith(prefix & "="):
        let parts = line.split({':', '='}, maxsplit = 1)
        if parts.len >= 2:
          result[prefix] = parts[1].strip().unquote()

# Populate config from a dictionary with provenance
proc applyDict(
  cfg: var RhizoConfig,
  dict: Table[string, string],
  source: SettingSource,
  detail: string
) =
  for k, v in dict:
    let lowKey = k.toLowerAscii.replace("-", "_")
    case lowKey
    of "redis_url", "redisurl", "rhizo_redis_url", "valkey_url", "valkeyurl":
      if v.len > 0:
        cfg.redisUrl = v
        cfg.provenance["redis_url"] = ProvenanceEntry(key: "redis_url", value: v, source: source, detail: detail)
    of "prefix", "redis_prefix", "rhizo_redis_prefix":
      if v.len > 0:
        cfg.prefix = v
        cfg.provenance["prefix"] = ProvenanceEntry(key: "prefix", value: v, source: source, detail: detail)
    of "project", "rhizo_project":
      if v.len > 0:
        cfg.project = v
        cfg.provenance["project"] = ProvenanceEntry(key: "project", value: v, source: source, detail: detail)
    of "agent_name", "agentname", "rhizo_agent_name":
      if v.len > 0:
        cfg.agentName = v
        cfg.provenance["agent_name"] = ProvenanceEntry(key: "agent_name", value: v, source: source, detail: detail)
    of "session_id", "sessionid", "rhizo_session_id":
      if v.len > 0:
        cfg.sessionId = v
        cfg.provenance["session_id"] = ProvenanceEntry(key: "session_id", value: v, source: source, detail: detail)
    of "secret", "rhizo_secret":
      if v.len > 0:
        cfg.secret = v
        cfg.provenance["secret"] = ProvenanceEntry(key: "secret", value: "[REDACTED]", source: source, detail: detail)
    of "secret_file", "secretfile", "rhizo_secret_file":
      if v.len > 0:
        cfg.secretFile = expandPathSafe(v)
        cfg.provenance["secret_file"] = ProvenanceEntry(key: "secret_file", value: cfg.secretFile, source: source, detail: detail)
    of "encrypt", "rhizo_encrypt":
      let b = v.toLowerAscii in ["1", "true", "yes", "on"]
      cfg.encrypt = b
      cfg.provenance["encrypt"] = ProvenanceEntry(key: "encrypt", value: $b, source: source, detail: detail)
    of "cluster", "rhizo_cluster", "rhizo_redis_cluster":
      let b = v.toLowerAscii in ["1", "true", "yes", "on"]
      cfg.cluster = b
      cfg.provenance["cluster"] = ProvenanceEntry(key: "cluster", value: $b, source: source, detail: detail)
    of "heartbeat_ttl", "heartbeat":
      try:
        let n = parseInt(v)
        cfg.heartbeatTtl = n
        cfg.provenance["heartbeat_ttl"] = ProvenanceEntry(key: "heartbeat_ttl", value: $n, source: source, detail: detail)
      except ValueError: discard
    of "message_ttl", "ttl":
      try:
        let n = parseInt(v)
        cfg.messageTtl = n
        cfg.provenance["message_ttl"] = ProvenanceEntry(key: "message_ttl", value: $n, source: source, detail: detail)
      except ValueError: discard
    of "listen_timeout", "timeout":
      try:
        let n = parseInt(v)
        cfg.listenTimeout = n
        cfg.provenance["listen_timeout"] = ProvenanceEntry(key: "listen_timeout", value: $n, source: source, detail: detail)
      except ValueError: discard
    else:
      discard

# Load file into config with profile support
proc loadConfigFile(
  cfg: var RhizoConfig,
  path: string,
  source: SettingSource,
  targetProfile: string = ""
) =
  if not fileExists(path): return
  cfg.activeConfigFile = path

  let ext = path.splitFile.ext.toLowerAscii
  if ext in [".toml"]:
    let toml = parseSimpleToml(readFile(path))
    # Apply root section
    if toml.hasKey(""):
      applyDict(cfg, toml[""], source, path)
    # Apply [default] section if present
    if toml.hasKey("default"):
      applyDict(cfg, toml["default"], source, path & " [default]")
    # Apply [project] section if present
    if toml.hasKey("project"):
      applyDict(cfg, toml["project"], source, path & " [project]")
    # Apply requested profile if specified
    if targetProfile.len > 0:
      let profKey1 = "profiles." & targetProfile.toLowerAscii
      let profKey2 = targetProfile.toLowerAscii
      if toml.hasKey(profKey1):
        applyDict(cfg, toml[profKey1], source, path & " [" & profKey1 & "]")
      elif toml.hasKey(profKey2):
        applyDict(cfg, toml[profKey2], source, path & " [" & profKey2 & "]")
  elif ext in [".json"]:
    try:
      let j = parseJson(readFile(path))
      var dict = initTable[string, string]()
      for k, v in j.pairs:
        if v.kind == JString: dict[k] = v.getStr()
        elif v.kind in [JInt, JBool]: dict[k] = $v
      applyDict(cfg, dict, source, path)

      if targetProfile.len > 0 and j.hasKey("profiles") and j["profiles"].hasKey(targetProfile):
        var profDict = initTable[string, string]()
        for k, v in j["profiles"][targetProfile].pairs:
          if v.kind == JString: profDict[k] = v.getStr()
          elif v.kind in [JInt, JBool]: profDict[k] = $v
        applyDict(cfg, profDict, source, path & " [profiles." & targetProfile & "]")
    except CatchableError:
      discard
  elif path.endsWith(".env"):
    let envDict = parseSimpleEnv(readFile(path))
    applyDict(cfg, envDict, source, path)
  elif path.endsWith("AGENTS.md"):
    let agentsDict = parseAgentsMd(readFile(path))
    applyDict(cfg, agentsDict, source, path)

# The Full Cascading Resolution Protocol
type CliOverrides* = object
  redisUrl*: string
  prefix*: string
  project*: string
  agentName*: string
  sessionId*: string
  secret*: string
  secretFile*: string
  encrypt*: Option[bool]
  cluster*: Option[bool]
  timeout*: Option[int]
  profile*: string
  configFile*: string
  forceSteal*: bool
  allowDrift*: bool
  allProjects*: bool
  globalLock*: bool
  crossProject*: string

proc getEnvFirst*(keys: varargs[string]): string =
  for k in keys:
    let val = getEnv(k, "")
    if val.len > 0:
      return val
  return ""

proc detectCurrentSessionId*(): string =
  let opencode = getEnv("OPENCODE_SESSION_ID", "")
  if opencode.len > 0: return "opencode:" & opencode
  let codex = getEnv("CODEX_SESSION_ID", "")
  if codex.len > 0: return "codex:" & codex
  let pi = getEnv("PI_SESSION_ID", "")
  if pi.len > 0: return "pi:" & pi
  let claude = getEnvFirst("CLAUDE_CONVERSATION_ID", "CLAUDE_SESSION_ID")
  if claude.len > 0: return "claude:" & claude
  let agy = getEnv("ANTIGRAVITY_CONVERSATION_ID", "")
  if agy.len > 0: return "agy:" & agy
  let custom = getEnv("RHIZO_SESSION_ID", "")
  if custom.len > 0: return custom
  return ""

proc resolveFullConfig*(cli: CliOverrides = CliOverrides()): RhizoConfig =
  # Step 0: Pre-load .env and .env.local into process environment
  loadDotEnv()

  # Step 1: Initialize with default values (workspace-aware project detection)
  let repoRoot = findGitOrWorkspaceRoot(getCurrentDir())
  let defProject = if repoRoot.len > 0 and repoRoot.splitPath.tail notin ["", "/", "Development"]:
                     repoRoot.splitPath.tail
                   else:
                     getCurrentDir().splitPath.tail

  # Operational Invariant: PWD vs Environment Variable Drift Guard
  # Enforced whenever execution occurs inside an active git repository / workspace
  let envProject = getEnvFirst("RHIZO_PROJECT", "A2A_PROJECT")
  let allowDrift = cli.allowDrift or (getEnv("RHIZO_ALLOW_DRIFT", "") in ["1", "true", "yes"])
  if not allowDrift and repoRoot.len > 0:
    let repoName = repoRoot.splitPath.tail
    if repoName.len > 0 and repoName notin ["default", "Development", ""]:
      if envProject.len > 0 and envProject.toLowerAscii != repoName.toLowerAscii:
        stderr.writeLine("Error: Environment variable RHIZO_PROJECT='" & envProject & "' does not match active repository project '" & repoName & "' (at " & repoRoot & ").")
        stderr.writeLine("Aborting to prevent cross-project state corruption. Unset RHIZO_PROJECT, use --project, or pass --allow-drift.")
        quit(1)
  result = RhizoConfig(
    redisUrl: "redis://127.0.0.1:6379",
    prefix: "rhizo:",
    project: defProject,
    agentName: "",
    sessionId: "",
    secret: "",
    secretFile: "",
    encrypt: false,
    cluster: false,
    heartbeatTtl: 150,
    messageTtl: 604800,
    listenTimeout: 0,
    profile: "default",
    provenance: initTable[string, ProvenanceEntry]()
  )

  # Record initial defaults in provenance
  result.provenance["redis_url"] = ProvenanceEntry(key: "redis_url", value: result.redisUrl, source: srcDefault, detail: "builtin default")
  result.provenance["prefix"] = ProvenanceEntry(key: "prefix", value: result.prefix, source: srcDefault, detail: "builtin default")
  result.provenance["project"] = ProvenanceEntry(key: "project", value: result.project, source: srcDefault, detail: "current directory basename")
  result.provenance["agent_name"] = ProvenanceEntry(key: "agent_name", value: "", source: srcDefault, detail: "none")
  result.provenance["session_id"] = ProvenanceEntry(key: "session_id", value: "", source: srcDefault, detail: "builtin default")
  result.provenance["encrypt"] = ProvenanceEntry(key: "encrypt", value: "false", source: srcDefault, detail: "builtin default")
  result.provenance["cluster"] = ProvenanceEntry(key: "cluster", value: "false", source: srcDefault, detail: "builtin default")
  result.provenance["heartbeat_ttl"] = ProvenanceEntry(key: "heartbeat_ttl", value: $result.heartbeatTtl, source: srcDefault, detail: "150s default")
  result.provenance["message_ttl"] = ProvenanceEntry(key: "message_ttl", value: $result.messageTtl, source: srcDefault, detail: "7 days default")
  result.provenance["listen_timeout"] = ProvenanceEntry(key: "listen_timeout", value: $result.listenTimeout, source: srcDefault, detail: "0s (infinite blocking default)")

  # Resolve profile selector
  var targetProfile = cli.profile
  if targetProfile.len == 0:
    targetProfile = getEnv("RHIZO_PROFILE", "")
  if targetProfile.len > 0:
    result.profile = targetProfile

  # Step 2: Global / System Configuration
  let sysPath = getSystemConfigPath()
  if fileExists(sysPath):
    loadConfigFile(result, sysPath, srcSystemFile, targetProfile)

  # Step 3: Per-User Configuration
  let userPath = getUserConfigPath()
  if fileExists(userPath):
    loadConfigFile(result, userPath, srcUserFile, targetProfile)

  # Step 4: Workspace / Project Configuration
  let wsPath = findWorkspaceConfigPath()
  if wsPath.len > 0 and fileExists(wsPath):
    loadConfigFile(result, wsPath, srcWorkspaceFile, targetProfile)

  # Step 4b: Workspace Local Configuration Override (.rhizo.local.toml, etc.)
  let wsLocalPath = findWorkspaceLocalConfigPath(wsPath)
  if wsLocalPath.len > 0 and fileExists(wsLocalPath) and wsLocalPath != wsPath:
    loadConfigFile(result, wsLocalPath, srcWorkspaceLocalFile, targetProfile)

  # Step 5: Custom Config File Override (if provided via CLI or RHIZO_CONFIG)
  var customPath = cli.configFile
  if customPath.len == 0:
    customPath = getEnv("RHIZO_CONFIG")
  if customPath.len > 0:
    customPath = expandPathSafe(customPath)
    if fileExists(customPath):
      loadConfigFile(result, customPath, srcCustomFile, targetProfile)
    else:
      stderr.writeLine("Warning: Specified configuration file does not exist: " & customPath)

  # Step 6: Process Environment Variables
  let envRedisUrl = getEnvFirst("RHIZO_REDIS_URL", "RHIZO_VALKEY_URL", "A2A_REDIS_URL", "VALKEY_URL", "REDIS_URL")
  if envRedisUrl.len > 0:
    result.redisUrl = envRedisUrl
    result.provenance["redis_url"] = ProvenanceEntry(key: "redis_url", value: envRedisUrl, source: srcEnv, detail: "RHIZO_REDIS_URL / VALKEY_URL / REDIS_URL")

  let envPrefix = getEnvFirst("RHIZO_REDIS_PREFIX", "RHIZO_PREFIX", "A2A_REDIS_PREFIX")
  if envPrefix.len > 0:
    result.prefix = envPrefix
    result.provenance["prefix"] = ProvenanceEntry(key: "prefix", value: envPrefix, source: srcEnv, detail: "RHIZO_REDIS_PREFIX / RHIZO_PREFIX")

  if envProject.len > 0:
    result.project = envProject
    result.provenance["project"] = ProvenanceEntry(key: "project", value: envProject, source: srcEnv, detail: "RHIZO_PROJECT")

  let envAgent = getEnvFirst("RHIZO_AGENT_NAME", "MY_NAME")
  if envAgent.len > 0:
    result.agentName = envAgent
    result.provenance["agent_name"] = ProvenanceEntry(key: "agent_name", value: envAgent, source: srcEnv, detail: "RHIZO_AGENT_NAME")

  let envSessionId = getEnv("RHIZO_SESSION_ID")
  if envSessionId.len > 0:
    result.sessionId = envSessionId
    result.provenance["session_id"] = ProvenanceEntry(key: "session_id", value: envSessionId, source: srcEnv, detail: "RHIZO_SESSION_ID")

  let envSecret = getEnv("RHIZO_SECRET")
  if envSecret.len > 0:
    result.secret = envSecret
    result.provenance["secret"] = ProvenanceEntry(key: "secret", value: "[REDACTED]", source: srcEnv, detail: "RHIZO_SECRET")

  let envSecretFile = getEnv("RHIZO_SECRET_FILE")
  if envSecretFile.len > 0:
    result.secretFile = expandPathSafe(envSecretFile)
    result.provenance["secret_file"] = ProvenanceEntry(key: "secret_file", value: result.secretFile, source: srcEnv, detail: "RHIZO_SECRET_FILE")

  let envEnc = getEnv("RHIZO_ENCRYPT")
  if envEnc.len > 0:
    let b = envEnc in ["1", "true", "TRUE", "yes"]
    result.encrypt = b
    result.provenance["encrypt"] = ProvenanceEntry(key: "encrypt", value: $b, source: srcEnv, detail: "RHIZO_ENCRYPT=" & envEnc)

  let envCluster = getEnv("RHIZO_CLUSTER")
  if envCluster.len > 0:
    let b = envCluster in ["1", "true", "TRUE", "yes"]
    result.cluster = b
    result.provenance["cluster"] = ProvenanceEntry(key: "cluster", value: $b, source: srcEnv, detail: "RHIZO_CLUSTER=" & envCluster)

  # Step 7: Explicit CLI Arguments
  if cli.redisUrl.len > 0:
    result.redisUrl = cli.redisUrl
    result.provenance["redis_url"] = ProvenanceEntry(key: "redis_url", value: cli.redisUrl, source: srcCli, detail: "--redis-url")

  if cli.prefix.len > 0:
    result.prefix = cli.prefix
    result.provenance["prefix"] = ProvenanceEntry(key: "prefix", value: cli.prefix, source: srcCli, detail: "--prefix")

  if cli.project.len > 0:
    result.project = cli.project
    result.provenance["project"] = ProvenanceEntry(key: "project", value: cli.project, source: srcCli, detail: "--project")

  if cli.agentName.len > 0:
    result.agentName = cli.agentName
    result.provenance["agent_name"] = ProvenanceEntry(key: "agent_name", value: cli.agentName, source: srcCli, detail: "--agent-name")

  if cli.sessionId.len > 0:
    result.sessionId = cli.sessionId
    result.provenance["session_id"] = ProvenanceEntry(key: "session_id", value: cli.sessionId, source: srcCli, detail: "--session-id")

  if cli.secret.len > 0:
    result.secret = cli.secret
    result.provenance["secret"] = ProvenanceEntry(key: "secret", value: "[REDACTED]", source: srcCli, detail: "--secret")

  if cli.secretFile.len > 0:
    result.secretFile = expandPathSafe(cli.secretFile)
    result.provenance["secret_file"] = ProvenanceEntry(key: "secret_file", value: result.secretFile, source: srcCli, detail: "--secret-file")

  if cli.encrypt.isSome:
    let b = cli.encrypt.get()
    result.encrypt = b
    result.provenance["encrypt"] = ProvenanceEntry(key: "encrypt", value: $b, source: srcCli, detail: "--encrypt")

  if cli.cluster.isSome:
    let b = cli.cluster.get()
    result.cluster = b
    result.provenance["cluster"] = ProvenanceEntry(key: "cluster", value: $b, source: srcCli, detail: "--cluster")

  if cli.timeout.isSome:
    let t = cli.timeout.get()
    result.listenTimeout = t
    result.provenance["listen_timeout"] = ProvenanceEntry(key: "listen_timeout", value: $t, source: srcCli, detail: "--timeout")

  # Redis Cluster Hash Tag Enforcement
  if result.cluster and not (result.prefix.contains('{') and result.prefix.contains('}')):
    let base = if result.prefix.endsWith(":"): result.prefix[0 .. ^2] else: result.prefix
    result.prefix = "{" & base & ":" & result.project & "}:"
    result.provenance["prefix"] = ProvenanceEntry(key: "prefix", value: result.prefix, source: srcDefault, detail: "Cluster hash tag auto-applied")

  # Auto-detect Session ID if unpopulated
  if result.sessionId.len == 0:
    let autoSid = detectCurrentSessionId()
    if autoSid.len > 0:
      result.sessionId = autoSid
      result.provenance["session_id"] = ProvenanceEntry(key: "session_id", value: autoSid, source: srcEnv, detail: "auto-detected harness session")

  result.forceSteal = cli.forceSteal or (getEnv("RHIZO_FORCE_STEAL", "") in ["1", "true", "yes"])
  result.allowDrift = allowDrift
  result.allProjects = cli.allProjects or (getEnv("RHIZO_ALL_PROJECTS", "") in ["1", "true", "yes"])
  result.globalLock = cli.globalLock or (getEnv("RHIZO_GLOBAL_LOCK", "") in ["1", "true", "yes"])
  result.crossProject = if cli.crossProject.len > 0: cli.crossProject else: getEnv("RHIZO_CROSS_PROJECT", "")

# Starter TOML template
const starterTomlContent* = """# Rhizo Configuration File (.rhizo.toml)
# Tiered inter-assistant communication bus over Redis

# Redis connection endpoint
redis_url = "redis://127.0.0.1:6379"

# Key namespace prefix
prefix = "rhizo:"

# Project isolation group
# project = "my-project"

# Cryptographic payload encryption (AES-256-CBC)
encrypt = false

# Redis Cluster support (automatically applies {prefix:project} hash tags)
cluster = false

# Heartbeat TTL in seconds for agent registration
heartbeat_ttl = 150

# Maximum message lifetime in seconds (default 7 days)
message_ttl = 604800

# Default listen timeout in seconds (0 = block indefinitely until message arrives)
listen_timeout = 0

# Optional path to shared secret file (kept out of version control)
# secret_file = "~/.config/rhizo/secret"

# [profiles.staging]
# redis_url = "rediss://staging.internal:6380"
# prefix = "stg:rhizo:"
# encrypt = true

# [profiles.prod]
# redis_url = "rediss://cluster.internal:6379"
# cluster = true
# encrypt = true
"""

proc formatConfigTable*(cfg: RhizoConfig): string =
  var lines: seq[string] = @[]
  lines.add("SETTING              VALUE                         SOURCE             DETAIL")
  lines.add("------------------------------------------------------------------------------------------------------------------------")
  
  let orderedKeys = [
    "redis_url", "prefix", "project", "agent_name", "secret", "secret_file",
    "encrypt", "cluster", "heartbeat_ttl", "message_ttl", "listen_timeout"
  ]
  for k in orderedKeys:
    if cfg.provenance.hasKey(k):
      let entry = cfg.provenance[k]
      let valStr = if entry.value.len > 28: entry.value[0..24] & "..." else: entry.value
      lines.add(entry.key.alignLeft(21) & valStr.alignLeft(30) & sourceLabel(entry.source).alignLeft(19) & entry.detail)
  
  if cfg.activeConfigFile.len > 0:
    lines.add("active_config".alignLeft(21) & cfg.activeConfigFile.alignLeft(30) & "file".alignLeft(19) & "loaded")
  lines.add("active_profile".alignLeft(21) & cfg.profile.alignLeft(30) & "profile".alignLeft(19) & "-")
  return lines.join("\n")

proc formatConfigJson*(cfg: RhizoConfig): string =
  var root = newJObject()
  for k, v in cfg.provenance:
    var entryObj = newJObject()
    entryObj["value"] = %v.value
    entryObj["source"] = %sourceLabel(v.source)
    entryObj["detail"] = %v.detail
    root[k] = entryObj
  root["active_profile"] = %cfg.profile
  if cfg.activeConfigFile.len > 0:
    root["active_config"] = %cfg.activeConfigFile
  return pretty(root)

proc formatConfigPaths*(): string =
  var lines: seq[string] = @[]
  let sys = getSystemConfigPath()
  let sysStatus = if fileExists(sys): "[FOUND]" else: "[NOT FOUND]"
  lines.add("System config    : " & sys & " " & sysStatus)

  let usr = getUserConfigPath()
  let usrStatus = if fileExists(usr): "[FOUND]" else: "[NOT FOUND]"
  lines.add("User config      : " & usr & " " & usrStatus)

  let ws = findWorkspaceConfigPath()
  let wsStatus = if ws.len > 0 and fileExists(ws): "[FOUND: " & ws & "]" else: "[NOT FOUND in current tree]"
  lines.add("Workspace config : " & wsStatus)
  return lines.join("\n")

proc secureFilePermissions*(path: string) =
  when not defined(windows):
    try:
      setFilePermissions(path, {fpUserRead, fpUserWrite})
    except CatchableError:
      discard

proc initConfigFile*(target: string = "workspace", force: bool = false): string =
  let norm = target.toLowerAscii.strip(chars = {'-', ' '})
  let path = if norm in ["user", "global", "home", "u"]:
    getUserConfigPath()
  else:
    getCurrentDir() / ".rhizo.toml"

  if fileExists(path) and not force:
    return "Error: Config file already exists at " & path & " (use --force to overwrite)"
  
  createDir(path.splitPath.head)
  writeFile(path, starterTomlContent)
  secureFilePermissions(path)
  return "Initialized Rhizo configuration at: " & path
