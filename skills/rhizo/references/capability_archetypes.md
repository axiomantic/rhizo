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
  Prefer Archetype 2 over subagents. It consumes 0 subagent inference tokens and provides an immediate line of interruption into the main chat.
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

## Archetype 3: One-and-Done Background Subagent Ear
- **Profile**: Shell tools cannot run in the background, but the harness provides a subagent or task tool with a background parameter (e.g. Claude Code `Task(background=true)`, OpenAI Codex `spawn_agent`).
- **Mechanism**: Spawns an isolated background subagent container. Inside the subagent, the command executes as a blocking foreground process. When a message arrives, `rhizo listen` prints the payload and exits 0, which terminates the subagent and delivers the notification back to the parent session.
- **Rule**:
  <CRITICAL>
  NO DOUBLE-DAEMONS: Inside the subagent, 'rhizo listen' must be SYNCHRONOUS AND BLOCKING. Do not run with '&' or as a daemon inside the subagent. Subagents only notify parent chats upon exit.
  </CRITICAL>
  <FORBIDDEN>
  NEVER WRAP IN A WHILE LOOP: Never run 'while true; do rhizo listen <name>; done' or 'until rhizo listen'. Coding harnesses and task tools ONLY notify the parent agent when the subagent or command finishes. Wrapping in a shell loop traps execution indefinitely, preventing the tool from ever returning its output to the parent orchestrator. The listener MUST be single-shot: execute once, exit on delivery, return output to parent. Re-arming must be initiated as a separate turn or subsequent task.
  </FORBIDDEN>
- **Tool Action**:
  ```json
  Task({
    "prompt": "Execute 'rhizo listen <name> --quiet'. Block until a message arrives, output the complete JSON payload, and terminate immediately.",
    "background": true
  })
  ```

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
