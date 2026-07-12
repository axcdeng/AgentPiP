# AgentPiP

A tiny, native macOS picture-in-picture monitor for Codex/ChatGPT, Claude Code, Google Antigravity, OpenCode, and Cursor agent sessions. It reads local session metadata and does not inspect normal chats.

## Run

Requires macOS 14 and Xcode 16 or newer.

```bash
swift run AgentPiP
```

For a standalone personal app bundle:

```bash
./scripts/build-app.sh
open .build/AgentPiP.app
```

The app appears in the menu bar and opens its floating panel when it detects new agent activity. Use the menu to pause monitoring, restore hidden threads, inspect diagnostics, or quit.

## Privacy and compatibility

AgentPiP watches `~/.codex`, `~/.claude`, `~/.local/share/opencode`, and the Antigravity/Cursor application-support folders using read-only filesystem and SQLite access. Claude usage is opt-in: a manually supplied Claude.ai `sessionKey` is stored in a AgentPiP-owned macOS Keychain item and sent only to Claude.ai's HTTPS organization and usage endpoints. The cookie is never logged or stored in `UserDefaults`, and AgentPiP does not access Claude Code credentials or create background Claude sessions. Provider event and database formats are implementation details, so parsers are intentionally defensive and may need updates after source-app upgrades.
