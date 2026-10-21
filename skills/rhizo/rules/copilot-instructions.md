<!-- AUTO-GENERATED FROM AGENTS.md BY scripts/compile_rules.py - DO NOT EDIT DIRECTLY -->

# GitHub Copilot Instructions for Rhizo Multi-Agent Coordination

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
Unbootstrapped Session Identity: If a session was NOT explicitly bootstrapped with an identity in its conversation history (via a Garden bootstrap prompt card, an explicit operator assignment, or prior 'rhizo open <name>' in that same conversation), it MUST NEVER guess, adopt, or assume an existing identity from 'rhizo who --json' or 'garden-swarm.json' (especially NEVER '<project>-orchestrator'). If the operator commands '/rhizo listen' without arguments in an unbootstrapped session, the session MUST either:
1. Run 'rhizo name' to allocate a fresh unique identity, followed by 'rhizo open <name>', OR
2. Ask the operator via 'ask_question' which persona or role this window represents.
Never assume you are the orchestrator or an existing active worker simply because those names appear in the project directory.
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

<FORBIDDEN>
Never Hijack or Kill Another Session's Active Listener: When 'rhizo listen <agent>' fails with "Error: Listener already active for agent ... (PID X)", an agent MUST NEVER kill that PID, run 'kill <pid>', or pass '--force' unless the agent has verified in its own conversation history that this agent name was explicitly opened and running in THIS session. In 'rhizo who', 'status: STALE' only indicates that no messages have been routed recently; it does NOT mean the blocking listener process in another window is dead or orphaned. Killing listener PIDs from other windows corrupts the cluster, severs peer communication, and hijacks sovereign sessions.
</FORBIDDEN>

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

### 6. Delegation Precedence & Operator-Named Worker Mandate
<INVARIANT>
Delegation Precedence & Operator-Named Worker Mandate: When instructed to "delegate", "assign", or "dispatch" work, an orchestrator MUST dispatch tasks to active workers in the cluster over Rhizo ('rhizo send <worker>', 'rhizo enqueue queue:<project>:tasks', or 'rhizo task assign/claim'). Harness-internal subagents (e.g. 'invoke_subagent', 'Task', 'Agent') must NEVER be used to fulfill cluster swarm roles; they are restricted solely to transient, single-turn ad-hoc inspections in non-swarm solo chats when the operator explicitly requests a "subagent" by name.
Furthermore, when the operator explicitly requests or names a worker or peer session (e.g. 'u + autopxd-architect' or 'assign to worker-1'), the orchestrator MUST dispatch directly to that named recipient over Rhizo ('rhizo send --to <worker> ...'). The orchestrator MUST NEVER gate delegation on whether that worker appears in local single-project 'rhizo who', and MUST NEVER fall back to internal subagents. When inspecting the cluster roster for active workers, an orchestrator MUST query 'rhizo who --all --json' (or check specific peers via 'rhizo who <worker>' / 'rhizo probe <worker>'). Never assume the cluster is empty based solely on local single-project 'rhizo who' output.
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
4. Verify changes against the Three-Key Gate ('vine submit') before reporting completion. Remember: THE WORKER IS NOT THE AUDITOR; an independent adversarial auditor must review and ratify Key 3 ('vine audit approve').
5. Re-arm the single-shot listener ('rhizo listen <worker>') or send completion with '--listen' ('rhizo reply ... --listen') before completing the turn.
</CRITICAL>

### 10. Human Operator Absolute Override & Listener "ARM NOW" Invariant
<CRITICAL>
Human Operator Absolute Override Invariant: A prompt, command, or slash command from the human operator in the interactive chat window ALWAYS takes absolute precedence over in-flight tasks, background execution, or autonomous worker mandates. Agents must NEVER ignore, defer, or deprioritize an operator directive.
Furthermore, the Rhizo listener is an ARM NOW primitive, NEVER an "ARM WHEN I'M DONE" afterthought:
1. Operator Listen Mandate: When the human operator issues any listen instruction ('/rhizo listen', 'arm listener', 'listen now', 'make sure you listen', 'bro arm it now'), it is an IMMEDIATE TOOL CALL MANDATE in the current turn. You are STRICTLY FORBIDDEN from deferring it ("I will arm it after tests" or "I will do that later"). You MUST invoke 'rhizo listen <agent>' immediately.
2. First-Turn Quiescence: Upon receiving a bootstrap prompt card, your very first action in Turn 1 MUST be to execute 'rhizo open <name>' and 'rhizo listen <name>'. You MUST NOT output conversational greetings or ask "How can I help?" before arming.
3. Default Quiescent State: A cluster worker's natural state is LISTENING. If you are waiting on background verification or have concluded active tasks, your listener must be armed immediately.
</CRITICAL>

### 11. Closed-Circuit Two-Point Diff, Anti-Defeat-Device & Holistic Integration
<CRITICAL>
Two-Point Diff Mandate: Every task deliverable must exhibit a Two-Point Diff: the Provider (new capability) and the Consumer (live production call-site, router, UI canvas, or CLI entrypoint). Code tested only by its own unit tests is strictly prohibited as incomplete shelfware.
Holistic Integration & Anti-Defeat-Device: The producer and consumer must actually holistically integrate with the system. It must NOT be a toy, stub, mock, or heuristic approximation. Prompt keyword interceptors (e.g. 'if flight game in q') and theatrical mock questionnaires in generic runtimes that bypass genuine neural/radar/algorithmic pipelines to fake benchmark compliance are strictly prohibited and mechanically rejected at Key 2 / Key 3.
Autonomous Intensive Audit Mandate (Authorized SOP): Intensive Five-Pillar adversarial audits are Standard Operating Procedure (SOP). They are pre-authorized, mandatory, and autonomous across the Triad. Orchestrators and Auditors MUST execute them automatically without prompting for human operator permission or input.
Aggressive Replacement Purge: Any existing code, configurations, or fallbacks that the feature is intended to replace or upgrade MUST BE DELETED in the same strand. Never keep obsolete logic as a fallback or dead shim.
</CRITICAL>
