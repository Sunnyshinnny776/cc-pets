// CC Bridge 的存储层：会话注册表、信箱、回执、订阅、锁。
//
// 全部是"一条记录一个文件"，状态流转靠同一文件系统内的 rename 完成——rename 是原子的，
// 多个终端的 hook / watcher / MCP 进程同时抢同一条消息时，只有一个能 rename 成功，
// 其余拿到 ENOENT 直接跳过，不需要任何守护进程或数据库锁。
//
// 目录放在 CC_PETS_STATE_DIR（默认 $TMPDIR）下，与桌宠事件流同级：会话本身活不过重启，
// 注册表和未投递的消息也没有跨重启保留的意义。启用开关则放在 ~/.cc-pets 里持久保存。

import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const MESSAGE_BODY_LIMIT = 16 * 1024;
export const MESSAGE_TTL_MS = 24 * 60 * 60 * 1000;
// 同一对会话 10 分钟内来回超过这个数，基本可以断定是两个 Agent 在互相自动回复。
export const PAIR_LIMIT_WINDOW_MS = 10 * 60 * 1000;
export const PAIR_LIMIT_COUNT = 20;
export const SENDER_LIMIT_COUNT = 40;

const uid = () => (typeof process.getuid === "function" ? process.getuid() : 0);

// 不能直接用 os.tmpdir()：它只认 TMPDIR 环境变量，而 Codex 拉起 MCP server 时会裁剪环境，
// 拿不到 TMPDIR 就退回 /tmp，与 hook 写入的目录分家。DARWIN_USER_TEMP_DIR 按用户固定、
// 不依赖环境变量，也正是桌宠原生端 NSTemporaryDirectory() 返回的目录。
let cachedUserTempDirectory;
const userTempDirectory = () => {
  if (cachedUserTempDirectory === undefined) {
    cachedUserTempDirectory = null;
    if (process.platform === "darwin") {
      try {
        const value = execFileSync("/usr/bin/getconf", ["DARWIN_USER_TEMP_DIR"],
          { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
        if (value) cachedUserTempDirectory = value;
      } catch {
        // 退回 os.tmpdir()。
      }
    }
  }
  return cachedUserTempDirectory || os.tmpdir();
};

export const bridgeDirectory = () => path.join(
  process.env.CC_PETS_STATE_DIR || userTempDirectory(), `cc-bridge-${uid()}`);

export const bridgeHomeDirectory = () =>
  process.env.CC_PETS_HOME || path.join(os.homedir(), ".cc-pets");

const enabledFlagPath = () => path.join(bridgeHomeDirectory(), "bridge-enabled");

export const isBridgeEnabled = () => fs.existsSync(enabledFlagPath());

// 桌宠（~/Applications 下的 App）不知道 cc-pets 包装在哪，菜单开关要靠这个文件找到 node 与 CLI。
// 每次安装（bridge refresh）、enable、configure 都会重写，包路径随升级变化也能跟上。
export const writeCliLocator = (cliPath) => {
  fs.mkdirSync(bridgeHomeDirectory(), { recursive: true, mode: 0o700 });
  const file = path.join(bridgeHomeDirectory(), "bridge-cli.json");
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify({ schemaVersion: 1, node: process.execPath, cli: cliPath }, null, 2)}\n`,
    { mode: 0o600 });
  fs.renameSync(temporary, file);
};

// 正式发布前叫过 "Agent Bus"，开关文件是 bus-enabled。迁移成新名字并保留当时的选项，
// 这样 refresh / 卸载能认出"用户开启过"，把旧集成清掉后按原选项重写。
export const migrateLegacyFlag = () => {
  const legacy = path.join(bridgeHomeDirectory(), "bus-enabled");
  if (!fs.existsSync(legacy)) return false;
  if (fs.existsSync(enabledFlagPath())) {
    fs.rmSync(legacy, { force: true });
  } else {
    fs.renameSync(legacy, enabledFlagPath());
  }
  return true;
};

// 开关文件同时保存 enable 时的选项：重装 / 升级后包路径会变，安装流程要用同样的选项
// 重写一遍 hooks 与 MCP 注册（见 cli.mjs 的 refresh）。
export const readBridgeOptions = () => {
  try {
    const parsed = JSON.parse(fs.readFileSync(enabledFlagPath(), "utf8"));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
};

export const setBridgeEnabled = (enabled, options = {}) => {
  if (enabled) {
    fs.mkdirSync(bridgeHomeDirectory(), { recursive: true, mode: 0o700 });
    fs.writeFileSync(enabledFlagPath(),
      `${JSON.stringify({ ...options, enabledAt: new Date().toISOString() }, null, 2)}\n`, { mode: 0o600 });
  } else {
    fs.rmSync(enabledFlagPath(), { force: true });
  }
};

// 目录一律 0700：信箱里是消息正文，同机其他用户不能读，也不能往里塞"任务"。
// 已存在的目录也要校正权限并确认归属，防止有人提前在共享 /tmp 里抢建同名目录。
const ensureDirectory = (directory) => {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const status = fs.lstatSync(directory);
  if (!status.isDirectory() || status.isSymbolicLink()) {
    throw new Error(`${directory} 不是普通目录`);
  }
  if (status.uid !== uid()) throw new Error(`${directory} 不属于当前用户`);
  if ((status.mode & 0o077) !== 0) fs.chmodSync(directory, 0o700);
  return directory;
};

export const bridgePath = (...parts) => {
  const root = ensureDirectory(bridgeDirectory());
  if (parts.length === 0) return root;
  const directory = path.join(root, ...parts.slice(0, -1));
  if (parts.length > 1) ensureDirectory(directory);
  return path.join(directory, parts[parts.length - 1]);
};

export const bridgeSubdirectory = (...parts) => ensureDirectory(path.join(bridgePath(), ...parts));

// session id 会拼进文件路径，只放行 UUID 一类的安全字符，杜绝 ../ 之类的路径穿越。
export const safeSessionId = (value) =>
  typeof value === "string" && /^[A-Za-z0-9._-]{1,128}$/.test(value) && !/^\.+$/.test(value)
    ? value : null;

// 先写同目录临时文件再 rename：读取端永远看不到写了一半的 JSON。
export const writeJsonAtomic = (file, value) => {
  const temporary = `${file}.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, file);
};

export const readJson = (file) => {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
};

const listJson = (directory) => {
  let entries;
  try {
    entries = fs.readdirSync(directory);
  } catch {
    return [];
  }
  return entries.filter((name) => name.endsWith(".json")).sort();
};

// ---------------------------------------------------------------------------
// 会话注册表

export const sessionRef = (sessionId) =>
  crypto.createHash("sha1").update(sessionId).digest("hex").slice(0, 6);

const sessionFile = (sessionId) => path.join(bridgeSubdirectory("sessions"), `${sessionId}.json`);

export const readSession = (sessionId) => {
  const safe = safeSessionId(sessionId);
  return safe ? readJson(sessionFile(safe)) : null;
};

export const listSessions = () => {
  const directory = bridgeSubdirectory("sessions");
  return listJson(directory).map((name) => readJson(path.join(directory, name))).filter(Boolean);
};

export const removeSession = (sessionId) => {
  const safe = safeSessionId(sessionId);
  if (safe) fs.rmSync(sessionFile(safe), { force: true });
};

const projectSlug = (cwd) => {
  const base = path.basename(cwd || "") || "session";
  const slug = base.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  return (slug || "session").slice(0, 32);
};

// 名字是给 Agent 和人看的地址：<provider>-<项目目录名>-<n>。n 取同前缀下在线会话
// 未占用的最小正整数，会话结束后编号可以被复用；ref 由 session id 派生，永不变化，
// 用于重名时消歧。
const allocateName = (provider, cwd, sessionId, liveSessions) => {
  const prefix = `${provider.toLowerCase()}-${projectSlug(cwd)}`;
  const taken = new Set(liveSessions
    .filter((entry) => entry.session !== sessionId)
    .map((entry) => entry.name));
  for (let index = 1; ; index += 1) {
    const candidate = `${prefix}-${index}`;
    if (!taken.has(candidate)) return candidate;
  }
};

// 自定义名字：启动时用 CC_BRIDGE_NAME 指定，或会话里调用 set_name 修改。
// 只允许小写字母、数字和 . _ -，首字符必须是字母或数字，最长 40 个字符——名字会出现在消息头
// 和 Agent 的工具参数里，不能带空格、方括号（与 "名字 [ref]" 语法冲突）或控制字符。
export const normalizeSessionName = (value) => {
  const name = String(value ?? "").trim().toLowerCase();
  return /^[a-z0-9][a-z0-9._-]{0,39}$/.test(name) ? name : null;
};

const nameTakenBy = (name, sessionId, liveSessions) =>
  liveSessions.find((entry) => entry.session !== sessionId && entry.name === name) || null;

// 启动时指定的名字被占用就追加序号（frontend → frontend-2），不让会话因此注册失败。
const allocateCustomName = (name, sessionId, liveSessions) => {
  if (!nameTakenBy(name, sessionId, liveSessions)) return name;
  for (let index = 2; ; index += 1) {
    const candidate = `${name}-${index}`.slice(0, 40);
    if (!nameTakenBy(candidate, sessionId, liveSessions)) return candidate;
  }
};

// liveSessions 由调用方传入（需要进程探测，放在 process.mjs 里做），避免存储层依赖 ps。
export const upsertSession = ({
  sessionId, provider, pid, cwd, tty, status, preferredName, liveSessions = []
}) => {
  const safe = safeSessionId(sessionId);
  if (!safe) return null;
  const now = Date.now();
  const existing = readSession(safe);
  const record = existing || {
    session: safe,
    provider,
    ref: sessionRef(safe),
    startedAt: now
  };
  record.provider = provider || record.provider;
  if (Number.isInteger(pid) && pid > 1) record.pid = pid;
  if (cwd) record.cwd = cwd;
  if (tty) record.tty = tty;
  if (!record.name) {
    const custom = normalizeSessionName(preferredName);
    record.name = custom
      ? allocateCustomName(custom, safe, liveSessions)
      : allocateName(record.provider, record.cwd, safe, liveSessions);
  }
  if (status) record.status = status;
  record.updatedAt = now;
  writeJsonAtomic(sessionFile(safe), record);
  return record;
};

// 会话内改名：名字被其他在线会话占用时直接报错，由调用方换一个，不自动追加序号。
export const renameSession = (sessionId, requestedName, liveSessions) => {
  const record = readSession(sessionId);
  if (!record) return { error: "当前会话尚未注册。" };
  const name = normalizeSessionName(requestedName);
  if (!name) {
    return { error: "名字只能包含小写字母、数字和 . _ -，以字母或数字开头，最长 40 个字符。" };
  }
  const holder = nameTakenBy(name, record.session, liveSessions);
  if (holder) return { error: `名字 ${name} 已被 ${holder.name} [${holder.ref}] 使用，请换一个。` };
  const previous = record.name;
  record.name = name;
  record.updatedAt = Date.now();
  writeJsonAtomic(sessionFile(record.session), record);
  return { session: record, previous };
};

// ---------------------------------------------------------------------------
// 消息

export const newMessageId = () =>
  `m${Date.now().toString(36)}${crypto.randomBytes(5).toString("hex")}`;

const inboxDirectory = (sessionId) => bridgeSubdirectory("inbox", sessionId);
const claimedDirectory = (sessionId) => bridgeSubdirectory("claimed", sessionId);
const receiptFile = (messageId) => path.join(bridgeSubdirectory("sent"), `${messageId}.json`);

export const readReceipt = (messageId) =>
  /^[a-z0-9]+$/.test(messageId || "") ? readJson(receiptFile(messageId)) : null;

export const writeReceipt = (message) => writeJsonAtomic(receiptFile(message.id), message);

export const updateReceipt = (messageId, patch) => {
  const current = readReceipt(messageId);
  if (!current) return null;
  const next = { ...current, ...patch, updatedAt: Date.now() };
  writeReceipt(next);
  return next;
};

export const listReceipts = () => {
  const directory = bridgeSubdirectory("sent");
  return listJson(directory).map((name) => readJson(path.join(directory, name))).filter(Boolean);
};

// 发送前的配额检查。返回 null 表示放行，否则返回拒绝原因。
export const checkSendLimits = (fromSession, toSession, now = Date.now()) => {
  const recent = listReceipts().filter((entry) => now - (entry.createdAt || 0) < PAIR_LIMIT_WINDOW_MS);
  const pair = recent.filter((entry) =>
    (entry.from?.session === fromSession && entry.to?.session === toSession) ||
    (entry.from?.session === toSession && entry.to?.session === fromSession));
  if (pair.length >= PAIR_LIMIT_COUNT) {
    return `这两个会话 10 分钟内已往来 ${pair.length} 条消息，疑似互相自动回复形成循环，已暂停发送。请让用户确认后再继续。`;
  }
  const sent = recent.filter((entry) => entry.from?.session === fromSession);
  if (sent.length >= SENDER_LIMIT_COUNT) {
    return `当前会话 10 分钟内已发送 ${sent.length} 条消息，超过上限，已暂停发送。`;
  }
  return null;
};

export const enqueueInbox = (message) => {
  const target = safeSessionId(message.to?.session);
  if (!target) throw new Error("目标会话 id 无效");
  writeJsonAtomic(path.join(inboxDirectory(target), `${message.id}.json`), message);
};

// 认领：inbox → claimed。rename 失败（被别的进程抢先认领）就跳过。
// 过期消息顺手标记 expired 并丢弃，不再投递。
export const claimInbox = (sessionId, now = Date.now()) => {
  const safe = safeSessionId(sessionId);
  if (!safe) return [];
  const inbox = inboxDirectory(safe);
  const claimed = claimedDirectory(safe);
  const messages = [];
  for (const name of listJson(inbox)) {
    const source = path.join(inbox, name);
    const destination = path.join(claimed, name);
    try {
      fs.renameSync(source, destination);
    } catch {
      continue;
    }
    const message = readJson(destination);
    fs.rmSync(destination, { force: true });
    if (!message) continue;
    if (now - (message.createdAt || 0) > MESSAGE_TTL_MS) {
      updateReceipt(message.id, { status: "expired" });
      continue;
    }
    messages.push(message);
  }
  return messages;
};

export const pendingCount = (sessionId) => {
  const safe = safeSessionId(sessionId);
  return safe ? listJson(inboxDirectory(safe)).length : 0;
};

// 会话结束：信箱里还没投出去的消息标记为 undeliverable，回执里能看到。
export const abandonInbox = (sessionId) => {
  const safe = safeSessionId(sessionId);
  if (!safe) return;
  const inbox = inboxDirectory(safe);
  for (const name of listJson(inbox)) {
    const file = path.join(inbox, name);
    const message = readJson(file);
    fs.rmSync(file, { force: true });
    if (message) updateReceipt(message.id, { status: "undeliverable", reason: "目标会话已结束" });
  }
};

// 回执保留 TTL 两倍时长，够排查问题，又不会无限增长。
export const pruneReceipts = (now = Date.now()) => {
  const directory = bridgeSubdirectory("sent");
  for (const name of listJson(directory)) {
    const file = path.join(directory, name);
    const receipt = readJson(file);
    if (!receipt || now - (receipt.createdAt || 0) > MESSAGE_TTL_MS * 2) fs.rmSync(file, { force: true });
  }
};

// ---------------------------------------------------------------------------
// 空闲订阅：subscriptions/<target>/<subscriber>.json，一次性。

export const addIdleSubscription = (targetSession, subscriberSession) => {
  const target = safeSessionId(targetSession);
  const subscriber = safeSessionId(subscriberSession);
  if (!target || !subscriber) return;
  writeJsonAtomic(path.join(bridgeSubdirectory("subscriptions", target), `${subscriber}.json`),
    { subscriber, createdAt: Date.now() });
};

export const hasIdleSubscriptions = (targetSession) => {
  const target = safeSessionId(targetSession);
  return target ? listJson(path.join(bridgeDirectory(), "subscriptions", target)).length > 0 : false;
};

export const takeIdleSubscriptions = (targetSession) => {
  const target = safeSessionId(targetSession);
  if (!target) return [];
  const directory = bridgeSubdirectory("subscriptions", target);
  const subscribers = [];
  for (const name of listJson(directory)) {
    const file = path.join(directory, name);
    const claimed = `${file}.taken`;
    try {
      fs.renameSync(file, claimed);
    } catch {
      continue;
    }
    const entry = readJson(claimed);
    fs.rmSync(claimed, { force: true });
    if (entry?.subscriber) subscribers.push(entry.subscriber);
  }
  return subscribers;
};

// ---------------------------------------------------------------------------
// 锁：O_EXCL 创建，内容是持有者 pid。持有者已死的锁视为陈旧，可以抢占。

export const acquireLock = (name, isHolderAlive) => {
  const file = path.join(bridgeSubdirectory("locks"), `${name}.pid`);
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const descriptor = fs.openSync(file, "wx", 0o600);
      fs.writeSync(descriptor, String(process.pid));
      fs.closeSync(descriptor);
      return () => {
        const holder = Number.parseInt(fs.readFileSync(file, "utf8"), 10);
        if (holder === process.pid) fs.rmSync(file, { force: true });
      };
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      let holder = 0;
      try {
        holder = Number.parseInt(fs.readFileSync(file, "utf8"), 10);
      } catch {
        // 锁文件刚被释放，下一轮重试。
      }
      if (holder > 0 && isHolderAlive(holder)) return null;
      fs.rmSync(file, { force: true });
    }
  }
  return null;
};
