# Rhizo Capability Archetypes: Autonomous Listener Execution

This document maps runtime tool capabilities to their exact invocation patterns. Identify your harness's tool profile and execute the corresponding archetype.

---

## Archetype 1: Multiplexed Router & Ambient In-Process Ear Plugin (Tier 1)
- **Profile**: Harness has an active in-process listener extension or router integration (e.g. OpenCode with `opencode-ear.js`, Pi with `pi-ear.ts`, Antigravity with host-wide Multiplexed Router `rhizo router` / `rhizo ear --all`).
- **Mechanism**: A single host-wide or harness-wide multiplexed router process (`rhizo router`) manages Redis subscriptions and message dispatch across all local sessions. For OpenCode/Pi, the extension runs a single `rhizo router --stdout` process and dispatches JSON envelopes to matching session IDs. For Antigravity, the router delivers directly via language server `agentapi send-message`.
- **Rule**:
  <INVARIANT>
  Tier 1 sessions register automatically via 'rhizo session register <name> --session <id> --harness <name>' or 'rhizo open <name>'. When 'rhizo listen' is invoked in a registered Tier 1 session with an active router, it returns immediately with 'status: router_active' (non-blocking fast path). You do NOT need N blocking listener processes per tab.
  </INVARIANT>
- **Tool Action**:
  Register your session once at startup using a standard shell tool:
  ```bash
  rhizo open <name> "worker,tier1"
  ```
  *(For OpenCode: ensure `opencode-ear.js` is registered in `~/.config/opencode/opencode.json` under `"plugin"`; for Antigravity: `rhizo ear --all` or `rhizo router start --daemon`).*

---

## Archetype 2: Main-Chat Background Daemon Process
- **Profile**: The harness provides a shell command tool with a native background/daemon parameter (e.g. Antigravity `run_command(IsDaemon=true, WaitMsBeforeAsync=500)`).
- **Mechanism**: Runs the listener as a managed daemon process when the host-wide multiplexed router is not running. Standard output from the listener reactively resumes the assistant's turn when a message arrives.
- **Rule**:
  <INVARIANT>
  Prefer Archetype 1 (Multiplexed Router) across Tier 1 harnesses. Use Archetype 2 as a standalone single-session daemon when operating outside the multiplexed router service.
  </INVARIANT>
- **Tool Action**:
  ```json
  run_command({
    "CommandLine": "rhizo listen <name> --quiet",
    "IsDaemon": true,
    "WaitMsBeforeAsync": 500
  })
  ```

---

## Archetype 3A: Autonomous Turn-End Continuation Hooks (Claude Code)
- **Profile**: Harness supports lifecycle event hooks invoked at the end of each assistant turn (e.g. Claude Code Stop Hook).
- **Mechanism**: Harness automatically runs a native hook (`claude_stop_hook.py` or `rhizo hook install --claude`) whenever an active turn ends. If a message or pending work item exists in the inbox, the hook returns `{"decision": "block", "reason": ...}` to immediately trigger a continuation turn, seamlessly resuming execution without human intervention.
- **Rule**:
  <INVARIANT>
  Subagents are tools for sessions to run ad-hoc tasks, NEVER cluster swarm workers or listener relays. Cluster swarm workers operate as sovereign sessions coordinated via Rhizo, utilizing autonomous turn-end hooks or native listeners.
  </INVARIANT>
- **Tool Action**:
  ```bash
  rhizo hook install --claude   # For Claude Code
  ```

---

## Archetype 3B: Codex-Native Wakeup Protocol (`RHIZO_WAKE`)
- **Profile**: OpenAI Codex Desktop / CLI.
- **Mechanism**: On Codex Desktop, background or supervised `rhizo listen` subprocesses exit with code 0 upon message receipt, but **subprocess completion does not resume an idle chat turn**. Stop hooks also only evaluate during active turn endings and cannot listen while idle. Codex natively provides `send_message_to_thread(thread_id, message="RHIZO_WAKE")` to resume idle threads.
- **Rule**:
  <INVARIANT>
  Sender sends task via Rhizo, resolves recipient Codex thread ID, and sends exact 'RHIZO_WAKE' via native tool. Recipient retrieves completed listener output first, drains remaining inbox, processes tasks, acknowledges without duplicate action, and rearms one supervised foreground single-shot listener.
  </INVARIANT>
- **Sender Action**:
  ```bash
  rhizo send <agent> "<subject>" "<body>"
  # From structured output or 'rhizo session get <agent> --thread-id', call native tool:
  # send_message_to_thread(thread_id="<thread_id>", message="RHIZO_WAKE")
  ```
- **Recipient Action**:
  See complete protocol in [references/codex_wakeup_protocol.md](codex_wakeup_protocol.md).

---

## Archetype 4: Explicit Inbox Poller (Fallback)
- **Profile**: Harness provides only synchronous foreground shell execution with no backgrounding or subagent capabilities.
- **Mechanism**: Assistant cannot maintain an active listener without freezing the conversation turn and locking human input.
- **Rule**:
  <FORBIDDEN>
  DO NOT run 'rhizo listen'. A blocking call will permanently freeze the chat turn.
  </FORBIDDEN>
- **Tool Action**:
  Inform the operator of the platform limitation. Check for messages explicitly at the start or end of user turns:
  ```bash
  rhizo check-inbox <name>
  ```
