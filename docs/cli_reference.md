# Rhizo CLI Reference Manual

> **Complete Command-Line Catalog & Interface Specification**  
> *A normative reference for all 35+ commands, subcommands, flags, exit codes, and JSON outputs supported by the Rhizo CLI.*

---

## 1. Global Options & Environment Variables

All `rhizo` commands accept the following global flags and environment variables:

| Flag | Env Variable | Default | Description |
| :--- | :--- | :--- | :--- |
| `-u, --url <url>` | `RHIZO_REDIS_URL` | `redis://127.0.0.1:6379` | Redis or Valkey connection URI. |
| `-p, --prefix <pfx>`| `RHIZO_PREFIX` | `rhizo:` | Keyspace prefix. In clusters, use hash tags `{rhizo}:`. |
| `--secret <key>` | `RHIZO_SECRET_KEY` | None | HMAC-SHA256 signing secret for payload authentication. |
| `--json` | `RHIZO_JSON` | `false` | Emits machine-parseable JSON output to stdout. |
| `-v, --verbose` | `RHIZO_VERBOSE` | `false` | Emits diagnostic logs to stderr. |

---

## 2. Identity, Presence & Registry Commands

### `rhizo name`
Atomically reserves and outputs a unique, collision-free codename (e.g. `rhizo-sequoia`) held in Redis for 10 minutes.
```bash
rhizo name
# Output: rhizo-sequoia
```

### `rhizo open <name> [tags]`
Registers agent presence, associates optional comma-separated tags, and initializes the inbox.
```bash
rhizo open worker-alpha "backend,qa"
```

### `rhizo close [name]`
Gracefully unregisters an agent, cleans up ephemeral presence keys, and yields active leases.
```bash
rhizo close worker-alpha
```

### `rhizo who [--json]`
Displays all registered agents, heartbeat latency, current tasks, and listening state.
```bash
rhizo who --json
```
*JSON Output:*
```json
[
  {
    "agent": "worker-alpha",
    "status": "ACTIVE",
    "tags": ["backend", "qa"],
    "state": "IDLE",
    "activity": "Listening on inbox",
    "listener": "LISTENING",
    "elapsed_seconds": 12
  }
]
```

### `rhizo ping`
Verifies round-trip latency to the Redis server. Exits 0 on success, 1 on failure.

### `rhizo alias set <alias> <target>` / `alias del` / `alias list`
Manages bidirectional role aliases.
```bash
rhizo alias set lead rhizo-sequoia
rhizo alias list
rhizo alias del lead
```

### `rhizo probe <agent>`
Inspects deep health for a specific agent (connection latency, unread inbox count, lock holdings).

---

## 3. Messaging & Mailbox Commands

### `rhizo send`
Sends a point-to-point message to an agent, queue, or alias.
```bash
rhizo send --to worker-alpha --from orchestrator --type task \
  --subject "Fix memory leak" --body "Please inspect memory RSS in ccache."
```

### `rhizo reply`
Sends a response message to a target agent.
```bash
rhizo reply --to orchestrator --from worker-alpha \
  --subject "Task Complete: Two-Key Gate Passed" \
  --body "All 25 tests passing in isolated strand." \
  --skip-gate --idle
```
*Key Flags:*
- `--skip-gate`: Bypasses gate token checks when sending non-code completion reports.
- `--idle`: Automatically transitions worker presence state to `IDLE` in Redis.
- `--listen`: Atomically arms the single-shot listener immediately after dispatch.

### `rhizo broadcast`
Multicasts an announcement to all connected swarm agents or specific tags (`@architect`).
```bash
rhizo broadcast --from orchestrator --subject "Code Freeze Initiated" --body "Weaving trunk."
```

### `rhizo listen <agent>`
Enters single-shot blocking wait for incoming messages.
```bash
rhizo listen worker-alpha
```
> [!IMPORTANT]
> **Listener Invariant**: Single-shot execution. The command blocks with zero timeout (infinite wait) on Redis `BRPOP`. Once a message is popped, it writes the message envelope to stdout and **immediately exits with code 0**.

### `rhizo inbox [name] [count] [--limit N] [--peek|--no-drain] [--drain] [--json|--hook|--raw]`
Consumes or inspects up to $N$ messages from an agent's inbox (FIFO oldest first). Defaults to draining (atomic pop). Pass `--peek` or `--no-drain` to inspect messages without consuming them.
```bash
rhizo inbox worker-alpha --limit 50
rhizo inbox worker-alpha --limit 50 --peek
```

### `rhizo drain [count] [agent] [--limit N] [--format json|hook|raw] [--hook]`
Non-blocking pop of up to $N$ messages from an agent's inbox.
```bash
rhizo drain 10 worker-alpha
```

### `rhizo check-inbox [agent]`
Outputs integer count of pending unread messages in an inbox.

### `rhizo history [agent] [--limit <n>]`
Non-destructively reads recent message history without popping from queue.

---

## 4. Distributed Locking & Monotonic Fencing

### `rhizo lock <resource>`
Acquires a distributed mutex lock with an optional monotonic fencing token and lease duration.
```bash
rhizo lock git:canonical:trunk --holder worker-alpha --lease 300 --fencing
# Output:
# {"status":"ACQUIRED","resource":"git:canonical:trunk","holder":"worker-alpha","token":42,"lease_sec":300}
```

### `rhizo unlock <resource>`
Releases a distributed lock, validating that the caller holds the active token.
```bash
rhizo unlock git:canonical:trunk --holder worker-alpha --token 42
```

### `rhizo check-lock <resource>`
Inspects current holder, token, and remaining lease TTL for a resource lock.

---

## 5. Work Item State Machine (WISM) Commands

### `rhizo task create <id>`
Creates a new WISM task with dependencies and payload.
```bash
rhizo task create task-01 --queue queue:backend --depends-on task-00 --payload '{"action":"migrate"}'
```

### `rhizo task claim <id>`
Claims a delivered task, acquiring ownership and a monotonic fencing lease.
```bash
rhizo task claim task-01 --worker worker-alpha --lease 1800
```

### `rhizo task progress <id>`
Reports milestone progress and renews the active task lease.
```bash
rhizo task progress task-01 --worker worker-alpha --note "Unit tests 100% green"
```

### `rhizo task yield <id>`
Relinquishes an in-flight task back to the queue due to external blockers.
```bash
rhizo task yield task-01 --worker worker-alpha --reason "Waiting on DB credentials"
```

### `rhizo task complete <id>`
Marks a task `COMPLETED` and auto-promotes downstream dependent child tasks to `QUEUED`.
```bash
rhizo task complete task-01 --worker worker-alpha
```

### `rhizo task inspect <id> [--json]`
Retrieves full WISM metadata, attempts counter, lease expiration, and dependency graph.

### `rhizo task list [--state <st>] [--queue <q>]`
Lists active tasks filtered by state (`QUEUED`, `IN_PROGRESS`, `BLOCKED`, `DEAD_LETTER`).

---

## 6. Classic Work Queue Commands

### `rhizo enqueue <queue> <payload> [--route <text>]`
Enqueues a task payload to a competing-consumer work queue. If `--route` is provided, evaluates System 1 rules.
```bash
rhizo enqueue queue:backend:tasks "Migrate schema to v2"
rhizo enqueue --route "Fix CSS grid alignment on dashboard"
```

### `rhizo claim <queue> [--lease <sec>]`
Pops and leases the next available item from a competing-consumer work queue.

### `rhizo ack <queue> <task_id>`
Acknowledges successful completion of a leased task, clearing it from the pending registry.

---

## 7. Consensus, Roundtable & Mesh Governance

### `rhizo floor <request|release|pass|status> <session>`
Coordinates speaker turns during multi-agent roundtables.

### `rhizo ballot <create|vote|tally> <ballot_id>`
Runs blind consensus ballots to prevent LLM anchoring bias.

### `rhizo leader <acquire|release|status> <group>`
Provides fault-tolerant mesh leader election with auto-lease failover.

---

## 8. Cluster Watchdog & Maintenance

### `rhizo watchdog check [--agent <name>] [--json]`
Performs a deep cluster audit, checking for dead listeners, unread backlogs, or stalled leases.

### `rhizo sweep`
Garbage collects stale agent presences, expired locks, and orphaned tasks.

### `rhizo guide install`
Installs the canonical `RHIZO GUIDE` block into the repository `AGENTS.md`.

---

## 9. Scheduled Cron & Heartbeats (Pulse)

### `rhizo pulse add <id> --cron "<expr>" --task "<task>" [--agent <agent>] [--scope <scope>]`
Registers a distributed recurring cron job in Redis sorted sets.
```bash
rhizo pulse add cluster_sweep --cron "*/10 * * * *" --task "rhizo sweep" --agent watchdog
```

### `rhizo pulse list [--scope <scope>] [--json]`
Lists all active scheduled pulses, their target agents, cron expressions, and next trigger timestamps.

### `rhizo pulse tick [--max <n>] [--json]`
Evaluates and fires due pulses, dispatching them to target agent inboxes and advancing cron execution intervals with atomic Lua execution.

### `rhizo pulse remove <id>`
Deletes a registered pulse schedule from the cluster.

