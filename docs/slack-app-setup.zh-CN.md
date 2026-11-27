# 创建 Slack App：让机器人在频道收发消息

本指南适用于通过 **Socket Mode** 连接 Slack 的机器人。完成后，你会得到一个已加入目标频道的 App、一个用于建立连接的 `xapp-` 令牌，以及一个用于发送消息的 `xoxb-` 令牌。机器人程序可以运行在本机，无需提供公网回调地址。[Slack Socket Mode 说明](https://docs.slack.dev/apis/events-api/using-socket-mode/)

## 1. 确定工作区和频道类型

先在 Slack 中打开准备使用的频道，确认工作区名称以及频道是公开还是私有。创建 App 时选择这个工作区。两种频道都需要机器人发送权限 `chat:write`，接收消息所需的配置如下。

| 目标频道 | 机器人读取权限（Bot Token Scope） | 订阅的机器人事件（Bot Event） |
| --- | --- | --- |
| 公开频道 | `channels:history` | `message.channels` |
| 私有频道 | `groups:history` | `message.groups` |

如果要支持两种频道，就添加两行对应的权限和事件。这些订阅会接收机器人已加入频道中的消息。[Slack 消息事件文档](https://docs.slack.dev/reference/events/message/)

## 2. 用 Manifest 创建 App

1. 打开 Slack 的应用管理页面，点击 **Create New App**。[进入 Your Apps](https://api.slack.com/apps)
2. 选择 **Paste a manifest → Continue**，在 **Workspace** 中选好工作区，切换到 **JSON**。
3. 粘贴下面的示例。将两处 `team-helper` 换成自己的名称：`display_information.name` 显示在应用列表里，`features.bot_user.display_name` 显示在机器人发出的消息上。

```json
{
  "display_information": {
    "name": "team-helper"
  },
  "features": {
    "bot_user": {
      "display_name": "team-helper",
      "always_online": false
    }
  },
  "oauth_config": {
    "scopes": {
      "bot": ["chat:write", "channels:history"]
    }
  },
  "settings": {
    "socket_mode_enabled": true,
    "event_subscriptions": {
      "bot_events": ["message.channels"]
    }
  }
}
```

示例可直接用于**公开频道**。如果只用私有频道，把 JSON 中的 `channels:history` 换成 `groups:history`，同时把 `message.channels` 换成 `message.groups`，保留 `chat:write`。

点击 **Next**，在 **Review your app** 页面核对权限和事件，再点 **Create**。如果看到 Socket Mode 需要额外设置的黄色提示，继续创建，并完成下一步。

## 3. 生成连接令牌，安装 App

| 要保存的值 | 在 App 设置页中的操作 | 用途 |
| --- | --- | --- |
| App-Level Token，前缀 `xapp-` | **Basic Information → App-Level Tokens → Generate Token and Scopes**。名称可填 `socket`，添加 `connections:write`，点击 **Generate** 后复制令牌 | 让程序建立 Socket Mode 连接 |
| Bot User OAuth Token，前缀 `xoxb-` | **OAuth & Permissions → Install to Workspace**（按钮也可能显示工作区名称）。核对工作区并点击 **Allow**，回到 **OAuth & Permissions** 复制 **Bot User OAuth Token** | 以机器人身份调用 Slack API，例如向频道发送消息 |

把两个真实令牌保存在运行机器人的设备或密钥管理工具里。分享教程、截图或配置示例时使用占位符。如果工作区要求审批，由管理员批准安装请求。[Slack 令牌配置步骤](https://docs.slack.dev/tools/python-slack-sdk/socket-mode/) · [Slack 应用安装说明](https://slack.com/help/articles/360001537467)

## 4. 将机器人添加到频道

1. 回到 Slack 桌面端或网页版，打开目标频道，点击聊天窗口顶部的**频道名称**。
2. 在 **Integrations（集成）→ Add apps（添加应用）** 中搜索刚创建的 App，点击 **Add**。在该频道的集成列表中能看到它，即已添加。[Slack 添加应用到频道的说明](https://slack.com/help/articles/360001537467)
3. 如果机器人程序需要频道 ID，打开同一窗口的 **About（关于）**，滚动到底部，复制 **Channel ID**。[Slack 查找频道 ID 的说明](https://docs.slack.dev/tools/python-slack-sdk/tutorial/uploading-files/#sharing-a-file-within-a-channel)

## 5. 验证发送和接收

创建和安装完成后，启动实际处理消息的机器人程序，把 `xapp-`、`xoxb-` 和目标频道 ID 填到它要求的位置。日常使用哪条指令、收到消息后如何回复，由该程序决定。

| 验证项 | 如何判断成功 |
| --- | --- |
| 已连接 | 程序报告 Socket Mode 连接成功 |
| 能发送 | 让程序向目标频道发送一条确认消息，频道中显示机器人的名字和该消息 |
| 能接收 | 在频道里发送一条程序支持的消息，确认程序收到了事件，或在原线程得到预期回复 |

**能发消息却收不到消息时**，先核对第 1 步的频道类型。到 **OAuth & Permissions → Bot Token Scopes** 检查读取权限，再到 **Event Subscriptions → Subscribe to bot events** 检查事件。保存修改后，如果新增了权限，点击 **Reinstall to Workspace** 完成授权。[Slack 权限设置说明](https://docs.slack.dev/app-management/quickstart-app-settings/)

### 可选：用于 CC Pets 的 CC Bridge

若要传图片或文件，请在每个参与的 App 的 **Bot Token Scopes** 中额外添加 `files:write` 和 `files:read`，再点击 **Reinstall to Workspace**。

要让多台 Mac 自动发现对方的在线 agent，每台 Mac 各建一个 App，加入同一个频道。在每台电脑的 `~/.cc-pets/bridge-slack.json` 中填入该机 App 的两个令牌、共用频道 ID 和本机名称。例如：

```json
{
  "enabled": true,
  "app_token": "<本机的 xapp- 令牌>",
  "bot_token": "<本机的 xoxb- 令牌>",
  "discovery": {
    "channel": "<共用频道的 ID>",
    "name": "mac-a"
  }
}
```

打开支持 Slack 发现的 CC Pets，在桌宠菜单启用 **CC Bridge**。频道里出现 `mac-a` 的在线名单后，到另一台已接入的 Mac，让 agent 执行 `list_agents`。从结果中选一个 `mac-a/会话名`，让 agent 通过 Bridge 发消息并请对方回复 `pong`。看到回复就验证了跨机双向收发。[CC Bridge 使用指南](../CC_BRIDGE.zh-CN.md#slack)
