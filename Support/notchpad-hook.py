#!/usr/bin/env python3
"""Notchpad hook — pushes session state to the notch app over a Unix socket.

Fire-and-forget: never blocks Claude Code, never fails a turn.
"""
import json
import os
import socket
import subprocess
import sys

SOCKET_PATH = "/tmp/notchpad.sock"
TIMEOUT = 1.5

STATUS = {
    "UserPromptSubmit": "processing",
    "PreToolUse": "running_tool",
    "PostToolUse": "processing",
    "PostToolUseFailure": "processing",
    "PermissionDenied": "processing",
    "PermissionRequest": "waiting_for_approval",
    "PreCompact": "compacting",
    "PostCompact": "processing",
    "SubagentStart": "processing",
    "SubagentStop": "processing",
    "Stop": "waiting_for_input",
    "StopFailure": "waiting_for_input",
    "SessionStart": "waiting_for_input",
    "SessionEnd": "ended",
}


def get_tty():
    try:
        out = subprocess.run(["ps", "-p", str(os.getppid()), "-o", "tty="],
                             capture_output=True, text=True, timeout=1).stdout.strip()
        if out and out not in ("??", "-"):
            return out if out.startswith("/dev/") else "/dev/" + out
    except Exception:
        pass
    return None


def send(state):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())
        sock.close()
    except Exception:
        pass


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    event = data.get("hook_event_name", "")
    status = STATUS.get(event, "unknown")

    if event == "Notification":
        kind = data.get("notification_type")
        if kind == "permission_prompt":
            status = "waiting_for_approval"
        elif kind == "idle_prompt":
            status = "waiting_for_input"
        else:
            status = "notification"

    state = {
        "session_id": data.get("session_id", "unknown"),
        "cwd": data.get("cwd", ""),
        "event": event,
        "status": status,
        "pid": os.getppid(),
        "tty": get_tty(),
    }
    if data.get("tool_name"):
        state["tool"] = data["tool_name"]
        state["tool_input"] = data.get("tool_input", {})
    if data.get("message"):
        state["message"] = data["message"]

    send(state)
    # Never influence the turn: exit clean with no stdout payload.
    sys.exit(0)


if __name__ == "__main__":
    main()
