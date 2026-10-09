# Rhizo Capability Archetypes: Autonomous Listener Execution

This document maps runtime tool capabilities to their exact invocation patterns. Identify your harness's tool profile and execute the corresponding archetype.

---

## Archetype 1: Ambient In-Process Ear Plugin
- **Profile**: Harness has an active in-process listener extension (e.g. OpenCode with `opencode-ear.js`, Pi with `pi-ear.ts`).
- **Mechanism**: The plugin supervises `rhizo listen` internally as a child process and injects turns directly into the assistant's context via the harness SDK.
- **Rule**:
  <FORBIDDEN>
  Do NOT execute 'rhizo listen' with ANY tool. Continuous listening is handled automatically in-process. Calling listen causes duplicate inbox consumption and locks the bash process.
  </FORBIDDEN>
- **Tool Action**:
  Register your session once at startup using a standard shell tool:
  ```bash
  rhizo open <name> "worker,tier1"
  ```
  *(For OpenCode: ensure `opencode-ear.js` is registered in `~/.config/opencode/opencode.json` under `"plugin"`).*

---

## Archetype 2: Main-Chat Background Daemon Process
- **Profile**: The harness provides a shell command tool with a native background/daemon parameter (e.g. Antigravity `run_command(IsDaemon=true, WaitMsBeforeAsync=500)`).
- **Mechanism**: Runs the infinite listener in the background of the primary conversation turn. Standard output from the listener reactively resumes the assistant's turn when a message arrives.
- **Rule**:
  <INVARIANT>
  Prefer Archetype 2 in native daemon harnesses (e.g. Antigravity). It maintains direct, immediate execution in the primary session with 0 overhead.
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

## Archetype 3: Autonomous Turn-End Continuation Hooks
- **Profile**: Harness supports lifecycle event hooks invoked at the end of each assistant turn (e.g. Claude Code Stop Hook, OpenAI Codex Stop Hook).
- **Mechanism**: Harness automatically runs a native hook (`claude_stop_hook.py`, `codex_stop_hook.py`, or `rhizo hook codex-stop`) whenever the turn ends. If a message or pending work item exists in the inbox, the hook returns `{"decision": "block", "reason": ...}` to immediately trigger a continuation turn, seamlessly resuming execution without human intervention.
- **Rule**:
  <INVARIANT>
  Subagents are tools for sessions to run ad-hoc tasks, NEVER cluster swarm workers or listener relays. Cluster swarm workers operate as sovereign sessions coordinated via Rhizo, utilizing autonomous turn-end hooks or native listeners.
  </INVARIANT>
  <INVARIANT>
  Zero Token Waste: Autonomous turn-end hooks operate outside the LLM context window with 0 prompt token overhead, eliminating subagent initialization costs.
  </INVARIANT>
- **Tool Action**:
  Install the appropriate hook once during session setup:
  ```bash
  rhizo hook install --claude   # For Claude Code
  rhizo hook install --codex    # For OpenAI Codex
  ```
  *(Or execute single-shot `rhizo listen <name>` in dedicated worker terminals).*

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
