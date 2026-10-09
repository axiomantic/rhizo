# src/guide.nim
# Manages installable/uninstallable demarcated documentation blocks in AGENTS.md
# for the Rhizo multi-agent coordination mesh.
# Uses atomic temporary file writes and strict balanced-marker validation
# to ensure zero file corruption or data loss.

import std/[os, strutils]

const
  GuideVersion* = "v1.5"
  BeginMarker* = "<!-- BEGIN RHIZO GUIDE [" & GuideVersion & "] -->"
  EndMarker* = "<!-- END RHIZO GUIDE -->"
  MarkerPrefix* = "<!-- BEGIN RHIZO GUIDE"

const CanonicalGuideContent* = """
<!-- BEGIN RHIZO GUIDE [v1.5] -->
<!-- DO NOT EDIT DIRECTLY: Managed by `rhizo guide install` -->

## Rhizo Multi-Agent Coordination Guide

This repository utilizes **Rhizo** for inter-assistant communication, distributed locking, and synchronized task queues over Redis/Valkey.

### 0. Self-Bootstrapping Prerequisite
All multi-agent coordination requires `rhizo` and `rift`:
```bash
npm install -g @axiomantic/rhizo rift-snapshot
```
*(In restricted environments: prefix with `npx -y @axiomantic/rhizo` or `npx -y rift-snapshot`).*

### 1. Invariants & Identity
<INVARIANT>
Identity Allocation: Agent identity must be unique and collision-free. Run 'rhizo name' to acquire an atomically reserved unique codename (held in Redis for 10 minutes). Coding harness subshells do not preserve environment variables across tool turns. Record the literal name output from 'rhizo name' (e.g. 'rhizo-sequoia') in your reasoning context and pass it explicitly in all subsequent commands: 'rhizo open <name>', 'rhizo listen <name>'.
</INVARIANT>

<INVARIANT>
Sovereign Session & Subagent Prohibition: Swarm workers are ALWAYS sovereign, independent interactive sessions (dedicated terminal tabs, CLI windows, or IDE sessions) bootstrapped via Garden 10-backtick prompt cards. Harness-internal subagents (e.g., Antigravity's 'invoke_subagent', Claude Code's 'Task', OpenCode subagents, Cursor sub-composers) are STRICTLY PROHIBITED from acting as cluster swarm workers across all harnesses. Internal subagents are ephemeral, terminate upon single-task completion, cannot maintain persistent blocking listeners ('rhizo listen'), corrupt workspace isolation, and cause severe context poisoning by dumping execution traces back into the parent prompt. When orchestrating or bootstrapping a swarm, an orchestrator must NEVER spawn internal subagents and must NEVER offer "subagents" as a worker execution option during intake.
</INVARIANT>

<FORBIDDEN>
Zero Dirty Commits: Never stage or commit coordination metadata (*.lock, .rhizo.*) into Git. Keep all agent state in ~/.gitignore_global.
</FORBIDDEN>

### 2. Listener Discipline & Anti-Token-Thrash
<CRITICAL>
Always run 'rhizo listen <agent>' with zero timeout (infinite wait). Bounded timeouts cause empty LLM turn wakeups that exhaust token budgets. Never execute 'rhizo listen &' or redirect output ('> /dev/null').
</CRITICAL>

<INVARIANT>
No Double-Daemons: If an ad-hoc subagent is explicitly requested by the operator for a one-off inspection, 'rhizo listen' inside that subagent must run as a synchronous blocking foreground command that exits on message receipt. Never spawn background daemons inside subagents.
</INVARIANT>

<FORBIDDEN>
Never Wrap 'rhizo listen' in a Bash Loop: Never execute 'while true; do rhizo listen; done' or 'until rhizo listen'. Coding harnesses and parent agents only receive output and wake up when the tool execution TERMINATES. An infinite loop inside a single command prevents the process from returning, trapping the message payload inside an unmonitored subshell log and hanging the parent task forever. Each 'rhizo listen' must be a single-shot execution that exits on delivery; re-arming is the orchestrator's job in a separate task or subsequent turn.
</FORBIDDEN>

### 3. Task Claiming & Fencing
<INVARIANT>
Always negotiate leases when claiming tasks: 'rhizo claim <queue> --lease <sec>'. Acquire fencing tokens before modifying shared resources: 'rhizo lock <resource> --fencing'. Acknowledge completion with 'rhizo ack' only after verification.
</INVARIANT>

### 4. Task Routing & Optional System 1
<INVARIANT>
System 1 Routing is strictly optional. All core primitives (messaging, locking, explicit queues 'rhizo enqueue <queue>') require zero ML models and zero configuration files. Semantic routing ('rhizo enqueue --route <text>') is an optional triage accelerator; it resolves cascading rules starting from a machine-wide global configuration (~/.config/rhizo/rhizo-routes.yaml or routes.yaml, created via 'rhizo route init --global') down through repo-root and subdirectory rhizo-routes.yaml files (scaffold via 'rhizo route init'). All projects inherit global rules unless overridden.
</INVARIANT>

### 5. Case-Insensitive Coordination
<INVARIANT>
Case-Insensitive Channels & Entities: Agent codenames, inbox addresses, multicast tags ('@tag'), work queues ('queue:<name>'), distributed locks ('lock:<name>'), pub/sub channels ('channel:<name>'), tasks, and run cancellations are normalized case-insensitively. Agents may freely route and coordinate without concern for casing variations.
</INVARIANT>

### 6. Delegation Precedence
<INVARIANT>
Delegation Precedence: When instructed to "delegate", "assign", or "dispatch" work, an orchestrator MUST dispatch tasks to active workers in the cluster over Rhizo ('rhizo send <worker>', 'rhizo enqueue queue:<project>:tasks', or 'rhizo task assign/claim'). Harness-internal subagents (e.g. 'invoke_subagent', 'Task', 'Agent') must NEVER be used to fulfill cluster swarm roles; they are restricted solely to transient, single-turn ad-hoc inspections in non-swarm solo chats when the operator explicitly requests a "subagent" by name.
</INVARIANT>

### 7. Post-Compaction Ceremony Restoration
<INVARIANT>
Post-Compaction Ceremony Restoration: If a session utilizes Rhizo, Garden, or Vine, context compaction purges operational invariants from memory. Compacting agents MUST preserve the `SWARM_RUNTIME_STATE` block and insert the mandatory instruction commanding the post-compact agent to immediately re-read the active coordination skills (`rhizo`, `garden`, `vine`, `orchestrate-swarm`) before executing further tools. Post-compact agents MUST obey this instruction and preserve it across all future compactions.
</INVARIANT>

### 8. Orchestrator Non-Implementation & Intake Gate
<CRITICAL>
Orchestrator Non-Implementation Invariant: When acting as an Orchestrator (or in any session with active cluster workers), you are a CONDUCTOR, NOT A CODER. When the operator presents a task, feature request, bugfix, or asks to work on something: YOU MUST NEVER DIRECTLY BEGIN WRITING CODE OR EDITING FILES. Instead, you MUST STOP and prompt the operator to choose routing:
1. Enqueue to Cluster Work Queue ('rhizo enqueue queue:<project>:tasks')
2. Dispatch Directly to Worker ('rhizo send <worker>')
3. Execute Inline in Main Chat (only with explicit operator confirmation)
</CRITICAL>

### 9. Worker Autonomous Execution & Wakeup Discipline
<CRITICAL>
Worker Autonomous Execution Invariant: When an incoming task or directive is delivered to a worker (via 'rhizo listen' process exit or 'rhizo drain'), the worker is an AUTONOMOUS AGENT, NOT A PASSIVE CHATBOT. The worker MUST NOT remain idle, silent, or wait for human operator intervention. Upon message delivery, the worker MUST IMMEDIATELY:
1. Inspect the delivered task payload, instructions, and target files.
2. Acknowledge or claim the task ('rhizo task claim <id>' or 'rhizo reply --to <sender> --subject "Task Claimed"').
3. Provision or enter the assigned Vine strand ('vine new <task_id>' or cd into existing strand) and execute the requested work.
4. Verify changes against the Two-Key Gate ('vine gate') before reporting completion.
5. Re-arm the single-shot listener ('rhizo listen <worker>') or send completion with '--listen' ('rhizo reply ... --listen') before completing the turn.
</CRITICAL>
<!-- END RHIZO GUIDE -->"""

type GuideStatus* = enum
  gsNotFound,
  gsInstalled,
  gsMalformed,
  gsFileMissing

proc checkGuide*(targetPath: string): GuideStatus =
  if not fileExists(targetPath):
    return gsFileMissing

  let content = readFile(targetPath)
  let hasBegin = content.contains(MarkerPrefix)
  let hasEnd = content.contains(EndMarker)

  if hasBegin and hasEnd:
    return gsInstalled
  elif hasBegin xor hasEnd:
    return gsMalformed
  else:
    return gsNotFound

proc installGuide*(targetPath: string): tuple[success: bool, message: string] =
  let status = checkGuide(targetPath)

  if status == gsMalformed:
    return (false, "Error: Malformed markers detected in " & targetPath & " (one marker found without matching pair). Aborting to prevent data loss.")

  let pid = getCurrentProcessId()
  let tmpPath = targetPath & ".tmp." & $pid

  try:
    if status == gsFileMissing:
      createDir(targetPath.splitPath.head)
      let initialContent = "# AGENTS.md — Rhizo Multi-Agent Guide\n\n" & CanonicalGuideContent & "\n"
      writeFile(tmpPath, initialContent)
      moveFile(tmpPath, targetPath)
      return (true, "Created " & targetPath & " and installed Rhizo Guide [" & GuideVersion & "].")

    let content = readFile(targetPath)

    if status == gsInstalled:
      # In-place update between markers
      let lines = content.splitLines()
      var newLines: seq[string] = @[]
      var inBlock = false
      var replaced = false

      for line in lines:
        if line.contains(MarkerPrefix):
          inBlock = true
          if not replaced:
            newLines.add(CanonicalGuideContent)
            replaced = true
          continue
        elif inBlock and line.contains(EndMarker):
          inBlock = false
          continue

        if not inBlock:
          newLines.add(line)

      writeFile(tmpPath, newLines.join("\n") & "\n")
      moveFile(tmpPath, targetPath)
      return (true, "Updated Rhizo Guide to [" & GuideVersion & "] in " & targetPath & ".")

    else: # gsNotFound
      var updated = content.strip(trailing = true)
      if updated.len > 0:
        updated.add("\n\n")
      updated.add(CanonicalGuideContent & "\n")

      writeFile(tmpPath, updated)
      moveFile(tmpPath, targetPath)
      return (true, "Appended Rhizo Guide [" & GuideVersion & "] to " & targetPath & ".")

  except Exception as e:
    if fileExists(tmpPath):
      try: removeFile(tmpPath)
      except CatchableError: discard
    return (false, "Error installing guide: " & e.msg)

proc uninstallGuide*(targetPath: string): tuple[success: bool, message: string] =
  let status = checkGuide(targetPath)

  if status == gsFileMissing:
    return (false, "Error: Target file " & targetPath & " does not exist.")

  if status == gsMalformed:
    return (false, "Error: Malformed markers detected in " & targetPath & " (one marker found without matching pair). Aborting to prevent data loss.")

  if status == gsNotFound:
    return (true, "Notice: Rhizo Guide not found in " & targetPath & ". Nothing to uninstall.")

  let pid = getCurrentProcessId()
  let tmpPath = targetPath & ".tmp." & $pid

  try:
    let content = readFile(targetPath)
    let lines = content.splitLines()
    var newLines: seq[string] = @[]
    var inBlock = false

    for line in lines:
      if line.contains(MarkerPrefix):
        inBlock = true
        continue
      elif inBlock and line.contains(EndMarker):
        inBlock = false
        continue

      if not inBlock:
        newLines.add(line)

    var resultText = newLines.join("\n").strip(trailing = true)
    if resultText.len > 0:
      resultText.add("\n")

    writeFile(tmpPath, resultText)
    moveFile(tmpPath, targetPath)
    return (true, "Successfully uninstalled Rhizo Guide from " & targetPath & ".")

  except Exception as e:
    if fileExists(tmpPath):
      try: removeFile(tmpPath)
      except CatchableError: discard
    return (false, "Error uninstalling guide: " & e.msg)
