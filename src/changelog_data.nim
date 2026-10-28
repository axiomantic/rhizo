# src/changelog_data.nim
# Compile-time changelog table, range slicer, and dynamic skill discovery for protocol upgrade notifications.

import std/[strutils, os, algorithm]

const RawChangelog = staticRead("../CHANGELOG.md")
const RawSkillsListing = staticExec("ls -1 " & currentSourcePath().parentDir() & "/../skills")

type
  ChangelogEntry* = object
    version*: string
    date*: string
    content*: string

proc parseChangelogAtCompileTime*(raw: string): seq[ChangelogEntry] {.compileTime.} =
  var entries: seq[ChangelogEntry] = @[]
  var currentVersion = ""
  var currentDate = ""
  var currentContent = ""

  let lines = raw.splitLines()
  for line in lines:
    if line.startsWith("## ["):
      # Close previous entry if exists
      if currentVersion.len > 0 and currentVersion != "Unreleased":
        entries.add(ChangelogEntry(version: currentVersion, date: currentDate, content: currentContent.strip()))
      currentContent = ""
      currentVersion = ""
      currentDate = ""

      # Parse ## [version] - date or ## [Unreleased]
      let closeBracket = line.find(']')
      if closeBracket > 4:
        let ver = line[4 ..< closeBracket].strip()
        if ver != "Unreleased":
          currentVersion = ver
          let dashPos = line.find('-', closeBracket)
          if dashPos != -1 and dashPos + 2 < line.len:
            currentDate = line[dashPos + 1 .. ^1].strip()
    else:
      if currentVersion.len > 0:
        currentContent.add(line & "\n")

  if currentVersion.len > 0 and currentVersion != "Unreleased":
    entries.add(ChangelogEntry(version: currentVersion, date: currentDate, content: currentContent.strip()))

  return entries

const EmbeddedChangelog* = parseChangelogAtCompileTime(RawChangelog)

proc parseSemverParts*(vStr: string): tuple[major, minor, patch: int, valid: bool] =
  result = (0, 0, 0, false)
  var clean = vStr.strip()
  if clean.startsWith("v") or clean.startsWith("V"):
    clean = clean[1..^1]
  let parts = clean.split('.')
  if parts.len < 3:
    return (0, 0, 0, false)
  try:
    let maj = parseInt(parts[0])
    let min = parseInt(parts[1])
    var patchStr = parts[2]
    var cleanPatch = ""
    for c in patchStr:
      if c in '0'..'9':
        cleanPatch.add(c)
      else:
        break
    if cleanPatch.len == 0:
      return (0, 0, 0, false)
    let pat = parseInt(cleanPatch)
    return (maj, min, pat, true)
  except CatchableError:
    return (0, 0, 0, false)

proc cmpSemVer*(a, b: tuple[major, minor, patch: int, valid: bool]): int =
  if a.major != b.major: return cmp(a.major, b.major)
  if a.minor != b.minor: return cmp(a.minor, b.minor)
  return cmp(a.patch, b.patch)

proc formatEntry(e: ChangelogEntry): string =
  result = "## [" & e.version & "]"
  if e.date.len > 0:
    result.add(" - " & e.date)
  result.add("\n\n" & e.content)

proc getChangelogDiff*(fromVer, toVer: string): string =
  ## Returns Markdown containing entries for versions strictly newer than `fromVer` up to `toVer`.
  ## If `fromVer` is empty or not a valid semver, returns entries for `toVer` (or latest release highlights).
  let targetToVer = if toVer.strip().len > 0: toVer.strip()
                    elif EmbeddedChangelog.len > 0: EmbeddedChangelog[0].version
                    else: ""

  if targetToVer.len == 0 or EmbeddedChangelog.len == 0:
    return ""

  let cleanFrom = fromVer.strip()
  if cleanFrom.len == 0:
    # Empty fromVer: return latest release highlights (targetToVer)
    for e in EmbeddedChangelog:
      if e.version == targetToVer:
        return formatEntry(e)
    return formatEntry(EmbeddedChangelog[0])

  if cleanFrom == targetToVer:
    return ""

  let svFrom = parseSemverParts(cleanFrom)
  let svTo = parseSemverParts(targetToVer)

  if svFrom.valid and svTo.valid:
    if cmpSemVer(svFrom, svTo) >= 0:
      return "" # Already at or newer than target version

    var diffEntries: seq[ChangelogEntry] = @[]
    for e in EmbeddedChangelog:
      let svE = parseSemverParts(e.version)
      if svE.valid and cmpSemVer(svE, svFrom) > 0 and cmpSemVer(svE, svTo) <= 0:
        diffEntries.add(e)

    if diffEntries.len > 0:
      var res = ""
      for i, e in diffEntries:
        if i > 0: res.add("\n\n")
        res.add(formatEntry(e))
      return res
    else:
      # No intermediate versions found via semver range, fallback to targetToVer
      for e in EmbeddedChangelog:
        if e.version == targetToVer:
          return formatEntry(e)
      return formatEntry(EmbeddedChangelog[0])
  else:
    # fromVer is unknown/invalid semver (e.g. "unknown", "invalid")
    # Return latest release highlights for targetToVer
    for e in EmbeddedChangelog:
      if e.version == targetToVer:
        return formatEntry(e)
    return formatEntry(EmbeddedChangelog[0])

proc getDiscoveredSkills*(coreToolName: string = "rhizo", runtimeDir: string = ""): tuple[coreSkill: string, subsidiarySkills: seq[string]] =
  ## Dynamically enumerates skills from compile-time embedding and runtime directory scan,
  ## separating the core tool skill from subsidiary skills.
  var skillNames: seq[string] = @[]

  # 1. Check compile-time static listing
  for line in RawSkillsListing.splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0 and not trimmed.startsWith(".") and trimmed notin skillNames:
      skillNames.add(trimmed)

  # 2. Augment with runtime directory scan if available
  let candidateDirs = [runtimeDir, "skills", "../skills", getAppDir() / "skills", getAppDir() / "../skills"]
  for cDir in candidateDirs:
    if cDir.len > 0 and dirExists(cDir):
      try:
        for kind, path in walkDir(cDir):
          if kind == pcDir:
            let sName = extractFilename(path)
            if sName.len > 0 and not sName.startsWith(".") and sName notin skillNames:
              skillNames.add(sName)
      except CatchableError:
        discard

  let normCore = coreToolName.toLowerAscii.strip()
  var coreSkill = normCore
  var subsidiaries: seq[string] = @[]

  for s in skillNames:
    if s.toLowerAscii == normCore:
      coreSkill = s
    else:
      subsidiaries.add(s)

  subsidiaries.sort()
  return (coreSkill: coreSkill, subsidiarySkills: subsidiaries)

proc formatUpgradeGuidance*(coreToolName, fromVer, toVer: string, runtimeDir: string = ""): string =
  let (coreSkill, subsidiaries) = getDiscoveredSkills(coreToolName, runtimeDir)
  var lines: seq[string] = @[]
  lines.add("[" & coreToolName.toUpperAscii & " PROTOCOL UPGRADE NOTICE]")
  lines.add(coreToolName & " was upgraded on this host from " & (if fromVer.len > 0: fromVer else: "unrecorded") & " to " & toVer & ".")
  lines.add("")
  let diff = getChangelogDiff(fromVer, toVer)
  if diff.len > 0:
    lines.add("### Changelog Delta (" & (if fromVer.len > 0: fromVer else: "initial") & " -> " & toVer & "):")
    lines.add(diff)
    lines.add("")

  lines.add("### Action Required in This Session:")
  lines.add("1. Re-read updated core skill (mandatory): file://~/.gemini/config/skills/" & coreSkill & "/SKILL.md")
  if subsidiaries.len > 0:
    lines.add("2. Associated skills: " & subsidiaries.join(", ") & " (if already loaded in this session, re-read now via view_file; otherwise leave lazy-loaded)")
    lines.add("3. Inspect new CLI flags: " & coreToolName & " --help")
    lines.add("4. Re-arm listener: " & coreToolName & " listen <name>")
  else:
    lines.add("2. Inspect new CLI flags: " & coreToolName & " --help")
    lines.add("3. Re-arm listener: " & coreToolName & " listen <name>")

  lines.add("")
  lines.add("### Invariants for this Notice:")
  lines.add("- DO NOT run 'npm install' or package managers (the binary on this host is already upgraded to " & toVer & ").")
  lines.add("- DO NOT claim a task or execute code. This is an informational upgrade notice, not a task directive.")
  lines.add("- DO NOT reply to this notice. Simply re-read the skill file and re-arm your listener.")

  return lines.join("\n")
