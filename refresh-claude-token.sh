#!/usr/bin/env bash
# Refresh the Claude Code OAuth access token by calling Anthropic's refresh
# endpoint directly, bypassing the macOS Keychain entirely.
#
# Why: on macOS, Claude Code reaches for the Keychain at session startup.
# From an SSH/mosh session the Keychain is inaccessible (no GUI security
# context), so a cold-start mosh session with an expired access token in
# ~/.claude/.credentials.json prints "Not logged in". This script keeps the
# file's access token fresh so cold starts always find a valid token.
#
# Race-condition safety: refresh tokens are single-use. If a live claude
# session refreshes concurrently with this script, one of them gets a stale
# token and is logged out. We mitigate by only refreshing when the access
# token is within REFRESH_BUFFER seconds of expiry — a recently-active session
# will already have rotated, leaving us idle.

set -uo pipefail

CREDS="$HOME/.claude/.credentials.json"
REFRESH_BUFFER=${REFRESH_BUFFER:-1800}   # refresh if < 30 min to expiry
CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
ENDPOINT="https://console.anthropic.com/v1/oauth/token"
LOG_PREFIX="[refresh-claude-token $(date '+%Y-%m-%d %H:%M:%S')]"

log() { echo "$LOG_PREFIX $*"; }
err() { echo "$LOG_PREFIX $*" >&2; }

if [[ ! -f "$CREDS" ]]; then
  err "No credentials file at $CREDS — nothing to refresh. Run /login first."
  exit 1
fi

PLAN=$(/usr/bin/python3 - "$CREDS" "$REFRESH_BUFFER" <<'PY'
import json, sys, time
path, buf = sys.argv[1], int(sys.argv[2])
with open(path) as f:
    obj = json.load(f)
o = obj["claudeAiOauth"]
remaining = (o["expiresAt"] - int(time.time() * 1000)) / 1000
if remaining > buf:
    print(f"skip {remaining:.0f}")
else:
    print(f"refresh {remaining:.0f} {o['refreshToken']}")
PY
) || { err "Failed to parse $CREDS"; exit 1; }

read -r ACTION REMAINING TOKEN <<<"$PLAN"

if [[ "$ACTION" == "skip" ]]; then
  exit 0
fi
if [[ "$ACTION" != "refresh" || -z "${TOKEN:-}" ]]; then
  err "Unexpected planner output: $PLAN"
  exit 1
fi

log "Access token expires in ${REMAINING}s (buffer ${REFRESH_BUFFER}s). Refreshing."

REQ_BODY=$(/usr/bin/python3 -c '
import json, sys
print(json.dumps({
    "grant_type": "refresh_token",
    "refresh_token": sys.argv[1],
    "client_id": sys.argv[2],
}))
' "$TOKEN" "$CLIENT_ID")

RESP=$(curl -sS --fail-with-body -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "User-Agent: claude-cli/2.1.126" \
  -d "$REQ_BODY" 2>&1) || {
  err "Refresh request failed:"
  err "$RESP"
  exit 2
}

TMP=$(mktemp "${CREDS}.XXXXXX")
trap 'rm -f "$TMP"' EXIT

if ! RESP="$RESP" CREDS_PATH="$CREDS" TMP_PATH="$TMP" /usr/bin/python3 <<'PY'
import json, os, sys, time
try:
    resp = json.loads(os.environ["RESP"])
except json.JSONDecodeError as e:
    sys.stderr.write(f"refresh response not JSON: {e}\nbody: {os.environ['RESP'][:500]}\n")
    sys.exit(1)
for key in ("access_token", "refresh_token", "expires_in"):
    if key not in resp:
        sys.stderr.write(f"refresh response missing {key}; got keys: {list(resp)}\n")
        sys.exit(1)
with open(os.environ["CREDS_PATH"]) as f:
    obj = json.load(f)
o = obj["claudeAiOauth"]
o["accessToken"] = resp["access_token"]
o["refreshToken"] = resp["refresh_token"]
o["expiresAt"] = int(time.time() * 1000) + int(resp["expires_in"]) * 1000
with open(os.environ["TMP_PATH"], "w") as f:
    json.dump(obj, f, separators=(",", ":"))
PY
then
  err "Failed to apply refresh response to $CREDS"
  exit 3
fi

chmod 600 "$TMP"
mv "$TMP" "$CREDS"
trap - EXIT

NEW_EXP=$(/usr/bin/python3 -c "import json,time; e=json.load(open('$CREDS'))['claudeAiOauth']['expiresAt']; print(f'{e}  ({time.strftime(\"%Y-%m-%d %H:%M:%S\", time.localtime(e/1000))})')")
log "Refresh OK. New expiresAt=$NEW_EXP"
