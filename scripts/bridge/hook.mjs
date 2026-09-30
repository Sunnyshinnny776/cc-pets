// 同步 hook：维护会话注册表，并在用户输入时兜底注入信箱里的待处理消息。
//
// 安装时以 `CC_BRIDGE_HOOK=<Claude|Codex> node …/cli.mjs hook` 注册到两边的
// SessionStart / UserPromptSubmit / Stop / SessionEnd。任何异常都吞掉并 exit 0：
// 这是别人 CLI 的关键路径，CC Bridge 出错不能拖垮对方的一轮对话。

import { spawn } from "node:child_process";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { PROVIDERS, formatEnvelope, liveSessions } from "./core.mjs";
import { currentOptions } from "./options.mjs";
import { findAgentAncestor, processTty } from "./process.mjs";
import {
  acknowledgeReservation, describeReservation, editedFilesFromToolInput, findForeignReservations, isAcknowledged,
  releaseSessionReservations
} from "./reservations.mjs";
import {
  abandonInbox, claimInbox, hasIdleSubscriptions, isBridgeEnabled, pruneReceipts, readSession, removeSession,
  safeSessionId, updateReceipt, upsertSession
} from "./store.mjs";

const cliPath = fileURLToPath(new URL("./cli.mjs", import.meta.url));

const STATUS_BY_EVENT = {
  SessionStart: "idle",
  UserPromptSubmit: "busy",
  Stop: "idle"
};

const agentPid = (provider) => {
  const ancestor = findAgentAncestor();
  return ancestor && ancestor.provider === provider ? ancestor.pid : undefined;
};

// 用户开口时把信箱里的消息一并带进这一轮。Claude 平时由 watcher 负责投递，这里只是
// watcher 超时退出后的空窗期兜底；Codex 平时走 codex queue，这里兜的是 queue 不可用
// 时退回信箱的消息。
const injectPending = (sessionId, eventName) => {
  const messages = claimInbox(sessionId);
  if (messages.length === 0) return null;
  for (const message of messages) {
    updateReceipt(message.id, { status: "delivered", transport: { kind: "prompt-inject" } });
  }
  return {
    hookSpecificOutput: {
      hookEventName: eventName,
      additionalContext: messages.map(formatEnvelope).join("\n\n")
    }
  };
};

// 首次拦截、重试放行：本会话第一次编辑某处他人预留的文件时返回 deny 并说明原因，同时记下
// "已提醒"；重试同一操作时这处预留已确认，直接放行。用 deny 而不是只注入 additionalContext：
// 实测 Codex 的 additionalContext 在工具调用发出之后才到达，拦不住这次编辑，模型也会忽略。
// 不用 "ask"：Codex 的 PreToolUse 只支持 allow / deny，两边行为要一致。
const checkReservations = (payload, sessionId) => {
  const files = editedFilesFromToolInput(payload.tool_input);
  const cwd = typeof payload.cwd === "string" ? payload.cwd : readSession(sessionId)?.cwd;
  if (files.length === 0 || !cwd) return null;
  const pending = findForeignReservations({ sessionId, cwd, filePaths: files })
    .filter((hit) => !isAcknowledged(hit.reservation, sessionId));
  if (pending.length === 0) return null;
  for (const hit of pending) acknowledgeReservation(hit.reservation.id, sessionId);
  const lines = pending.map((hit) => `- ${hit.file}：${describeReservation(hit.reservation)}`);
  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: [
        "[cc-bridge 文件预留] 这次编辑先暂停一次：以下文件已被本机另一个 Agent 会话预留。",
        ...lines,
        "这不是权限拒绝，而是一次性提醒：如果这次修改是用户明确要求的，直接重试同一操作即可放行，" +
          "之后不会再因这处预留拦你；否则请先用 send_message 与对方协调，或改做其他部分。",
        // 实测 Codex 重试放行后只回复"已创建"，用户不知道自己改的是别人正在改的区域。
        "如果重试放行，请在给用户的回复里说明：这些文件正被上面的会话预留（写明会话名和原因），" +
          "以便用户判断是否需要与对方协调。"
      ].join("\n")
    }
  };
};

// 空闲通知可能要调 codex queue（秒级），放到脱离的子进程里做，
// 不让 Stop hook 拖慢对方回合的收尾。
const notifyIdleInBackground = (sessionId) => {
  const child = spawn(process.execPath, [cliPath, "notify-idle", sessionId], {
    detached: true, stdio: "ignore", env: process.env
  });
  child.unref();
};

export const runHook = (rawInput, environment = process.env) => {
  if (!isBridgeEnabled()) return null;
  const provider = environment.CC_BRIDGE_HOOK;
  if (!PROVIDERS.includes(provider)) return null;
  let payload;
  try {
    payload = JSON.parse(rawInput);
  } catch {
    return null;
  }
  const event = payload?.hook_event_name;
  const sessionId = safeSessionId(payload?.session_id);
  if (!event || !sessionId) return null;

  if (event === "SessionEnd") {
    removeSession(sessionId);
    abandonInbox(sessionId);
    releaseSessionReservations(sessionId);
    return null;
  }

  // 编辑前检查文件预留（首次拦截、重试放行）。不更新注册表——这个 hook 每次编辑都会跑，保持最轻。
  if (event === "PreToolUse") return currentOptions().editGuard ? checkReservations(payload, sessionId) : null;

  const status = STATUS_BY_EVENT[event];
  const known = readSession(sessionId);
  // 每次都重新探测：`claude --resume` 会在新进程里沿用同一个 session id。
  const pid = agentPid(provider) ?? known?.pid;
  upsertSession({
    sessionId,
    provider,
    pid,
    cwd: typeof payload.cwd === "string" ? payload.cwd : undefined,
    tty: processTty(pid) ?? undefined,
    status,
    // hook 继承宿主 CLI 的环境：`CC_BRIDGE_NAME=frontend claude` 即以 frontend 注册。
    // 只在首次注册时生效，之后改名走 set_name。
    preferredName: environment.CC_BRIDGE_NAME,
    liveSessions: known ? [] : liveSessions()
  });

  if (event === "SessionStart") {
    pruneReceipts();
    return null;
  }
  if (event === "UserPromptSubmit") return injectPending(sessionId, event);
  if (event === "Stop" && hasIdleSubscriptions(sessionId)) notifyIdleInBackground(sessionId);
  return null;
};

export const main = () => {
  try {
    const output = runHook(fs.readFileSync(0, "utf8"));
    if (output) process.stdout.write(JSON.stringify(output));
  } catch {
    // 见文件头：绝不因为 CC Bridge 的问题让对方 CLI 的 hook 失败。
  }
  return 0;
};
