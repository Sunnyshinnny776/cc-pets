#!/usr/bin/env node
// `cc-pets paths` 与 `cc-pets doctor`。
//
// 两者都只读：不改任何配置、不拉起桌宠。输出常被贴进 issue，所以 home 一律显示成 `~`，
// 不打印 status line 原命令、会话内容或 token。
// 桌宠自己的数据路径以原生程序 `--paths` 为准（与运行时同一套函数、同样认环境变量覆盖），
// 这里只补上 Node 侧才知道的部分（CC Bridge、shim、各 CLI 的配置文件）。

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { detectClaudeCLI, detectCodexCLI } from "./detect-cli.mjs";
import {
  CLAUDE_HOOK, CODEX_HOOK, LEGACY_CLAUDE_HOOK, LEGACY_CODEX_HOOK, SHIM_START_MARKER,
  STATUS_LINE_MARKER, STATUS_LINE_START_MARKER, isManagedHookCommand, isManagedStatusLine,
  resolveStatusLineScript
} from "./integration-markers.mjs";
import { HOOK_MARKER, describeCodexQueue } from "./bridge/install.mjs";
import { currentOptions } from "./bridge/options.mjs";
import { probeCodexQueue, resolveRealExecutable } from "./bridge/process.mjs";
import { bridgeDirectory, bridgeHomeDirectory, isBridgeEnabled } from "./bridge/store.mjs";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const petBinary = path.join(projectDir, ".build/release/cc-pets");
const packageVersion = JSON.parse(fs.readFileSync(path.join(projectDir, "package.json"), "utf8")).version;
const home = os.homedir();
const claudeHome = process.env.CLAUDE_CONFIG_DIR || path.join(home, ".claude");
const codexHome = process.env.CODEX_HOME || path.join(home, ".codex");
const shimDirectory = path.resolve(process.env.CC_PETS_SHIM_DIR || path.join(home, ".cc-pets/shims"));
const shellRC = path.join(process.env.ZDOTDIR || home, ".zshrc");
const installedApp = path.join(process.env.CC_PETS_APPLICATIONS_DIR || path.join(home, "Applications"), "CC Pets.app");

const tilde = (value) => {
  if (typeof value !== "string") return value;
  if (value === home) return "~";
  return value.startsWith(`${home}/`) ? `~${value.slice(home.length)}` : value;
};

const run = (executable, args) => {
  try {
    return execFileSync(executable, args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 10_000 });
  } catch {
    return null;
  }
};

const nativePaths = () => {
  const output = fs.existsSync(petBinary) ? run(petBinary, ["--paths"]) : null;
  try {
    return output ? JSON.parse(output) : null;
  } catch {
    return null;
  }
};

const sizeOf = (target) => {
  let stats;
  try {
    stats = fs.lstatSync(target);
  } catch {
    return null;
  }
  if (!stats.isDirectory()) return stats.size;
  let total = 0;
  for (const entry of fs.readdirSync(target)) total += sizeOf(path.join(target, entry)) ?? 0;
  return total;
};

const formatSize = (bytes) => {
  if (bytes === null) return "不存在";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
};

// 终端里中文占两列，按 length 对齐会错位。
const displayWidth = (text) => [...text].reduce((width, character) =>
  width + (/[\u1100-\u115f\u2e80-\ua4cf\uac00-\ud7a3\uf900-\ufaff\ufe30-\ufe4f\uff00-\uff60\uffe0-\uffe6]/.test(character) ? 2 : 1), 0);

const readJson = (file) => {
  try {
    return { value: JSON.parse(fs.readFileSync(file, "utf8")) };
  } catch (error) {
    return { error: error.code === "ENOENT" ? "missing" : "invalid" };
  }
};

// ---------------------------------------------------------------------------
// cc-pets paths

const pathGroups = (native) => {
  const ccPetsHome = bridgeHomeDirectory();
  const groups = [
    {
      title: "设置（--purge 会删除）",
      items: native ? [["偏好设置", native.preferences]] : []
    },
    {
      title: "用户内容（clean 与 --purge 都保留）",
      items: [
        ...(native ? [
          ["桌宠素材", native.pets],
          ["通用台词", native.phrases],
          ["宠物专属台词", native.petPhrases]
        ] : []),
        ["CC Bridge 开关", path.join(ccPetsHome, "bridge-enabled")],
        ["codex / claude shim", shimDirectory]
      ]
    },
    {
      title: "应用数据（--purge 会删除；clean 只清其中的 Token 缓存与更新日志）",
      items: native ? [
        ["应用数据目录", native.applicationSupport],
        ["额度历史", native.quotaHistory],
        ["自动更新配置", path.join(native.applicationSupport, "updater.json")]
      ] : []
    },
    {
      title: "缓存与运行时状态（clean 会清理，丢失不影响使用）",
      items: [
        ...(native ? [
          ["素材清单缓存", native.petStoreCache],
          ["Agent 事件流", native.agentEvents],
          ["Claude 额度快照", native.claudeUsage],
          ["Codex 实时额度", native.codexLiveUsage],
          ["Codex 启动记录", native.codexLaunches],
          ["在线客户端记录", native.clients]
        ] : []),
        ["CC Bridge 状态目录", bridgeDirectory()]
      ]
    },
    {
      title: "程序与集成",
      items: [
        ["npm 包", projectDir],
        ["已安装的 App", installedApp],
        ["Claude Code 配置", path.join(claudeHome, "settings.json")],
        ["Codex Hooks", path.join(codexHome, "hooks.json")],
        ["Shell 配置", shellRC]
      ]
    }
  ];
  return groups.filter((group) => group.items.length > 0);
};

const printPaths = (asJson) => {
  const native = nativePaths();
  const groups = pathGroups(native);
  if (asJson) {
    const document = {
      version: packageVersion,
      running: native?.running ?? null,
      groups: groups.map((group) => ({
        title: group.title,
        items: group.items.map(([label, target]) => ({ label, path: tilde(target), bytes: sizeOf(target) }))
      }))
    };
    console.log(JSON.stringify(document, null, 2));
    return 0;
  }
  if (!native) {
    console.log("⚠️  原生程序未构建或无法运行，桌宠自身的数据路径无法确定；执行 cc-pets install 后重试。\n");
  }
  const width = Math.max(...groups.flatMap((group) => group.items.map(([label]) => displayWidth(label))));
  groups.forEach((group, index) => {
    if (index > 0) console.log("");
    console.log(group.title);
    for (const [label, target] of group.items) {
      console.log(`  ${label}${" ".repeat(width - displayWidth(label) + 2)}${tilde(target)}  (${formatSize(sizeOf(target))})`);
    }
  });
  return 0;
};

// ---------------------------------------------------------------------------
// cc-pets doctor

const ICONS = { ok: "✅", warn: "⚠️ ", fail: "❌", info: "ℹ️ " };

const versionOfApp = (appPath) => {
  const plist = path.join(appPath, "Contents/Info.plist");
  if (!fs.existsSync(plist)) return null;
  return (run("/usr/bin/plutil", ["-extract", "CFBundleShortVersionString", "raw", "-o", "-", plist]) || "").trim() || null;
};

// 认出配置里属于 CC Pets 的 hook，并区分"指向当前安装"和"指向别处"（包被挪走、换了 node 版本重装后
// 常见，hook 每次触发都会失败）。
const inspectHooks = (configFile, signature, legacySignature) => {
  const { value, error } = readJson(configFile);
  if (error === "invalid") return { error: "invalid" };
  const commands = Object.values(value?.hooks ?? {})
    .filter(Array.isArray).flat()
    .flatMap((group) => (Array.isArray(group?.hooks) ? group.hooks : []))
    .map((handler) => handler?.command);
  const managed = commands.filter((command) => isManagedHookCommand(command, signature));
  const current = managed.filter((command) => command.includes(`'${petBinary}'`));
  return {
    total: managed.length,
    stale: managed.length - current.length,
    legacy: commands.filter((command) => isManagedHookCommand(command, legacySignature)).length,
    bridge: commands.filter((command) => typeof command === "string" && command.startsWith(HOOK_MARKER)).length
  };
};

const hookChecks = (name, configFile, signature, legacySignature) => {
  const hooks = inspectHooks(configFile, signature, legacySignature);
  if (hooks.error) {
    return {
      results: [{ level: "fail", title: `${name} 配置无法解析：${tilde(configFile)}`, fix: "修正该 JSON 文件后执行 cc-pets install" }],
      bridgeHooks: 0
    };
  }
  const results = [];
  if (hooks.total === 0) {
    results.push({ level: "fail", title: `${name} Hooks 未安装`, fix: "cc-pets install" });
  } else if (hooks.stale > 0) {
    results.push({
      level: "warn",
      title: `${name} Hooks 中有 ${hooks.stale} 条指向其他位置的 cc-pets（包被移动或重装过）`,
      fix: "cc-pets install"
    });
  } else {
    results.push({ level: "ok", title: `${name} Hooks 已安装（${hooks.total} 个事件）` });
  }
  if (hooks.legacy > 0) {
    results.push({ level: "warn", title: `${name} 配置里残留 ${hooks.legacy} 条旧版 codex-pet Hooks`, fix: "cc-pets install" });
  }
  return { results, bridgeHooks: hooks.bridge };
};

const statusLineCheck = () => {
  const { value } = readJson(path.join(claudeHome, "settings.json"));
  const command = typeof value?.statusLine?.command === "string" ? value.statusLine.command : "";
  if (isManagedStatusLine(command, STATUS_LINE_MARKER)) {
    return { level: "ok", title: "Claude status line 已通过包装器接入额度采集" };
  }
  const script = resolveStatusLineScript(command);
  let content = "";
  try {
    content = script ? fs.readFileSync(script, "utf8") : "";
  } catch {
    content = "";
  }
  if (content.includes(STATUS_LINE_START_MARKER)) {
    return content.includes(`'${petBinary}'`)
      ? { level: "ok", title: `Claude status line 已接入额度采集（${tilde(script)}）` }
      : { level: "warn", title: "Claude status line 里的额度采集指向其他位置的 cc-pets", fix: "cc-pets install" };
  }
  return {
    level: "warn",
    title: command ? "Claude status line 未接入额度采集，桌宠拿不到 Claude 额度百分比" : "未配置 Claude status line，桌宠拿不到 Claude 额度百分比",
    fix: "cc-pets install"
  };
};

const shimChecks = () => {
  const results = [];
  let rc = "";
  try {
    rc = fs.readFileSync(shellRC, "utf8");
  } catch {
    rc = "";
  }
  results.push(rc.includes(SHIM_START_MARKER)
    ? { level: "ok", title: `${tilde(shellRC)} 已加入 shim 目录` }
    : { level: "fail", title: `${tilde(shellRC)} 中没有 CC Pets 的 shim 配置`, fix: "cc-pets install" });

  const broken = [];
  for (const name of ["codex", "claude"]) {
    const shim = path.join(shimDirectory, name);
    let link = null;
    try {
      link = fs.readlinkSync(shim);
    } catch {
      broken.push(`${name}（缺失）`);
      continue;
    }
    if (!fs.existsSync(path.resolve(shimDirectory, link))) broken.push(`${name}（指向的文件不存在）`);
  }
  results.push(broken.length === 0
    ? { level: "ok", title: `shim 完整：${tilde(shimDirectory)}` }
    : { level: "warn", title: `shim 异常：${broken.join("、")}`, fix: "cc-pets install" });

  const entries = (process.env.PATH || "").split(path.delimiter).filter(Boolean).map((entry) => path.resolve(entry));
  const index = entries.indexOf(shimDirectory);
  if (index < 0) {
    results.push({ level: "warn", title: "当前终端的 PATH 里没有 shim 目录，直接敲 codex / claude 不会拉起桌宠", fix: `source ${tilde(shellRC)}，或新开一个终端` });
  } else if (index > 0) {
    const shadowing = entries.slice(0, index).find((entry) =>
      ["codex", "claude"].some((name) => fs.existsSync(path.join(entry, name))));
    results.push(shadowing
      ? { level: "warn", title: `PATH 中 ${tilde(shadowing)} 排在 shim 目录之前，会绕过桌宠`, fix: `source ${tilde(shellRC)}，或新开一个终端` }
      : { level: "ok", title: "PATH 中 shim 目录优先于真实的 codex / claude" });
  } else {
    results.push({ level: "ok", title: "PATH 中 shim 目录排在最前" });
  }
  return results;
};

const realBinaryCheck = (name, variable) => {
  const real = resolveRealExecutable(name, variable);
  return real && fs.existsSync(real)
    ? { level: "ok", title: `找到真实的 ${name}：${tilde(real)}` }
    : { level: "warn", title: `PATH 中找不到真实的 ${name}，shim 无法转发`, fix: `export ${variable}=/absolute/path/to/${name}` };
};

const updaterCheck = (native) => {
  if (!native) return null;
  const file = path.join(native.applicationSupport, "updater.json");
  const { value, error } = readJson(file);
  if (error) {
    return { level: "warn", title: "自动更新未配置，应用内无法一键更新", fix: "npm install -g cc-pets@latest --allow-scripts=cc-pets" };
  }
  const missing = ["nodePath", "npmCliPath"].filter((key) => !value?.[key] || !fs.existsSync(value[key]));
  return missing.length === 0
    ? { level: "ok", title: "自动更新配置有效" }
    : { level: "warn", title: `自动更新记录的 ${missing.join("、")} 已不存在（换过 Node 版本？）`, fix: "npm install -g cc-pets@latest --allow-scripts=cc-pets" };
};

const formatAge = (milliseconds) => {
  const minutes = Math.round(milliseconds / 60_000);
  if (minutes < 60) return `${minutes} 分钟前`;
  const hours = Math.round(minutes / 60);
  return hours < 48 ? `${hours} 小时前` : `${Math.round(hours / 24)} 天前`;
};

const runDoctor = () => {
  const native = nativePaths();
  const sections = [];
  const claudeDetected = detectClaudeCLI();
  const codexDetected = detectCodexCLI();

  const nodeMajor = Number(process.versions.node.split(".")[0]);
  const program = [
    nodeMajor >= 18
      ? { level: "ok", title: `Node.js ${process.versions.node}` }
      : { level: "fail", title: `Node.js ${process.versions.node} 过旧，需要 18 或更高版本` },
    { level: "info", title: `npm 包 ${packageVersion}：${tilde(projectDir)}` }
  ];
  const binaryVersion = fs.existsSync(petBinary) ? (run(petBinary, ["--version"]) || "").trim().replace(/^cc-pets\s+/, "") : null;
  if (!binaryVersion) {
    program.push({ level: "fail", title: "原生程序未构建或无法运行", fix: "cc-pets install" });
  } else if (binaryVersion !== packageVersion) {
    program.push({ level: "warn", title: `原生程序版本 ${binaryVersion} 与 npm 包 ${packageVersion} 不一致`, fix: "cc-pets install" });
  } else {
    program.push({ level: "ok", title: `原生程序 ${binaryVersion}` });
  }
  const appVersion = versionOfApp(installedApp);
  if (!appVersion) {
    program.push({ level: "warn", title: `未找到已安装的 App：${tilde(installedApp)}`, fix: "cc-pets install" });
  } else if (appVersion !== packageVersion) {
    program.push({ level: "warn", title: `已安装的 App 版本 ${appVersion} 与 npm 包 ${packageVersion} 不一致`, fix: "cc-pets install" });
  } else {
    program.push({ level: "ok", title: `已安装的 App ${appVersion}` });
  }
  if (native) program.push({ level: "info", title: native.running ? "桌宠正在运行" : "桌宠未运行" });
  const updater = updaterCheck(native);
  if (updater) program.push(updater);
  sections.push({ title: "程序", results: program });

  let claudeBridgeHooks = 0;
  if (claudeDetected) {
    const { results, bridgeHooks } = hookChecks("Claude Code", path.join(claudeHome, "settings.json"), CLAUDE_HOOK, LEGACY_CLAUDE_HOOK);
    claudeBridgeHooks = bridgeHooks;
    const claude = [...results, statusLineCheck()];
    if (native) {
      let modified = null;
      try {
        modified = fs.statSync(native.claudeUsage).mtimeMs;
      } catch {
        modified = null;
      }
      claude.push(modified
        ? { level: "info", title: `Claude 额度快照更新于 ${formatAge(Date.now() - modified)}` }
        : { level: "info", title: "暂无 Claude 额度快照（Claude Code 首次收到 API 响应后生成）" });
    }
    sections.push({ title: "Claude Code", results: claude });
  } else {
    sections.push({ title: "Claude Code", results: [{ level: "info", title: "未检测到 Claude Code CLI，跳过" }] });
  }

  let codexBridgeHooks = 0;
  if (codexDetected) {
    const { results, bridgeHooks } = hookChecks("Codex", path.join(codexHome, "hooks.json"), CODEX_HOOK, LEGACY_CODEX_HOOK);
    codexBridgeHooks = bridgeHooks;
    sections.push({
      title: "Codex",
      results: [
        ...results,
        { level: "info", title: "Codex 需要在 /hooks 中信任 CC Pets Hooks 后才会触发（无法自动检测）" }
      ]
    });
  } else {
    sections.push({ title: "Codex", results: [{ level: "info", title: "未检测到 Codex CLI，跳过" }] });
  }

  sections.push({
    title: "Shell 集成",
    results: [
      ...shimChecks(),
      ...(codexDetected ? [realBinaryCheck("codex", "CODEX_REAL_BIN")] : []),
      ...(claudeDetected ? [realBinaryCheck("claude", "CLAUDE_REAL_BIN")] : [])
    ]
  });

  if (!isBridgeEnabled()) {
    sections.push({ title: "CC Bridge", results: [{ level: "info", title: "未开启（可选功能，cc-pets bridge enable 开启）" }] });
  } else {
    const bridge = [{ level: "ok", title: "已开启" }];
    if (claudeDetected) {
      bridge.push(claudeBridgeHooks > 0
        ? { level: "ok", title: "Claude Code 中的 CC Bridge Hooks 已安装" }
        : { level: "warn", title: "Claude Code 中缺少 CC Bridge Hooks", fix: "cc-pets bridge enable" });
    }
    if (codexDetected) {
      bridge.push(codexBridgeHooks > 0
        ? { level: "ok", title: "Codex 中的 CC Bridge Hooks 已安装" }
        : { level: "warn", title: "Codex 中缺少 CC Bridge Hooks", fix: "cc-pets bridge enable" });
      if (currentOptions().wake) {
        const notice = describeCodexQueue(probeCodexQueue());
        bridge.push(notice
          ? { level: "warn", title: notice }
          : { level: "ok", title: "Codex 支持 codex queue，可自动唤醒" });
      }
    }
    sections.push({ title: "CC Bridge", results: bridge });
  }

  console.log(`CC Pets 诊断（npm 包 ${packageVersion}，${os.platform()} ${os.release()}）`);
  const counts = { ok: 0, warn: 0, fail: 0, info: 0 };
  for (const section of sections) {
    console.log(`\n${section.title}`);
    for (const result of section.results) {
      counts[result.level] += 1;
      console.log(`  ${ICONS[result.level]} ${result.title}`);
      if (result.fix) console.log(`     → ${result.fix}`);
    }
  }
  console.log(`\n结果：${counts.ok} 项正常，${counts.warn} 项警告，${counts.fail} 项错误。`);
  if (counts.fail + counts.warn > 0) console.log("多数问题执行 cc-pets install 即可修复；数据位置见 cc-pets paths。");
  return counts.fail > 0 ? 1 : 0;
};

// ---------------------------------------------------------------------------

const [command, ...args] = process.argv.slice(2);
if (command === "paths") {
  process.exitCode = printPaths(args.includes("--json"));
} else if (command === "doctor") {
  process.exitCode = runDoctor();
} else {
  console.error("用法: doctor.mjs paths [--json] | doctor");
  process.exitCode = 2;
}
