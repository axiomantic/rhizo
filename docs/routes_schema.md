# System 1 Semantic Routing YAML Schema Reference (`rhizo-routes.yaml`)

Rhizo's System 1 Semantic Routing Engine provides millisecond-latency task triage and automatic routing over local decision models (e.g. Laya, Decider, Jev, or Ollama/vLLM endpoints). 

Routing rules are defined in declarative YAML files. This document specifies the full schema, operator semantics, chunking limits, and real-world examples.

---

## 1. File Discovery & Cascading Hierarchy

When `rhizo route` or `rhizo enqueue --route` executes, it resolves routing configuration across three hierarchical tiers:

```
1. Explicit CLI Flag:        --routes <path> or env var RHIZO_ROUTES_FILE
2. Local Developer Overlay:  .rhizo-routes.local.yaml (gitignored local overrides)
3. Repository Root Config:   rhizo-routes.yaml (project-shared rules)
4. Global User Fallback:     ~/.config/rhizo/rhizo-routes.yaml (machine-wide fallback)
```

If no configuration file exists at any tier, Rhizo falls back to built-in heuristic triage.

### Scaffolding New Configurations

```bash
# Create project-level rhizo-routes.yaml:
rhizo route init

# Create machine-wide global routes template:
rhizo route init --global

# Validate syntax and match operator integrity:
rhizo route lint
```

---

## 2. Root Schema Specification

A valid `rhizo-routes.yaml` file contains five top-level keys:

```yaml
version: "1.0"          # Required: Schema version string ("1.0")

service:                # Optional: Inference endpoint configuration
  url: "http://127.0.0.1:8100"
  timeout_seconds: 5.0
  model: "default"
  api_key: "${RHIZO_API_KEY}" # Supports environment variable expansion

limits:                 # Optional: Chunking and payload size safeguards
  overflow_strategy: "split_aggregate" # "split_aggregate" | "truncate"
  chunk_size: 4000
  chunk_overlap: 200
  max_chunks: 5
  defaults:
    domain: "general"
    urgency: 1

questions:              # Required: Classification questions asked of the model
  <question_id>:
    type: "choice" | "score" | "noul"
    instructions: "Question prompt for the model"
    options: ["opt1", "opt2", ...]       # For type: choice
    criteria: ["crit1", "crit2", ...]   # For type: score
    aggregate: "max_confidence" | "max" | "min" | "first"

routes:                 # Required: Ordered list of routing rules
  - name: "rule-unique-identifier"
    match:
      <condition>: <value>
    target:
      queue: "queue:target-worker-queue"
      tags: ["tag1", "tag2"]
      lease_seconds: 1800
      priority: "CRITICAL" | "HIGH" | "NORMAL" | "LOW"
```

---

## 3. Section Details

### 3.1 `service`

Configures the backend inference endpoint that scores incoming text.

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `url` | URL | `http://127.0.0.1:8100` | HTTP base URL of the System 1 inference server. |
| `timeout_seconds` | Float | `5.0` | HTTP request timeout. If exceeded, fallback defaults are used. |
| `model` | String | `default` | Name of the active model on the inference server. |
| `api_key` | String | `""` | Optional authorization token. Expands `${VAR}` environment syntax. |
| `prompt_template` | String | *Internal* | Custom prompt wrapper formatting question prompts. |

### 3.2 `limits` & Chunking Engine

Prevents payload blowup by governing how large texts (e.g. stack traces, logs, git diffs) are chunked and aggregated.

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `overflow_strategy`| Enum | `split_aggregate` | How to handle text exceeding `chunk_size`. Options: `split_aggregate` (evaluate chunks independently and aggregate) or `truncate` (score only the first chunk). |
| `chunk_size` | Int | `4000` | Maximum character length of each chunk. |
| `chunk_overlap` | Int | `200` | Character overlap between consecutive chunks. |
| `split_delimiter` | String | `\n` | Preferred boundary delimiter for chunk splits (e.g. newline or paragraph). |
| `max_chunks` | Int | `5` | Maximum number of chunks to send to the model before stopping. |
| `defaults` | Map | `{}` | Fallback dictionary populated if inference is unreachable or times out. |

### 3.3 `questions`

Defines the triage dimensions evaluated by the decision model.

#### Question Types

1. **`choice`**: Discrete categorization among a fixed list of string options.
   - `options`: List of allowable string categories.
   - `aggregate`: How to combine multi-chunk results:
     - `max_confidence`: Pick the option with highest model certainty across all chunks.
     - `first`: Use the decision from the first chunk.
2. **`score`**: Numerical rating from 1 to 10 (or across defined ordinal criteria).
   - `criteria`: List of score levels (e.g. `["low", "medium", "high", "critical"]`).
   - `aggregate`:
     - `max`: Highest score across any chunk (ideal for urgency/severity).
     - `min`: Lowest score across all chunks.
     - `mean`: Average score rounded to nearest integer.
3. **`noul`**: Freeform semantic feature extraction (entity or keyword tagger).

### 3.4 `routes` & Match Operators

Rules are evaluated sequentially in the order listed. The first rule whose `match` expression evaluates to `true` claims the task and dispatches to the `target`.

#### Supported Match Operators

| Operator | Syntax Example | Meaning |
| :--- | :--- | :--- |
| **Exact Equality** | `domain.choice: "database"` | Value of question equals literal string. |
| **Greater Than or Equal** | `urgency.score: { gte: 8 }` | Numerical score is $\ge 8$. |
| **Less Than or Equal** | `complexity.score: { lte: 3 }` | Numerical score is $\le 3$. |
| **Greater Than** | `severity.score: { gt: 5 }` | Numerical score is $> 5$. |
| **Less Than** | `risk.score: { lt: 2 }` | Numerical score is $< 2$. |
| **Set Membership** | `domain.choice: ["auth", "security"]` | Match if choice is in the given list. |
| **Negation** | `not: { domain.choice: "frontend" }` | Invert nested match condition. |
| **Logical AND** | `and: [ { ... }, { ... } ]` | All nested conditions must match. |
| **Logical OR** | `or: [ { ... }, { ... } ]` | At least one nested condition must match. |

#### Target Actions

| Action Key | Type | Description |
| :--- | :--- | :--- |
| `queue` | String | Destination Redis work queue (e.g. `queue:swarm:architect`). |
| `tags` | Array[String]| Multicast agent tags attached to the task (e.g. `["db", "migration"]`). |
| `lease_seconds` | Int | Worker claim lease window in seconds before timeout (default: 300). |
| `priority` | Enum | Priority tier: `CRITICAL` (1), `HIGH` (2), `NORMAL` (3), `LOW` (4). |

---

## 4. Full Annotated Example

```yaml
version: "1.0"

service:
  url: "http://127.0.0.1:8100"
  timeout_seconds: 5.0
  model: "decider-4b"

limits:
  overflow_strategy: "split_aggregate"
  chunk_size: 4000
  chunk_overlap: 200
  max_chunks: 5
  defaults:
    domain: "general"
    urgency: 3

questions:
  domain:
    type: choice
    instructions: "Which technical domain does this ticket or error belong to?"
    options: ["database", "frontend", "infrastructure", "security", "general"]
    aggregate: max_confidence

  urgency:
    type: score
    instructions: "Rate the operational urgency of this issue from 1 (minor cosmetic) to 10 (data loss or production outage)."
    criteria: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"]
    aggregate: max

routes:
  # Route 1: Critical Security Incident
  - name: "critical-security"
    match:
      domain.choice: "security"
      urgency.score: { gte: 8 }
    target:
      queue: "queue:swarm:secops"
      tags: ["security", "p0", "oncall"]
      lease_seconds: 600
      priority: "CRITICAL"

  # Route 2: Database Outage or Data Migration
  - name: "database-ops"
    match:
      domain.choice: "database"
      urgency.score: { gte: 5 }
    target:
      queue: "queue:swarm:dba"
      tags: ["database", "sql"]
      lease_seconds: 1800
      priority: "HIGH"

  # Route 3: Frontend Feature / Bug
  - name: "frontend-work"
    match:
      domain.choice: "frontend"
    target:
      queue: "queue:swarm:frontend"
      tags: ["ui", "css", "react"]
      lease_seconds: 3600
      priority: "NORMAL"

  # Route 4: Catch-All / Default Triage
  - name: "default-triage"
    match:
      domain.choice: "*"
    target:
      queue: "queue:swarm:general"
      tags: ["triage"]
      lease_seconds: 1800
      priority: "NORMAL"
```

---

## 5. CLI Verification Commands

```bash
# Lint the configuration syntax and schema
rhizo route lint

# Test a dry-run classification of a prompt:
rhizo route "Postgres connection pool exhausted under high query volume"

# Triage and enqueue directly to the matched queue:
rhizo enqueue --route "Memory leak detected in frontend dashboard websocket loop"
```
