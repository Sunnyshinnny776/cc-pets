// Claude 端的投递者：以 asyncRewake hook 运行，等信箱来消息后 exit 2 唤醒会话。
//
// 实测（Claude Code 2.1.281）：
//   - asyncRewake hook 以 exit 2 退出时，stderr 作为系统提醒进入会话；会话空闲会被唤醒，
//     忙碌则注入当前回合；
//   - hook 的 timeout 会被强制执行，所以 watcher 在超时前主动退出，下一次 SessionStart /
//     UserPromptSubmit / Stop 事件再重新挂上；
//   - 会话退出时 hook 子进程会被清理。
//
// 每个会话只保留一个 watcher（锁文件），否则多个 watcher 会抢同一个信箱、重复唤醒。

import fs from "node:fs";
import { formatEnvelope } from "./core.mjs";
import { currentOptions } from "./options.mjs";
import { isProcessAlive } from "./process.mjs";
import { acquireLock, claimInbox, isBridgeEnabled, safeSessionId, updateReceipt } from "./store.mjs";

// 安装时 hook 的 timeout 是 3600 秒，这里留 5 分钟余量主动退出，保证锁由自己释放。
const DEFAULT_WATCH_SECONDS = 3300;
const DEFAULT_POLL_MS = 1000;

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

export const runWatch = async (rawInput, environment = process.env) => {
  // 关闭"自动唤醒"后 watcher 本不会被安装；配置还没刷新到对方 CLI 时在这里兜底。
  if (!isBridgeEnabled() || !currentOptions().wake) return 0;
  let payload;
  try {
    payload = JSON.parse(rawInput);
  } catch {
    return 0;
  }
  const sessionId = safeSessionId(payload?.session_id);
  if (!sessionId) return 0;

  const release = acquireLock(`watch-${sessionId}`, isProcessAlive);
  if (!release) return 0;

  const seconds = Number(environment.CC_BRIDGE_WATCH_SECONDS) || DEFAULT_WATCH_SECONDS;
  const pollMs = Number(environment.CC_BRIDGE_POLL_MS) || DEFAULT_POLL_MS;
  const deadline = Date.now() + seconds * 1000;
  const parent = process.ppid;
  try {
    while (Date.now() < deadline) {
      // 宿主会话已经没了（被 kill -9 等，没来得及清理子进程）就别再占着锁。
      if (!isProcessAlive(parent)) return 0;
      const messages = claimInbox(sessionId);
      if (messages.length > 0) {
        for (const message of messages) {
          updateReceipt(message.id, { status: "delivered", transport: { kind: "claude-rewake" } });
        }
        process.stderr.write(`${messages.map(formatEnvelope).join("\n\n")}\n`);
        return 2;
      }
      await sleep(pollMs);
    }
    return 0;
  } finally {
    release();
  }
};

export const main = async () => {
  try {
    return await runWatch(fs.readFileSync(0, "utf8"));
  } catch {
    return 0;
  }
};
