#!/usr/bin/env python3
"""
hook_utils.py - Shared utilities for Rhizo lifecycle hooks.
Resolves session mappings, locates the rhizo binary, and checks/drains inboxes.
"""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def find_rhizo_bin() -> str:
    """Locates the rhizo binary in PATH or common install directories."""
    env_bin = os.environ.get("RHIZO_BIN")
    if env_bin and os.path.exists(env_bin):
        return env_bin

    which_bin = shutil.which("rhizo")
    if which_bin:
        return which_bin

    home = Path.home()
    candidates = [
        home / ".local" / "bin" / "rhizo",
        home / ".nimble" / "bin" / "rhizo",
        Path("/opt/homebrew/bin/rhizo"),
        Path("/usr/local/bin/rhizo"),
        Path(__file__).resolve().parent.parent.parent.parent / "bin" / "rhizo",
    ]
    for c in candidates:
        if c.exists() and os.access(c, os.X_OK):
            return str(c)

    return "rhizo"


def get_sessions_file() -> Path:
    """Returns ~/.config/rhizo/sessions.json."""
    return Path.home() / ".config" / "rhizo" / "sessions.json"


def load_sessions_map() -> dict:
    p = get_sessions_file()
    if p.exists():
        try:
            with open(p, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def save_session_mapping(session_key: str, agent_name: str):
    p = get_sessions_file()
    p.parent.mkdir(parents=True, exist_ok=True)
    m = load_sessions_map()
    from datetime import datetime, timezone
    m[session_key] = {
        "agent": agent_name,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    with open(p, "w", encoding="utf-8") as f:
        json.dump(m, f, indent=2)


def remove_session_mapping(session_key: str):
    p = get_sessions_file()
    if p.exists():
        m = load_sessions_map()
        if session_key in m:
            del m[session_key]
            with open(p, "w", encoding="utf-8") as f:
                json.dump(m, f, indent=2)


def resolve_agent_name(session_id: str = "", runtime_prefix: str = "") -> str:
    """
    Resolves agent identity in order:
    1. RHIZO_AGENT_NAME / A2A_NAME env vars
    2. Local session mapping (<runtime_prefix>:<session_id>)
    3. Rhizo CLI session get
    4. Fallback default
    """
    env_name = (
        os.environ.get("RHIZO_AGENT_NAME")
        or os.environ.get("A2A_NAME")
        or os.environ.get("MY_NAME")
    )
    if env_name:
        return env_name.strip()

    bin_path = find_rhizo_bin()

    if session_id:
        key = f"{runtime_prefix}:{session_id}" if runtime_prefix and not session_id.startswith(f"{runtime_prefix}:") else session_id
        m = load_sessions_map()
        if key in m:
            entry = m[key]
            if isinstance(entry, dict) and "agent" in entry:
                return entry["agent"]
            elif isinstance(entry, str):
                return entry

        # Try query session get
        try:
            res = subprocess.run([bin_path, "session", "get", key], capture_output=True, text=True, timeout=2)
            if res.returncode == 0 and res.stdout.strip():
                return res.stdout.strip()
        except Exception:
            pass

    return ""


def check_inbox(agent_name: str) -> int:
    """Calls rhizo check-inbox and returns unread count."""
    if not agent_name:
        return 0
    bin_path = find_rhizo_bin()
    try:
        res = subprocess.run([bin_path, "check-inbox", agent_name], capture_output=True, text=True, timeout=3)
        if res.returncode == 0:
            return int(res.stdout.strip() or "0")
    except Exception:
        pass
    return 0


def drain_inbox(agent_name: str, format_type: str = "hook", count: int = 50) -> str:
    """Drains inbox using rhizo drain."""
    if not agent_name:
        return ""
    bin_path = find_rhizo_bin()
    try:
        args = [bin_path, "drain", str(count), agent_name]
        if format_type == "hook":
            args.append("--hook")
        elif format_type == "raw":
            args.append("--raw")
        else:
            args.append("--json")
        res = subprocess.run(args, capture_output=True, text=True, timeout=5)
        if res.returncode == 0:
            return res.stdout.strip()
    except Exception:
        pass
    return ""


def check_watchdog(agent_name: str, expect_listening: bool = False) -> dict:
    """Calls rhizo watchdog check and returns parsed status dict."""
    if not agent_name:
        return {}
    bin_path = find_rhizo_bin()
    try:
        args = [bin_path, "watchdog", "check", "--agent", agent_name, "--json"]
        if expect_listening:
            args.append("--expect-listening")
        res = subprocess.run(args, capture_output=True, text=True, timeout=5)
        if res.stdout.strip():
            return json.loads(res.stdout.strip())
    except Exception:
        pass
    return {}


