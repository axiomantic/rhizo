# tests/test_changelog_diff.nim
import std/[unittest, os, strutils]
import ../src/changelog_data

suite "Changelog Diff & Compile-Time Embedding":
  test "embedded changelog has entries":
    check EmbeddedChangelog.len > 0
    check EmbeddedChangelog[0].version == "0.2.25"
    check EmbeddedChangelog[0].date == "2026-10-22"

  test "1-version increment (0.2.24 -> 0.2.25)":
    let diff = getChangelogDiff("0.2.24", "0.2.25")
    check diff.len > 0
    check "## [0.2.25]" in diff
    check "Swarm Reassignment" in diff
    check "## [0.2.24]" notin diff

  test "multi-version jump (0.2.22 -> 0.2.25)":
    let diff = getChangelogDiff("0.2.22", "0.2.25")
    check diff.len > 0
    check "## [0.2.25]" in diff
    check "## [0.2.24]" in diff
    check "## [0.2.23]" in diff
    check "## [0.2.22]" notin diff

  test "empty fromVer returns latest release highlights":
    let diff = getChangelogDiff("", "0.2.25")
    check diff.len > 0
    check "## [0.2.25]" in diff
    check "Swarm Reassignment" in diff
    check "## [0.2.24]" notin diff

  test "unknown fromVer returns latest release highlights":
    let diff = getChangelogDiff("unknown", "0.2.25")
    check diff.len > 0
    check "## [0.2.25]" in diff
    check "Swarm Reassignment" in diff

  test "same fromVer and toVer returns empty diff":
    let diff = getChangelogDiff("0.2.25", "0.2.25")
    check diff == ""

  test "fromVer newer than toVer returns empty diff":
    let diff = getChangelogDiff("0.2.26", "0.2.25")
    check diff == ""

  test "dynamic skill discovery":
    let (core, subs) = getDiscoveredSkills("rhizo")
    check core == "rhizo"
    let guidance = formatUpgradeGuidance("rhizo", "0.2.24", "0.2.25")
    check "rhizo" in guidance
    check "0.2.24" in guidance
    check "0.2.25" in guidance
