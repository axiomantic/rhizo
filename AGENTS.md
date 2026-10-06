# AGENTS.md — Locutus & Multi-Agent Workspace Guide

This repository guide establishes the runtime invariants, directory hygiene, and coordination protocols for AI coding agents operating across projects.

<!-- BEGIN RHIZO GUIDE [v1.0] -->
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

<FORBIDDEN>
Zero Dirty Commits: Never stage or commit coordination metadata (*.lock, .rhizo.*) into Git. Keep all agent state in ~/.gitignore_global.
</FORBIDDEN>

### 2. Listener Discipline & Anti-Token-Thrash
<CRITICAL>
Always run 'rhizo listen <agent>' with zero timeout (infinite wait). Bounded timeouts cause empty LLM turn wakeups that exhaust token budgets. Never execute 'rhizo listen &' or redirect output ('> /dev/null').
</CRITICAL>

<INVARIANT>
No Double-Daemons: Inside background subagents, 'rhizo listen' must run as a synchronous blocking foreground command that exits on message receipt. Never spawn background daemons inside subagents.
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
<!-- END RHIZO GUIDE -->

<!-- BEGIN VINE GUIDE [v1.0] -->
<!-- DO NOT EDIT DIRECTLY: Managed by `vine guide install` -->

## Vine Workspace & Strand Coordination Guide

Vine manages isolated copy-on-write workspaces (**Strands**), polyglot build cache normalizers, and the Two-Key integration gate for parallel agent development.

### 0. Self-Bootstrapping Prerequisite
```bash
npm install -g @axiomantic/vine rift-snapshot
```
*(In restricted environments: prefix with `npx -y @axiomantic/vine` or `npx -y rift-snapshot`).*

### 1. Invariants & Workspace Virtualization
<CRITICAL>
The Two-Key Gate: Never weave a strand into canonical trunk without passing 'vine gate' (exit code 0). Key 1 verifies in-memory mechanical mergeability; Key 2 executes the live compiler and test suite. Text mergeability does not imply compilation correctness.
</CRITICAL>

<INVARIANT>
Workspace Virtualization: Rift is the primary, preferred workspace engine ('vine new <task_id>'). Git worktree is supported as a fallback when '--worktree' is explicitly specified or if Rift is unavailable. Workspaces are strictly 1:1 with tasks; never assign multiple concurrent workers to the same strand directory.
</INVARIANT>

<FORBIDDEN>
Never stage or commit '.vine.json' or workspace metadata into Git.
</FORBIDDEN>

### 2. Weaving Protocol
Once Key 1 and Key 2 pass 100% green:
```bash
vine weave
```
<!-- END VINE GUIDE -->

<!-- BEGIN GARDEN GUIDE [v1.0] -->
<!-- DO NOT EDIT DIRECTLY: Managed by `garden guide install` -->

## Garden Multi-Agent Swarm Guide

Garden directs multi-agent swarms using Rhizo for transport and Vine for workspace virtualization.

### 0. Self-Bootstrapping Prerequisite
```bash
npm install -g @axiomantic/garden
```

### 1. Epistemic Protocol & Invariants
<CRITICAL>
The Supreme Orchestrator Invariant: The primary conversation directs, reviews, and weaves; it never performs large multi-file edits directly when worker fleet tasks are active.
</CRITICAL>

<INVARIANT>
Zero Theatrical Dialogue: Every dialectical assertion must be substantiated with empirical evidence obtained through tool calls (file reading, test running, compiler output). Roleplay without evidence is rejected.
</INVARIANT>

<INVARIANT>
Multiplexer Discipline: Workers run exclusively inside managed tmux panes ('garden launch'). Never detach unmanaged background processes with '&'.
</INVARIANT>
<!-- END GARDEN GUIDE -->


