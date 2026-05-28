#!/usr/bin/env bash
# Install the Claude Code OAuth token refresher as a LaunchAgent.
#
# Idempotent: safe to re-run. If a previous install is loaded, it will be
# unloaded and replaced.

set -euo pipefail

LABEL="dev.claudecodetools.token-refresh"
SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/refresh-claude-token.sh"
SCRIPT_DST="$HOME/.local/bin/refresh-claude-token.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/.claude/logs/claude-token-refresh.log"
INTERVAL=900

err() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || err "this installer is macOS only."
[[ -f "$SCRIPT_SRC" ]] || err "refresh-claude-token.sh not found alongside this installer."
[[ -f "$HOME/.claude/.credentials.json" ]] || err "no ~/.claude/.credentials.json — run 'claude /login' first."

mkdir -p "$(dirname "$SCRIPT_DST")" "$(dirname "$PLIST")" "$(dirname "$LOG")"

# Stage script
install -m 0755 "$SCRIPT_SRC" "$SCRIPT_DST"
echo "installed: $SCRIPT_DST"

# Unload existing agent (if any) before rewriting plist
if launchctl list | grep -q "^[^[:space:]]*[[:space:]][^[:space:]]*[[:space:]]$LABEL$"; then
  launchctl unload "$PLIST" 2>/dev/null || true
fi

# Generate plist with this machine's $HOME baked in
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTD/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$SCRIPT_DST</string>
    </array>

    <key>StartInterval</key>
    <integer>$INTERVAL</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>$LOG</string>

    <key>StandardErrorPath</key>
    <string>$LOG</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin</string>
    </dict>
</dict>
</plist>
PLIST
chmod 0644 "$PLIST"
echo "installed: $PLIST"

launchctl load "$PLIST"
sleep 1

if launchctl list | grep -q "[[:space:]]$LABEL$"; then
  echo "loaded: $LABEL"
else
  err "load failed — check $LOG"
fi

echo
echo "Done. The agent will run every $((INTERVAL / 60)) minutes."
echo "Verify with: tail -f $LOG"
echo "Uninstall with: ./uninstall.sh"
