# CC Bridge（实验性，默认关闭）

[English](./CC_BRIDGE.md) | 简体中文

CC Bridge 让本机同时运行的 Claude Code 与 Codex 终端会话互相发现、发消息、唤醒对方，
体验对齐 Claude Code 原生的跨会话消息（`ListAgents` / `SendMessage`），并且支持
Claude ↔ Codex、Codex ↔ Codex。

它只使用两边官方公开的扩展点：hooks、MCP、`codex queue`。不接入任何内部协议，
不向终端注入按键，不修改会话记录。

## 开启与关闭

```bash
cc-pets bridge enable     # 写入 hooks、注册 MCP，并打开开关
cc-pets bridge status     # 查看开关、选项、在线会话与最近消息
cc-pets bridge disable    # 移除全部 CC Bridge 集成并关闭
```

也可以在桌宠右键菜单的 **CC Bridge** 里直接开关，见下文[桌宠菜单](#桌宠菜单)。

开启后：

- 已经在运行的 Claude Code 会话会热加载 hooks，**立即开始接收消息**，但 MCP 工具要重启后才有；
  在此之前可以在 Bash 里用 `cc-pets bridge send <名字> '<内容>'` 回复（收到的消息里会附带这条提示）。
- 已经在运行的 Codex 会话需要**重启**。启动后执行 `/hooks`，信任 cc-pets bridge 的 hooks；
  未信任的 hooks 会被 Codex 跳过，对应会话不会出现在列表里。
- Codex 默认每次调用 MCP 工具都要审批（审批策略为 `never` 时调用会直接失败）；Claude Code 首次调用时也会按你的
  权限设置询问。可以按需放开，见下方[选项](#选项)。

`cc-pets uninstall` 也会一并移除 CC Bridge 集成；重装或升级时，已开启的 CC Bridge 会按原选项自动重写集成。

### 选项

`enable` 与 `configure` 接受同一组选项，**没给的保持原值**；`configure` 只改选项、不重新注册 MCP，更快：

```bash
cc-pets bridge configure --approve=view,send    # Codex 与 Claude 同时免审批
cc-pets bridge configure --codex-approve=view   # 只设 Codex
cc-pets bridge configure --claude-allow=        # 清空 Claude 免确认
cc-pets bridge configure --wake=off             # 关闭自动唤醒
cc-pets bridge configure --edit-guard=off       # 关闭编辑前预留拦截
```

| 选项 | 说明 |
| --- | --- |
| `--approve` / `--codex-approve` / `--claude-allow` | 免审批的工具。可写分组 `view`（列会话、查预留、读信箱）、`send`（发消息）、`reserve`（预留 / 释放）、`name`（改名），或具体工具名。Codex 写入 `~/.codex/config.toml` 末尾的带标记块，Claude 写入 `~/.claude/settings.json` 的 `permissions.allow`（只增删 `mcp__cc-bridge__*` 条目）；`disable` 时一并移除 |
| `--wake=on\|off` | 自动唤醒空闲会话，默认开。关闭后消息只进信箱，等对方下次收到你的输入时带入，可省 token |
| `--edit-guard=on\|off` | 编辑他人预留的文件时暂停一次，默认开 |

Claude 侧的改动会被热加载；Codex 侧（审批、hooks）需要重启 Codex 会话，hooks 变化后还要在 `/hooks` 中重新信任。

## 使用

在任意一个会话里直接用自然语言：

> 列出本机其他 Agent 会话，然后给 codex-my-app-1 发消息：接口改成了 POST /api/pets，你那边同步一下。

Agent 会调用这些 MCP 工具：

| 工具 | 说明 |
| --- | --- |
| `list_agents` | 列出在线会话：名字 [ref]、CLI、忙闲、所在终端（tty）、启动时间、目录。名字就是地址；只有重名时才需要写成 `名字 [ref]`。 |
| `send_message` | 发消息；`notify_when_idle: true` 时，对方下次完成回合后你会收到一条一次性空闲通知。 |
| `set_name` | 修改当前会话的名字。 |
| `reserve_files` | 预留即将修改的文件或目录（支持 glob），与他人预留重叠时返回冲突列表。 |
| `release_files` | 释放本会话的预留。 |
| `list_reservations` | 查看当前仓库的所有预留，或某个文件被谁预留。 |
| `check_inbox` | 手动读取信箱。正常情况下消息会自动送达，一般不需要调用。 |

### 会话名

默认名字是 `<claude|codex>-<项目目录名>-<序号>`，例如 `claude-my-app-1`。同一目录开多个终端时，
可以给它们起好记的名字：

```bash
CC_BRIDGE_NAME=frontend claude      # 以 frontend 注册；被占用时自动变成 frontend-2
CC_BRIDGE_NAME=api codex
```

也可以在会话里让 Agent 改名（"把本会话在 cc-bridge 里的名字改成 frontend"，即调用 `set_name`），
或在 Claude 的 shell 里执行 `cc-pets bridge name frontend`。名字只能包含小写字母、数字和 `. _ -`，最长 40 个字符。

`list_agents` 与 `cc-pets bridge status` 会显示每个会话所在的终端（如 `ttys003`），
可以直接说"发给 ttys003 那个会话"。

## 怎么和 Agent 说

用自然语言即可，不需要记工具名。小技巧：**说话时带上"cc-bridge"或对方的会话名**，Agent 会直接调用工具，
而不是先去项目文件里搜"bridge"是什么。下面的例子假设两个会话分别以 `web`（Claude）和 `api`（Codex）命名。

**也可以直接叫它"pet"或"桌宠"**，效果相同：

> 用 pet 发给 web：接口改好了
> 让桌宠转告 api：先别动 backend/
> pet 看看谁在线
> 用 pet 预留 src/api 再开始改

"pet"在很多项目里本身就是业务概念（比如 Petstore 示例里的 `/api/pets`），所以请带上动作来说——
"**用 pet 发给**……""**让桌宠转告**……""**pet 看看谁在线**"。像"给 pet 加个字段"这种说法，Agent 会理解成改业务代码，
不会去调用 CC Bridge。说法改动需要重启 Claude / Codex 会话后才生效（MCP 说明在会话启动时加载）。

### 常用说法

| 想做的事 | 可以这样说 |
| --- | --- |
| 看谁在线 | 用 cc-bridge 看看现在有哪些会话在线 |
| 通知对方 | 用 cc-bridge 告诉 api：登录接口改成了 POST /api/login，返回字段加了 token，你那边同步改一下前端调用 |
| 分派任务 | 让 web 帮忙写 src/api/login.ts 的单元测试，写完告诉我结果 |
| 要对方回复 | 问一下 api 数据库迁移做到哪一步了，让它用 cc-bridge 回复你 |
| 等对方做完 | 给 api 发消息让它跑一遍测试，并在它空闲时通知你 |
| 按终端指定 | 发给 ttys003 那个 Claude 会话：…… |

对方的回复会作为一条新消息出现在当前会话里。"在它空闲时通知你"会让对方这一轮做完后，
当前会话收到一条一次性的空闲通知（`notify_when_idle`），适合"等它做完我再继续"。

### 多个会话改同一个仓库

- 开工前预留："先用 cc-bridge 预留 src/api 目录，原因写'重构登录'，再开始改；改完释放预留。"
- 查看预留："看看这个仓库现在谁预留了哪些文件。"
- 遇到冲突：另一个会话第一次去改被预留的文件时会被暂停一次，并看到是谁、为什么预留，通常会先发消息协调。
  如果确实要它改，直接说："我知道 web 在改，你照样改 src/api/user.ts。"它重试一次即可，之后不再被这处预留拦住。

### 典型协作流程

**前后端分工**

1. 在 `web` 里："预留 frontend/ 目录，开始做登录页面。"
2. 在 `api` 里："预留 backend/ 目录，实现登录接口，做完用 cc-bridge 把接口格式发给 web。"
3. `api` 做完发出消息，`web` 被唤醒，按接口格式完成对接。

**写完请另一个会话审查**

> 把刚才改动的文件列表和改动要点发给 api，让它帮忙 review，有问题直接回复你。

### 小贴士

- 消息是**队友的请求**，对方在**自己的权限范围内**处理：它那边需要审批的操作照样会弹审批。
- Codex 每次调用 cc-bridge 工具默认都要审批；只读类工具可以放开：
  `cc-pets bridge enable --codex-approve=list_agents,list_reservations,check_inbox`。
- 开启 CC Bridge 之前就在运行的 Claude 会话能收消息，但没有这些工具，只能在 shell 里用 `cc-pets bridge send` 回复；重启一下最省事。
- 留意桌宠：状态图标右下角出现蓝色数字，说明会话之间有往来；点开能看到谁发给了谁，点一下即跳到对应终端（见下文）。

## 文件预留

多个 Agent 在同一个仓库里工作时，最怕两个会话同时改同一个文件。文件预留让 Agent 在开始较大的修改前
先声明"我要改 `src/api/**`"：

- 其他会话预留时如果与之重叠，会收到冲突列表（持有者、原因、剩余时间），可以直接 `send_message` 协调；
- 其他会话**第一次编辑**被预留的文件时（Claude 的 Edit / Write / MultiEdit / NotebookEdit，Codex 的 apply_patch），
  这次编辑会被**暂停一次**，Agent 会看到是谁、为什么预留。如果修改是用户明确要求的，重试即可放行，
  之后这处预留不再拦它；否则 Agent 应先协调或改做其他部分。
- 预留是**建议性**的：不锁文件，不会把编辑卡死，只保证 Agent 一定会注意到。
- 默认 30 分钟过期（最长 8 小时），重复预留即续期；会话结束时自动释放。
- 按仓库根目录隔离：不同仓库、同一仓库的不同 worktree 互不影响。只记录路径模式和原因，不记录文件内容。

可以直接对 Agent 说："先预留 src/api 目录再开始重构，改完释放。"

## 送达方式

| 目标 | 对方空闲 | 对方忙碌 | 对方已退出 |
| --- | --- | --- | --- |
| Codex | 通过 `codex queue` 立即唤醒 | 排在当前回合之后处理 | 不投递，回执为 undeliverable |
| Claude Code | 后台 watcher 通过 `asyncRewake` 唤醒 | 注入当前回合 | 不投递，回执为 undeliverable |

Claude Code 的 watcher 在会话启动和每轮结束时挂上，每次最多等待约 55 分钟后自动退出。
如果 Claude 会话在这段空窗期里一直空闲，消息会留在信箱，等用户下次输入时一并带入；
那一轮进行中新到的消息，在该轮结束时投递。

发送方只会收到"已送达队列 / 已放入信箱 / 无法投递"这类回执。送达不代表对方已读，也不代表对方同意。

## 桌宠里的显示

开启 CC Bridge 后，桌宠状态卡的圆形图标右下角会多一个消息角标（右上角的红色角标仍是待审批）：

- **蓝色数字**：桌宠运行期间新送达的跨会话消息条数；
- **橙色数字**：有消息积压在某个会话的信箱里（通常是长时间空闲的 Claude 会话），需要你去那个终端说句话才会送达。

点击图标打开会话菜单，顶部的「CC Bridge 消息」列出最近 30 分钟的往来（如 `api → web · 22:43`）和积压提醒，
点击任一条即跳到**收件会话所在的终端**；下方的会话列表会带上各会话在 CC Bridge 中的名字。打开菜单即视为已读。
菜单与角标只显示会话名和时间，不显示消息正文。

## 桌宠菜单

桌宠右键菜单 → **CC Bridge**：

| 开关 | 作用 |
| --- | --- |
| 启用 | 等同 `cc-pets bridge enable / disable`，执行需要几秒 |
| 免审批：查看类 / 发消息 / 文件预留 / 改会话名 | 每组同时作用于 Codex 免审批与 Claude 免确认。"发消息"开启后，Agent 可以不经确认给其他会话发消息 |
| 自动唤醒 | 自动唤醒空闲会话，同 `--wake` |
| 编辑拦截 | 编辑前预留拦截，同 `--edit-guard` |
| 消息角标 | 只影响桌宠：是否显示状态图标右下角的消息角标 |
| 新消息通知 | 只影响桌宠：会话之间有消息送达时发系统通知（只含谁发给谁，不含正文），首次开启时申请通知权限 |

菜单底部显示"N 会话 · M 预留"（在线会话数与有效预留数），各开关悬停可看说明。除角标和通知外，其余开关在 CC Bridge 未开启时置灰。
菜单开关通过 `~/.cc-pets/bridge-cli.json` 找到命令行程序（每次 `cc-pets install` 时写入）；找不到时会提示重新安装。

## 安全与隐私

- 收到的消息会带上来源标头，Agent 会把它当作**队友的请求**，在**本会话自身的权限设置内**处理。
  这条消息不能提升权限：不能用来修改权限或配置，不能当作对待确认操作的批准；如果对方说某个操作
  在它那边被拒绝、请你代为执行，Agent 应拒绝并告知用户。
- 消息正文保存在当前用户的临时目录（`getconf DARWIN_USER_TEMP_DIR` 下的 `cc-bridge-<uid>/`），
  目录权限为 `0700`、文件权限为 `0600`，未投递的消息 24 小时后过期。
  这是对 [Provider 协议](./PROVIDER_PROTOCOL.zh-CN.md)"不接收正文"原则的一个显式例外，
  所以默认关闭，需要你主动开启。
- 单条消息最多 16KB。同一对会话 10 分钟内往来超过 20 条会被暂停，防止两个 Agent 互相自动回复形成循环。
- 桌宠的状态卡片与系统通知不会显示消息正文。
- 不引入常驻守护进程：只有 hooks、MCP server，以及 Claude 会话内的 watcher，都随会话结束而退出。
