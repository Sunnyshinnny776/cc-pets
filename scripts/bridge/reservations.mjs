// 文件预留：多个 Agent 在同一个仓库里工作时，先声明"我要改哪些文件"，避免互相覆盖。
//
// 预留是建议性的，不锁文件。其他会话第一次编辑被预留的文件时，PreToolUse hook 会把这次编辑
// 拦下一次并说明原因；重试同一操作即放行，之后这处预留不再拦它（"首次拦截、重试放行"）。
// 只注入提醒不够：实测 Codex 的 additionalContext 在工具调用已经发出之后才到达，拦不住这次
// 编辑，模型也常常忽略。只记录路径模式和原因，不记录文件内容。
//
// 作用域是仓库根目录（git rev-parse --show-toplevel）：不同仓库、同一仓库的不同 worktree
// 各自独立——它们是不同的工作副本，物理上不会互相覆盖。

import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { describeSession, liveSessions } from "./core.mjs";
import { bridgeSubdirectory, readJson, writeJsonAtomic } from "./store.mjs";

export const DEFAULT_TTL_MINUTES = 30;
export const MAX_TTL_MINUTES = 8 * 60;
const MAX_PATTERNS = 50;
const MAX_PATTERN_LENGTH = 300;
const MAX_REASON_LENGTH = 200;

const GLOB_CHARACTERS = /[*?[\]{}]/;

export const repoRoot = (directory) => {
  if (!directory) return null;
  try {
    return execFileSync("git", ["rev-parse", "--show-toplevel"],
      { cwd: directory, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim() || directory;
  } catch {
    return directory;
  }
};

// 把调用方给的路径（绝对、相对、glob 均可）规范成"相对仓库根、以 / 分隔"的模式。
// 越出仓库根的路径拒绝，防止预留变成对整个磁盘的声明。
export const normalizePattern = (root, baseDirectory, raw) => {
  const text = String(raw ?? "").trim();
  if (!text || text.length > MAX_PATTERN_LENGTH) return null;
  const absolute = path.isAbsolute(text) ? path.normalize(text) : path.normalize(path.join(baseDirectory, text));
  const relative = path.relative(root, absolute);
  if (relative === "" ) return "**";
  if (relative.startsWith("..") || path.isAbsolute(relative)) return null;
  return relative.split(path.sep).join("/").replace(/\/+$/, "");
};

const escapeRegExp = (text) => text.replace(/[.+^${}()|\\]/g, "\\$&");

// 支持 **、*、?；不带通配符的模式视为"这个文件，或这个目录下的一切"。
export const patternToRegExp = (pattern) => {
  if (!GLOB_CHARACTERS.test(pattern)) {
    return new RegExp(`^${escapeRegExp(pattern)}(?:/.*)?$`);
  }
  let source = "";
  for (let index = 0; index < pattern.length; index += 1) {
    const character = pattern[index];
    if (character === "*" && pattern[index + 1] === "*") {
      // "**/" 可以匹配零层目录：src/**/a.ts 也匹配 src/a.ts。
      if (pattern[index + 2] === "/") {
        source += "(?:.*/)?";
        index += 2;
      } else {
        source += ".*";
        index += 1;
      }
    } else if (character === "*") {
      source += "[^/]*";
    } else if (character === "?") {
      source += "[^/]";
    } else if (character === "[" || character === "]" || character === "{" || character === "}") {
      source += `\\${character}`;
    } else {
      source += escapeRegExp(character);
    }
  }
  return new RegExp(`^${source}$`);
};

const staticPrefix = (pattern) => {
  const index = pattern.search(GLOB_CHARACTERS);
  if (index < 0) return pattern;
  const head = pattern.slice(0, index);
  return head.slice(0, head.lastIndexOf("/") + 1);
};

// 两个模式是否可能指向同一个文件。有一方是具体路径时精确匹配；两个都是 glob 时，
// 只比较静态目录前缀——宁可多报（src/**/*.ts 与 src/api/* 视为重叠），不能漏报。
export const patternsOverlap = (left, right) => {
  const leftGlob = GLOB_CHARACTERS.test(left);
  const rightGlob = GLOB_CHARACTERS.test(right);
  if (!leftGlob || !rightGlob) {
    return patternToRegExp(left).test(right) || patternToRegExp(right).test(left);
  }
  const leftPrefix = staticPrefix(left);
  const rightPrefix = staticPrefix(right);
  return leftPrefix.startsWith(rightPrefix) || rightPrefix.startsWith(leftPrefix);
};

// ---------------------------------------------------------------------------
// 存储：一条预留 = 一个 (会话, 仓库, 模式)，id 由三者派生，重复预留即续期。

const reservationDirectory = () => bridgeSubdirectory("reservations");

const reservationId = (session, root, pattern) =>
  `r${crypto.createHash("sha1").update(`${session}\0${root}\0${pattern}`).digest("hex").slice(0, 16)}`;

const listAll = () => {
  const directory = reservationDirectory();
  let names;
  try {
    names = fs.readdirSync(directory);
  } catch {
    return [];
  }
  return names.filter((name) => name.endsWith(".json"))
    .map((name) => readJson(path.join(directory, name))).filter(Boolean);
};

const removeReservation = (id) => fs.rmSync(path.join(reservationDirectory(), `${id}.json`), { force: true });

// 过期的、持有者已不在线的预留顺手清掉，返回仍然有效的。
export const activeReservations = ({ root, now = Date.now(), sessions } = {}) => {
  // PreToolUse 每次编辑都会走到这里；没有任何预留时不做进程探测。
  const all = listAll();
  if (all.length === 0) return [];
  const live = new Map((sessions ?? liveSessions()).map((session) => [session.session, session]));
  const active = [];
  for (const reservation of all) {
    const holder = live.get(reservation.session);
    if (!holder || reservation.expiresAt <= now) {
      removeReservation(reservation.id);
      continue;
    }
    if (root && reservation.root !== root) continue;
    active.push({ ...reservation, holder });
  }
  return active.sort((left, right) => left.createdAt - right.createdAt);
};

export const releaseSessionReservations = (sessionId) => {
  for (const reservation of listAll()) {
    if (reservation.session === sessionId) removeReservation(reservation.id);
  }
};

const minutesLeft = (reservation, now = Date.now()) => Math.max(1, Math.round((reservation.expiresAt - now) / 60000));

export const describeReservation = (reservation, now = Date.now()) =>
  `${reservation.pattern}  ·  ${describeSession(reservation.holder)}  ·  剩余 ${minutesLeft(reservation, now)} 分钟` +
  (reservation.reason ? `  ·  ${reservation.reason}` : "");

// ---------------------------------------------------------------------------

export const reserveFiles = ({ self, paths, reason = "", ttlMinutes = DEFAULT_TTL_MINUTES, now = Date.now() }) => {
  const list = Array.isArray(paths) ? paths : [paths];
  if (list.length === 0 || list.length > MAX_PATTERNS) return { error: `一次最多预留 ${MAX_PATTERNS} 个路径，至少 1 个。` };
  const ttl = Number(ttlMinutes);
  if (!Number.isFinite(ttl) || ttl < 1 || ttl > MAX_TTL_MINUTES) {
    return { error: `ttl_minutes 需在 1 到 ${MAX_TTL_MINUTES} 之间。` };
  }
  const root = repoRoot(self.cwd);
  if (!root) return { error: "无法确定当前会话所在的仓库目录。" };
  const patterns = [];
  for (const raw of list) {
    const pattern = normalizePattern(root, self.cwd, raw);
    if (!pattern) return { error: `路径 ${raw} 无效，或不在当前仓库 ${root} 内。` };
    if (!patterns.includes(pattern)) patterns.push(pattern);
  }
  const note = String(reason ?? "").trim().slice(0, MAX_REASON_LENGTH);
  const others = activeReservations({ root, now }).filter((entry) => entry.session !== self.session);
  const conflicts = [];
  for (const pattern of patterns) {
    const id = reservationId(self.session, root, pattern);
    const file = path.join(reservationDirectory(), `${id}.json`);
    // 续期保留已放行名单，否则持有者每续期一次，别人就会被重新拦一次。
    const previous = readJson(file);
    writeJsonAtomic(file, {
      id, session: self.session, root, pattern, reason: note, createdAt: previous?.createdAt ?? now,
      expiresAt: now + ttl * 60000, acknowledgedBy: previous?.acknowledgedBy ?? []
    });
    for (const other of others) {
      if (patternsOverlap(pattern, other.pattern)) conflicts.push({ pattern, other });
    }
  }
  return { root, patterns, ttl, conflicts };
};

// 记下"这个会话已经被这处预留拦过一次"，之后放行。
export const acknowledgeReservation = (reservationId, sessionId) => {
  const file = path.join(reservationDirectory(), `${reservationId}.json`);
  const record = readJson(file);
  if (!record) return;
  const acknowledged = new Set(record.acknowledgedBy ?? []);
  if (acknowledged.has(sessionId)) return;
  acknowledged.add(sessionId);
  writeJsonAtomic(file, { ...record, acknowledgedBy: [...acknowledged] });
};

export const isAcknowledged = (reservation, sessionId) =>
  Array.isArray(reservation.acknowledgedBy) && reservation.acknowledgedBy.includes(sessionId);

export const releaseFiles = ({ self, paths }) => {
  const root = repoRoot(self.cwd);
  const own = listAll().filter((entry) => entry.session === self.session && entry.root === root);
  let targets = own;
  if (Array.isArray(paths) && paths.length > 0) {
    const wanted = new Set(paths.map((raw) => normalizePattern(root, self.cwd, raw)).filter(Boolean));
    targets = own.filter((entry) => wanted.has(entry.pattern));
  }
  for (const entry of targets) removeReservation(entry.id);
  return { root, released: targets.map((entry) => entry.pattern) };
};

// PreToolUse 用：这些具体文件是否被其他在线会话预留。
export const findForeignReservations = ({ sessionId, cwd, filePaths, now = Date.now() }) => {
  const root = repoRoot(cwd);
  const others = activeReservations({ root, now }).filter((entry) => entry.session !== sessionId);
  if (others.length === 0) return [];
  const hits = [];
  for (const filePath of filePaths) {
    const relative = normalizePattern(root, cwd, filePath);
    if (!relative || GLOB_CHARACTERS.test(relative)) continue;
    for (const other of others) {
      if (patternToRegExp(other.pattern).test(relative)) hits.push({ file: relative, reservation: other });
    }
  }
  return hits;
};

// 从编辑类工具的输入里找出要改的文件。
//   - Claude：Edit / Write / MultiEdit 的 file_path，NotebookEdit 的 notebook_path；
//   - Codex：apply_patch 的补丁正文里的 "*** Update/Add/Delete File: <path>" 与 "*** Move to: <path>"。
//     Codex hook 里补丁放在哪个字段没有文档保证，所以对整个 tool_input 做文本匹配。
export const editedFilesFromToolInput = (toolInput) => {
  const files = new Set();
  if (toolInput && typeof toolInput === "object") {
    for (const key of ["file_path", "notebook_path"]) {
      if (typeof toolInput[key] === "string") files.add(toolInput[key]);
    }
  }
  const text = typeof toolInput === "string" ? toolInput : JSON.stringify(toolInput ?? "");
  const patch = text.replace(/\\n/g, "\n");
  for (const match of patch.matchAll(/\*\*\* (?:Update|Add|Delete) File: ([^\n"]+)/g)) files.add(match[1].trim());
  for (const match of patch.matchAll(/\*\*\* Move to: ([^\n"]+)/g)) files.add(match[1].trim());
  return [...files];
};
