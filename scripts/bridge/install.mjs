// CC Bridge 的接入与移除：hooks、MCP 注册、Codex 工具审批与 Claude 工具放行（可选）。
//
// 与 install-claude-hooks.mjs / install-codex-hooks.mjs 同一套约定：
//   - 只追加带标记的条目，移除时只认自己的标记，不碰用户其他配置；
//   - 配置文件先写临时文件再 rename；
//   - 没装的 CLI 不写（不凭空创建 ~/.claude、~/.codex）。
// MCP 用各自官方的 `claude mcp add` / `codex mcp add` 注册，而不是手改它们的内部文件。

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { detectClaudeCLI, detectCodexCLI } from "../detect-cli.mjs";
import { DEFAULT_OPTIONS, normalizeOptions } from "./options.mjs";
import { probeCodexQueue, resolveRealExecutable } from "./process.mjs";
import { t } from "../i18n.mjs";

export const HOOK_MARKER = "CC_BRIDGE_HOOK=";
export const MCP_NAME = "cc-bridge";
const TOML_START = "# >>> cc-bridge >>>";
const TOML_END = "# <<< cc-bridge <<<";

// 正式发布前这个功能叫过 "Agent Bus"（cc-pets bus）。启用过旧版的机器上还留着旧标记的
// hooks、旧名字的 MCP 注册和旧审批块，安装 / 卸载时一并识别清理，不留两套。
const LEGACY_HOOK_MARKERS = ["CC_PETS_BUS_HOOK="];
const LEGACY_MCP_NAMES = ["cc-pets-bus"];
const LEGACY_TOML_BLOCKS = [["# >>> cc-pets-bus >>>", "# <<< cc-pets-bus <<<"]];

const cliPath = fileURLToPath(new URL("./cli.mjs", import.meta.url));
const shellQuote = (value) => `'${value.replaceAll("'", `'\\''`)}'`;

const claudeHome = () => process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");
const codexHome = () => process.env.CODEX_HOME || path.join(os.homedir(), ".codex");

// node 用绝对路径：hook 的 PATH 不一定带 nvm 之类的目录。
const bridgeCommand = (provider, subcommand) =>
  `${HOOK_MARKER}${provider} ${shellQuote(process.execPath)} ${shellQuote(cliPath)} ${subcommand}`;

const isBridgeHook = (handler) =>
  typeof handler?.command === "string" &&
  [HOOK_MARKER, ...LEGACY_HOOK_MARKERS].some((marker) => handler.command.startsWith(marker));

const readJsonConfig = (file) => {
  if (!fs.existsSync(file)) return {};
  const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(t("{file} isn't a JSON object", { file }));
  }
  return parsed;
};

const writeJsonConfig = (file, value) => {
  const temporary = `${file}.cc-bridge.tmp`;
  const mode = fs.existsSync(file) ? fs.statSync(file).mode & 0o777 : 0o600;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode });
  fs.renameSync(temporary, file);
};

const stripBridgeHooks = (config) => {
  if (!config.hooks || typeof config.hooks !== "object" || Array.isArray(config.hooks)) return config;
  for (const [event, groups] of Object.entries(config.hooks)) {
    if (!Array.isArray(groups)) continue;
    const kept = groups.flatMap((group) => {
      if (!group || !Array.isArray(group.hooks)) return [group];
      const handlers = group.hooks.filter((handler) => !isBridgeHook(handler));
      return handlers.length > 0 ? [{ ...group, hooks: handlers }] : [];
    });
    if (kept.length > 0) {
      config.hooks[event] = kept;
    } else {
      delete config.hooks[event];
    }
  }
  if (Object.keys(config.hooks).length === 0) delete config.hooks;
  return config;
};

const addHook = (config, event, handler, matcher) => {
  if (!config.hooks || typeof config.hooks !== "object" || Array.isArray(config.hooks)) config.hooks = {};
  if (!Array.isArray(config.hooks[event])) config.hooks[event] = [];
  config.hooks[event].push(matcher ? { matcher, hooks: [handler] } : { hooks: [handler] });
};

// 文件预留提醒只挂在编辑类工具上，避免每次 shell / 读文件都多跑一次 hook。
// Codex 的补丁工具名以实测为准；匹配不上时只是没有提醒，不影响其他功能。
const CLAUDE_EDIT_MATCHER = "Edit|Write|MultiEdit|NotebookEdit";
const CODEX_EDIT_MATCHER = "apply_patch|Edit|Write";

// Claude：同步 hook 维护注册表；asyncRewake watcher 负责投递（单例锁保证同时只有一个）。
// watcher 只挂 SessionStart / Stop，不挂 UserPromptSubmit：由 UserPromptSubmit 拉起的 watcher
// 在回合中途 exit 2 时，Claude Code 会显示成 "Stop hook blocking error from command
// UserPromptSubmit"，像报错。Stop 拉起的 watcher 会一直活过下一个忙碌回合，中途投递照常，
// 显示为正常的 "Stop hook feedback"；watcher 超时退出后，用户开口时信箱里已有的消息由同步
// hook 注入，回合中新到的消息在回合结束（Stop 重新挂上 watcher）时投递。
//
// 选项决定装哪些：关闭"自动唤醒"时不装 watcher（消息只在用户开口时带入）；关闭"编辑前预留拦截"
// 时不装 PreToolUse（每次编辑少跑一次 hook）。hook / watcher 自己也会再读一次选项兜底。
export const claudeHookPlan = (options = DEFAULT_OPTIONS) => [
  ...["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"].map((event) => ({
    event, handler: { type: "command", command: bridgeCommand("Claude", "hook"), timeout: 10 }
  })),
  ...(options.editGuard ? [{
    event: "PreToolUse",
    matcher: CLAUDE_EDIT_MATCHER,
    handler: { type: "command", command: bridgeCommand("Claude", "hook"), timeout: 10 }
  }] : []),
  ...(options.wake ? ["SessionStart", "Stop"].map((event) => ({
    event,
    handler: { type: "command", command: bridgeCommand("Claude", "watch"), asyncRewake: true, timeout: 3600 }
  })) : [])
];

export const codexHookPlan = (options = DEFAULT_OPTIONS) => [
  ...["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"].map((event) => ({
    event, handler: { type: "command", command: bridgeCommand("Codex", "hook"), timeout: 10 }
  })),
  ...(options.editGuard ? [{
    event: "PreToolUse",
    matcher: CODEX_EDIT_MATCHER,
    handler: { type: "command", command: bridgeCommand("Codex", "hook"), timeout: 10 }
  }] : [])
];

// Claude 的工具放行写在 settings.json 的 permissions.allow 里，条目形如 mcp__cc-bridge__send_message。
// 只增删这个前缀下的条目（含旧名 cc-pets-bus），不碰用户其他的放行规则。
const MANAGED_ALLOW = new RegExp(`^mcp__(?:${[MCP_NAME, ...LEGACY_MCP_NAMES].map((name) =>
  name.replace(/[-]/g, "\\-")).join("|")})__[a-z_]+$`);

const applyClaudeAllow = (config, tools) => {
  const permissions = config.permissions && typeof config.permissions === "object" && !Array.isArray(config.permissions)
    ? config.permissions : null;
  const current = Array.isArray(permissions?.allow) ? permissions.allow : [];
  const kept = current.filter((entry) => !(typeof entry === "string" && MANAGED_ALLOW.test(entry)));
  const next = [...kept, ...tools.map((tool) => `mcp__${MCP_NAME}__${tool}`)];
  if (next.length > 0) {
    config.permissions = { ...(permissions ?? {}), allow: next };
  } else if (permissions) {
    delete permissions.allow;
    if (Object.keys(permissions).length === 0) delete config.permissions;
  }
  return config;
};

const updateJsonHooks = (file, plan, claudeAllow) => {
  const config = stripBridgeHooks(readJsonConfig(file));
  for (const { event, handler, matcher } of plan) addHook(config, event, handler, matcher);
  if (claudeAllow) applyClaudeAllow(config, claudeAllow);
  writeJsonConfig(file, config);
};

const removeJsonHooks = (file, { claudeAllow = false } = {}) => {
  if (!fs.existsSync(file)) return false;
  const original = fs.readFileSync(file, "utf8");
  const config = stripBridgeHooks(readJsonConfig(file));
  if (claudeAllow) applyClaudeAllow(config, []);
  const updated = `${JSON.stringify(config, null, 2)}\n`;
  if (updated === original) return false;
  writeJsonConfig(file, config);
  return true;
};

const runQuietly = (executable, args) => {
  try {
    execFileSync(executable, args, { stdio: ["ignore", "pipe", "pipe"], timeout: 60_000 });
    return true;
  } catch {
    return false;
  }
};

const mcpCommand = () => ["--", process.execPath, cliPath, "mcp"];

// MCP 进程的环境会被 CLI 裁剪，PATH 里不一定找得到 codex；投递到 Codex 需要它，
// 注册时把安装时解析到的绝对路径固定下来。
const mcpEnvironment = () => {
  const codex = resolveRealExecutable("codex", "CODEX_REAL_BIN");
  return codex ? [`CODEX_REAL_BIN=${codex}`] : [];
};

const claudeMcpAddArgs = () => [
  "mcp", "add", "--scope", "user", MCP_NAME,
  ...mcpEnvironment().flatMap((pair) => ["-e", pair]),
  ...mcpCommand()
];

const codexMcpAddArgs = () => [
  "mcp", "add", MCP_NAME,
  ...mcpEnvironment().flatMap((pair) => ["--env", pair]),
  ...mcpCommand()
];

// ---------------------------------------------------------------------------
// Codex 工具审批：Codex 默认每次 MCP 调用都要审批，approval_policy=never 时直接报错
// （实测）。用户选择放开时，只在 config.toml 末尾追加一段带标记的块，移除时整段删掉。

const codexApprovalBlock = (tools) => [
  TOML_START,
  t("# Written by cc-pets bridge enable / configure; cc-pets bridge disable removes it."),
  ...tools.flatMap((tool) => [
    `[mcp_servers.${MCP_NAME}.tools.${tool}]`,
    'approval_mode = "approve"',
    ""
  ]),
  TOML_END
].join("\n");

const stripTomlBlock = (text) => [[TOML_START, TOML_END], ...LEGACY_TOML_BLOCKS].reduce(
  (current, [start, end]) => current.replace(new RegExp(`\\n?${start}[\\s\\S]*?${end}\\n?`, "g"), "\n"), text)
  .replace(/\n{3,}/g, "\n\n");

const setCodexApproval = (tools) => {
  const file = path.join(codexHome(), "config.toml");
  const original = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
  let updated = stripTomlBlock(original).replace(/\s*$/, "\n");
  if (tools.length > 0) updated += `\n${codexApprovalBlock(tools)}\n`;
  if (updated === original) return;
  const temporary = `${file}.cc-bridge.tmp`;
  fs.writeFileSync(temporary, updated, { mode: fs.existsSync(file) ? fs.statSync(file).mode & 0o777 : 0o600 });
  fs.renameSync(temporary, file);
};

// ---------------------------------------------------------------------------

// 自动唤醒 Codex 依赖 `codex queue`。不支持时 CC Bridge 照样能用（消息进信箱），只是对方要
// check_inbox 或等下次输入才收到，开启时就说清楚，免得用户以为"发了没反应"。
export const describeCodexQueue = (probe) => {
  const version = probe.version ? t(" ({version})", { version: probe.version }) : "";
  switch (probe.status) {
    case "supported":
      return null;
    case "unsupported":
      return t("This Codex{version} doesn't support codex queue, so messages to Codex can't wake it; they go to its inbox ", { version }) +
        t("and are picked up via check_inbox or with the next input. Upgrading Codex enables wake-up without re-enabling CC Bridge.");
    case "missing":
      return t("codex executable not found, so messages to Codex can only go to its inbox; set CODEX_REAL_BIN and run cc-pets bridge enable.");
    default:
      return t("Couldn't tell whether Codex supports codex queue; failed deliveries fall back to the inbox.");
  }
};

// registerMcp=false 用于只改选项（桌宠开关、cc-pets bridge configure）：不必重跑 claude / codex mcp add。
export const install = ({ options: rawOptions = DEFAULT_OPTIONS, registerMcp = process.env.CC_BRIDGE_SKIP_MCP !== "1" } = {}) => {
  const options = normalizeOptions(rawOptions);
  const report = [];
  if (detectClaudeCLI()) {
    updateJsonHooks(path.join(claudeHome(), "settings.json"), claudeHookPlan(options), options.claudeAllow);
    report.push(t("Claude Code hooks written to {path}", { path: path.join(claudeHome(), "settings.json") }));
    report.push(options.claudeAllow.length > 0
      ? t("Claude Code allows these tools without asking: {claudeAllow}", { claudeAllow: options.claudeAllow.join(", ") })
      : t("In Claude Code, cc-bridge tools follow your permission settings."));
    if (registerMcp) {
      const claude = resolveRealExecutable("claude", "CLAUDE_REAL_BIN");
      for (const name of [MCP_NAME, ...LEGACY_MCP_NAMES]) {
        runQuietly(claude || "claude", ["mcp", "remove", "--scope", "user", name]);
      }
      const ok = claude && runQuietly(claude, claudeMcpAddArgs());
      report.push(ok
        ? t("Claude Code MCP registered: {MCP_NAME} (on first use, Claude asks according to your permission settings)", { MCP_NAME })
        : t("Claude Code MCP registration failed. Run manually: claude {shellQuote}", { shellQuote: claudeMcpAddArgs().map(shellQuote).join(" ") }));
    }
  } else {
    report.push(t("Claude Code CLI not detected, skipped."));
  }

  if (detectCodexCLI()) {
    fs.mkdirSync(codexHome(), { recursive: true });
    updateJsonHooks(path.join(codexHome(), "hooks.json"), codexHookPlan(options));
    report.push(t("Codex hooks written to {path}. Next time you start Codex, run /hooks and trust the cc-pets bridge hooks.", { path: path.join(codexHome(), "hooks.json") }));
    if (registerMcp) {
      const codex = resolveRealExecutable("codex", "CODEX_REAL_BIN");
      for (const name of [MCP_NAME, ...LEGACY_MCP_NAMES]) runQuietly(codex || "codex", ["mcp", "remove", name]);
      const ok = codex && runQuietly(codex, codexMcpAddArgs());
      report.push(ok
        ? t("Codex MCP registered: {MCP_NAME}", { MCP_NAME })
        : t("Codex MCP registration failed. Run manually: codex {shellQuote}", { shellQuote: codexMcpAddArgs().map(shellQuote).join(" ") }));
      // 只在 enable / refresh 时探测：configure 由桌宠菜单开关触发，不值得每次多拉起两次 codex。
      if (options.wake) {
        const queueNotice = describeCodexQueue(probeCodexQueue(codex));
        if (queueNotice) report.push(queueNotice);
      }
    }
    setCodexApproval(options.codexApprove);
    report.push(options.codexApprove.length > 0
      ? t("Codex auto-approves these tools: {codexApprove} (restart Codex sessions to apply)", { codexApprove: options.codexApprove.join(", ") })
      : t("cc-bridge tools keep Codex's default approvals (calls fail under approval_policy=never; allow them with --codex-approve)."));
  } else {
    report.push(t("Codex CLI not detected, skipped."));
  }
  return report;
};

export const uninstall = ({ unregisterMcp = process.env.CC_BRIDGE_SKIP_MCP !== "1" } = {}) => {
  const report = [];
  if (removeJsonHooks(path.join(claudeHome(), "settings.json"), { claudeAllow: true })) {
    report.push(t("Removed the cc-bridge hooks and tool permissions from Claude Code."));
  }
  if (removeJsonHooks(path.join(codexHome(), "hooks.json"))) report.push(t("Removed the cc-bridge hooks from Codex."));
  if (fs.existsSync(path.join(codexHome(), "config.toml"))) setCodexApproval([]);
  if (unregisterMcp) {
    const claude = resolveRealExecutable("claude", "CLAUDE_REAL_BIN");
    for (const name of [MCP_NAME, ...LEGACY_MCP_NAMES]) {
      if (claude && runQuietly(claude, ["mcp", "remove", "--scope", "user", name])) report.push(t("Removed Claude Code MCP: {name}.", { name }));
    }
    const codex = resolveRealExecutable("codex", "CODEX_REAL_BIN");
    for (const name of [MCP_NAME, ...LEGACY_MCP_NAMES]) {
      if (codex && runQuietly(codex, ["mcp", "remove", name])) report.push(t("Removed Codex MCP: {name}.", { name }));
    }
  }
  return report;
};
