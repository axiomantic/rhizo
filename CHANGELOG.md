# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.9] - 2026-10-07

### Added
- **Dynamic ANSI Terminal Tab/Window Titling (`rhizo title` & Auto-Titling)**:
  - Implemented `setTerminalTitle` emitting standard ANSI OSC 0 escape sequence (`\033]0;<agent>\007`) to `stderr` (preserving clean JSON/stdout pipeline streams).
  - Integrated auto-titling across core commands: `rhizo open <agent>` updates window/tab to the agent codename, and `rhizo listen <agent>` dynamically stamps `<agent> (listening)` during wait cycles and restores `<agent>` upon completion.
  - Added standalone `rhizo title [name]` CLI command for manual or scripted window titling with project scoping.
  - Enables window-targeting AI tools (ChatGPT, macOS Accessibility, AppleScript) and human developers to locate agent tabs and windows deterministically.
- **The "Doorbell" Protocol & `rhizo poke <agent>`**:
  - Added `rhizo poke <agent> [--cmd <command>] [--force/-f] [--dry-run/-n] [--json]` (with aliases `wake`, `nudge`) to inject a non-destructive wakeup keystroke into stalled, deaf, or idle worker terminal windows.
  - **Cascading Target Resolution**:
    1. `tmux`: checks `list-panes` matching pane title or window name and injects `tmux send-keys -t <pane> <cmd> C-m`.
    2. macOS `Ghostty`: uses native AppleScript API (`tell application "Ghostty" ... input text cmd to term ... send key "enter" to term`) without stealing focus.
    3. macOS `Terminal.app`: uses `do script cmd in selected tab of w`.
    4. macOS `iTerm2`: uses `tell session to write text cmd`.
    5. macOS Universal GUI / Electron / IDEs (Antigravity, Cursor, VS Code, Claude Desktop): falls back to `System Events` targeting windows matching `<agent>`.
  - **Health Interlock Guard**: Automatically queries `doProbe`. If the target agent is actively listening on Redis with 0 unread messages, `doPoke` safely skips injection (preventing stdin corruption) unless overridden with `--force`.
  - Added invariant test `test_23_terminal_title_and_poke_invariants` to `tests/test_coordination_invariants.py`.

## [0.2.8] - 2026-10-07

### Added
- **Project-Scoped Role Naming & Anti-Collision Engine**:
  - Implemented `ensureProjectScopedName` in `src/rhizo.nim` preventing bare generic roles (`orchestrator`, `architect`, `auditor`, `implementer`, `worker`, `agent`, `lead`, `reviewer`, `tester`, `coder`, `dev`) from colliding across multi-project clusters.
  - Automatically scopes bare generic roles to `<project>-<role>` (e.g. `rhizo-orchestrator`, `rhizo-architect`) with clear diagnostic notices.
  - Updated `reserveUniqueName` (`rhizo name`) to prefix bare roles or prefix-less requests with the active project namespace (`<project>-<word>` or `<project>-<role>-<word>`).
  - Updated `rhizo listen`, `rhizo open`, `rhizo send`, `rhizo reply`, and `rhizo broadcast` to automatically resolve and target project-scoped agent identities.
  - Added invariant test `test_22_bare_role_project_scoping` to `tests/test_coordination_invariants.py`.

## [0.2.7] - 2026-10-07

### Added
- **Unified Work Item State Machine (WISM) (Module 18)**:
  - Formally implemented the 10-state lifecycle: `DRAFTED` $\rightarrow$ `BLOCKED` (DAG) $\rightarrow$ `QUEUED` $\rightarrow$ `DELIVERED` (Transport Receipt) $\rightarrow$ `CLAIMED` (Semantic ACK) $\rightarrow$ `IN_PROGRESS` $\rightarrow$ `GATE_EVALUATING` $\rightarrow$ `READY_TO_WEAVE` $\rightarrow$ `COMPLETED` (plus `ORPHANED`, `YIELDED`, `DEAD_LETTER`).
  - Completely rewrote `scripts/task.lua` with atomic Redis operations, lease renewals, and monotonic fencing validation.
  - **Automated DAG Dependency Resolution**: On task completion (`rhizo task complete`), the Redis Lua engine automatically scans all downstream tasks in state `BLOCKED`, verifies completed dependencies, and promotes unblocked child tasks to `QUEUED` while publishing `TASK_UNBLOCKED` event notifications.
  - **Transport Delivery Unification**: `doListen` automatically registers popped inbox messages as Work Items in `DELIVERED` state and mirrors the active task to `~/.config/rhizo/current_task.json`.
  - **Causal Auto-Clearing**: Downstream actions (`rhizo reply`, `rhizo send`, `rhizo task complete`, `rhizo task yield`) automatically clear the local task mirror and release Redis task assignments.
  - **Sub-Millisecond Stop Hook Interlock**: `rhizo hook codex-stop` evaluates `current_task.json` and Redis active task state in $<2\text{ms}$, returning `{"decision": "block", "reason": "..."}` to block premature turn completions until workers acknowledge and execute their tasks.
  - Added CLI subcommands: `rhizo task gate-report <id> --token <token>`, `rhizo task current [agent] [--json]`, `rhizo task sweep [--json]`, and `--state <STATE>` filtering on `rhizo task list`.
  - Embedded Mermaid state diagrams and ASCII transition flowcharts across `rhizo`, `garden`, and `vine` skills.

## [0.2.6] - 2026-10-07

### Added
- **Native Lifecycle Hook Interlock (`rhizo hook codex-stop` & `rhizo hook install`) (GVR-017)**:
  - Added native CLI subcommands `rhizo hook codex-stop [--agent <name>]` and `rhizo hook install [--codex|--claude] [--agent <name>]`.
  - Sub-millisecond turn-end interlock for OpenAI Codex Desktop / CLI and Claude Code: intercepts the `Stop` event and returns `{"decision": "block", "reason": "..."}` if unread inbox messages wait or if a registered cluster worker yields without an active listener.
  - Implemented rolling thrash protection valve (`{prefix}hook_blocks:<agent>` in Redis, 60s TTL) allowing turn completion after 3 consecutive blocks to prevent deadlocking sessions.
  - Added automatic scaffolding of `.codex/hooks.json` via `rhizo hook install --codex`.
- **Imperative Autonomous Execution Delivery Banner (GVR-017)**:
  - Replaced passive lifecycle notices in `doListen` with a prominent imperative banner: `🚨 [RHIZO TASK DELIVERED: IMMEDIATE AUTONOMOUS ACTION REQUIRED] 🚨`.
  - Commands receiving LLM workers to execute delivered directives immediately without waiting for human operator prompts.
  - Displays exact command line and harness capability tier instructions for re-arming listeners.
- **Worker Autonomous Execution Invariant (Section 9 in Rhizo Guide v1.4)**:
  - Codified the autonomous execution invariant in `src/guide.nim` and `AGENTS.md`: upon task delivery, workers must immediately transition to active execution in their isolated Vine strand rather than remaining passive chatbots.
  - Synchronized Guide to `v1.4` across all repositories.

## [0.2.5] - 2026-10-07

### Added
- **Watchdog Stepped Backoff & 4-Strike Cap Protocol (GVR-015)**:
  - Implemented Redis-backed streak tracking in hash `{prefix}watchdog:<agent>`.
  - Added stepped backoff schedule (Base 15m $\rightarrow$ 30m $\rightarrow$ 60m $\rightarrow$ 120m) for orchestrator safety watchdog checks during consecutive quiescent checks with a healthy listener.
  - Added 4-strike cap and stand-down (`substatus: "MAX_STREAK_REACHED"`, `recommended_cadence: 0`, `next_action: "STAND_DOWN"`), preventing infinite token-eating polling loops while the background listener remains active on Redis `BRPOP`.
  - Enforced Non-Exponential Reset Invariant: streak and cadence reset to base 15m immediately upon listener trouble (`REARM_LISTENER`), unread inbox backlog (`UNREAD_MESSAGES`), outbound task dispatch (`rhizo send`/`enqueue`), worker message receipt, or chat prompts.
  - Added `rhizo watchdog reset [--agent <name>]` and `--streak <N>` CLI flags.
- **Orchestrator Non-Implementation & Intake Gate Invariant (GVR-016)**:
  - Codified the non-implementation rule for orchestrators: an orchestrator is a conductor, not a coder.
  - When the operator presents a task, feature request, bugfix, or asks to work on something, the orchestrator MUST NEVER directly begin writing code or editing files.
  - The orchestrator MUST stop and prompt the operator to choose routing (Enqueue to cluster queue, Dispatch to worker, or Execute inline).
  - Upgraded Rhizo Coordination Guide to `[v1.3]` with Section 8 in `src/guide.nim` and `AGENTS.md` across repositories.

## [0.2.4] - 2026-10-07

### Added
- **Delegation Precedence Invariant**:
  - Enforced that when instructed to "delegate", "assign", or "dispatch" work, orchestrator sessions MUST route tasks to active cluster workers via Rhizo (`rhizo send <worker>`, `rhizo enqueue queue:<project>:tasks`, or `rhizo task assign/claim`).
  - Restricted harness-internal subagents (`invoke_subagent`, `Task`, `Agent`) to explicit operator requests by name or fallback when no cluster workers exist in `rhizo who`.
- **Post-Compaction Ceremony Restoration Invariant (GVR-010)**:
  - Added a mandatory compaction directive requiring compacting agents to preserve the `SWARM_RUNTIME_STATE` block and insert the ceremony restoration instruction.
  - Resurrected agents must immediately re-read active coordination skills (`garden`, `orchestrate-swarm`, `rhizo`, `vine`) before executing further tools.
- **Rhizo Coordination Guide v1.2**:
  - Updated canonical guide in `src/guide.nim` and `AGENTS.md` across projects to encode delegation precedence and post-compaction ceremony restoration.

## [0.2.3] - 2026-10-06

### Added
- **Environment Variable Canonicalization**:
  - Prefixed OpenSSL binary path check with `RHIZO_OPENSSL_BIN` (fallback to `OPENSSL_BIN`).
  - Prefixed hostname detection with `RHIZO_HOSTNAME` (fallback to `HOSTNAME` and `COMPUTERNAME`).
  - Canonicalized test fixtures to prefer `RHIZO_REDIS_URL`.
- **Comprehensive Configuration & Schema Documentation**:
  - Authored `docs/configuration.md`: Comprehensive reference table for all `RHIZO_*` environment variables, `.rhizo.toml` / `.rhizo.local.toml` hierarchy, security keys, and profile layering.
  - Authored `docs/routes_schema.md`: Full YAML specification for System 1 Semantic Routing (`rhizo-routes.yaml`), question types (`choice`, `score`, `noul`), chunking limits (`split_aggregate` vs `truncate`), match operators (`gte`, `lte`, `and`, `or`, `not`), and real-world examples.

## [0.2.2] - 2026-10-06

### Added
- **Orchestrator Self-Audit Watchdog (`rhizo watchdog check`)**:
  - Implemented `rhizo watchdog [check] [agent] [--agent <name>] [--json] [--expect-listening]` to inspect listener registration, host/PID liveness, unread inbox backlog, and in-flight tasks/leases across Redis queues and workspaces (`scripts/watchdog_inflight.lua`).
  - Added structured exit codes (`0` for `OK` / `STAND_DOWN`, `2` for `ACTION_REQUIRED: REARM_LISTENER` or `ACTION_REQUIRED: UNREAD_MESSAGES`).
- **Scheduled Timer Watchdog & Debouncer Protocol (GVR-014)**:
  - Codified the 15-minute debounced scheduled timer protocol in `orchestrate-swarm` and `rhizo` skills for harnesses supporting `schedule` (e.g. Google Antigravity).
  - Enforced "Replace, Never Stack" debouncer discipline (`manage_task(Action='kill')` before scheduling new timer) on task dispatch, worker reports, and plan updates.
  - Zero-token happy path: incoming messages satisfy `TimerCondition="any"` and cancel the timer before it ever fires.
- **Hook Context Rider Hardening**:
  - Enhanced `claude_stop_hook.py`, `codex_stop_hook.py`, and `agy_stop_hook.py` with `check_watchdog` to block turn completion and direct the agent to start `rhizo listen` if in-flight tasks exist without an active listener.

## [0.2.1] - 2026-10-06

### Added
- **LLM Variance Normalization**:
  - Added robust identifier sanitization across all routing endpoints, stripping leading `@` / `#`, enclosing quotes/backticks/brackets (`"`, `'`, `` ` ``, `<...>`, `[...]`, `(...)`), entity prefixes (`agent:`, `user:`, `bot:`, `inbox:`, `channel:`, `queue:`, `lock:`), and trailing punctuation (`:`, `,`, `;`, `.`).
  - Addressed LLM tendency to address agents as `--to @alice` by cleanly routing directly to `inbox:alice` as a 1:1 direct message rather than triggering multicast.
- **Dynamic Agent Aliases & Atomic Mailbox Rerouting (`rhizo alias`, `rhizo reroute`)**:
  - Implemented dynamic alias registry (`rhizo alias set|get|del|list`) backed by `rhizo:aliases`.
  - Added atomic queue rerouting (`rhizo reroute <from> <to>`) to evacuate stranded inboxes into replacement agents while preserving original FIFO delivery order and preventing self-rerouting.
  - Implemented multi-hop HMAC signature preservation (`original_recipient`) so rerouted messages verify successfully without cryptographic tamper drops.
- **Agent Health Assessment (`rhizo probe`)**:
  - Added `rhizo probe <agent>` to evaluate heartbeat TTL, listener registration, host/PID liveness, inbox backlog, and alias resolution.
- **Non-Destructive Mailbox Inspection (`rhizo history` / `rhizo log`)**:
  - Added non-destructive inspection of agent mailboxes and audit trail events via `LRANGE`.
- **Continuous Listener Streaming (`rhizo listen --continuous` / `--daemon`)**:
  - Added opt-in streaming loop for background monitoring processes while enforcing active duplicate listener protection.

### Fixed
- **Multi-Hop Reroute Cryptographic Integrity**: Fixed HMAC verification failure on multi-hop rerouted messages by preserving the original recipient envelope and evaluating HMAC against `original_recipient`.
- **Argument Parsing in `rhizo send --listen`**: Converted `--listen` to a strictly boolean re-arm flag to prevent greedy absorption of subject/body positional arguments or numeric timeout confusion.
- **PRNG Backoff Seeding**: Seeded thread-local PRNG with `randomize()` across connection retry handlers and CLI entrypoint to eliminate thundering herd synchronization.
- **Duplicate Listener Prevention**: Removed `--continuous` bypass to guarantee single active listener per agent regardless of mode unless `--force` is specified.

## [0.2.0] - 2026-10-06

### Added
- **First-Class Task Lifecycle & Governance (`rhizo task`)**:
  - Added state-machine-governed task objects (`rhizo task create|claim|progress|complete|yield|get|list`) with monotonic status progression (`UNASSIGNED`, `CLAIMED`, `IN_PROGRESS`, `COMPLETED`, `YIELDED`).
  - Enforced single-active-lease invariant per agent and typed deliverables contracts.
  - Added automatic Vine APFS CoW strand provisioning on `rhizo task claim` (`vine new <task_id>`) and Two-Key Gate verification (`vine gate`) before task completion.
- **Cryptographic Operator Decision Ledger (`rhizo decision`)**:
  - Added immutable, verifiable governance rulings (`rhizo decision propose|approve|reject|verify|get|list`) with operator-signed HMAC status.
  - Added gate verification via `rhizo decision verify <id>` (exiting 0 on approved, 1 on non-approved).
- **Side-Effect Audit Stream (`rhizo audit`)**:
  - Added append-only audit stream ledger (`rhizo:audit_trail`) via `rhizo audit log` and `rhizo audit list` for recording task, decision, and coordination events.
- **Sticky Advisory & Reminder System (`rhizo remind`)**:
  - Added sticky invariant management (`rhizo remind add|dismiss|ack|get|list|tick`) to prevent agent token amnesia and late-joining worker drift.
  - Added smart opportunistic piggybacking to attach active advisories onto inbound `rhizo listen` and `rhizo drain` payloads when cadence windows elapse.
  - Added per-agent anti-fatigue cooldowns (`--cadence`) and standalone fallback broadcasts (`rhizo remind tick`) for idle agents.
  - Added non-destructive inspection (`rhizo remind list --for <agent> --json`) to peek at advisory delivery and acknowledgement status without consuming banners.
- **Virtual Mock Time & Deterministic Invariant Testing (`rhizo time`)**:
  - Added Redis virtual time offset manipulation (`rhizo time advance|reset|get`) across Lua scripts (`mock_time_offset`) for instantaneous, deterministic TTL and lease expiry testing.
  - Added comprehensive 17-invariant test suite (`tests/test_coordination_invariants.py`).
- **Universal Case-Insensitive Channel & Coordination Primitives**:
  - Normalized agent identities, inbox addresses, multicast tags (`@tag`), work queues (`queue:<name>`), distributed locks (`lock:<name>`), pub/sub channels (`channel:<name>`), task IDs, decisions, ballots, and run cancellation tokens across 27 Redis Lua scripts and CLI.
  - Senders, workers, and orchestrators can communicate regardless of casing variations without dropped messages or lease collisions.

### Changed
- **Decoupled Telemetry & Work State (`rhizo who`)**:
  - Split overloaded `STATE` column in `rhizo who` into decoupled `LISTENER` (`LISTENING` / `DETACHED`) and `TASK_STATE` (`UNASSIGNED` / `HOLDING_LEASE <task_id>`) columns.
  - Ceased defaulting unassigned workers to deceptive `"IDLE"`.
- **Single-Shot Listener Discipline & Re-Arming Protocol**:
  - Listener strictly exits 0 upon delivering one message to prevent unmonitored background subshell hangs.
  - Added explicit listener identity notices (`Listener Identity: @<name> (this is YOU)`) and ready-to-run harness tool calls (`run_command` / `Task`) aligned with capability tiers (Tiers 1–4).
- **Explicit Broadcast Scoping**:
  - Required explicit `--scope all` or `--scope project`/`--tags` on broadcast commands, reporting exact recipient rosters and total counts.
- **Delivery Feedback & Ergonomics**:
  - `rhizo send` returns structured delivery feedback (`recipient_status`, `listener_attached`, `inbox_depth`) and warns when recipients have no active listener attached.
  - `rhizo drain [count] [name]` supports polymorphic argument ordering and inspects agent registry entries case-insensitively.
  - Injected `elapsed_seconds`, `age_human`, and `is_stale` (1hr+) flags into message envelopes.
- **Causal Message Threading & Auto-Correlated Quorum**:
  - Added `thread_id` and `in_reply_to` tracking to message envelopes.
  - `rhizo reply` automatically fulfills `rhizo scatter` quorums without requiring manual request ID threading.

### Fixed
- **Identity Leakage & Silent Agent Pruning**:
  - Deprecated shared global `current_agent` cross-agent leakage; sender identities are strictly process-bound via `RHIZO_AGENT_NAME`, session mappings, or `--from`.
  - Expired agent heartbeats transition agents to `STALE` instead of executing destructive `SREM` and `DEL`, preserving metadata and group tag memberships.
- **Anti-While-Loop & Detachment Supervision Guardrails**:
  - Listener inspects parent process supervision in `checkSupervisionAttached`, aborting immediately if wrapped in `while true; do rhizo listen; done` or `until rhizo listen` shell loops, or if stdout is redirected to regular files / `nohup.out`.
- **Decoupled Project Namespace**:
  - Removed silent `pwd` basename defaulting; commands require explicit `--project` or `.rhizo.toml`.

## [0.1.12] - 2026-09-30

### Fixed
- **CI Test Suite Headless Isolation**:
  - Attached `mock_laya_server` fixture to `test_route_uses_builtin_fallback_when_no_config_present` so fallback route verification does not depend on a live local System 1 server in headless CI environments.
  - Automatically mirror `USERPROFILE` from `HOME` in test subprocess runners on Windows.
- **TOML Escape Sequence Parsing**:
  - Replaced naive chained string replacements with a character-by-character escape parser in `unquote()`, preventing escaped backslashes in Windows file paths (e.g. `\\tmp`, `\\tests`) from collapsing into tab or newline control characters.
- **Workflow & Runner Environment Alignment**:
  - Aligned all CI workflows (`ci.yml`, `llm-ci.yml`) and test scripts (`scripts/ci/test.sh`) to `RHIZO_REDIS_URL`.
  - Replaced remaining `LOCUTUS_VERSION` variables in universal install scripts (`install.sh`, `install.ps1`) with `RHIZO_VERSION`.

## [0.1.11] - 2026-09-30

### Added
- **Global Route Configuration & Inheritance Across All Projects**:
  - Added support for machine-wide global route configuration (`~/.config/rhizo/rhizo-routes.yaml` and `routes.yaml`) via `rhizo route init --global`.
  - All projects on the machine automatically inherit global routing rules; project-specific and monorepo subdirectory `rhizo-routes.yaml` files cleanly layer on top, inheriting questions and limits while overriding or prepending custom routes.
- **Hierarchical Cascading Route Resolution**:
  - Added recursive directory chain discovery (`findRoutesConfigChain()`) in `src/routing.nim`.
  - Discovers and merges routing configurations up the parent directory hierarchy to git root or filesystem boundaries (`rhizo-routes.yaml`, `rhizo-routes.local.yaml`, `.rhizo-routes.yaml`), layering child project rules over parent and global (`~/.config/rhizo/routes.yaml`) configurations.
- **Embedded Route Scaffolding (`rhizo route init`)**:
  - Added `rhizo route init [--force/-f] [--global/-g]` command to scaffold starter route configuration templates with domain classification, priority scoring, review triggers, and catch-all queues.
- **Sensible Built-in Default Routing**:
  - Added embedded fallback routing configuration (`defaultFallbackRoutingConfig()`) so routing commands function out of the box without requiring explicit project configuration files.

### Removed
- **Complete Purge of Legacy Locutus Backwards-Compatibility Fallbacks**:
  - Purged all `LOCUTUS_*` environment variable fallbacks in favor of canonical `RHIZO_*` (`RHIZO_REDIS_URL`, `RHIZO_PREFIX`, `RHIZO_PROJECT`, `RHIZO_AGENT_NAME`, `RHIZO_SESSION_ID`, `RHIZO_SECRET`, `RHIZO_ENCRYPT`, `RHIZO_CLUSTER`, `RHIZO_QUIET`).
  - Purged legacy `.locutus.toml`, `locutus.toml`, `.locutus.json`, and `~/.config/locutus` config search paths from `src/config.nim`.
  - Removed legacy `bin/locutus` and `bin/locu` binary symlinks and `packaging/scoop/locutus.json`.
  - Updated package names to `rhizo` across `pyproject.toml`, `package.json`, and `rhizo.nimble`.
  - Purged all legacy `LocutusEar` class aliases and `[locutus-ear]` logs across OpenCode and Pi agent extensions.

### Changed
- **Harness Modernization & Rhizo Brand Alignment**:
  - Modernized OpenCode listener extension to `@axiomantic/rhizo-opencode-ear` with `[rhizo-ear]` logging and `[RHIZO CONTEXT ANCHOR]` context markers.
  - Modernized Pi agent extension (`skills/rhizo/pi-ear.ts`) and lifecycle hooks (`skills/rhizo/hooks/`).
- **System 1 Optionality & Documentation**:
  - Clarified across `README.md`, `SKILL.md`, `AGENTS.md`, and guides that System 1 (ModernBERT triage) is strictly optional. All core Redis coordination (pub/sub, work queues, distributed locking with fencing tokens, DAG workflows, blackboard, leader election) operates independently with zero ML requirements.
  - Updated `references/system_one_setup.md` with GitHub source installation instructions for `local-systemone`.

## [0.1.10] - 2026-09-30

### Changed
- **System 1 Default Port Migration (`8000` $\to$ `8100`)**:
  - Migrated the default System 1 decision engine port from `8000` to `8100` across `src/routing.nim`, `rhizo-routes.yaml`, and test suites.
  - Eliminates common port conflicts with local web application servers, proxy tools, and dev environments.

### Added
- **Full Cross-Platform Linux & macOS Daemon Documentation**:
  - Added native Linux deployment documentation (`systemd` user service unit, GPU CUDA / ROCm acceleration, and `loginctl enable-linger $USER` guidance) to `references/system_one_setup.md` and `SKILL.md`.
  - Updated all guide and skill references to [`axiomantic/local-systemone`](https://github.com/axiomantic/local-systemone).

### Fixed
- **Windows Path Escaping in Test Generator**:
  - Escaped Windows backslashes in `.locutus.toml` file generator (`tests/test_nim_binary.py`) to prevent TOML escape character parsing errors.
- **LLM CI Dependencies**:
  - Aligned `.github/workflows/llm-ci.yml` dependency installation with project definitions.

## [0.1.9] - 2026-09-30

### Added
- **Layered Uncommitted Configuration & Dotenv Secrets**:
  - Added automatic `.env` and `.env.local` secret loading in `src/config.nim` via `loadDotEnv()`.
  - Added `.rhizo.local.toml` layering over `.rhizo.toml` with `srcWorkspaceLocalFile` setting precedence (`sourceLabel: "local workspace config"`).
  - Added `rhizo-routes.local.yaml` overlay support in `src/routing.nim`, merging questions, limits, service configuration, and route rules over `rhizo-routes.yaml`.
  - Updated `.gitignore` to prevent leaking uncommitted `.env`, `.env.*`, and `*.local.{toml,yaml,yml,json}` configuration files.
- **System 1 Decision Engine CLI & Architecture Generalization**:
  - Generalized System 1 CLI flags: `--service-url`, `--systemone-url`, `--model` (`-m`), `--api-key` (`-k`), and `--route-timeout` across `rhizo route` and `rhizo enqueue --route`.
  - Preserved backward compatibility for `--laya-url` and `callLayaSystemOne()`.
  - Added `Authorization: Bearer <apiKey>` header support in `callSystemOne()`, enabling seamless integration with TypeSafe Jev API (`https://api.typesafe.ai`) and hosted endpoints.
  - Added environment variable resolution (`RHIZO_SERVICE_URL`, `RHIZO_SYSTEMONE_URL`, `RHIZO_MODEL`, `RHIZO_API_KEY`, `JEV_API_KEY`, `RHIZO_ROUTE_TIMEOUT`).
  - Generalized diagnostic and error messages from Laya-specific wording to vendor-neutral System 1 decision engine terminology.
- **System 1 Routing & Multi-Agent Skill Documentation**:
  - Added comprehensive System 1 setup and architecture guide in `references/system_one_setup.md` covering local open-source models (ModernBERT Laya, Kev, Decider) and cloud APIs (TypeSafe Jev).
  - Updated `SKILL.md` (root, packaged, and global `~/.gemini/config/skills/rhizo/`) with Environment Verification (`rhizo ping`), Layered Config, System 1 setup instructions, causal command reference, and directive routing workflows.
- **Comprehensive Test Coverage**:
  - Added unit and integration tests across `tests/test_config.py`, `tests/test_routing.py`, and `tests/test_routing_unit.nim`.

## [0.1.8] - 2026-09-30

### Added
- **Atomic Identity Allocation & Lexicon Engine (`rhizo name`)**:
  - Embedded 1,000-word curated lexicon (`src/lexicon.nim`) spanning minerals, geography, architecture, mythology, physics, botany, mathematics, astronomy, biology, and nautical domains with zero word duplicates.
  - Added atomic reservation script (`scripts/reserve_name.lua`) verifying availability against active registered agents, live heartbeats, and temporary reservation holds (`held_name:<name>`) with configurable TTL (default 10 minutes).
  - Added `rhizo name [prefix] [--ttl <sec>] [--json]` CLI command returning atomically reserved unique codenames.
  - Integrated automatic identity reservation into `rhizo open [tags]`: when invoked without an explicit name, automatically reserves a unique codename from the lexicon.
  - Updated `scripts/register.lua` to automatically release temporary holds (`held_name:<name>`) upon successful agent registration.
- **Dual-Phase Reset & Nuclear Wipe (`rhizo nuke`, `rhizo reset`)**:
  - Added `scripts/reset.lua` implementing a two-phase clean teardown protocol:
    - **Phase 1 (`notify`)**: Pushes `{"type":"shutdown", ...}` poison-pill payloads to agent inboxes to immediately unblock `BLPOP` listener threads on suspended sockets.
    - **Phase 2 (`purge`)**: Deletes Redis keys safely in batches of 500 to prevent Redis single-thread blocking.
  - Implemented `rhizo nuke [--json]`: The nuclear option for test teardown and development resets. Notifies all listeners across the namespace and wipes all keys matching `{prefix}*`.
  - Implemented `rhizo reset [project] [--all/-a] [--json]`: Project-scoped reset that selectively terminates listeners, cleans active rosters, and deletes inboxes, heartbeats, tags, queues, and held names (`held_name:<project>-*`) belonging only to the specified project. Passing `--all` performs a full namespace nuke.
  - Added poison-pill listener shutdown handler in `doListen`: listeners receiving message `type == "shutdown"` log a termination notice to stderr and exit immediately with code 0 without hanging or leaving zombie processes.
- **Sub-Millisecond Redis Health Check (`rhizo ping`)**:
  - Added `rhizo ping [--json]` CLI command for immediate Redis reachability checks and sub-millisecond round-trip latency reporting (`latency_ms`).
- **Identity Allocation Invariant & Multi-Agent Coordination Protocol**:
  - Codified the Identity Allocation Invariant in `AGENTS.md` and `src/guide.nim`: Agents operating in ephemeral subshells must invoke `rhizo name`, record their assigned codename in their reasoning context, and pass it explicitly to subsequent commands (`rhizo open <name>`, `rhizo listen <name>`).
  - Added self-bootstrapping `npx -y @axiomantic/rhizo` and `npx -y rift-snapshot` zero-install fallback documentation in `README.md`, `SKILL.md`, `skills/rhizo/SKILL.md`, and `src/guide.nim`.
- **Dedicated Test Coverage for Name Reservation & Reset**:
  - Added `tests/test_name_reservation.py` covering codename reservation, custom prefixes, JSON payloads, collision resistance, hold release on open, project-scoped `rhizo reset`, and `rhizo nuke`.

### Changed
- **Documentation Token Compression & Skill Modularization**:
  - Offloaded verbose coding-harness playbooks and tool matrices to dedicated reference files (`references/capability_archetypes.md` and `skills/rhizo/references/capability_archetypes.md`), reducing core `SKILL.md` from 1,400+ lines to ~150 lines for massive agent prompt token savings.
  - Updated `AGENTS.md` and `src/guide.nim` with streamlined rules and clear invariant markers.
  - Synchronized generated Cursor rules (`skills/rhizo/rules/cursor-rules.mdc`) and GitHub Copilot instructions (`.github/copilot-instructions.md`, `skills/rhizo/rules/copilot-instructions.md`).
- **Test Teardown Modernization & Strict Fail-Loud Discipline**:
  - Updated `setUp()` and `tearDown()` in `tests/test_name_reservation.py` and `tests/test_nim_binary.py` to use `rhizo nuke` with strict returncode assertions, eliminating silent `try...except` exception swallowing.

### Fixed
- **Legacy Environment Variable Compatibility**:
  - Updated `src/config.nim` to transparently fall back to legacy `LOCUTUS_*` environment variables (`LOCUTUS_REDIS_URL`, `LOCUTUS_REDIS_PREFIX`, `LOCUTUS_PROJECT`, `LOCUTUS_AGENT_NAME`, `LOCUTUS_SESSION_ID`, `LOCUTUS_SECRET`, `LOCUTUS_SECRET_FILE`, `LOCUTUS_ENCRYPT`), ensuring backward compatibility with older test harnesses and CI environments.

## [0.1.7] - 2026-09-29

### Added
- **Fat-Package Pre-Bundled Native Binaries**: Npm package now pre-bundles native compiled binaries for all 5 major platforms (`darwin-arm64`, `darwin-x64`, `linux-x64`, `linux-arm64`, `win32-x64.exe`) inside `bin/binaries/`.
- **Zero-Latency Offline Execution**: Invocations immediately execute the matching bundled native binary with zero network requests, zero `curl`/`powershell` execution, and complete air-gap/corporate-proxy support.
- **Supply-Chain Security Hardening**: Completely eliminated runtime unverified binary downloads, external shell executions, and supply-chain scanner red flags.

## [0.1.6] - 2026-09-29

### Added
- **Architecture-Aware Binary Bootstrapping**: `bin/run.js` now verifies host architecture via executable magic bytes (Mach-O arm64/x64, ELF amd64/arm64, Windows PE) and automatically downloads the appropriate release asset from GitHub Releases into `~/.cache/rhizo/bin/`.
- **SKILL.md Self-Bootstrapping Section 0**: Added clear instructions for agents encountering a missing `rhizo` CLI to run `npm install -g @axiomantic/rhizo`.

### Fixed
- **Release CI Multi-Platform Assets**: Fixed release workflow compiling `src/rhizo.nim` across Linux amd64/arm64, macOS arm64/amd64, and Windows amd64.
- **Pure Universal NPM Package**: Excluded host-specific binaries from npm packages, ensuring 100% cross-platform compatibility on initial install.

### Added
- **Native Task Routing Engine (`locu route`)**:
  - Declarative routing schema (`locu-routes.yaml` or `.locutus/routes.yaml`) dispatching unstructured task prompts directly to agent queues with matched tags and lease durations.
  - Integration with Laya System 1 decision models supporting `choice`, `score`, and `noul` (trigger) questions over HTTP.
  - Intelligent chunking and sliding-window aggregation strategies (`max_confidence`, `max`, `min`, `average`, `all`, `any`, `threshold`) with fail-fast limits.
  - Route configuration linter (`locu route lint [--check-service]`) validating question references, aggregation strategies, and endpoint availability.
- **Rule Compilation & Verification Pipeline (`scripts/compile_rules.py`)**:
  - Automated single-source rule generator compiling Cursor rules (`skills/locutus/rules/cursor-rules.mdc`) and GitHub Copilot instructions (`skills/locutus/rules/copilot-instructions.md` and `.github/copilot-instructions.md`) directly from canonical `AGENTS.md`.
  - Added strict dual-copy verification and synchronization between root `SKILL.md` and `skills/locutus/SKILL.md` in both compile and `--check` modes.
  - Added pre-commit hook in `.githooks/pre-commit` and CI drift assertion (`--check`) in `.github/workflows/ci.yml` and `scripts/ci/test.sh`.
- **Coding Harness Ear Verification Playbook**:
  - Dedicated 4-phase verification playbook (`docs/playbooks/coding-harness-ear-verification/SKILL.md`) using Computer Use / macOS-MCP to verify zero-touch idle listening, autonomous task acceptance, in-flight preemption, and turn-end re-arming.

### Changed
- **CLI & Runtime Telemetry Alignment**:
  - Standardized CLI `--help` text, subcommand usage examples, and table references to `locu` (preserving `locuti` and `locutus` as backward-compatible aliases).
  - Added `-a|--all` and `--json` flags to `locu who` CLI help text.
  - Annotated positional `[timeout_sec]` in CLI help to explicitly document `0` as the infinite wait default and discourage bounded polling timeouts.
  - Modernized `stderr` lifecycle post-amble upon listener exit to output clean capability-based re-arming instructions, and eliminated stale `SKILL.md Step 2/2b/2d` references.
- **Capability-Based Execution & Runtime Introspection**:
  - Replaced hardcoded harness matrices across `AGENTS.md`, `SKILL.md`, `README.md`, and `src/guide.nim` with a universal capability decision tree based on runtime tool introspection.
  - Established the Token Efficiency Hierarchy: strictly prioritizes Tier 1 in-process extensions and Tier 2 main-chat background daemon commands (`run_command(IsDaemon=true)`) over subagents to eliminate token overhead and maintain a direct line of interruption.
  - Codified the "No Double-Daemons" discipline and Subagent Completion Barrier: subagents report output only upon exit, requiring synchronous blocking execution (`locu listen <agent>`) inside subagent containers (`Task(background=true)`).
  - Enforced zero-timeout infinite wait default (`timeout = 0`) across all documentation, configurations, and instructions to permanently eliminate token thrashing from empty polling wakeups.
  - Synchronized embedded `locu guide install` in `src/guide.nim` with canonical `AGENTS.md`.
  - Streamlined `CONTRIBUTING.md` to remove lengthy MCP essays and bounded timeouts, directing developers to native CLI integration protocols.
  - Completely purged legacy MCP server mentions and negative priming across all instruction and rule files.

### Fixed
- **Documentation & Link Integrity**:
  - Resolved 10 broken Table of Contents anchors and removed duplicate header row in CLI reference table in `README.md`.
  - Updated Recipe 1 in `README.md` to decouple agent identity registration (`locu open`) from listener arming based on harness tool capabilities.
- **OpenCode Ear Desktop Runtime Compatibility**:
  - Added dual runtime detection in `opencode-ear.js` supporting both Bun (`Bun.spawn`) and Node/Electron (`child_process.spawn` + `readline.createInterface`), eliminating silent startup deafness in OpenCode Desktop GUI.
  - Fixed session auto-registration to resolve unmapped sessions on `session.created`, `syncSessions`, and `shell.env` without requiring manual commands.

## [0.1.3] - 2026-09-26

### Added
- **Primary CLI Command `locu`**: Renamed primary CLI executable to `locu` (with `locuti` and `locutus` preserved as 100% backward-compatible aliases).
- **GitHub Repository Migration**: Repository moved to `https://github.com/axiomantic/locu`.
- **NPM Package `@axiomantic/locu`**: Official distribution via npm with cross-platform native binaries for macOS (Apple Silicon & Intel), Linux (x86_64 & aarch64), and Windows.
- **Distributed Fencing Tokens for Locks (`locutus lock --fencing`)**: Concurrency guard against delayed zombie writes (`locutus lock <lock_name> [ttl_sec] [--fencing] [--raw]`). Automatically increments and returns a monotonic integer sequence counter stored at `${prefix}lock:fencing:<lock_name>` via `scripts/lock.lua`. Allows downstream storage, databases, and peer agents to detect and reject out-of-order writes from delayed processes whose lock leases have expired.
- **Cluster Health Watchdog & Sweeper (`locutus sweep`)**: Proactive cluster cleanup utility (`locutus sweep [--dry-run] [--raw]`). Scans active agent directories in Redis to prune entries whose heartbeats have lapsed, inspects listener locks across the cluster, and automatically removes orphaned listener locks tied to dead local PIDs via `scripts/sweep.lua` and host process verification.
- **Directed Acyclic Graph (DAG) Workflow Engine (`locutus workflow`)**: Declarative multi-stage pipeline coordination (`locutus workflow <define|next|resolve|fail|status> <flow_id>`). Supports complex DAG dependencies (`--deps "test:lint;build:lint;deploy:test,build"`), automatic dependency resolution, instant stage unlocking upon step completion, and failure handling via `scripts/workflow.lua`.
- **Leader Election via Lease Preemption (`locutus leader`)**: Fault-tolerant coordinator election (`locutus leader <acquire|renew|resign|status> <role>`). Employs lease TTLs and instant failover promotion via `scripts/leader.lua`, eliminating single points of failure across decentralized multi-agent meshes and orchestrator clusters.
- **Blind Voting & Ballot Consensus (`locutus ballot`)**: Unbiased consensus voting protocol (`locutus ballot <open|cast|tally|status> <ballot_id>`). Keeps individual agent votes sealed and hidden until officially tallied, eliminating anchoring bias and LLM sycophancy in multi-agent panels, architectural roundtables, and design decisions via `scripts/ballot.lua`.
- **Global Run Cancellation Tokens (`locutus cancel`)**: Coordinated run cancellation mechanism (`locutus cancel <run_id> [--reason ...]`, `locutus cancel check <run_id> [--exit-code|--raw]`, `locutus cancel clear <run_id>`). Sets an atomic cancellation token in Redis with reason, timestamp, and emitter metadata via `scripts/cancel.lua`, broadcasts to cancellation channels (`channel:cancellations` and `channel:cancel:<run_id>`), and enables background worker agents to cleanly abort runaway workflows before burning expensive AI tokens.
- **Floor Control & Speaker Ring (`locutus floor`)**: Turn-taking protocol for agent roundtables and collaborative meetings (`locutus floor <request|yield|pass|status> <room>`). Employs atomic FIFO waiter queues with auto-expiring speaker leases via `scripts/floor.lua` to prevent agents from interrupting or talking over one another.
- **Shared Blackboard & Scratchpad Memory (`locutus blackboard`)**: Room-scoped shared memory providing atomic key-value storage (`set`, `get`), append lists (`append`), key deletion (`delete`, `clear`), and complete room state snapshots (`snapshot`) in Redis via `scripts/blackboard.lua`. Eliminates massive token waste from re-transmitting large file bodies and conversational state across multi-turn agent chats.
- **Reliable Task Leases, Acking & Dead-Letter Queue (`locutus claim` / `locutus ack`)**: Non-destructive queue consumption using leases (`locutus claim <queue> [--lease 120]`) and explicit acknowledgment (`locutus ack <queue> <task_id>`). If a worker agent terminates or crashes before completion, the lease expiration triggers automatic retry or escalation to `dlq:<queue>` after 3 attempts via atomic `scripts/claim.lua`.
- **Scatter-Gather & Quorum Consensus (`locutus scatter`)**: Native orchestrator primitive for multicasting tasks across specialist pools (`--targets <@tag|agents|*>`) and gathering replies into a unified JSON array until a configurable quorum (`--quorum N`) is reached or timeout expires. Supports `--raw` output for shell piping and atomic target resolution via `scripts/scatter.lua`.
- **In-Flight Claim Lease Renewal (`locutus claim renew`)**: Safe lease extension primitive (`locutus claim renew <queue> <task_id> [--lease 120]`). Extends worker execution deadlines atomically via `scripts/claim_renew.lua` before long-running tasks expire and get reassigned to other workers.
- **Worker Cancellation Awareness (`--run-id`)**: Added `--run-id <run_id>` support to `locutus work` and `locutus claim`. Workers check cryptographic cancellation tokens on each iteration and post-claim, discarding aborted work and exiting cleanly in under 0.5s without burning expensive AI tokens.
- **Graceful Signal Trapping (`SIGINT` / `SIGTERM`)**: Added POSIX and Windows signal handlers in `src/locutus.nim` that automatically trap process termination signals and clean up active listener registrations, held floor locks, and waiter queues before exit, preventing orphaned locks.
- **Multi-Host Sweeper Provenance Reporting (`locutus sweep`)**: Added `foreign_listeners` metadata array to `locutus sweep` JSON output detailing foreign host listeners (`agent`, `host`, `pid`, `status: "foreign_active"`), preventing blind skipping across multi-node or multi-container clusters.
- **End-to-End Cryptography & Cryptographic Authentication**:
  - **Shared Blackboard Transparent AES-256 Encryption & HMAC Signatures**: Blackboard entries and snapshots are transparently encrypted with AES-256-CBC when `--encrypt` or `LOCUTUS_ENCRYPT=1` is active, and verified with HMAC-SHA256 signatures to detect and drop tampered entries.
  - **Cryptographic Cancellation Tokens**: Cancellation tokens embed canonical HMAC signatures (`run_id|reason|by|ts`) to prevent unauthenticated/forged denial-of-service aborts.
  - **Cryptographic Ballot Authentication**: Individual votes cast via `locutus ballot cast` embed voter HMAC signatures, ensuring untampered and unforgeable tally verification.
  - **Leader Election Authority Authentication**: Leader leases and renewals embed HMAC signatures (`role|leader|ts|lease_sec`), with automatic eviction and preemption of unauthenticated/forged rogue leader keys.
- **Custom Tripwire Plugin & Protocol Verifiers (`tests/tripwire_locutus.py`)**: Dedicated `tripwire.plugins` entry point (`locutus = "tests.tripwire_locutus:LocutusPlugin"`) implementing strict CLI command mocking and assertions, Redis Cluster slot affinity linter (`check_cluster_affinity`), canonical HMAC-SHA256 wire envelope validation (`validate_wire_envelope`), and complete JSON schema verifiers for all Locutus subcommands.
- **Comprehensive Green Mirage Audit & Tripwire Migration (TASK-GM-001 to TASK-GM-092 across 92 Tests)**:
  - **Group 2.1: Installer Test Suite (TASK-GM-001 to TASK-GM-009)**: Upgraded all 9 installer tests (`tests/test_installer.py`) with Level 5 assertion rigor, exact binary permissions (`0755`), byte-for-byte skill content equality, home directory snapshot immutability, complete Scoop/Homebrew/Release DAG schemas, negative controls, and tripwire sandbox verification.
  - **Group 2.2: LLM Agent & Multi-Agent PingPong (TASK-GM-010, TASK-GM-011)**: Upgraded end-to-end integration tests (`tests/test_llm_agent.py`, `tests/test_multi_agent_pingpong.py`) with exact prompt injection firewall assertions, negative control drops, wire envelope schema validation, multi-turn conversational sequencing, and tripwire environment sandboxing.
  - **Group 2.3: Nim Binary CLI Suite (TASK-GM-012 to TASK-GM-063)**: Upgraded all 52 CLI tests (`tests/test_nim_binary.py`) to Level 4/5 assertions. Added negative controls on argument parsing and unauthenticated payloads; verified byte-for-byte AES-256-CBC ciphertexts and HMAC-SHA256 signatures; validated exact JSON schemas for `who`, `status`, `config`, `sweep`, `blackboard`, `floor`, `ballot`, `leader`, and `workflow`; asserted PID lifecycle and singleton anti-stacking invariants; verified lock timeouts, work queues, DLQ routing, and scatter quorum clamping; verified zero unjustified test skips.
  - **Group 2.4: Redis Protocol & Lua Engine Suite (TASK-GM-064 to TASK-GM-092)**: Upgraded all 29 protocol tests (`tests/test_protocol.py`) to Level 4/5 rigor. Proved input validation negative controls on every Lua script (`scripts/*.lua`); asserted cluster hash tag `{...}` single-slot affinity; verified monotonic fencing token counter progression across contention cycles; proved atomic optimistic concurrency control (OCC) revision tracking on shared blackboard entries; asserted strict JSON array serialization of empty waiters in floor control; and proved natural TTL expiration, lazy directory auto-pruning, and complete keyspace cleanup upon agent unregistration.
- **Lua Script Argument Hardening & Input Sanitization**: Added strict input validation negative controls to all 14 Redis Lua scripts (`ack.lua`, `ballot.lua`, `blackboard.lua`, `cancel.lua`, `claim.lua`, `directory.lua`, `drain.lua`, `enqueue.lua`, `floor.lua`, `leader.lua`, `lock.lua`, `multicast.lua`, `register.lua`, `scatter.lua`, `send_o2o.lua`, `status.lua`, `sweep.lua`, `tag.lua`, `unlock.lua`, `unregister.lua`, `workflow.lua`), aborting immediately with `ERR: ...` on missing prefixes or required arguments.
- **Optimistic Concurrency Control (OCC) for Blackboard (`scripts/blackboard.lua`)**: Added atomic revision token counter tracking (`blackboard:{room}:rev`) with an optional `expected_rev` argument on mutations, rejecting stale concurrent writes with `ERR: OCC revision mismatch` while preserving existing room data.

### Fixed
- **Installer Local Skill Prioritization**: In `scripts/install.sh`, local skills directory (`skills/locutus`) is now preferentially resolved from the local repository or release payload before falling back to curling GitHub remote, enabling seamless offline and local development branch installation.
- **Socket Connection Reuse & Adaptive Backoff in `locutus claim`**: Replaced per-poll socket creation and teardown in `doClaim` with persistent client reuse and dynamic exponential backoff (250ms scaling up to 2000ms), eliminating `TIME_WAIT` socket exhaustion during empty queue polling.
- **Buffered RESP2 Stream Reading & 32MB Safety Guard**: Introduced internal 8KB buffer reading in `src/resp.nim` for high-throughput CRLF framing and bulk transfers, guarded against excessive allocations with a 32MB payload limit, and added an empty bulk string (`$0\r\n\r\n`) fast-path.
- **Poison Pill Head-of-Line Jamming Prevention**: In `scripts/claim.lua`, re-queued expired retries now use `LPUSH` to the tail instead of `RPUSH` to the front, preventing failing tasks from immediately blocking subsequent healthy queue items.
- **Scatter Quorum Clamping Safety**: In `src/locutus.nim` `doScatter`, `effectiveQuorum` is automatically clamped to `min(quorum, delivered)` when targets are reached, or `0` when `delivered == 0`, preventing workers from hanging when configured quorum exceeds available participants.
- **Sweeper Non-Blocking SCAN Protocol**: Replaced O(N) blocking `KEYS` command in `scripts/sweep.lua` with non-blocking cursor-based `SCAN` loops across active agents and listener keys to prevent Redis main-thread blocking.
- **Workflow DAG Validation & Cycle Detection**: Added topological sort cycle detection and dangling dependency checks in `scripts/workflow.lua` to fail fast with actionable error messages when cyclic or invalid dependencies are declared.
- **Redis Cluster Slot Affinity**: Enclosed shared entity keys in Redis cluster hash tags (`{...}`) across all multi-key Lua scripts (`claim.lua`, `ack.lua`, `floor.lua`, `ballot.lua`, `workflow.lua`, `blackboard.lua`, `leader.lua`, `lock.lua`, `unlock.lua`, `enqueue.lua`) and Nim queue/DLQ/floor resolution procs, ensuring single-slot affinity across Redis cluster deployments.
- **Sweeper Dead Agent Metadata & Tag Pruning**: In `scripts/sweep.lua`, corrected key references to extract agent tags from `agent:<name>` and delete reverse indexes from `tag:<tag>` sets alongside deleting the `agent:<name>` hash when pruning dead agents.
- **Floor Waiter Timeout Queue Dequeue**: In `src/locutus.nim` `doFloorRequest`, added automatic `LREM` cleanup to dequeue agents from `floor:<room>:waiters` when `--wait` timeout expires, preventing abandoned requests from hijacking subsequent speaker yields.
- **Workflow State Machine Failure Preservation**: In `scripts/workflow.lua`, ensured step resolution (`resolve`) only transitions pipeline status to `"running"` if `flow.status` is not already `"failed"`, preventing subsequent step resolutions from masking earlier step failures in DAG pipelines.
- **Floor Control JSON Serialization**: In `scripts/floor.lua`, corrected empty `waiters` list serialization from JSON `{}` (empty map) to `[]` (empty array) for strict API schema conformance.
- **Request O2O Routing to Target Agent**: Fixed regression in `doSend` destination queue routing where messages with `replyTo` keys (such as `locutus request`) routed directly to the ephemeral reply channel instead of `toAgent`. DestQueue routing now strictly checks that `msgType == "reply"` before routing to a reply channel.

## [0.1.2] - 2026-09-19

### Added
- **`locutus reply` First-Class Command**: Native CLI subcommand for replying directly to messages (`locutus reply --to <sender> --subject <subj> --body <body> [--reply-to <id>]`), automatically tagging the message with `type = reply`.
- **Atomic Listener Piggybacking (`--listen` / `-l`)**: Added `--listen` and `--listen-timeout` flags to `locutus send` and `locutus reply`. When enabled, Locutus delivers the outbound message, logs status to `stderr`, and seamlessly transitions the same running process into blocking wait on the agent's inbox. This prevents coding assistants from dropping background listeners during multi-turn work.
- **Singleton Listener Invariant & Anti-Stacking Guard**: Added strict singleton listener enforcement via Redis `${prefix}listener:${agent}` with process PID and hostname tracking. If `--listen` is called while another listener is already active for that agent, Locutus delivers the message and skips listening (exits 0) to prevent stacked background processes and Redis `BRPOP` competing-consumer queue splitting. Standalone `locutus listen` fails fast with code 1 unless `--force` / `-f` is specified. Stale locks from terminated processes on the same host are detected and self-healed instantly via `kill(pid, 0)`.
- **Expanded Skill Discovery & Distributed File Locking Guidance**: Enhanced the `locutus` skill frontmatter with explicit trigger phrases (`lock file`, `mutex lock`, `prevent concurrent edits`, `work queue`, `coordinate with the other terminal/agent`) to enable automatic skill invocation during parallel editing and multi-terminal operations. Added concrete file locking protocols (`locutus lock file:schema.prisma 60` / `locutus unlock file:schema.prisma`) to Section 1 and Section 3.C.
- **Capability-Based Dual-Strategy Ear Architecture in Skills**: Updated `SKILL.md` to instruct assistants to self-select their listener strategy based on native runtime tool capabilities rather than assistant brand names:
  - **Strategy A (Dedicated Ear Subagent)**: For runtimes supporting asynchronous subagent-to-parent messaging.
  - **Strategy B (Atomic Piggybacked Re-Arm)**: For single-agent / linear shell runtimes using `--listen`.

### Fixed
- **Conditional Listener Ownership Deletion on Exit**: Updated `doListen`'s cleanup block to verify that `locutus:listener:<name>` in Redis matches the terminating process's PID and hostname before deleting it. Prevents preempted or replaced listeners from having their locks wiped by an earlier process exiting.
- **Worker Heartbeat Starvation Prevention in `locutus work`**: Added automatic heartbeat and `active_agents` renewal during `doWork` chunked polling timeouts when an agent identity is resolved. Prevents idle worker processes waiting on task queues from expiring and being pruned from `locutus who`.
- **Directory Consistency in `status.lua`**: Added `SADD active_agents <name>` to `scripts/status.lua` to ensure that setting state or activity restores pruned agents to directory listings.
- **Cryptographic Error Handling**: Added null pointer check on OpenSSL `HMAC()` return value in `computeHmacSha256` to raise explicit `ValueError` on calculation failure.

## [0.1.1] - 2026-09-19

### Added
- **Silent Indefinite Blocking Listener**: `locutus listen` now defaults to indefinite blocking wait (`listenTimeout = 0`) with 60-second chunked internal polling and silent Redis heartbeat renewal (`SET heartbeat:<name> 1 EX 150`). Receivers now stay continuously registered in `locutus who` without exiting to the OS shell or waking the assistant.
- **Rule of Silence for Zero Token Churn**: Commands that timeout (`listen`, `work`, and `sub`) now return returncode `0` with 0 bytes on stdout (`""`), permanently eliminating token waste and death-by-a-thousand-tokencuts in AI context windows.
- **Indefinite Worker Queue**: `locutus work <queue>` now defaults to indefinite wait when no timeout is supplied, allowing worker pools to sit silently on Redis queues with zero token overhead.

### Changed
- **Continuous Ear Invariant in Skills**: Updated canonical `SKILL.md` (and synchronized mirrors) to strictly forbid wrapping shell loops (`while true; do ... done`). Assistants now launch bare `locutus listen` directly in the background and re-arm immediately only upon receipt of an authenticated message.
- **Ephemeral Pub/Sub Silence**: `locutus sub` now outputs 0 bytes on timeout instead of printing `(nil)`.

## [0.1.0] - 2026-09-19

### Added
- **Pure-Nim Daemonless Client**: Single compiled binary built with Nim standard library (`std/net`, `std/openssl`), utilizing an embedded pure-Nim RESP socket client with zero external runtime dependencies.
- **Out-of-Band Cryptographic Security**:
  - HMAC-SHA256 signature verification over all inter-agent messages, acting as an air-gap prompt-injection firewall to drop forged and tampered packets.
  - In-memory AES-256-CBC envelope encryption via native OpenSSL EVP C-bindings (`EVP_aes_256_cbc`, PBKDF2 SHA-256 with 10,000 iterations) with zero temporary files on disk.
  - Zero-friction key storage at `~/.config/locutus/secret` (`0600` permissions) with auto-generated 256-bit entropy.
- **Peer Discovery & Directory Service (`locutus who`)**:
  - Real-time active agent registry backed by Redis hashes and sets.
  - Automatic on-query dead-agent pruning for expired heartbeats.
  - Cluster-wide discovery flags (`-a`, `--all`, `*`) and structured JSON output (`--json`, `-j`).
- **Core Messaging Protocols**:
  - Direct point-to-point (O2O) task, query, reply, and status delivery (`locutus send`).
  - Multicast (O2M) messaging with multi-tag filtering (`locutus broadcast`).
  - Keyspace isolation via `LOCUTUS_PROJECT` and `{...}` hash tags for Redis Cluster compatibility.
  - Offline message queuing and ordered inbox backlog recovery (`locutus drain`).
- **Distributed Coordination Primitives**:
  - Synchronous RPC (`locutus request`) with blocking timeout and raw payload piping (`--raw`).
  - Competing-consumers work queues (`locutus enqueue` and `locutus work`) for parallel worker teams.
  - Distributed mutual exclusion locks (`locutus lock` and `locutus unlock`) with TTL lease hygiene.
  - Ephemeral real-time streaming (`locutus pub` and `locutus sub`).
  - Live agent operational state and activity tracking (`locutus status`).
- **Host & Multi-Terminal Isolation**:
  - Multi-tiered agent identity resolution prioritizing CLI arguments, `LOCUTUS_AGENT_NAME` process environment variables, session ID mappings, and user-level fallbacks.
  - Automatic listener auto-registration into live directory sets.
- **Universal Assistant Integration**:
  - Canonical agent skill specification in `skills/locutus/SKILL.md` compatible with Claude Code, Antigravity, Cursor, OpenCode, Codex, and Hermes via `npx skills` and `skilz`.
  - Zero-CPU, zero-token background listener discipline via Redis `BRPOP`.
- **Cascading Configuration System**:
  - Configuration hierarchy: CLI Flags -> Env Vars -> Workspace Config (`.locutus.toml`) -> User Config (`~/.config/locutus/locutus.toml`) -> Defaults.
  - Multiple environment profiles (`dev`, `staging`, `prod`).
  - Configuration inspection and initialization CLI (`locutus config show|get|path|init`).
- **Cross-Platform Distribution & Packaging**:
  - Official Homebrew formula in `axiomantic/homebrew-tap` (`brew install axiomantic/tap/locutus`).
  - Official Debian/Ubuntu APT repository deployed on GitHub Pages.
  - Windows Scoop manifest in `packaging/scoop/locutus.json`.
  - Universal 1-line installer and uninstaller scripts (`scripts/install.sh`, `scripts/install.ps1`).
  - Cross-compilation release pipeline generating standalone binaries and tarballs for Linux (amd64, arm64), macOS (Apple Silicon, Intel), and Windows (x64).

[Unreleased]: https://github.com/axiomantic/locu/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/axiomantic/locu/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/axiomantic/locu/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/axiomantic/locu/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/axiomantic/locu/releases/tag/v0.1.0
