// CC Bridge 的用户选项：保存在开关文件（~/.cc-pets/bridge-enabled）里，
// 由 `cc-pets bridge enable / configure` 写入，桌宠菜单也通过这两个命令修改。
//
//   codexApprove  Codex 中免审批的工具（写入 config.toml 的带标记块）
//   claudeAllow   Claude Code 中免确认的工具（写入 settings.json 的 permissions.allow）
//   wake          自动唤醒空闲会话；关闭后消息只进信箱，等对方下次收到用户输入时带入（省 token）
//   editGuard     编辑他人预留的文件时暂停一次（首次拦截、重试放行）

import { isBridgeEnabled, readBridgeOptions } from "./store.mjs";

// 桌宠菜单按用途分组，而不是暴露 7 个工具名。
export const TOOL_GROUPS = {
  view: ["list_agents", "list_reservations", "check_inbox"],
  send: ["send_message"],
  reserve: ["reserve_files", "release_files"],
  name: ["set_name"]
};

export const ALL_TOOLS = Object.values(TOOL_GROUPS).flat();

export const DEFAULT_OPTIONS = Object.freeze({
  codexApprove: [],
  claudeAllow: [],
  wake: true,
  editGuard: true
});

const uniqueTools = (tools) => ALL_TOOLS.filter((tool) => tools.includes(tool));

export const normalizeOptions = (raw = {}) => ({
  codexApprove: Array.isArray(raw.codexApprove) ? uniqueTools(raw.codexApprove) : [],
  claudeAllow: Array.isArray(raw.claudeAllow) ? uniqueTools(raw.claudeAllow) : [],
  wake: raw.wake !== false,
  editGuard: raw.editGuard !== false
});

// 已开启时取保存的选项，否则取默认值。hook / watcher 每次都读，文件很小。
export const currentOptions = () => (isBridgeEnabled() ? normalizeOptions(readBridgeOptions()) : { ...DEFAULT_OPTIONS });

// "view,send_message" → 展开分组、校验工具名。空字符串表示清空。
export const parseToolList = (text, flag) => {
  const tools = [];
  const unknown = [];
  for (const item of String(text ?? "").split(",").map((entry) => entry.trim()).filter(Boolean)) {
    if (TOOL_GROUPS[item]) {
      tools.push(...TOOL_GROUPS[item]);
    } else if (ALL_TOOLS.includes(item)) {
      tools.push(item);
    } else {
      unknown.push(item);
    }
  }
  if (unknown.length > 0) {
    throw new Error(`${flag} 只接受分组 ${Object.keys(TOOL_GROUPS).join(", ")} 或工具 ${ALL_TOOLS.join(", ")}，收到：${unknown.join(", ")}`);
  }
  return uniqueTools(tools);
};

export const parseSwitch = (text, flag) => {
  const value = String(text ?? "").trim().toLowerCase();
  if (["on", "true", "1", "yes"].includes(value)) return true;
  if (["off", "false", "0", "no"].includes(value)) return false;
  throw new Error(`${flag} 只接受 on / off，收到：${text}`);
};

// 在 base 之上叠加命令行里给出的选项；没给的保持原值。
export const mergeOptionFlags = (base, flags) => {
  const next = { ...normalizeOptions(base) };
  if (flags.approve !== undefined) {
    const tools = parseToolList(flags.approve, "--approve");
    next.codexApprove = tools;
    next.claudeAllow = tools;
  }
  if (flags.codexApprove !== undefined) next.codexApprove = parseToolList(flags.codexApprove, "--codex-approve");
  if (flags.claudeAllow !== undefined) next.claudeAllow = parseToolList(flags.claudeAllow, "--claude-allow");
  if (flags.wake !== undefined) next.wake = parseSwitch(flags.wake, "--wake");
  if (flags.editGuard !== undefined) next.editGuard = parseSwitch(flags.editGuard, "--edit-guard");
  return next;
};

export const describeOptions = (options) => [
  `Codex 免审批：${options.codexApprove.length > 0 ? options.codexApprove.join(", ") : "无"}`,
  `Claude 免确认：${options.claudeAllow.length > 0 ? options.claudeAllow.join(", ") : "无"}`,
  `自动唤醒空闲会话：${options.wake ? "开" : "关"}`,
  `编辑前预留拦截：${options.editGuard ? "开" : "关"}`
];
