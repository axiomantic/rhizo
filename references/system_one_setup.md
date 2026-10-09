# System 1 Routing & Configuration Guide

This guide details the end-to-end setup and operation of the Rhizo System 1 task classification and routing engine.

---

## 1. Overview & Architecture

Rhizo integrates **System 1 Decision Models** (fast, calibrated probabilistic classification heads like ModernBERT Laya, Kev, Decider, and TypeSafe Jev) to route incoming natural language directives into typed, leased queues with sub-50ms latency.

Rather than running an autoregressive text decoding loop that requires parsing JSON or Markdown prose, System 1 models evaluate state text against dynamic schemas (`choice`, `score`, `noul`) in a single forward pass.

```
                      +-----------------------------+
                      |   Task Text / Directive    |
                      +--------------+--------------+
                                     |
                                     v
                      +-----------------------------+
                      |  rhizo route / enqueue      |
                      +--------------+--------------+
                                     |
                         POST /v1/systemone (JSON)
                                     |
                                     v
                   +----------------------------------+
                   |     System 1 Decision Engine     |
                   | (Laya / Kev / Decider / Jev API) |
                   +-----------------+----------------+
                                     |
                     Calibrated Probabilities & Scores
                                     |
                                     v
                      +-----------------------------+
                      |  rhizo-routes.yaml Matcher  |
                      +--------------+--------------+
                                     |
                                     v
                      +-----------------------------+
                      |    Target Queue Enqueued    |
                      |  (e.g. queue:swarm:database)|
                      +-----------------------------+
```

---

## 2. Decision Engine Options

Rhizo supports both self-hosted local neural engines and cloud-hosted API endpoints. When configuring a project, choose between the two paths based on privacy, latency, and hardware availability:

### Option A: Local / Self-Hosted Open-Source Engine (Default Recommended)
- **Best for:** Offline development, zero recurring token costs, strict data privacy, and sub-40ms latency across both macOS and Linux.
- **Supported Engines & Platforms:**
  - **`local-systemone` ([axiomantic/local-systemone](https://github.com/axiomantic/local-systemone))**: Turnkey cross-platform daemon supporting Laya (ModernBERT 421M / mmBERT 322M), Ollama models, and local GGUF llama-server endpoints with built-in macOS `launchd` and Linux `systemd` daemon management.
  - **Laya (`convaiinnovations/laya`)**: ModernBERT-large (421M parameters), bidirectional encoder with typed decision heads.
    - **macOS**: Native Apple Silicon Metal acceleration (`mps`) or CPU (~1.1 GB RAM footprint).
    - **Linux**: NVIDIA CUDA acceleration (`cuda`), AMD ROCm (`rocm`), or multi-core CPU.
  - **Ollama / Local LLM**: Evaluates schemas through local Ollama (`http://127.0.0.1:11434`) via `local-systemone --engine ollama`.
  - **Local GGUF (llama-server)**: Evaluates schemas via `local-systemone --engine openai`.
- **Default Endpoint:** `http://127.0.0.1:8100`

#### Quickstart Local System 1 Daemon (`local-systemone`):
```bash
# 1. Install local-systemone directly from GitHub (Python 3.10+):
pip install "git+https://github.com/axiomantic/local-systemone.git#egg=local-systemone[full]"
# Or with uv:
# uv pip install "git+https://github.com/axiomantic/local-systemone.git#egg=local-systemone[full]"

# 2. Start in foreground:
local-systemone                     # Default: Laya ModernBERT on port 8100
# Or run with alternative engines:
# local-systemone --engine ollama   # Local Ollama bridge
# local-systemone --engine openai   # Local llama-server (GGUF)

# 3. (Optional) Run permanently as a background daemon:
# Configures macOS launchd (~/Library/LaunchAgents/com.axiomantic.local-systemone.plist)
# or Linux systemd (~/.config/systemd/user/local-systemone.service):
local-systemone --install-daemon

# On Linux, enable linger so the user systemd daemon persists without an active login session:
# loginctl enable-linger $USER
```
Verify reachability:
```bash
curl http://127.0.0.1:8100/healthz
# Returns: {"status":"ok","engine":"laya","mock":false,"loaded_models":["multilingual","typed-decisions","english"],"device":"mps"}
```

### Option B: Cloud-Hosted Endpoint (TypeSafe Jev)
- **Best for:** Teams with no local GPU/neural runtime setup or centralized enterprise routing.
- **Provider:** TypeSafe AI (Jev API)
- **Endpoint:** `https://api.typesafe.ai`
- **Authentication:** Bearer token (`LAYA_API_KEY` or `RHIZO_LAYA_API_KEY`)
- **Model:** e.g. `jev-1` or `jev-fast`

---

## 3. Configuration & Secret Layering

Rhizo uses a strict, uncommitted layering model so secrets and developer-specific endpoints are never committed to version control.

### Precedence Hierarchy:
1. **CLI Flags**: `--service-url`, `--model`, `--api-key`, `--route-timeout`
2. **Process Environment Variables**: Shell environment (`LAYA_API_KEY`, `RHIZO_LAYA_API_KEY`, `RHIZO_SERVICE_URL`)
3. **Local Uncommitted Env (`.env.local`)**: Machine-local secrets (git-ignored)
4. **Project Env Defaults (`.env`)**: Shared, non-sensitive environment settings
5. **Local Uncommitted Routes (`rhizo-routes.local.yaml`)**: Developer endpoint and rule overrides (git-ignored)
6. **Tracked Base Routes (`rhizo-routes.yaml`)**: Team canonical routing rules (committed)
7. **Builtin Defaults**: `http://127.0.0.1:8100`, 5.0s timeout

### Storing Secrets Safely:
Create `.env.local` in your workspace root (automatically git-ignored):
```bash
# .env.local
RHIZO_SERVICE_URL="https://api.typesafe.ai"
LAYA_API_KEY="laya_live_sec_abcdef123456"
RHIZO_MODEL="jev-1"
```

Or configure via `rhizo-routes.local.yaml`:
```yaml
# rhizo-routes.local.yaml (uncommitted local override)
service:
  url: "https://api.typesafe.ai"
  api_key: "jev_live_sec_abcdef123456"
  model: "jev-1"
```

---

## 4. Route Specification (`rhizo-routes.yaml`)

Canonical route definitions live in `rhizo-routes.yaml` (or `.rhizo/routes.yaml`).

### Full Schema Example:
```yaml
version: "1.0"

service:
  url: "http://127.0.0.1:8100"
  timeout_seconds: 5.0
  model: "laya-large"

limits:
  overflow_strategy: "split_aggregate" # split_aggregate | lead_tail | fail_fast
  chunk_size: 8000                     # Max characters per forward pass
  chunk_overlap: 800
  max_chunks: 10
  defaults:
    choice: "max_confidence"           # max_confidence | mean_prob | majority_vote
    score: "max"                       # max | mean | sum | min
    noul: "any"                        # any | all | mean

questions:
  domain:
    type: choice
    instructions: "Which technical domain does this task belong to?"
    options: ["database", "frontend", "api", "firmware", "devops"]
    aggregate: max_confidence

  urgency:
    type: score
    instructions: "How urgent is this directive?"
    criteria: ["low priority", "standard triage", "critical incident"]
    aggregate: max

  migration_required:
    type: noul
    instructions: "Does this change require database schema migrations or data backfills?"
    aggregate: any

routes:
  - name: "critical-production-incident"
    match:
      urgency.score: { gte: 1.5 }
    target:
      queue: "queue:swarm:incidents"
      tags: ["urgent", "pager"]
      lease_seconds: 3600

  - name: "database-specialist-route"
    match:
      domain.choice: "database"
      migration_required.noul: { gte: 0.5 }
    target:
      queue: "queue:swarm:database"
      tags: ["db", "sql", "migration"]
      lease_seconds: 2400

  - name: "firmware-worker-fallback"
    match:
      domain.choice: "firmware"
    target:
      queue: "queue:worker:worker-claude"
      tags: ["firmware", "c"]
      lease_seconds: 1800

  - name: "general-domain-routing"
    match:
      domain.choice: ["api", "frontend", "devops"]
    target:
      queue: "queue:swarm:{{ domain.choice }}"
      tags: ["{{ domain.choice }}"]
      lease_seconds: 1800
```

---

## 5. Verification & Operational Commands

### 1. Validate Syntax & Connectivity
Validate your route file and ping the underlying System 1 service:
```bash
# Offline schema and rule cross-validation:
rhizo route lint

# Live service ping and authentication verification:
rhizo route lint --check-service
```
Expected output:
```text
✓ Route configuration is valid: ./rhizo-routes.yaml (+ rhizo-routes.local.yaml)
  Questions (3): domain [choice], urgency [score], migration_required [noul]
  Routes (4): critical-production-incident, database-specialist-route, firmware-worker-fallback, general-domain-routing
  Service: http://127.0.0.1:8100 (timeout: 5.0s)
  Model: laya-large
  Limits: split_aggregate (chunk: 8000, overlap: 800, max_chunks: 10)
  ✓ System 1 service check passed
```

### 2. Dry-Run Routing Inspection
Evaluate where a directive would be dispatched without enqueuing it into Redis:
```bash
rhizo route "Deadlock on postgres users table when running migrations"
```
Sample Output:
```json
{
  "matched_rule": "database-specialist-route",
  "target": {
    "queue": "queue:swarm:database",
    "tags": ["db", "sql", "migration"],
    "lease_seconds": 2400
  },
  "answers": {
    "domain": {
      "type": "choice",
      "choice": "database",
      "confidence": 0.96
    },
    "migration_required": {
      "type": "noul",
      "noul": 0.88
    },
    "urgency": {
      "type": "score",
      "score": 0.82
    }
  },
  "aggregation": {
    "chunks_evaluated": 1,
    "strategy": "direct"
  }
}
```

### 3. Atomic Enqueue with Routing
Evaluate the task through System 1 and atomically place it onto the resolved queue in Redis:
```bash
rhizo enqueue --route "Deadlock on postgres users table when running migrations"
# Stdout returns generated message ID:
# msg_01J8ABCXYZ123456789
```

---

## 6. Troubleshooting

| Error | Root Cause | Solution |
| :--- | :--- | :--- |
| `System 1 service is unreachable at ...` | Local service is stopped or port is blocked | Start local engine (`local-systemone` / `laya-serve` / `uvicorn`) or check `curl http://127.0.0.1:8100/healthz`. |
| `HTTP 401 Unauthorized` | Missing or invalid API key | Configure `LAYA_API_KEY` in `.env.local` or `--api-key <key>`. |
| `Route configuration not found` | No `rhizo-routes.yaml` in workspace or parents | Create `rhizo-routes.yaml` or specify `--routes-file <path>`. |
| `No route rule matched classification results` | Missing default fallback route | Add a catch-all route at the bottom of `routes` with wildcard options. |
| `Input requires more chunks than configured` | Directive exceeds `chunk_size * max_chunks` | Increase `limits.max_chunks` or change `overflow_strategy: lead_tail`. |
