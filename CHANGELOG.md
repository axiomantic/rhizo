# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Pure Redis Strand State Management & Three-Key Ratification Gate (`scripts/strand.lua`, `src/rhizo.nim`, `tests/test_strand_lua.py`)**:
  - Implemented pure Redis strand state management in `scripts/strand.lua`, completely eliminating on-disk `.vine.json` dependency.
  - Supported actions: `create`, `submit`, `ratify`, `reject`, `weave`, `get`, and `list` across lifecycle states (`PROVISIONED`, `SUBMITTED`, `RATIFIED`, `REJECTED`, `WOVEN`).
  - Enforced atomic ratification invariants in Lua: verifies independent auditor (`auditor_pubkey != author_pubkey`), checks active auditor heartbeat lease, checks anti-blink temporal floor, and updates state and index sets atomically.
  - Added comprehensive automated test suite `tests/test_strand_lua.py`.
- **Dedicated CLI Subcommand Help Handling (`src/rhizo.nim`, `tests/test_cli_help.py`)**:
  - Implemented early intercept for `--help` and `-h` across all subcommands (`listen`, `send`, `reply`, `broadcast`, `open`, `claim`, `work`, `lock`, `unlock`, `probe`, `who`, `watchdog`, `leader`, `route`, `config`, etc.).
  - Fixed issue where `rhizo listen --help` and `rhizo listen <name> --help` would fail on missing agent name or start blocking/hanging indefinitely on Redis.
  - Subcommand help now outputs detailed command-specific usage and options to stdout and exits with code 0 immediately without opening Redis connections or performing network I/O.
  - Added support for `rhizo help <subcommand>` and `rhizo --help <subcommand>`.
  - Added comprehensive automated test suite `tests/test_cli_help.py` asserting exit code 0, non-blocking execution, and proper isolation with unreachable Redis configurations.

## [0.2.26] - 2026-10-24

### Added
- **Autonomous Dispatch Fast-Path & Interactive Intake Discipline (`src/guide.nim`, `AGENTS.md`, `SKILL.md`, `tests/test_guide.py`)**:
  - Updated Section 8 'Orchestrator Non-Implementation & Intake Gate' in Rhizo Guide `v1.9` across `src/guide.nim`, `AGENTS.md`, `SKILL.md`, and compiled instruction rules.
  - Added Pre-Authorized Directives & Active Fleet Fast-Path: When the operator instructs 'work on this with your workers', 'delegate this', or when active cluster workers exist in `rhizo who --all`, orchestrators must not stop to ask routing questions, but immediately break down work, provision strands, and dispatch over Rhizo (`rhizo send`) or enqueue to work queues.
  - Mandated `ask_question` Tool Discipline: If operator routing input is genuinely required (true cold start with 0 workers), orchestrators must invoke the interactive `ask_question` tool and are strictly prohibited from dumping numbered multiple-choice text lists into raw chat.
  - Added Fleet-First Mandate: When online workers exist, never output copy-paste prompt cards to the human operator; dispatch or repurpose existing workers over Rhizo.
  - Added unit test coverage in `tests/test_guide.py` (`test_guide_section_8_autonomous_dispatch_discipline`).
- **Single-Orchestrator Leader Lease Guide Invariant & Alias Deprecation (`src/guide.nim`, `src/rhizo.nim`, `tests/test_guide.py`, `AGENTS.md`)**:
  - Bumped Rhizo Guide to `v1.9` in `src/guide.nim` with the `Single-Orchestrator Mutual Exclusion via Leader Leases` invariant, requiring orchestrators to acquire `orchestrator:<project>` with 7200s lease and forbidding leadership usurpation if held.
  - Added `Deprecation of Aliases in Favor of Sovereign Handles & Capability Tags` invariant, deprecating `rhizo alias` in favor of unique codenames and capability tags.
  - Purged references to `garden-swarm.json` and `<project>-orchestrator` across `src/guide.nim`, `src/rhizo.nim`, `AGENTS.md`, and instruction rules.
  - Marked `rhizo alias` as deprecated in CLI help text and subcommand execution warning.
  - Updated `tests/test_guide.py` with affirmative and negative assertions for `v1.9` invariants.
- **Compile-Time Changelog Table & Protocol Upgrade Notifications (`src/changelog_data.nim`, `src/upgrade_notify.nim`, `src/rhizo.nim`, `tests/test_changelog_diff.nim`, `tests/test_coordination_invariants.py`)**:
  - Implemented zero-I/O compile-time changelog parsing via `staticRead("../CHANGELOG.md")` into a typed `EmbeddedChangelog` table.
  - Implemented `getChangelogDiff(fromVer, toVer: string): string` range slicer supporting 1-version increments, multi-version jumps, and latest release highlights.
  - Implemented dynamic skill discovery (`getDiscoveredSkills`) enumerating `skills/` at build and run time, partitioning into core tool and subsidiary skills for smart reload guidance.
  - Implemented session-specific Redis upgrade tracking via `agent:<name> -> last_version_notified:rhizo` and `last_version_notified_at:rhizo`.
  - Implemented Dual-Delivery Architecture: Proactive Push via `notifyClusterOfUpgrade` enqueuing signed `system:upgrade` directives to active worker inboxes and waking listeners; and Reactive Pull fallback emitting structured `<!-- RHIZO_PROTOCOL_UPGRADE_RIDER -->` on interactive CLI turns.
  - Enforced strict machine command exemptions: `--version`, `--help`, `--json`, `ping`, and completion commands never advance watermarks or emit riders.
  - Added hermetic unit tests in `tests/test_changelog_diff.nim` and comprehensive integration test `test_38_session_protocol_upgrade_notification` in `tests/test_coordination_invariants.py`.

## [0.2.25] - 2026-10-22

### Added
- **Swarm Reassignment & Repurposing Directives (`src/rhizo.nim`, `tests/test_coordination_invariants.py`)**:
  - Implemented `rhizo reassign <worker> --project <project> --role <role> [--tags <tags>] [--queue <queue>] [--json]` (aliased as `rhizo repurpose`) for dynamically redirecting active cluster workers to new projects and roles.
  - Dispatches authenticated `SWARM_REASSIGN` directive payloads over Redis with automatic tag configuration.
  - Enhanced `doListen` with specialized `[RHIZO SWARM REASSIGNMENT DIRECTIVE DELIVERED]` lifecycle rider, instructing workers to run `rhizo tag add`, broadcast `WORKER_READY`, and re-arm listeners.
  - Added `test_37_rhizo_reassign_swarm_directive` to test suite.
- **Task Roadmap CLI & Botanical Auto-Sowing (`src/rhizo.nim`, `tests/test_coordination_invariants.py`)**:
  - Implemented `rhizo roadmap` and `rhizo task roadmap` subcommands supporting `--json`, `--markdown`, `--write`, and `--sync`.
  - Added automated botanical seed sowing (`autoSowGardenTask`) into `.garden/seeds/<task_id>.toml` on `rhizo task create`.
  - Added automated harvest reconciliation (`autoHarvestGardenTask`) marking seeds `status = "WOVEN"` upon `rhizo task complete` and triggering roadmap sync.
  - Added `test_36_task_roadmap_and_garden_autosow` to test suite.
- **Redis Persistence Advisory Check (`src/rhizo.nim`, `src/config.nim`)**:
  - Added startup persistence advisory check for Lead Orchestrator sessions to verify Redis AOF/RDB configuration.
  - Added `rhizo config redis-persistence` CLI tool with `--status`, `--enable`, and `--disable-warning` flags, and `check_persistence` config setting.
- **Operator-Named Worker Delegation Mandate (`AGENTS.md`, `src/guide.nim`, `skills/rhizo/SKILL.md`)**:
  - Codified mandatory direct routing to operator-named workers over Rhizo, prohibiting single-project roster gating or fallback to subagents.
- **Anti-Defeat-Device & Autonomous Intensive Audit Mandates (`AGENTS.md`, `src/guide.nim`, `skills/rhizo/SKILL.md`)**:
  - Added the Anti-Defeat-Device & Anti-Theatrical Interceptor Mandate to Section 11 of the Rhizo Guide: strictly prohibits prompt keyword interceptors and theatrical mock questionnaires in production code.
  - Codified the Autonomous Intensive Audit Mandate: intensive Five-Pillar adversarial audits are Standard Operating Procedure (SOP), pre-authorized, and autonomous across the Triad without requiring operator confirmation.

### Fixed
- **Active Listener Liveness & Query Resolution (`scripts/directory.lua`, `src/rhizo.nim`)**:
  - Enhanced `scripts/directory.lua` to support exact agent codename queries (`rhizo who <agent>`).
  - Active listeners (`has_listener == 1`) are now unconditionally reported as `alive = 1` (`status: "ACTIVE"`).
  - Enhanced `doListen` to refresh `last_seen` timestamp in `agent:<name>` on initial arming and every chunk timeout renewal, eliminating false-stale timeouts.
  - Added `test_35_who_query_and_active_listener_liveness` to test suite.

## [0.2.24] - 2026-10-19

### Added
- **Codex-Native Wakeup Protocol (`RHIZO_WAKE`)**:
  - Implemented compact, zero-polling wakeup protocol for OpenAI Codex Desktop and CLI using the exact shorthand `RHIZO_WAKE`.
  - Added reverse session resolution functions (`getLocalSessionKeyForAgent`, `getRedisSessionKeyForAgent`, `resolveAgentSession`) supporting bidirectional lookups between session keys and agent names.
  - Enhanced `rhizo session get <agent|session_key>` to support reverse lookups, `--thread-id` extraction, and `--json` structured output.
  - Added `rhizo session resolve <agent|session_key> [--json]` for deep session inspection, thread ID resolution, and native wakeup guidance.
  - Enhanced `rhizo send` to detect Codex recipients and output structured `[RHIZO CODEX-WAKE ACTION]` blocks (and `wake_tool_call` in `--json`), providing exact parameters for `send_message_to_thread(thread_id="<id>", message="RHIZO_WAKE")`.
  - Enhanced `rhizo reply` with routine ACK guidance prohibiting wakeups on routine acknowledgments to eliminate ACK ping-pong loops.
  - Added comprehensive protocol documentation in `skills/rhizo/references/codex_wakeup_protocol.md` and updated `SKILL.md` Section 3 / 3.5.
  - Added comprehensive test coverage in `tests/test_nim_binary.py` (`test_71_codex_native_wakeup_protocol`).

### Changed
- Updated conflicting Codex guidance in `src/rhizo.nim`, `SKILL.md`, and `capability_archetypes.md` that previously treated Stop hooks or background process completion as proof of autonomous idle turn resumption.

## [0.2.23] - 2026-10-19

### Added
- **First-Class `rhizo inbox` Subcommand (`src/rhizo.nim`, `scripts/peek.lua`, `tests/test_nim_binary.py`)**:
  - Added dedicated `rhizo inbox [name] [count] [--limit N] [--peek|--no-drain] [--drain]` command for consuming or inspecting agent inboxes.
  - Defaults to **draining** (atomically popping messages FIFO oldest first) so that messages are consumed without piling up.
  - Added non-destructive inspection via `--peek` and `--no-drain` flags (backed by Redis `LRANGE` via `scripts/peek.lua`), leaving inbox queues untouched.
  - Added `--limit <N>` and `-l <N>` flags across both `rhizo inbox` and `rhizo drain`.
  - Added support for polymorphic positional arguments (`rhizo inbox <agent> [count]` or `rhizo inbox [count] [agent]`), resolving the active session agent if omitted.
  - Added command suggestions directing `rhizo mail`, `rhizo mailbox`, and `rhizo messages` to `rhizo inbox`.

## [0.2.22] - 2026-10-18

### Added
- **Unbootstrapped Session Identity & Active Listener Hijacking Guardrails (`src/rhizo.nim`, `src/guide.nim`, `skills/rhizo/SKILL.md`)**:
  - Added explicit warning messages to `rhizo listen` when refusing duplicate listeners, warning AI assistants against killing active listener PIDs or assuming they are orphaned.
  - Added guidance when no agent name is specified, prohibiting unbootstrapped sessions from guessing identities from `rhizo who` or `garden-swarm.json`.
  - Bumped Rhizo Guide to `v1.8` with the `Unbootstrapped Session Identity Invariant` and `Never Hijack or Kill Another Session's Active Listener` rule.

## [0.2.21] - 2026-10-17

### Added
- **Triad Update Checking Engine (`src/update.nim`, `src/rhizo.nim`)**:
  - Unified 24-hour update cadence checking for `garden`, `rhizo`, and `vine` cached in `~/.config/axiomantic/updates.json`.
  - Smart installation kind auto-detection (`dev_source` git checkout, `local_npm`, `homebrew`, `pnpm`, `yarn`, `bun`, `standalone_binary`, `global_npm`).
  - Automatic `<!-- TRIAD_UPDATE_RIDER -->` prompt riders attached to `rhizo who` and `rhizo ping` during interactive use.
  - Full suppression in Autonomous Mode (`AUTONOMOUS_MODE=1` or `.autonomous`) and JSON mode (`--json`).
  - Added `rhizo update` subcommand supporting `--check`, `--apply`, `--skip <pkg@ver>`, `--disable`, `--enable`, and `--json`.
- **Garden Guide v2.2 & Vine Guide v1.6 (`AGENTS.md`)**:
  - Embedded Three-Key Gate (Mechanical, Semantic, Adversarial Code Audit Pump) and Literal Fidelity & Reference Parity Mandate.
  - Structural Assertion Rigor eliminating Green Mirages.

### Fixed
- **Packaging & CI Cross-Platform Hardening (`Formula/rhizo.rb`, `packaging/scoop/rhizo.json`, `src/rhizo.nim`, `tests/test_coordination_invariants.py`)**:
  - Synced Homebrew formula and Scoop manifest specs with repository version `0.2.21`.
  - Added `findExe("garden")` check in `rhizo listen --roster-guard` to properly fail-open when garden is not installed.
  - Added path-aware test skips in `test_24` and `test_29` when external peer CLIs (`vine`, `garden`) are not in PATH.

## [0.2.20] - 2026-10-15

### Added
- **Distributed Cron & Heartbeat Scheduler (`rhizo pulse`, `scripts/pulse.lua`, `src/rhizo.nim`)**:
  - Implemented distributed recurring cron scheduling backed by Redis sorted sets (`rhizo:pulses`) with an atomic Lua execution engine.
  - Subcommands:
    - `rhizo pulse add <id> --cron "<expr>" --task "<task>" [--agent <agent>] [--scope <scope>]`: Schedules a recurring cron task with standard 5-field syntax.
    - `rhizo pulse list [--scope <scope>] [--json]`: Lists all active pulses with next execution timestamps, cron expressions, and assigned agents.
    - `rhizo pulse remove <id>`: Unregisters a scheduled pulse.
    - `rhizo pulse tick [--max <n>] [--json]`: Sweeps and dispatches ready pulses to target inboxes, atomically advancing cron intervals with HA zero-duplicate execution.
  - Added unit test suite in `tests/test_pulse.py`.
- **Rift CoW Terminology Normalization**:
  - Replaced legacy APFS copy-on-write references with generic, polyglot Rift CoW snapshotting across guides and prompt templates.
- **Fast Hermetic Test Configuration (`vine.toml`)**:
  - Configured project-level `test_command` in `vine.toml` targeting core coordination and pulse invariants, speeding up Strand Two-Key Gate verification from timeouts to ~14s.

## [0.2.19] - 2026-10-14

### Added
- **Antigravity Non-Yield Invariant in Lifecycle Notice (`src/rhizo.nim`)**:
  - Embedded explicit instructions in Section 2 of `[RHIZO LIFECYCLE NOTICE]` instructing workers in background-capable harnesses (Antigravity) to arm `rhizo listen` immediately upon task receipt and strictly choose Option A ("proceed to other relevant work") instead of Option B ("simply update the user... and end turn").
- **Anti-Premature-Yield Safety Guard in `rhizo reply` (`src/rhizo.nim`)**:
  - Emits a loud stderr warning when `--listen` is appended to a message whose subject indicates an initial task claim or acknowledgment (`CLAIM` or `ACK`), preventing workers from blocking or prematurely yielding their turn before implementing deliverables.
- **Reminder Scope & Project Boundary Isolation (`scripts/reminder.lua`, `src/rhizo.nim`)**:
  - Enforced project boundary isolation for `scope: "*"` reminders in `evaluate_piggyback`, `tick_candidates`, and `list` so project-scoped reminders do not leak across cluster boundaries to unrelated projects.
  - Added support for explicit `@global` scope for cross-project announcements.
  - Added `--author` (and `--author=`) flag alias for `--by` in `rhizo remind add`.
  - Added unit test coverage in `tests/test_coordination_invariants.py` (`test_28_reminder_project_isolation`).

### Fixed
- **Sender Identity Resolution Precedence (`src/rhizo.nim`)**:
  - Fixed `getActiveAgentName` invocation in `send` dispatcher to prevent ambient `sessionId` from erroneously overriding explicit `RHIZO_AGENT_NAME` environment variables.

## [0.2.18] - 2026-10-14

### Added
- **`rhizo probe` WISM In-Flight Task Telemetry (`src/rhizo.nim`)**:
  - Upgraded `rhizo probe <agent> [--json]` to inspect and report active WISM task telemetry (`current_task`, `task_state`, `task_progress`, `task_lease_remaining_sec`, `in_flight_active`).
  - Distinguishes actively executing workers (e.g. running Playwright/test suites) from stalled or offline workers, eliminating false `OFFLINE` diagnostics when single-shot foreground listeners have exited.
- **In-Flight Task Lease Liveness in `rhizo who` (`scripts/directory.lua`)**:
  - Extended in-flight task lease liveness in `scripts/directory.lua` to recognize `DELIVERED` tasks within their active delivery window alongside `IN_PROGRESS` and `CLAIMED`.
  - Propagates WISM task progress (`progress`) into agent `activity` output when no explicit activity is set.
- **Extended Task Delivery Window & Immediate ACK/Re-Arm Mandate (`src/rhizo.nim`)**:
  - Increased default delivery lease window in `doListen` from 180s to 900s (15 minutes).
  - Updated `[RHIZO LIFECYCLE NOTICE]` with an immediate task ACK/claim mandate, immediate background listener re-arming upon receipt in Tier 2 async harnesses (Antigravity), and periodic progress telemetry (`rhizo task progress <id> "Step X/Y"`) during operations taking >2 minutes.

### Fixed
- **Windows Platform Compatibility (`src/rhizo.nim`, `scripts/install.ps1`, `tests/`)**:
  - Resolved `start /B` shell builtin execution by using `cmd /c start /B` in `doRouteSetup`.
  - Added `USERPROFILE` environment fallback for Windows home directory resolution in hook installation.
  - Normalized command-line quote escaping in `test_coordination_invariants.py` and forced RESP2 protocol for legacy Windows Redis services.
  - Optimized `scripts/install.ps1` to re-use pre-built binaries and honor `RHIZO_SKIP_NPX=1`.
- **Nomenclature & Cleanup**:
  - Renamed all remaining legacy `Locutus` references across scripts, test suites, documentation, and hooks to `Rhizo` (including `tests/tripwire_locutus.py` -> `tests/tripwire_rhizo.py`).

## [0.2.17] - 2026-10-14

### Added
- **Closed-Circuit Two-Point Diff Mandate (Rhizo Guide v1.7)**:
  - Formally codified Section 11 in `guide.nim` (`v1.7`) and Section 2 in `SKILL.md`: every task deliverable must exhibit a Two-Point Diff: the Provider (new capability) and an active Consumer call-site in live entrypoints, routers, CLI dispatchers, or UI. Hermetic modules tested solely by their own unit tests are strictly prohibited as incomplete shelfware.
- **Holistic Production Integration (Anti-Stub / Anti-Toy)**:
  - Deliverables must actually holistically integrate with real application state and production error paths rather than mock heuristics or dummy stubs.
- **Aggressive Replacement Purge (Zero Dead Code)**:
  - Obsolete code, deprecated functions, and vestigial fallbacks targeted for replacement MUST be deleted in the same strand diff.

## [0.2.16] - 2026-10-13

### Added
- **Cross-Project Identity & Registration Protection (`scripts/register.lua`, `scripts/drain.lua`, `scripts/directory.lua`, `scripts/status.lua`)**:
  - Enforced strict project namespace isolation during agent registration (`rhizo open`) and inbox draining (`rhizo drain` / `rhizo listen`).
  - Rejects cross-project identity hijacking (`ERR_CROSS_PROJECT_HIJACK`) when an agent attempts to claim or drain an active codename belonging to a different project namespace, unless `--force` is passed or the registration has expired.
- **Directory vs. Environment Drift Guard (`src/config.nim`, `src/rhizo.nim`)**:
  - Implemented `checkProjectDrift` to detect mismatches between `RHIZO_PROJECT` / `RHIZO_PREFIX` environment variables and the current git repository root (`PWD`).
  - Prevents accidental cross-project message pollution when subshells or terminal tabs change directories without updating environment variables; added `--allow-drift` escape hatch.
- **Automated Multi-Harness Session ID Detection (`src/config.nim`)**:
  - Added `detectSessionId` to automatically identify and bind the calling coding harness session (`agy:<id>` via `ANTIGRAVITY_CONVERSATION_ID`/`ANTIGRAVITY_APP_DIR`, `claude:<id>` via `CLAUDE_SESSION_ID`/`CLAUDE_CODE`, `opencode:<id>` via `OPENCODE_SESSION_ID`, `codex:<id>` via `CODEX_SESSION_ID`, `pi:<id>` via `PI_SESSION_ID`, and terminal fallback `term:<tty>`).
- **Enhanced Cluster Sweep & Stale Lock Garbage Collection (`scripts/sweep.lua`, `src/rhizo.nim`)**:
  - Upgraded `rhizo sweep` to cross-verify process liveness, clean orphaned listener registrations, and prune expired project locks.
- **Comprehensive Dual-Onboarding Documentation Suite (`AGENTS.md`, `README.md`, `docs/`)**:
  - Authored `docs/architecture.md` (system topology, Redis keyspace, Lua atomicity), `docs/cli_reference.md` (complete command & flag taxonomy), `docs/wire_protocol.md` (JSON envelope schema & HMAC-SHA256 Air-Gap Prompt Firewall specification), `docs/wism_state_machine.md` (10-state WISM transitions & leases), and `docs/system_one_routing.md` (cascading ModernBERT/Laya routing rules).
  - Updated `AGENTS.md` and `README.md` with structured onboarding maps for both human developers and LLM agents.
- **Dependencies & Testing (`rhizo.nimble`, `tests/test_coordination_invariants.py`)**:
  - Updated `typestates` dependency requirement to `>= 0.13.0`.
  - Added 325 lines of cross-project isolation, session binding, and drift guard negative control tests.

## [0.2.15] - 2026-10-10

### Added
- **POSIX Double-Dash End-of-Options Pattern for Doorbell Wakeup (`rhizo poke <agent> -- <command...>`)**:
  - Added support for `-- <command...>` to pass custom wakeup commands without nested quotation marks or shell escaping headaches.
  - Automatically joins and shell-quotes trailing `argv` parameters, eliminating JSON string escaping errors in autonomous agent harnesses.
  - Retained `--cmd <command>` as a backwards-compatible option.
  - Added test coverage in `tests/test_coordination_invariants.py`.
- **Vine Guide v1.3 Synchronization**:
  - Updated Vine Coordination Guide in `AGENTS.md` to `v1.3` reflecting double-dash custom test runner invocation.

## [0.2.14] - 2026-10-09

### Added
- **Human Operator Absolute Override & Listener "ARM NOW" Invariant (Rhizo Guide v1.6)**:
  - Formally codified that operator prompts, commands, and slash commands in the interactive window ALWAYS take absolute precedence over in-flight tasks and cluster queues.
  - Established the "ARM NOW" imperative: `rhizo listen` is an immediate action, never a deferred post-task checklist item.
  - Updated `doListen` delivery lifecycle notices on stderr with `OPERATOR OVERRIDE PRIORITY` and `ARM NOW DISCIPLINE`.
- **WISM In-Flight Lease Liveness & Auto-Heartbeat**:
  - Added in-flight lease liveness tracking to `scripts/directory.lua` so workers actively holding valid leases are recognized as busy even if their background heartbeat is temporarily lagging.
  - Automated heartbeat renewal during task claim and progress events in `scripts/task.lua`.

## [0.2.13] - 2026-10-09

### Added
- **Automated Harness Hook & Ear Installers (`rhizo hook install`)**:
  - Implemented `rhizo hook install --opencode` and `rhizo hook install --pi` supporting global and `--local` scopes.
  - Automatically provisions `rhizo-ear.js` / `rhizo-ear.ts` into `.opencode/plugins` and `.pi/agent/extensions` via symlink, copying, or compiled embedded fallbacks.
  - Added unit test suite in `tests/test_hooks.py`.
- **Two-Key Gate Command Interlock**:
  - Integrated Vine Two-Key verification directly into `rhizo task complete` and `rhizo reply`.
  - Enforces that tasks with active Vine strands cannot be completed or acknowledged without passing mechanical merge pre-checks and live semantic test suites (`READY_FOR_WEAVE` with valid `gate_token`), preventing unverified commits from entering trunk.
- **OpenCode & Pi Ear Extension Supervisors**:
  - Added automated lease keep-alive heartbeats triggered during active tool calls and file edits, preventing long refactor turns from timing out.
  - Implemented in-flight run cancellation interrupts via Redis pub/sub (`RHIZO_INTERRUPT`), allowing operators and orchestrators to abort runaway sessions.
  - Added active advisory injection: automatically surfaces critical cluster reminders and self-audit guardrails into prompt contexts.
  - Added 22 integration tests in `tests/test_opencode_ear.test.js` and `tests/test_pi_ear.test.js`.
- **Garden Guide v1.8**:
  - Integrated Garden Guide v1.8 in `AGENTS.md` featuring the Active Swarm Fast-Path and elimination of standalone model pairing quizzes.

## [0.2.12] - 2026-10-09

### Added
- **Sovereign Session Invariant & Universal Subagent Prohibition (Rhizo Guide v1.5)**:
  - Formally established the Sovereign Session Invariant: cluster swarm workers are strictly independent interactive sessions (separate terminal tabs or IDE windows) bootstrapped via Garden prompt cards.
  - Harness-internal subagents (e.g. Antigravity's `invoke_subagent`, Claude Code's `Task`, OpenCode subtasks, Cursor sub-composers) are strictly prohibited from acting as cluster swarm workers across all harnesses.
  - Eliminated the fallback clause in Delegation Precedence that previously allowed subagent fallback during swarm intake; subagents are restricted solely to transient, single-turn ad-hoc inspections in non-swarm solo chats when explicitly requested by name.
  - Bumped `GuideVersion` to `v1.5` and updated `tests/test_guide.py`.

## [0.2.11] - 2026-10-07

### Changed
- **Watchdog Timer Protocol Clarification (Exempting Antigravity & OpenCode)**:
  - Updated Section 2 turn-end listener protocol in `skills/rhizo/SKILL.md` and `SKILL.md` to explicitly designate scheduled watchdog timers as strictly for OpenAI Codex / ChatGPT CLI.
  - Formally exempted Google Antigravity (where native background listener processes reactively wake the session on message receipt via `run_command(..., WaitMsBeforeAsync=500)`) and OpenCode (using background ear) from setting scheduled timers.

## [0.2.10] - 2026-10-07

### Fixed
- **Work Item State Machine Monotonicity Guards (`scripts/task.lua`)**:
  - Added strict state validation in `rhizo task claim`: prevents claiming tasks in `BLOCKED` (waiting on incomplete DAG dependencies), `COMPLETED`, `READY_TO_WEAVE`, and `DEAD_LETTER` states.
  - Added existence check in `rhizo task progress` to prevent creating phantom unindexed task keys in Redis when referencing non-existent task IDs.
  - Expanded orchestrator permission checks in `rhizo task complete` to accept project-scoped orchestrators (e.g. `<project>-orchestrator`) in addition to bare `orchestrator`.
- **Per-Agent Local Task Isolation (`src/rhizo.nim`)**:
  - Scoped local task mirroring to `~/.config/rhizo/current_task_<agent>.json` with backwards-compatible fallback to `current_task.json`.
  - Prevents race conditions, state clobbering, and spurious hook blocks when multiple worker agents operate concurrently on the same local host.
  - Wired per-agent path resolution across `doSend`, `doListen`, `doHookCodexStop`, `task claim`, `task complete`, and `task yield`.
- **Doorbell Wakeup IDE Buffer Safety (`rhizo poke`)**:
  - Restricted raw keystroke injection (`cmd & return`) in System Events fallback exclusively to recognized terminal emulators (`alacritty`, `kitty`, `wezterm`, `hyper`, `warp`).
  - Replaced raw keystroke injection for general GUI/IDE applications (Antigravity, Cursor, VS Code) with non-destructive macOS native notifications (`display notification ... with title "Rhizo Doorbell Wakeup"`), eliminating code buffer contamination while preserving operator notification.
- **Terminal Title Sanitization (`rhizo title`)**:
  - Added control character sanitization (filtering chars `< ' '` and `\x7f`) and disabled ANSI escape sequence output when `TERM=dumb`.

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
  - Added automatic Vine Rift CoW strand provisioning on `rhizo task claim` (`vine new <task_id>`) and Two-Key Gate verification (`vine gate`) before task completion.
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
  - Replaced remaining `RHIZO_VERSION` variables in universal install scripts (`install.sh`, `install.ps1`) with `RHIZO_VERSION`.

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
- **Complete Purge of Legacy Rhizo Backwards-Compatibility Fallbacks**:
  - Purged all `RHIZO_*` environment variable fallbacks in favor of canonical `RHIZO_*` (`RHIZO_REDIS_URL`, `RHIZO_PREFIX`, `RHIZO_PROJECT`, `RHIZO_AGENT_NAME`, `RHIZO_SESSION_ID`, `RHIZO_SECRET`, `RHIZO_ENCRYPT`, `RHIZO_CLUSTER`, `RHIZO_QUIET`).
  - Purged legacy `.rhizo.toml`, `rhizo.toml`, `.rhizo.json`, and `~/.config/rhizo` config search paths from `src/config.nim`.
  - Removed legacy `bin/rhizo` and `bin/locu` binary symlinks and `packaging/scoop/rhizo.json`.
  - Updated package names to `rhizo` across `pyproject.toml`, `package.json`, and `rhizo.nimble`.
  - Purged all legacy `RhizoEar` class aliases and `[rhizo-ear]` logs across OpenCode and Pi agent extensions.

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
  - Escaped Windows backslashes in `.rhizo.toml` file generator (`tests/test_nim_binary.py`) to prevent TOML escape character parsing errors.
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
  - Updated `src/config.nim` to transparently fall back to legacy `RHIZO_*` environment variables (`RHIZO_REDIS_URL`, `RHIZO_REDIS_PREFIX`, `RHIZO_PROJECT`, `RHIZO_AGENT_NAME`, `RHIZO_SESSION_ID`, `RHIZO_SECRET`, `RHIZO_SECRET_FILE`, `RHIZO_ENCRYPT`), ensuring backward compatibility with older test harnesses and CI environments.

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
  - Declarative routing schema (`locu-routes.yaml` or `.rhizo/routes.yaml`) dispatching unstructured task prompts directly to agent queues with matched tags and lease durations.
  - Integration with Laya System 1 decision models supporting `choice`, `score`, and `noul` (trigger) questions over HTTP.
  - Intelligent chunking and sliding-window aggregation strategies (`max_confidence`, `max`, `min`, `average`, `all`, `any`, `threshold`) with fail-fast limits.
  - Route configuration linter (`locu route lint [--check-service]`) validating question references, aggregation strategies, and endpoint availability.
- **Rule Compilation & Verification Pipeline (`scripts/compile_rules.py`)**:
  - Automated single-source rule generator compiling Cursor rules (`skills/rhizo/rules/cursor-rules.mdc`) and GitHub Copilot instructions (`skills/rhizo/rules/copilot-instructions.md` and `.github/copilot-instructions.md`) directly from canonical `AGENTS.md`.
  - Added strict dual-copy verification and synchronization between root `SKILL.md` and `skills/rhizo/SKILL.md` in both compile and `--check` modes.
  - Added pre-commit hook in `.githooks/pre-commit` and CI drift assertion (`--check`) in `.github/workflows/ci.yml` and `scripts/ci/test.sh`.
- **Coding Harness Ear Verification Playbook**:
  - Dedicated 4-phase verification playbook (`docs/playbooks/coding-harness-ear-verification/SKILL.md`) using Computer Use / macOS-MCP to verify zero-touch idle listening, autonomous task acceptance, in-flight preemption, and turn-end re-arming.

### Changed
- **CLI & Runtime Telemetry Alignment**:
  - Standardized CLI `--help` text, subcommand usage examples, and table references to `locu` (preserving `locuti` and `rhizo` as backward-compatible aliases).
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
- **Primary CLI Command `locu`**: Renamed primary CLI executable to `locu` (with `locuti` and `rhizo` preserved as 100% backward-compatible aliases).
- **GitHub Repository Migration**: Repository moved to `https://github.com/axiomantic/rhizo`.
- **NPM Package `@axiomantic/rhizo`**: Official distribution via npm with cross-platform native binaries for macOS (Apple Silicon & Intel), Linux (x86_64 & aarch64), and Windows.
- **Distributed Fencing Tokens for Locks (`rhizo lock --fencing`)**: Concurrency guard against delayed zombie writes (`rhizo lock <lock_name> [ttl_sec] [--fencing] [--raw]`). Automatically increments and returns a monotonic integer sequence counter stored at `${prefix}lock:fencing:<lock_name>` via `scripts/lock.lua`. Allows downstream storage, databases, and peer agents to detect and reject out-of-order writes from delayed processes whose lock leases have expired.
- **Cluster Health Watchdog & Sweeper (`rhizo sweep`)**: Proactive cluster cleanup utility (`rhizo sweep [--dry-run] [--raw]`). Scans active agent directories in Redis to prune entries whose heartbeats have lapsed, inspects listener locks across the cluster, and automatically removes orphaned listener locks tied to dead local PIDs via `scripts/sweep.lua` and host process verification.
- **Directed Acyclic Graph (DAG) Workflow Engine (`rhizo workflow`)**: Declarative multi-stage pipeline coordination (`rhizo workflow <define|next|resolve|fail|status> <flow_id>`). Supports complex DAG dependencies (`--deps "test:lint;build:lint;deploy:test,build"`), automatic dependency resolution, instant stage unlocking upon step completion, and failure handling via `scripts/workflow.lua`.
- **Leader Election via Lease Preemption (`rhizo leader`)**: Fault-tolerant coordinator election (`rhizo leader <acquire|renew|resign|status> <role>`). Employs lease TTLs and instant failover promotion via `scripts/leader.lua`, eliminating single points of failure across decentralized multi-agent meshes and orchestrator clusters.
- **Blind Voting & Ballot Consensus (`rhizo ballot`)**: Unbiased consensus voting protocol (`rhizo ballot <open|cast|tally|status> <ballot_id>`). Keeps individual agent votes sealed and hidden until officially tallied, eliminating anchoring bias and LLM sycophancy in multi-agent panels, architectural roundtables, and design decisions via `scripts/ballot.lua`.
- **Global Run Cancellation Tokens (`rhizo cancel`)**: Coordinated run cancellation mechanism (`rhizo cancel <run_id> [--reason ...]`, `rhizo cancel check <run_id> [--exit-code|--raw]`, `rhizo cancel clear <run_id>`). Sets an atomic cancellation token in Redis with reason, timestamp, and emitter metadata via `scripts/cancel.lua`, broadcasts to cancellation channels (`channel:cancellations` and `channel:cancel:<run_id>`), and enables background worker agents to cleanly abort runaway workflows before burning expensive AI tokens.
- **Floor Control & Speaker Ring (`rhizo floor`)**: Turn-taking protocol for agent roundtables and collaborative meetings (`rhizo floor <request|yield|pass|status> <room>`). Employs atomic FIFO waiter queues with auto-expiring speaker leases via `scripts/floor.lua` to prevent agents from interrupting or talking over one another.
- **Shared Blackboard & Scratchpad Memory (`rhizo blackboard`)**: Room-scoped shared memory providing atomic key-value storage (`set`, `get`), append lists (`append`), key deletion (`delete`, `clear`), and complete room state snapshots (`snapshot`) in Redis via `scripts/blackboard.lua`. Eliminates massive token waste from re-transmitting large file bodies and conversational state across multi-turn agent chats.
- **Reliable Task Leases, Acking & Dead-Letter Queue (`rhizo claim` / `rhizo ack`)**: Non-destructive queue consumption using leases (`rhizo claim <queue> [--lease 120]`) and explicit acknowledgment (`rhizo ack <queue> <task_id>`). If a worker agent terminates or crashes before completion, the lease expiration triggers automatic retry or escalation to `dlq:<queue>` after 3 attempts via atomic `scripts/claim.lua`.
- **Scatter-Gather & Quorum Consensus (`rhizo scatter`)**: Native orchestrator primitive for multicasting tasks across specialist pools (`--targets <@tag|agents|*>`) and gathering replies into a unified JSON array until a configurable quorum (`--quorum N`) is reached or timeout expires. Supports `--raw` output for shell piping and atomic target resolution via `scripts/scatter.lua`.
- **In-Flight Claim Lease Renewal (`rhizo claim renew`)**: Safe lease extension primitive (`rhizo claim renew <queue> <task_id> [--lease 120]`). Extends worker execution deadlines atomically via `scripts/claim_renew.lua` before long-running tasks expire and get reassigned to other workers.
- **Worker Cancellation Awareness (`--run-id`)**: Added `--run-id <run_id>` support to `rhizo work` and `rhizo claim`. Workers check cryptographic cancellation tokens on each iteration and post-claim, discarding aborted work and exiting cleanly in under 0.5s without burning expensive AI tokens.
- **Graceful Signal Trapping (`SIGINT` / `SIGTERM`)**: Added POSIX and Windows signal handlers in `src/rhizo.nim` that automatically trap process termination signals and clean up active listener registrations, held floor locks, and waiter queues before exit, preventing orphaned locks.
- **Multi-Host Sweeper Provenance Reporting (`rhizo sweep`)**: Added `foreign_listeners` metadata array to `rhizo sweep` JSON output detailing foreign host listeners (`agent`, `host`, `pid`, `status: "foreign_active"`), preventing blind skipping across multi-node or multi-container clusters.
- **End-to-End Cryptography & Cryptographic Authentication**:
  - **Shared Blackboard Transparent AES-256 Encryption & HMAC Signatures**: Blackboard entries and snapshots are transparently encrypted with AES-256-CBC when `--encrypt` or `RHIZO_ENCRYPT=1` is active, and verified with HMAC-SHA256 signatures to detect and drop tampered entries.
  - **Cryptographic Cancellation Tokens**: Cancellation tokens embed canonical HMAC signatures (`run_id|reason|by|ts`) to prevent unauthenticated/forged denial-of-service aborts.
  - **Cryptographic Ballot Authentication**: Individual votes cast via `rhizo ballot cast` embed voter HMAC signatures, ensuring untampered and unforgeable tally verification.
  - **Leader Election Authority Authentication**: Leader leases and renewals embed HMAC signatures (`role|leader|ts|lease_sec`), with automatic eviction and preemption of unauthenticated/forged rogue leader keys.
- **Custom Tripwire Plugin & Protocol Verifiers (`tests/tripwire_rhizo.py`)**: Dedicated `tripwire.plugins` entry point (`rhizo = "tests.tripwire_rhizo:RhizoPlugin"`) implementing strict CLI command mocking and assertions, Redis Cluster slot affinity linter (`check_cluster_affinity`), canonical HMAC-SHA256 wire envelope validation (`validate_wire_envelope`), and complete JSON schema verifiers for all Rhizo subcommands.
- **Comprehensive Green Mirage Audit & Tripwire Migration (TASK-GM-001 to TASK-GM-092 across 92 Tests)**:
  - **Group 2.1: Installer Test Suite (TASK-GM-001 to TASK-GM-009)**: Upgraded all 9 installer tests (`tests/test_installer.py`) with Level 5 assertion rigor, exact binary permissions (`0755`), byte-for-byte skill content equality, home directory snapshot immutability, complete Scoop/Homebrew/Release DAG schemas, negative controls, and tripwire sandbox verification.
  - **Group 2.2: LLM Agent & Multi-Agent PingPong (TASK-GM-010, TASK-GM-011)**: Upgraded end-to-end integration tests (`tests/test_llm_agent.py`, `tests/test_multi_agent_pingpong.py`) with exact prompt injection firewall assertions, negative control drops, wire envelope schema validation, multi-turn conversational sequencing, and tripwire environment sandboxing.
  - **Group 2.3: Nim Binary CLI Suite (TASK-GM-012 to TASK-GM-063)**: Upgraded all 52 CLI tests (`tests/test_nim_binary.py`) to Level 4/5 assertions. Added negative controls on argument parsing and unauthenticated payloads; verified byte-for-byte AES-256-CBC ciphertexts and HMAC-SHA256 signatures; validated exact JSON schemas for `who`, `status`, `config`, `sweep`, `blackboard`, `floor`, `ballot`, `leader`, and `workflow`; asserted PID lifecycle and singleton anti-stacking invariants; verified lock timeouts, work queues, DLQ routing, and scatter quorum clamping; verified zero unjustified test skips.
  - **Group 2.4: Redis Protocol & Lua Engine Suite (TASK-GM-064 to TASK-GM-092)**: Upgraded all 29 protocol tests (`tests/test_protocol.py`) to Level 4/5 rigor. Proved input validation negative controls on every Lua script (`scripts/*.lua`); asserted cluster hash tag `{...}` single-slot affinity; verified monotonic fencing token counter progression across contention cycles; proved atomic optimistic concurrency control (OCC) revision tracking on shared blackboard entries; asserted strict JSON array serialization of empty waiters in floor control; and proved natural TTL expiration, lazy directory auto-pruning, and complete keyspace cleanup upon agent unregistration.
- **Lua Script Argument Hardening & Input Sanitization**: Added strict input validation negative controls to all 14 Redis Lua scripts (`ack.lua`, `ballot.lua`, `blackboard.lua`, `cancel.lua`, `claim.lua`, `directory.lua`, `drain.lua`, `enqueue.lua`, `floor.lua`, `leader.lua`, `lock.lua`, `multicast.lua`, `register.lua`, `scatter.lua`, `send_o2o.lua`, `status.lua`, `sweep.lua`, `tag.lua`, `unlock.lua`, `unregister.lua`, `workflow.lua`), aborting immediately with `ERR: ...` on missing prefixes or required arguments.
- **Optimistic Concurrency Control (OCC) for Blackboard (`scripts/blackboard.lua`)**: Added atomic revision token counter tracking (`blackboard:{room}:rev`) with an optional `expected_rev` argument on mutations, rejecting stale concurrent writes with `ERR: OCC revision mismatch` while preserving existing room data.

### Fixed
- **Installer Local Skill Prioritization**: In `scripts/install.sh`, local skills directory (`skills/rhizo`) is now preferentially resolved from the local repository or release payload before falling back to curling GitHub remote, enabling seamless offline and local development branch installation.
- **Socket Connection Reuse & Adaptive Backoff in `rhizo claim`**: Replaced per-poll socket creation and teardown in `doClaim` with persistent client reuse and dynamic exponential backoff (250ms scaling up to 2000ms), eliminating `TIME_WAIT` socket exhaustion during empty queue polling.
- **Buffered RESP2 Stream Reading & 32MB Safety Guard**: Introduced internal 8KB buffer reading in `src/resp.nim` for high-throughput CRLF framing and bulk transfers, guarded against excessive allocations with a 32MB payload limit, and added an empty bulk string (`$0\r\n\r\n`) fast-path.
- **Poison Pill Head-of-Line Jamming Prevention**: In `scripts/claim.lua`, re-queued expired retries now use `LPUSH` to the tail instead of `RPUSH` to the front, preventing failing tasks from immediately blocking subsequent healthy queue items.
- **Scatter Quorum Clamping Safety**: In `src/rhizo.nim` `doScatter`, `effectiveQuorum` is automatically clamped to `min(quorum, delivered)` when targets are reached, or `0` when `delivered == 0`, preventing workers from hanging when configured quorum exceeds available participants.
- **Sweeper Non-Blocking SCAN Protocol**: Replaced O(N) blocking `KEYS` command in `scripts/sweep.lua` with non-blocking cursor-based `SCAN` loops across active agents and listener keys to prevent Redis main-thread blocking.
- **Workflow DAG Validation & Cycle Detection**: Added topological sort cycle detection and dangling dependency checks in `scripts/workflow.lua` to fail fast with actionable error messages when cyclic or invalid dependencies are declared.
- **Redis Cluster Slot Affinity**: Enclosed shared entity keys in Redis cluster hash tags (`{...}`) across all multi-key Lua scripts (`claim.lua`, `ack.lua`, `floor.lua`, `ballot.lua`, `workflow.lua`, `blackboard.lua`, `leader.lua`, `lock.lua`, `unlock.lua`, `enqueue.lua`) and Nim queue/DLQ/floor resolution procs, ensuring single-slot affinity across Redis cluster deployments.
- **Sweeper Dead Agent Metadata & Tag Pruning**: In `scripts/sweep.lua`, corrected key references to extract agent tags from `agent:<name>` and delete reverse indexes from `tag:<tag>` sets alongside deleting the `agent:<name>` hash when pruning dead agents.
- **Floor Waiter Timeout Queue Dequeue**: In `src/rhizo.nim` `doFloorRequest`, added automatic `LREM` cleanup to dequeue agents from `floor:<room>:waiters` when `--wait` timeout expires, preventing abandoned requests from hijacking subsequent speaker yields.
- **Workflow State Machine Failure Preservation**: In `scripts/workflow.lua`, ensured step resolution (`resolve`) only transitions pipeline status to `"running"` if `flow.status` is not already `"failed"`, preventing subsequent step resolutions from masking earlier step failures in DAG pipelines.
- **Floor Control JSON Serialization**: In `scripts/floor.lua`, corrected empty `waiters` list serialization from JSON `{}` (empty map) to `[]` (empty array) for strict API schema conformance.
- **Request O2O Routing to Target Agent**: Fixed regression in `doSend` destination queue routing where messages with `replyTo` keys (such as `rhizo request`) routed directly to the ephemeral reply channel instead of `toAgent`. DestQueue routing now strictly checks that `msgType == "reply"` before routing to a reply channel.

## [0.1.2] - 2026-09-19

### Added
- **`rhizo reply` First-Class Command**: Native CLI subcommand for replying directly to messages (`rhizo reply --to <sender> --subject <subj> --body <body> [--reply-to <id>]`), automatically tagging the message with `type = reply`.
- **Atomic Listener Piggybacking (`--listen` / `-l`)**: Added `--listen` and `--listen-timeout` flags to `rhizo send` and `rhizo reply`. When enabled, Rhizo delivers the outbound message, logs status to `stderr`, and seamlessly transitions the same running process into blocking wait on the agent's inbox. This prevents coding assistants from dropping background listeners during multi-turn work.
- **Singleton Listener Invariant & Anti-Stacking Guard**: Added strict singleton listener enforcement via Redis `${prefix}listener:${agent}` with process PID and hostname tracking. If `--listen` is called while another listener is already active for that agent, Rhizo delivers the message and skips listening (exits 0) to prevent stacked background processes and Redis `BRPOP` competing-consumer queue splitting. Standalone `rhizo listen` fails fast with code 1 unless `--force` / `-f` is specified. Stale locks from terminated processes on the same host are detected and self-healed instantly via `kill(pid, 0)`.
- **Expanded Skill Discovery & Distributed File Locking Guidance**: Enhanced the `rhizo` skill frontmatter with explicit trigger phrases (`lock file`, `mutex lock`, `prevent concurrent edits`, `work queue`, `coordinate with the other terminal/agent`) to enable automatic skill invocation during parallel editing and multi-terminal operations. Added concrete file locking protocols (`rhizo lock file:schema.prisma 60` / `rhizo unlock file:schema.prisma`) to Section 1 and Section 3.C.
- **Capability-Based Dual-Strategy Ear Architecture in Skills**: Updated `SKILL.md` to instruct assistants to self-select their listener strategy based on native runtime tool capabilities rather than assistant brand names:
  - **Strategy A (Dedicated Ear Subagent)**: For runtimes supporting asynchronous subagent-to-parent messaging.
  - **Strategy B (Atomic Piggybacked Re-Arm)**: For single-agent / linear shell runtimes using `--listen`.

### Fixed
- **Conditional Listener Ownership Deletion on Exit**: Updated `doListen`'s cleanup block to verify that `rhizo:listener:<name>` in Redis matches the terminating process's PID and hostname before deleting it. Prevents preempted or replaced listeners from having their locks wiped by an earlier process exiting.
- **Worker Heartbeat Starvation Prevention in `rhizo work`**: Added automatic heartbeat and `active_agents` renewal during `doWork` chunked polling timeouts when an agent identity is resolved. Prevents idle worker processes waiting on task queues from expiring and being pruned from `rhizo who`.
- **Directory Consistency in `status.lua`**: Added `SADD active_agents <name>` to `scripts/status.lua` to ensure that setting state or activity restores pruned agents to directory listings.
- **Cryptographic Error Handling**: Added null pointer check on OpenSSL `HMAC()` return value in `computeHmacSha256` to raise explicit `ValueError` on calculation failure.

## [0.1.1] - 2026-09-19

### Added
- **Silent Indefinite Blocking Listener**: `rhizo listen` now defaults to indefinite blocking wait (`listenTimeout = 0`) with 60-second chunked internal polling and silent Redis heartbeat renewal (`SET heartbeat:<name> 1 EX 150`). Receivers now stay continuously registered in `rhizo who` without exiting to the OS shell or waking the assistant.
- **Rule of Silence for Zero Token Churn**: Commands that timeout (`listen`, `work`, and `sub`) now return returncode `0` with 0 bytes on stdout (`""`), permanently eliminating token waste and death-by-a-thousand-tokencuts in AI context windows.
- **Indefinite Worker Queue**: `rhizo work <queue>` now defaults to indefinite wait when no timeout is supplied, allowing worker pools to sit silently on Redis queues with zero token overhead.

### Changed
- **Continuous Ear Invariant in Skills**: Updated canonical `SKILL.md` (and synchronized mirrors) to strictly forbid wrapping shell loops (`while true; do ... done`). Assistants now launch bare `rhizo listen` directly in the background and re-arm immediately only upon receipt of an authenticated message.
- **Ephemeral Pub/Sub Silence**: `rhizo sub` now outputs 0 bytes on timeout instead of printing `(nil)`.

## [0.1.0] - 2026-09-19

### Added
- **Pure-Nim Daemonless Client**: Single compiled binary built with Nim standard library (`std/net`, `std/openssl`), utilizing an embedded pure-Nim RESP socket client with zero external runtime dependencies.
- **Out-of-Band Cryptographic Security**:
  - HMAC-SHA256 signature verification over all inter-agent messages, acting as an air-gap prompt-injection firewall to drop forged and tampered packets.
  - In-memory AES-256-CBC envelope encryption via native OpenSSL EVP C-bindings (`EVP_aes_256_cbc`, PBKDF2 SHA-256 with 10,000 iterations) with zero temporary files on disk.
  - Zero-friction key storage at `~/.config/rhizo/secret` (`0600` permissions) with auto-generated 256-bit entropy.
- **Peer Discovery & Directory Service (`rhizo who`)**:
  - Real-time active agent registry backed by Redis hashes and sets.
  - Automatic on-query dead-agent pruning for expired heartbeats.
  - Cluster-wide discovery flags (`-a`, `--all`, `*`) and structured JSON output (`--json`, `-j`).
- **Core Messaging Protocols**:
  - Direct point-to-point (O2O) task, query, reply, and status delivery (`rhizo send`).
  - Multicast (O2M) messaging with multi-tag filtering (`rhizo broadcast`).
  - Keyspace isolation via `RHIZO_PROJECT` and `{...}` hash tags for Redis Cluster compatibility.
  - Offline message queuing and ordered inbox backlog recovery (`rhizo drain`).
- **Distributed Coordination Primitives**:
  - Synchronous RPC (`rhizo request`) with blocking timeout and raw payload piping (`--raw`).
  - Competing-consumers work queues (`rhizo enqueue` and `rhizo work`) for parallel worker teams.
  - Distributed mutual exclusion locks (`rhizo lock` and `rhizo unlock`) with TTL lease hygiene.
  - Ephemeral real-time streaming (`rhizo pub` and `rhizo sub`).
  - Live agent operational state and activity tracking (`rhizo status`).
- **Host & Multi-Terminal Isolation**:
  - Multi-tiered agent identity resolution prioritizing CLI arguments, `RHIZO_AGENT_NAME` process environment variables, session ID mappings, and user-level fallbacks.
  - Automatic listener auto-registration into live directory sets.
- **Universal Assistant Integration**:
  - Canonical agent skill specification in `skills/rhizo/SKILL.md` compatible with Claude Code, Antigravity, Cursor, OpenCode, Codex, and Hermes via `npx skills` and `skilz`.
  - Zero-CPU, zero-token background listener discipline via Redis `BRPOP`.
- **Cascading Configuration System**:
  - Configuration hierarchy: CLI Flags -> Env Vars -> Workspace Config (`.rhizo.toml`) -> User Config (`~/.config/rhizo/rhizo.toml`) -> Defaults.
  - Multiple environment profiles (`dev`, `staging`, `prod`).
  - Configuration inspection and initialization CLI (`rhizo config show|get|path|init`).
- **Cross-Platform Distribution & Packaging**:
  - Official Homebrew formula in `axiomantic/homebrew-tap` (`brew install axiomantic/tap/rhizo`).
  - Official Debian/Ubuntu APT repository deployed on GitHub Pages.
  - Windows Scoop manifest in `packaging/scoop/rhizo.json`.
  - Universal 1-line installer and uninstaller scripts (`scripts/install.sh`, `scripts/install.ps1`).
  - Cross-compilation release pipeline generating standalone binaries and tarballs for Linux (amd64, arm64), macOS (Apple Silicon, Intel), and Windows (x64).

[Unreleased]: https://github.com/axiomantic/rhizo/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/axiomantic/rhizo/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/axiomantic/rhizo/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/axiomantic/rhizo/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/axiomantic/rhizo/releases/tag/v0.1.0
