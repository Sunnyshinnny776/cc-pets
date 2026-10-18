# 手动 Agent Home 与多账号卡片实施计划

## 目标

官方默认 `~/.claude`、`~/.codex` 保持旧版安装时自动集成；除此之外不扫描用户目录、不自动接管新账号。用户从 CC Pets 主菜单手动添加自定义 Claude 或 Codex Home，应用在确认后异步完成 Hook、用量采集和可选 CC Bridge 适配，并在用量面板中为每个 Provider 提供独立的账号卡片轮播。

## 已确认的产品规则

1. 主菜单提供“添加 Claude Home…”和“添加 Codex Home…”，先确定 Provider，再选择目录。
2. profile 的默认显示名原样来自 Home 文件夹名，仅去掉开头的点：`.claude-x` 显示为 `claude-x`；用户后续输入什么名称就原样显示，不做大小写或友好化转换。
3. 内部身份不使用文件夹名，使用 Provider 与规范化绝对路径生成的稳定 ID，防止同名目录串数据。
4. 添加 profile 时始终安装 Pet Hooks 与用量采集；CC Bridge 仅在全局 Bridge 已开启时安装。
5. 后续开启、关闭或调整 Bridge 时，遍历所有已登记 profile 同步 Hook、MCP 与权限；单个 profile 失败不阻塞其他 profile。
6. 外部程序覆盖配置后只提示“需要修复”，不静默写回。
7. “移除集成”只删除 CC Pets 管理的配置并移出列表，不删除账号、登录信息、会话历史或 Home 目录。
8. Codex 与 Claude 各自保留一张 Provider 卡片；卡片内通过点击、触控板横向手势和键盘左右键切换该 Provider 的账号。
9. 顶部 Token 数可以标注为“全部账号合计”；五小时/七天额度、趋势和刷新时间始终属于当前卡片选中的 profile，不跨账号合并。
10. 安装时自动登记并适配官方默认 `~/.claude`、`~/.codex`；已含 CC Pets 管理标记的默认 Home 可进行一次性迁移；除此之外不扫描或发现其他 Home。

## 数据模型

新增 profile 注册表，保存于 `~/.cc-pets/agent-profiles.json`，文件权限为 `0600`：

```json
{
  "schemaVersion": 1,
  "profiles": [
    {
      "id": "claude:<path-hash>",
      "provider": "claude",
      "home": "/Users/example/.claude-x",
      "slug": "claude-x",
      "displayName": "claude-x",
      "bridgePolicy": "followGlobal",
      "addedAt": 0
    }
  ]
}
```

- Home 在保存前解析 `~`、标准化路径并解析现有软链接。
- `id` 由 Provider 和规范化路径生成；修改显示名不改变 ID。
- Home 迁移通过“重新定位”更新路径并保留原 ID 与历史。
- 运行状态（适配中、部分完成、需要修复、目录不可用）由实时诊断得出，不作为不可恢复的真相写死在注册表中。

## 适配流程

1. 用户选择目录后进行只读预检：目录存在、不是危险软链接、配置文件可解析、Provider 与所选入口一致。
2. 展示目录、显示名和即将安装的能力，用户点击“开始适配”。
3. 创建临时 profile 卡片并显示分阶段进度：检查配置、安装 Pet Hooks、接入用量、同步 Bridge、验证。
4. 后台队列执行写入，所有 JSON/TOML 改动保持原有用户条目，只管理带 CC Pets 标记的内容。
5. 成功后登记 profile；部分失败时保留成功内容并显示可重试的“需要修复”。
6. Claude 新增 MCP 后提示重启会话；Codex 提示重启并在 `/hooks` 中信任。

## 实施阶段

### 阶段一：profile 注册表与显式路径 API

- 新增 profile 注册表的读取、校验、原子写入、迁移与路径哈希。
- 将 Hook、status line、Bridge 安装与卸载函数改造成显式接收 Provider/Home，保留当前环境变量入口以兼容 CLI。
- 新增“适配、修复、移除、重新定位、诊断”服务，并提供阶段进度回调。

### 阶段二：主菜单管理入口

- 增加“Agent 账户”菜单与 Claude/Codex 添加入口。
- 使用目录选择器和确认页，不自动扫描未登记 Home。
- 增加异步 loading、逐 profile 结果、失败重试和移除确认。

### 阶段三：Bridge 多 profile 同步

- `bridge enable/disable/configure/refresh` 遍历注册表中的所有可用 profile。
- Bridge 开启时，新添加 profile 自动同步；关闭时只移除 Bridge 管理条目。
- CLI、Pet 菜单和设置页统一调用同一同步逻辑。

### 阶段四：事件与会话归属

- Hook 命令携带稳定 `CC_PETS_PROFILE_ID` 与显示名。
- 事件流、在线客户端记录、会话卡片和 Bridge 会话保留 profile 身份。
- 隐藏账号发生事件时通过页码状态提示，不强制切换用户当前查看的卡片。

### 阶段五：多 profile 用量与历史

- 用量监控器为每个已登记 Home 建立独立 reader 与文件监听。
- Claude/Codex 当前额度、Token、模型统计和月度缓存按 profile 隔离。
- 额度历史升级为 `provider + profileId` 维度，迁移旧数据到默认 profile，禁止跨账号合并百分比。
- 顶部汇总只累计可相加的本地 Token 数据，并明确标注“全部账号合计”。

### 阶段六：Provider 独立轮播

- Codex 与 Claude 各自一张卡片，保存各自最后选中的 profile。
- 支持左右按钮、页码圆点、触控板横向手势和键盘左右键。
- 单 profile 隐藏翻页控件；边界不循环；切换动画约 180–220ms。
- 页码状态表达在线、待审批和 Bridge 未读；满足键盘焦点、辅助功能标签和足够点击区域。

### 阶段七：诊断、升级和卸载

- Doctor、Paths、升级修复和卸载覆盖全部已登记 profile。
- profile 目录缺失时保留登记与历史，显示“目录不可用”。
- 外部覆盖管理条目时显示“需要修复”，由用户主动修复。

## 验证方式

遵循仓库约束，不新增或运行测试命令。实施期间使用：

- Objective-C 严格编译（`CC_PETS_STRICT=1`）作为主要静态验证。
- `plutil`、`jq` 和只读 CLI 状态检查验证生成配置结构。
- 人工检查默认 Home、额外 Claude Home、额外 Codex Home、Bridge 开关同步、目录缺失和部分失败状态。
- 人工检查卡片按钮、滑动、键盘切换、单账号隐藏控件及多账号数据隔离。

## 完成标准

- 除官方默认 `~/.claude`、`~/.codex` 外，未经用户选择的 Home 不会被扫描、登记或修改。
- 用户可从主菜单添加 Claude/Codex Home，并看到真实阶段进度与最终状态。
- Pet Hook、用量采集、Bridge、会话身份、额度、Token、历史和诊断均按 profile 隔离。
- Bridge 全局开关能同步所有已登记 profile，失败可逐项修复。
- Codex/Claude 卡片能独立切换账号，切换后所有显示数据与 profile 一致。
- 移除或卸载不删除用户账号数据，且只清理 CC Pets 管理内容。
