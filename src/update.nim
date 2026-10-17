# /Users/eek/Development/garden/src/update.nim
# Shared Triad Update Checker & Prompt Rider for Garden, Rhizo, and Vine.
# Manages ~/.config/axiomantic/updates.json with 24-hour check cadence,
# install mechanism auto-detection (Dev/Symlink, Local npm, pnpm, yarn, brew, Global npm),
# autonomous mode exemption, version skipping, and AI prompt riders.

import std/[os, osproc, strutils, json, times]

const
  TriadPackages* = ["garden", "rhizo", "vine"]
  CheckCadenceSeconds* = 86400 # 24 hours

type
  InstallKind* = enum
    ikDevSource = "dev_source"
    ikLocalNpm = "local_npm"
    ikGlobalPnpm = "global_pnpm"
    ikGlobalYarn = "global_yarn"
    ikGlobalBun = "global_bun"
    ikHomebrew = "homebrew"
    ikStandaloneBinary = "standalone_binary"
    ikGlobalNpm = "global_npm"

proc getAxiomanticConfigDir*(): string =
  result = getHomeDir() / ".config" / "axiomantic"

proc getUpdatesFilePath*(): string =
  result = getAxiomanticConfigDir() / "updates.json"

proc parseSemverParts*(vStr: string): tuple[major, minor, patch: int] =
  result = (0, 0, 0)
  var clean = vStr.strip()
  if clean.startsWith("v") or clean.startsWith("V"):
    clean = clean[1..^1]
  let parts = clean.split('.')
  if parts.len > 0:
    try: result.major = parseInt(parts[0])
    except CatchableError: discard
  if parts.len > 1:
    try: result.minor = parseInt(parts[1])
    except CatchableError: discard
  if parts.len > 2:
    let p = parts[2].split('-')[0]
    try: result.patch = parseInt(p)
    except CatchableError: discard

proc isNewerSemver*(remoteVer, localVer: string): bool =
  let r = parseSemverParts(remoteVer)
  let l = parseSemverParts(localVer)
  if r.major > l.major: return true
  if r.major < l.major: return false
  if r.minor > l.minor: return true
  if r.minor < l.minor: return false
  return r.patch > l.patch

proc detectInstallKind*(binName: string): tuple[kind: InstallKind, realPath: string, updateCommand: string] =
  let (whichOut, whichCode) = try: execCmdEx("which " & binName) except CatchableError: ("", 1)
  if whichCode != 0 or whichOut.strip().len == 0:
    return (ikGlobalNpm, "", "npm install -g @axiomantic/" & binName)

  let rawPath = whichOut.strip()
  var realPath = rawPath
  try:
    if symlinkExists(rawPath):
      realPath = expandSymlink(rawPath)
  except CatchableError: discard

  # Check 1: Dev source checkout
  let parentDir = realPath.parentDir()
  let grandParentDir = parentDir.parentDir()
  if fileExists(parentDir / (binName & ".nimble")) or dirExists(parentDir / ".git") or
     fileExists(grandParentDir / (binName & ".nimble")) or dirExists(grandParentDir / ".git"):
    let repoDir = if fileExists(grandParentDir / (binName & ".nimble")): grandParentDir else: parentDir
    return (ikDevSource, realPath, "git -C " & quoteShell(repoDir) & " pull && (cd " & quoteShell(repoDir) & " && nimble build -d:release)")

  # Check 2: Local node_modules
  if "node_modules/.bin" in rawPath or "node_modules/@axiomantic" in realPath:
    if fileExists("pnpm-lock.yaml"):
      return (ikLocalNpm, realPath, "pnpm update @axiomantic/" & binName)
    elif fileExists("yarn.lock"):
      return (ikLocalNpm, realPath, "yarn upgrade @axiomantic/" & binName)
    elif fileExists("bun.lock") or fileExists("bun.lockb"):
      return (ikLocalNpm, realPath, "bun update @axiomantic/" & binName)
    else:
      return (ikLocalNpm, realPath, "npm update @axiomantic/" & binName)

  # Check 3: Homebrew
  if "/Cellar/" in realPath or ("/opt/homebrew/" in rawPath and not ("node_modules" in realPath)):
    return (ikHomebrew, realPath, "brew upgrade " & binName)

  # Check 4: Global alternative package managers
  if "pnpm" in rawPath or "pnpm" in realPath:
    return (ikGlobalPnpm, realPath, "pnpm add -g @axiomantic/" & binName)
  if "yarn" in rawPath or "yarn" in realPath:
    return (ikGlobalYarn, realPath, "yarn global add @axiomantic/" & binName)
  if "bun" in rawPath or "bun" in realPath:
    return (ikGlobalBun, realPath, "bun add -g @axiomantic/" & binName)

  # Check 5: Standalone binary in ~/.local/bin
  if rawPath.startsWith(getHomeDir() / ".local/bin"):
    return (ikStandaloneBinary, realPath, "npm install -g @axiomantic/" & binName)

  # Default: Global npm
  return (ikGlobalNpm, realPath, "npm install -g @axiomantic/" & binName)

proc installKindLabel*(kind: InstallKind, realPath: string): string =
  case kind
  of ikDevSource: "Dev Repo (" & realPath.parentDir().parentDir() & ")"
  of ikLocalNpm: "Local npm (node_modules)"
  of ikGlobalPnpm: "Global pnpm"
  of ikGlobalYarn: "Global yarn"
  of ikGlobalBun: "Global bun"
  of ikHomebrew: "Homebrew"
  of ikStandaloneBinary: "Binary (~/.local/bin)"
  of ikGlobalNpm: "Global npm"

proc loadUpdatesConfig*(): JsonNode =
  let path = getUpdatesFilePath()
  if fileExists(path):
    try:
      return parseJson(readFile(path))
    except CatchableError:
      discard

  result = %*{
    "last_checked_at": 0,
    "settings": {
      "update_check": "daily",
      "prompt_rider": true,
      "ignored_versions": {
        "garden": "",
        "rhizo": "",
        "vine": ""
      }
    },
    "cached": {}
  }

proc saveUpdatesConfig*(config: JsonNode) =
  let dir = getAxiomanticConfigDir()
  if not dirExists(dir):
    createDir(dir)
  try:
    writeFile(getUpdatesFilePath(), pretty(config))
  except CatchableError:
    discard

proc getInstalledVersion*(pkg: string, callerVer: string = "", callerPkg: string = ""): string =
  if (pkg == callerPkg or (callerPkg.len == 0 and (pkg == "vine" or pkg == "garden" or pkg == "rhizo"))) and callerVer.len > 0:
    return callerVer

  let binCmd = pkg & " --version"
  let (outp, code) = try: execCmdEx(binCmd) except CatchableError: ("", 1)
  if code == 0 and outp.len > 0:
    for token in outp.splitWhitespace():
      var t = token.strip()
      if t.startsWith("v") or t.startsWith("V"): t = t[1..^1]
      let parts = t.split('.')
      if parts.len >= 2:
        try:
          discard parseInt(parts[0])
          return t
        except CatchableError: discard
  return ""

proc fetchRemoteVersion*(pkg: string): string =
  let url = "https://registry.npmjs.org/@axiomantic/" & pkg & "/latest"
  let (outp, code) = try:
    execCmdEx("curl -s --max-time 1.5 " & quoteShell(url))
  except CatchableError: ("", 1)

  if code == 0 and outp.len > 0:
    try:
      let parsed = parseJson(outp)
      if parsed.hasKey("version"):
        return parsed["version"].getStr().strip()
    except CatchableError: discard

  let (nOut, nCode) = try:
    execCmdEx("npm view @axiomantic/" & pkg & " version")
  except CatchableError: ("", 1)
  if nCode == 0 and nOut.len > 0:
    return nOut.strip()

  return ""

proc checkTriadUpdates*(
  callerVer: string = "",
  callerPkg: string = "",
  force: bool = false
): JsonNode =
  var config = loadUpdatesConfig()
  let settings = if config.hasKey("settings"): config["settings"] else: newJObject()
  let updateCheck = settings{"update_check"}.getStr("daily")

  if updateCheck == "never" and not force:
    return config

  let nowSec = getTime().toUnix()
  let lastChecked = config{"last_checked_at"}.getBiggestInt(0)

  if not force and updateCheck == "daily" and (nowSec - lastChecked) < CheckCadenceSeconds:
    return config

  var cached = newJObject()
  var updatesAvailable = false

  for pkg in TriadPackages:
    let installed = if pkg == callerPkg and callerVer.len > 0: callerVer
                    else: getInstalledVersion(pkg, callerVer, callerPkg)
    let latest = fetchRemoteVersion(pkg)
    let effectiveLatest = if latest.len > 0: latest else: installed
    let hasUpdate = if installed.len > 0 and effectiveLatest.len > 0:
                      isNewerSemver(effectiveLatest, installed)
                    else: false

    let installInfo = detectInstallKind(pkg)

    if hasUpdate:
      updatesAvailable = true

    cached[pkg] = %*{
      "installed": installed,
      "latest": effectiveLatest,
      "has_update": hasUpdate,
      "install_kind": $installInfo.kind,
      "real_path": installInfo.realPath,
      "update_command": installInfo.updateCommand
    }

  config["last_checked_at"] = %nowSec
  config["cached"] = cached
  config["updates_available"] = %updatesAvailable
  saveUpdatesConfig(config)
  return config

proc isAutonomousModeActive*(): bool =
  let envVal = getEnv("AUTONOMOUS_MODE", "").toLowerAscii()
  if envVal in ["1", "true", "yes", "on"]: return true
  if fileExists(getCurrentDir() / ".autonomous"): return true
  return false

proc getUpdatePromptRider*(callerVer: string = "", callerPkg: string = ""): string =
  if isAutonomousModeActive():
    return ""

  let config = checkTriadUpdates(callerVer, callerPkg, force = false)
  let settings = config{"settings"}
  if settings != nil and not settings{"prompt_rider"}.getBool(true):
    return ""

  let ignoredMap = if settings != nil and settings.hasKey("ignored_versions"):
                     settings["ignored_versions"]
                   else: newJObject()

  let cached = config{"cached"}
  if cached == nil: return ""

  var updateList: seq[tuple[pkg, inst, latest, kind, updateCmd: string]] = @[]

  for pkg in TriadPackages:
    if cached.hasKey(pkg):
      let item = cached[pkg]
      if item{"has_update"}.getBool(false):
        let inst = item{"installed"}.getStr()
        let latest = item{"latest"}.getStr()
        let kind = item{"install_kind"}.getStr("global_npm")
        let updateCmd = item{"update_command"}.getStr("")
        let ignored = if ignoredMap != nil and ignoredMap.hasKey(pkg): ignoredMap[pkg].getStr() else: ""
        if ignored != latest:
          updateList.add((pkg, inst, latest, kind, updateCmd))

  if updateList.len == 0:
    return ""

  var sb: seq[string] = @[]
  sb.add("<!-- TRIAD_UPDATE_RIDER: START -->")
  sb.add("> [!TIP]")
  sb.add("> ## 📦 Axiomantic Triad Update Available")
  sb.add("> Newer versions are available for your installation:")
  for u in updateList:
    let label = if u.kind == $ikDevSource: " (Local Dev Checkout)" else: ""
    sb.add("> - **" & u.pkg & "**" & label & ": " & u.inst & " ➔ " & u.latest)
  sb.add(">")
  sb.add("> **Recommended Update Actions (Auto-Detected):**")
  for u in updateList:
    sb.add("> - `" & u.updateCmd & "`")
  sb.add(">")
  sb.add("> **Instructions for AI Assistant:**")
  sb.add("> 1. If in **Autonomous Mode** or executing background tasks: Do NOT interrupt the operator. Proceed silently.")
  sb.add("> 2. If interactive: Ask operator if they would like to run the recommended update command above.")
  sb.add("> 3. If operator says *\"skip this version\"*: run `garden update --skip <pkg@version>`")
  sb.add("> 4. If operator says *\"don't ask again\"*: run `garden update --disable`")
  sb.add("<!-- TRIAD_UPDATE_RIDER: END -->")
  return sb.join("\n")

proc doUpdateCommand*(
  args: seq[string],
  callerVer: string = "",
  callerPkg: string = "vine"
): int =
  var forceCheck = false
  var applyUpdate = false
  var disablePrompt = false
  var enablePrompt = false
  var skipVersion = ""
  var jsonOut = false

  var i = 0
  while i < args.len:
    let a = args[i]
    if a in ["--check", "-c"]: forceCheck = true
    elif a in ["--apply", "-a"]: applyUpdate = true
    elif a in ["--disable", "-d", "--never"]: disablePrompt = true
    elif a in ["--enable", "-e"]: enablePrompt = true
    elif a == "--json": jsonOut = true
    elif a == "--skip" and i + 1 < args.len:
      skipVersion = args[i+1]; inc i
    elif a.startsWith("--skip="):
      skipVersion = a[7..^1]
    inc i

  var config = loadUpdatesConfig()

  if disablePrompt:
    if not config.hasKey("settings"): config["settings"] = newJObject()
    config["settings"]["prompt_rider"] = %false
    config["settings"]["update_check"] = %"never"
    saveUpdatesConfig(config)
    echo "[UPDATES] Triad update prompts disabled. You will not be prompted again."
    return 0

  if enablePrompt:
    if not config.hasKey("settings"): config["settings"] = newJObject()
    config["settings"]["prompt_rider"] = %true
    config["settings"]["update_check"] = %"daily"
    saveUpdatesConfig(config)
    echo "[UPDATES] Triad update prompts enabled (cadence: daily)."
    return 0

  if skipVersion.len > 0:
    if not config.hasKey("settings"): config["settings"] = newJObject()
    if not config["settings"].hasKey("ignored_versions"): config["settings"]["ignored_versions"] = newJObject()

    if '@' in skipVersion:
      let parts = skipVersion.split('@')
      let pkg = parts[0].strip().replace("@axiomantic/", "")
      let ver = parts[1].strip()
      config["settings"]["ignored_versions"][pkg] = %ver
      echo "[UPDATES] Skipped notifications for " & pkg & "@" & ver
    else:
      for pkg in TriadPackages:
        config["settings"]["ignored_versions"][pkg] = %skipVersion
      echo "[UPDATES] Skipped notifications for triad version " & skipVersion
    saveUpdatesConfig(config)
    return 0

  let res = checkTriadUpdates(callerVer, callerPkg, force = (forceCheck or applyUpdate or not config.hasKey("cached") or config["cached"].len == 0))

  if jsonOut:
    echo pretty(res)
    return 0

  if applyUpdate:
    echo "[UPDATES] Executing auto-detected update commands for packages with available updates..."
    let cached = res{"cached"}
    var anyApplied = false
    var overallCode = 0

    for pkg in TriadPackages:
      if cached != nil and cached.hasKey(pkg):
        let item = cached[pkg]
        if item{"has_update"}.getBool(false):
          let cmd = item{"update_command"}.getStr()
          echo "\n--- Updating " & pkg & " via auto-detected method: " & item{"install_kind"}.getStr() & " ---"
          echo "Executing: " & cmd
          let code = execCmd(cmd)
          if code != 0:
            stderr.writeLine("[ERROR] Failed to update " & pkg & " (exit code: " & $code & ")")
            overallCode = code
          else:
            echo "[SUCCESS] Updated " & pkg
            anyApplied = true

    if not anyApplied:
      echo "[UPDATES] No updates needed. All triad packages are current."
    else:
      # Refresh status
      discard checkTriadUpdates(callerVer, callerPkg, force = true)
    return overallCode

  # Default: display status
  echo "=========================================================================================="
  echo "Axiomantic Swarm Triad: Update Status"
  echo "=========================================================================================="
  echo "Package                Installed   Latest      Status             Installation Method"
  echo "------------------------------------------------------------------------------------------"

  let cached = res{"cached"}
  var hasAnyUpdate = false
  for pkg in TriadPackages:
    let info = if cached != nil and cached.hasKey(pkg): cached[pkg] else: nil
    let inst = if info != nil: info{"installed"}.getStr("unknown") else: "unknown"
    let lat = if info != nil: info{"latest"}.getStr("unknown") else: "unknown"
    let up = if info != nil: info{"has_update"}.getBool(false) else: false
    let kindStr = if info != nil: info{"install_kind"}.getStr("global_npm") else: "global_npm"
    let realP = if info != nil: info{"real_path"}.getStr("") else: ""
    let kindEnum = try: parseEnum[InstallKind](kindStr) except CatchableError: ikGlobalNpm
    let methodLabel = installKindLabel(kindEnum, realP)

    if up: hasAnyUpdate = true
    let statusStr = if up: "UPDATE AVAILABLE" else: "Up to date"
    echo alignLeft("@axiomantic/" & pkg, 23) & alignLeft(inst, 12) & alignLeft(lat, 12) & alignLeft(statusStr, 19) & methodLabel

  echo "------------------------------------------------------------------------------------------"
  let lastCheckedSec = res{"last_checked_at"}.getBiggestInt(0)
  if lastCheckedSec > 0:
    let dt = fromUnix(lastCheckedSec).utc().format("yyyy-MM-dd HH:mm:ss 'UTC'")
    echo "Last checked: " & dt & " (cadence: daily)"
  else:
    echo "Last checked: never"

  if hasAnyUpdate:
    echo ""
    echo "To execute recommended updates, run:"
    echo "  garden update --apply"
  else:
    echo ""
    echo "All Triad tools are up to date."
  echo "=========================================================================================="
  return 0
