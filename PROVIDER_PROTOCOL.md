# CC Pets Provider Event Protocol

English | [简体中文](./PROVIDER_PROTOCOL.zh-CN.md)

Third-party CLI agents can write normalized status events to CC Pets through
standard input and reuse its status card, animations, and optional system
notifications. The protocol accepts status and tool categories only. It does not
accept prompts, command text, file contents, or model output.

## Sending an event

```bash
printf '%s' '{
  "schemaVersion": 1,
  "provider": "MyAgent",
  "state": "tool",
  "tool": "shell"
}' | cc-pets provider-event
```

`provider` is required, has a maximum length of 32 characters, and may contain only
letters, digits, spaces, `.`, `_`, and `-`. `tool` is optional, has a maximum length
of 64 characters, and is used only to select redacted status text and animation.

`state` must be one of these values:

| State | Meaning |
| --- | --- |
| `starting` | Session started |
| `thinking` | Agent is thinking |
| `tool` | Tool execution started |
| `approval` | Waiting for user approval |
| `subagent` | Subagent is working |
| `tool_completed` | One tool execution completed |
| `tool_failed` | One tool execution failed |
| `completed` | Current task completed |
| `failed` | Current task failed |
| `notification` | User attention is required |

Recommended tool categories are `shell`, `edit`, `write`, `read`, `search`, `web`,
`mcp`, and `agent`. CC Pets never executes the `tool` value or uses it as notification
body text.

## Display rules

Events may arrive in an order that differs from their semantic order, so the status
card applies two additional rules:

- **Terminal states are sticky.** After `completed` or `failed`, a following
  `tool_completed` event (or internal `SubagentStop` / `TaskCompleted` event) does
  not replace the terminal status. Send `thinking`, `tool`, `approval`,
  `notification`, or another new-action state to clear it.
- **`starting` is temporary.** If no later event arrives within eight seconds, the
  card changes to idle to show that the session is ready and waiting. Send
  `thinking` explicitly for longer preparation work.

## Lifecycle

Events are written to the current user's temporary state directory and are read
immediately by a running CC Pets process. A provider integration is responsible for
starting and stopping CC Pets. This protocol does not create a background daemon or
change the managed lifecycle of the Codex and Claude integrations.

An incompatible schema version or invalid field returns exit code `2`. A write
failure returns a non-zero exit code.

## Relationship to CC Bridge

This protocol carries state only, never content. To pass message content between sessions,
use [CC Bridge](./CC_BRIDGE.md), which is off by default and must be enabled explicitly. It does
not go through this protocol and does not change its field constraints.
