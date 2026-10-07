# Rhizo Configuration & Environment Variables Reference

Rhizo provides a multi-tiered configuration system spanning command-line flags, process environment variables, workspace `.rhizo.toml` files, `.env` files, and global user settings.

---

## 1. Configuration Resolution Precedence

When Rhizo resolves a setting (e.g. Redis URL, project namespace, or encryption keys), it evaluates sources in the following strict order (highest precedence wins):

```
1. CLI Arguments & Flags           (--redis-url, --project, --from, etc.)
2. Process Environment Variables   (RHIZO_REDIS_URL, RHIZO_PROJECT, etc.)
3. Local Dotenv Overrides          (.env.local in current directory)
4. Standard Dotenv File            (.env in current directory)
5. Local Workspace Config          (.rhizo.local.toml in project root)
6. Workspace Config                (.rhizo.toml or rhizo.toml in project root)
7. Global Profile Config           (~/.config/rhizo/config.toml [profiles.<name>])
8. Global Default Config           (~/.config/rhizo/config.toml [default])
9. Builtin Fallbacks               (redis://127.0.0.1:6379, rhizo:, etc.)
```

To inspect the effective configuration and source provenance at any time, run:
```bash
rhizo config show
# Or as structured JSON:
rhizo config show --format json
```

---

## 2. Environment Variables Reference

All Rhizo-controlled environment variables use the canonical `RHIZO_` prefix. For backward compatibility with legacy tooling, fallback aliases are inspected if the canonical variable is unset.

### Core Transport & Connection

| Variable | Fallback Alias | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `RHIZO_REDIS_URL` | `RHIZO_VALKEY_URL`, `A2A_REDIS_URL`, `REDIS_URL` | URL | `redis://127.0.0.1:6379` | Connection URI for Redis or Valkey broker (`redis://`, `rediss://`, `valkey://`, `valkeys://`, or Unix socket `unix:///path.sock`). |
| `RHIZO_PREFIX` | `RHIZO_REDIS_PREFIX`, `A2A_REDIS_PREFIX` | String | `rhizo:` | Key namespace prefix applied to all Redis keys, channels, and queues. |
| `RHIZO_PROJECT` | `A2A_PROJECT` | String | *Directory basename* | Project namespace for task queues, locks, and channel grouping. |
| `RHIZO_CLUSTER` | — | Boolean | `false` | Enable Redis Cluster support (sharded key slots). |
| `RHIZO_CONFIG` | — | Path | `~/.config/rhizo/config.toml` | Custom path to global or project TOML configuration file. |
| `RHIZO_PROFILE` | — | String | `default` | Target configuration profile section inside TOML config. |
| `RHIZO_QUIET` | — | Boolean | `0` | When set to `1`, `true`, or `yes`, suppresses non-essential stderr banners and lifecycle notices. |
| `RHIZO_HOSTNAME` | `HOSTNAME`, `COMPUTERNAME` | String | *OS Hostname* | Override host machine identifier reported in heartbeat telemetry and packet origin headers. |
| `RHIZO_OPENSSL_BIN`| `OPENSSL_BIN` | Path | *Auto-detected* | Explicit path to OpenSSL binary executable for CLI operations. |

### Agent Identity & Session Binding

| Variable | Fallback Alias | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `RHIZO_AGENT_NAME` | `A2A_NAME`, `MY_NAME` | String | `rhizo-worker` | The canonical agent codename for the active session (e.g. `rhizo-sequoia`). Case-insensitive. |
| `RHIZO_SESSION_ID` | — | String | *Auto-detected* | Coding harness session identifier. Automatically detected from `CLAUDE_PROJECT_ROOT`, `OPENCODE_SESSION_ID`, `PI_SESSION_ID`, `CODEX_SESSION_ID`, or `ANTIGRAVITY_APP_DIR`. |

### Cryptography & Security

| Variable | Fallback Alias | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `RHIZO_SECRET` | — | Hex/Str | *None* | 32-byte shared secret key used for HMAC-SHA256 wire authentication and AES-256-GCM message encryption. |
| `RHIZO_SECRET_FILE`| — | Path | `~/.config/rhizo/secret` | Path to file containing the 32-byte shared secret. Auto-generated on first launch if absent. |
| `RHIZO_ENCRYPT` | — | Boolean | `false` | When set to `1` or `true`, enables end-to-end payload encryption for all outgoing messages. |

### System 1 Semantic Routing (Laya / Decider / Jev)

| Variable | Fallback Alias | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `RHIZO_ROUTES_FILE` | — | Path | `rhizo-routes.yaml` | Explicit path to the active routing rules YAML manifest. |
| `RHIZO_ROUTES_LOCAL_FILE` | `SYSTEMONE_ROUTES_LOCAL_FILE` | Path | `.rhizo-routes.local.yaml`| Local developer route override overlay. |
| `RHIZO_GLOBAL_ROUTES_FILE`| `SYSTEMONE_GLOBAL_ROUTES_FILE`| Path | `~/.config/rhizo/rhizo-routes.yaml`| Machine-wide fallback route configuration. |
| `RHIZO_SERVICE_URL`| `SYSTEMONE_URL`, `LAYA_URL` | URL | `http://127.0.0.1:8100` | HTTP endpoint for the local or remote System 1 inference service. |
| `RHIZO_API_KEY` | `SYSTEMONE_API_KEY`, `JEV_API_KEY` | String | *None* | Optional bearer token or API key for System 1 endpoint authentication. |
| `RHIZO_MODEL` | `SYSTEMONE_MODEL`, `LAYA_MODEL` | String | `default` | Name of the fast triage model running on the System 1 inference backend. |
| `RHIZO_ROUTE_TIMEOUT` | `SYSTEMONE_TIMEOUT` | Seconds | `5.0` | HTTP connection and response timeout for semantic routing evaluation. |

### Harness Extensions & Lifecycle Hooks

| Variable | Fallback Alias | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `RHIZO_BIN` | — | Path | *Auto-detected* | Explicit path to `rhizo` executable for subprocess invocations from extension hooks. |
| `RHIZO_EAR_DISABLED` | — | Boolean | `0` | When set to `1`, disables background listener hooks in OpenCode, Pi, and Claude Code harnesses. |
| `RHIZO_INTERRUPT` | — | Boolean | `1` | Controls whether incoming high-priority messages can abort a busy worker session (`1` = abort/interrupt allowed, `0` = queue without interrupting). |
| `RHIZO_ABORT_ON_BUSY` | — | Boolean | `0` | When set to `1`, forces session abort when messages arrive while an LLM turn is actively generating. |

---

## 3. TOML Configuration Files (`rhizo.toml`)

Rhizo supports configuration files at both the project root (`.rhizo.toml` or `rhizo.toml`) and the global user directory (`~/.config/rhizo/config.toml`).

### Structure and Profile Support

```toml
# .rhizo.toml - Project Configuration
redis_url = "redis://127.0.0.1:6379"
prefix = "myproject:"
project = "locutus"
encrypt = false
heartbeat_ttl = 150
listen_timeout = 0
message_ttl = 604800

# Optional profile environments
[profiles.staging]
redis_url = "rediss://staging.mesh.internal:6380"
prefix = "stg:myproject:"
encrypt = true

[profiles.production]
redis_url = "rediss://prod.mesh.internal:6380"
prefix = "prod:myproject:"
encrypt = true
```

### Switching Profiles

You can select a profile via flag or environment variable:
```bash
# Using CLI flag:
rhizo --profile staging who

# Using environment variable:
export RHIZO_PROFILE=staging
rhizo who
```

---

## 4. Local Layering (`.rhizo.local.toml`)

For developer-specific settings that should never be committed to git, create `.rhizo.local.toml` alongside `.rhizo.toml`. Rhizo automatically loads `.rhizo.local.toml` on top of `.rhizo.toml`, allowing local overrides (e.g. custom Redis ports or debug prefixes) while keeping shared project configuration pristine.
