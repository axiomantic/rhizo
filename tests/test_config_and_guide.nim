# /Users/eek/Development/rhizo/tests/test_config_and_guide.nim
# Consolidated in-process Nim test suite for CLI Help, Config Cascading, Guide Lifecycle,
# Atomic Name Reservation / Reset / Nuke, and Installer / Packaging Specifications.

import tripwire
import tripwire/plugins/osproc as nfos
import ./plugins/redis_tripwire
import std/[os, osproc, strutils, json, options, unittest]
import config, redis, guide, lexicon, rhizo
import ./test_helpers

let initialWorkingDir = getCurrentDir()
let testTmpRoot = getTempDir() / ("rhizo_cfg_guide_" & $getCurrentProcessId())
let testRedisUrl = getEnv("RHIZO_REDIS_URL", "redis://127.0.0.1:6379")
let testPrefix = "test_rhizo_cfg_" & $getCurrentProcessId() & ":"
var testSeq = 0

removeDir(testTmpRoot)
createDir(testTmpRoot)

proc nextTmpDir(name: string): string =
  inc testSeq
  result = testTmpRoot / (name & "_" & $testSeq)
  removeDir(result)
  createDir(result)

proc saveAndScrubRhizoEnv(fakeHome: string = ""): seq[tuple[k, v: string, present: bool]] =
  let keys = [
    "HOME", "USERPROFILE", "XDG_CONFIG_HOME", "APPDATA",
    "RHIZO_REDIS_URL", "RHIZO_VALKEY_URL", "REDIS_URL",
    "RHIZO_PREFIX", "RHIZO_REDIS_PREFIX", "RHIZO_PROJECT",
    "RHIZO_CONFIG", "RHIZO_PROFILE", "RHIZO_SECRET", "RHIZO_SECRET_FILE",
    "RHIZO_ENCRYPT", "RHIZO_CLUSTER", "RHIZO_HOSTNAME",
    "RHIZO_AGENT_NAME", "RHIZO_AGENT_ID", "RHIZO_SESSION_ID",
    "ANTIGRAVITY_CONVERSATION_ID", "OPENCODE_SESSION_ID", "PI_SESSION_ID",
    "CODEX_SESSION_ID", "CLAUDE_CONVERSATION_ID", "CLAUDE_SESSION_ID"
  ]
  for k in keys:
    result.add((k, getEnv(k, ""), existsEnv(k)))
    if k.startsWith("RHIZO_") or k in ["ANTIGRAVITY_CONVERSATION_ID", "OPENCODE_SESSION_ID", "PI_SESSION_ID", "CODEX_SESSION_ID", "CLAUDE_CONVERSATION_ID", "CLAUDE_SESSION_ID"]:
      if k notin ["RHIZO_EAR_DISABLED", "RHIZO_TEST"]:
        delEnv(k)
  if fakeHome.len > 0:
    putEnv("HOME", fakeHome)
    putEnv("USERPROFILE", fakeHome)
    putEnv("XDG_CONFIG_HOME", fakeHome)
    putEnv("APPDATA", fakeHome)

proc restoreEnv(saved: seq[tuple[k, v: string, present: bool]]) =
  for item in saved:
    if item.present: putEnv(item.k, item.v)
    else: delEnv(item.k)

suite "Rhizo CLI Help & Subcommand Usage Suite":

  teardown:
    try: setCurrentDir(initialWorkingDir) except CatchableError: discard

  test "top-level --help, -h, help print usage":
    for flag in ["--help", "-h", "help"]:
      let r = runRhizoInProcess([flag])
      check r.code == 0
      check r.outStr.contains("Rhizo")
      check r.outStr.contains("Usage:")
      check r.outStr.contains("rhizo listen")

  test "listen --help and -h variants never block or touch Redis":
    let cases = [
      @["listen", "--help"],
      @["listen", "-h"],
      @["listen", "mock-agent-xyz", "--help"],
      @["listen", "mock-agent-xyz", "-h"],
      @["help", "listen"],
      @["--help", "listen"]
    ]
    for args in cases:
      let r = runRhizoInProcess(args)
      check r.code == 0
      check r.outStr.contains("Usage: rhizo listen")
    let rFull = runRhizoInProcess(["listen", "--help"])
    check rFull.outStr.contains("--timeout")
    check rFull.outStr.contains("--continuous")

  test "messaging, queue, lock, inspection, and coordination subcommands --help/-h":
    for subcmd in ["send", "reply", "broadcast", "request", "scatter",
                   "open", "claim", "work", "lock", "unlock", "ack", "enqueue",
                   "who", "probe", "watchdog", "leader", "status", "ping", "session",
                   "blackboard", "floor", "ballot", "workflow", "pulse", "cancel", "task", "decision", "audit"]:
      let r1 = runRhizoInProcess([subcmd, "--help"])
      check r1.code == 0
      check (r1.outStr.contains("Usage: rhizo " & subcmd) or r1.outStr.contains("Usage:\n  rhizo " & subcmd))
      let r2 = runRhizoInProcess([subcmd, "-h"])
      check r2.code == 0
      check (r2.outStr.contains("Usage: rhizo " & subcmd) or r2.outStr.contains("Usage:\n  rhizo " & subcmd))

    let rClaimRenew = runRhizoInProcess(["claim", "renew", "--help"])
    check rClaimRenew.code == 0
    check rClaimRenew.outStr.contains("Usage: rhizo claim renew")

    let rRouteSetup = runRhizoInProcess(["route", "setup", "--help"])
    check rRouteSetup.code == 0
    check rRouteSetup.outStr.contains("Usage: rhizo route setup")

    let rPersist = runRhizoInProcess(["config", "redis-persistence", "--help"])
    check rPersist.code == 0
    check rPersist.outStr.contains("Usage: rhizo config redis-persistence")

  test "help never touches Redis even with unreachable endpoint":
    let saved = saveAndScrubRhizoEnv()
    defer: restoreEnv(saved)
    putEnv("RHIZO_REDIS_URL", "redis://127.0.0.1:59999")
    for subcmd in ["listen", "who", "lock", "unlock", "claim", "work", "probe", "watchdog"]:
      let r = runRhizoInProcess([subcmd, "--help"])
      check r.code == 0
      check (r.outStr.contains("Usage: rhizo " & subcmd) or r.outStr.contains("Usage:\n  rhizo " & subcmd))

  test "unknown subcommand exits 1 with diagnostic":
    let r = runRhizoInProcess(["nonexistent-subcommand-xyz", "--help"])
    check r.code == 1
    check (r.errStr.contains("Error: Unknown subcommand") or r.outStr.contains("Unknown subcommand"))

suite "Rhizo Tiered Configuration & Dotenv Cascading Suite":

  teardown:
    try: setCurrentDir(initialWorkingDir) except CatchableError: discard

  test "config defaults in isolated workspace":
    let tmpDir = nextTmpDir("cfg_defaults")
    let saved = saveAndScrubRhizoEnv(tmpDir)
    defer:
      try: setCurrentDir(initialWorkingDir) except CatchableError: discard
      restoreEnv(saved)
      removeDir(tmpDir)
    setCurrentDir(tmpDir)
    let r = runRhizoInProcess(["config", "show", "--format", "json"])
    check r.code == 0
    let data = parseJson(r.outStr)
    check data["redis_url"]["value"].getStr() == "redis://127.0.0.1:6379"
    check data["prefix"]["value"].getStr() == "rhizo:"
    check data["heartbeat_ttl"]["value"].getStr() == "150"
    check data["listen_timeout"]["value"].getStr() == "0"
    check data["message_ttl"]["value"].getStr() == "604800"

  test "config reads rhizo.toml and [profiles.staging]":
    let tmpDir = nextTmpDir("cfg_toml")
    let saved = saveAndScrubRhizoEnv(tmpDir)
    defer:
      restoreEnv(saved)
      removeDir(tmpDir)
    let tomlPath = tmpDir / "rhizo.toml"
    writeFile(tomlPath, """# rhizo.toml
redis_url = "redis://redis.internal:6379"
prefix = "mycustom:"
project = "custom-project"
encrypt = true
heartbeat_ttl = 120

[profiles.staging]
redis_url = "rediss://staging.internal:6380"
prefix = "stg:rhizo:"
""")
    let r1 = runRhizoInProcess(["config", "show", "--config", tomlPath, "--format", "json"])
    check r1.code == 0
    let d1 = parseJson(r1.outStr)
    check d1["redis_url"]["value"].getStr() == "redis://redis.internal:6379"
    check d1["prefix"]["value"].getStr() == "mycustom:"
    check d1["project"]["value"].getStr() == "custom-project"
    check d1["encrypt"]["value"].getStr() == "true"
    check d1["heartbeat_ttl"]["value"].getStr() == "120"

    let r2 = runRhizoInProcess(["config", "show", "--config", tomlPath, "--profile", "staging", "--format", "json"])
    check r2.code == 0
    let d2 = parseJson(r2.outStr)
    check d2["redis_url"]["value"].getStr() == "rediss://staging.internal:6380"
    check d2["prefix"]["value"].getStr() == "stg:rhizo:"

  test "config CLI overrides take precedence":
    let saved = saveAndScrubRhizoEnv()
    defer: restoreEnv(saved)
    let r = runRhizoInProcess([
      "config", "show", "--redis-url", "redis://cli-override:6379",
      "--prefix", "cli:", "--project", "test-project", "--format", "json"
    ])
    check r.code == 0
    let d = parseJson(r.outStr)
    check d["redis_url"]["value"].getStr() == "redis://cli-override:6379"
    check d["prefix"]["value"].getStr() == "cli:"
    check d["project"]["value"].getStr() == "test-project"
    check d["redis_url"]["source"].getStr() == "cli flag"

  test "config .env, .env.local, process env, and .rhizo.local.toml layering":
    let tmpDir = nextTmpDir("cfg_layers")
    let saved = saveAndScrubRhizoEnv(tmpDir)
    defer:
      try: setCurrentDir(initialWorkingDir) except CatchableError: discard
      restoreEnv(saved)
      removeDir(tmpDir)
    setCurrentDir(tmpDir)

    writeFile(tmpDir / ".env", "RHIZO_PROJECT=base-project\nRHIZO_REDIS_URL=\"redis://base.internal:6379\"\nexport RHIZO_PREFIX=\"env_pfx:\"\n")
    let r1 = runRhizoInProcess(["config", "show", "--format", "json"])
    check r1.code == 0
    let d1 = parseJson(r1.outStr)
    check d1["project"]["value"].getStr() == "base-project"
    check d1["redis_url"]["value"].getStr() == "redis://base.internal:6379"
    check d1["prefix"]["value"].getStr() == "env_pfx:"

    writeFile(tmpDir / ".env.local", "RHIZO_REDIS_URL=redis://local-override.internal:6379\n")
    delEnv("RHIZO_PROJECT")
    delEnv("RHIZO_REDIS_URL")
    delEnv("RHIZO_PREFIX")
    let r2 = runRhizoInProcess(["config", "show", "--format", "json"])
    check r2.code == 0
    let d2 = parseJson(r2.outStr)
    check d2["project"]["value"].getStr() == "base-project"
    check d2["redis_url"]["value"].getStr() == "redis://local-override.internal:6379"

    delEnv("RHIZO_PROJECT")
    delEnv("RHIZO_REDIS_URL")
    delEnv("RHIZO_PREFIX")
    putEnv("RHIZO_PROJECT", "process-env-project")
    let r3 = runRhizoInProcess(["config", "show", "--format", "json"])
    check r3.code == 0
    check parseJson(r3.outStr)["project"]["value"].getStr() == "process-env-project"
    delEnv("RHIZO_PROJECT")
    delEnv("RHIZO_REDIS_URL")
    delEnv("RHIZO_PREFIX")

    removeFile(tmpDir / ".env")
    removeFile(tmpDir / ".env.local")
    writeFile(tmpDir / ".rhizo.toml", "project = \"base-team-project\"\nprefix = \"team:\"\nencrypt = true\n")
    writeFile(tmpDir / ".rhizo.local.toml", "redis_url = \"redis://my-dev-box:6379\"\nprefix = \"my-dev:\"\n")
    let r4 = runRhizoInProcess(["config", "show", "--format", "json"])
    check r4.code == 0
    let d4 = parseJson(r4.outStr)
    check d4["project"]["value"].getStr() == "base-team-project"
    check d4["encrypt"]["value"].getStr() == "true"
    check d4["project"]["source"].getStr() == "workspace config"
    check d4["redis_url"]["value"].getStr() == "redis://my-dev-box:6379"
    check d4["prefix"]["value"].getStr() == "my-dev:"
    check d4["redis_url"]["source"].getStr() == "local workspace config"

  test "RHIZO_* environment variables and config get/path/init":
    let tmpDir = nextTmpDir("cfg_env")
    let saved = saveAndScrubRhizoEnv(tmpDir)
    defer:
      try: setCurrentDir(initialWorkingDir) except CatchableError: discard
      restoreEnv(saved)
      removeDir(tmpDir)
    let customCfg = tmpDir / "custom.toml"
    writeFile(customCfg, "project = \"custom-env-project\"\nprefix = \"custom-env:\"\n")
    putEnv("RHIZO_CONFIG", customCfg)
    putEnv("RHIZO_REDIS_URL", "redis://rhizo-env-redis:6379")
    putEnv("RHIZO_HOSTNAME", "rhizo-test-host")
    putEnv("RHIZO_AGENT_NAME", "test-prefixed-agent")

    let rShow = runRhizoInProcess(["config", "show", "--format", "json"])
    check rShow.code == 0
    let d = parseJson(rShow.outStr)
    check d["project"]["value"].getStr() == "custom-env-project"
    check d["redis_url"]["value"].getStr() == "redis://rhizo-env-redis:6379"
    check d["agent_name"]["value"].getStr() == "test-prefixed-agent"

    let rGet = runRhizoInProcess(["config", "get", "prefix"])
    check rGet.code == 0
    check rGet.outStr.strip() == "custom-env:"

    let rGetBad = runRhizoInProcess(["config", "get", "nonexistent_key"])
    check rGetBad.code == 1

    let rPath = runRhizoInProcess(["config", "path"])
    check rPath.code == 0
    check rPath.outStr.contains("Workspace config")

    delEnv("RHIZO_CONFIG")
    setCurrentDir(tmpDir)
    let rInit = runRhizoInProcess(["config", "init"])
    check rInit.code == 0
    check (fileExists(tmpDir / ".rhizo.toml") or fileExists(tmpDir / "rhizo.toml"))

suite "Rhizo Guide Lifecycle Suite":

  test "guide install, update in-place, uninstall, malformed fail-safe, check, and Section 8 invariants":
    let tmpDir = nextTmpDir("guide")
    defer: removeDir(tmpDir)
    let target = tmpDir / "AGENTS.md"

    # Check missing
    let rChk1 = runRhizoInProcess(["guide", "check", target])
    check rChk1.code == 0
    check rChk1.outStr.contains("[MISSING]")

    # Install new file
    let rInst = runRhizoInProcess(["guide", "install", target])
    check rInst.code == 0
    check rInst.outStr.contains("Created")
    let c1 = readFile(target)
    check c1.contains("<!-- BEGIN RHIZO GUIDE [v2.0] -->")
    check c1.contains("<!-- END RHIZO GUIDE -->")
    check c1.contains("Rhizo Multi-Agent Coordination Guide")
    check c1.contains("Single-Orchestrator Mutual Exclusion via Leader Leases")
    check c1.contains("Deprecation of Aliases in Favor of Sovereign Handles & Capability Tags")
    check c1.contains("### 8. Orchestrator Non-Implementation & Intake Gate")
    check c1.contains("Pre-Authorized Directives & Active Fleet Fast-Path")
    check c1.contains("Mandatory ask_question Tool Discipline")
    check c1.contains("Project-Scoped Fleet Mandate")
    check c1.contains("Dumping numbered multiple-choice lists (1, 2, 3) in raw chat text is STRICTLY PROHIBITED")
    check not c1.contains("garden-swarm.json")
    check not c1.contains("<project>-orchestrator")

    # Check installed
    let rChk2 = runRhizoInProcess(["guide", "check", target])
    check rChk2.code == 0
    check rChk2.outStr.contains("[INSTALLED]")

    # Preserve custom content and update in place
    let header = "# Custom Header\n\nKeep this text intact!\n\n"
    let oldBlock = "<!-- BEGIN RHIZO GUIDE [v1.0] -->\nOld outdated guide body.\n<!-- END RHIZO GUIDE -->\n"
    let footer = "\n\n# Custom Footer\nKeep this footer intact too!\n"
    writeFile(target, header & oldBlock & footer)
    let rUpd = runRhizoInProcess(["guide", "install", target])
    check rUpd.code == 0
    check rUpd.outStr.contains("Updated")
    let c2 = readFile(target)
    check c2.contains("Keep this text intact!")
    check c2.contains("Keep this footer intact too!")
    check not c2.contains("Old outdated guide body")
    check c2.contains("<!-- BEGIN RHIZO GUIDE [v2.0] -->")

    # Uninstall preserves custom notes
    let rUninst = runRhizoInProcess(["guide", "uninstall", target])
    check rUninst.code == 0
    check rUninst.outStr.contains("Successfully uninstalled")
    let c3 = readFile(target)
    check c3.contains("Keep this text intact!")
    check not c3.contains("BEGIN RHIZO GUIDE")
    check not c3.contains("END RHIZO GUIDE")

    let rChk3 = runRhizoInProcess(["guide", "check", target])
    check rChk3.code == 0
    check rChk3.outStr.contains("[NOT FOUND]")

    # Malformed marker fail-safe
    let corrupted = "# Notes\n\n<!-- BEGIN RHIZO GUIDE [v1.0] -->\nAccidentally missing end marker!\n"
    writeFile(target, corrupted)
    let rBadInst = runRhizoInProcess(["guide", "install", target])
    check rBadInst.code != 0
    check rBadInst.combined.contains("Malformed")
    check readFile(target) == corrupted

    let rBadUninst = runRhizoInProcess(["guide", "uninstall", target])
    check rBadUninst.code != 0
    check rBadUninst.combined.contains("Malformed")
    check readFile(target) == corrupted

suite "Rhizo Atomic Name Reservation, Open, Reset & Nuke Suite":

  setup:
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  teardown:
    cleanupRedisPrefix(testRedisUrl, testPrefix)

  test "name allocation, TTL reservation, collision avoidance, open cleanup, nuke, and project-scoped reset":
    sandbox:
      allow(redisPluginInstance)
      allow(nfos.osprocPluginInstance)
      let tmpHome = nextTmpDir("name_home")
      let saved = saveAndScrubRhizoEnv(tmpHome)
      setCurrentDir(tmpHome)
      defer:
        try: setCurrentDir(initialWorkingDir) except CatchableError: discard
        restoreEnv(saved)
        removeDir(tmpHome)

      var r = openRedisClient(testRedisUrl)
      defer: (try: r.close() except CatchableError: discard)

      # 1. Basic name reservation
      let r1 = runRhizoInProcess(["--prefix", testPrefix, "--redis-url", testRedisUrl, "name"])
      check r1.code == 0
      let name1 = r1.outStr.strip()
      check name1.len > 0
      let heldKey1 = testPrefix & "held_name:" & name1
      check r.get(heldKey1) == "1"
      let ttl1 = r.ttl(heldKey1)
      check ttl1 > 550 and ttl1 <= 600

      # 2. Custom prefix, TTL, and JSON output
      let r2 = runRhizoInProcess(["--prefix", testPrefix, "--redis-url", testRedisUrl, "name", "myproj", "--ttl", "300", "--json"])
      check r2.code == 0
      let j2 = parseJson(r2.outStr.strip())
      check j2["name"].getStr().startsWith("myproj-")
      check j2["prefix"].getStr() == "myproj"
      check j2["ttl"].getInt() == 300
      check j2["held"].getBool() == true
      check j2["name"].getStr() == "myproj-" & j2["codename"].getStr()
      let ttl2 = r.ttl(testPrefix & "held_name:" & j2["name"].getStr())
      check ttl2 > 250 and ttl2 <= 300

      # 3. Collision-free 5x allocation
      var seenNames: seq[string] = @[]
      for _ in 0 ..< 5:
        let rBatch = runRhizoInProcess(["--prefix", testPrefix, "--redis-url", testRedisUrl, "name", "batch"])
        check rBatch.code == 0
        let bn = rBatch.outStr.strip()
        check bn notin seenNames
        seenNames.add(bn)
        check r.get(testPrefix & "held_name:" & bn) == "1"

      # 4. open clears held_name and activates agent
      let rOpenPrep = runRhizoInProcess(["--prefix", testPrefix, "--redis-url", testRedisUrl, "name", "openproc"])
      check rOpenPrep.code == 0
      let openName = rOpenPrep.outStr.strip()
      check r.get(testPrefix & "held_name:" & openName) == "1"

      let rOpen = runRhizoInProcess(["--prefix", testPrefix, "--redis-url", testRedisUrl, "open", openName, "worker"])
      check rOpen.code == 0
      check r.get(testPrefix & "held_name:" & openName) == redisNil
      check r.sismember(testPrefix & "active_agents", openName) == 1
      check r.get(testPrefix & "heartbeat:" & openName) == "1"

      # 5. Bare open fails fast without identity (in fresh nuked session state)
      check runRhizoInProcess(["--prefix", testPrefix, "--redis-url", testRedisUrl, "nuke"]).code == 0
      let rBare = runRhizoInProcess(["--prefix", testPrefix, "--redis-url", testRedisUrl, "open"])
      check rBare.code == 1
      check rBare.errStr.contains("No agent name specified")

      # 6. Nuke clears reserved/active keys
      discard runRhizoInProcess(["--prefix", testPrefix, "--redis-url", testRedisUrl, "open", openName, "worker"])
      let rNuke = runRhizoInProcess(["--prefix", testPrefix, "--redis-url", testRedisUrl, "nuke", "--json"])
      check rNuke.code == 0
      let jNuke = parseJson(rNuke.outStr.strip())
      check jNuke["status"].getStr() == "ok"
      check jNuke["mode"].getStr() == "nuke"
      check jNuke["deleted_keys"].getInt() > 0
      check r.keys(testPrefix & "*").len == 0

      # 7. open --session-id auto-assigns lexicon name
      let rSes = runRhizoInProcess(["--prefix", testPrefix, "--redis-url", testRedisUrl, "open", "--session-id", "test_ses_auto"])
      check rSes.code == 0
      check rSes.outStr.contains("Registered Successfully")
      let active = r.sMembers(testPrefix & "active_agents")
      check active.len == 1
      check r.get(testPrefix & "heartbeat:" & active[0]) == "1"

      # 8. Project-scoped reset vs --all
      discard runRhizoInProcess(["--prefix", testPrefix, "--redis-url", testRedisUrl, "nuke"])
      check runRhizoInProcess(["--prefix", testPrefix, "--redis-url", testRedisUrl, "--project", "alpha_proj", "open", "alpha_agent", "worker"]).code == 0
      check runRhizoInProcess(["--prefix", testPrefix, "--redis-url", testRedisUrl, "--project", "beta_proj", "open", "beta_agent", "worker"]).code == 0
      let rRst = runRhizoInProcess(["--prefix", testPrefix, "--redis-url", testRedisUrl, "reset", "alpha_proj", "--json"])
      check rRst.code == 0
      let jRst = parseJson(rRst.outStr.strip())
      check jRst["status"].getStr() == "ok"
      var closedAlpha = false
      var closedBeta = false
      for c in jRst["closed_agents"]:
        if c.getStr() == "alpha_agent": closedAlpha = true
        if c.getStr() == "beta_agent": closedBeta = true
      check closedAlpha
      check not closedBeta
      check r.sismember(testPrefix & "active_agents", "beta_agent") == 1

      let rRstAll = runRhizoInProcess(["--prefix", testPrefix, "--redis-url", testRedisUrl, "reset", "--all", "--json"])
      check rRstAll.code == 0
      check r.keys(testPrefix & "*").len == 0

suite "Rhizo Installer & Packaging Spec Verification Suite":

  test "SKILL.md, skills/rhizo/SKILL.md, wire_spec.md, scripts, scoop, homebrew, and release workflow specs":
    let pkgJson = parseJson(readFile(initialWorkingDir / "package.json"))
    let curVer = pkgJson["version"].getStr()
    check curVer.len > 0

    let rootSkill = readFile(initialWorkingDir / "SKILL.md").replace("\r\n", "\n")
    let pkgSkill = readFile(initialWorkingDir / "skills" / "rhizo" / "SKILL.md").replace("\r\n", "\n")
    check rootSkill.len > 0
    check pkgSkill.startsWith("---\n")
    check pkgSkill.contains("name: rhizo")
    check pkgSkill.contains("description:")
    check fileExists(initialWorkingDir / "skills" / "rhizo" / "references" / "wire_spec.md")

    let installSh = initialWorkingDir / "scripts" / "install.sh"
    let installPs1 = initialWorkingDir / "scripts" / "install.ps1"
    check fileExists(installSh)
    check fileExists(installPs1)
    let psContent = readFile(installPs1)
    check psContent.contains("param(")
    check psContent.contains("ErrorActionPreference")

    let scoop = parseJson(readFile(initialWorkingDir / "packaging" / "scoop" / "rhizo.json"))
    check scoop["version"].getStr() == curVer
    check scoop["architecture"].hasKey("64bit")

    let formula = readFile(initialWorkingDir / "Formula" / "rhizo.rb")
    check formula.contains("class Rhizo < Formula")
    check formula.contains("version \"" & curVer & "\"")
    check formula.contains("license \"MIT\"")
    check formula.contains("on_macos do")
    check formula.contains("on_linux do")
    for tb in ["rhizo-darwin-arm64.tar.gz", "rhizo-darwin-amd64.tar.gz", "rhizo-linux-arm64.tar.gz", "rhizo-linux-amd64.tar.gz"]:
      check formula.contains(tb)
    check formula.contains("#{opt_pkgshare}/skills/rhizo")
    check formula.contains("test do")

    let releaseYml = readFile(initialWorkingDir / ".github" / "workflows" / "release.yml")
    check releaseYml.contains("publish-release")
    check releaseYml.contains("skills")

    removeDir(testTmpRoot)
