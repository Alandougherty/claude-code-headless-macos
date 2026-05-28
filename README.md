# claude-code-headless-macos

Keep [Claude Code](https://claude.ai/code) signed in over SSH and mosh on macOS, without unlocking the keychain or auto-login.

## The symptom

You SSH or mosh into your Mac from another machine. You start `claude`, type a message, and get:

```
Not logged in · Please run /login
· Run in another terminal: security unlock-keychain
```

You run `/login`, it works for a few hours, then breaks again. Two to three times a day, every day.

## Solution confirmed working on

| | |
|---|---|
| macOS | 26.3.1 (Tahoe) on Apple Silicon (M4 Pro) |
| Claude Code | 2.1.126 |
| Subscription | Max (Free and Pro should work too — see [Limitations](#limitations)) |
| Soak test | 13 autonomous refreshes over 4 days, zero failures |
| Remote access | mosh from another macOS machine (also tested briefly via plain SSH) |

If you run this on a different combination and it works (or doesn't), please open an issue so this table can grow.

## The cause

Claude Code stores OAuth credentials in two places on macOS:

- `~/.claude/.credentials.json` (mode 600) — used at runtime by a live process
- A `Claude Code-credentials-<hash>` item in the login keychain — consulted at session **startup**

From an SSH or mosh session, the keychain is inaccessible: those sessions run outside the macOS Aqua security context and can't read keychain items or display the GUI unlock prompt. The credentials file is reachable, but Claude Code consults the keychain first at startup. If the file's access token has expired, the startup falls back to the keychain, can't read it, and prints _Not logged in_.

A live `claude` process refreshes the file's access token before expiry — but only when actually making API calls. An idle process does not refresh, so leaving `claude` open in tmux doesn't help. The result: any time the access token expires (every ~8 hours), the next cold mosh-in fails.

## The fix

Refresh the credentials file ourselves by calling Anthropic's OAuth endpoint directly, on a schedule, before the access token expires. Bypasses the keychain entirely.

A small bash script reads the file, decides whether the access token is close enough to expiry to be worth refreshing, POSTs to `https://console.anthropic.com/v1/oauth/token` with the file's refresh token, and writes the new tokens back atomically. A LaunchAgent runs it every 15 minutes.

Result: the file is always within ~15 minutes of fresh, so cold mosh starts never see an expired token.

## Install

Prerequisites: macOS, Claude Code installed, and `claude /login` already run at least once so `~/.claude/.credentials.json` exists.

```bash
git clone https://github.com/alandougherty/claude-code-headless-macos.git
cd claude-code-headless-macos
./install.sh
```

The installer copies the refresh script to `~/.local/bin/`, generates a LaunchAgent plist at `~/Library/LaunchAgents/dev.claudecodetools.token-refresh.plist` with your `$HOME` baked in, and loads it.

Verify:

```bash
launchctl list | grep claude-token       # status column should be 0
tail -f ~/.claude/logs/claude-token-refresh.log
```

Most fires are silent (token still fresh). Every ~7.5 hours you'll see a `Refresh OK` line.

## Uninstall

```bash
./uninstall.sh
```

Removes the LaunchAgent and the script. Leaves `~/.claude/.credentials.json` and the log file alone.

## Design notes

### Race-condition safety

OAuth refresh tokens are **single-use**. The server invalidates the old refresh token when issuing a new pair. If this tool's LaunchAgent and a live Claude Code session both refresh at the same moment, one of them gets a stale token and is logged out on its next call. This is [issue #24317](https://github.com/anthropics/claude-code/issues/24317).

We mitigate by only firing the refresh when the access token is within `REFRESH_BUFFER` seconds of expiry (default 1800 = 30 minutes). A recently-active session has already rotated the token, so its new expiry is far in the future and we sit idle. The only time we actually call the endpoint is when no live session has touched the token recently — which is exactly the scenario this tool exists to handle.

Do not remove the buffer check. Without it, every 15 minutes the script would race with whatever session is running.

### Atomic file writes

The script writes the new tokens to a temp file in the same directory, `chmod 600`s it, then `mv`s it into place. This is atomic at the filesystem level — a concurrent reader will see either the old or new file, never a partial write.

### Field preservation

The credentials file has more than just the three OAuth fields. `scopes`, `subscriptionType`, `rateLimitTier` are also read by Claude Code. The script merges the new tokens into the existing object, preserving everything else.

### Validation before write

If the refresh response is malformed (e.g. an error page rather than JSON, or missing fields), the script logs the issue and exits without touching the file. Bad responses cannot corrupt working credentials.

## Limitations

- **macOS only.** The keychain problem and LaunchAgent setup are Mac-specific. On Linux/Windows the failure mode is different; consider [RavenStorm-bit/claude-token-refresh](https://github.com/RavenStorm-bit/claude-token-refresh) instead, ideally adapted to refresh on a buffer rather than only when already expired.
- **Claude.ai OAuth only.** Works for any Claude Code account that signs in via `claude /login` (Free, Pro, or Max). The script uses Claude Code's hardcoded OAuth client_id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`, which is the same across plan tiers — only the resulting token's `subscriptionType` differs. (Soak-tested on Max; Free/Pro should work for the same reason but haven't been empirically verified — please open an issue if you're on Free or Pro and run into anything.) If you authenticate via `ANTHROPIC_API_KEY` or via Bedrock/Vertex/Foundry, you have a different auth path and don't need this tool.
- **Anthropic could change things.** The client_id, endpoint, or file schema are not part of any public API contract. If Anthropic rotates the client_id this script will start returning 401s; recovery is to `/login` once and find the new client_id from a network capture or community update.
- **First login must still happen.** This tool doesn't replace `claude /login` — you need a valid credentials file to start with. It just keeps that file fresh forever after.
- **Refresh token has its own TTL.** Anthropic's refresh-token lifetime is undocumented but appears to be at least many days. If it does expire, you'll get a 401 from the endpoint and need to `/login` once.

## Prior art

This is not the first OAuth refresher for Claude Code, but it's the first to address the macOS+SSH cold-start case specifically.

- [RavenStorm-bit/claude-token-refresh](https://github.com/RavenStorm-bit/claude-token-refresh) — cross-platform Python implementation. Refreshes when already expired (or with `--force`). No race-condition mitigation, no launchd integration.
- [cedws gist on Anthropic OAuth](https://gist.github.com/cedws/3a24b2c7569bb610e24aa90dd217d9f2) — endpoint documentation, no script.
- [Phoenix Trap: Claude Code over SSH](https://phoenixtrap.com/2025/10/26/claude-code-cli-over-ssh-on-macos-fixing-keychain-access/) — fixes a related but different failure (locked keychain, not expired token).
- Anthropic issues [#21765](https://github.com/anthropics/claude-code/issues/21765), [#24317](https://github.com/anthropics/claude-code/issues/24317), [#29816](https://github.com/anthropics/claude-code/issues/29816), [#50743](https://github.com/anthropics/claude-code/issues/50743), [#60503](https://github.com/anthropics/claude-code/issues/60503) — all closed without an official fix as of early 2026.

## License

MIT. Pick whatever — it's ~80 lines of bash.
