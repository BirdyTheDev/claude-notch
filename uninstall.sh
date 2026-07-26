#!/bin/bash
# Removes everything: the app, the hook, its settings entries, launch scripts and preferences.
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
APP="/Applications/Notchpad.app"

echo "-> quitting"
pkill -f "Notchpad.app" 2>/dev/null || true

echo "-> cleaning settings.json"
python3 - "$CLAUDE_DIR/settings.json" <<'PY'
import json, shutil, sys, time, os

path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
shutil.copy(path, f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}")

with open(path) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
for event, groups in list(hooks.items()):
    kept = []
    for group in groups:
        inner = [h for h in group.get("hooks", []) if not any(n in h.get("command", "") for n in ("notchpad-hook", "claude-notch-hook"))]
        if inner:
            group["hooks"] = inner
            kept.append(group)
    if kept:
        hooks[event] = kept
    else:
        hooks.pop(event, None)

if hooks:
    settings["hooks"] = hooks
else:
    settings.pop("hooks", None)

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
print("   hook entries removed")
PY

rm -f "$CLAUDE_DIR/hooks/notchpad-hook.py"
rm -rf "$HOME/Library/Application Support/Notchpad" "$HOME/Library/Application Support/ClaudeNotch"
defaults delete com.notchpad.app 2>/dev/null || true
defaults delete com.claudenotch.app 2>/dev/null || true
rm -rf "$APP" "/Applications/Claude Notch.app"
rm -f /tmp/notchpad.sock

echo "Removed. A settings.json backup is left at ~/.claude/settings.json.bak-*"
