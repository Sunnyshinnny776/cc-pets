#!/usr/bin/env node
// `cc-pets bridge <子命令>` 的入口。
//
// 面向用户：enable / disable / status / list / send / inbox
// 面向 CLI 集成（由 hooks / MCP 配置调用）：hook / watch / mcp / notify-idle

import {
  describeSession, identifySelf, liveSessions, receiptSummary, resolveTarget, sendIdleNotices,
  sendMessage, formatEnvelope
} from "./core.mjs";
import { install, uninstall } from "./install.mjs";
import { DEFAULT_OPTIONS, currentOptions, describeOptions, mergeOptionFlags, normalizeOptions } from "./options.mjs";
import { fileURLToPath } from "node:url";
import { activeReservations, describeReservation } from "./reservations.mjs";
import {
  bridgeDirectory, claimInbox, isBridgeEnabled, listReceipts, pendingCount, migrateLegacyFlag, readBridgeOptions, readSession, renameSession,
  setBridgeEnabled, takeIdleSubscriptions, updateReceipt, writeCliLocator
} from "./store.mjs";

const recordCliLocation = () => writeCliLocator(fileURLToPath(import.meta.url));

const USAGE = `用法: cc-pets bridge <命令>

  enable [选项]          开启 CC Bridge：写入 Claude Code / Codex hooks 并注册 MCP
  configure [选项]       已开启时只修改选项（不重新注册 MCP）
  disable                关闭并移除所有 CC Bridge 集成
  status                 查看开关状态与在线会话
  list                   列出在线会话
  send <to> <消息…>      以当前会话身份发送（需在 Agent 会话内执行，或用 --from 指定）
  name <新名字>          修改当前会话的名字（需在 Agent 会话内执行，或用 --from 指定）
  inbox                  读取当前会话信箱（调试用）

选项（没给的保持原值）：
  --approve=<列表>       Codex 与 Claude 同时免审批
  --codex-approve=<列表> 只设 Codex 免审批
  --claude-allow=<列表>  只设 Claude 免确认
                         列表可写分组 view, send, reserve, name，或具体工具名；传空值表示清空
  --wake=on|off          自动唤醒空闲会话（关闭可省 token，消息等对方下次收到用户输入时带入）
  --edit-guard=on|off    编辑他人预留的文件时暂停一次

启动时指定会话名：CC_BRIDGE_NAME=frontend claude（或 codex）

CC Bridge 让本机的 Claude Code 与 Codex 终端会话互相发现、发消息、唤醒对方。
消息正文会保存在本机临时目录（仅当前用户可读），默认关闭。`;

const parseFlag = (args, name) => {
  const prefix = `--${name}=`;
  const index = args.findIndex((arg) => arg === `--${name}` || arg.startsWith(prefix));
  if (index < 0) return undefined;
  const [flag] = args.splice(index, 1);
  if (flag.startsWith(prefix)) return flag.slice(prefix.length);
  return args.splice(index, 1)[0];
};

const readOptionFlags = (args) => ({
  approve: parseFlag(args, "approve"),
  codexApprove: parseFlag(args, "codex-approve"),
  claudeAllow: parseFlag(args, "claude-allow"),
  wake: parseFlag(args, "wake"),
  editGuard: parseFlag(args, "edit-guard")
});

const printSessions = () => {
  const sessions = liveSessions();
  if (sessions.length === 0) {
    console.log("没有在线会话。");
    return;
  }
  for (const session of sessions) {
    console.log(`${describeSession(session)}  ${session.provider}  ${session.status || "-"}  pid=${session.pid ?? "-"}  ${session.tty || "-"}  ${session.cwd || "-"}  待投递=${pendingCount(session.session)}`);
  }
};

const selfOrFrom = (args) => {
  const from = parseFlag(args, "from");
  if (from) {
    const resolved = resolveTarget(from, liveSessions());
    if (resolved.error) throw new Error(resolved.error);
    return resolved.session;
  }
  const self = identifySelf();
  if (!self) throw new Error("无法识别当前会话；在普通终端里调试请用 --from <会话名>。");
  return self;
};

const commands = {
  async enable(args) {
    const options = mergeOptionFlags(isBridgeEnabled() ? currentOptions() : DEFAULT_OPTIONS, readOptionFlags(args));
    for (const line of install({ options })) console.log(line);
    setBridgeEnabled(true, options);
    recordCliLocation();
    console.log("CC Bridge 已开启。");
    console.log("- 已在运行的 Claude Code 会话会热加载 hooks、立即开始收消息，但要重启后才有 cc-bridge 工具（期间可用 cc-pets bridge send 回复）。");
    console.log("- 已在运行的 Codex 会话需要重启，并在 /hooks 中信任 cc-pets bridge 的 hooks。");
    return 0;
  },

  // 只改选项：重写 hooks、Codex 审批块、Claude 放行规则，不重跑 claude / codex mcp add，
  // 所以很快。桌宠菜单的开关走这条路。
  async configure(args) {
    if (!isBridgeEnabled()) throw new Error("CC Bridge 未开启，请先执行 cc-pets bridge enable。");
    const options = mergeOptionFlags(currentOptions(), readOptionFlags(args));
    install({ options, registerMcp: false });
    setBridgeEnabled(true, options);
    recordCliLocation();
    for (const line of describeOptions(options)) console.log(line);
    return 0;
  },

  // 安装 / 升级流程调用：已开启时按原选项重写集成（包路径可能变了），未开启时什么都不做。
  async refresh() {
    // 未开启也要写：桌宠菜单的"启用"开关就靠它找到 CLI。
    recordCliLocation();
    if (!isBridgeEnabled()) return 0;
    const options = normalizeOptions(readBridgeOptions());
    for (const line of install({ options })) console.log(line);
    setBridgeEnabled(true, options);
    return 0;
  },

  async disable() {
    for (const line of uninstall()) console.log(line);
    setBridgeEnabled(false);
    console.log("CC Bridge 已关闭。");
    return 0;
  },

  async status() {
    console.log(`CC Bridge：${isBridgeEnabled() ? "已开启" : "未开启"}`);
    if (isBridgeEnabled()) for (const line of describeOptions(currentOptions())) console.log(`  ${line}`);
    console.log(`状态目录：${bridgeDirectory()}`);
    printSessions();
    const reservations = activeReservations();
    if (reservations.length > 0) {
      console.log("\n文件预留：");
      for (const reservation of reservations) console.log(`  ${reservation.root}  ${describeReservation(reservation)}`);
    }
    const receipts = listReceipts().sort((left, right) => right.createdAt - left.createdAt).slice(0, 5);
    if (receipts.length > 0) {
      console.log("\n最近消息：");
      for (const receipt of receipts) {
        const from = receipt.from.system ? "cc-pets" : receipt.from.name;
        console.log(`  ${receipt.id}  ${from} → ${receipt.to.name}  ${receipt.status}${receipt.reason ? `（${receipt.reason}）` : ""}`);
      }
    }
    return 0;
  },

  async list() {
    printSessions();
    return 0;
  },

  async send(args) {
    const from = selfOrFrom(args);
    const [to, ...words] = args;
    if (!to || words.length === 0) throw new Error("用法: cc-pets bridge send <to> <消息…>");
    const target = resolveTarget(to, liveSessions());
    if (target.error) throw new Error(target.error);
    const result = await sendMessage({ from, to: target.session, body: words.join(" ") });
    if (result.error) throw new Error(result.error);
    console.log(receiptSummary(result.receipt, target.session));
    return result.receipt.status === "undeliverable" ? 1 : 0;
  },

  async name(args) {
    const self = selfOrFrom(args);
    if (!args[0]) throw new Error("用法: cc-pets bridge name <新名字>");
    const result = renameSession(self.session, args[0], liveSessions());
    if (result.error) throw new Error(result.error);
    console.log(`已从 ${result.previous} 改名为 ${describeSession(result.session)}。`);
    return 0;
  },

  async inbox(args) {
    const self = selfOrFrom(args);
    const messages = claimInbox(self.session);
    for (const message of messages) {
      updateReceipt(message.id, { status: "delivered", transport: { kind: "check-inbox" } });
    }
    console.log(messages.length > 0 ? messages.map(formatEnvelope).join("\n\n") : "信箱里没有新消息。");
    return 0;
  },

  async hook() {
    return (await import("./hook.mjs")).main();
  },

  async watch() {
    return (await import("./watch.mjs")).main();
  },

  async mcp() {
    return (await import("./mcp-server.mjs")).main();
  },

  // Stop hook 脱离出来的子进程：给订阅了该会话空闲的会话发通知。
  async "notify-idle"(args) {
    if (!isBridgeEnabled()) return 0;
    const target = readSession(args[0]);
    if (!target) return 0;
    const subscribers = takeIdleSubscriptions(target.session);
    if (subscribers.length > 0) await sendIdleNotices(target, subscribers);
    return 0;
  }
};

const run = async () => {
  const [command, ...args] = process.argv.slice(2);
  if (!command || command === "help" || command === "--help" || command === "-h") {
    console.log(USAGE);
    return command ? 0 : 2;
  }
  const handler = commands[command];
  // 集成子命令（hook / watch / mcp）跑在对方 CLI 的关键路径上，不做迁移这类文件操作。
  if (!["hook", "watch", "mcp", "notify-idle"].includes(command)) migrateLegacyFlag();
  if (!handler) {
    console.error(`未知命令：${command}\n\n${USAGE}`);
    return 2;
  }
  try {
    return await handler(args);
  } catch (error) {
    console.error(error.message);
    return 1;
  }
};

process.exitCode = await run();
