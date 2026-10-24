---
name: rhizo
description: "Multi-agent coordination, inter-terminal messaging, distributed mutex locking with monotonic fencing tokens, task queues, Redis cron scheduler (rhizo pulse), System 1 routing (Laya, Kev, Decider, Jev), DAG pipelines, and the Codex-native wakeup protocol (RHIZO_WAKE) for autonomous turn resumption. Use when coordinating across AI assistant sessions, handling RHIZO_WAKE signals, acquiring mutex locks, dispatching peer tasks, consuming from queues with leases/DLQ, scheduling recurring cron jobs with pulse, running consensus ballots, electing mesh leaders, managing roundtable floor control, or sweeping dead listeners. Triggers: 'rhizo', 'RHIZO_WAKE', 'wake', 'pulse', 'cron', 'coordinate', 'inter-agent', 'lock resource', 'mutex', 'fencing token', 'work queue', 'enqueue', 'claim task', 'blackboard', 'floor control', 'ballot', 'leader election', 'dag pipeline', 'sweep'."
---

# Rhizo: High-Performance Inter-Agent Coordination Bus

## 0. Prerequisite & Bootstrapping

All multi-agent operations require the native `rhizo` CLI. If missing, install globally:
```bash
npm install -g @axiomantic/rhizo
# Or install full triad:
npm install -g @axiomantic/rhizo @axiomantic/vine @axiomantic/garden
```

> [!TIP]
> **Zero-Install Fallback (`npx`)**: In restricted environments where global installations are prohibited, prefix commands with `npx -y @axiomantic/rhizo <command>`.

---

## 1. Setup, Environment Verification & System 1 Routing

Before initiating swarm coordination, verify environment readiness:

### A. Redis Connectivity Verification
Verify connection and round-trip latency to Redis / Valkey:
```bash
rhizo ping
# Expected: ✓ Connected to Redis at 127.0.0.1:6379 (0.42ms)
```

### B. Layered Configuration & Uncommitted Secrets
Rhizo uses layered configuration so local developer settings and API keys are never committed to version control:
- **Base Tracked Config**: `.rhizo.toml` (or `~/.config/rhizo/config.toml`)
- **Local Overrides**: `.rhizo.local.toml` (git-ignored host/prefix settings)
- **Environment Secrets**: `.env.local` / `.env` (git-ignored API keys and service URLs)
- **Detailed Reference**: See [`docs/configuration.md`](../../docs/configuration.md) for the complete table of `RHIZO_*` environment variables and security profiles.

### C. Task Routing & Optional System 1 Decision Engine
> [!NOTE]
> **System 1 Routing is strictly OPTIONAL.**
> All core Rhizo coordination (messaging `rhizo open/send/listen`, distributed locking `rhizo lock --fencing`, explicit task queues `rhizo enqueue <queue>`, roundtable floor control, consensus ballots, and leader election) operates directly over Redis and requires **zero ML models, zero Python runtimes, and zero configuration files**.
> For full YAML schema rules and match operators, see [`docs/routes_schema.md`](../../docs/routes_schema.md).

When you have a high-throughput firehose of raw, untyped natural language tasks (e.g. from Jira, Slack, or user prompts) and want zero-shot classification into typed queues without generative LLM decoding delays:
* **Explicit Queueing (Default)**: Route deterministically without models: `rhizo enqueue queue:worker:claude "Fix button CSS"`.
* **Semantic Triage (Optional)**: Route via local ModernBERT/Laya (<40ms): `rhizo enqueue --route "Fix button CSS"`.

#### Cascading Routing Hierarchy & Scaffolding
When using semantic routing (`--route`), Rhizo resolves rules in a cascading hierarchy where more specific scopes override broader ones:
1. **Built-in Baseline**: Zero config needed; automatically classifies into standard domains (`backend`, `frontend`, `database`, `devops`, `firmware`, `docs`) routing to `queue:swarm:{{ domain.choice }}`.
2. **Global User Config**: `~/.config/rhizo/rhizo-routes.yaml` or `~/.config/rhizo/routes.yaml` (machine-wide configuration that applies across all projects on the system).
3. **Repo Root Config**: `<git-root>/rhizo-routes.yaml` (project canonical rules layering on top of global).
4. **Subdirectory Config**: `<repo>/packages/*/rhizo-routes.yaml` (monorepo subproject rules).
5. **Local Uncommitted Overrides**: `rhizo-routes.local.yaml` (developer scratch overrides).

Initialize routes anytime:
```bash
rhizo route init           # Scaffold project rhizo-routes.yaml
rhizo route init --global  # Scaffold machine-wide ~/.config/rhizo/rhizo-routes.yaml (applies across all projects)
rhizo route lint --check-service  # Validate rules & verify daemon connectivity
```

#### Local System 1 Daemon Setup (Optional)
1. **Install Daemon**: Use [`axiomantic/local-systemone`](https://github.com/axiomantic/local-systemone) (Python 3.10+):
   ```bash
   pip install "git+https://github.com/axiomantic/local-systemone.git#egg=local-systemone[full]"
   local-systemone --install-daemon   # macOS launchd or Linux systemd daemon on port 8100
   ```
2. **Cloud Alternative**: TypeSafe Jev API at `https://api.typesafe.ai` with `LAYA_API_KEY`.
   *For detailed service setup, macOS Metal & Linux deployment instructions, and schema definitions, see [references/system_one_setup.md](references/system_one_setup.md).*

---

## 2. Core Operational Invariants

<CRITICAL>
Run 'rhizo listen <agent>' with zero timeout (infinite wait). Do not pass bounded timeouts (--timeout 30), because timeout expiry forces empty LLM wakeups that exhaust token budgets.
</CRITICAL>

<FORBIDDEN>
Never execute 'rhizo listen &' or redirect output ('> /dev/null'). Detaching severs process supervision. Redirecting output discards the notification stream, causing permanent agent deafness.
</FORBIDDEN>

<FORBIDDEN>
Never Hijack or Kill Another Session's Active Listener: When 'rhizo listen <agent>' fails with "Error: Listener already active for agent ... (PID X)", an agent MUST NEVER kill that PID, run 'kill <pid>', or pass '--force' unless the agent has verified in its own conversation history that this agent name was explicitly opened and running in THIS session. In 'rhizo who', 'status: STALE' only indicates that no messages have been routed recently; it does NOT mean the blocking listener process in another window is dead or orphaned. Killing listener PIDs from other windows corrupts the cluster, severs peer communication, and hijacks sovereign sessions.
</FORBIDDEN>

<INVARIANT>
Ad-Hoc Subagents & No Double-Daemons: Subagents are tools for sessions to run ad-hoc tasks, never cluster swarm workers or listener relays. If an ad-hoc subagent is explicitly requested by the operator for a one-off inspection, 'rhizo listen' inside that subagent must run as a synchronous blocking foreground command that exits on message receipt. Never spawn background daemons inside subagents.
</INVARIANT>

<INVARIANT>
Identity Allocation: Agent identity must be unique and collision-free across projects. Run 'rhizo name' to acquire an atomically reserved unique codename (held in Redis for 10 minutes). Coding harness subshells do not preserve environment variables across tool turns. Record the literal name output from 'rhizo name' (e.g. 'rhizo-sequoia') in your reasoning context and pass it explicitly in all subsequent commands: 'rhizo open <name>', 'rhizo listen <name>'.
</INVARIANT>

<INVARIANT>
Unbootstrapped Session Identity Invariant: If a session was NOT explicitly bootstrapped with an identity in its conversation history (via a Garden prompt card, an explicit operator assignment, or prior 'rhizo open <name>' in that same conversation), it MUST NEVER guess, adopt, or assume an existing identity from 'rhizo who --json' or static role files. If the operator commands '/rhizo listen' without arguments in an unbootstrapped session, the session MUST either:
1. Run 'rhizo name' to allocate a fresh unique identity, followed by 'rhizo open <name>', OR
2. Ask the operator via 'ask_question' which persona or role this window represents.
Never assume you are the orchestrator or an existing active worker simply because those names appear in the project directory.
</INVARIANT>

<INVARIANT>
Never stage coordination metadata (*.lock, .rhizo.*) into Git. Keep all agent state in ~/.gitignore_global.
</INVARIANT>

<FORBIDDEN>
Never Wrap 'rhizo listen' in a Bash Loop: Never execute 'while true; do rhizo listen; done' or 'until rhizo listen'. Coding harnesses and task tools only receive output when the process finishes. Wrapping listen in a shell loop traps execution indefinitely, preventing the tool from ever returning its output to the parent orchestrator. The listener MUST be single-shot: execute once, exit on delivery, return output. Re-arming must be initiated as a separate turn or subsequent task.
</FORBIDDEN>

<INVARIANT>
Case-Insensitive Coordination: All channel names, agent codenames, inbox addresses, multicast tags ('@tag'), work queues ('queue:<name>'), distributed locks ('lock:<name>'), pub/sub channels ('channel:<name>'), task contracts, decisions, and run cancellation tokens are normalized case-insensitively. Agents may freely route and coordinate without concern for casing variations.
</INVARIANT>

<INVARIANT>
Sovereign Session & Subagent Prohibition: Swarm workers are ALWAYS sovereign, independent interactive sessions (dedicated terminal tabs, CLI windows, or IDE sessions) bootstrapped via Garden 10-backtick prompt cards. Harness-internal subagents (e.g., Antigravity's 'invoke_subagent', Claude Code's 'Task', OpenCode subagents, Cursor sub-composers) are STRICTLY PROHIBITED from acting as cluster swarm workers across all harnesses. Internal subagents are ephemeral, terminate upon single-task completion, cannot maintain persistent blocking listeners ('rhizo listen'), corrupt workspace isolation, and cause severe context poisoning by dumping execution traces back into the parent prompt. When orchestrating or bootstrapping a swarm, an orchestrator must NEVER spawn internal subagents and must NEVER offer "subagents" as a worker execution option during intake.
</INVARIANT>

<INVARIANT>
Delegation Precedence: When instructed to "delegate", "assign", or "dispatch" work (or when acting as an orchestrator in a repository with active cluster workers), the session MUST route tasks to active cluster workers via Rhizo (`rhizo send <worker>`, `rhizo enqueue queue:<project>:tasks`, or `rhizo task assign/claim`). Harness-internal subagents (e.g. `invoke_subagent`, `Task`, `Agent`) must NEVER be used to fulfill cluster swarm roles; they are restricted solely to transient, single-turn ad-hoc inspections in non-swarm solo chats when the operator explicitly requests a "subagent" by name.
</INVARIANT>

<CRITICAL>
Orchestrator Non-Implementation & Intake Gate Invariant (GVR-016):
When acting as an Orchestrator (or in any session with active cluster workers), you are a CONDUCTOR, NOT A CODER.
When the operator presents a task, feature request, bugfix, or asks to work on something:
YOU MUST NEVER DIRECTLY BEGIN WRITING CODE OR INVOKING EDIT TOOLS (`write_to_file`, `replace_file_content`, `edit_file`).

1. Pre-Authorized Directives & Active Fleet Fast-Path:
When the operator instructs 'work on this with your workers', 'delegate this', 'dispatch to the swarm', or when active cluster workers already exist in `rhizo who --all`, the Orchestrator MUST NOT stop to ask routing questions or wait for human confirmation. It must immediately break down work, provision strands (`vine strand`), and dispatch directly over Rhizo (`rhizo send --to <worker>`) or enqueue to work queues (`rhizo enqueue queue:<project>:tasks`).

2. Mandatory ask_question Tool Discipline:
If operator routing input is genuinely required (a true cold start with 0 cluster workers online), the orchestrator MUST invoke the interactive `ask_question` tool. Dumping numbered multiple-choice lists (1, 2, 3) in raw chat text is STRICTLY PROHIBITED.

3. Fleet-First Mandate:
When online workers exist, NEVER output copy-paste prompt cards to the human operator. Dispatch or repurpose existing workers over Rhizo.

4. Cold-Start Routing Options (via ask_question only):
- Enqueue to Cluster Work Queue (`rhizo enqueue queue:<project>:tasks`)
- Dispatch Directly to Worker (`rhizo send <worker>`)
- Execute Inline in Main Chat (only with explicit operator confirmation)

Direct inline implementation is prohibited unless the operator explicitly directs the orchestrator to code it inline in the main session.
</CRITICAL>

<CRITICAL>
Worker Autonomous Execution Invariant (GVR-017):
Swarm workers are autonomous implementers, not passive chatbots.
When an incoming task or directive is delivered to a worker (via 'rhizo listen' process exit or 'rhizo drain'), the worker MUST NOT remain idle, silent, or wait for human operator intervention.
Upon message delivery, the worker MUST IMMEDIATELY:
1. Inspect the delivered task payload, instructions, and target files.
2. Acknowledge or claim the task ('rhizo task claim <id>' or 'rhizo reply --to <sender> --subject "Task Claimed"').
3. Provision or enter the assigned Vine strand ('vine new <task_id>' or cd into existing strand) and execute the requested work.
4. Verify changes against the Three-Key Gate ('vine submit') before reporting completion. Remember: THE WORKER IS NOT THE AUDITOR; an independent adversarial auditor must review and ratify Key 3 ('vine audit approve').
5. Re-arm the single-shot listener ('rhizo listen <worker>') or send completion with '--listen' ('rhizo reply ... --listen') before completing the turn.
</CRITICAL>

<CRITICAL>
Closed-Circuit Two-Point Diff, Anti-Defeat-Device & Holistic Integration Invariant:
1. Two-Point Diff Mandate: Every deliverable must contain both a Provider and an active Consumer call-site (live router, CLI entrypoint, UI, or orchestration loop). Hermetic shelfware that is tested only by its own unit tests is strictly prohibited.
2. Holistic Integration & Anti-Defeat-Device: The producer and consumer must actually holistically integrate with the system. It must NOT be a toy, stub, mock, or heuristic approximation. Prompt keyword interceptors (e.g. 'if flight game in q') and theatrical mock questionnaires in generic runtimes that bypass genuine neural/radar/algorithmic pipelines to fake benchmark compliance are strictly prohibited and mechanically rejected at Key 2 (`ExitGateDefeatDeviceViolation` = 7) and Key 3.
3. Autonomous Intensive Audit Mandate (Authorized SOP): Intensive Five-Pillar adversarial audits are Standard Operating Procedure (SOP). They are pre-authorized, mandatory, and autonomous across the Triad. Orchestrators and Auditors MUST execute them automatically without prompting for human operator permission or input.
4. Aggressive Replacement Purge (Zero Dead Code): Any existing code, configurations, or fallbacks that your feature is intended to replace or upgrade MUST BE DELETED in the same strand. Do not preserve obsolete logic as a fallback, and do not leave commented-out shims in the codebase.
</CRITICAL>

<CRITICAL>
Compaction Preservation Rider & Post-Compact Invariant (GVR-010):
Context compaction purges detailed operational invariants, ceremony rules, and protocol mechanics from working memory.

1. **Compacting Agent Obligation**:
   If and only if this session has utilized `rhizo` (messaging, queues, distributed locks, task claiming), `garden`, or `vine`:
   The compacting agent MUST preserve the `SWARM_RUNTIME_STATE` block verbatim AND prepend the following mandatory instruction at the very top of the post-compaction summary preamble:

<!-- POST-COMPACTION INVARIANT: CEREMONY RESTORATION -->
> [!IMPORTANT]
> ## MANDATORY POST-COMPACTION INVARIANT: CEREMONY RESTORATION
> You are operating within an active multi-agent coordination workflow. Context compaction has purged detailed operational invariants and protocols from memory.
>
> **MANDATORY IMMEDIATE ACTION BEFORE ANY FURTHER WORK:**
> Before invoking any tool, modifying any file, or assigning any task, you MUST immediately re-read the active coordination skills using `view_file`:
> - If this session used **Garden** (or `orchestrate-swarm`): You MUST re-read `garden`, `orchestrate-swarm`, `rhizo`, and `vine`.
> - If this session used **Rhizo** standalone: You MUST re-read `rhizo`.
> - If this session used **Vine** standalone: You MUST re-read `vine`.
>
> **IMMORTALITY REQUIREMENT:**
> This directive and the `SWARM_RUNTIME_STATE` block MUST remain intact in all subsequent compaction summaries until all planned tasks are completed and woven into trunk.
<!-- END POST-COMPACTION INVARIANT -->

2. **Maintain Runtime State**: Keep this exact block in the working context:
<!-- SWARM_RUNTIME_STATE: DO NOT DISCARD OR ABBREVIATE IN COMPACTION -->
- AGENT_NAME: <codename> (Role: <role>)
- AGENT_ROLE: Lead Orchestrator (NON-IMPLEMENTING CONDUCTOR)
- INTAKE_GATE: MANDATORY_ASK (Never implement directly; ask to enqueue vs dispatch vs inline)
- WORKSPACE_MODE: Root Trunk | Strand (<path>)
- ACTIVE_STRAND: <branch> (Parent: <parent_branch>)
- ACTIVE_PEERS:
  * <peer_codename> (<project>: <current_task_description>)
- ACTIVE_LISTENER: <task_id_or_pid> (Listening on inbox: <codename>)
- ACTIVE_FENCING_TOKENS: <lock_key>=<token_int>
<!-- END_SWARM_RUNTIME_STATE -->

3. **Resurrected Agent Invariant**:
   Upon waking from compaction, the agent MUST immediately read the required skills, re-arm its single-shot listener (`rhizo listen <agent>`), check `implementation_plan.md`, and resume work under full ceremony discipline.
</CRITICAL>

<CRITICAL>
Orchestrator Turn-End Listener Invariant (GVR-014):
Coding harnesses (Antigravity, Claude Code, OpenCode) are event-driven: yielding a conversation turn with text output completely suspends model execution. Redis inbox state changes CANNOT wake an idle harness without an active child process registered in the task manager.

Whenever an Orchestrator or sender dispatches work or awaits peer replies, THE FINAL ACTION OF THAT TURN MUST BE ARMING A BACKGROUND LISTENER:
`run_command(CommandLine="rhizo listen <agent>", IsDaemon=false, WaitMsBeforeAsync=500)`

FORBIDDEN: Never conclude a turn after dispatching tasks without leaving an active background listener running. Yielding without a listener severs the swarm's physical lifeline, trapping worker replies in Redis and causing silent swarm stalls.

Codex / ChatGPT Limitation & Wakeup Protocol:
- **Codex Limitation**: In OpenAI Codex Desktop / CLI, a running shell listener does not itself wake an idle Codex chat. While the listener subprocess consumes messages and exits with code 0, subprocess completion does not resume model execution. Stop hooks only evaluate during turn endings and cannot listen while idle.
- **Autonomous Delivery**: Scheduled polling is prohibited as a substitute. Autonomous turn resumption requires the Codex-Native Wakeup Protocol (`RHIZO_WAKE` via `send_message_to_thread`) or a supported harness integration (e.g. Pi extension). Prompt instructions enforce recovery during turns.
</CRITICAL>

---

## 3. Capability-Based Listener Execution

Inspect your available runtime tools and execute the highest matching tier:

| Tier | Capability | Action | Rationale |
| :--- | :--- | :--- | :--- |
| **Tier 1** | In-Process Extension (e.g. OpenCode `opencode-ear.js`, Pi) | **Do not call any listen tool** | Plugin runs listener in-process and injects turns automatically with 0 token overhead. |
| **Tier 2** | Shell tool with daemon support (e.g. Antigravity `run_command(IsDaemon=true)`) | Run `rhizo listen <agent>` as managed daemon | Maintains direct line of communication in main chat with 0 token overhead. |
| **Tier 3A** | Autonomous Turn-End Hooks (Claude Code) | Install hook via `rhizo hook install --claude` | Native stop hook inspects inbox and interlocks turn completion if work is pending; ensures continuous listening discipline without token waste. |
| **Tier 3B** | Codex-Native Wakeup Protocol (`RHIZO_WAKE`) | Senders: `send_message_to_thread(thread_id, "RHIZO_WAKE")`<br>Recipients: recognize `RHIZO_WAKE`, process listener/inbox payloads, re-arm single-shot listener | On Codex Desktop, background listener completion does NOT resume idle chat, and Stop hooks only run at turn-end. Native `send_message_to_thread` resumes idle chat turns cleanly without scheduled polling or token waste. |
| **Tier 4** | Synchronous foreground shell only | **Do not run `rhizo listen`**. Call `rhizo check-inbox` | Blocking foreground shell freezes the turn. Poll explicitly during user turns. |

*For exact configuration parameters and tool call snippets, see [references/capability_archetypes.md](references/capability_archetypes.md).*

---

## 3.5 Codex-Native Wakeup Protocol (`RHIZO_WAKE`)

### Limitation & Idle Mechanics
On OpenAI Codex Desktop/CLI, a running shell listener (`rhizo listen <agent>`) does not itself wake an idle Codex chat. While the listener subprocess consumes messages and exits with code 0, **subprocess completion does not resume an idle conversation turn**.
Stop hooks also only evaluate during active turn endings and cannot listen while idle.
Prompt instructions enforce recovery during turns; autonomous delivery requires a native wake or a supported harness integration.

To wake an idle Codex session cleanly without polling loops or scheduled heartbeats, peers use Codex's native `send_message_to_thread` tool with the exact trigger:
```
RHIZO_WAKE
```

### Sender Contract
For substantive messages to a Codex session:
- **Send Payload Through Rhizo**: Dispatch the actual task payload through the Rhizo bus first: `rhizo send <agent> "<subject>" "<body>"`.
- **Resolve Thread ID**: If the recipient is registered to Codex, `rhizo send` outputs structured `[RHIZO CODEX-WAKE ACTION]`. You can also resolve explicitly: `rhizo session get <agent> --thread-id` or `rhizo session resolve <agent> --json`.
- **Send `RHIZO_WAKE` Through Native Tool**: Send `RHIZO_WAKE` through native Codex `send_message_to_thread(thread_id="<thread_id>", message="RHIZO_WAKE")`.
- **Avoid Wake/Acknowledgement Ping-Pong**: Send one wakeup per actionable batch. **NEVER** wake merely to acknowledge a wakeup or routine ACK (`rhizo reply`).
- **Preserve Payload on Tool Failure**: If native messaging fails or lacks authorization, the queued task remains safe in Redis. Report the limitation explicitly; never report delivery as completed execution.

### Recipient Contract (Codex Listener Workflow)
On `RHIZO_WAKE`, at turn start, and before ending any turn:

1. **Retrieve completed supervised listener output**: The listener may already have consumed a message, leaving the inbox empty.
2. **Process every delivered message, then drain and process the remaining inbox**: Run `rhizo drain 50 <agent> --json` and process all pending work within authorized scope.
3. **Refresh the agent registration if its heartbeat expired**: Ensure session lease and mapping are valid (`rhizo open <agent>`).
4. **Probe the listener**: Preserve an existing live listener; never create a duplicate.
5. **Start single-shot listener if none is running**:
   ```bash
   rhizo --project <project> listen <agent> --quiet
   ```
6. **Handle immediate message delivery**: If it immediately delivers a message, process it and repeat through separate tool calls.
7. **End turn when blocked**: End the turn only after a listener remains blocked waiting for messages, with no unprocessed output or inbox backlog. If arming fails, report the failure explicitly.

<FORBIDDEN>
Never use shell loops (`while true; do rhizo listen; done`), `&` backgrounding, output redirection (`> /dev/null`), `--timeout`, or kill another session's listener.
</FORBIDDEN>

*For complete details, security boundaries, delivery race analysis, and examples, see [references/codex_wakeup_protocol.md](references/codex_wakeup_protocol.md).*

---

## 4. Causal Command Reference

| Intent | Command | Invariant / Anti-Pattern |
| :--- | :--- | :--- |
| **Reserve Identity** | `rhizo name [prefix] [--ttl 600] [--json]` | Atomically reserve a unique codename from the 1,000-word lexicon (held in Redis for 10 min). |
| **Register & Listen** | `rhizo open [name] [tags] --listen` | Always specify tags to enable group broadcasts (`--tags worker,builder`). |
| **Continuous Ear** | `rhizo listen [name] [--quiet]` | Do not set `--timeout`. Let command block indefinitely until work arrives. |
| **Dispatch Task** | `rhizo send --to <agent> --subject <s> --body <b>` | Use `--type task` for actionable directives, `--type query` for questions. |
| **Direct Reply** | `rhizo reply --to <agent> --subject <s> --body <b>` | Always include `--reply-to <task_id>` when responding to an assigned task. |
| **Synchronous RPC** | `rhizo request --to <agent> --subject <s> --body <b> --raw` | Caller blocks up to 30s. Specialist must respond using `rhizo reply`. |
| **Scatter / Quorum** | `rhizo scatter --targets <@tag\|*> --subject <s> --body <b> --quorum N` | Waits until $N$ distinct agents reply. Exits 1 if timeout expires before quorum. |
| **Claim Work** | `rhizo claim <queue> --lease <sec> [--run-id <id>] --raw` | Negotiate lease duration. If task exceeds lease, renew before writeback. |
| **Acknowledge Work** | `rhizo ack <queue> <task_id>` | Call only after work is verified. Failure to ack returns task to queue (or DLQ). |
| **Acquire Lock** | `rhizo lock <name> [ttl_sec] --fencing --raw` | Always use `--fencing`. If exit code is 1, abort. Never write with an outdated token. |
| **Release Lock** | `rhizo unlock <name>` | Release immediately after write verification. Locks cannot be unlocked by non-owners. |
| **Validate Routes** | `rhizo route lint [--routes-file <f>] [--check-service]` | Lints route schemas and tests System 1 model connectivity. |
| **Inspect Routing** | `rhizo route "<directive>" [--routes-file <f>]` | Dry-run System 1 evaluation. Outputs matched rule, probabilities, target queue. |
| **Route & Enqueue** | `rhizo enqueue --route "<directive>" [--routes-file <f>]` | Evaluates task via System 1 and atomically enqueues to target queue in Redis. |
| **Cancel Run** | `rhizo cancel <run_id> [--reason <text>]` | Cancels all active tasks linked to `run_id`. Workers check via `--run-id`. |
| **Check Inbox** | `rhizo check-inbox [name]` | Non-blocking. Use only under Tier 4 synchronous shells. |
| **Cluster Health** | `rhizo sweep [--dry-run] --raw` | Prunes dead agent registrations and stale listener sockets. |
| **Health Check** | `rhizo ping [--json]` | Sub-millisecond latency and connectivity check to Redis/Valkey. |
| **Sticky Advisory** | `rhizo remind add <text> [--priority <prio>] [--cadence <sec>] [--ttl <sec>]` | Enqueues sticky invariant with smart piggyback cadence and standalone fallback. |
| **Inspect Advisories** | `rhizo remind list [--for <agent>] [--scope <scope>] [--json]` | Non-destructively inspects active advisories and per-worker delivery/ack status. |
| **Acknowledge Advisory**| `rhizo remind ack <id> [--agent <name>]` | Confirms worker internalized directive. With `--once`, suppresses future banners. |
| **Dismiss Advisory** | `rhizo remind dismiss <id>` | Immediately revokes advisory across entire cluster. |
| **Trigger Fallback** | `rhizo remind tick [--json]` | Evaluates idle workers and dispatches standalone reminders if cadence elapsed. |
| **Add Pulse (Cron)** | `rhizo pulse add <id> <cron> --queue <q> --body <b> [--title <t>]` | Registers distributed cron rhythm in Redis sorted set (`rhizo:pulses`). |
| **List Pulses** | `rhizo pulse list [--json]` | Inspects registered pulses, schedule, target queues, next run time, and ticks. |
| **Remove Pulse** | `rhizo pulse remove <id>` | Unregisters pulse from distributed schedule. |
| **Tick Pulses** | `rhizo pulse tick [--max <n>] [--json]` | Atomic cluster sweeper. Enqueues due pulses to target queues and advances cron without duplicates. |
| **Create Task** | `rhizo task create <id> --title <t> [--deliverables <files>]` | Creates first-class contract with explicit typed deliverables schema. |
| **Claim Task** | `rhizo task claim <id> [--lease <sec>]` | Atomically claims task and provisions isolated Vine strand (`vine new <id>`). |
| **Complete Task** | `rhizo task complete <id> [--gate-token <tok>]` | Verifies deliverables and Three-Key Gate before allowing merge to trunk. |
| **Propose Decision** | `rhizo decision propose <id> --title <t> [--summary <s>]` | Submits architectural proposal to verifiable governance ledger. |
| **Rule on Decision** | `rhizo decision approve\|reject <id> [--note/reason <text>]` | Operator-signed ruling. Replaces conversational prose spoofing. |
| **Verify Decision** | `rhizo decision verify <id>` | Returns exit code 0 if APPROVED, 1 if not. Machine-readable gate. |
| **Audit Trail** | `rhizo audit log --action <a> --details <d> / rhizo audit list` | Append-only stream recording coordination events and side-effects. |
| **Virtual Mock Time** | `rhizo time advance <seconds> / rhizo time reset` | Manipulates Redis virtual time offset for deterministic, instantaneous TTL testing. |
| **Reset Project** | `rhizo reset [project] [--all/-a] [--json]` | Sends shutdown poison-pill to active project listeners, unbinds sessions, and purges project keys. Pass `--all` to nuke entire namespace. |
| **Nuke Namespace** | `rhizo nuke [--json]` | Nuclear reset: sends shutdown poison-pill to all listeners, unbinds sessions, and wipes all keys matching `{prefix}*`. |
| **Turn-End Hook** | `rhizo hook codex-stop [--agent <name>]` | Evaluates turn-end Stop event: blocks if unread messages wait or listener is dead. |
| **Install Hook** | `rhizo hook install [--codex\|--claude] [--agent <name>]` | Scaffolds `.codex/hooks.json` or updates `settings.json` with turn-end interlock. |
| **Get Session**     | `rhizo session get <agent\|session_key> [--thread-id] [--json]` | Resolves session key or agent name; extracts verified thread ID for native tools. |
| **Resolve Session** | `rhizo session resolve <agent\|session_key> [--json]` | Deep session resolution: harness, thread ID, project, and native wakeup guidance. |
| **Set Window Title** | `rhizo title [name]` | Sets terminal tab/window title via ANSI OSC 0 (`\033]0;<name>\007`) on stderr. |
| **Doorbell Wakeup**  | `rhizo poke <agent> [--cmd <cmd>] [--force] [--dry-run] [--json] [-- <cmd...>]` | Injects wakeup keystroke into worker's window (Ghostty, tmux, Terminal, iTerm2, GUI). Supports `-- <cmd...>`. |
| **Reassign Worker** | `rhizo reassign <worker> --project <p> --role <r> [--tags <t>] [--queue <q>]` | Dynamically reassigns an active cluster worker session to a new project/role without reopening terminal tabs. |

---

## 5. Unified Work Item State Machine (WISM)

Rhizo, Garden, and Vine coordinate all multi-agent work through the formal **Work Item State Machine (WISM)**. Every task progresses through deterministic states with atomic Redis transitions, automated DAG unblocking, and Three-Key integration gates.

```mermaid
stateDiagram-v2
    [*] --> DRAFTED : rhizo task create <id>
    DRAFTED --> BLOCKED : Unmet DAG dependencies (depends_on)
    DRAFTED --> QUEUED : Zero unmet dependencies
    BLOCKED --> QUEUED : Parent task COMPLETED (Auto-promoted by Lua engine)

    QUEUED --> DELIVERED : Listener pops message (Transport Receipt emitted)
    DELIVERED --> CLAIMED : Worker acknowledges (Acquires monotonic lease)
    DELIVERED --> ORPHANED : Receipt timeout (180s without claim)

    CLAIMED --> IN_PROGRESS : Worker provisions strand (vine new <id>)
    IN_PROGRESS --> IN_PROGRESS : Progress reported (rhizo task progress, lease extended)
    IN_PROGRESS --> GATE_EVALUATING : Verification initiated (vine submit / vine gate)
    IN_PROGRESS --> YIELDED : rhizo task yield (Returned to pool)
    IN_PROGRESS --> ORPHANED : Lease expires without progress

    GATE_EVALUATING --> IN_PROGRESS : Gate failed (Tests red, changelog missing, or merge conflict)
    GATE_EVALUATING --> READY_FOR_AUDIT : Keys 1 & 2 PASSED (vine submit, gate token stamped)

    READY_FOR_AUDIT --> AUDIT_RATIFIED : Key 3 PASSED (vine audit approve, audit token stamped)
    READY_FOR_AUDIT --> AUDIT_REJECTED : Key 3 FAILED (vine audit reject)
    AUDIT_REJECTED --> IN_PROGRESS : Remediate defects in strand

    AUDIT_RATIFIED --> COMPLETED : vine weave && rhizo task complete (Unblocks downstream DAG children)

    ORPHANED --> QUEUED : Re-queued for retry (attempts < 3)
    ORPHANED --> DEAD_LETTER : Max delivery retries exceeded (attempts >= 3)
    YIELDED --> QUEUED : Returned to pool

    COMPLETED --> [*]
    DEAD_LETTER --> [*]
```

### ASCII State Transition Reference (LLM Fast-Path)

```text
  [rhizo task create]
          │
          ▼
     +---------+      Unmet deps
     | DRAFTED | ──────────────────► [ BLOCKED ]
     +---------+                         │
          │ Zero deps                    │ Parent task COMPLETED
          ▼                              ▼
     +---------+ ◄───────────────────────+
     | QUEUED  |
     +---------+
          │
          │ rhizo listen pops task (Transport Receipt emitted)
          ▼
    +-----------+      180s Receipt Timeout
    | DELIVERED | ─────────────────────────────────► [ ORPHANED ]
    +-----------+                                          │
          │                                                │ Attempts >= 3
          │ rhizo task claim / rhizo reply                 ▼
          ▼                                         [ DEAD_LETTER ]
     +---------+
     | CLAIMED |
     +---------+
          │
          │ vine new <task_id> (Provision strand)
          ▼
   +-------------+      Lease expires
   | IN_PROGRESS | ────────────────────────────────► [ ORPHANED ]
   +-------------+
     │        ▲
     │ vine   │ Gate fails
     │ submit │ (Tests red or conflict)
     ▼        │
  +-----------------+
  | GATE_EVALUATING |
  +-----------------+
          │
          │ Keys 1 & 2 PASSED (vine submit: merge-tree + live test suite green)
          ▼
  +------------------+
  | READY_FOR_AUDIT  | ◄──────────────────────┐
  +------------------+                        │
     │            │                           │
     │ approve    │ reject                    │ Remediate
     ▼            ▼                           │
  +------------+ +----------------+           │
  | AUDIT_     | | AUDIT_REJECTED | ──────────┘
  | RATIFIED   | +----------------+
  +------------+
          │
          │ vine weave && rhizo task complete
          ▼
    +-----------+
    | COMPLETED | ──► Auto-promotes BLOCKED child tasks to QUEUED!
    +-----------+
```

### State Definitions & Invariants

| State | CLI Trigger | Atomic Action & Side Effects | Timeout / Failure Escalation |
| :--- | :--- | :--- | :--- |
| **`DRAFTED`** | `rhizo task create <id> --title <t>` | Creates immutable task contract hash `task:<id>` in Redis. | N/A |
| **`BLOCKED`** | Evaluated on create | Stamped if `depends_on` contains incomplete tasks. Workers cannot claim. | N/A |
| **`QUEUED`** | Auto on create or parent complete | Pushed to queue/inbox. Available for worker consumption. | N/A |
| **`DELIVERED`** | `rhizo listen` consumes payload | **Atomically moves into `task:<id>` DELIVERED state**. Instant transport receipt emitted to orchestrator. Mirrored to local `~/.config/rhizo/current_task.json` for turn-end hook interlocks. | 180s Receipt Timeout $\rightarrow$ `ORPHANED` |
| **`CLAIMED`** | `rhizo task claim <id>` / `rhizo reply` | Worker acquires monotonic fencing lease. Isolated Vine strand provisioned (`vine new <id>`). Turn-end hook blocks until work starts. | Lease expires $\rightarrow$ `ORPHANED` |
| **`IN_PROGRESS`** | Worker coding in strand | Enforces single-active-lease invariant. Periodic `rhizo task progress` extends lease. | Lease expires $\rightarrow$ `ORPHANED` |
| **`GATE_EVALUATING`**| `vine submit` / `vine gate` | Key 1 (mechanical merge-tree) & Key 2 (live compiler/test suite + changelog) evaluated. | Exit 1 $\rightarrow$ `CONFLICTED`<br>Exit 2 $\rightarrow$ `GATE_FAILED` |
| **`READY_FOR_AUDIT`**| `vine submit` | Keys 1 & 2 passed. Strand submitted for independent adversarial review. | N/A |
| **`AUDIT_REJECTED`** | `vine audit reject` | Auditor rejected deliverable with recorded defect reasons. Worker returns to `IN_PROGRESS` for delta remediation. | N/A |
| **`AUDIT_RATIFIED`** | `vine audit approve` | Key 3 passed! Cryptographic `audit_token` stamped. Auditor and author identities strictly decoupled (`auditor != author`). | N/A |
| **`COMPLETED`** | `vine weave && rhizo task complete` | Fast-forward merged into canonical trunk. Strand pruned. Locks released. **Downstream DAG dependencies automatically unblocked (`BLOCKED` $\rightarrow$ `QUEUED`)!** | N/A |
| **`ORPHANED`** | Receipt timeout or lease expired | Stalled worker detected. Increments `delivery_attempts`. If $\ge 3 \rightarrow$ `DEAD_LETTER`. Otherwise returns to `QUEUED`. | Escalates to operator if Dead-Lettered |
| **`YIELDED`** | `rhizo task yield <id>` | Worker gracefully steps aside. Task returned to `QUEUED`. | N/A |
| **`DEAD_LETTER`** | Retries exhausted ($\ge 3$) | Moved to dead-letter queue. Alerts orchestrator and operator. | Requires manual operator triage |

---

## 6. Essential Coordination Workflows

### A. Agent Identity Allocation & Context Retention
Coding harness tools execute in isolated subshells (`bash -c` / `zsh -c`) that do not preserve shell environment variables across turns (`NAME=$(rhizo name)` is lost in subsequent turns).

1. Acquire an atomically held unique codename:
```bash
rhizo name
# Stdout: rhizo-sequoia
```
2. Note the returned codename in your reasoning context (`"My assigned name is rhizo-sequoia"`).
3. Pass that literal name in all subsequent tool calls:
```bash
rhizo open rhizo-sequoia "backend,worker"
rhizo listen rhizo-sequoia
```

### B. Distributed Locking with Monotonic Fencing
Before editing a shared file, database schema, or deployment resource, acquire a fencing token:
```bash
FENCE=$(rhizo lock file:config.json 60 --fencing --raw) || { echo "Lock collision"; exit 1; }
# Perform edits safely...
# Verify token has not been superseded before saving...
rhizo unlock file:config.json
```
<FORBIDDEN>
Never perform shared mutations if your lease expired. If a lease expires, another agent may have acquired a higher fencing token; proceeding causes silent data overwrites (zombie writes).
</FORBIDDEN>

### C. Competing-Consumers Queue with Dead-Letter Leases
Workers claim tasks from shared project queues:
```bash
# 1. Atomically claim task with a 120s lease:
TASK=$(rhizo claim queue:frontend:tasks --lease 120 --raw) || exit 0
TASK_ID=$(echo "$TASK" | jq -r '.id')
# 2. Execute task...
# 3. Confirm completion and release lease:
rhizo ack queue:frontend:tasks "$TASK_ID"
rhizo reply --to <project>-orchestrator --subject "Task complete" --body '{"status":"ok"}' --reply-to "$TASK_ID"
```

### D. System 1 Intelligent Directive Routing
When receiving unclassified user directives or multi-agent tasks:
1. Validate routing definitions and service health:
```bash
rhizo route lint --check-service
```
2. Test where a directive routes without executing (dry-run):
```bash
rhizo route "Fix off-by-one bounds check in graphics display buffer"
```
3. Atomically classify and dispatch to the resolved queue:
```bash
rhizo enqueue --route "Fix off-by-one bounds check in graphics display buffer"
```
4. If System 1 service is unreachable or unconfigured, fallback to explicit queue enqueue:
```bash
rhizo enqueue queue:firmware:tasks --body '{"directive":"Fix off-by-one..."}'
```

### E. Quorum Consensus Across Agents
Orchestrators fan out decision proposals and await consensus:
```bash
rhizo scatter --targets "@reviewers" --subject "Architecture Approval" --body '{"proposal":"RFC-101"}' --quorum 2 --timeout 30
```

### F. Global Run Cancellation
When an orchestrator aborts a workflow, all worker loops pass `--run-id` to terminate immediately:
```bash
# Orchestrator abort:
rhizo cancel run-90210 --reason "User requested stop"

# Worker loop awareness (exits 0 immediately if run is cancelled):
rhizo claim queue:build:tasks --lease 60 --run-id run-90210
```

### G. Sticky Reminders & Operational Advisories (`rhizo remind`)
Prevent context drift, token amnesia, and late-joining agent ignorance without causing token thrash or banner fatigue:

1. **Add Sticky Advisory**:
```bash
rhizo remind add "MUST run vine gate before completing any task" \
  --priority CRITICAL \
  --cadence 15m \
  --ttl 4h
```
- **Opportunistic Piggyback**: When an agent drains or listens (`rhizo drain`, `rhizo inbox`, `rhizo listen`), Rhizo automatically attaches the top active advisories to the incoming message payload if the agent's cadence window has elapsed.
- **Cadence Anti-Fatigue**: Reminders are not repeated on every message. Once shown, the agent enters a cooldown window (`--cadence 15m`), keeping messages clean.
- **Standalone Fallback**: If an agent is idle or receives no peer messages across its cadence window, `rhizo remind tick` dispatches a standalone HMAC-signed broadcast into its inbox.

2. **Non-Destructive Inspection (Side-Effect Free)**:
```bash
# Peek at active reminders and delivery/ack status for a worker without consuming:
rhizo remind list --for claude-worker-1 --json
```

3. **Worker Acknowledgment & Dismissal**:
```bash
# Worker confirms it has internalized the directive:
rhizo remind ack rem-1 --agent claude-worker-1

# Operator or orchestrator revokes an advisory:
rhizo remind dismiss rem-1
```

### H. First-Class Task Lifecycle & Leases (`rhizo task`)
Replace prose-based task assignments with state-machine-governed contracts:

1. **Create Task with Typed Deliverables Contract**:
```bash
rhizo task create task-auth-01 \
  --title "Implement JWT refresh token rotation" \
  --deliverables "src/auth/jwt.nim,tests/test_jwt.nim" \
  --description "Rotate tokens every 15 minutes; store revoked tokens in Redis"
```

2. **Claim Task & Automatic Vine Strand Virtualization**:
```bash
# Atomically claims task with a 30-minute lease and provisions an isolated Vine strand:
rhizo task claim task-auth-01 --lease 1800
# Automatic stdout: [VINE INTEGRATION] Provisioned Rift CoW strand 'task-auth-01' via 'vine new task-auth-01'
```

3. **Progress Updates**:
```bash
rhizo task progress task-auth-01 --message "Implemented token refresh logic; running tests"
```

4. **Complete Task with Three-Key Gate Verification**:
```bash
# Requires passing 'vine gate' verification token before allowing completion:
rhizo task complete task-auth-01 --gate-token "GATE_PASSED_v0.1"
```

### I. Cryptographic Operator Decisions & Rulings (`rhizo decision`)
Replace conversational prose spoofing with an immutable, verifiable decision ledger:

1. **Propose Architecture Decision**:
```bash
rhizo decision propose dec-db-01 \
  --title "Migrate session store from Postgres to Redis" \
  --summary "Reduces p99 latency from 45ms to 1.2ms under 10k concurrent agents"
```

2. **Operator Ruling (Approve / Reject)**:
```bash
rhizo decision approve dec-db-01 --note "Approved with 30-day data retention requirement"
# Or:
rhizo decision reject dec-db-01 --reason "Postgres transaction guarantees required for billing"
```

3. **Automated Verification in CI / Pre-Flight**:
```bash
# Exits code 0 if APPROVED, exits code 1 if not approved:
rhizo decision verify dec-db-01 || { echo "Gate blocked: decision not approved"; exit 1; }
```

### J. Single-Shot Listener Discipline & Re-Arming Protocol
<CRITICAL>
Every 'rhizo listen' execution MUST be a single-shot foreground command that terminates immediately upon delivering ONE message.
</CRITICAL>

**Why Bash Loops Are Strictly Forbidden**:
When an agent or task tool executes `while true; do rhizo listen; done`, the subshell never terminates. The harness pauses indefinitely waiting for tool completion, trapping the message payload inside an unmonitored background log. The parent orchestrator never wakes up!

**How to Re-Arm by Capability Tier**:
When `rhizo listen` delivers a message, it exits with code 0 and prints:
```text
[RE-ARM INSTRUCTION FOR CODING AGENT]
Listener Identity: @claude-worker-1 (this is YOU)
Delivered Message: 'msg_104' from @<project>-orchestrator
To continue listening, relaunch this EXACT command using your capability tier (NOT a shell loop!):
  Exact command: rhizo listen claude-worker-1
Capability-Tier Invocations (SKILL.md Section 3):
  - Tier 1 (In-Process Extension): In-process fiber handles listening automatically; DO NOT call listen.
  - Tier 2 (Shell Daemon): run_command(CommandLine="rhizo listen claude-worker-1", IsDaemon=true, WaitMsBeforeAsync=500)
  - Tier 3A (Claude Code Turn-End Hook): rhizo hook install --claude
  - Tier 3B (Codex Native Wakeup): Arm supervised single-shot 'rhizo listen codex-worker-1'; senders wake idle chats via RHIZO_WAKE.
  - Tier 4 (Synchronous Shell): Run 'rhizo listen claude-worker-1' directly in foreground (or 'rhizo check-inbox')
```
Select the invocation matching your runtime environment's capability tier (defined in [Section 3: Capability-Based Listener Execution](#3-capability-based-listener-execution)):
- **Tier 1 (In-Process Extension e.g. OpenCode, Pi)**: Native extension fiber is active in-process; never call any listen tool.
- **Tier 2 (Shell Daemon e.g. Antigravity)**: Launch via `run_command(CommandLine="...", IsDaemon=true, WaitMsBeforeAsync=500)` to maintain direct unblocked conversation flow.
- **Tier 3A (Claude Code Turn-End Hook)**: Install lifecycle stop hook via `rhizo hook install --claude`.
- **Tier 3B (Codex Native Wakeup)**: Arm supervised foreground single-shot `rhizo listen <agent>`. Senders wake idle sessions via `send_message_to_thread(thread_id, "RHIZO_WAKE")`. See [Section 3.5](#35-codex-native-wakeup-protocol-rhizo_wake).
- **Tier 4 (Synchronous Foreground Shell)**: Run single-shot in foreground or poll non-blocking via `rhizo check-inbox`.

### K. Health Probing & Watchdog Checks (`rhizo probe`, `rhizo watchdog`)

1. **Agent Health Probe (`rhizo probe`)**:
Assess peer liveness, heartbeat age, registered listener PID/host, and unread inbox depth:
```bash
rhizo probe <agent> [--json]
```

2. **Self-Audit Watchdog Check (`rhizo watchdog check`)**:
Inspect whether the calling session or target agent should be listening, whether work is currently in flight, and detect silent stall conditions:
```bash
rhizo watchdog check [--agent <name>] [--json] [--expect-listening]
```
Exit Codes & Verdicts:
- `0` (`OK` / `LISTENING`): Active listener process healthy and verified.
- `0` (`STAND_DOWN` / `IDLE`): Zero in-flight tasks and zero unread messages. Stand down; listener not required.
- `2` (`ACTION_REQUIRED` / `REARM_LISTENER`): In-flight tasks exist but listener is dead or missing. Run recommended command `rhizo listen <name>`.
- `2` (`ACTION_REQUIRED` / `UNREAD_MESSAGES`): Unconsumed inbox messages waiting. Drain and re-arm listener.

### L. Hybrid Window Targeting & The Doorbell Protocol (`rhizo title`, `rhizo poke`)

1. **Dynamic ANSI Terminal Tab & Window Titling (`rhizo title`)**:
   - `rhizo open <agent>` automatically stamps the active terminal tab and window name to `@<agent>` using standard ANSI OSC 0 escape sequences (`\033]0;<agent>\007`).
   - `rhizo listen <agent>` dynamically stamps `@<agent> (listening)` while awaiting messages, and restores `@<agent>` upon exit.
   - All escape sequences are emitted to `stderr`, keeping `stdout` completely clean for JSON parsing and shell piping (`rhizo listen | jq .`).
   - Run `rhizo title [name]` to manually or programmatically set the window title of the current pane or tab.

2. **Window-Targeted Doorbell Wakeup (`rhizo poke`)**:
   When an agent has stalled, gone deaf, or when external tools (ChatGPT, macOS Accessibility, AppleScript) need to reach an agent window directly by name:
   ```bash
   rhizo poke claude-worker-1
   # Or inject a custom command via -- (or --cmd):
   rhizo poke claude-worker-1 -- rhizo listen claude-worker-1
   ```
   - **Cascading Target Resolution**:
     1. `tmux`: checks `tmux list-panes` matching pane title or window name and dispatches `tmux send-keys -t <pane> <cmd> C-m`.
     2. macOS `Ghostty`: sends native AppleScript (`tell application "Ghostty" ... input text cmd to term ... send key "enter" to term`) without stealing window focus.
     3. macOS `Terminal.app`: uses `do script cmd in selected tab of w`.
     4. macOS `iTerm2`: uses `tell s to write text cmd`.
     5. macOS Universal GUI / Electron / IDEs (Antigravity, Cursor, VS Code, Claude Desktop): falls back to `System Events` targeting window title matches.
   - **Health Interlock Safety Guard**:
     `rhizo poke` queries `rhizo probe <agent>`. If the worker is already actively listening with 0 unread messages, injection is skipped (`status: SKIPPED`) to protect healthy listening agents from having text injected into their stdin.
     Pass `--force` (`-f`) to override this check.
   - **Dry Run**:
     Pass `--dry-run` (`-n`) to inspect window discovery and verify matching windows without executing keystrokes.

### M. Distributed Redis ZSET Cron & Heartbeat Pulses (`rhizo pulse`)

Rhizo provides high-availability distributed cron scheduling without requiring background OS daemons or single-point-of-failure loops:
1. **Register a Recurring Pulse**:
   ```bash
   rhizo pulse add "nightly-audit" "0 2 * * *" --queue "queue:rhizo:tasks" --body "Nightly health audit" --title "Nightly Audit"
   ```
2. **List Registered Pulses**:
   ```bash
   rhizo pulse list [--json]
   ```
3. **Cluster Sweeper Tick (`rhizo pulse tick`)**:
   Any worker or cluster watchdog invoking `rhizo pulse tick` safely evaluates due pulses. Uses atomic Lua scripts over Redis sorted set `rhizo:pulses`:
   ```bash
   rhizo pulse tick [--max 10] [--json]
   ```
   - Automatically enqueues work items to target queues.
   - Calculates the next Unix timestamp from the cron expression.
   - Reschedules atomically with zero duplicate firings across concurrent sweepers.
4. **Remove a Pulse**:
   ```bash
   rhizo pulse remove <pulse_id>
   ```

---

## 6. Architectural References

- **System 1 Routing & Configuration Guide**: See [references/system_one_setup.md](references/system_one_setup.md)
- **Capability Archetypes & Harness Execution**: See [references/capability_archetypes.md](references/capability_archetypes.md)
- **JSON Wire Protocol & Payloads**: See [references/wire_spec.md](references/wire_spec.md)
