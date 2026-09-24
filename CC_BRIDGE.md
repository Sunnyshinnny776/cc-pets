# CC Bridge (experimental, off by default)

English | [简体中文](./CC_BRIDGE.zh-CN.md)

CC Bridge lets Claude Code and Codex terminal sessions running on the same Mac discover
each other, exchange messages, and wake each other up. It mirrors Claude Code's native
cross-session messaging (`ListAgents` / `SendMessage`) and extends it to
Claude ↔ Codex and Codex ↔ Codex.

It uses only documented extension points of both CLIs: hooks, MCP, and `codex queue`.
It does not use internal protocols, inject keystrokes into terminals, or edit transcripts.

## Enable and disable

```bash
cc-pets bridge enable     # Write hooks, register the MCP server, and turn CC Bridge on
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
cc-pets bridge configure --wake=off             # Turn off auto-wake
cc-pets bridge configure --edit-guard=off       # Turn off the reservation edit guard
```

| Option | Description |
| --- | --- |
| `--approve` / `--codex-approve` / `--claude-allow` | Tools that skip approval. Use groups `view` (list sessions, list reservations, read inbox), `send`, `reserve` (reserve / release), `name`, or tool names. Codex gets a marked block at the end of `~/.codex/config.toml`; Claude gets entries in `~/.claude/settings.json` `permissions.allow` (only `mcp__cc-bridge__*` entries are touched). `disable` removes both |
| `--wake=on\|off` | Wake idle sessions automatically (default on). When off, messages wait in the inbox until the recipient's next prompt, which saves tokens |
| `--edit-guard=on\|off` | Pause the first edit to a file another session reserved (default on) |

Claude picks up changes immediately; Codex needs a session restart (and re-trusting in `/hooks` when hooks change).

## Usage

Ask in plain language in any session:

> List the other agent sessions on this Mac, then tell codex-my-app-1 that the endpoint is now POST /api/pets.

The agent uses these MCP tools:

| Tool | Description |
| --- | --- |
| `list_agents` | Lists online sessions: name [ref], CLI, busy/idle, terminal (tty), start time, directory. The name is the address; add ` [ref]` only when names collide. |
| `send_message` | Sends a message. With `notify_when_idle: true`, you get a one-shot notice when the recipient next finishes a turn. |
| `set_name` | Renames the current session. |
| `reserve_files` | Reserves files or directories you are about to edit (globs supported); returns conflicts when they overlap with other reservations. |
| `release_files` | Releases this session's reservations. |
| `list_reservations` | Lists reservations in the current repository, or who reserved a given file. |
| `check_inbox` | Reads the inbox manually. Messages are normally delivered automatically. |

### Session names

Default names look like `<claude|codex>-<project-directory>-<n>`, for example `claude-my-app-1`.
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
| Wait until it's done | Tell api to run the test suite, and notify you when it goes idle |
| Target by terminal | Send this to the Claude session in ttys003: … |

Replies arrive as new messages in your session. "Notify you when it goes idle" sends a one-shot
notice once the recipient finishes its turn (`notify_when_idle`), which is handy for "continue after
it's done".

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

The Claude Code watcher arms at session start and at the end of every turn, and waits up to about
55 minutes before exiting. If a Claude session stays idle through that gap, messages stay in its
inbox and are included with the user's next prompt; messages that arrive during that turn are
delivered when it ends.

Senders get receipts such as "queued", "in inbox", or "undeliverable". Delivery does not mean
the recipient has read or agreed to anything.

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
| 免审批 (Skip approval): 查看类 view / 发消息 send / 文件预留 reserve / 改会话名 rename | Each group applies to both Codex approval and Claude permissions. With "send" on, agents can message other sessions without asking |
| 自动唤醒 (Auto-wake) | Same as `--wake` |
| 编辑拦截 (Edit guard) | Same as `--edit-guard` |
| 消息角标 (Message badge) | Pet only: show the message badge on the status icon |
| 新消息通知 (New-message notifications) | Pet only: a system notification when sessions message each other (sender and recipient only, never the body); asks for notification permission the first time |

The pet's UI is currently in Simplified Chinese. The bottom of the menu shows "N 会话 · M 预留"
(online sessions and active reservations), and each switch has a hover tooltip. Except for the badge and
notification switches, everything is dimmed while CC Bridge is off. The menu finds the command-line
tool through `~/.cc-pets/bridge-cli.json`, written on every `cc-pets install`; if it's missing, you'll be asked to reinstall.

## Security and privacy

- Delivered messages carry a source header. The agent treats them as a **teammate's request** and
  acts within **its own session's permission settings**. A message cannot escalate permissions:
  it must not be used to change permissions or configuration or to approve a pending prompt, and
  when a peer asks for an action that was denied on its side, the agent should refuse and tell the user.
- Message bodies are stored in the current user's temporary directory
  (`cc-bridge-<uid>/` under `getconf DARWIN_USER_TEMP_DIR`) with `0700` directories and `0600`
  files; undelivered messages expire after 24 hours. This is an explicit exception to the
  [Provider protocol](./PROVIDER_PROTOCOL.md)'s no-content rule, which is why CC Bridge is off by default.
- A message is limited to 16 KB. A pair of sessions exchanging more than 20 messages within
  10 minutes is paused to stop two agents from auto-replying to each other in a loop.
- Pet status cards and notifications never show message bodies.
- No background daemon: only hooks, the MCP server, and the watcher inside Claude sessions, all of which exit with the session.
