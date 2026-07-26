#!/bin/bash
# Installs the hook, points ~/.claude/settings.json at it and launches the app.
# The existing settings file is backed up first.
set -euo pipefail

cd "$(dirname "$0")"
CLAUDE_DIR="$HOME/.claude"
HOOK="$CLAUDE_DIR/hooks/notchpad-hook.py"

echo "-> installing hook"
mkdir -p "$CLAUDE_DIR/hooks"
cp Support/notchpad-hook.py "$HOOK"
chmod +x "$HOOK"

echo "-> wiring up settings.json"
python3 - "$CLAUDE_DIR/settings.json" "$HOOK" <<'PY'
import json, shutil, sys, time, os

path, hook = sys.argv[1], sys.argv[2]
shutil.copy(path, f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}")

with open(path) as f:
    settings = json.load(f)

EVENTS = {
    "SessionStart": ["*"], "SessionEnd": ["*"], "UserPromptSubmit": ["*"],
    "PreToolUse": ["*"], "PostToolUse": ["*"], "PostToolUseFailure": ["*"],
    "PermissionRequest": ["*"], "PermissionDenied": ["*"], "Notification": ["*"],
    "Stop": ["*"], "StopFailure": ["*"], "SubagentStart": ["*"], "SubagentStop": ["*"],
    "PreCompact": ["auto", "manual"], "PostCompact": ["auto", "manual"],
}

hooks = settings.get("hooks", {})
command = f"python3 '{hook}'"

# Drop entries from other notch apps and any stale copy of our own hook.
for event, groups in list(hooks.items()):
    kept = []
    for group in groups:
        stale = ("claude-island", "claude-notch-hook", "notchpad-hook")
        inner = [h for h in group.get("hooks", [])
                 if not any(name in h.get("command", "") for name in stale)]
        if inner:
            group["hooks"] = inner
            kept.append(group)
    if kept:
        hooks[event] = kept
    else:
        hooks.pop(event, None)

for event, matchers in EVENTS.items():
    groups = hooks.setdefault(event, [])
    for matcher in matchers:
        group = next((g for g in groups if g.get("matcher") == matcher), None)
        entry = {"type": "command", "command": command}
        if event == "PermissionRequest":
            entry["timeout"] = 10
        if group is None:
            groups.append({"matcher": matcher, "hooks": [entry]})
        else:
            group.setdefault("hooks", []).append(entry)

settings["hooks"] = hooks
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
print("   hooks:", ", ".join(sorted(EVENTS)))
PY

if pgrep -qf "Vibe Notch"; then
    echo "-> quitting the old notch app"
    osascript -e 'tell application "Vibe Notch" to quit' 2>/dev/null || pkill -f "Vibe Notch" || true
fi

echo "-> launching"
pkill -f "Notchpad.app" 2>/dev/null || true
sleep 0.4
open -a "/Applications/Notchpad.app"

echo "Done. Look for the sparkle in the menu bar."
echo "  Settings: menu bar sparkle -> Settings"
echo "  If another notch app starts at login, remove it in System Settings > General > Login Items"
