// 进程探测：存活判断、沿进程树找到所属的 Claude / Codex 进程。
//
// 身份判定不信任调用方自报——Codex 的 MCP 进程拿不到 CODEX_THREAD_ID，只能靠
// "我的祖先里哪个是 codex 进程"反查注册表；hook 进程也用同一套逻辑补记 pid，
// 两边落到同一个 pid 上才对得上。

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const isProcessAlive = (pid) => {
  if (!Number.isInteger(pid) || pid <= 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM";
  }
};

const processInfo = (pid) => {
  try {
    const output = execFileSync("/bin/ps", ["-o", "ppid=,command=", "-p", String(pid)],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    const match = output.match(/^(\d+)\s+(.*)$/s);
    return match ? { ppid: Number(match[1]), command: match[2] } : null;
  } catch {
    return null;
  }
};

export const processCommand = (pid) => processInfo(pid)?.command ?? null;

// CLI 进程的控制终端，如 "ttys003"。hook 进程自己的 stdin 是管道，只能看宿主 CLI 进程的。
export const processTty = (pid) => {
  if (!Number.isInteger(pid) || pid <= 1) return null;
  try {
    const tty = execFileSync("/bin/ps", ["-o", "tty=", "-p", String(pid)],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    if (!tty || tty === "??" || tty === "?") return null;
    return tty.startsWith("tty") ? tty : `tty${tty}`;
  } catch {
    return null;
  }
};

// 只看可执行文件本身，不看参数：参数里出现 "claude" / "codex" 的进程太多了
// （比如 tmux new-session "codex …"、编辑器打开的某个路径）。
const executableOf = (command) => (command || "").split(/\s+/)[0] || "";

const PROVIDER_MATCHERS = {
  // Codex 的 npm 包是 node 包装器 + 原生二进制；hook 和 MCP 进程的直接祖先都是原生二进制，
  // 取离自己最近的那个，两边才能落到同一个 pid。
  Codex: (command) => {
    const executable = executableOf(command);
    return path.basename(executable) === "codex" || /\/codex-[a-z0-9-]+\/vendor\//.test(executable);
  },
  Claude: (command) => {
    const executable = executableOf(command);
    return path.basename(executable) === "claude" ||
      /@anthropic-ai\/claude-code\//.test(executable) ||
      /@anthropic-ai\/claude-code\//.test((command || "").split(/\s+/)[1] || "");
  }
};

export const commandMatchesProvider = (provider, command) =>
  Boolean(PROVIDER_MATCHERS[provider]?.(command));

// 返回离 startPid 最近的 Claude / Codex 祖先进程。取"最近"而不是"某一种"：
// 在 Claude 的 Bash 里再起一个 codex，里面的 MCP 进程属于那个 codex，而不是外层 Claude。
export const findAgentAncestor = (startPid = process.ppid, maximumDepth = 12) => {
  // 测试 / 诊断覆盖："Codex:1234"。测试本身常跑在某个 Claude 会话的 Bash 里，
  // 不覆盖的话会沿进程树认到那个真实会话头上。
  const forced = (process.env.CC_BRIDGE_AGENT || "").match(/^(Claude|Codex):(\d+)$/);
  if (forced) return { provider: forced[1], pid: Number(forced[2]) };
  let pid = startPid;
  for (let depth = 0; depth < maximumDepth && pid > 1; depth += 1) {
    const info = processInfo(pid);
    if (!info) return null;
    for (const [provider, matches] of Object.entries(PROVIDER_MATCHERS)) {
      if (matches(info.command)) return { provider, pid };
    }
    pid = info.ppid;
  }
  return null;
};

// 会话是否在线：有 pid 时以"进程还在且仍是同一种 CLI"为准（防 pid 复用）；
// 没有 pid 的记录退回到 6 小时活动窗口，与桌宠"没有 pid 文件就看最近事件"的思路一致。
const STALE_WITHOUT_PID_MS = 6 * 60 * 60 * 1000;

export const isSessionLive = (session, now = Date.now()) => {
  if (!session || session.status === "gone") return false;
  if (Number.isInteger(session.pid)) {
    if (!isProcessAlive(session.pid)) return false;
    const command = processCommand(session.pid);
    return command === null || commandMatchesProvider(session.provider, command);
  }
  return now - (session.updatedAt || 0) < STALE_WITHOUT_PID_MS;
};

// 找真实的 codex 可执行文件，跳过 cc-pets 自己的 shim（与 bin/codex-with-pet 同一规则）。
export const resolveRealExecutable = (name, realBinVariable) => {
  const forced = process.env[realBinVariable];
  if (forced) return forced;
  const shim = path.resolve(process.env.CC_PETS_SHIM_DIR || path.join(os.homedir(), ".cc-pets/shims"));
  for (const entry of (process.env.PATH || "").split(path.delimiter)) {
    if (!entry) continue;
    let resolvedEntry;
    try {
      resolvedEntry = fs.realpathSync(entry);
    } catch {
      resolvedEntry = path.resolve(entry);
    }
    if (resolvedEntry === shim) continue;
    const candidate = path.join(entry, name);
    try {
      const stats = fs.statSync(candidate);
      if (!stats.isFile() || (stats.mode & 0o111) === 0) continue;
      const real = fs.realpathSync(candidate);
      if (path.dirname(real) === shim || /-with-pet$/.test(path.basename(real))) continue;
      return candidate;
    } catch {
      // 断链或没权限的候选跳过。
    }
  }
  return null;
};
