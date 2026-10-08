#!/usr/bin/env node
// `cc-pets bridge <子命令>` 的入口。
//
// 面向用户：enable / disable / status / list / send / inbox
// 面向 CLI 集成（由 hooks / MCP 配置调用）：hook / watch / mcp / notify-idle

import {
  describeSession, identifySelf, liveSessions, receiptSummary, resolveTarget, sendIdleNotices,
  sendMessage, formatEnvelope
} from "./core.mjs";
import { describeCodexQueue, install, uninstall } from "./install.mjs";
import { probeCodexQueue } from "./process.mjs";
import { detectCodexCLI } from "../detect-cli.mjs";
import { DEFAULT_OPTIONS, currentOptions, describeOptions, mergeOptionFlags, normalizeOptions } from "./options.mjs";
import { fileURLToPath } from "node:url";
import { activeReservations, describeReservation } from "./reservations.mjs";
import {
  bridgeDirectory, claimInbox, isBridgeEnabled, listReceipts, pendingCount, migrateLegacyFlag, readBridgeOptions, readSession, renameSession,
  setBridgeEnabled, takeIdleSubscriptions, updateReceipt, writeCliLocator
} from "./store.mjs";
import { t } from "../i18n.mjs";

const recordCliLocation = () => writeCliLocator(fileURLToPath(import.meta.url));

const USAGE = t(`Usage: cc-pets bridge <command>

  enable [options]       Turn on CC Bridge: write Claude Code / Codex hooks and register MCP
  configure [options]    Change options while enabled (doesn't re-register MCP)
  disable                Turn off and remove all CC Bridge integrations
  status                 Show whether it's on and which sessions are online
  list                   List online sessions
  send <to> <message…>   Send as the current session (run inside an Agent session, or use --from)
  name <new-name>        Rename the current session (run inside an Agent session, or use --from)
  inbox                  Read the current session's inbox (for debugging)

Options (anything omitted keeps its current value):
  --approve=<list>       Auto-approve in both Codex and Claude
  --codex-approve=<list> Auto-approve in Codex only
  --claude-allow=<list>  Allow without asking in Claude only
                         Use groups view, send, reserve, name, or tool names; pass an empty value to clear
  --wake=on|off          Wake idle sessions automatically (off saves tokens; messages arrive with the next user input)
  --edit-guard=on|off    Pause once when editing a file another session reserved

Name a session at launch: CC_BRIDGE_NAME=frontend claude (or codex)

CC Bridge lets local Claude Code and Codex terminal sessions find, message and wake each other.
Message bodies are stored in a local temp directory readable only by you. Off by default.`);

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
    console.log(t("No sessions online."));
    return;
  }
  for (const session of sessions) {
    console.log(`${describeSession(session)}  ${session.provider}  ${session.status || "-"}  pid=${session.pid ?? "-"}  ${session.tty || "-"}  ${session.cwd || "-"}  ${t("pending")}=${pendingCount(session.session)}`);
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
  if (!self) throw new Error(t("Can't identify the current session; when debugging in a plain terminal, use --from <session-name>."));
  return self;
};

const commands = {
  async enable(args) {
    const options = mergeOptionFlags(isBridgeEnabled() ? currentOptions() : DEFAULT_OPTIONS, readOptionFlags(args));
    for (const line of install({ options })) console.log(line);
    setBridgeEnabled(true, options);
    recordCliLocation();
    console.log(t("CC Bridge is on."));
    console.log(t("- Running Claude Code sessions hot-reload the hooks and start receiving messages right away, but only get the cc-bridge tools after a restart (until then, reply with cc-pets bridge send)."));
    console.log(t("- Running Codex sessions need a restart, then trust the cc-pets bridge hooks in /hooks."));
    return 0;
  },

  // 只改选项：重写 hooks、Codex 审批块、Claude 放行规则，不重跑 claude / codex mcp add，
  // 所以很快。桌宠菜单的开关走这条路。
  async configure(args) {
    if (!isBridgeEnabled()) throw new Error(t("CC Bridge is off. Run cc-pets bridge enable first."));
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
    console.log(t("CC Bridge is off."));
    return 0;
  },

  async status() {
    console.log(t("CC Bridge: {state}", { state: isBridgeEnabled() ? t("Enabled") : t("Disabled") }));
    if (isBridgeEnabled()) {
      for (const line of describeOptions(currentOptions())) console.log(`  ${line}`);
      if (currentOptions().wake && detectCodexCLI()) {
        console.log(`  ${describeCodexQueue(probeCodexQueue()) ?? t("Codex supports codex queue, so it can be woken automatically.")}`);
      }
    }
    console.log(t("State directory: {bridgeDirectory}", { bridgeDirectory: bridgeDirectory() }));
    printSessions();
    const reservations = activeReservations();
    if (reservations.length > 0) {
      console.log(t("\nFile reservations:"));
      for (const reservation of reservations) console.log(`  ${reservation.root}  ${describeReservation(reservation)}`);
    }
    const receipts = listReceipts().sort((left, right) => right.createdAt - left.createdAt).slice(0, 5);
    if (receipts.length > 0) {
      console.log(t("\nRecent messages:"));
      for (const receipt of receipts) {
        const from = receipt.from.system ? "cc-pets" : receipt.from.name;
        console.log(`  ${receipt.id}  ${from} → ${receipt.to.name}  ${receipt.status}${receipt.reason ? t(" ({reason})", { reason: receipt.reason }) : ""}`);
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
    if (!to || words.length === 0) throw new Error(t("Usage: cc-pets bridge send <to> <message…>"));
    const target = resolveTarget(to, liveSessions());
    if (target.error) throw new Error(target.error);
    const result = await sendMessage({ from, to: target.session, body: words.join(" ") });
    if (result.error) throw new Error(result.error);
    console.log(receiptSummary(result.receipt, target.session));
    return result.receipt.status === "undeliverable" ? 1 : 0;
  },

  async name(args) {
    const self = selfOrFrom(args);
    if (!args[0]) throw new Error(t("Usage: cc-pets bridge name <new-name>"));
    const result = renameSession(self.session, args[0], liveSessions());
    if (result.error) throw new Error(result.error);
    console.log(t("Renamed {previous} to {session}.", { previous: result.previous, session: describeSession(result.session) }));
    return 0;
  },

  async inbox(args) {
    const self = selfOrFrom(args);
    const messages = claimInbox(self.session);
    for (const message of messages) {
      updateReceipt(message.id, { status: "delivered", transport: { kind: "check-inbox" } });
    }
    console.log(messages.length > 0 ? messages.map(formatEnvelope).join("\n\n") : t("No new messages in the inbox."));
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
    console.error(t("Unknown command: {command}\n\n{USAGE}", { command, USAGE }));
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
