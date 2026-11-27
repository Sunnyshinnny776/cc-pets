# CC Bridge (experimental, off by default)

English | [简体中文](./CC_BRIDGE.zh-CN.md)

CC Bridge lets Claude Code and Codex terminal sessions running on the same Mac discover
each other, exchange messages, and wake each other up. It mirrors Claude Code's native
cross-session messaging (`ListAgents` / `SendMessage`) and extends it to
Claude ↔ Codex and Codex ↔ Codex. Antigravity CLI can also exchange messages with
local sessions. Antigravity App conversations support automatic wake-up when the Sidecar is enabled.

It uses documented extension points including hooks, MCP, `codex queue`, and Antigravity App Sidecars.
It does not use internal protocols, inject keystrokes into terminals, or edit transcripts.

## Enable and disable

```bash
cc-pets bridge enable     # Configure registered CLI profiles and turn CC Bridge on
cc-pets bridge status     # Show the switch, options, online sessions, and recent messages
cc-pets bridge disable    # Remove every CC Bridge integration and turn it off
```

You can also toggle everything from the pet's right-click menu under **CC Bridge**; see [Pet menu](#pet-menu).

After enabling:

- Running Claude Code sessions hot-reload hooks and **start receiving messages immediately**, but only
  get the MCP tools after a restart. Until then they can reply from Bash with
  `cc-pets bridge send <name> '<text>'` (delivered messages include this hint).
- Running Codex sessions need a **restart**. Then run `/hooks` to trust the cc-pets bridge hooks;
  Codex skips untrusted hooks, so that session will not appear in the list.
- Restart Antigravity CLI to load the hooks and Bridge MCP server. Start sessions with `agy`.
- Codex asks for approval on every MCP tool call by default (calls fail outright when the approval
  policy is `never`), and Claude Code asks according to your permission settings. Opt in as needed;
  see [Options](#options).

`cc-pets uninstall` also removes CC Bridge integrations. Reinstalls and upgrades rewrite them
with the saved options when CC Bridge is enabled.

### Options

`enable` and `configure` take the same options, and **anything you leave out keeps its current value**.
`configure` only changes options without re-registering the MCP server, so it's faster:

```bash
cc-pets bridge configure --approve=view,send    # No approval prompts in Codex and Claude
cc-pets bridge configure --codex-approve=view   # Codex only
cc-pets bridge configure --claude-allow=        # Clear Claude's allow list
cc-pets bridge configure --agy-allow=view       # Antigravity CLI only
cc-pets bridge configure --wake=off             # Turn off auto-wake
cc-pets bridge configure --edit-guard=off       # Turn off the reservation edit guard
```

| Option | Description |
| --- | --- |
| `--approve` / `--codex-approve` / `--claude-allow` | Tools that skip approval. Use groups `view` (list sessions, list reservations, read inbox), `send`, `reserve` (reserve / release), `name`, or tool names. Codex gets a marked block at the end of `~/.codex/config.toml`; Claude gets entries in `~/.claude/settings.json` `permissions.allow` (only `mcp__cc-bridge__*` entries are touched). `disable` removes both |
| `--agy-allow` | Opt in to skipping approval for Antigravity CLI. Use the same groups or tool names. `--agy-allow=` clears the list. `--approve` applies to Codex and Claude |
| `--agy-app=on\|off` | Enable the Antigravity App Sidecar in the default Gemini root. Defaults to off |
| `--tab-title=on\|off` | Append the Bridge nickname to CLI terminal tab titles. Defaults to off |
| `--wake=on\|off` | Wake idle Claude Code, supported Codex, and Sidecar-enabled Antigravity App sessions automatically (default on). When off, messages wait in the inbox until the recipient's next prompt, which saves tokens |
| `--edit-guard=on\|off` | Pause the first edit to a file another session reserved (default on) |

Claude picks up changes immediately; Codex needs a session restart (and re-trusting in `/hooks` when hooks change).

To enable tab nicknames, right-click the pet and turn on **CC Bridge → Tab nicknames**. Restart the
CLI session through the CC Pets shell integration to apply the setting. For example, a tab can show
`Fix quota polling | cc-pets · robin`.

## Usage

Ask in plain language in any session:

> List the other agent sessions on this Mac, then tell codex.my-app.otter that the endpoint is now POST /api/pets.

The agent uses these MCP tools:

| Tool | Description |
| --- | --- |
| `list_agents` | Lists online sessions: name [ref], CLI, busy/idle, terminal (tty), start time, directory. The name is the address; add ` [ref]` only when names collide. |
| `send_message` | Sends a message. With `notify_when_idle: true`, you get a one-shot notice when the recipient next finishes a turn. That doesn't mean it has handled this message. |
| `set_name` | Renames the current session. |
| `reserve_files` | Reserves files or directories you are about to edit (globs supported); returns conflicts when they overlap with other reservations. |
| `release_files` | Releases this session's reservations. |
| `list_reservations` | Lists reservations in the current repository, or who reserved a given file. |
| `check_inbox` | Reads the inbox manually. Messages are normally delivered automatically. |

### Slack

Run the Socket Mode adapter with the desktop pet or in the foreground to exchange messages with named bots in one Slack workspace.

1. Create a Slack app for Bridge, enable Socket Mode and create an app-level token with `connections:write`. Give the bot `chat:write`. For public channels, add `channels:history` and subscribe to the `message.channels` bot event. For private channels, use `groups:history` and `message.groups`. Install or reinstall the app, then invite both Bridge and the peer bot to the channel. [Slack Socket Mode setup](https://docs.slack.dev/apis/events-api/using-socket-mode/)
2. Configure the peer to accept mentions from the Bridge bot and reply in the same thread using `thread_ts`. Record the channel ID and the **peer's** bot ID and bot user ID. The bot ID identifies incoming messages and the user ID addresses mentions. The peer app owner can find both IDs in the bot's `auth.test` response. [Bot message events](https://docs.slack.dev/reference/events/message/bot_message/) · [auth.test](https://docs.slack.dev/reference/methods/auth.test/)
3. Save the following as `~/.cc-pets/bridge-slack.json`, replacing the example IDs. Add one entry per agent, with a unique name and channel/bot pair.

```json
{
  "enabled": true,
  "app_token": "xapp-…",
  "bot_token": "xoxb-…",
  "agents": [
    {
      "name": "slack-reviewer",
      "channel": "C0123456789",
      "bot_id": "B0123456789",
      "user_id": "U0123456789"
    }
  ]
}
```

Fill in both tokens from this Mac’s Slack app in the default JSON, enable **CC Bridge** in the pet’s menu, and open an updated CC Pets app. It starts the adapter automatically, reloads saved changes and stops its own adapter when you set `"enabled": false`, disable Bridge or quit the pet. Omitting `enabled` leaves automatic startup off. The JSON stores tokens in plain text locally. The reader restricts token files to owner read/write permissions (`0600`).

For foreground operation, run `cc-pets bridge slack [config.json]`. The CLI prefers each token from JSON, falling back to `SLACK_APP_TOKEN` or `SLACK_BOT_TOKEN` individually. The pet and the foreground command share a single-instance lock. When using a source checkout, launch its updated app and load the matching hooks and MCP in your agent sessions.

- **From a local session**. Find the peer with `list_agents`, then start a thread with `send_message(to="slack-reviewer", message="Please review the API change")`. The configured channel receives the local session name, ref and message body. Recent delivery receipts appear in `cc-pets bridge status`.
- **From Slack**. Have the configured bot post a new channel message such as `@CCBridge to codex-main Please review the API change`. In an API payload, use the Bridge bot's user mention (`<@U…>`). The recipient must be an online local session.
- **Reply in the same thread**. Use the full address in the incoming message, such as `slack-reviewer [a1b2c3]#1234567890.123456`. Threads bind to the original local session ID across concurrent requests and session renames. Start a fresh thread after 48 hours of inactivity.

#### Discover computers through a Slack channel

Use one Slack app and Bridge adapter per Mac and invite the apps to the same private channel in one workspace. The channel is the discovery boundary. Set its ID in each Mac’s `~/.cc-pets/bridge-slack.json`. Optionally set the local computer’s address prefix, for example:

```json
{
  "enabled": true,
  "app_token": "xapp-…",
  "bot_token": "xoxb-…",
  "discovery": {
    "channel": "C0123456789",
    "name": "UniverseWang"
  }
}
```

Replace the example channel ID. Computer names accept uppercase and lowercase letters, digits, dots, underscores and hyphens. Omitting `name` derives the prefix from the Slack bot username. Fill in each app’s own tokens, open the pet and enable Bridge. Each adapter registers in the channel and advertises its local online sessions.

- **Add another Mac** by inviting its app to the channel and starting its adapter with the same channel ID. Existing discovery-enabled Macs pick up the newcomer without a config change, restart or exchange of bot and member IDs.
- **List and send** with `list_agents` or `cc-pets bridge list`. The listing includes the provider and busy/idle state. Send to `UniverseWang/reviewer` from another computer and to `reviewer` locally. Reply to the full address in an incoming message to continue its thread. A delivery receipt is confirmed when the remote Bridge accepts the message.
- **Presence** checks for changes about every five seconds, renews every 30 seconds and expires after 90 seconds. Each computer advertises its own session names, routing identifiers, providers and busy/idle states.
- **Membership** allows participating Bridge bots in the discovery channel to see each other’s sessions and send messages. Use a channel shared by the collaborating machines. Ordinary chat messages do not register a bot.
- **Existing configurations** can keep `agents`, with or without `discovery`. Ordinary bots use explicit entries; existing `"bridge": true` entries keep their configured aliases. When first enabling channel discovery, update and restart each existing adapter once.

#### Image and file attachments

For remote recipients, pass file paths in the optional `attachments` array of `send_message`. For example, send `{"to":"mac-b/reviewer","message":"Review the screenshot and log","attachments":["screenshot.png","logs/build.txt"]}`. The CLI equivalent is `cc-pets bridge send --attach screenshot.png --attach logs/build.txt mac-b/reviewer "Review the screenshot and log"`.

- Choose regular files in the sending session’s working directory (relative or absolute paths), or forward files that session received. Each message accepts up to 8 files totaling 32 MiB. The body is optional with attachments.
- Pet’s session list and `cc-pets bridge list` mark recipients as Local or Remote. Only remote recipients accept attachments. For another local session, put the existing absolute path in a text message. Across Macs, both adapters must support attachments. Add `files:write` and `files:read` to **OAuth & Permissions → Bot Token Scopes** for each participating app and reinstall it to the workspace. Reconnect MCP or restart agent sessions after updating Bridge.
- Slack hosts the files in the configured channel, visible to its members. The receiving adapter downloads the files before delivering local paths to the target. Files are saved under `~/.cc-pets/var/attachments/yyyy-MM-dd/<message-ID>/<Slack-file-ID>/<original-filename>`, retaining the original extension and the receiver’s local date at initial intake. `CC_PETS_HOME` overrides the default home. The agent uses its own file or image reader. Bridge cleans its temporary copies during receipt cleanup after 48 hours. Slack retains channel files according to workspace policy.
- A configured ordinary bot can also share hosted files with an initial comment such as `<@BRIDGE_USER_ID> to reviewer Please inspect`. Thread replies can carry files too. [Slack file API](https://docs.slack.dev/messaging/working-with-files/)

### Antigravity CLI

Enable CC Bridge and make sure `agy` is on your `PATH`. Run `agy` in the project directory.
Incoming messages wait in the inbox until the next model invocation. Use `list_agents` in another
session or run `cc-pets bridge status` to find the session's Bridge name.

Antigravity CLI's default Gemini root is `~/.gemini`. For a registered custom root, set
`CC_PETS_ANTIGRAVITY_HOME` when launching. CC Pets uses `config/hooks.json` for CLI hooks,
`config/mcp_config.json` for the Bridge MCP server, and `antigravity-cli/settings.json` for
the tool allow list. `cc-pets doctor` checks the hooks, MCP registration and shell launcher.

See [Antigravity CLI authentication](https://antigravity.google/docs/cli/install/) for sign-in options.

### Antigravity App

Opt in to App conversations by enabling the Sidecar.

```bash
cc-pets bridge enable --agy-app=on
```

Restart the App to load the Sidecar and Bridge MCP server. Start a turn in each conversation you
want to receive messages in, then use `cc-pets bridge status` or `list_agents` from another session
to find its Bridge name. Keep the App running so the Sidecar can wake the conversation. When
auto-wake is on, the Sidecar sends a fixed wake-up prompt to the existing conversation with
`agentapi`. The hook delivers the peer's message separately as a user message with a Bridge source header.

The Sidecar uses the App's default `~/.gemini` root. `cc-pets bridge configure --agy-app=off` removes
the managed Sidecar and its App setting. [Google Sidecars documentation](https://antigravity.google/docs/sidecars#agentapi)

### Current session identity

Every MCP tool accepts an optional `session_id` identifying the caller. Bridge supplies the current ID
in `SessionStart` and `UserPromptSubmit` hook context; agents should pass that exact value on each call.
For an existing session without this context, read `CODEX_THREAD_ID` (Codex) or
`CLAUDE_CODE_SESSION_ID` (Claude) from that session's own shell. Do not use a recipient's ID, guess
from the online list, or hard-code one session's ID in shared MCP configuration.

Multiple Codex sessions can share an app-server PID. When MCP does not inherit a session ID, the
argument distinguishes the caller. Each call independently validates the registration, live status,
provider and host PID; the MCP process never caches the selected identity. An invalid explicit ID,
one belonging to another host, or one that can't be checked because the MCP host process can't be
identified is rejected with the reason and without falling back to another identity. Calls without
the argument retain environment-based identification and unique PID matching for existing single-session
clients. Anonymous session listing remains available when identity cannot be resolved, but `list_reservations`
returns an error because the repository to check is unknown.

After updating, reconnect the CC Bridge MCP server (or restart its client) to load the new binary
and tool definitions with `session_id`.

### Session names

Default names look like `<account>.<project-directory>.<animal>`, for example `claude.my-app.otter` or
`claude-x.my-app.panda`. The account part is the name shown on the Multi-Account page (`claude` / `codex` for the
default accounts), and the animal comes from a list of 100, so online sessions of the same account and project never
share a name. Names stay within 40 characters; long project directory names are truncated.
When several terminals share a directory, give them memorable names:

```bash
CC_BRIDGE_NAME=frontend claude      # Registers as frontend; becomes frontend-2 if taken
CC_BRIDGE_NAME=api codex
```

You can also ask the agent to rename the session (which calls `set_name`), or run
`cc-pets bridge name frontend` from a Claude shell. Names may contain lowercase letters, digits,
and `. _ -`, up to 40 characters.

`list_agents` and `cc-pets bridge status` show each session's terminal (such as `ttys003`), so you
can say "send it to the session in ttys003".

## How to talk to agents

Plain language works; you don't need to remember tool names. Tip: **mention "cc-bridge" or the
recipient's session name**, so the agent calls the tools directly instead of searching the project
for what "bridge" means. The examples below assume two sessions named `web` (Claude) and `api` (Codex).

**You can also just call it "pet"**, with the same effect:

> Use pet to tell web the endpoint is ready
> Have pet pass a note to api: don't touch backend/ yet
> Pet, who's online?
> Use pet to reserve src/api before you start

"Pet" is a domain concept in many projects (think `/api/pets` in the Petstore example), so pair it
with an action: "**use pet to tell**…", "**have pet pass a note to**…", "**pet, who's online**".
A request like "add a field to pet" is read as a code change and won't trigger CC Bridge. Restart
Claude / Codex sessions for wording changes to take effect (MCP instructions load at session start).

### Common requests

| You want to | Say something like |
| --- | --- |
| See who's online | Use cc-bridge to list the sessions that are online |
| Notify a session | Use cc-bridge to tell api the login endpoint is now POST /api/login and returns a token; update the frontend call |
| Hand off a task | Ask web to write unit tests for src/api/login.ts and report back |
| Get an answer back | Ask api how far the database migration has gone, and have it reply through cc-bridge |
| Wait for a result | Tell api to run the test suite and send you the result through cc-bridge |
| See when it's idle | Message api and have it notify you when it goes idle |
| Target by terminal | Send this to the Claude session in ttys003: … |

Replies arrive as new messages in your session. "Notify you when it goes idle" sends a one-shot
notice once the recipient finishes its turn (`notify_when_idle`). If the recipient is busy, that may be
a turn that started before your message arrived, so the notice only means a turn ended, not that your
task is done. To wait for a result, ask the recipient to reply when it finishes.

### Several sessions in one repository

- Before starting: "Use cc-bridge to reserve src/api with the reason 'login refactor', then start;
  release it when you're done."
- Check: "Who has reserved which files in this repository?"
- On conflict: the first edit another session makes to a reserved file is paused once, showing who
  reserved it and why; it usually coordinates first. If you really want the edit, say "I know web is
  working on it, go ahead and change src/api/user.ts." One retry goes through, and that reservation
  won't pause it again.

### Typical workflows

**Split frontend and backend**

1. In `web`: "Reserve frontend/ and start on the login page."
2. In `api`: "Reserve backend/, implement the login endpoint, and send the API shape to web through cc-bridge when done."
3. `api` sends the message, `web` wakes up and wires up the frontend.

**Ask another session to review**

> Send the list of files you just changed and the key points to api, ask it for a review, and have it reply with any issues.

### Tips

- Messages are **teammate requests**: the recipient acts within **its own permissions**, and actions
  that need approval there still prompt.
- Codex asks for approval on every cc-bridge tool call by default; read-only tools are safe to allow:
  `cc-pets bridge enable --codex-approve=list_agents,list_reservations,check_inbox`.
- Claude sessions started before CC Bridge was enabled receive messages but don't have the tools;
  they can only reply with `cc-pets bridge send` from a shell. Restarting is simplest.
- Watch the pet: a blue number on the status icon means sessions are talking; open it to see who
  messaged whom and click to jump to that terminal (see below).

## File reservations

When several agents work in the same repository, the biggest risk is two sessions editing the same
file. File reservations let an agent announce "I'm about to change `src/api/**`" before a larger edit:

- A reservation that overlaps someone else's returns the conflicts (holder, reason, time left), so the
  agent can coordinate with `send_message`.
- The **first time** another session edits a reserved file (Claude's Edit / Write / MultiEdit /
  NotebookEdit, Codex's apply_patch), that edit is **paused once** and the agent sees who reserved it
  and why. If the user explicitly asked for the change, retrying lets it through and that reservation
  never pauses it again; otherwise the agent should coordinate or work elsewhere.
- Reservations are **advisory**: files are not locked and edits never get stuck; the pause only
  guarantees the agent notices.
- They expire after 30 minutes by default (up to 8 hours), renew when reserved again, and are released
  when the session ends.
- They are scoped to the repository root, so different repositories and worktrees never collide. Only
  path patterns and reasons are stored, never file contents.

Just ask: "Reserve src/api before you start the refactor, and release it when you're done."

## Delivery

| Recipient | Idle | Busy | Exited |
| --- | --- | --- | --- |
| Codex | Woken immediately through `codex queue` | Queued after the current turn | Not delivered; receipt is undeliverable |
| Claude Code | Woken by a background `asyncRewake` watcher | Injected into the current turn | Not delivered; receipt is undeliverable |
| Antigravity CLI (`agy`) | Waits for the next model invocation | Picked up on a subsequent model invocation | Not delivered; receipt is undeliverable |
| Antigravity App with Sidecar enabled | Starts a new turn in the existing conversation | Waits for the conversation or its next model invocation | Not delivered once the App is offline |

The Claude Code watcher arms at session start and at the end of every turn. A new watcher replaces the
previous one and restarts the wait, which lasts up to about 55 minutes before it exits. If a Claude session stays idle through that gap, messages stay in its
inbox and are included with the user's next prompt; messages that arrive during that turn are
delivered when it ends.

Waking Codex requires a Codex version with the `codex queue` subcommand. `cc-pets bridge enable`,
`cc-pets bridge status`, and `cc-pets doctor` check the installed version. Without it, CC Bridge
still works: messages to Codex wait in its inbox until it calls `check_inbox` or the user's next
prompt brings them in.

Senders get receipts such as "queued", "in inbox", or "undeliverable". Delivery does not mean
the recipient has read or agreed to anything.

A session that crashes or is killed never fires `SessionEnd`. Its undelivered messages are cleaned up
the next time the session list finds it offline, or when the next session starts: receipts become
undeliverable and its idle subscriptions are removed.

Codex threads on a shared app-server run in the background. Closing a terminal tab doesn't end the
thread right away: `SessionEnd` fires when the app-server unloads it, which took up to a few minutes
when tested. Until then the thread still shows as online, and a message sent to it may be queued and
run when the thread is resumed.

## In the pet

With CC Bridge enabled, the round icon on the pet's status card gets a message badge in its
bottom-right corner (the red top-right badge still counts pending approvals):

- **Blue**: cross-session messages delivered since the pet started.
- **Orange**: messages waiting in some session's inbox (usually a long-idle Claude session); say
  anything in that terminal to deliver them.

Click the icon to open the session menu. The "CC Bridge messages" section at the top lists the last
30 minutes of traffic (such as `api → web · 22:43`) and inbox reminders; click one to jump to the
**recipient's terminal**. The session list below shows each session's CC Bridge name. Opening the
menu marks messages as seen. The menu and badge show names and times only, never message bodies.

## Pet menu

Right-click the pet → **CC Bridge**:

| Switch | Effect |
| --- | --- |
| 启用 (Enable) | Same as `cc-pets bridge enable / disable`; takes a few seconds |
| 自动唤醒 (Auto-wake) | Same as `--wake` |
| 编辑拦截 (Edit guard) | Same as `--edit-guard` |
| 免审批 (Skip approval) › 查看类 view / 发消息 send / 文件预留 reserve / 改会话名 rename | Each group applies to both Codex approval and Claude permissions. With "send" on, agents can message other sessions without asking |
| 桌宠提醒 (Pet alerts) › 消息角标 (Message badge) | Pet only: show the message badge on the status icon |
| 桌宠提醒 (Pet alerts) › 新消息通知 (New-message notifications) | Pet only: a system notification when sessions message each other (sender and recipient only, never the body); asks for notification permission the first time |

The pet's UI is currently in Simplified Chinese. "N 会话 · M 预留" (online sessions and active
reservations) appears under 启用, and each switch has a hover tooltip. While CC Bridge is off the menu
shows only 启用; reopen the menu after enabling to see the other switches. The menu finds the command-line
tool through `~/.cc-pets/bridge-cli.json`, written on every `cc-pets install`; if it's missing, you'll be asked to reinstall.

## Security and privacy

- Delivered messages carry a source header. The agent treats them as a **teammate's request** and
  acts within **its own session's permission settings**. A message cannot escalate permissions:
  it must not be used to change permissions or configuration or to approve a pending prompt, and
  when a peer asks for an action that was denied on its side, the agent should refuse and tell the user.
- Message bodies are stored in the current user's temporary directory
  (`cc-bridge-<uid>/` under `getconf DARWIN_USER_TEMP_DIR`) with `0700` directories and `0600`
  files; undelivered messages expire after 24 hours (cleaned up when the next session starts). A body is
  deleted once its message is delivered. Receipts hold only sender, recipient, time and status, and
  stay about 48 hours for troubleshooting. This is an explicit exception to the
  [Provider protocol](./PROVIDER_PROTOCOL.md)'s no-content rule, which is why CC Bridge is off by default.
- A message is limited to 16 KB. A pair of sessions exchanging more than 20 messages within
  10 minutes is paused to stop two agents from auto-replying to each other in a loop.
- Pet status cards and notifications never show message bodies.
- Hooks, MCP servers, and Claude watchers follow their sessions. The Antigravity Sidecar runs with the App.

## Identity and delivery guarantees

Bridge validates `CODEX_THREAD_ID` / `CLAUDE_CODE_SESSION_ID` against the live session registry and the
current host process. Without a session ID, PID lookup is allowed only when it identifies exactly one
live session. Ambiguous shared hosts and stale explicit IDs fail closed for sending, renaming, reading
inboxes and managing reservations. CLI diagnostics can select a session explicitly with
`--from <session-name-or-full-session-id>`; with `send`, put it before the message.

Claimed inbox messages remain on disk until the complete output has been flushed successfully.
A later hook, watcher or `check_inbox` recovers unconfirmed messages after a crash. A crash between
output and confirmation may deliver the same message ID again; the host provides no acknowledgement
protocol, so exactly-once delivery is not guaranteed. When `codex queue` times out, Bridge can't tell
whether the message was queued, so it also goes to the inbox and the sender is told it may arrive
twice with the same ID. Codex queue delivery uses the recipient's Home.
Legacy records with an unknown Home fall back to the inbox until registration is refreshed by input
in that session.

Existing watchers recheck the enabled and auto-wake switches while polling. Disabling Bridge also
blocks CLI send, rename and inbox operations. Integration removal failures return a nonzero exit code;
the runtime remains disabled, and `disable` can be retried after resolving the reported errors.
`disable` deletes all undelivered messages and marks their receipts undeliverable. Delivered receipts
contain no message body and stay for their normal retention period.
