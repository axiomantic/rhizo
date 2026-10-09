# src/routing.nim
# Declarative, Fail-Fast Laya System 1 Task Routing Engine for Rhizo.
# Handles rhizo-routes.yaml parsing, question-level chunk aggregation,
# fail-fast timeout/connectivity, and schema linting.

import std/[os, strutils, json, tables, httpclient, uri, net]
import yaml/tojson, config

type
  OverflowStrategy* = enum
    osSplitAggregate = "split_aggregate"
    osLeadTail = "lead_tail"
    osFailFast = "fail_fast"

  ChoiceAggregate* = enum
    caMaxConfidence = "max_confidence"
    caMeanProb = "mean_prob"
    caMajorityVote = "majority_vote"

  ScoreAggregate* = enum
    saMax = "max"
    saMean = "mean"
    saSum = "sum"
    saMin = "min"

  NoulAggregate* = enum
    naAny = "any"
    naAll = "all"
    naMean = "mean"

  RoutingLimits* = object
    overflowStrategy*: OverflowStrategy
    chunkSize*: int             # default 8000 chars
    chunkOverlap*: int          # default 800 chars
    splitDelimiter*: string     # default "\n"
    maxChunks*: int             # default 10
    defaultChoiceAgg*: ChoiceAggregate
    defaultScoreAgg*: ScoreAggregate
    defaultNoulAgg*: NoulAggregate

  RoutingServiceConfig* = object
    url*: string                # default "http://127.0.0.1:8100"
    timeoutSeconds*: float      # default 5.0
    model*: string              # optional model identifier (e.g. "kev-4b", "decider-4b")
    apiKey*: string             # optional API key for hosted endpoints (e.g. Laya / TypeSafe Jev)

  QuestionConfig* = object
    id*: string
    qType*: string              # "choice", "score", "noul"
    instructions*: string
    options*: seq[string]       # for choice
    criteria*: seq[string]      # for score
    rawNode*: JsonNode          # underlying node for Laya
    choiceAgg*: ChoiceAggregate
    scoreAgg*: ScoreAggregate
    noulAgg*: NoulAggregate

  MatchCondition* = object
    key*: string                # e.g. "domain.choice", "urgency.score"
    operator*: string           # "eq", "in", "gte", "gt", "lte", "lt"
    strValue*: string
    seqValue*: seq[string]
    floatValue*: float

  RouteTarget* = object
    queue*: string              # e.g. "queue:swarm:{{ domain.choice }}" or "queue:worker:worker-claude"
    tags*: seq[string]          # e.g. ["database", "sql"]
    leaseSeconds*: int          # default 1800

  RouteRule* = object
    name*: string
    conditions*: seq[MatchCondition]
    target*: RouteTarget

  RoutingConfig* = object
    version*: string
    configPath*: string
    service*: RoutingServiceConfig
    limits*: RoutingLimits
    questions*: Table[string, QuestionConfig]
    routes*: seq[RouteRule]

  RoutingDecision* = object
    matchedRule*: string
    targetQueue*: string
    tags*: seq[string]
    leaseSeconds*: int
    rawAnswers*: JsonNode
    aggregationMetadata*: JsonNode

proc parseChoiceAgg(s: string, defaultVal: ChoiceAggregate = caMaxConfidence): ChoiceAggregate =
  case s.toLowerAscii
  of "max_confidence", "confidence", "max": caMaxConfidence
  of "mean_prob", "mean", "probability_mean": caMeanProb
  of "majority_vote", "majority", "vote": caMajorityVote
  else: defaultVal

proc parseScoreAgg(s: string, defaultVal: ScoreAggregate = saMax): ScoreAggregate =
  case s.toLowerAscii
  of "max": saMax
  of "mean", "avg": saMean
  of "sum": saSum
  of "min": saMin
  else: defaultVal

proc parseNoulAgg(s: string, defaultVal: NoulAggregate = naAny): NoulAggregate =
  case s.toLowerAscii
  of "any", "or": naAny
  of "all", "and": naAll
  of "mean", "avg": naMean
  else: defaultVal

proc parseOverflowStrategy(s: string): OverflowStrategy =
  case s.toLowerAscii
  of "split_aggregate", "chunk", "aggregate": osSplitAggregate
  of "lead_tail", "head_tail", "slice": osLeadTail
  of "fail_fast", "failfast", "error": osFailFast
  else: osSplitAggregate

proc defaultRoutingLimits*(): RoutingLimits =
  result.overflowStrategy = osSplitAggregate
  result.chunkSize = 8000
  result.chunkOverlap = 800
  result.splitDelimiter = "\n"
  result.maxChunks = 10
  result.defaultChoiceAgg = caMaxConfidence
  result.defaultScoreAgg = saMax
  result.defaultNoulAgg = naAny

proc defaultServiceConfig*(): RoutingServiceConfig =
  result.url = "http://127.0.0.1:8100"
  result.timeoutSeconds = 5.0
  result.model = ""
  result.apiKey = ""

# Find uncommitted local routes configuration file if present
proc findLocalRoutesConfig*(basePath: string = ""): string =
  let envPath = getEnv("RHIZO_ROUTES_LOCAL_FILE", getEnv("SYSTEMONE_ROUTES_LOCAL_FILE", ""))
  if envPath.len > 0 and fileExists(envPath): return envPath

  var searchDirs: seq[string] = @[]
  if basePath.len > 0 and fileExists(basePath):
    searchDirs.add(basePath.splitPath.head)
  searchDirs.add(getCurrentDir())

  for dir in searchDirs:
    for candidate in [
      "rhizo-routes.local.yaml", "rhizo-routes.local.yml", "rhizo-routes.local.json",
      ".rhizo/routes.local.yaml", ".rhizo/routes.local.yml", ".rhizo/routes.local.json"
    ]:
      let p = dir / candidate
      if fileExists(p): return p
  return ""

# Starter template for rhizo route init
const StarterRouteTemplate* = """# rhizo-routes.yaml
# Declarative System 1 Task Classification & Routing Configuration for Rhizo.
#
# NOTE: System 1 routing is OPTIONAL.
# Rhizo's core primitives (inter-agent messaging, distributed mutex locking,
# and explicit work queues) require zero ML models and operate directly over Redis.
#
# Semantic routing (`rhizo enqueue --route <task>`) is an optional triage accelerator
# that evaluates this declarative rule schema via local ModernBERT/Laya (<40ms forward pass).
#
# Cascading Search & Overriding Hierarchy:
#   1. Built-in defaults: Fallback domain & urgency classifier
#   2. Global user config: ~/.config/rhizo/routes.yaml
#   3. Repo root: <git-root>/rhizo-routes.yaml
#   4. Subdirectories: <repo>/packages/*/rhizo-routes.yaml
#   5. Local scratch: rhizo-routes.local.yaml (uncommitted)
#
version: "1.0"

service:
  url: "http://127.0.0.1:8100"   # local-systemone daemon port
  timeout_seconds: 5.0

limits:
  overflow_strategy: "split_aggregate"
  chunk_size: 8000
  chunk_overlap: 800
  max_chunks: 10
  defaults:
    choice: "max_confidence"
    score: "max"
    noul: "any"

questions:
  domain:
    type: choice
    instructions: "Which technical domain or subsystem does this task belong to?"
    options:
      - backend
      - frontend
      - database
      - devops
      - firmware
      - docs
    aggregate: max_confidence

  urgency:
    type: score
    instructions: "How urgent is this issue or request?"
    criteria:
      - "low priority backlog chore"
      - "standard feature or bug fix"
      - "urgent blocker or production issue"
    aggregate: max

routes:
  - name: "critical-production-incident"
    match:
      urgency.score: { gte: 1.5 }
    target:
      queue: "queue:swarm:incidents"
      tags: ["urgent", "incident"]
      lease_seconds: 3600

  - name: "domain-swarm-routing"
    match: {}
    target:
      queue: "queue:swarm:{{ domain.choice }}"
      tags: ["{{ domain.choice }}"]
      lease_seconds: 1800
"""

# Built-in sensible fallback routing config used when no routes file is found
proc defaultFallbackRoutingConfig*(): RoutingConfig =
  result.version = "1.0"
  result.configPath = "built-in default fallback"
  result.service = defaultServiceConfig()
  result.limits = defaultRoutingLimits()
  result.questions = initTable[string, QuestionConfig]()
  result.routes = @[]

  var qDomain = QuestionConfig(
    id: "domain",
    qType: "choice",
    instructions: "Which technical domain or subsystem does this task belong to?",
    options: @["backend", "frontend", "database", "devops", "firmware", "docs"],
    choiceAgg: caMaxConfidence
  )
  result.questions["domain"] = qDomain

  var qUrgency = QuestionConfig(
    id: "urgency",
    qType: "score",
    instructions: "How urgent is this issue or request?",
    criteria: @["low priority backlog chore", "standard feature or bug fix", "urgent blocker or production issue"],
    scoreAgg: saMax
  )
  result.questions["urgency"] = qUrgency

  var dynRule = RouteRule(
    name: "default-domain-swarm",
    conditions: @[],
    target: RouteTarget(
      queue: "queue:swarm:{{ domain.choice }}",
      tags: @["auto-routed"],
      leaseSeconds: 1800
    )
  )
  result.routes.add(dynRule)

# Find global user-level routes configuration file (~/.config/rhizo/routes.yaml or rhizo-routes.yaml)
proc getGlobalRoutesConfigPath*(): string =
  let envGlobal = getEnv("RHIZO_GLOBAL_ROUTES_FILE", getEnv("SYSTEMONE_GLOBAL_ROUTES_FILE", ""))
  if envGlobal.len > 0 and fileExists(envGlobal): return envGlobal
  let home = getHomeDir()
  for candidate in [
    home / ".config" / "rhizo" / "rhizo-routes.yaml",
    home / ".config" / "rhizo" / "rhizo-routes.yml",
    home / ".config" / "rhizo" / "rhizo-routes.json",
    home / ".config" / "rhizo" / "routes.yaml",
    home / ".config" / "rhizo" / "routes.yml",
    home / ".config" / "rhizo" / "routes.json",
    home / ".rhizo-routes.yaml",
    home / ".rhizo-routes.yml",
    home / ".rhizo-routes.json",
    home / ".rhizo" / "rhizo-routes.yaml",
    home / ".rhizo" / "rhizo-routes.yml",
    home / ".rhizo" / "rhizo-routes.json",
    home / ".rhizo" / "routes.yaml",
    home / ".rhizo" / "routes.yml",
    home / ".rhizo" / "routes.json"
  ]:
    if fileExists(candidate): return candidate
  return ""

# Find global user-level uncommitted local routes configuration file (~/.config/rhizo/routes.local.yaml)
proc getGlobalLocalRoutesConfigPath*(): string =
  let home = getHomeDir()
  for candidate in [
    home / ".config" / "rhizo" / "rhizo-routes.local.yaml",
    home / ".config" / "rhizo" / "rhizo-routes.local.yml",
    home / ".config" / "rhizo" / "rhizo-routes.local.json",
    home / ".config" / "rhizo" / "routes.local.yaml",
    home / ".config" / "rhizo" / "routes.local.yml",
    home / ".config" / "rhizo" / "routes.local.json",
    home / ".rhizo-routes.local.yaml",
    home / ".rhizo-routes.local.yml",
    home / ".rhizo-routes.local.json",
    home / ".rhizo" / "rhizo-routes.local.yaml",
    home / ".rhizo" / "rhizo-routes.local.yml",
    home / ".rhizo" / "rhizo-routes.local.json",
    home / ".rhizo" / "routes.local.yaml",
    home / ".rhizo" / "routes.local.yml",
    home / ".rhizo" / "routes.local.json"
  ]:
    if fileExists(candidate): return candidate
  return ""

# Discover all route configuration files walking up the directory chain to the git root.
# Returns list ordered from root (lowest precedence) to leaf subdirectory (highest precedence).
proc findRoutesConfigChain*(startDir: string = ""): seq[string] =
  var cur = if startDir.len > 0: startDir else: getCurrentDir()
  var discovered: seq[string] = @[]

  while true:
    var foundInCur = ""
    for candidate in [
      "rhizo-routes.yaml", "rhizo-routes.yml", "rhizo-routes.json",
      ".rhizo/routes.yaml", ".rhizo/routes.yml", ".rhizo/routes.json"
    ]:
      let p = cur / candidate
      if fileExists(p):
        foundInCur = p
        break

    if foundInCur.len > 0:
      discovered.add(foundInCur)

    if dirExists(cur / ".git") or fileExists(cur / ".git"):
      break
    let parent = cur.parentDir()
    if parent == cur or parent.len == 0:
      break
    cur = parent

  # Reverse so root comes first and leaf comes last (lowest to highest precedence)
  var chain: seq[string] = @[]
  for idx in countdown(discovered.len - 1, 0):
    chain.add(discovered[idx])
  return chain

# Find configuration file starting from startDir walking up
proc findRoutesConfig*(customPath: string = ""): string =
  if customPath.len > 0:
    if fileExists(customPath): return customPath
    raise newException(IOError, "Custom routes file not found: " & customPath)

  let envPath = getEnv("RHIZO_ROUTES_FILE")
  if envPath.len > 0 and fileExists(envPath): return envPath

  var cur = getCurrentDir()
  while true:
    for candidate in ["rhizo-routes.yaml", "rhizo-routes.yml", "rhizo-routes.json",
                      ".rhizo/routes.yaml", ".rhizo/routes.yml", ".rhizo/routes.json"]:
      let p = cur / candidate
      if fileExists(p): return p

    if dirExists(cur / ".git") or fileExists(cur / ".git"):
      break
    let parent = cur.parentDir()
    if parent == cur or parent.len == 0:
      break
    cur = parent

  # Check global user fallback (~/.config/rhizo/routes.yaml)
  let globalFallback = getGlobalRoutesConfigPath()
  if globalFallback.len > 0: return globalFallback

  # Fallback to local uncommitted routes configuration file if base is not found
  let localFallback = findLocalRoutesConfig("")
  if localFallback.len > 0: return localFallback
  return ""

# Lint YAML / JSON route configuration
proc lintYamlContent*(content: string, checkService: bool = false, isOverlay: bool = false,
                      inheritedQuestionIds: seq[string] = @[],
                      inheritedQuestionOptions: Table[string, seq[string]] = initTable[string, seq[string]]()): tuple[valid: bool, errors: seq[string], warnings: seq[string]] =
  var errors: seq[string] = @[]
  var warnings: seq[string] = @[]

  var doc: seq[JsonNode]
  try:
    var s = content
    doc = loadToJson(s)
  except CatchableError as e:
    return (false, @["YAML syntax error: " & e.msg], @[])

  if doc.len == 0 or doc[0] == nil or doc[0].kind != JObject:
    return (false, @["Root document must be a YAML/JSON mapping object"], @[])

  let root = doc[0]

  # Version check
  if not isOverlay and not root.hasKey("version"):
    warnings.add("Missing 'version' field in route configuration (recommended: version: \"1.0\")")

  # Questions check
  if not isOverlay and inheritedQuestionIds.len == 0 and (not root.hasKey("questions") or root["questions"].kind != JObject or root["questions"].len == 0):
    errors.add("Missing or empty 'questions' section: at least one classifier question is required")

  var questionIds: seq[string] = @[]
  for q in inheritedQuestionIds: questionIds.add(q)
  var questionOptions: Table[string, seq[string]] = inheritedQuestionOptions

  if root.hasKey("questions") and root["questions"].kind == JObject:
    for qid, qNode in root["questions"]:
      questionIds.add(qid)
      if qNode.kind != JObject:
        errors.add("Question '" & qid & "' must be a mapping object")
        continue

      let qType = qNode.getOrDefault("type").getStr("").toLowerAscii
      if qType notin ["choice", "score", "noul"]:
        errors.add("Question '" & qid & "' has invalid type '" & qType & "'. Must be choice, score, or noul")

      if qNode.getOrDefault("instructions").getStr("").strip().len == 0:
        errors.add("Question '" & qid & "' missing required 'instructions'")

      # Options validation for choice
      if qType == "choice":
        var opts: seq[string] = @[]
        if qNode.hasKey("options") and qNode["options"].kind == JArray:
          for o in qNode["options"]: opts.add(o.getStr())
        elif qNode.hasKey("criteria") and qNode["criteria"].kind == JObject:
          for k, _ in qNode["criteria"]: opts.add(k)
        elif qNode.hasKey("criteria") and qNode["criteria"].kind == JArray:
          for o in qNode["criteria"]: opts.add(o.getStr())
        
        if opts.len == 0:
          errors.add("Choice question '" & qid & "' must define non-empty 'options' list or 'criteria' mapping")
        questionOptions[qid] = opts

        # Aggregation validation for choice
        if qNode.hasKey("aggregate"):
          let aggStr = qNode["aggregate"].getStr("").toLowerAscii
          if aggStr notin ["max_confidence", "confidence", "mean_prob", "mean", "majority_vote", "vote"]:
            errors.add("Invalid aggregation strategy '" & aggStr & "' for choice question '" & qid &
                       "'. Valid options: max_confidence, mean_prob, majority_vote")

      elif qType == "score":
        var critCount = 0
        if qNode.hasKey("criteria") and qNode["criteria"].kind == JArray: critCount = qNode["criteria"].len
        elif qNode.hasKey("rubric") and qNode["rubric"].kind == JArray: critCount = qNode["rubric"].len
        elif qNode.hasKey("levels") and qNode["levels"].kind == JArray: critCount = qNode["levels"].len
        elif qNode.hasKey("criteria") and qNode["criteria"].kind == JObject: critCount = qNode["criteria"].len

        if critCount < 2:
          errors.add("Score question '" & qid & "' must define at least 2 levels in 'criteria' list")

        # Aggregation validation for score
        if qNode.hasKey("aggregate"):
          let aggStr = qNode["aggregate"].getStr("").toLowerAscii
          if aggStr notin ["max", "mean", "avg", "sum", "min"]:
            errors.add("Invalid aggregation strategy '" & aggStr & "' for score question '" & qid &
                       "'. Valid options: max, mean, sum, min")

      elif qType == "noul":
        if qNode.hasKey("aggregate"):
          let aggStr = qNode["aggregate"].getStr("").toLowerAscii
          if aggStr notin ["any", "or", "all", "and", "mean", "avg"]:
            errors.add("Invalid aggregation strategy '" & aggStr & "' for noul question '" & qid &
                       "'. Valid options: any, all, mean")

  # Routes check
  if not isOverlay and (not root.hasKey("routes") or root["routes"].kind != JArray or root["routes"].len == 0):
    errors.add("Missing or empty 'routes' section: at least one routing rule is required")

  var seenRuleNames: seq[string] = @[]

  if root.hasKey("routes") and root["routes"].kind == JArray:
    for idx, rNode in root["routes"].elems:
      if rNode.kind != JObject:
        errors.add("Route at index " & $idx & " must be an object")
        continue

      let name = rNode.getOrDefault("name").getStr("route-" & $idx)
      if name in seenRuleNames:
        warnings.add("Duplicate route rule name: '" & name & "'")
      seenRuleNames.add(name)

      # Match conditions (empty mapping acts as catch-all rule)
      if rNode.hasKey("match") and rNode["match"].kind == JObject:
        if rNode["match"].len == 0 and idx < root["routes"].elems.len - 1:
          warnings.add("Route '" & name & "' has empty match (catch-all) but is not the last rule in the list")
        for mKey, mVal in rNode["match"]:
          let qPrefix = mKey.split('.')[0]
          if qPrefix notin questionIds:
            errors.add("Route '" & name & "' references undeclared question '" & qPrefix & "' in match key '" & mKey & "'")
          else:
            # If matching a choice option, verify option exists
            if questionOptions.hasKey(qPrefix):
              let opts = questionOptions[qPrefix]
              if mVal.kind == JString:
                let s = mVal.getStr()
                if s notin opts:
                  errors.add("Route '" & name & "' matches choice value '" & s & "' not present in question '" & qPrefix & "' options " & $opts)
              elif mVal.kind == JArray:
                for item in mVal:
                  if item.kind == JString and item.getStr() notin opts:
                    errors.add("Route '" & name & "' matches choice value '" & item.getStr() & "' not present in question '" & qPrefix & "' options " & $opts)
      elif not rNode.hasKey("match"):
        if idx < root["routes"].elems.len - 1:
          warnings.add("Route '" & name & "' has no match conditions (catch-all) but is not the last rule in the list")
      else:
        errors.add("Route '" & name & "' 'match' must be a mapping object")

      # Target validation
      if not rNode.hasKey("target") or rNode["target"].kind != JObject:
        errors.add("Route '" & name & "' missing 'target' object")
      else:
        let tNode = rNode["target"]
        let queue = tNode.getOrDefault("queue").getStr("")
        if queue.strip().len == 0:
          errors.add("Route '" & name & "' target missing required 'queue' string")
        elif not (queue.startsWith("queue:swarm:") or queue.startsWith("queue:worker:") or
                  queue.startsWith("swarm:") or queue.startsWith("worker:") or "{{" in queue):
          warnings.add("Route '" & name & "' queue '" & queue & "' does not match standard convention 'queue:swarm:<tag>' or 'queue:worker:<agent>'")

        if tNode.hasKey("lease_seconds"):
          if tNode["lease_seconds"].kind != JInt or tNode["lease_seconds"].getInt() <= 0:
            errors.add("Route '" & name & "' lease_seconds must be a positive integer")

  # Limits validation
  if root.hasKey("limits") and root["limits"].kind == JObject:
    let lNode = root["limits"]
    let chunkSize = lNode.getOrDefault("chunk_size").getInt(8000)
    let chunkOverlap = lNode.getOrDefault("chunk_overlap").getInt(800)
    let maxChunks = lNode.getOrDefault("max_chunks").getInt(10)
    if chunkSize <= 0:
      errors.add("limits.chunk_size must be a positive integer")
    if chunkOverlap < 0 or chunkOverlap >= chunkSize:
      errors.add("limits.chunk_overlap must be >= 0 and less than chunk_size")
    if maxChunks <= 0:
      errors.add("limits.max_chunks must be a positive integer")

  # Optional live service check
  if checkService and errors.len == 0:
    var serviceUrl = "http://127.0.0.1:8100"
    var apiKey = ""
    if root.hasKey("service") and root["service"].kind == JObject:
      serviceUrl = root["service"].getOrDefault("url").getStr(serviceUrl)
      apiKey = root["service"].getOrDefault("api_key").getStr("")
    let envUrl = getEnvFirst("RHIZO_SERVICE_URL", "RHIZO_SYSTEMONE_URL", "RHIZO_LAYA_URL", "SYSTEMONE_URL", "LAYA_URL")
    if envUrl.len > 0: serviceUrl = envUrl
    let envKey = getEnvFirst("LAYA_API_KEY", "RHIZO_LAYA_API_KEY")
    if envKey.len > 0: apiKey = envKey

    var client = newHttpClient(timeout = 3000)
    if apiKey.len > 0:
      client.headers = newHttpHeaders({"Authorization": "Bearer " & apiKey})
    try:
      var resp = client.get(serviceUrl & "/healthz")
      if resp.code != Http200:
        # Fallback to /v1/models or root for Kev/Decider/Jev servers
        resp = client.get(serviceUrl & "/v1/models")
        if resp.code != Http200:
          resp = client.get(serviceUrl & "/")
          if resp.code != Http200 and resp.code != Http404 and resp.code != Http405:
            errors.add("System 1 service at " & serviceUrl & " returned HTTP " & $resp.code)
    except CatchableError as e:
      errors.add("Cannot connect to System 1 service at " & serviceUrl & ": " & e.msg)
    finally:
      client.close()

  return (errors.len == 0, errors, warnings)

# Lint file directly
proc lintRoutesConfigFile*(filePath: string, checkService: bool = false, isOverlay: bool = false,
                           inheritedQuestionIds: seq[string] = @[],
                           inheritedQuestionOptions: Table[string, seq[string]] = initTable[string, seq[string]]()): tuple[valid: bool, errors: seq[string], warnings: seq[string]] =
  if not fileExists(filePath):
    return (false, @["File does not exist: " & filePath], @[])
  try:
    let content = readFile(filePath)
    let overlayFlag = isOverlay or filePath.contains(".local.")
    return lintYamlContent(content, checkService, isOverlay = overlayFlag,
                           inheritedQuestionIds = inheritedQuestionIds,
                           inheritedQuestionOptions = inheritedQuestionOptions)
  except CatchableError as e:
    return (false, @["Failed to read file: " & e.msg], @[])

# Parse full configuration from YAML content
proc parseRoutesConfig*(yamlContent: string, configPath: string = ""): RoutingConfig =
  loadDotEnv()
  var doc: seq[JsonNode]
  try:
    var s = yamlContent
    doc = loadToJson(s)
  except CatchableError as e:
    raise newException(ValueError, "Failed to parse YAML route config: " & e.msg)

  if doc.len == 0 or doc[0] == nil or doc[0].kind != JObject:
    raise newException(ValueError, "Route config root must be a YAML mapping")

  let root = doc[0]
  result.configPath = configPath
  result.version = root.getOrDefault("version").getStr("1.0")
  result.service = defaultServiceConfig()
  result.limits = defaultRoutingLimits()
  result.questions = initTable[string, QuestionConfig]()
  result.routes = @[]

  # Parse service
  if root.hasKey("service") and root["service"].kind == JObject:
    let sNode = root["service"]
    result.service.url = sNode.getOrDefault("url").getStr(result.service.url)
    result.service.model = sNode.getOrDefault("model").getStr("")
    result.service.apiKey = sNode.getOrDefault("api_key").getStr("")
    if sNode.hasKey("timeout_seconds"):
      if sNode["timeout_seconds"].kind == JFloat:
        result.service.timeoutSeconds = sNode["timeout_seconds"].getFloat()
      elif sNode["timeout_seconds"].kind == JInt:
        result.service.timeoutSeconds = float(sNode["timeout_seconds"].getInt())

  # Env overrides
  let envUrl = getEnvFirst("RHIZO_SERVICE_URL", "RHIZO_SYSTEMONE_URL", "RHIZO_LAYA_URL", "SYSTEMONE_URL", "LAYA_URL")
  if envUrl.len > 0: result.service.url = envUrl
  let envModel = getEnvFirst("RHIZO_MODEL", "RHIZO_SYSTEMONE_MODEL", "SYSTEMONE_MODEL", "LAYA_MODEL")
  if envModel.len > 0: result.service.model = envModel
  let envKey = getEnvFirst("LAYA_API_KEY", "RHIZO_LAYA_API_KEY")
  if envKey.len > 0: result.service.apiKey = envKey
  let envTimeout = getEnvFirst("RHIZO_ROUTE_TIMEOUT", "RHIZO_SYSTEMONE_TIMEOUT", "SYSTEMONE_TIMEOUT")
  if envTimeout.len > 0:
    try: result.service.timeoutSeconds = parseFloat(envTimeout)
    except ValueError: discard

  # Parse limits
  if root.hasKey("limits") and root["limits"].kind == JObject:
    let lNode = root["limits"]
    result.limits.overflowStrategy = parseOverflowStrategy(lNode.getOrDefault("overflow_strategy").getStr("split_aggregate"))
    result.limits.chunkSize = lNode.getOrDefault("chunk_size").getInt(8000)
    result.limits.chunkOverlap = lNode.getOrDefault("chunk_overlap").getInt(800)
    result.limits.splitDelimiter = lNode.getOrDefault("split_delimiter").getStr("\n")
    result.limits.maxChunks = lNode.getOrDefault("max_chunks").getInt(10)
    if lNode.hasKey("defaults") and lNode["defaults"].kind == JObject:
      let dNode = lNode["defaults"]
      result.limits.defaultChoiceAgg = parseChoiceAgg(dNode.getOrDefault("choice").getStr("max_confidence"))
      result.limits.defaultScoreAgg = parseScoreAgg(dNode.getOrDefault("score").getStr("max"))
      result.limits.defaultNoulAgg = parseNoulAgg(dNode.getOrDefault("noul").getStr("any"))

  # Parse questions
  if root.hasKey("questions") and root["questions"].kind == JObject:
    for qid, qNode in root["questions"]:
      if qNode.kind != JObject: continue
      var qc = QuestionConfig(
        id: qid,
        qType: qNode.getOrDefault("type").getStr("choice").toLowerAscii,
        instructions: qNode.getOrDefault("instructions").getStr(""),
        options: @[],
        criteria: @[],
        rawNode: qNode,
        choiceAgg: result.limits.defaultChoiceAgg,
        scoreAgg: result.limits.defaultScoreAgg,
        noulAgg: result.limits.defaultNoulAgg
      )
      if qNode.hasKey("aggregate"):
        let aStr = qNode["aggregate"].getStr("")
        qc.choiceAgg = parseChoiceAgg(aStr, result.limits.defaultChoiceAgg)
        qc.scoreAgg = parseScoreAgg(aStr, result.limits.defaultScoreAgg)
        qc.noulAgg = parseNoulAgg(aStr, result.limits.defaultNoulAgg)

      if qNode.hasKey("options") and qNode["options"].kind == JArray:
        for o in qNode["options"]: qc.options.add(o.getStr())
      elif qNode.hasKey("criteria") and qNode["criteria"].kind == JObject:
        for k, _ in qNode["criteria"]: qc.options.add(k)
      elif qNode.hasKey("criteria") and qNode["criteria"].kind == JArray:
        for o in qNode["criteria"]:
          qc.options.add(o.getStr())
          qc.criteria.add(o.getStr())

      result.questions[qid] = qc

  # Parse routes
  if root.hasKey("routes") and root["routes"].kind == JArray:
    for idx, rNode in root["routes"].elems:
      if rNode.kind != JObject: continue
      var rule = RouteRule(
        name: rNode.getOrDefault("name").getStr("rule-" & $idx),
        conditions: @[],
        target: RouteTarget(queue: "", tags: @[], leaseSeconds: 1800)
      )

      if rNode.hasKey("match") and rNode["match"].kind == JObject:
        for mKey, mVal in rNode["match"]:
          var cond = MatchCondition(key: mKey)
          if mVal.kind == JString:
            cond.operator = "eq"
            cond.strValue = mVal.getStr()
          elif mVal.kind == JArray:
            cond.operator = "in"
            cond.seqValue = @[]
            for item in mVal: cond.seqValue.add(item.getStr())
          elif mVal.kind == JObject:
            # Score or probability comparisons: { gte: 1.5, lt: 0.2, etc. }
            for op, valNode in mVal:
              cond.operator = op.toLowerAscii
              if valNode.kind == JFloat: cond.floatValue = valNode.getFloat()
              elif valNode.kind == JInt: cond.floatValue = float(valNode.getInt())
          rule.conditions.add(cond)

      if rNode.hasKey("target") and rNode["target"].kind == JObject:
        let tNode = rNode["target"]
        rule.target.queue = tNode.getOrDefault("queue").getStr("")
        rule.target.leaseSeconds = tNode.getOrDefault("lease_seconds").getInt(1800)
        if tNode.hasKey("tags") and tNode["tags"].kind == JArray:
          for t in tNode["tags"]: rule.target.tags.add(t.getStr())

      result.routes.add(rule)

# Merge uncommitted local route overrides onto base configuration
proc mergeRoutingConfigs*(baseCfg: var RoutingConfig, localCfg: RoutingConfig) =
  # Service overrides
  let def = defaultServiceConfig()
  if localCfg.service.url.len > 0 and localCfg.service.url != def.url:
    baseCfg.service.url = localCfg.service.url
  if localCfg.service.model.len > 0:
    baseCfg.service.model = localCfg.service.model
  if localCfg.service.apiKey.len > 0:
    baseCfg.service.apiKey = localCfg.service.apiKey
  if localCfg.service.timeoutSeconds != def.timeoutSeconds and localCfg.service.timeoutSeconds > 0:
    baseCfg.service.timeoutSeconds = localCfg.service.timeoutSeconds

  # Limits overrides
  let defLim = defaultRoutingLimits()
  if localCfg.limits.overflowStrategy != defLim.overflowStrategy:
    baseCfg.limits.overflowStrategy = localCfg.limits.overflowStrategy
  if localCfg.limits.chunkSize != defLim.chunkSize:
    baseCfg.limits.chunkSize = localCfg.limits.chunkSize
  if localCfg.limits.chunkOverlap != defLim.chunkOverlap:
    baseCfg.limits.chunkOverlap = localCfg.limits.chunkOverlap
  if localCfg.limits.maxChunks != defLim.maxChunks:
    baseCfg.limits.maxChunks = localCfg.limits.maxChunks

  # Questions overrides / additions
  for qid, qc in localCfg.questions:
    baseCfg.questions[qid] = qc

  # Routes overrides / additions (prepend new rules so local rules match first)
  for localRule in localCfg.routes:
    var replaced = false
    for i in 0 ..< baseCfg.routes.len:
      if baseCfg.routes[i].name == localRule.name:
        baseCfg.routes[i] = localRule
        replaced = true
        break
    if not replaced:
      baseCfg.routes.insert(localRule, 0)

# Load effective configuration cascading across global config, directory chain, and local overlays
proc loadEffectiveRoutesConfig*(customPath: string = ""): RoutingConfig =
  loadDotEnv()
  if customPath.len > 0:
    let p = if fileExists(customPath): customPath else: findRoutesConfig(customPath)
    if p.len == 0 or not fileExists(p):
      raise newException(IOError, "Custom routes file not found: " & customPath)
    let localCompanion = findLocalRoutesConfig(p)
    var baseCfg = parseRoutesConfig(readFile(p), p)
    if localCompanion.len > 0 and fileExists(localCompanion) and localCompanion != p:
      let localCfg = parseRoutesConfig(readFile(localCompanion), localCompanion)
      mergeRoutingConfigs(baseCfg, localCfg)
      baseCfg.configPath = p & " (+ " & localCompanion.extractFilename & ")"
    return baseCfg

  let envPath = getEnv("RHIZO_ROUTES_FILE")
  if envPath.len > 0 and fileExists(envPath):
    var baseCfg = parseRoutesConfig(readFile(envPath), envPath)
    let localCompanion = findLocalRoutesConfig(envPath)
    if localCompanion.len > 0 and fileExists(localCompanion) and localCompanion != envPath:
      let localCfg = parseRoutesConfig(readFile(localCompanion), localCompanion)
      mergeRoutingConfigs(baseCfg, localCfg)
      baseCfg.configPath = envPath & " (+ " & localCompanion.extractFilename & ")"
    return baseCfg

  # Hierarchical resolution:
  # 1. Global config (~/.config/rhizo/routes.yaml)
  # 2. Directory chain from repo-root down to current dir
  # 3. Local uncommitted overrides (*.local.yaml)
  var fileChain: seq[string] = @[]
  var pathDescriptions: seq[string] = @[]

  let globalBase = getGlobalRoutesConfigPath()
  if globalBase.len > 0:
    fileChain.add(globalBase)
    pathDescriptions.add(globalBase)
    let globalLocal = getGlobalLocalRoutesConfigPath()
    if globalLocal.len > 0 and globalLocal != globalBase:
      fileChain.add(globalLocal)
      pathDescriptions.add(globalLocal.extractFilename)

  let dirChain = findRoutesConfigChain(getCurrentDir())
  for f in dirChain:
    fileChain.add(f)
    pathDescriptions.add(f)
    let fLocal = findLocalRoutesConfig(f)
    if fLocal.len > 0 and fLocal != f and fLocal notin fileChain:
      fileChain.add(fLocal)
      pathDescriptions.add(fLocal.extractFilename)

  let curLocal = findLocalRoutesConfig(getCurrentDir())
  if curLocal.len > 0 and curLocal notin fileChain:
    fileChain.add(curLocal)
    pathDescriptions.add(curLocal.extractFilename)

  if fileChain.len == 0:
    # No route files anywhere in chain: return built-in fallback default
    return defaultFallbackRoutingConfig()

  var effective = parseRoutesConfig(readFile(fileChain[0]), fileChain[0])
  for i in 1 ..< fileChain.len:
    let nextCfg = parseRoutesConfig(readFile(fileChain[i]), fileChain[i])
    mergeRoutingConfigs(effective, nextCfg)

  effective.configPath = pathDescriptions.join(" -> ")
  return effective

# Lint effective routes configuration considering both base, chain, and local overlays
proc lintEffectiveRoutesConfig*(customPath: string = "", checkService: bool = false): tuple[valid: bool, errors: seq[string], warnings: seq[string], pathDesc: string] =
  loadDotEnv()
  if customPath.len > 0:
    let (v, e, w) = lintRoutesConfigFile(customPath, checkService)
    return (v, e, w, customPath)

  let envPath = getEnv("RHIZO_ROUTES_FILE")
  if envPath.len > 0 and fileExists(envPath):
    let (v, e, w) = lintRoutesConfigFile(envPath, checkService)
    return (v, e, w, envPath)

  var fileChain: seq[string] = @[]
  var pathDescriptions: seq[string] = @[]

  let globalBase = getGlobalRoutesConfigPath()
  if globalBase.len > 0:
    fileChain.add(globalBase)
    pathDescriptions.add(globalBase)
    let globalLocal = getGlobalLocalRoutesConfigPath()
    if globalLocal.len > 0 and globalLocal != globalBase:
      fileChain.add(globalLocal)
      pathDescriptions.add(globalLocal.extractFilename)

  let dirChain = findRoutesConfigChain(getCurrentDir())
  for f in dirChain:
    fileChain.add(f)
    pathDescriptions.add(f)
    let fLocal = findLocalRoutesConfig(f)
    if fLocal.len > 0 and fLocal != f and fLocal notin fileChain:
      fileChain.add(fLocal)
      pathDescriptions.add(fLocal.extractFilename)

  let curLocal = findLocalRoutesConfig(getCurrentDir())
  if curLocal.len > 0 and curLocal notin fileChain:
    fileChain.add(curLocal)
    pathDescriptions.add(curLocal.extractFilename)

  if fileChain.len == 0:
    var warnings: seq[string] = @["No rhizo-routes.yaml found; using built-in default domain/urgency routing fallback"]
    var errors: seq[string] = @[]
    if checkService:
      let defSvc = defaultServiceConfig()
      var client = newHttpClient(timeout = 3000)
      try:
        var resp = client.get(defSvc.url & "/healthz")
        if resp.code != Http200:
          resp = client.get(defSvc.url & "/")
          if resp.code != Http200 and resp.code != Http404 and resp.code != Http405:
            errors.add("System 1 service at " & defSvc.url & " returned HTTP " & $resp.code)
      except CatchableError as e:
        errors.add("Cannot connect to System 1 service at " & defSvc.url & ": " & e.msg)
      finally:
        client.close()
    return (errors.len == 0, errors, warnings, "built-in default fallback")

  var allErrors: seq[string] = @[]
  var allWarnings: seq[string] = @[]
  var allValid = true

  var accQuestionIds: seq[string] = @[]
  var accQuestionOptions: Table[string, seq[string]] = initTable[string, seq[string]]()

  for idx, f in fileChain:
    let isOver = f.contains(".local.") or idx > 0
    let (v, e, w) = lintRoutesConfigFile(f, checkService = false, isOverlay = isOver,
                                         inheritedQuestionIds = accQuestionIds,
                                         inheritedQuestionOptions = accQuestionOptions)
    if not v: allValid = false
    for err in e: allErrors.add("[" & f.extractFilename & "] " & err)
    for warn in w: allWarnings.add("[" & f.extractFilename & "] " & warn)

    # Accumulate questions declared in this file for downstream overlays
    try:
      let doc = loadToJson(readFile(f))
      if doc.len > 0 and doc[0] != nil and doc[0].kind == JObject and doc[0].hasKey("questions") and doc[0]["questions"].kind == JObject:
        for qid, qNode in doc[0]["questions"]:
          if qid notin accQuestionIds:
            accQuestionIds.add(qid)
          if qNode.kind == JObject and qNode.hasKey("options") and qNode["options"].kind == JArray:
            var opts: seq[string] = @[]
            for opt in qNode["options"]:
              if opt.kind == JString: opts.add(opt.getStr())
            accQuestionOptions[qid] = opts
    except CatchableError: discard

  if allValid and checkService:
    try:
      let effective = loadEffectiveRoutesConfig("")
      var client = newHttpClient(timeout = 3000)
      if effective.service.apiKey.len > 0:
        client.headers = newHttpHeaders({"Authorization": "Bearer " & effective.service.apiKey})
      try:
        var resp = client.get(effective.service.url & "/healthz")
        if resp.code != Http200:
          resp = client.get(effective.service.url & "/v1/models")
          if resp.code != Http200:
            resp = client.get(effective.service.url & "/")
            if resp.code != Http200 and resp.code != Http404 and resp.code != Http405:
              allErrors.add("System 1 service at " & effective.service.url & " returned HTTP " & $resp.code)
      except CatchableError as e:
        allErrors.add("Cannot connect to System 1 service at " & effective.service.url & ": " & e.msg)
      finally:
        client.close()
    except CatchableError as e:
      allErrors.add("Failed to evaluate effective merged routes: " & e.msg)

  let pathDesc = pathDescriptions.join(" -> ")
  return (allErrors.len == 0 and allValid, allErrors, allWarnings, pathDesc)

# Split oversized input into chunks respecting limits
proc splitIntoChunks*(text: string, limits: RoutingLimits): seq[string] =
  if text.len <= limits.chunkSize:
    return @[text]

  case limits.overflowStrategy
  of osFailFast:
    raise newException(ValueError, "Input length (" & $text.len & " chars) exceeds limits.chunk_size (" &
                                   $limits.chunkSize & " chars) and overflow_strategy is fail_fast")

  of osLeadTail:
    let budget = limits.chunkSize
    let headLen = int(float(budget) * 0.45)
    let tailLen = int(float(budget) * 0.45)
    let marker = "\n\n[... truncated " & $(text.len - headLen - tailLen) & " characters of middle context ...]\n\n"
    return @[text[0 ..< headLen] & marker & text[^tailLen .. ^1]]

  of osSplitAggregate:
    result = @[]
    var curPos = 0
    let step = max(1, limits.chunkSize - limits.chunkOverlap)

    while curPos < text.len:
      if result.len >= limits.maxChunks:
        raise newException(ValueError, "Input requires more chunks than configured limits.max_chunks (" &
                                       $limits.maxChunks & "). Increase max_chunks or summarize text.")

      let remain = text.len - curPos
      if remain <= limits.chunkSize:
        result.add(text[curPos .. ^1])
        break

      # Look for natural split delimiter near the end of chunkSize
      let windowEnd = curPos + limits.chunkSize
      var cutPos = windowEnd
      if limits.splitDelimiter.len > 0:
        let searchBackLimit = max(curPos + step, windowEnd - (limits.chunkOverlap div 2))
        let delimIdx = text.rfind(limits.splitDelimiter, searchBackLimit, windowEnd)
        if delimIdx > 0 and delimIdx > curPos:
          cutPos = delimIdx + limits.splitDelimiter.len

      result.add(text[curPos ..< cutPos])
      curPos = curPos + step
      if curPos >= text.len: break

# Multi-chunk question-level aggregation
proc aggregateChunkAnswers*(
  chunksAnswers: seq[JsonNode],
  questions: Table[string, QuestionConfig]
): (JsonNode, JsonNode) =
  var aggAnswers = newJObject()
  var metaAnswers = newJObject()

  if chunksAnswers.len == 0:
    return (aggAnswers, metaAnswers)

  if chunksAnswers.len == 1:
    let single = chunksAnswers[0]
    var meta = %*{
      "chunks_evaluated": 1,
      "strategy": "direct"
    }
    return (single, meta)

  let numChunks = chunksAnswers.len

  for qid, qc in questions:
    case qc.qType
    of "choice":
      case qc.choiceAgg
      of caMaxConfidence:
        var maxConf = -1.0
        var bestNode: JsonNode = nil
        var bestChunkIdx = 0
        for idx, ca in chunksAnswers:
          if ca.hasKey(qid) and ca[qid].hasKey("confidence"):
            let conf = ca[qid]["confidence"].getFloat(0.0)
            if conf > maxConf:
              maxConf = conf
              bestNode = ca[qid]
              bestChunkIdx = idx + 1
        if bestNode != nil:
          aggAnswers[qid] = bestNode
          metaAnswers[qid] = %*{
            "aggregate_strategy": "max_confidence",
            "winning_chunk": bestChunkIdx,
            "confidence": maxConf
          }
        else:
          aggAnswers[qid] = chunksAnswers[0].getOrDefault(qid)

      of caMeanProb:
        var probSums = initTable[string, float]()
        var counts = initTable[string, int]()
        for ca in chunksAnswers:
          if ca.hasKey(qid) and ca[qid].hasKey("probabilities"):
            for opt, pVal in ca[qid]["probabilities"]:
              probSums[opt] = probSums.getOrDefault(opt, 0.0) + pVal.getFloat(0.0)
              counts[opt] = counts.getOrDefault(opt, 0) + 1

        var bestOpt = ""
        var maxProb = -1.0
        var avgProbNode = newJObject()
        for opt, sumVal in probSums:
          let avgP = sumVal / float(max(1, counts.getOrDefault(opt, 1)))
          avgProbNode[opt] = %avgP
          if avgP > maxProb:
            maxProb = avgP
            bestOpt = opt

        var node = newJObject()
        node["type"] = %"choice"
        node["choice"] = %bestOpt
        node["confidence"] = %maxProb
        node["probabilities"] = avgProbNode
        aggAnswers[qid] = node
        metaAnswers[qid] = %*{
          "aggregate_strategy": "mean_prob",
          "choice": bestOpt
        }

      of caMajorityVote:
        var votes = initTable[string, int]()
        for ca in chunksAnswers:
          if ca.hasKey(qid) and ca[qid].hasKey("choice"):
            let c = ca[qid]["choice"].getStr()
            votes[c] = votes.getOrDefault(c, 0) + 1

        var topChoice = ""
        var topVotes = -1
        for c, count in votes:
          if count > topVotes:
            topVotes = count
            topChoice = c

        var node = newJObject()
        node["type"] = %"choice"
        node["choice"] = %topChoice
        aggAnswers[qid] = node
        metaAnswers[qid] = %*{
          "aggregate_strategy": "majority_vote",
          "choice": topChoice,
          "votes": topVotes
        }

    of "score":
      var scores: seq[float] = @[]
      for ca in chunksAnswers:
        if ca.hasKey(qid) and ca[qid].hasKey("score"):
          scores.add(ca[qid]["score"].getFloat(0.0))

      if scores.len == 0:
        aggAnswers[qid] = chunksAnswers[0].getOrDefault(qid)
        continue

      var finalScore = 0.0
      case qc.scoreAgg
      of saMax:
        finalScore = scores[0]
        for s in scores:
          if s > finalScore: finalScore = s
      of saMin:
        finalScore = scores[0]
        for s in scores:
          if s < finalScore: finalScore = s
      of saMean:
        var sum = 0.0
        for s in scores: sum += s
        finalScore = sum / float(scores.len)
      of saSum:
        var sum = 0.0
        for s in scores: sum += s
        finalScore = sum

      var node = newJObject()
      node["type"] = %"score"
      node["score"] = %finalScore
      aggAnswers[qid] = node
      metaAnswers[qid] = %*{
        "aggregate_strategy": $qc.scoreAgg,
        "score": finalScore,
        "chunk_scores": %scores
      }

    of "noul":
      var noulVals: seq[float] = @[]
      for ca in chunksAnswers:
        if ca.hasKey(qid):
          let sub = ca[qid]
          if sub.hasKey("noul"):
            if sub["noul"].kind == JFloat: noulVals.add(sub["noul"].getFloat())
            elif sub["noul"].kind == JInt: noulVals.add(float(sub["noul"].getInt()))
            elif sub["noul"].kind == JBool: noulVals.add(if sub["noul"].getBool(): 1.0 else: 0.0)

      if noulVals.len == 0:
        aggAnswers[qid] = chunksAnswers[0].getOrDefault(qid)
        continue

      var finalVal = 0.0
      case qc.noulAgg
      of naAny:
        for v in noulVals:
          if v >= 0.5:
            finalVal = v
            break
      of naAll:
        var allTrue = true
        for v in noulVals:
          if v < 0.5: allTrue = false; break
        finalVal = if allTrue: 1.0 else: 0.0
      of naMean:
        var sum = 0.0
        for v in noulVals: sum += v
        finalVal = sum / float(noulVals.len)

      var node = newJObject()
      node["type"] = %"noul"
      node["noul"] = %finalVal
      aggAnswers[qid] = node
      metaAnswers[qid] = %*{
        "aggregate_strategy": $qc.noulAgg,
        "noul": finalVal
      }
    else:
      aggAnswers[qid] = chunksAnswers[0].getOrDefault(qid)

  var fullMeta = %*{
    "strategy": "split_aggregate",
    "chunks_evaluated": numChunks,
    "answers": metaAnswers
  }
  return (aggAnswers, fullMeta)

# Helper to resolve string interpolation: {{ question.field }} -> value
proc interpolateString(templateStr: string, answers: JsonNode): string =
  result = templateStr
  while "{{" in result and "}}" in result:
    let startIdx = result.find("{{")
    let endIdx = result.find("}}", startIdx)
    if startIdx < 0 or endIdx < 0: break

    let rawKey = result[startIdx + 2 ..< endIdx].strip()
    var repl = ""
    let parts = rawKey.split('.')
    if parts.len == 1:
      if answers.hasKey(parts[0]):
        let n = answers[parts[0]]
        if n.kind == JString: repl = n.getStr()
        elif n.hasKey("choice"): repl = n["choice"].getStr()
        elif n.hasKey("score"): repl = $n["score"].getFloat()
    elif parts.len >= 2:
      let qid = parts[0]
      let field = parts[1]
      if answers.hasKey(qid) and answers[qid].hasKey(field):
        let n = answers[qid][field]
        if n.kind == JString: repl = n.getStr()
        elif n.kind == JFloat: repl = $n.getFloat()
        elif n.kind == JInt: repl = $n.getInt()
        elif n.kind == JBool: repl = $n.getBool()

    result = result[0 ..< startIdx] & repl & result[endIdx + 2 .. ^1]

# Evaluate matching rules against final answers
proc evaluateRules*(rules: seq[RouteRule], answers: JsonNode, meta: JsonNode): RoutingDecision =
  for rule in rules:
    var allMatched = true

    for cond in rule.conditions:
      let parts = cond.key.split('.')
      let qid = parts[0]
      let field = if parts.len > 1: parts[1] else: ""

      if not answers.hasKey(qid):
        allMatched = false
        break

      let qNode = answers[qid]

      case cond.operator
      of "eq":
        let actual = if field.len > 0 and qNode.hasKey(field): qNode[field].getStr()
                     elif qNode.hasKey("choice"): qNode["choice"].getStr()
                     elif qNode.kind == JString: qNode.getStr()
                     else: ""
        if actual != cond.strValue:
          allMatched = false
          break

      of "in":
        let actual = if field.len > 0 and qNode.hasKey(field): qNode[field].getStr()
                     elif qNode.hasKey("choice"): qNode["choice"].getStr()
                     elif qNode.kind == JString: qNode.getStr()
                     else: ""
        if actual notin cond.seqValue:
          allMatched = false
          break

      of "gte":
        let actual = if field.len > 0 and qNode.hasKey(field): qNode[field].getFloat(0.0)
                     elif qNode.hasKey("score"): qNode["score"].getFloat(0.0)
                     elif qNode.kind == JFloat: qNode.getFloat()
                     else: 0.0
        if actual < cond.floatValue:
          allMatched = false
          break

      of "gt":
        let actual = if field.len > 0 and qNode.hasKey(field): qNode[field].getFloat(0.0)
                     elif qNode.hasKey("score"): qNode["score"].getFloat(0.0)
                     else: 0.0
        if actual <= cond.floatValue:
          allMatched = false
          break

      of "lte":
        let actual = if field.len > 0 and qNode.hasKey(field): qNode[field].getFloat(0.0)
                     elif qNode.hasKey("score"): qNode["score"].getFloat(0.0)
                     else: 0.0
        if actual > cond.floatValue:
          allMatched = false
          break

      of "lt":
        let actual = if field.len > 0 and qNode.hasKey(field): qNode[field].getFloat(0.0)
                     elif qNode.hasKey("score"): qNode["score"].getFloat(0.0)
                     else: 0.0
        if actual >= cond.floatValue:
          allMatched = false
          break

      else:
        allMatched = false
        break

    if allMatched:
      let targetQ = interpolateString(rule.target.queue, answers)
      var finalTags: seq[string] = @[]
      for t in rule.target.tags:
        finalTags.add(interpolateString(t, answers))

      return RoutingDecision(
        matchedRule: rule.name,
        targetQueue: targetQ,
        tags: finalTags,
        leaseSeconds: rule.target.leaseSeconds,
        rawAnswers: answers,
        aggregationMetadata: meta
      )

  # Fail-Fast: Zero graceful degradation
  raise newException(ValueError, "No route rule matched Laya classification results: " & $answers)

# Call System 1 endpoint with strict timeout and diagnostics
proc callSystemOne*(
  service: RoutingServiceConfig,
  stateText: string,
  questions: Table[string, QuestionConfig]
): JsonNode =
  var qDict = newJObject()
  for qid, qc in questions:
    if qc.rawNode != nil:
      qDict[qid] = qc.rawNode
    else:
      var qn = newJObject()
      qn["type"] = %qc.qType
      qn["instructions"] = %qc.instructions
      if qc.options.len > 0: qn["options"] = %qc.options
      elif qc.criteria.len > 0: qn["criteria"] = %qc.criteria
      qDict[qid] = qn

  var reqBody = %*{
    "state": stateText,
    "questions": qDict
  }
  if service.model.len > 0:
    reqBody["model"] = %service.model

  let timeoutMs = int(service.timeoutSeconds * 1000)
  var client = newHttpClient(timeout = timeoutMs)
  var headers = newHttpHeaders({"Content-Type": "application/json"})
  if service.apiKey.len > 0:
    headers["Authorization"] = "Bearer " & service.apiKey
  client.headers = headers

  let endpoint = service.url.strip(chars = {'/'}) & "/v1/systemone"

  var respStr = ""
  try:
    respStr = client.postContent(endpoint, body = $reqBody)
  except HttpRequestError as e:
    stderr.writeLine("Error: System 1 service returned HTTP error at " & endpoint & ": " & e.msg)
    quit(1)
  except TimeoutError:
    stderr.writeLine("Error: System 1 service timed out after " & $service.timeoutSeconds &
                     "s at " & endpoint & ". Service may be overloaded or hung.")
    quit(1)
  except CatchableError as e:
    stderr.writeLine("Error: System 1 service is unreachable at " & endpoint & " (" & e.msg & ").")
    stderr.writeLine("Start your System 1 service (Laya, Kev, Decider, Jev, or Ollama) before routing tasks.")
    quit(1)
  finally:
    client.close()

  try:
    let parsed = parseJson(respStr)
    if parsed.hasKey("answers"):
      return parsed["answers"]
    return parsed
  except CatchableError as e:
    stderr.writeLine("Error: Failed to parse System 1 response JSON: " & e.msg)
    stderr.writeLine("Raw response: " & respStr)
    quit(1)

# Backwards compatible alias for callSystemOne
proc callLayaSystemOne*(
  service: RoutingServiceConfig,
  stateText: string,
  questions: Table[string, QuestionConfig]
): JsonNode =
  callSystemOne(service, stateText, questions)

# Full end-to-end task routing pipeline
proc routeTask*(cfg: RoutingConfig, text: string): RoutingDecision =
  let chunks = splitIntoChunks(text, cfg.limits)
  var chunkResults: seq[JsonNode] = @[]

  for c in chunks:
    let ans = callSystemOne(cfg.service, c, cfg.questions)
    chunkResults.add(ans)

  let (aggAnswers, meta) = aggregateChunkAnswers(chunkResults, cfg.questions)
  return evaluateRules(cfg.routes, aggAnswers, meta)
