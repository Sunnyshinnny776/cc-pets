# Changelog

English | [简体中文](./CHANGELOG.zh-CN.md)

This project follows Semantic Versioning. `package.json` is the single source of
truth for the version.

## [Unreleased]

### Language

- The app is now available in English and Simplified Chinese. A new **Language** submenu offers **System Default**, **English** and **简体中文**; System Default follows macOS's preferred languages and falls back to English.
- `cc-pets` commands, hooks and CC Bridge messages follow the same choice through `~/.cc-pets/language`; `CC_PETS_LANGUAGE` overrides it per command.
- Added English default lines. An unedited `~/.cc-pets/speech.txt` switches with the language; lines without Chinese, Japanese or Korean text may now be up to 40 characters.
- The update dialog shows the highlights from the release notes section matching the UI language.

## [2.1.2] - 2026-10-04

Update prompts through the pet, `cc-pets doctor` and `cc-pets paths`, plus cleanup fixes.

### Updates

- Check npm for a newer version 5 seconds after launch, and again when a CLI reopens a running pet (at most once every 10 minutes); failed checks stay silent.
- Announce a new version with a clickable speech bubble that shows up to three highlights from the matching GitHub Release. The bubble waits while an agent is busy, and with chatter on, idle speech now and then reminds you until you choose **Later**.
- Added a glass "↑" badge on the pet as a lasting entry point, and while a new version is available the right-click menu shows **Update to x.y.z…** at the top level; the update dialog lists highlights and links to the full release notes, and **About CC Pets** uses the same dialog style.
- **Check for Updates…** and **About CC Pets** moved into a new **Help** submenu.

### CLI

- Added `cc-pets doctor`, a read-only check of the installation: Node.js, matching versions of the npm package, native binary and installed app, Claude Code and Codex hooks (including hooks that still point to a moved package), the Claude status line, shell shims and `PATH` order, the real CLI binaries, the updater config, and CC Bridge. Each problem comes with a fix, and the output shows the home directory as `~` so it can be pasted into an issue.
- Added `cc-pets paths [--json]`, which lists where settings, pet assets, phrases, caches and runtime state live, how large each is, and what `clean` and `--purge` remove.
- `cc-pets clean` now also removes the pet store manifest cache in `~/.cc-pets/cache`.
- `cc-pets uninstall --purge` keeps your pet assets and phrases in `~/.cc-pets`, as it always did; the help text, confirmation prompt and README now say so instead of promising to remove all local data.

### CC Bridge

- `cc-pets bridge enable`, `cc-pets bridge status` and `cc-pets doctor` check whether the installed Codex supports `codex queue`. Without it, CC Bridge still turns on and messages to Codex wait in its inbox; upgrading Codex enables wake-up without re-enabling CC Bridge.

## [2.1.1] - 2026-09-30

Feature release: the native Liquid Glass panel theme and multi-terminal jump-back, plus quota fixes.

### Panels and menus

- Added a Liquid Glass panel theme on macOS 26 and later, chosen under **Panel theme** in the right-click menu; Classic stays the default and is unchanged. It covers the quota panel, status card, speech bubble and agent session list.
- The public glass styles turn frosted whenever the app is inactive, and the pet never activates. On macOS 27 an undocumented glass variant keeps the clear, refractive look; `defaults write com.universewang.cc-pets CCPetsDisableExperimentalGlass -bool YES` turns it off and falls back to public Clear glass.
- **Glass dimming** offers Clear (0%), Light (15%), Standard (25%, default) and Legible (45%); soft shades on the top and bottom edges tone down the bright rim.
- In Liquid Glass the quota panel uses white text with colored dots instead of colored text and pill badges, a minimum text size, monospaced digits and a light scrim under each card.
- The agent session list opens as a glass panel with a height limit and scrolling; unlike the system menu it has no arrow-key navigation.
- Theme and dimming choices apply immediately and keep the menu open, so levels can be compared.
- Added **About CC Pets** to the right-click menu.
- Menu switch hints now show even while the pet app is inactive.
- Removed the **Refresh usage** menu item and the quota panel's refresh button; usage still refreshes on a timer.
- The CC Bridge submenu is down from 14 rows to 6; while CC Bridge is off it shows only **Enable**.

### Agent status

- Fix Codex bubbles jumping to the wrong terminal: Codex 0.159 runs every terminal's sessions in one shared `codex app-server --managed-daemon`, so hooks inherited the environment of whichever terminal started it. `codex-with-pet` now registers each launch, hooks pair new sessions with the launch in the same directory, and when no pairing is certain the bubble does not jump. Codex sessions started before this version need to be restarted once.

### Quota and usage

- Fix idle Claude sessions rolling the quota back to an older, higher remaining value: a lower value is accepted only from a newer response, and expired 5-hour windows no longer show their old percentage.
- Keep the live Codex quota across restarts and app-server gaps, instead of falling back to an hours-old session-log snapshot.

### CLI

- Added `cc-pets --help`; unknown flags now fail with exit status 2 instead of launching the pet, and `cc-pets uninstall --purge` takes effect.

## [2.1.0] - 2026-09-24

CC Bridge for messaging between Claude Code and Codex sessions.

### CC Bridge (experimental, off by default)

- Added `cc-pets bridge enable|disable|status`, which lets Claude Code and Codex terminal sessions on the same Mac discover each other, exchange messages, and wake each other, including Claude ↔ Codex and Codex ↔ Codex. See [CC_BRIDGE.md](./CC_BRIDGE.md).
- Uses documented extension points only: an MCP server (`list_agents` / `send_message` / `check_inbox`) for sending, `codex queue` for delivery to Codex, and an `asyncRewake` hook for delivery to Claude Code.
- Checks that the recipient is online before delivery so Codex never runs stale messages on resume; 16 KB message limit, 24-hour expiry, and a 20-messages-per-10-minutes pair limit to break auto-reply loops.
- `cc-pets uninstall` removes CC Bridge integrations; reinstalls and upgrades refresh them with the saved options.
- File reservations: `reserve_files` / `release_files` / `list_reservations`, where the first edit to a file someone else reserved is paused once by a PreToolUse hook with the reason, and a retry goes through; reservations expire and are released when the session ends.
- Pet integration: a message badge on the status icon (blue for new deliveries, orange for inbox backlog), recent cross-session messages in the session menu, and click-to-jump to the recipient's terminal; names and times only, never bodies.
- Options and pet switches: `cc-pets bridge configure` and `enable` accept `--approve` / `--codex-approve` / `--claude-allow` (skip approval in Codex and Claude by tool group), `--wake`, and `--edit-guard`, keeping anything not given; the pet's right-click menu gains a CC Bridge section (enable, four approval groups, auto-wake, edit guard, message badge, new-message notifications).
- Custom session names via `CC_BRIDGE_NAME` at launch, or `set_name` / `cc-pets bridge name` in a session; `list_agents` shows each session's terminal (tty).

### Agent status

- Fix the status card not jumping back from VS Code family editors: `TERM_PROGRAM=vscode` is shared by VS Code, Cursor, Windsurf and Antigravity, so it no longer decides the application on its own — the captured bundle identifier goes first, and every candidate that is not running is skipped instead of failing the whole jump.

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
