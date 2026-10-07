# AGENTS.md — Locutus & Multi-Agent Workspace Guide

This repository guide establishes the runtime invariants, directory hygiene, and coordination protocols for AI coding agents operating across projects.

<!-- BEGIN RHIZO GUIDE [v1.4] -->
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

### 5. Case-Insensitive Coordination
<INVARIANT>
Case-Insensitive Channels & Entities: Agent codenames, inbox addresses, multicast tags ('@tag'), work queues ('queue:<name>'), distributed locks ('lock:<name>'), pub/sub channels ('channel:<name>'), tasks, and run cancellations are normalized case-insensitively. Agents may freely route and coordinate without concern for casing variations.
</INVARIANT>

### 6. Delegation Precedence
<INVARIANT>
Delegation Precedence: When instructed to "delegate", "assign", or "dispatch" work, an orchestrator MUST dispatch tasks to active workers in the cluster over Rhizo ('rhizo send <worker>', 'rhizo enqueue queue:<project>:tasks', or 'rhizo task assign/claim'). Harness-internal subagents (e.g. 'invoke_subagent', 'Task', 'Agent') must ONLY be used if the operator explicitly requests a "subagent" by name, or if no cluster workers exist.
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
<!-- END RHIZO GUIDE -->

<!-- BEGIN VINE GUIDE [v1.1] -->
<!-- DO NOT EDIT DIRECTLY: Managed by `vine guide install` -->

## Vine Workspace & Strand Coordination Guide

Vine manages zero-cost APFS copy-on-write workspaces (**Strands**), polyglot build cache normalizers, and the Two-Key integration gate for parallel agent development.

### 0. Self-Bootstrapping Prerequisite
This project requires `rhizo` and `vine`. If `command -v rhizo` or `command -v vine` fails, install them via npm:
```bash
npm install -g @axiomantic/rhizo @axiomantic/vine
```

### 1. Invariants & Strand Identity
* **No Workspace-Scoped Identity Files**:
  Agent identity is strictly decoupled from directory paths. Never create or read `.rhizo.agent` or `.vine.agent` in any project or strand directory.
* **Zero Dirty Commits**:
  All strand state, lockfiles, temporary buffers, and manifests must be ignored in `~/.gitignore_global` or `.git/info/exclude`. Never stage or commit coordination metadata (`.vine.json`, `workspaces/`).
* **Post-Compaction Ceremony Restoration**:
  Whenever context compaction occurs in a session that used Vine (or Rhizo/Garden), the compaction summary MUST include the mandatory directive commanding the resurrected agent to re-read `vine` (and `rhizo`/`garden` if active) and inspect active strands before touching canonical trunk files. This directive must remain intact across all future compactions.
* **Compaction Recovery**:
  Whenever starting a session or recovering from context compaction, inspect active strands before editing canonical files:
  ```bash
  vine list 2>/dev/null || rift list 2>/dev/null || ls -la ~/Development/workspaces/ 2>/dev/null || true
  ```
  If an assigned task has an active `.vine.json`, re-anchor to that directory instead of touching the canonical repository root.

---

### 2. When to Spin a Strand vs. Working in Trunk
* **Spin an Isolated Strand when**:
  - The repository contains Git submodules (e.g., PebbleOS).
  - The task requires complex, multi-file refactoring or high risk of breaking `main`.
  - Parallel subagents or assistants are operating simultaneously on different tasks.
* **Work Directly in Trunk when**:
  - The task is a trivial 1-file documentation fix, typo correction, or minor configuration tweak.

---

### 3. Strand Provisioning Protocol

#### Step 1: Directory Setup
All strands live outside canonical repositories to prevent recursive indexing and IDE thrashing:
```bash
STRAND_DIR="$HOME/Development/workspaces/<project>/<task-slug>/<repo>"
mkdir -p "$(dirname "$STRAND_DIR")"
```

#### Step 2: Submodule Pre-Flight Check & Workspace Creation
1. **Check for Uninitialized Submodules**:
   ```bash
   if git submodule status 2>/dev/null | grep -q '^-'; then
     echo "WARNING: Canonical repository has uninitialized submodules. Initialize first before cloning!"
   fi
   ```
2. **Clone Workspace via APFS Copy-on-Write**:
   - **Repositories with Submodules (e.g. PebbleOS)**:
     Use `rift` (native APFS CoW cloning of working tree + `.git/modules` in ~9s with 0 extra blocks):
     ```bash
     rift create --into "$(dirname "$STRAND_DIR")" --name "<repo>"
     ```
   - **Monolithic Repositories without Submodules (e.g. rhizo, redis)**:
     Use native Git worktree:
     ```bash
     git worktree add "$STRAND_DIR" -b "<branch>"
     ```
3. **Stat Cache Warmup**:
   Silences APFS inode change time (`ctime`) differences in <15ms:
   ```bash
   git -C "$STRAND_DIR" update-index --refresh >/dev/null 2>&1 || true
   ```

#### Step 3: The Universal APFS CoW Vendoring Fast-Path
Clone pre-built dependency caches from the canonical repository in <80ms without consuming physical disk space:
```bash
CANONICAL_REPO="$HOME/Development/<project>"
VENDORED_DIRS=("deps" "nimbledeps" "vendor" "node_modules" ".zig-cache")

for vdir in "${VENDORED_DIRS[@]}"; do
  if [ -d "$CANONICAL_REPO/$vdir" ] && [ ! -d "$STRAND_DIR/$vdir" ]; then
    cp -c -R "$CANONICAL_REPO/$vdir" "$STRAND_DIR/$vdir"
  fi
done
```

#### Step 4: Python Virtual Environment (`.venv`) Policy
1. Inspect `$CANONICAL_REPO/.venv/pyvenv.cfg`.
2. **If `relocatable = true`**: Safe to APFS clone:
   ```bash
   cp -c -R "$CANONICAL_REPO/.venv" "$STRAND_DIR/.venv"
   ```
3. **If NOT relocatable**: **Do not blind-copy** (prevents mutating parent environment via absolute shebangs).
   - Check `vine.toml` for `venv_policy`:
     - If `recreate`: Run `UV_VENV_RELOCATABLE=1 uv venv "$STRAND_DIR/.venv"` (~12ms).
     - If `prompt` (default): Ask user whether to recreate or skip.

#### Step 5: Non-Destructive Polyglot `.envrc` Setup
Place this `.envrc` in `$STRAND_DIR` and run `direnv allow "$STRAND_DIR"`:
```bash
# Source parent repository .envrc if present (non-destructive chaining)
[ -f "$HOME/Development/<project>/.envrc" ] && source_env "$HOME/Development/<project>/.envrc"

export PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
export CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/dev-workspaces/$(basename "$PROJECT_ROOT")"
mkdir -p "$CACHE_ROOT"

# C / C++ Ccache normalization across Strands
if command -v ccache >/dev/null 2>&1; then
    export CCACHE_BASEDIR="$(dirname "$PROJECT_ROOT")"
    export CCACHE_NOHASHDIR=1
fi

# Rust Target / Sccache
[ -f "$PROJECT_ROOT/Cargo.toml" ] && export CARGO_TARGET_DIR="$CACHE_ROOT/cargo-target"

# Python uv clone mode
export UV_LINK_MODE="clone"

# Nim Nimcache
export NIMCACHE="$CACHE_ROOT/nimcache"
```

#### Step 6: Initialize Strand Manifest (`.vine.json`)
```json
{
  "task_id": "<task-id>",
  "project": "<project>",
  "strand_path": "<strand-dir>",
  "branch": "<branch>",
  "base_branch": "<base-branch>",
  "base_commit": "<base-commit-sha>",
  "status": "IN_PROGRESS",
  "created_at": "2026-09-26T12:00:00Z"
}
```

---

### 4. Turn-End & Weaving Protocol (The Two-Key Rule)

Never declare a task complete or attempt to weave without passing both keys:

#### Key 1: In-Memory Conflict Gate
```bash
BASE_BRANCH="${BASE_BRANCH:-main}"
git merge-tree --write-tree "$BASE_BRANCH" HEAD
```
- **Exit 0**: Clean mechanical merge.
- **Exit 1**: Conflicts detected. Resolve conflicts *inside the Strand* before touching canonical trunk.

#### Key 2: Live Compiler & Test Suite Gate (Zero Green Mirage)
Execute the project's actual build and test suite inside the Strand:
```bash
# Inferred or from vine.toml [verification] test_command:
$BUILD_AND_TEST_COMMAND
```
*Never bypass this gate. `git merge-tree` only verifies text mergeability, not compilation or semantic correctness.*

#### Step 3: Weave into Canonical Trunk
Once Key 1 and Key 2 pass 100% green:
```bash
cd "$CANONICAL_REPO"
# Fetch branch directly from isolated Strand
git fetch "$STRAND_DIR" <branch>:<branch>
# Fast-forward merge
git merge --ff-only <branch>
```

#### Step 4: Prune & Cleanup
```bash
rm -rf "$STRAND_DIR"
command -v rift >/dev/null 2>&1 && rift prune >/dev/null 2>&1 || true
```
<!-- END VINE GUIDE -->

<!-- BEGIN GARDEN GUIDE [v1.6] -->
<!-- DO NOT EDIT DIRECTLY: Managed by `garden guide install` -->

## Garden Multi-Agent Swarm & Ceremony Guide

Garden directs high-level methodology, persona deliberations, and synchronized task execution on top of Rhizo (transport) and Vine (workspace integrator).

### 0. Self-Bootstrapping Prerequisite
This project requires `rhizo`, `vine`, and `garden`. If missing, install via npm:
```bash
npm install -g @axiomantic/rhizo @axiomantic/vine @axiomantic/garden rift-snapshot
```

### 1. Invariants & Epistemic Protocol
* **Zero Theatrical Dialogue**:
  Every dialectical exchange must cite empirical evidence obtained from tool execution (file line citations, test suite runs, AST analysis, compiler output). Theatrical roleplay without tool grounding is strictly prohibited.
* **Single-Source Planning**:
  All tasks, locks, and strands must be coordinated via `implementation_plan.md`. Dynamic progress must be tracked in lockstep with plan checkboxes (`- [ ]` to `- [x]`) and harness To-Do tracking.
* **Emergent Design Addendum Protocol**:
  Workers discovering architectural discrepancies cannot unilaterally deviate from `design.md`. They must submit a formal `addendum_<topic>.md` with rationale, await Orchestrator ratification, update `design.md`, and refresh `implementation_plan.md`.

### 2. Fleet Lifecycle & Session Coordination
* **Interactive Intake & Persona Calibration**:
  Before dispatching work, the orchestrator conducts an intake interview (`garden` / `choose-personas`) to calibrate personas, harnesses, and foundation models, then generates `garden-swarm.json`.
* **Prompt-Bootstrapped Sessions**:
  Swarm workers operate in dedicated interactive coding sessions (Claude Code, OpenCode, Antigravity, Pi, Cursor) bootstrapped from Garden prompt cards (`garden prompts` / `garden launch`) wrapped in 10 backticks. Never detach unmanaged background processes with `&` or redirect output.
* **Listener Discipline**:
  Workers arm their single-shot Rhizo listener (`rhizo listen <agent>`) with zero-timeout infinite wait to prevent token thrashing. Never wrap `rhizo listen` in a shell while-loop.
* **Delegation Precedence**:
  When instructed to "delegate", "assign", or "dispatch" work, the orchestrator MUST route tasks to active cluster workers via Rhizo (`rhizo send`, `rhizo enqueue`, `rhizo task assign/claim`). Harness-internal subagents (e.g. `invoke_subagent`, `Task`, `Agent`) must ONLY be used if the operator explicitly specifies the word "subagent", or if no cluster workers exist in the roster (`rhizo who`).
* **Orchestrator Non-Implementation Invariant**:
  When acting as an Orchestrator (or in any session with active cluster workers), the session is a conductor, not a coder. When the operator presents a task, feature request, bugfix, or asks to work on something, the orchestrator MUST NEVER directly write code or edit files. It MUST STOP and prompt the operator to choose routing (Enqueue to cluster queue, Dispatch to worker, or Execute inline).
* **Post-Compaction Ceremony Restoration**:
  Whenever context compaction occurs in a session that used Garden, Rhizo, or Vine, the compaction summary MUST include an explicit directive commanding the resurrected agent to re-read the active coordination skills (`garden`, `orchestrate-swarm`, `rhizo`, `vine`) before executing any further tools. Upon waking from compaction, the agent MUST immediately re-read those skills to restore ceremony, gate protocols, and listener discipline. This directive must remain intact across all future compactions.
* **Worker Autonomous Execution Invariant**:
  When 'rhizo listen' unblocks and exits, a task has been delivered! Swarm workers operate as sovereign, autonomous implementers, not passive chatbots. Workers MUST NOT wait for an operator prompt or ask "Shall I start?". They MUST immediately transition to active execution: claim the task, enter the isolated Vine strand, perform the work, verify the Two-Key Gate, report results, and re-arm the single-shot listener.

### 3. The Two-Key Gate & Strand Weaving
Never weave a strand into the canonical trunk without passing both keys:
* **Key 1 (Mechanical)**: In-memory conflict pre-check (`git merge-tree --write-tree`).
* **Key 2 (Semantic)**: Automated compiler and test suite run inside the strand.
* **Weave**: `vine weave && rhizo ack queue:<project>:tasks <task_id>`
<!-- END GARDEN GUIDE -->















