#!/usr/bin/env bash
# Uninstall the Claude Code OAuth token refresher.
#
# Leaves ~/.claude/.credentials.json and ~/.claude/logs/* untouched.

set -euo pipefail

LABEL="dev.claudecodetools.token-refresh"
SCRIPT_DST="$HOME/.local/bin/refresh-claude-token.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ -f "$PLIST" ]]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm "$PLIST"
  echo "removed: $PLIST"
else
  echo "not present: $PLIST"
fi

if [[ -f "$SCRIPT_DST" ]]; then
  rm "$SCRIPT_DST"
  echo "removed: $SCRIPT_DST"
else
  echo "not present: $SCRIPT_DST"
fi

echo
echo "Credentials file and logs left in place. Remove manually if desired:"
echo "  ~/.claude/.credentials.json"
echo "  ~/.claude/logs/claude-token-refresh.log"
