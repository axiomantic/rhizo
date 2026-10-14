# tests/test_routing_unit.nim
# Unit test suite for Rhizo native task routing engine and route config linter.

import std/[unittest, json, tables, os, strutils]
import ../src/routing

suite "Route Config Linter & Parser":
  test "valid configuration passes linting with 0 errors":
    let validYaml = """
version: "1.0"
service:
  url: "http://127.0.0.1:8100"
  timeout_seconds: 5.0
limits:
  overflow_strategy: "split_aggregate"
  chunk_size: 8000
  chunk_overlap: 800
  split_delimiter: "\n"
  max_chunks: 10
questions:
  domain:
    type: choice
    instructions: "Which technical domain does this task belong to?"
    options: ["database", "frontend", "api", "firmware"]
    aggregate: max_confidence
  urgency:
    type: score
    instructions: "How urgent is this fix?"
    criteria: ["low priority", "medium priority", "critical production outage"]
    aggregate: max
  needs_migration:
    type: noul
    instructions: "Does this require a database schema migration?"
    aggregate: any
routes:
  - name: "database-tasks"
    match:
      domain.choice: "database"
    target:
      queue: "queue:swarm:database"
      tags: ["database", "sql"]
      lease_seconds: 1800
  - name: "critical-incidents"
    match:
      urgency.score: { gte: 1.5 }
    target:
      queue: "queue:swarm:incidents"
      tags: ["urgent", "incident"]
      lease_seconds: 3600
  - name: "firmware-dedicated"
    match:
      domain.choice: "firmware"
    target:
      queue: "queue:worker:worker-claude"
      tags: ["firmware", "c"]
      lease_seconds: 2400
"""
    let (valid, errors, warnings) = lintYamlContent(validYaml, checkService = false)
    check valid == true
    check errors.len == 0

  test "linter rejects missing questions or empty routes":
    let badYaml = """
version: "1.0"
service:
  url: "http://127.0.0.1:8100"
"""
    let (valid, errors, warnings) = lintYamlContent(badYaml, checkService = false)
    check valid == false
    check errors.len > 0

  test "linter rejects invalid aggregation strategy for question type":
    let badAggYaml = """
version: "1.0"
questions:
  domain:
    type: choice
    instructions: "Which domain?"
    options: ["api", "db"]
    aggregate: max # Invalid for choice! Should be max_confidence or mean_prob
routes:
  - name: "default"
    match:
      domain.choice: "api"
    target:
      queue: "queue:swarm:api"
"""
    let (valid, errors, warnings) = lintYamlContent(badAggYaml, checkService = false)
    check valid == false
    var foundError = false
    for err in errors:
      if "Invalid aggregation" in err or "choice" in err:
        foundError = true
    check foundError == true

  test "linter rejects route matching undeclared question":
    let undeclaredYaml = """
version: "1.0"
questions:
  domain:
    type: choice
    instructions: "Which domain?"
    options: ["api", "db"]
routes:
  - name: "typo-rule"
    match:
      doman.choice: "api" # Typo: doman instead of domain
    target:
      queue: "queue:swarm:api"
"""
    let (valid, errors, warnings) = lintYamlContent(undeclaredYaml, checkService = false)
    check valid == false
    var foundError = false
    for err in errors:
      if "doman" in err and "undeclared" in err:
        foundError = true
    check foundError == true

  test "linter rejects choice value not present in question options":
    let badOptionYaml = """
version: "1.0"
questions:
  domain:
    type: choice
    instructions: "Which domain?"
    options: ["api", "db"]
routes:
  - name: "typo-option"
    match:
      domain.choice: "mobile" # Not in options!
    target:
      queue: "queue:swarm:mobile"
"""
    let (valid, errors, warnings) = lintYamlContent(badOptionYaml, checkService = false)
    check valid == false
    var foundError = false
    for err in errors:
      if "mobile" in err and "options" in err:
        foundError = true
    check foundError == true

suite "Chunking & Splitting":
  test "text under chunk_size returns single chunk":
    let limits = RoutingLimits(
      overflowStrategy: osSplitAggregate,
      chunkSize: 1000,
      chunkOverlap: 100,
      splitDelimiter: "\n",
      maxChunks: 10
    )
    let chunks = splitIntoChunks("Hello world short text", limits)
    check chunks.len == 1
    check chunks[0] == "Hello world short text"

  test "oversized text splits on newline boundaries":
    let limits = RoutingLimits(
      overflowStrategy: osSplitAggregate,
      chunkSize: 50,
      chunkOverlap: 10,
      splitDelimiter: "\n",
      maxChunks: 10
    )
    let text = "Line 1: Alpha beta gamma\nLine 2: Delta epsilon zeta\nLine 3: Eta theta iota\nLine 4: Kappa lambda mu"
    let chunks = splitIntoChunks(text, limits)
    check chunks.len > 1
    # Verify no chunk exceeds limits.chunkSize
    for c in chunks:
      check c.len <= limits.chunkSize + 10 # small margin if no newline found

  test "overflowStrategy fail_fast throws on oversized input":
    let limits = RoutingLimits(
      overflowStrategy: osFailFast,
      chunkSize: 20,
      chunkOverlap: 5,
      splitDelimiter: "\n",
      maxChunks: 10
    )
    expect(CatchableError):
      discard splitIntoChunks("This string is way longer than twenty characters", limits)

  test "exceeding max_chunks raises CatchableError":
    let limits = RoutingLimits(
      overflowStrategy: osSplitAggregate,
      chunkSize: 10,
      chunkOverlap: 2,
      splitDelimiter: "\n",
      maxChunks: 2
    )
    let text = "123456789\n123456789\n123456789\n123456789\n123456789"
    expect(CatchableError):
      discard splitIntoChunks(text, limits)

suite "Aggregation Engine":
  test "choice max_confidence picks chunk with highest confidence":
    var questions = initTable[string, QuestionConfig]()
    questions["domain"] = QuestionConfig(
      id: "domain",
      qType: "choice",
      choiceAgg: caMaxConfidence
    )
    let chunk1 = %*{
      "domain": {
        "choice": "api",
        "confidence": 0.40,
        "probabilities": {"api": 0.6, "database": 0.4}
      }
    }
    let chunk2 = %*{
      "domain": {
        "choice": "database",
        "confidence": 0.95,
        "probabilities": {"api": 0.05, "database": 0.95}
      }
    }
    let (agg, meta) = aggregateChunkAnswers(@[chunk1, chunk2], questions)
    check agg["domain"]["choice"].getStr() == "database"
    check agg["domain"]["confidence"].getFloat() == 0.95
    check meta["answers"]["domain"]["winning_chunk"].getInt() == 2

  test "score max picks maximum score across chunks":
    var questions = initTable[string, QuestionConfig]()
    questions["urgency"] = QuestionConfig(
      id: "urgency",
      qType: "score",
      scoreAgg: saMax
    )
    let chunk1 = %*{"urgency": {"score": 0.2}}
    let chunk2 = %*{"urgency": {"score": 1.9}}
    let chunk3 = %*{"urgency": {"score": 0.8}}
    let (agg, meta) = aggregateChunkAnswers(@[chunk1, chunk2, chunk3], questions)
    check agg["urgency"]["score"].getFloat() == 1.9

  test "noul any triggers true if any chunk triggers":
    var questions = initTable[string, QuestionConfig]()
    questions["needs_migration"] = QuestionConfig(
      id: "needs_migration",
      qType: "noul",
      noulAgg: naAny
    )
    let chunk1 = %*{"needs_migration": {"noul": 0.1}}
    let chunk2 = %*{"needs_migration": {"noul": 0.9}}
    let (agg, meta) = aggregateChunkAnswers(@[chunk1, chunk2], questions)
    check agg["needs_migration"]["noul"].getFloat() >= 0.5

suite "Rule Matching & Interpolation":
  test "matches rule by choice and interpolates queue name":
    var rule = RouteRule(
      name: "database-rule",
      conditions: @[
        MatchCondition(key: "domain.choice", operator: "eq", strValue: "database")
      ],
      target: RouteTarget(
        queue: "queue:swarm:{{ domain.choice }}",
        tags: @["sql", "{{ domain.choice }}"],
        leaseSeconds: 1800
      )
    )
    let answers = %*{
      "domain": {"choice": "database"}
    }
    let decision = evaluateRules(@[rule], answers, %*{})
    check decision.matchedRule == "database-rule"
    check decision.targetQueue == "queue:swarm:database"
    check "sql" in decision.tags
    check "database" in decision.tags

  test "matches rule by score threshold":
    var rule = RouteRule(
      name: "critical-incident",
      conditions: @[
        MatchCondition(key: "urgency.score", operator: "gte", floatValue: 1.5)
      ],
      target: RouteTarget(
        queue: "queue:swarm:incidents",
        tags: @["pager"],
        leaseSeconds: 3600
      )
    )
    let answers = %*{
      "urgency": {"score": 1.85}
    }
    let decision = evaluateRules(@[rule], answers, %*{})
    check decision.matchedRule == "critical-incident"
    check decision.targetQueue == "queue:swarm:incidents"

  test "fails fast when no rule matches":
    var rule = RouteRule(
      name: "frontend-only",
      conditions: @[
        MatchCondition(key: "domain.choice", operator: "eq", strValue: "frontend")
      ],
      target: RouteTarget(
        queue: "queue:swarm:frontend",
        tags: @["ui"],
        leaseSeconds: 1800
      )
    )
    let answers = %*{
      "domain": {"choice": "firmware"}
    }
    expect(CatchableError):
      discard evaluateRules(@[rule], answers, %*{})

suite "Local Route Config Overlays":
  test "mergeRoutingConfigs overlays service url, model, api key and prepends routes":
    let baseYaml = """
version: "1.0"
service:
  url: "http://127.0.0.1:8100"
  timeout_seconds: 5.0
questions:
  domain:
    type: choice
    instructions: "Which domain?"
    options: ["database", "api"]
routes:
  - name: "base-db"
    match:
      domain.choice: "database"
    target:
      queue: "queue:swarm:database"
"""
    let localYaml = """
service:
  url: "https://api.typesafe.ai"
  model: "jev-2"
  api_key: "jev-secret-xyz"
  timeout_seconds: 8.0
routes:
  - name: "local-override"
    match:
      domain.choice: "api"
    target:
      queue: "queue:worker:local-agent"
"""
    var baseCfg = parseRoutesConfig(baseYaml)
    let localCfg = parseRoutesConfig(localYaml)
    mergeRoutingConfigs(baseCfg, localCfg)

    check baseCfg.service.url == "https://api.typesafe.ai"
    check baseCfg.service.model == "jev-2"
    check baseCfg.service.apiKey == "jev-secret-xyz"
    check baseCfg.service.timeoutSeconds == 8.0
    check baseCfg.questions.hasKey("domain")
    check baseCfg.routes.len == 2
    check baseCfg.routes[0].name == "local-override"
    check baseCfg.routes[1].name == "base-db"

suite "Fallback & Hierarchical Overriding":
  test "defaultFallbackRoutingConfig provides domain, urgency and fallback swarm route":
    let def = defaultFallbackRoutingConfig()
    check def.questions.hasKey("domain")
    check def.questions.hasKey("urgency")
    check def.questions["domain"].options.len >= 5
    check def.routes.len == 1
    check def.routes[0].name == "default-domain-swarm"
    check def.routes[0].target.queue == "queue:swarm:{{ domain.choice }}"

  test "catch-all rule with empty match passes validation":
    let catchAllYaml = """
version: "1.0"
questions:
  domain:
    type: choice
    instructions: "Which domain?"
    options: ["frontend", "backend"]
routes:
  - name: "frontend-specific"
    match:
      domain.choice: "frontend"
    target:
      queue: "queue:swarm:frontend"
  - name: "all-other-tasks"
    match: {}
    target:
      queue: "queue:swarm:general"
"""
    let (valid, errors, warnings) = lintYamlContent(catchAllYaml, checkService = false)
    check valid == true
    check errors.len == 0

  test "findRoutesConfigChain discovers root and child configs in root-to-leaf order":
    let tmpBase = getTempDir() / "rhizo_chain_test_" & $getCurrentProcessId()
    let repoRoot = tmpBase / "myrepo"
    let subPkg = repoRoot / "packages" / "frontend"
    createDir(subPkg)
    createDir(repoRoot / ".git")

    writeFile(repoRoot / "rhizo-routes.yaml", "version: \"1.0\"\nquestions:\n  q1:\n    type: choice\n    instructions: \"?\"\n    options: [\"a\"]\nroutes:\n  - name: r1\n    match: { q1.choice: a }\n    target: { queue: q1 }\n")
    writeFile(subPkg / "rhizo-routes.yaml", "version: \"1.0\"\nquestions:\n  q2:\n    type: choice\n    instructions: \"?\"\n    options: [\"b\"]\nroutes:\n  - name: r2\n    match: { q2.choice: b }\n    target: { queue: q2 }\n")

    let chain = findRoutesConfigChain(subPkg)
    check chain.len == 2
    check chain[0] == repoRoot / "rhizo-routes.yaml"
    check chain[1] == subPkg / "rhizo-routes.yaml"

    # Clean up
    removeDir(tmpBase)


