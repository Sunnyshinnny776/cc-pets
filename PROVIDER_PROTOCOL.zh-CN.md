# CC Pets Provider 事件协议

[English](./PROVIDER_PROTOCOL.md) | 简体中文

第三方 CLI Agent 可以通过标准输入向 CC Pets 写入统一状态事件，从而复用状态气泡、
桌宠动画和可选的系统通知。协议只接收状态类别和工具类别，不接收提示词、命令正文、
文件内容或模型输出。

## 发送事件

```bash
printf '%s' '{
  "schemaVersion": 1,
  "provider": "MyAgent",
  "state": "tool",
  "tool": "shell"
}' | cc-pets provider-event
```

`provider` 必填，最长 32 个字符，仅保留字母、数字、空格、`.`、`_` 和 `-`。
`tool` 可选，最长 64 个字符，仅用于选择脱敏后的状态文案和动画。

`state` 必须是下列值之一：

| state | 含义 |
| --- | --- |
| `starting` | 会话开始 |
| `thinking` | Agent 思考 |
| `tool` | 工具开始执行 |
| `approval` | 等待用户审批 |
| `subagent` | 子 Agent 工作中 |
| `tool_completed` | 单次工具执行完成 |
| `tool_failed` | 单次工具执行失败 |
| `completed` | 当前任务完成 |
| `failed` | 当前任务失败 |
| `notification` | 需要用户关注 |

建议工具类别使用 `shell`、`edit`、`write`、`read`、`search`、`web`、`mcp` 或
`agent`。CC Pets 不会执行 `tool` 字段，也不会将其作为通知正文。

## 状态显示规则

事件到达顺序不一定等于语义顺序，气泡显示因此有两条额外规则：

- **终态具有黏性。** 进入 `completed` 或 `failed` 后，紧随其后的 `tool_completed`
  （以及内部的 `SubagentStop`、`TaskCompleted`）不会改写气泡——这类尾巴事件常常在任务
  真正结束之后才到达。要解除终态，请发送 `thinking`、`tool`、`approval` 或
  `notification` 等表示新一轮动作的状态。
- **`starting` 是短时态。** 超过 8 秒没有后续事件，气泡会自动落到"待机中"，表示会话
  已就绪、正在等待输入。长时间的准备工作请显式发送 `thinking`，不要停留在 `starting`。

## 生命周期

事件写入当前用户的临时状态目录，已经运行的 CC Pets 会立即读取。Provider 集成需要自行
负责启动和关闭 CC Pets；事件协议不会创建后台守护进程，也不会改变现有 Codex/Claude CLI
的托管生命周期。

协议版本不兼容或字段无效时，命令返回退出码 `2`；写入失败时返回非零退出码。

## 与 CC Bridge 的关系

本协议只传状态，不传正文。需要在会话之间传递消息内容时，使用默认关闭、由用户显式开启的
[CC Bridge](./CC_BRIDGE.zh-CN.md)；它不经过本协议，也不改变本协议的字段约束。
