#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { detectClaudeCLI } from "./detect-cli.mjs";
import {
  CLAUDE_HOOK, CREATED_STATUS_LINE_MARKER, LEGACY_CLAUDE_HOOK, LEGACY_STATUS_LINE_MARKER,
  STATUS_LINE_END_MARKER, STATUS_LINE_MARKER, STATUS_LINE_START_MARKER,
  isManagedHookCommand, isManagedStatusLine
} from "./integration-markers.mjs";
import { t } from "./i18n.mjs";

const binary = process.argv[2];
if (!binary) {
  console.error(t("Usage: install-claude-hooks.mjs /absolute/path/to/cc-pets"));
  process.exit(2);
}

// 没装 Claude Code 就什么都不写。这里尤其重要：下面的 createStatusLine 分支会创建
// ~/.claude/statusline-command.sh 并把 settings.json 的 statusLine 指过去，
// 对还没装 Claude 的用户等于提前替他决定了状态栏。exit 0 的理由见 install-codex-hooks.mjs。
if (!detectClaudeCLI()) {
  console.log(t("Claude Code CLI not detected; skipping Claude hooks and status line setup."));
  console.log(t("If you install Claude Code later, run cc-pets install to set it up."));
  process.exit(0);
}

const claudeHome = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");
const settingsPath = path.join(claudeHome, "settings.json");
const marker = CLAUDE_HOOK.marker;
const statusLineMarker = STATUS_LINE_MARKER;
const managedHookSignatures = [CLAUDE_HOOK, LEGACY_CLAUDE_HOOK];
const managedStatusLineMarkers = [STATUS_LINE_MARKER, LEGACY_STATUS_LINE_MARKER];
const statusLineStartMarker = STATUS_LINE_START_MARKER;
const statusLineEndMarker = STATUS_LINE_END_MARKER;
const createdStatusLineMarker = CREATED_STATUS_LINE_MARKER;
const shellQuote = (value) => `'${value.replaceAll("'", `'\\''`)}'`;
const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const statusLineBlockPattern = new RegExp(
  `(?:^|\\n)${escapeRegExp(statusLineStartMarker)}\\n[\\s\\S]*?\\n${escapeRegExp(statusLineEndMarker)}(?=\\n|$)`,
  "g"
);
const removeStatusLineBlock = (value) => value
  .replace(statusLineBlockPattern, "")
  .replace(/^\n+/, "")
  .replace(/\n{3,}/g, "\n\n");
// `bash ~/.claude/statusline-command.sh` 指向的仍是一个能就地注入的脚本，只是多了解释器
// 前缀和 `~/`。不剥掉就会被下面的"绝对路径 + 无空格"两条拒掉，白白退化成 base64 包装器，
// 而包装器形态对改 settings.json 的 agent 是黑盒（读不出原命令，容易整条覆盖掉）。
// 带 -c 的形式除外：`-c` 后面是命令串而非脚本路径，不能当路径注入。
const interpreterPattern =
  /^(?:\/usr\/bin\/env\s+)?(?:[^\s'"]*\/)?(?:ba|z|k|da)?sh((?:\s+-[A-Za-z]+)*)\s+(.+)$/s;
const unquote = (value) => {
  const quoted = value.match(/^(['"])(.*)\1$/s);
  return quoted ? quoted[2] : value;
};
// target 保留用户原来的写法（含 `~/`），script 才是展开后用于读写文件的绝对路径。
// 官方形态就是 `~/.claude/statusline.sh`，`~` 是刻意的可移植写法，不能展开后写回配置。
const parseStatusLineCommand = (value) => {
  if (typeof value !== "string") return null;
  let candidate = unquote(value.trim());
  let hasInterpreter = false;
  let flags = "";
  const interpreted = candidate.match(interpreterPattern);
  if (interpreted && !/-[A-Za-z]*c(?=\s|$)/.test(interpreted[1])) {
    hasInterpreter = true;
    flags = interpreted[1].trim();
    candidate = unquote(interpreted[2].trim());
  }
  let resolved = candidate;
  if (resolved.startsWith("~/")) resolved = path.join(os.homedir(), resolved.slice(2));
  if (!path.isAbsolute(resolved) || /[\s;&|<>`$()]/.test(resolved)) return null;
  return { script: path.resolve(resolved), target: candidate, hasInterpreter, flags };
};
const resolveStatusLineScript = (value) => parseStatusLineCommand(value)?.script ?? null;
const statusLinePrelude = [
  statusLineStartMarker,
  `CC_PETS_STATUSLINE_INPUT="$(/usr/bin/mktemp "\${TMPDIR:-/tmp}/cc-pets-statusline.XXXXXX")" || exit 1`,
  `/bin/cat > "\${CC_PETS_STATUSLINE_INPUT}"`,
  `if [ -x ${shellQuote(path.resolve(binary))} ]; then`,
  `  ${shellQuote(path.resolve(binary))} --claude-usage < "\${CC_PETS_STATUSLINE_INPUT}" >/dev/null 2>&1 || true`,
  "fi",
  `exec 0< "\${CC_PETS_STATUSLINE_INPUT}"`,
  `/bin/rm -f "\${CC_PETS_STATUSLINE_INPUT}"`,
  "unset CC_PETS_STATUSLINE_INPUT",
  statusLineEndMarker
].join("\n");
const installStatusLinePrelude = (scriptPath, createIfMissing = false) => {
  let original = "";
  let mode = 0o700;
  if (fs.existsSync(scriptPath)) {
    const stats = fs.statSync(scriptPath);
    if (!stats.isFile()) return { installed: false, hadShebang: false };
    original = fs.readFileSync(scriptPath, "utf8");
    mode = stats.mode;
  } else if (createIfMissing) {
    fs.mkdirSync(path.dirname(scriptPath), { recursive: true });
    original = `#!/bin/zsh\n${createdStatusLineMarker}\n`;
  } else {
    return { installed: false, hadShebang: false };
  }

  const cleaned = removeStatusLineBlock(original);
  const firstNewline = cleaned.indexOf("\n");
  const hasShebang = cleaned.startsWith("#!");
  const shebang = hasShebang
    ? cleaned.slice(0, firstNewline === -1 ? cleaned.length : firstNewline)
    : "#!/bin/zsh";
  const body = hasShebang
    ? (firstNewline === -1 ? "" : cleaned.slice(firstNewline + 1))
    : cleaned;
  const updated = `${shebang}\n${statusLinePrelude}\n${body}`.replace(/\n*$/, "\n");
  const temporaryPath = `${scriptPath}.cc-pets.tmp`;
  fs.writeFileSync(temporaryPath, updated, { mode });
  fs.renameSync(temporaryPath, scriptPath);
  fs.chmodSync(scriptPath, mode | 0o100);
  return { installed: true, hadShebang: hasShebang };
};
const command = `${marker} ${shellQuote(path.resolve(binary))} --hook`;
const events = [
  "SessionStart",
  "UserPromptSubmit",
  "PreToolUse",
  "PermissionRequest",
  "PostToolUse",
  "PostToolUseFailure",
  "Notification",
  "SubagentStart",
  "SubagentStop",
  "TaskCreated",
  "TaskCompleted",
  "Stop",
  "StopFailure",
  "SessionEnd"
];

fs.mkdirSync(claudeHome, { recursive: true });
let config = {};
if (fs.existsSync(settingsPath)) {
  try {
    config = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  } catch (error) {
    console.error(t("Can't parse {settingsPath}: {message}", { settingsPath, message: error.message }));
    process.exit(1);
  }
}
if (!config || typeof config !== "object" || Array.isArray(config)) config = {};
if (!config.hooks || typeof config.hooks !== "object" || Array.isArray(config.hooks)) config.hooks = {};

for (const [event, groups] of Object.entries(config.hooks)) {
  if (!Array.isArray(groups)) continue;
  config.hooks[event] = groups.flatMap((group) => {
    if (!group || !Array.isArray(group.hooks)) return [group];
    const handlers = group.hooks.filter((handler) => {
      return !managedHookSignatures.some((signature) => isManagedHookCommand(handler?.command, signature));
    });
    return handlers.length > 0 ? [{ ...group, hooks: handlers }] : [];
  });
}

for (const event of events) {
  if (!Array.isArray(config.hooks[event])) config.hooks[event] = [];
  config.hooks[event].push({
    hooks: [{ type: "command", command, timeout: 3 }]
  });
}

let originalStatusLineCommand = "";
if (config.statusLine && typeof config.statusLine === "object" && !Array.isArray(config.statusLine)) {
  const currentCommand = typeof config.statusLine.command === "string" ? config.statusLine.command : "";
  if (managedStatusLineMarkers.some((value) => isManagedStatusLine(currentCommand, value))) {
    const match = currentCommand.match(/'([A-Za-z0-9+/=]*)'\s*$/);
    if (match) originalStatusLineCommand = Buffer.from(match[1], "base64").toString("utf8");
  } else {
    originalStatusLineCommand = currentCommand;
  }
} else {
  config.statusLine = { type: "command" };
}

let createdStatusLine = false;
if (!originalStatusLineCommand) {
  originalStatusLineCommand = path.join(claudeHome, "statusline-command.sh");
  createdStatusLine = true;
}
config.statusLine = { ...config.statusLine, type: "command", command: originalStatusLineCommand };

const parsedStatusLine = parseStatusLineCommand(originalStatusLineCommand);
const statusLineScript = parsedStatusLine?.script ?? null;
const preludeResult = statusLineScript
  ? installStatusLinePrelude(statusLineScript, createdStatusLine)
  : { installed: false, hadShebang: false };
const statusLineInstalled = preludeResult.installed;

// 只在原命令带解释器前缀（`bash ~/x.sh`）时才改写 command，去掉那层前缀让 agent 能直接读懂。
// 纯路径形态——包括官方默认的 `~/.claude/statusline.sh`——一个字都不动，写法原样保留。
// 两条额外的闸门，都是为了不改变脚本的执行语义：
//   * 带 flag（`sh -e ~/x.sh`）不动，否则 `-e` 这类选项会被悄悄丢掉；
//   * 脚本原本没有 shebang 的不动，否则 prelude 补的 `#!/bin/zsh` 会把本来用 bash 跑的
//     脚本换成 zsh 跑。用户写 `bash ~/x.sh` 往往正是因为脚本没有 shebang。
if (
  statusLineInstalled &&
  parsedStatusLine?.hasInterpreter &&
  !parsedStatusLine.flags &&
  preludeResult.hadShebang
) {
  config.statusLine = { ...config.statusLine, command: parsedStatusLine.target };
}

// 就地往用户脚本里插 prelude 只对"能解析出脚本路径的命令"成立。真·第三方状态栏不是这个
// 形态（`bun x ccstatusline`、`npx …`、任何带管道或 `sh -c` 的命令行），
// resolveStatusLineScript 一律拒绝。以前这里只打印一行警告就算了，而 statusline 是 Claude 额度的唯一来源
// （转录 jsonl 和 stats-cache.json 里都没有 rate_limits），于是这类用户的额度永远是 `--`。
// 回退到包装器：command 换成 claude-statusline-with-pet + base64 编码的原命令，它先把 stdin
// 喂给 cc-pets --claude-usage，再原样转发给原命令执行。卸载侧本来就认这个形态（marker +
// 末尾的 base64），能原样还原回去。
const statusLineWrapper = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)), "..", "bin", "claude-statusline-with-pet");
let statusLineWrapped = false;
if (!statusLineInstalled && originalStatusLineCommand && fs.existsSync(statusLineWrapper)) {
  try {
    fs.chmodSync(statusLineWrapper, fs.statSync(statusLineWrapper).mode | 0o100);
  } catch {
    // 包内文件不可写（只读安装）时权限位通常本来就是对的，交给下面的可执行判断兜底。
  }
  if (fs.existsSync(statusLineWrapper)) {
    const encoded = Buffer.from(originalStatusLineCommand, "utf8").toString("base64");
    config.statusLine = {
      ...config.statusLine,
      type: "command",
      command: `${statusLineMarker} ${shellQuote(statusLineWrapper)} '${encoded}'`
    };
    statusLineWrapped = true;
  }
}

if (!statusLineInstalled && !statusLineWrapped) {
  console.warn(t("Claude status line not hooked up: {command}", { command: originalStatusLineCommand || t("(not configured)") }));
  console.warn(t("Claude hooks still work, but the pet can't show Claude quota % (token usage is unaffected)."));
}

const temporaryPath = `${settingsPath}.cc-pets.tmp`;
fs.writeFileSync(temporaryPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
fs.renameSync(temporaryPath, settingsPath);
fs.chmodSync(settingsPath, 0o600);
console.log(t("Claude Code hooks installed in {settingsPath}", { settingsPath }));
if (statusLineInstalled) {
  console.log(t("Claude quota tracking added to your existing status line. The pet shows quota after the first API response."));
} else if (statusLineWrapped) {
  console.log(t("Claude quota tracking added to the status line through a wrapper; your original command still runs. The pet shows quota after the first API response."));
}
