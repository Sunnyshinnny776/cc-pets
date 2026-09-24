# Changelog

English | [简体中文](./CHANGELOG.zh-CN.md)

This project follows Semantic Versioning. `package.json` is the single source of
truth for the version.

## [Unreleased]

### CC Bridge (experimental, off by default)

- Added `cc-pets bridge enable|disable|status`, which lets Claude Code and Codex terminal sessions on the same Mac discover each other, exchange messages, and wake each other, including Claude ↔ Codex and Codex ↔ Codex. See [CC_BRIDGE.md](./CC_BRIDGE.md).
- Uses documented extension points only: an MCP server (`list_agents` / `send_message` / `check_inbox`) for sending, `codex queue` for delivery to Codex, and an `asyncRewake` hook for delivery to Claude Code.
- Checks that the recipient is online before delivery so Codex never runs stale messages on resume; 16 KB message limit, 24-hour expiry, and a 20-messages-per-10-minutes pair limit to break auto-reply loops.
- `cc-pets uninstall` removes CC Bridge integrations; reinstalls and upgrades refresh them with the saved options.
- File reservations: `reserve_files` / `release_files` / `list_reservations`, where the first edit to a file someone else reserved is paused once by a PreToolUse hook with the reason, and a retry goes through; reservations expire and are released when the session ends.
- Pet integration: a message badge on the status icon (blue for new deliveries, orange for inbox backlog), recent cross-session messages in the session menu, and click-to-jump to the recipient's terminal; names and times only, never bodies.
- Options and pet switches: `cc-pets bridge configure` and `enable` accept `--approve` / `--codex-approve` / `--claude-allow` (skip approval in Codex and Claude by tool group), `--wake`, and `--edit-guard`, keeping anything not given; the pet's right-click menu gains a CC Bridge section (enable, four approval groups, auto-wake, edit guard, message badge, new-message notifications).
- Custom session names via `CC_BRIDGE_NAME` at launch, or `set_name` / `cc-pets bridge name` in a session; `list_agents` shows each session's terminal (tty).

## [2.0.3] - 2026-09-17

Terminal jump-back and session-liveness fixes for agents started outside the wrapper scripts.

### Agent status

- Fall back to the kernel when `CC_PETS_TERMINAL_*` is missing: read the controlling terminal through `sysctl(KERN_PROC_PID)` and resolve the host terminal application by walking up the parent process chain, so `claude` / `codex` launched directly can still be jumped back to.
- Fix sessions without a pid file being declared dead immediately: liveness now prefers the pid file, and falls back to the activity grace window for providers that never wrote one.

## [2.0.2] - 2026-09-11

Multi-session agent list, plus session-liveness and Codex usage-trend fixes.

### Agent status

- Every hook status card is clickable and returns to the terminal that triggered the event; Terminal.app and iTerm2 are selected precisely by TTY, other terminals fall back to activating the owning application.
- The circular status icon lists up to eight recent online agent terminal sessions, badges the number of sessions waiting for approval, and pins those sessions to the top of the list.
- Notify once and pull the card back to the front when an agent sits in approval for 2 minutes or in thinking for 5 minutes; the session re-arms after its next event.
- The card no longer clears after 60 idle seconds while an approval is outstanding.
- Fix stale online sessions: a session is online only when its controlling terminal still matches the TTY recorded in the pid file, so orphaned Node processes no longer keep a closed window listed.

### Quota and usage

- Fix the usage-trend column being overridden by the pending refresh state while a 7-day percentage is available, and give the rate-limited footnote its own color.
- Keep official window percentages in quota history while rate limited, so a long-limited provider still has samples to draw a trend curve from.

## [2.0.1] - 2026-09-07

Bug fixes for quota display and panel stability.

### Quota and usage

- Read live Codex quota windows from the Codex App Server and overlay them on locally aggregated token usage, with a persistent background connection that handles refresh, notifications, timeouts, and fallback.
- Fix Codex quota not showing again after a quota reset: expired session quota windows are now discarded independently, and exhaustion state is preserved correctly across resets.
- Show a pending refresh state when official quota data is not yet available.

### Pet and interaction

- Fix the panel occasionally failing to show.
- Unify pet speech to first person: the pet now speaks as the agent instead of narrating it from the outside.

## [2.0.0] - 2026-08-23

First open-source release.

### Pet and interaction

- Native macOS AppKit desktop pet with no Electron runtime and no dependency on the Codex or Claude desktop apps.
- Idle breathing, random movements, drag lag and landing bounce, plus hover and click feedback for the head, pocket, feet, and both body sides.
- The right-click menu can switch pets, refresh usage, toggle quota history and system notifications, check for updates, or exit.
- Supports built-in assets and external assets under `~/.cc-pets/pets/`, with `spriteVersionNumber` v1 and v2 grids.

### Quota and usage

- Reads five-hour quota, weekly quota, and reset times from local `~/.codex/sessions` data and Claude Code's official status line input.
- Hovering over the pocket opens a panel with separate Codex and Claude cards for remaining percentage, local tokens, and seven-day trends.
- Optionally records seven days of local quota history; disabled by default and stored only on the local machine.
- Supports Subscription quota and API usage display modes.

### Agent status

- Codex Hooks and Claude Code Hooks drive animations for thinking, tool calls, approvals, subagents, completion, and failure.
- Displays a redacted glass status card beside the pet, which can be collapsed and shows the active CLI session count.
- macOS notifications can be enabled separately for completion, failure, and approval requests.
- Third-party CLI agents can integrate through the unified Provider event protocol; see [`PROVIDER_PROTOCOL.md`](./PROVIDER_PROTOCOL.md).

### Speech

- All pet speech comes from `~/.cc-pets/speech.txt`, can be edited in the built-in editor, and supports live data placeholders.
- Per-pet speech can be stored at `~/.cc-pets/speech/<pet-name>.txt` and replaces global speech by section.
- Includes four speech-frequency levels and stays silent while an agent is working.

### Installation and integration

- `npm install -g cc-pets` builds the native app, installs both hook integrations and shell integration, and installs `~/Applications/CC Pets.app`.
- Symlinks under `~/.cc-pets/shims` intercept `codex` and `claude`, including casing variants, to start the pet.
- `cc-pets install`, `uninstall`, and `uninstall-app` provide repeatable initialization and cleanup flows.

### Privacy

- Uploads no conversations, quotas, credentials, or usage statistics and contains no telemetry.
- Status cards and notifications show only the provider, state category, and redacted tool category.
