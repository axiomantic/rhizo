#!/usr/bin/env python3
"""
codex_stop_hook.py - OpenAI Codex `Stop` Lifecycle Hook for Rhizo.

Runs at the end of a Codex response turn.
If messages are waiting in the Rhizo inbox:
  - Drains them atomically
  - Returns `{"decision": "block", "reason": "<messages_text>"}`
  - In Codex, `decision: "block"` on `Stop` creates a continuation prompt
    that acts as a new user prompt, feeding the message directly to the model.
If inbox is empty:
  - Exits with `{}` allowing Codex to stop normally.
"""

import json
import sys
from pathlib import Path

# Add hooks directory to path for hook_utils
sys.path.insert(0, str(Path(__file__).resolve().parent))
from hook_utils import resolve_agent_name, check_inbox, drain_inbox, check_watchdog


def main():
    try:
        raw_input = sys.stdin.read()
        payload = json.loads(raw_input) if raw_input.strip() else {}
    except Exception:
        payload = {}

    session_id = payload.get("session_id", "")
    agent_name = resolve_agent_name(session_id, runtime_prefix="codex")

    if not agent_name:
        # Agent not registered on Rhizo bus; pass through silently
        print("{}")
        return

    # Check unread count
    count = check_inbox(agent_name)
    if count > 0:
        messages_text = drain_inbox(agent_name, format_type="hook")
        if messages_text:
            output = {
                "decision": "block",
                "reason": messages_text
            }
            print(json.dumps(output))
            return

    # Check watchdog status: tasks in-flight with no active listener
    watchdog = check_watchdog(agent_name)
    if watchdog.get("status") == "ACTION_REQUIRED" and watchdog.get("substatus") == "REARM_LISTENER":
        cmd = watchdog.get("recommended_command") or f"rhizo listen {agent_name}"
        tasks_count = watchdog.get("tasks_in_flight", 0)
        output = {
            "decision": "block",
            "reason": f"[RHIZO WATCHDOG WARNING] {tasks_count} task(s) are currently in-flight on the Rhizo bus, but no active listener was detected for @{agent_name}. Run '{cmd}' before ending your turn."
        }
        print(json.dumps(output))
        return

    print("{}")


if __name__ == "__main__":
    main()
