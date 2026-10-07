<div align="center">

# Rhizo

**Fast, simple message exchange between AI coding assistants over Redis.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/axiomantic/rhizo/actions/workflows/ci.yml/badge.svg)](https://github.com/axiomantic/rhizo/actions/workflows/ci.yml)
[![Tests](https://img.shields.io/badge/Tests-129%20Passing-success.svg)](tests/)
[![Redis](https://img.shields.io/badge/Redis-6.2%2B-red.svg)](https://redis.io)
[![Valkey](https://img.shields.io/badge/Valkey-7.2%2B-purple.svg)](https://valkey.io)
[![Nim](https://img.shields.io/badge/Nim-2.0%2B-yellow.svg)](https://nim-lang.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Windows-blue.svg)](README.md)

*Connect multiple AI coding assistants across terminals, editors, and machines with a single command-line tool. No background services or daemons required.*

</div>

---

## Table of Contents

- [What is Rhizo?](#what-is-rhizo)
- [30-Second Quickstart](#30-second-quickstart)
  - [1. Install (Universal NPM Package)](#1-install-universal-npm-package)
  - [2. Try it in Your Terminals](#2-try-it-in-your-terminals)
  - [3. Multi-Assistant Chat Coordination (Orchestrator & Workers)](#3-multi-assistant-chat-coordination-orchestrator--workers)
  - [4. Coordination Primitives at a Glance](#4-coordination-primitives-at-a-glance)
- [Multi-Agent Playbooks & Recipes](#multi-agent-playbooks--recipes)
- [How it Works with Redis](#how-it-works-with-redis)
  - [Comparison](#comparison)
- [Task Routing & Optional System 1](#task-routing--optional-system-1-decision-engine)
- [How Messages Flow](#how-messages-flow)
- [Installation & Setup](#installation--setup)
  - [Option 1: Unified One-Line Installer (Recommended)](#option-1-unified-one-line-installer-recommended)
  - [Option 2: Install the AI Agent Skill (Using Skill Tools)](#option-2-install-the-ai-agent-skill-using-skill-tools)
  - [Option 3: Install via NPM (Universal Multi-Platform)](#option-3-install-via-npm-universal-multi-platform)
- [Uninstallation](#uninstallation)
- [CLI Reference](#cli-reference)
- [Autonomous Agent Lifecycle: Hooks, Extensions & Recipes](#autonomous-agent-lifecycle-hooks-extensions--recipes)
- [Configuration Architecture & Profiles](#configuration-architecture--profiles)
  - [Complete Configuration & Environment Reference](docs/configuration.md)
  - [System 1 Routes Schema Reference](docs/routes_schema.md)
- [Security & Prompt Injection Firewall](#security--prompt-injection-firewall)
- [Cross-Host Multi-Machine Coordination](#cross-host-multi-machine-coordination)
- [Redis Cluster Support (Hash Tags)](#redis-cluster-support-hash-tags)
- [Assistant Integration (Skill)](#assistant-integration-skill)
- [Performance & Benchmarks](#performance--benchmarks)
- [Testing & Verification](#testing--verification)
- [License](#license)

---

## What is Rhizo?

**Rhizo** is an inter-agent communication bus that lets AI coding assistants (such as Claude Code, OpenCode, Cursor, Windsurf, Antigravity, and Codex) exchange tasks and messages across terminals, editors, and machines.

Instead of running a complex background server, Rhizo routes and queues messages directly through **Redis** or **Valkey**.

### Standalone Yet Designed for the Axiomantic Triad

Rhizo is completely standalone and can be used on its own for any inter-process or multi-agent Redis communication, locking, and queues.

However, Rhizo is designed from the ground up to pair seamlessly with **Vine** and **Garden**:
- **Rhizo** (Transport & Concurrency): Inter-agent messaging bus, monotonic fencing locks, and task queues over Redis.
- [**Vine**](https://github.com/axiomantic/vine) (Workspaces & Verification): Sub-second APFS Copy-on-Write strands, polyglot build-cache normalization, and the Two-Key integration gate (`git merge-tree` mechanical + compiler/test suite semantic checks).
- [**Garden**](https://github.com/axiomantic/garden) (Swarm Ceremonies): Tmux worker fleet provisioning, 3-stage empirical dialectical pump (research, architecture, audit), and master ceremonial implementation planning.

#### Complete Workflow
1. **Claim Task**: `rhizo claim queue:myproj:tasks --lease 1800` (yields monotonic `fencing_token`).
2. **Spin Zero-Cost Strand**: `vine new <task_id> --worktree` (sub-second APFS CoW workspace).
3. **Verify Two-Key Gate**: `vine gate --json` (Key 1 in-memory conflict check + Key 2 live compiler/test suite).
4. **Weave & Acknowledge**: `vine weave && rhizo ack queue:myproj:tasks <task_id>`.

---

## 30-Second Quickstart

### 1. Install

```bash
# Recommended: Install the complete multi-agent triad globally
npx skills add -g axiomantic/rhizo
npx skills add -g axiomantic/vine
npx skills add -g axiomantic/garden

# Or install the CLI tools:
npm install -g @axiomantic/rhizo @axiomantic/vine @axiomantic/garden
```

### 2. Try it in Your Terminals

**Terminal A (Worker 1):**
```bash
rhizo open worker-1 "backend,qa"
rhizo listen
```
*Registers `worker-1` and waits for incoming tasks with zero CPU and zero token consumption.*

**Terminal B (Worker 2):**
```bash
rhizo open worker-2 "frontend,qa"
rhizo listen
```
*Registers `worker-2` and waits on its own inbox.*

**Terminal C (Coordinator / Sender):**
```bash
# 1-to-1 Direct Task (O2O):
rhizo send --to worker-1 --subject "Run Tests" --body "pytest tests/auth"

# 1-to-Many Group Broadcast (O2M):
rhizo broadcast --tags "qa" --subject "Deploy Staging" --body "Verify build v1.2"
```
*Terminal A receives the direct task; both Terminal A and Terminal B receive the multicast broadcast instantly.*

### 3. Multi-Assistant Chat Coordination (Orchestrator & Workers)

You can coordinate multiple coding assistants across different terminal windows or editors using natural language:

**Terminal 1 — The Orchestrator (Lead Assistant):**
> *"You are the coordinator for this project. Connect to Rhizo as lead. Check who is online with `rhizo who`, broadcast the test plan to the 'qa' group, and assign API work to 'backend'."*
- The lead registers (`rhizo open lead "orchestrator"`), inspects the active roster (`rhizo who`), and broadcasts work:
  ```bash
  rhizo broadcast --tags "qa" --subject "Test Plan" --body "Validate auth endpoints on staging"
  rhizo broadcast --tags "backend" --subject "API Task" --body "Implement POST /api/v1/login"
  ```

**Terminal 2 — Backend Worker Assistant (e.g. Claude Code or Cursor):**
> *"Connect to Rhizo as worker-backend with tag 'backend'. Listen for tasks, implement them, and send replies back to lead."*
- The worker registers (`rhizo open worker-backend "backend"`), blocks on `rhizo listen` (consuming **0 CPU** and **0 tokens** while waiting), receives the task, implements the code, and replies:
  ```bash
  rhizo send --to lead --type reply --subject "Re: API Task" --body "Login endpoint implemented in src/auth.py. Tests green."
  ```

**Terminal 3 — QA Worker Assistant (e.g. Antigravity or Windsurf):**
> *"Connect to Rhizo as worker-qa with tag 'qa'. Listen for incoming test requests."*
- The QA worker automatically receives the broadcast sent to `@qa` and begins running validation tests in parallel.

### 4. Coordination Primitives at a Glance

Rhizo extends point-to-point and group messaging with dedicated primitives designed specifically for autonomous AI agents and parallel terminal swarms:

| Coordination Primitive | Purpose & Architecture Guarantee | Core Command | Recipe |
|:---|:---|:---|:---:|
| **Safe File Locking** | Distributed mutual exclusion with automatic lease expiration | `rhizo lock file:src/router.ts 60` | [Recipe 1](#1-safe-concurrent-file-editing) |
| **Worker Pools** | Competing consumers with FIFO dispatch and fair scheduling | `rhizo enqueue <q>` / `rhizo work <q>` | [Recipe 2](#2-distributing-batch-jobs-across-a-worker-pool) |
| **Synchronous RPC** | Request-reply blocking on an ephemeral correlation channel | `rhizo request --to <agent> --subject "..." --body "..."` | [Recipe 3](#3-synchronous-rpc-delegation-specialist-query) |
| **Status & Activity** | Real-time cluster presence with focus broadcast and directory queries | `rhizo status <busy\|idle> "..."` / `rhizo who` | [Recipe 4](#4-team-discovery--live-focus-broadcasting) |
| **Scatter-Gather** | Fan-out queries across specialist pools with quorum aggregation | `rhizo scatter --targets @tag --quorum N --timeout 15` | [Recipe 5](#5-orchestrator-scatter-gather--quorum-consensus) |
| **Reliable Task Leases** | At-least-once claims, in-flight lease renewal, and DLQ routing | `rhizo claim <q> --lease 60` / `rhizo ack <q> <id>` | [Recipe 6](#6-fault-tolerant-worker-mesh-with-leases--dead-letter-queue) |
| **Shared Blackboard** | Durable shared KV & list scratchpad with OCC revision tracking | `rhizo blackboard <set\|get\|append\|snapshot\|load>` | [Recipe 7](#7-shared-blackboard--roundtable-scratchpad) |
| **Floor Control** | Roundtable speaker ring preventing cross-talk during discussions | `rhizo floor <request\|yield\|pass\|status> <room>` | [Recipe 8](#8-moderated-roundtable-discussion-with-floor-control) |
| **Cancellation Tokens** | Global abort signal halting runaway worker executions instantly | `rhizo cancel <run_id> --reason "..."` | [Recipe 9](#9-coordinated-run-cancellation-across-workers) |
| **Blind Consensus Voting** | Secret-ballot consensus eliminating model anchoring bias | `rhizo ballot <open\|cast\|tally\|status> <id>` | [Recipe 10](#10-blind-consensus-voting-to-eliminate-anchoring-bias) |
| **Leader Election** | Resilient coordinator lease with automatic preemption failover | `rhizo leader <acquire\|renew\|resign\|status> <role>` | [Recipe 11](#11-self-healing-leader-election--automated-failover) |
| **DAG Workflow Engine** | Multi-stage pipeline graph with automatic dependency unlocking | `rhizo workflow <define\|next\|resolve\|export\|import>` | [Recipe 12](#12-dag-based-multi-stage-workflow-pipeline) |
| **Cluster Health Sweeper** | Cursor-based SCAN watchdog pruning dead agents & stale listeners | `rhizo sweep [--dry-run] [--raw]` | [Recipe 13](#13-cluster-health-sweeping--self-healing-watchdog) |
| **Fencing Tokens** | Monotonic integer sequence counter preventing zombie writes | `rhizo lock <resource> 60 --fencing` | [Recipe 14](#14-distributed-locking-with-monotonic-fencing-tokens) |
| **Semantic Task Routing** | Zero-shot task classification into queues (<40ms) via ModernBERT/Laya | `rhizo enqueue --route "<task>"` | [Recipe 15](#15-semantic-task-routing-with-optional-system-1) |
| **Pub/Sub Streaming** | Real-time ephemeral broadcast streaming without queue memory | `rhizo pub <channel> "..."` / `rhizo sub <channel>` | [CLI Reference](#2-cli-command-reference) |

---

## Multi-Agent Playbooks & Recipes

Minimal, production-ready recipes for common multi-agent coordination patterns:

### 1. Safe Concurrent File Editing
Acquire a distributed lease before modifying shared files to prevent overwrite collisions across parallel agents:
```bash
# 1. Acquire 60-second lease (returns 0 on success, 1 on conflict):
rhizo lock file:src/router.ts 60

# 2. Safely inspect, edit, or refactor the file...

# 3. Release lease immediately upon completion:
rhizo unlock file:src/router.ts
```

### 2. Distributing Batch Jobs Across a Worker Pool
Farm out independent tasks across interchangeable worker assistants with guaranteed exactly-once delivery:
```bash
# Orchestrator pushes tasks:
rhizo enqueue test_suite --subject "Auth Tests" --body "tests/auth_test.go"
rhizo enqueue test_suite --subject "API Tests" --body "tests/api_test.go"

# Workers consume tasks concurrently (blocks silently until available):
task=$(rhizo work test_suite)
```

### 3. Synchronous RPC Delegation (Specialist Query)
Delegate a specialized query or verification and block for the clean result:
```bash
# Requester (blocks up to 30s; --raw outputs clean response body):
res=$(rhizo request --to db-expert --subject "Query Plan" --body "SELECT * FROM users" --timeout 30 --raw)

# Specialist Responder:
rhizo reply --to orchestrator --subject "Re: Query Plan" --body "Add composite index on (created_at, user_id)" --reply-to <req_id> --listen
```

### 4. Team Discovery & Live Focus Broadcasting
Check active teammates before dispatching tasks, and broadcast current focus to coordinators:
```bash
# Discover active agents cluster-wide:
rhizo who -a --json

# Broadcast current focus:
rhizo status busy "Refactoring auth middleware"

# Signal completion when ready:
rhizo status idle "Awaiting next task"
```

### 5. Orchestrator Scatter-Gather & Quorum Consensus
Fan out an objective across a pool of specialists and aggregate responses until quorum is met:
```bash
# Fan out to all agents with tag 'reviewers', waiting for at least 2 approvals:
replies=$(rhizo scatter --targets @reviewers --subject "Review PR #42" --body "Please review diff in staging" --quorum 2 --timeout 15)

# Or fan out to explicit agents and pipe bare response bodies:
rhizo scatter --targets "analyzer1,analyzer2" --subject "Benchmark" --body "run" --raw
```

### 6. Fault-Tolerant Worker Mesh with Leases & Dead-Letter Queue
Non-destructively claim tasks with leases and eliminate task loss on worker crash:
```bash
# 1. Claim task with 60-second lease (supports --run-id for cancellation awareness):
task=$(rhizo claim batch_pipeline --lease 60 --run-id run_042)
task_id=$(echo "$task" | jq -r '.id')

# 2. For long-running execution (>60s), periodically renew lease to prevent task theft:
rhizo claim renew batch_pipeline "$task_id" --lease 60

# 3. Confirm completion and release lease:
rhizo ack batch_pipeline "$task_id"
```

### 7. Shared Blackboard & Roundtable Scratchpad
Share persistent specs and append ideas across agents without context ballooning:
```bash
# 1. Set shared architecture specification:
rhizo blackboard set brainstorm arch_spec '{"runtime": "nim", "crypto": "openssl_evp"}'

# 2. Query current Optimistic Concurrency Control (OCC) revision:
rev=$(rhizo blackboard rev brainstorm arch_spec)
# => "1"

# 3. Append ideas or action items:
rhizo blackboard append brainstorm ideas "Idea 1: Add monotonic fencing tokens to mutex locks"
rhizo blackboard append brainstorm ideas "Idea 2: DAG-based workflow pipeline engine"

# 4. Take room snapshot:
rhizo blackboard snapshot brainstorm
```

### 8. Moderated Roundtable Discussion with Floor Control
Coordinate turn-taking and prevent cross-talk during multi-agent discussions:
```bash
# 1. Request the floor (with a 30s speaker lease). Blocks if occupied:
rhizo floor request design_room 30

# 2. Write speaking points or broadcast to participants:
rhizo blackboard append design_room notes "Speaker proposal: Split monolithic config into modular schemas"

# 3. Yield floor to the next waiting speaker:
rhizo floor yield design_room
# Or pass explicitly:
rhizo floor pass design_room specialist_bob
```

### 9. Coordinated Run Cancellation Across Workers
Publish cancellation tokens to immediately stop background jobs and prevent wasted AI token spend:
```bash
# 1. Lead / Orchestrator cancels run:
rhizo cancel run_042 --reason "Aborted by lead: switching models"

# 2. Workers pass --run-id directly to work/claim loops (exits 0 immediately if cancelled):
rhizo work batch_pipeline 30 --run-id run_042

# Or manual pre-check before expensive inferences:
if rhizo cancel check run_042 --exit-code; then
  echo "Job was cancelled! Halting execution."
  exit 0
fi

# 3. Clear token when starting fresh execution:
rhizo cancel clear run_042
```

### 10. Blind Consensus Voting to Eliminate Anchoring Bias
Conduct unbiased, sealed-ballot votes across independent models:
```bash
# 1. Open ballot:
rhizo ballot open framework_choice --options "react,vue,svelte" --voters "claude,gpt,gemini"

# 2. Assistants cast sealed ballots:
rhizo ballot cast framework_choice --vote "svelte" --voter "claude"
rhizo ballot cast framework_choice --vote "svelte" --voter "gpt"
rhizo ballot cast framework_choice --vote "react" --voter "gemini"

# 3. Reveal tally and determine winner:
rhizo ballot tally framework_choice --close
```

### 11. Self-Healing Leader Election & Automated Failover
Maintain resilient mesh coordination with preemption leases and failover:
```bash
# 1. Acquire leadership lease (30s):
rhizo leader acquire cluster_lead 30

# 2. While running, periodically heartbeat/renew:
rhizo leader renew cluster_lead 30

# 3. Check current leader:
rhizo leader status cluster_lead

# 4. Release leadership to standby nodes:
rhizo leader resign cluster_lead
```

### 12. DAG-Based Multi-Stage Workflow Pipeline
Coordinate complex pipelines where dependent tasks unlock automatically as upstream stages finish:
```bash
# 1. Define pipeline graph:
rhizo workflow define release_pipeline \
  --steps "lint,test,build,deploy" \
  --deps "test:lint;build:lint;deploy:test,build"

# 2. Query ready unblocked steps:
ready_steps=$(rhizo workflow next release_pipeline --raw)
# => "lint"

# 3. Worker executes 'lint' and resolves it:
rhizo workflow resolve release_pipeline lint --output "lint passed"
# 'test' and 'build' are now ready!

# 4. Resolve 'test' and 'build':
rhizo workflow resolve release_pipeline test --output "tests passed"
rhizo workflow resolve release_pipeline build --output "artifacts packaged"
# 'deploy' is now unlocked!

# 5. Final deployment step:
rhizo workflow resolve release_pipeline deploy --output "deployed to prod"
# Pipeline status is now 'completed'
```

### 13. Cluster Health Sweeping & Self-Healing Watchdog
Maintain clean Redis state and prevent directory clutter from crashed or ungracefully terminated agents:
```bash
# 1. Sweep dead agent heartbeats and local stale listener PID locks:
sweep_res=$(rhizo sweep)

# 2. Inspect swept resources:
echo "$sweep_res" | jq .

# 3. Clean summary line for automation:
rhizo sweep --raw
```

### 14. Distributed Locking with Monotonic Fencing Tokens
Prevent zombie writes across distributed storage or databases after lease expiration:
```bash
# 1. Acquire lock and obtain monotonic integer sequence token:
fence_token=$(rhizo lock db_migration 60 --fencing --raw)
# => "42"

# 2. Guard storage mutations with the fencing token:
# Storage or DB will reject any write whose fencing token <= current maximum token.

# 3. Release lock:
rhizo unlock db_migration
```

### 15. Semantic Task Routing with Optional System 1
Classify unstructured natural language tasks directly into typed worker queues without LLM decoding delays:
```bash
# 1. Enqueue task via System 1 triage (evaluates rules and pushes to queue):
rhizo enqueue --route "Investigate PostgreSQL deadlock during migration"

# 2. Or test dry-run routing decision with full provenance:
rhizo route "Investigate PostgreSQL deadlock during migration"
# => Routing Decision:
#    Target Queue: queue:swarm:database
#    Confidence:   0.94
#    Evaluator:    local-systemone (http://127.0.0.1:8100)

# 3. Initialize global routing rules that apply across all projects:
rhizo route init --global
# => Created ~/.config/rhizo/rhizo-routes.yaml (all projects inherit these rules)

# 4. Or scaffold project-specific routes (layers on top of global):
rhizo route init
# => Created ./rhizo-routes.yaml
```

---

## How it Works with Redis

Rhizo has **no background daemon or server process**. It is a single compiled binary that runs atomic commands directly against Redis (`rhizo send`, `rhizo listen`). Redis manages the queues and delivers messages when assistants request them.

Rhizo maps communication directly onto standard Redis data structures:

1. **Zero-Token, Zero-CPU Inboxes (Redis Lists)**:
   - Each assistant has an inbox list (`rhizo:inbox:<agent>`).
   - Senders push messages with `LPUSH`.
   - Receivers wait for messages with `BRPOP`. This blocking wait happens entirely inside the Redis server, so idle listeners consume **zero CPU** and **zero AI tokens** while waiting.

2. **Roster and Tags (Redis Sets)**:
   - Active assistants and their role tags (like `backend`, `frontend`, `qa`) are saved in Redis sets.
   - You can see who is online instantly with `rhizo who`.

3. **Group Multicast Messaging (Set Intersection)**:
   - When sending to a group (for example, `rhizo broadcast --tags "qa"`), Redis finds matching assistants directly on the server using set intersection (`SINTER`).

4. **Automatic Cleanup (Expiration)**:
   - **Heartbeats**: Active assistants refresh a 150-second key. If an assistant exits or crashes, it is automatically removed from the active roster.
   - **Inboxes**: Inboxes have a 7-day expiration that refreshes with every new message, automatically cleaning up abandoned queues.

5. **Redis Cluster Support**:
   - In a Redis Cluster, Rhizo groups project keys using hash tags (such as `{rhizo:project}:inbox:<name>`). This ensures all keys for a project live on the same cluster node, preventing multi-key errors.

6. **Non-Blocking Memory Deallocation (`UNLINK`)**:
   - High-throughput operations (such as clearing rooms in `rhizo blackboard clear` or sweeping dead agents in `rhizo sweep`) execute `UNLINK` rather than blocking `DEL`. Deallocation of large keys and sets occurs asynchronously in background reclaim threads, avoiding latency spikes.

### Supported Engines & Minimum Versions

Rhizo requires:
- **Redis 6.2+** (effects-based Lua replication, `UNLINK` memory deallocation, and atomic multi-key set commands).
- **Valkey 7.2+ & 8.0+** (wire-compatible drop-in; native support for `valkey://` and `valkeys://` connection schemes, `VALKEY_URL` and `RHIZO_VALKEY_URL` environment variables, `--valkey-url` CLI flag, and `valkey_url` configuration keys).

### Comparison

| Traditional Agent Frameworks | Rhizo Architecture |
| :--- | :--- |
| ❌ Heavy Python/Node background server daemons | ⚡ **Daemonless**: Single CLI tool; direct Redis calls |
| ❌ Complex WebSocket/HTTP setup requiring open ports | ⚡ **Standard Redis**: Works with local or hosted Redis (AWS, Upstash, Redis Cluster) |
| ❌ High memory usage and slow startup | ⚡ **Fast and lightweight**: Single small native binary with instant startup |
| ❌ Vulnerable to prompt injection from untrusted messages | ⚡ **Built-in Authentication**: Drops unauthenticated or tampered messages automatically |
| ❌ Idle listeners consume continuous AI tokens | ⚡ **Zero-token idle**: Blocking wait consumes 0 AI tokens while waiting for work |

---

## Task Routing & Optional System 1 Decision Engine

> [!NOTE]
> **System 1 Routing is strictly OPTIONAL.**
> All core Rhizo coordination (messaging `rhizo open/send/listen`, distributed locking `rhizo lock --fencing`, explicit task queues `rhizo enqueue <queue>`, roundtable floor control, consensus ballots, and leader election) operates directly over Redis and requires **zero ML models, zero Python runtimes, and zero configuration files**.

When you have a high-throughput stream of raw, untyped natural language tasks (e.g. from Jira, Slack, or user prompts) and want zero-shot classification into typed queues without generative LLM decoding delays:
* **Explicit Queueing (Default)**: Route deterministically without models: `rhizo enqueue queue:worker:claude "Fix button CSS"`.
* **Semantic Triage (Optional)**: Route via local ModernBERT/Laya (<40ms): `rhizo enqueue --route "Fix button CSS"`.

> [!TIP]
> For the complete specification of `rhizo-routes.yaml`, including chunking limits, question types, match operators (`gte`, `lte`, `and`, `or`, `not`), and real-world examples, see the [System 1 Routes Schema Reference](docs/routes_schema.md).

### Cascading Routing Hierarchy & Scaffolding
When using semantic routing (`--route`), Rhizo resolves rules in a cascading hierarchy where more specific scopes override broader ones:
1. **Built-in Baseline**: Zero config needed; automatically classifies into standard domains (`backend`, `frontend`, `database`, `devops`, `firmware`, `docs`) routing to `queue:swarm:{{ domain.choice }}`.
2. **Global User Config**: `~/.config/rhizo/routes.yaml` (machine-wide personal baseline).
3. **Repo Root Config**: `<git-root>/rhizo-routes.yaml` (project canonical rules).
4. **Subdirectory Config**: `<repo>/packages/*/rhizo-routes.yaml` (monorepo subproject rules).
5. **Local Uncommitted Overrides**: `rhizo-routes.local.yaml` (developer scratch overrides).

Initialize routes anytime:
```bash
rhizo route init           # Scaffold project rhizo-routes.yaml
rhizo route init --global  # Scaffold machine-wide ~/.config/rhizo/routes.yaml
rhizo route lint --check-service  # Validate rules & verify daemon connectivity
```

### Local System 1 Daemon Setup (Optional)
1. **Install Daemon**: Use [`axiomantic/local-systemone`](https://github.com/axiomantic/local-systemone) (Python 3.10+):
   ```bash
   pip install "git+https://github.com/axiomantic/local-systemone.git#egg=local-systemone[full]"
   local-systemone --install-daemon   # macOS launchd or Linux systemd daemon on port 8100
   ```
2. **Cloud Alternative**: TypeSafe Jev API at `https://api.typesafe.ai` with `RHIZO_API_KEY`.
   *For detailed service setup, macOS Metal & Linux deployment instructions, and schema definitions, see [references/system_one_setup.md](references/system_one_setup.md).*

---

## How Messages Flow


Every agent receives tasks through a single atomic inbox: `${PREFIX}inbox:<agent_name>`.

```mermaid
flowchart TD
    Sender["Sending Assistant<br/><i>(Claude Code, Antigravity, etc.)</i>"]

    Sender -->|Direct Task / O2O<br/><code>rhizo send</code>| Send["Redis List<br/><code>rhizo:inbox:worker</code>"]
    Sender -->|Multicast / O2M<br/><code>rhizo broadcast</code>| Bcast["Redis SINTER Tag Filter<br/><i>(Project-Scoped AND Filter)</i>"]

    Bcast --> InboxQA["Redis List<br/><code>rhizo:inbox:qa</code>"]
    Bcast --> InboxBackend["Redis List<br/><code>rhizo:inbox:backend</code>"]

    Send --> ListenWorker["Host Process: <code>rhizo listen</code>"]
    InboxQA --> ListenQA["Host Process: <code>rhizo listen</code>"]
    InboxBackend --> ListenBE["Host Process: <code>rhizo listen</code>"]

    subgraph FW1["Air-Gap Prompt Firewall"]
        ListenWorker --> HMAC1{"HMAC-SHA256<br/>Signature Check"}
        HMAC1 -->|Valid| Deliver1["✅ Valid Payload<br/><i>Delivered to LLM Context</i>"]
        HMAC1 -->|Tampered / Forged| Drop1["❌ Dropped to Stderr<br/><i>Prompt Injection Blocked</i>"]
    end

    subgraph FW2["Air-Gap Prompt Firewall"]
        ListenQA --> HMAC2{"HMAC-SHA256<br/>Signature Check"}
        HMAC2 -->|Valid| Deliver2["✅ Valid Payload<br/><i>Delivered to LLM Context</i>"]
        HMAC2 -->|Tampered / Forged| Drop2["❌ Dropped to Stderr<br/><i>Prompt Injection Blocked</i>"]
    end

    classDef pass fill:#e8f5e9,stroke:#2e7d32,stroke-width:1.5px;
    classDef drop fill:#ffebee,stroke:#c62828,stroke-width:1.5px;
    class Deliver1,Deliver2 pass;
    class Drop1,Drop2 drop;
```

---

## Installation & Setup

Rhizo is distributed both as an AI coding agent skill and as a high-speed CLI tool.

### 1. For AI Coding Assistants (Recommended)

Install the skills globally (`-g`) across all your coding assistants (Claude Code, Antigravity, Cursor, Codex, OpenCode, etc.):

```bash
# Recommended: Install the complete multi-agent triad globally
npx skills add -g axiomantic/rhizo
npx skills add -g axiomantic/vine
npx skills add -g axiomantic/garden
```

*(Each skill automatically self-bootstraps its native CLI binary if it is not already installed on your system).*

To install only Rhizo:
```bash
npx skills add -g axiomantic/rhizo
```

### 2. Standalone CLI Installation

Install the compiled CLI tools directly onto your `$PATH`:

```bash
# Install all three tools:
npm install -g @axiomantic/rhizo @axiomantic/vine @axiomantic/garden

# Or install Rhizo alone:
npm install -g @axiomantic/rhizo
```

> [!TIP]
> **Zero-Install Run via NPX**: In restricted or containerized environments where global installation is unavailable, you can run any command directly without installing:
> ```bash
> npx -y @axiomantic/rhizo <command>
> ```

### 3. Repository Coordination Guide

To equip all AI agents working in a repository with Rhizo invariants (anti-token-thrash zero-timeout listening, task claiming, fencing tokens):
```bash
rhizo guide install
```

#### Standalone Pre-Compiled Binaries
Pre-built archives and Debian packages are attached to every [GitHub Release](https://github.com/axiomantic/rhizo/releases):

| Operating System | Architecture | Package Archive |
| :--- | :--- | :--- |
| **macOS** | Apple Silicon (M1/M2/M3/M4) | `rhizo-darwin-arm64.tar.gz` |
| **macOS** | Intel x86_64 | `rhizo-darwin-amd64.tar.gz` |
| **Linux** | x86_64 (amd64) | `rhizo-linux-amd64.tar.gz` / `.deb` |
| **Linux** | ARM64 (aarch64) | `rhizo-linux-arm64.tar.gz` / `.deb` |
| **Windows** | x86_64 (amd64) | `rhizo-windows-amd64.zip` |

---

## Uninstallation

```bash
# Uninstall the global NPM package:
npm uninstall -g @axiomantic/rhizo

# Remove agent skills (if installed separately via skills.sh):
npx skills remove rhizo -g
```

*Note: Configuration files in `~/.config/rhizo` are preserved. To completely purge configurations and secret keys, run `rm -rf ~/.config/rhizo`.*

---

## CLI Reference

| Command | Description | Example |
| :--- | :--- | :--- |
| `rhizo open [name] [tags] [--listen] [--session-id <key>]` | Registers identity, binds session ID, sets project tags, drains offline backlog, and optionally arms listener. | `rhizo open coder "qa,python"` |
| `rhizo listen [name] [timeout_sec]` | Blocks on inbox, refreshes heartbeat, drops tampered messages (default: 0 / infinite wait). | `rhizo listen` |
| `rhizo send --to <target> ... [--immediate\|--soon]` | Sends direct (O2O) message with HMAC signature and delivery urgency. | `rhizo send --to worker-1 --subject "Fix Bug" --body "src/api.py" --soon` |
| `rhizo reply --to <sender> ... [--immediate\|--soon]` | Direct reply tagged with `type=reply`, urgency, and optional `--listen` re-arm. | `rhizo reply --to lead --subject "Re: Bug" --body "Fixed" --listen` |
| `rhizo broadcast [--tags <tags>] ... [--immediate\|--soon]` | Multicasts to all agents matching tags within project with urgency. | `rhizo broadcast --tags "qa" --subject "New Release" --body "Verify"` |
| `rhizo request --to <target> ... [--immediate\|--soon]` | Synchronous RPC: dispatches task and blocks until reply received. | `rhizo request --to solver --subject "Calc" --body "2+2"` |
| `rhizo scatter --targets <tgts> ... [--immediate\|--soon]` | Fan out task to agents/tags and gather responses until quorum. | `rhizo scatter --targets @qa --subject "Tests" --body "run" --quorum 2` |
| `rhizo enqueue <queue> ...` | Pushes task to competing-consumers worker queue. | `rhizo enqueue jobs --subject "Compile" --body "gcc -O2 main.c"` |
| `rhizo work <queue> [timeout_sec]` | Pops task from competing-consumers worker queue (default: 0 / infinite wait; supports `--run-id`). | `rhizo work jobs --run-id run_01` |
| `rhizo claim <queue> [timeout_sec]` | Non-destructively leases task from queue with DLQ escalation (default: 0 / infinite wait). | `rhizo claim jobs --lease 60 --run-id run_01` |
| `rhizo claim renew <queue> <id>` | Safely extends active worker lease deadline before task expires. | `rhizo claim renew jobs "task_123" --lease 120` |
| `rhizo ack <queue> <task_id>` | Acknowledges task completion and releases active worker lease. | `rhizo ack jobs "task_123"` |
| `rhizo blackboard <cmd> <room> ...` | Shared persistent scratchpad memory (`set`, `get`, `append`, `rev`, `snapshot`/`dump`, `load`/`restore`). | `rhizo blackboard snapshot room1 state.json` |
| `rhizo floor <cmd> <room> ...` | Turn-taking floor control for roundtables (`request`, `yield`, `pass`, `status`). | `rhizo floor request room1 30` |
| `rhizo cancel <run_id> ...` | Global run cancellation tokens (`cancel`, `check`, `clear`). | `rhizo cancel run_042 --reason "Aborted"` |
| `rhizo ballot <cmd> <ballot_id> ...` | Blind voting and ballot consensus (`open`, `cast`, `tally`, `status`). | `rhizo ballot open b1 --options "A,B"` |
| `rhizo leader <cmd> <role> ...` | Resilient leader election with failover (`acquire`, `renew`, `resign`, `status`). | `rhizo leader acquire lead 30` |
| `rhizo workflow <cmd> <flow_id> ...` | Multi-stage DAG task pipelines (`define`, `next`, `resolve`, `fail`, `status`, `export`, `import`). | `rhizo workflow export pipe pipe.json` |
| `rhizo sweep [--dry-run] [--raw]` | Cluster health watchdog: prunes dead agent heartbeats & stale PID locks. | `rhizo sweep` |
| `rhizo status <state> [activity] [--listen]` | Updates agent state (`idle`, `busy`, `error`), activity text, and optionally re-arms listener. | `rhizo status idle "Awaiting tasks"` |
| `rhizo lock <lock_name> [ttl]` | Acquires atomic distributed mutex lease with optional `--fencing` counter. | `rhizo lock deploy_lock 30 --fencing` |
| `rhizo unlock <lock_name>` | Releases distributed mutex lease if caller is owner. | `rhizo unlock deploy_lock` |
| `rhizo pub <channel> <msg>` | Ephemeral pub/sub broadcast to subscribers. | `rhizo pub alerts "Build finished"` |
| `rhizo sub <channel> [timeout_sec]` | Listens for ephemeral pub/sub broadcasts without queue buildup (default: 0 / infinite wait). | `rhizo sub alerts` |
| `rhizo who [-a\|--all] [--json] [filter]` | Formatted table or JSON of active cluster agents, states, and tags (auto-prunes dead agents). | `rhizo who`, `rhizo who -a`, or `rhizo who --json` |
| `rhizo tag <add\|remove\|set> <tags>` | Dynamically adjusts tags without dropping queued messages. | `rhizo tag add "lead"` |
| `rhizo session <set\|get\|remove\|list> [args...]` | Manages global `<runtime>:<sessionId>` to agent mappings. | `rhizo session set opencode:ses_123 worker-1` |
| `rhizo check-inbox [name]` | High-speed inbox check (exits 0 with count if messages exist, exits 1 if empty). | `rhizo check-inbox worker-1` |
| `rhizo drain [count] [name] [--format json\|hook\|raw] [--hook]` | Atomically pops, authenticates, and decrypts offline messages (FIFO). Supports prompt formatting for LLM hooks. | `rhizo drain 10 worker-1 --hook` |
| `rhizo close [name] [--session-id <key>]` | Graceful deregistration, clears tags, heartbeat, and session mapping. | `rhizo close` |
| `rhizo get-secret` | Prints or initializes 256-bit cluster secret. | `rhizo get-secret` |
| `rhizo config <show\|get\|path\|init>` | Introspects resolved settings, provenance, and paths. | `rhizo config show` or `rhizo config get redis_url` |

---

## Autonomous Agent Lifecycle: Hooks, Extensions & Recipes

Coordinating autonomous coding assistants requires handling two distinct operational states:

1. **When Busy (In-Turn)**: Do NOT abort active tool calls destructively. Queue incoming messages and process them on the assistant's next response turn (**`--soon`**).
2. **When Idle (Between Turns)**: An assistant waiting on `stdin` has a paused lifecycle. Active extensions, reactive background tasks, or continuation hooks must wake the sleeping process when a message arrives.

> [!NOTE] **Modernization: Elimination of Tmux & Standalone Ears**
> Previous iterations relied on a standalone Node/Python ear daemon that injected simulated keystrokes via `tmux send-keys`. This proved brittle, error-prone, and unnatural for modern desktop IDEs (Cursor, VS Code, Antigravity, OpenCode). Rhizo has completely eliminated `tmux` dependencies in favor of:
> - **In-process extensions** for OpenCode (`opencode-ear.js`) and Pi (`pi-ear.ts`) that directly hook the host's event loop and prompt APIs.
> - **Continuation Stop hooks** for Claude Code (`claude_stop_hook.py`), OpenAI Codex (`codex_stop_hook.py`), and Antigravity (`agy_stop_hook.py`) that intercept turn completion and feed pending inbox tasks into immediate continuation turns.
> - **Native Desktop Notifications** (`rhizo listen [agent] --notify`) compiled directly into the Nim engine for Cursor, Copilot, and background terminals.

### The Coding Harness Support Matrix: First-Class Integrations & Universal Compatibility

Rhizo provides first-class, verified integrations across major AI coding assistants, categorized by their execution efficiency tier:

| Assistant Runtime | Efficiency Tier | In-Turn Deferred Delivery (`soon`) | Idle Interruption / Background Mechanism |
| :--- | :--- | :--- | :--- |
| **OpenCode** | **Tier 1 (In-Process)** | `client.session.promptAsync` appends turn without aborting active fibers | In-process plugin `opencode-ear.js` streams listener in background Node/Bun fiber; 0 token overhead |
| **Pi Coding Agent (`pi.dev`)** | **Tier 1 (In-Process)** | In-process TypeScript fiber delivers via `deliverPiPrompt` | Background fiber streams listener; `--immediate` invokes `pi.abort()` preemption; 0 token overhead |
| **Antigravity (AGY)** | **Tier 2 (Native Daemon)** | `Stop` hook returns `decision: "continue"` with context | Background task `rhizo listen` with `IsDaemon=true` triggers native **Reactive Wakeup** on stdout; 0 subagents |
| **Claude Code** | **Tier 3/4 (Hook / Subagent)** | `Stop` hook inspects inbox, returns `decision: "block"` with `additionalContext` | Autonomous `Stop` hook (`claude_stop_hook.py`) or background subagent (`Task(..., background=true)`) |
| **OpenAI Codex** | **Tier 3/4 (Hook / Subagent)** | `Stop` hook returns `decision: "block"` with `reason` as next prompt | Autonomous `Stop` hook (`codex_stop_hook.py`) or one-shot subagent (`spawn_agent`) |
| **Cursor** | **Tier 5 (Terminal)** | Foreground wait (`rhizo listen <agent>`) via `terminal` tool | Native `rhizo listen --notify` triggers OS desktop notification |
| **GitHub Copilot** | **Tier 5 (Terminal)** | CLI / terminal execution with structured JSON prompt blocks | Native `rhizo listen --notify` triggers OS desktop notification |

#### Universal "Out-of-the-Box" Compatibility for Any Coding Harness

Don't see your coding harness listed above? **Rhizo is designed to work out of the box with ANY AI coding assistant** (e.g. Windsurf, Devin, Cline, Roo Code, Aider, etc.) by following our **Capability-Based Execution Protocol**:

1. **Preference 1 (In-Process Extension)**: If the harness supports background JavaScript/TypeScript extensions, load an ear plugin to stream listening with 0 LLM token overhead.
2. **Preference 2 (Direct Background Shell Task in Main Chat)**: If the harness provides a shell execution tool with a native daemon or background parameter (e.g. `run_command(IsDaemon=true)`), run `rhizo listen <agent>` directly in the main session. This provides a direct line of communication with zero subagent token overhead.
3. **Preference 3 (Background Subagent)**: If the harness only provides subagent tools with background support (e.g. `Task(background=true)`), dispatch a one-shot listener subagent that runs `rhizo listen <agent>` synchronously and terminates upon message arrival to notify the parent.
4. **Preference 4 (Synchronous Foreground Wait)**: If the harness only supports synchronous shell execution with no background parameters, do NOT run blocking listen commands during active chat. Instead, check the inbox explicitly via `rhizo check-inbox`.

> [!TIP] **We Welcome Pull Requests!**
> Want first-class integration, native lifecycle hooks, or an in-process ear extension for your favorite coding harness? We actively welcome community contributions! Check out our [Developer Guide & Integration Checklist](CONTRIBUTING.md#developer-guide-adding-support-for-a-new-coding-harness) to get started.

#### Architectural Deep Dive: Streaming Listeners vs. One-and-Done Subagents

A common architectural question in multi-agent harness engineering: *Can a listener stay open and stream messages continuously instead of terminating after each message?*

- **The Preference for Main-Chat Background Tasks**:
  A background daemon task directly in the main chat (e.g. Antigravity `run_command(IsDaemon=true)`) or an in-process plugin (OpenCode `opencode-ear.js`) is **always preferred over subagents**. Spawning a subagent consumes substantial token overhead (initializing system prompts, tool schemas, and extra reasoning tokens). A direct background task maintains a direct, immediate line of interruption into the main conversation loop with **zero subagent token cost**.

- **Why Subagents Cannot Stream Messages (The Completion Barrier)**:
  In subagent-capable harnesses (Claude Code, OpenAI Codex), subagents operate as **one-way completion barriers**. Subagents do **NOT** stream raw intermediate standard output back into the parent conversation while running. The parent session is only notified **upon subagent completion / process exit**. If a subagent were to run an infinite streaming loop (`while true; do rhizo listen; done`), the subagent would never terminate, and the parent session would **never receive any message**—messages would be consumed from Redis and trapped inside the subagent's memory forever! Consequently, inside subagents, `rhizo listen` **must be one-and-done**: it blocks until one message arrives, outputs the JSON payload, and exits `0`, allowing the subagent to complete and deliver the payload to the parent.

- **Where Streaming Operates Today**:
  Continuous streaming listener loops operate in **Tier 1 in-process extensions** (`opencode-ear.js`, `pi-ear.ts`), where host process runtimes (Node.js/Bun) supervise background child processes and inject prompt turns into the host event loop via native APIs (`promptAsync`), entirely bypassing LLM subagent overhead.

### Canonical Command Recipes: What to Run & When (Zero Guesswork)

To eliminate any ambiguity or cognitive load when coordinating across sessions:

> [!IMPORTANT] **The Core Invariant: Never Leave an Agent in a "Deaf" State**
> Rhizo is an asynchronous distributed message bus over Redis. An agent can ONLY receive messages if it has an active listener running or has a continuation hook installed. If an agent completes a task and concludes its turn without an active listener, it becomes "deaf"—subsequent messages from peer agents will sit in Redis unread until human intervention occurs. Every command sequence below is designed to ensure continuous, uninterrupted inbox coverage.
>
> ❌ **STRICT PROHIBITION: Never use shell `&` and never redirect stdout/stderr** (`> /dev/null 2>&1 &` or `> file.log &`). Detaching with `&` creates an unmanaged zombie process, and output redirection swallows the notification stream, leaving the agent permanently deaf to incoming tasks and urgent cancellation interrupts.

```mermaid
flowchart TD
    Start([Session Bootstrap]) --> Recipe1["Recipe 1: Default Startup<br/><code>rhizo open &lt;my-name&gt; '&lt;tags&gt;' --listen</code>"]
    Recipe1 --> InTurn["Execute Task / Tool Calls<br/>(Normal Turn Processing)"]
    InTurn --> Check{"Do you need to reply or wait for next task?"}
    Check -->|Reply with Result & Await Next Task| Recipe2["Recipe 2: Atomic Reply & Re-Arm<br/><code>rhizo reply --to &lt;sender&gt; --reply-to '&lt;id&gt;' ... --listen</code>"]
    Check -->|No Reply Needed, Just Wait| Recipe2b["Recipe 2b: Indefinite Wait (Zero Timeout)<br/><code>rhizo listen &lt;my-name&gt;</code>"]
    Check -->|Work Completely Finished| RecipeClose["Recipe 5: Clean Disconnect<br/><code>rhizo close &lt;my-name&gt;</code>"]
    Check -->|Using Autonomous Continuation Hooks| Recipe4["Recipe 4: Stop Hook Continuation<br/>Turn ends naturally; hook detects incoming message & continues"]
    Check -->|Subagent Completed One-Shot Listen| Recipe3["Recipe 3: Relaunch Subagent Ear<br/>Spawn fresh subagent with <code>rhizo listen &lt;my-name&gt;</code>"]
    Recipe2 --> InTurn
    Recipe2b --> InTurn
    Recipe3 --> InTurn
    Recipe4 --> InTurn
    RecipeClose --> Done([Session Closed Cleanly])
```

#### 1. Recipe 1: Default Startup ("Open and Listen")
1. **Register Identity**:
   ```bash
   rhizo open <my-name> "<tags>"
   ```
   *(Registers identity in Redis, sets project tags, binds session mapping, and drains any offline backlog).*

2. **Arm the Listener Based on Harness Tool Capabilities (Zero Guesswork)**:
   - **In-Process Harness Ear Extension (OpenCode `opencode-ear.js`, Pi `pi-ear.ts`)**:
     Do NOT execute `rhizo listen`. The bundled in-process extension maintains a continuous background fiber delivering incoming turns with 0 LLM token overhead.
   - **Main Chat Shell with Native Daemon / Background Parameter (Antigravity)**:
     Launch the listener via the tool's native background execution parameter:
     ```python
     run_command(CommandLine="rhizo listen <my-name>", WaitMsBeforeAsync=500, IsDaemon=True)
     ```
     The platform's native reactive wakeup will resume your turn when an incoming message arrives.
   - **Subagent / Background Task Support (Claude Code `Task(..., background=true)`, OpenAI Codex `spawn_agent`)**:
     Dispatch a one-shot background subagent running synchronous blocking `rhizo listen <my-name>` (no daemon inside the subagent: avoid double-daemons!). When a message arrives, the subagent terminates and delivers the payload to the parent turn.
   - **Dedicated Headless Shell / Human Worker Terminal**:
     ```bash
     rhizo open <my-name> "<tags>" --listen
     ```
     In a dedicated terminal window, passing `--listen` (`-l`) registers and immediately transitions in-process into waiting for work.
   - **Synchronous-Only Harness (No Background Execution Available)**:
     **DO NOT run `rhizo listen`** in the main conversation—a blocking listen call freezes the conversation turn and locks user input. Inform the user of this platform limitation, and check inbox explicitly via `rhizo check-inbox` during user turns.

#### 2. Recipe 2: Post-Task Transition ("After Task Finishes: Do I Re-Open?")
- **DO I NEED TO RUN `rhizo open` AGAIN?**
  **NO! Never re-run `rhizo open` after completing a task.** Your registration, tags, and heartbeat remain active in Redis for the session duration. Re-running `open` unnecessarily resets registration state. Only re-run `rhizo open` if the session crashed, reconnected after a long network disconnect, or heartbeat expired.
- **HOW DO I SEND MY RESULT AND WAIT FOR THE NEXT TASK?**
  When running in a dedicated terminal, background daemon, or inside a listener subagent, use **Atomic Reply & Re-Arm**:
  ```bash
  rhizo reply --to <sender> --subject "Re: <subj>" --body "<result>" --reply-to "<id>" --listen
  ```
  - **Why `--reply-to "<id>"` is expected**: Correlates the response with the sender's original task ID. This is required for synchronous RPC (`rhizo request`), scatter-gather quorum aggregation, and DAG workflow step resolution.
  - **Why `--listen` (`-l`) is expected**: Delivers the reply and immediately re-arms the listener *in the exact same command*. In interactive main-chat sessions without daemon shell parameters, omit `--listen` (`rhizo reply --to <sender> --subject "Re: <subj>" --body "<result>" --reply-to "<id>"`) and re-arm the listener via your harness subagent or stop hook.
- **WHAT IF NO REPLY IS NEEDED (JUST WAITING FOR WORK)?**
  Run with **NO TIMEOUT**:
  ```bash
  rhizo listen <my-name>
  ```
  - **Default Must Always Be Infinite Wait (`timeout = 0` / no timeout)**: Never specify an arbitrary bounded timeout (e.g. 30s or 120s). When a timeout expires, the command exits empty, forcing the assistant into an unnecessary LLM inference cycle (token thrashing) just to re-run the listener. A Redis `BLPOP` blocks indefinitely at the socket level with 0 CPU, 0 bandwidth, and 0 tokens burned until work actually arrives. Timeouts are optional and explicitly discouraged across the board.

#### 3. Recipe 3: Subagent Ear Completion & Relaunch
When running in an assistant that uses a one-shot subagent to listen (e.g. Claude Code `Task(background=true)` or OpenAI Codex):
1. The subagent runs `rhizo listen <my-name>` (with NO timeout, NO `&`, NO output redirection), blocks until ONE message arrives, outputs the JSON, and terminates cleanly.
2. The parent assistant receives the message JSON.
3. The parent assistant executes the requested work and sends the reply via `rhizo reply --reply-to "<id>" ...`.
4. **IMMEDIATE RELAUNCH**: Before or while concluding the turn, the parent assistant MUST spawn a fresh one-shot subagent running `rhizo listen <my-name>` to catch the next message.

#### 4. Recipe 4: Autonomous Turn Relaunching via Stop Hooks (Zero Cognitive Overhead)
If your harness supports lifecycle hooks (`claude_stop_hook.py`, `codex_stop_hook.py`, `agy_stop_hook.py`):
- You NEVER need to write `while true` loops, detach processes with `&`, or remember to re-listen.
- Whenever your turn finishes, the harness invokes the hook.
- The hook checks `rhizo check-inbox`. If a message is waiting, it returns `{"decision": "block", ...}`, preventing the session from going idle and immediately starting a continuation turn with the new message payload!

#### 5. Recipe 5: Clean Disconnect / Session End
When your assigned work is completely finished and you will not take any further tasks:
```bash
rhizo close <my-name>
```
- **Why `rhizo close` is expected**: Removes your agent's heartbeat from Redis, unlinks the listener PID lock, and clears session mappings. This ensures peer agents do not see you as active online (`rhizo who`) and prevents tasks from being queued to an abandoned session.

---

### Engine Lifecycle Post-Ambles & The Quiet Flag

When `rhizo listen` delivers a message and exits, the Nim engine automatically prints a **Harness-Aware Lifecycle Notice** to `stderr`:
```text
[RHIZO LIFECYCLE NOTICE] Listener for 'worker-1' delivered message 'msg_...' and EXITED.
- Detected harness: <harness> (consult Capability Decision Tree in AGENTS.md / SKILL.md)
- Expected follow-up action:
  1. When finished, reply and re-arm atomically in one command:
     rhizo reply --to <sender> --reply-to "<id>" --subject "Re: <subj>" --body "<results>" --listen
  2. If no reply is needed, wait for next task (zero-timeout infinite wait):
     rhizo listen worker-1
  3. If using subagents: dispatch a fresh one-shot listener subagent before concluding turn.
  4. If disconnecting or finishing session work completely:
     rhizo close worker-1
(To silence this notice: pass --quiet / -q, or set RHIZO_QUIET=1)
```

- **Stdout remains pure JSON**: Shell scripts, pipelines (`rhizo listen | jq .`), and automated test parsers continue reading clean JSON without parse errors.
- **LLM tool runners capture stderr**: In Claude Code, Codex, Cursor, and AGY, tool execution captures stderr alongside stdout, providing the LLM with direct, unmistakable next-step guidance tailored to its runtime harness.
- **Harness Detection**: The engine automatically detects the runtime harness (OpenCode, Pi, Codex, Antigravity, Claude, Cursor, Copilot) via session key prefixes (`opencode:`, `pi:`, `codex:`, `agy:`, `claude:`, `cursor:`) or environment variables (`OPENCODE_SESSION_ID`, `PI_SESSION_ID`, `CODEX_SESSION_ID`, `ANTIGRAVITY_APP_DIR`, `CLAUDE_CODE`, `CURSOR_APP`).
  - **OpenCode & Pi**: The notice warns that in-process extension fibers are active and instructs the agent *not* to run a blocking `rhizo listen`.
  - **OpenAI Codex / Claude Code**: The notice instructs the agent to dispatch a fresh one-shot listener subagent before concluding its turn.
  - **Antigravity**: The notice instructs the agent to re-arm its reactive background listener via `run_command` or append `--listen`.
  - **Dedicated Worker Terminal / Other**: The notice presents the atomic reply & re-arm pattern (`--listen`) or zero-timeout wait.
- **Suppression / Quiet Flag**: To suppress the lifecycle notice in automated scripts or extensions, pass `--quiet` / `-q`, or export `RHIZO_QUIET=1`.

---

### 1. Claude Code Hook Configuration (`.claude/settings.json`)

Configure Claude Code to automatically check the Rhizo inbox whenever a response finishes:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.gemini/config/skills/rhizo/hooks/claude_stop_hook.py"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.gemini/config/skills/rhizo/hooks/session_lifecycle_hook.py start"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.gemini/config/skills/rhizo/hooks/session_lifecycle_hook.py end"
          }
        ]
      }
    ]
  }
}
```

### 2. OpenAI Codex Hook Configuration (`~/.codex/hooks.json`)

Configure Codex to feed incoming messages directly into continuation turns:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.gemini/config/skills/rhizo/hooks/codex_stop_hook.py"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.gemini/config/skills/rhizo/hooks/session_lifecycle_hook.py start"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.gemini/config/skills/rhizo/hooks/session_lifecycle_hook.py end"
          }
        ]
      }
    ]
  }
}
```

### 3. OpenCode Plugin Configuration (`opencode.json`)

Add `opencode-ear.js` to your `opencode.json` plugin array:

```json
{
  "plugin": [
    "~/.config/opencode/opencode-ear.js"
  ]
}
```
*Automatically maps `opencode:<sessionId>` in `~/.config/rhizo/sessions.json`, injects `RHIZO_SESSION_ID` via `shell.env`, and delivers messages via `promptAsync` (or `abort` for `--immediate`).*

### 4. Desktop Notifications for Idle Sessions (`rhizo listen --notify`)

When running an assistant in Cursor, VS Code, or an idle terminal tab in the background, you can enable native operating system notifications:

```bash
rhizo listen --notify
# Or for a specific agent:
rhizo listen backend-worker --notify
```
When a peer message arrives, Rhizo displays a native OS notification banner (macOS Notification Center, Windows Action Center toast, or Linux `notify-send`) alerting you to the incoming task.

### 5. Pi Coding Agent Extension (`~/.pi/agent/extensions/rhizo.ts`)

For [Pi Coding Agent (`pi.dev`)](https://pi.dev), Rhizo provides a native TypeScript extension (`pi-ear.ts`):

```bash
# Automated via install.sh or manual setup:
mkdir -p ~/.pi/agent/extensions ~/.pi/agent/skills/rhizo
cp skills/rhizo/pi-ear.ts ~/.pi/agent/extensions/rhizo.ts
cp skills/rhizo/SKILL.md ~/.pi/agent/skills/rhizo/SKILL.md
```

- **Native Tool Registration**: Registers `rhizo` directly into Pi's tool registry (`pi.registerTool`) with full subcommand schemas (`open`, `send`, `reply`, `listen`, `status`, `who`).
- **Session Mapping**: Automatically maps `pi:<sessionId>` to `RHIZO_AGENT_NAME` in `~/.config/rhizo/sessions.json`.
- **Background Listener Fiber**: Asynchronously streams `rhizo listen <agent> 0` in an unblocked fiber.
- **Urgent Preemption**: For `--immediate` messages, triggers `pi.abort()` to halt active computation before injecting the prompt into the session turn.

### 6. Cursor Rules (`.cursor/rules/rhizo.mdc`)

Equip Cursor agents with project or user-level rules:

```bash
# Project-level rule:
mkdir -p .cursor/rules
cp skills/rhizo/rules/cursor-rules.mdc .cursor/rules/rhizo.mdc

# Or global user rule:
mkdir -p ~/.cursor/rules
cp skills/rhizo/rules/cursor-rules.mdc ~/.cursor/rules/rhizo.mdc
```

- **Execution Model**: Directs Cursor agents to execute Rhizo subcommands using Cursor's built-in `terminal` tool.
- **In-Turn Waiting**: Zero-timeout listening (`rhizo listen <my-name>`) while waiting for expected peer responses.
- **Idle Notifications**: Run `rhizo listen <name> --notify` in a background terminal for native desktop notifications.

### 7. GitHub Copilot Instructions (`.github/copilot-instructions.md`)

Instruct GitHub Copilot CLI and Copilot Chat agent mode:

```bash
mkdir -p .github
cp skills/rhizo/rules/copilot-instructions.md .github/copilot-instructions.md
```

- **Execution Model**: Coordinates via `gh copilot` CLI and terminal task execution.
- **Protocol Adherence**: Formats requests with explicit types (`task`, `reply`, `event`) and honors `--immediate` preemption flags.

---

## Configuration Architecture & Profiles

> [!TIP]
> For the comprehensive table of all `RHIZO_*` environment variables, backward-compatibility aliases, cryptographic key management, and profile inheritance rules, see the [Rhizo Configuration & Environment Reference](docs/configuration.md).

Rhizo provides deterministic, multi-tiered cascading configuration resolution:

```mermaid
flowchart TD
    Tier1["1. Explicit CLI Flags<br/><code>--redis-url, --valkey-url, --project, --profile, etc.</code>"]
    Tier2["2. Process Environment Variables<br/><code>RHIZO_REDIS_URL, VALKEY_URL, RHIZO_PROJECT, etc.</code>"]
    Tier3["3. Workspace / Project Config<br/><code>.rhizo.toml, .rhizo.toml (git root)</code>"]
    Tier4["4. Per-User Config<br/><code>~/.config/rhizo/config.toml</code>"]
    Tier5["5. Global / System Config<br/><code>/etc/rhizo/config.toml</code>"]
    Tier6["6. Built-in Hermetic Defaults<br/><code>redis://127.0.0.1:6379, rhizo:</code>"]

    Tier1 -->|Overrides| Tier2
    Tier2 -->|Overrides| Tier3
    Tier3 -->|Overrides| Tier4
    Tier4 -->|Overrides| Tier5
    Tier5 -->|Overrides| Tier6

    classDef default fill:#f9fafb,stroke:#9ca3af,stroke-width:1.5px;
    class Tier1,Tier2,Tier3,Tier4,Tier5,Tier6 default;
```

### Configuration Files

- **Workspace**: `.rhizo.toml` or `.rhizo.toml` in the project root (walks upwards to `.git`).
- **User**: `~/.config/rhizo/config.toml` (Linux/macOS) or `%APPDATA%\rhizo\config.toml` (Windows).
- **System**: `/etc/rhizo/config.toml` (Linux), `/Library/Application Support/rhizo/config.toml` (macOS), or `%ProgramData%\rhizo\config.toml` (Windows).

### Example `.rhizo.toml`

```toml
# Supports redis://, rediss://, valkey://, valkeys:// (or 'valkey_url')
redis_url = "redis://127.0.0.1:6379"
prefix = "rhizo:"
project = "my-project"
encrypt = false
cluster = false
heartbeat_ttl = 150
message_ttl = 604800
listen_timeout = 0 # 0 = infinite wait (recommended to prevent LLM token thrashing)

# Shared secret file (avoids committing secrets into git)
secret_file = "~/.config/rhizo/secret"

# Named profiles: rhizo --profile staging <subcommand>
[profiles.staging]
redis_url = "rediss://staging.internal:6380"
prefix = "stg:rhizo:"
encrypt = true

[profiles.prod]
redis_url = "rediss://prod-cluster.internal:6379"
cluster = true
encrypt = true
```

### Configuration CLI Commands

- `rhizo config show`: Displays the resolved configuration alongside the **source provenance** of each value (CLI flag, env var, workspace config, user config, or default).
- `rhizo config show --json`: Machine-readable JSON output of settings and provenance.
- `rhizo config get <key>`: Script-friendly access to individual values (`rhizo config get redis_url`).
- `rhizo config path`: Lists candidate configuration files on the system and their existence status.
- `rhizo config init [--user | --project]`: Scaffolds a starter `.rhizo.toml` file.

---


## Security & Prompt Injection Firewall

Rhizo protects coding assistants from prompt injection, forged messages, and unauthorized execution:

```mermaid
flowchart LR
    RedisIn["Redis Inbox Payload<br/><code>rhizo:inbox:&lt;agent&gt;</code>"] --> Listen["Host Verification<br/><code>rhizo listen</code>"]
    Secret[("Local Secret<br/><code>~/.config/rhizo/secret</code><br/><i>0600 Permissions</i>")] -.-> HMAC
    Listen --> HMAC{"HMAC-SHA256<br/>Verification"}
    HMAC -->|Signature Mismatch<br/>or Untrusted| Drop["❌ Dropped to Stderr<br/><i>Never enters assistant context</i>"]
    HMAC -->|Valid Signature| Decrypt{"E2EE Enabled?<br/><code>RHIZO_ENCRYPT</code>"}
    Decrypt -->|Yes| AES["In-Memory OpenSSL EVP<br/>AES-256-CBC Decryption"]
    Decrypt -->|No| Stdout["✅ Emitted to Stdout<br/><i>Assistant Context Window</i>"]
    AES --> Stdout

    classDef valid fill:#e8f5e9,stroke:#2e7d32,stroke-width:1.5px;
    classDef invalid fill:#ffebee,stroke:#c62828,stroke-width:1.5px;
    class Stdout valid;
    class Drop invalid;
```

1. **Host-Level Verification**: Messages are cryptographically validated by `rhizo listen` on your local host machine before reaching standard output.
2. **Untrusted Payloads Dropped**: Forged or unauthenticated messages are rejected immediately. They never enter the assistant's context window.
3. **Local Secret**: The secret key (`~/.config/rhizo/secret`, `0600` permissions) stays on your machine. It never enters prompts, Git commits, or Redis keys.
4. **Optional End-to-End Encryption (E2EE)**: Set `RHIZO_ENCRYPT=1` to encrypt message bodies with AES-256-CBC PBKDF2, ensuring plain text is never stored in Redis.

---

## Cross-Host Multi-Machine Coordination

Rhizo is built from the ground up for seamless distributed coordination across multiple physical workstations, cloud instances, and isolated development containers. Multiple assistants running on different machines coordinate over a single Redis or Valkey instance with full cryptographic authentication and host-level provenance tracking.

```mermaid
flowchart LR
    subgraph HostA["Machine A: macOS Workstation (dev-mac)"]
        A_Lead["Lead Assistant<br/><i>(Claude Code)</i>"]
        A_CLI["rhizo CLI / Ear"]
        A_Lead <--> A_CLI
    end

    subgraph HostB["Machine B: Linux GPU Server (gpu-box)"]
        B_Worker["Worker Assistant<br/><i>(OpenCode)</i>"]
        B_Ear["OpenCode Ear Plugin"]
        B_Worker <--> B_Ear
    end

    subgraph Bus["Shared Redis / Valkey Infrastructure"]
        RedisServer[("Central Redis / Valkey<br/><i>Local LAN, Upstash, or AWS</i>")]
    end

    A_CLI <-->|Direct Connection or<br/>SSH Tunnel :6379| RedisServer
    B_Ear <-->|Direct Connection or<br/>SSH Tunnel :6379| RedisServer

    classDef host fill:#f0f4c3,stroke:#9e9d24,stroke-width:1.5px;
    classDef redis fill:#ffebee,stroke:#c62828,stroke-width:1.5px;
    class HostA,HostB host;
    class Bus,RedisServer redis;
```

### 1. Connection Topologies: Direct Shared Network vs. SSH Port Forwarding

Depending on your network architecture and security policies, choose between direct network access or encrypted SSH tunnels:

#### Option A: Direct Shared Redis / Valkey Network
When your machines reside on the same local network, VPN, Tailscale mesh, or connect to a cloud service (e.g., Upstash, AWS ElastiCache, DigitalOcean):
```bash
# Set connection string on all participating hosts:
export RHIZO_REDIS_URL="redis://192.168.1.50:6379"
# Or with TLS:
export RHIZO_REDIS_URL="rediss://default:secret@cluster.internal:6379"

# Share the HMAC secret file across machines (0600 permissions):
scp ~/.config/rhizo/secret user@remote-box:~/.config/rhizo/secret
```

#### Option B: Encrypted SSH Port-Forwarding Tunnel
If the remote Redis instance is not exposed to the public network, establish a secure SSH tunnel from the worker host:
```bash
# On the remote worker machine, forward local port 6379 to the central Redis host:
ssh -N -L 6379:localhost:6379 user@primary-workstation.internal &

# Rhizo automatically connects to localhost:6379 over the encrypted tunnel:
rhizo who
```

### 2. Host Origin Provenance Header (`[host: <hostname>]`)

In multi-machine topologies, coding assistants often exchange file paths, terminal commands, and workspace references. If an assistant on `dev-mac` asks an assistant on `gpu-box` to *"inspect `/Users/alice/repo/config.json`"*, the recipient would fail if it assumed the path was local.

To eliminate this ambiguity:
- Rhizo automatically stamps the origin machine's hostname on every message envelope:
  ```json
  {
    "id": "msg_1710789000_lead_4242",
    "from": "lead-dev",
    "to": "gpu-trainer",
    "host": "dev-mac.local",
    "type": "task",
    "subject": "Run Benchmark",
    "body": "Run python scripts/train.py --batch 64",
    "urgency": "soon"
  }
  ```
- Passive drain hooks and active ears render the origin host directly in the context header:
  ```text
  [RHIZO BUS] 1 new message received on inbox for 'gpu-trainer':
  - From @lead-dev [host: dev-mac.local] (subject: "Run Benchmark") [type: task, urgency: soon]:
    Run python scripts/train.py --batch 64
  ```
- This immediately informs the receiving assistant that filepaths originating from `@lead-dev` reside on `dev-mac.local`, prompting the agent to either operate remotely via git/rsync or request code payloads over the message body.

### 3. Multi-Host Lock Safety & Watchdog Sweeping

Distributed environments must handle network partitions and machine restarts without corrupting agent state:
- **Foreign Host Lock Isolation**: Listener heartbeats and worker leases store both the PID and origin hostname. When an assistant runs `rhizo open` or `rhizo sweep`, it checks whether a lock belongs to the *current host*:
  - **Local Host**: If the lock was created by the local machine and the PID is dead, it is immediately self-healed and recycled.
  - **Foreign Host**: If the lock was created by a remote host (`host != currentHost`), Rhizo **never** assumes the PID is dead locally. It preserves the remote lock until the remote heartbeat TTL naturally expires, completely preventing split-brain conditions across machines.

---

## Redis Cluster Support (Hash Tags)

In a Redis Cluster, keys are distributed across multiple shards. Multi-key operations (`SINTER`, `SMEMBERS`) require that related keys live on the same shard.

Rhizo supports Redis Cluster hash tags automatically:
- Set `RHIZO_CLUSTER=1` (or `cluster = true` in config).
- Rhizo wraps the project prefix in curly brackets: `{rhizo:<project>}:inbox:<name>`.
- Redis hashes only the text inside `{...}`, guaranteeing that **all keys for the same project live on the exact same cluster shard**.
- You can also specify custom hash tags directly in `prefix` (for example, `prefix = "{team-alpha}:"`).


## Assistant Integration (Skill)

Rhizo is packaged as an assistant skill for Claude Code, Antigravity, and other coding assistants:

- **Skill Specification**: [`skills/rhizo/SKILL.md`](skills/rhizo/SKILL.md) (comprehensive multi-assistant protocol)
- **Wire Specification**: [`references/wire_spec.md`](references/wire_spec.md)
- **Validation Schema**: [`tests/schema.py`](tests/schema.py) (strict Pydantic envelope model)

---

## Performance & Benchmarks

Empirically measured end-to-end wall-clock timings on Apple Silicon against local Redis 7.2 via [`tests/benchmark.py`](tests/benchmark.py):

| Metric | Measurement | Description |
| :--- | :--- | :--- |
| **Binary Size** | `~313 KB` | Standalone static binary (stripped), zero runtime dependencies |
| **Cold Process Startup** | `~5.3 ms` | Full process spawn, arg parsing, OpenSSL bindings |
| **End-to-End Send Dispatch** | `~12.8 ms` | CLI invocation, HMAC-SHA256 signature, JSON encode, EVALSHA |
| **Optional E2EE 150KB Send + Listen** | `~39.7 ms` | Full roundtrip: AES-256 PBKDF2 (10k iter) encrypt + Redis + decrypt |
| **Idle Token Consumption** | `0 tokens` | Blocking `BRPOP` listener consumes zero LLM tokens while waiting |

---

## Testing & Verification

Rhizo includes a 100% automated, marked `pytest` suite:

```bash
# Run all hermetic unit tests (Protocol, Security, Native Binary, Cross-Platform Installer)
pytest -v -m "not llm"

# Run live LLM integration tests (uses local Ollama by default, skips cleanly if offline)
pytest -v -m llm

# Run live LLM integration tests via OpenRouter / Cloud API
LLM_API_KEY="sk-or-..." LLM_MODEL="deepseek/deepseek-chat" pytest -v -m llm
```


Continuous Integration (GitHub Actions) runs:
- **CI Workflow (`ci.yml`)**: Executes hermetic unit tests (`pytest -v -m "not llm"`) against live Redis services on Ubuntu Linux, macOS, and Windows on every push and pull request.
- **LLM CI Workflow (`llm-ci.yml`)**: Runs live model integration tests against OpenRouter (defaulting to `deepseek/deepseek-chat` or free models such as `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free`) on release tags (`v*`), merges to `main`, and maintainer-reviewed pull requests.

All tests execute against live Redis and validate payloads strictly against formal Pydantic schemas.


---

## License

Rhizo is open-source software licensed under the [MIT License](LICENSE).
Copyright (c) 2026 Axiomantic.
