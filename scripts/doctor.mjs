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
import { t } from "./i18n.mjs";

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
  if (bytes === null) return t("missing");
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
      title: t("Settings (removed by --purge)"),
      items: native ? [[t("Preferences"), native.preferences]] : []
    },
    {
      title: t("Your content (kept by both clean and --purge)"),
      items: [
        ...(native ? [
          [t("Pet sprites"), native.pets],
          [t("Shared lines"), native.phrases],
          [t("Per-pet lines"), native.petPhrases]
        ] : []),
        [t("CC Bridge switch"), path.join(ccPetsHome, "bridge-enabled")],
        ["codex / claude shim", shimDirectory]
      ]
    },
    {
      title: t("App data (removed by --purge; clean only clears the token cache and update log)"),
      items: native ? [
        [t("App data directory"), native.applicationSupport],
        [t("Quota history"), native.quotaHistory],
        [t("Auto-update config"), path.join(native.applicationSupport, "updater.json")]
      ] : []
    },
    {
      title: t("Caches and runtime state (cleared by clean; safe to lose)"),
      items: [
        ...(native ? [
          [t("Pet store manifest cache"), native.petStoreCache],
          [t("Agent event stream"), native.agentEvents],
          [t("Claude quota snapshot"), native.claudeUsage],
          [t("Codex live quota"), native.codexLiveUsage],
          [t("Codex launch records"), native.codexLaunches],
          [t("Online client records"), native.clients]
        ] : []),
        [t("CC Bridge state directory"), bridgeDirectory()]
      ]
    },
    {
      title: t("Program and integrations"),
      items: [
        [t("npm package"), projectDir],
        [t("Installed app"), installedApp],
        [t("Claude Code settings"), path.join(claudeHome, "settings.json")],
        ["Codex Hooks", path.join(codexHome, "hooks.json")],
        [t("Shell config"), shellRC]
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
    console.log(t(`⚠️  The native binary isn't built or can't run, so the pet's own data paths are unknown; run cc-pets install and try again.
`));
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
      results: [{ level: "fail", title: t("Can't parse {name} config: {configFile}", { name, configFile: tilde(configFile) }), fix: t("Fix that JSON file, then run cc-pets install") }],
      bridgeHooks: 0
    };
  }
  const results = [];
  if (hooks.total === 0) {
    results.push({ level: "fail", title: t("{name} hooks not installed", { name }), fix: "cc-pets install" });
  } else if (hooks.stale > 0) {
    results.push({
      level: "warn",
      title: hooks.stale !== 1
        ? t("{stale} {name} hooks point to cc-pets elsewhere (the package was moved or reinstalled)", { name, stale: hooks.stale })
        : t("{stale} {name} hook points to cc-pets elsewhere (the package was moved or reinstalled)", { name, stale: hooks.stale }),
      fix: "cc-pets install"
    });
  } else {
    results.push({ level: "ok", title: t("{name} hooks installed ({total} events)", { name, total: hooks.total }) });
  }
  if (hooks.legacy > 0) {
    results.push({
      level: "warn",
      title: hooks.legacy !== 1
        ? t("{name} config still has {legacy} old codex-pet hooks", { name, legacy: hooks.legacy })
        : t("{name} config still has {legacy} old codex-pet hook", { name, legacy: hooks.legacy }),
      fix: "cc-pets install"
    });
  }
  return { results, bridgeHooks: hooks.bridge };
};

const statusLineCheck = () => {
  const { value } = readJson(path.join(claudeHome, "settings.json"));
  const command = typeof value?.statusLine?.command === "string" ? value.statusLine.command : "";
  if (isManagedStatusLine(command, STATUS_LINE_MARKER)) {
    return { level: "ok", title: t("Claude status line feeds quota data through the wrapper") };
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
      ? { level: "ok", title: t("Claude status line feeds quota data ({script})", { script: tilde(script) }) }
      : { level: "warn", title: t("The quota hook in the Claude status line points to cc-pets elsewhere"), fix: "cc-pets install" };
  }
  return {
    level: "warn",
    title: command ? t("Claude status line doesn't feed quota data, so the pet can't show Claude quota %") : t("No Claude status line configured, so the pet can't show Claude quota %"),
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
    ? { level: "ok", title: t("{shellRC} adds the shim directory", { shellRC: tilde(shellRC) }) }
    : { level: "fail", title: t("{shellRC} has no CC Pets shim setup", { shellRC: tilde(shellRC) }), fix: "cc-pets install" });

  const broken = [];
  for (const name of ["codex", "claude"]) {
    const shim = path.join(shimDirectory, name);
    let link = null;
    try {
      link = fs.readlinkSync(shim);
    } catch {
      broken.push(t("{name} (missing)", { name }));
      continue;
    }
    if (!fs.existsSync(path.resolve(shimDirectory, link))) broken.push(t("{name} (target doesn't exist)", { name }));
  }
  results.push(broken.length === 0
    ? { level: "ok", title: t("Shims complete: {shimDirectory}", { shimDirectory: tilde(shimDirectory) }) }
    : { level: "warn", title: t("Shim problems: {broken}", { broken: broken.join(t(", ")) }), fix: "cc-pets install" });

  const entries = (process.env.PATH || "").split(path.delimiter).filter(Boolean).map((entry) => path.resolve(entry));
  const index = entries.indexOf(shimDirectory);
  if (index < 0) {
    results.push({ level: "warn", title: t("This terminal's PATH lacks the shim directory, so typing codex / claude won't start the pet"), fix: t("source {shellRC}, or open a new terminal", { shellRC: tilde(shellRC) }) });
  } else if (index > 0) {
    const shadowing = entries.slice(0, index).find((entry) =>
      ["codex", "claude"].some((name) => fs.existsSync(path.join(entry, name))));
    results.push(shadowing
      ? { level: "warn", title: t("{shadowing} comes before the shim directory in PATH and bypasses the pet", { shadowing: tilde(shadowing) }), fix: t("source {shellRC}, or open a new terminal", { shellRC: tilde(shellRC) }) }
      : { level: "ok", title: t("The shim directory comes before the real codex / claude in PATH") });
  } else {
    results.push({ level: "ok", title: t("The shim directory is first in PATH") });
  }
  return results;
};

const realBinaryCheck = (name, variable) => {
  const real = resolveRealExecutable(name, variable);
  return real && fs.existsSync(real)
    ? { level: "ok", title: t("Found the real {name}: {real}", { name, real: tilde(real) }) }
    : { level: "warn", title: t("The real {name} isn't in PATH, so the shim can't forward to it", { name }), fix: `export ${variable}=/absolute/path/to/${name}` };
};

const updaterCheck = (native) => {
  if (!native) return null;
  const file = path.join(native.applicationSupport, "updater.json");
  const { value, error } = readJson(file);
  if (error) {
    return { level: "warn", title: t("Auto-update isn't configured, so in-app updates won't work"), fix: "npm install -g cc-pets@latest --allow-scripts=cc-pets" };
  }
  const missing = ["nodePath", "npmCliPath"].filter((key) => !value?.[key] || !fs.existsSync(value[key]));
  return missing.length === 0
    ? { level: "ok", title: t("Auto-update config is valid") }
    : { level: "warn", title: t("The {missing} recorded for auto-update no longer exist (changed Node versions?)", { missing: missing.join(t(", ")) }), fix: "npm install -g cc-pets@latest --allow-scripts=cc-pets" };
};

const formatAge = (milliseconds) => {
  const minutes = Math.round(milliseconds / 60_000);
  if (minutes < 60) return t("{minutes} min ago", { minutes });
  const hours = Math.round(minutes / 60);
  return hours < 48 ? t("{hours} h ago", { hours }) : t("{days} days ago", { days: Math.round(hours / 24) });
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
      : { level: "fail", title: t("Node.js {node} is too old; 18 or later is required", { node: process.versions.node }) },
    { level: "info", title: t("npm package {packageVersion}: {projectDir}", { packageVersion, projectDir: tilde(projectDir) }) }
  ];
  const binaryVersion = fs.existsSync(petBinary) ? (run(petBinary, ["--version"]) || "").trim().replace(/^cc-pets\s+/, "") : null;
  if (!binaryVersion) {
    program.push({ level: "fail", title: t("Native binary isn't built or can't run"), fix: "cc-pets install" });
  } else if (binaryVersion !== packageVersion) {
    program.push({ level: "warn", title: t("Native binary {binaryVersion} doesn't match npm package {packageVersion}", { binaryVersion, packageVersion }), fix: "cc-pets install" });
  } else {
    program.push({ level: "ok", title: t("Native binary {binaryVersion}", { binaryVersion }) });
  }
  const appVersion = versionOfApp(installedApp);
  if (!appVersion) {
    program.push({ level: "warn", title: t("Installed app not found: {installedApp}", { installedApp: tilde(installedApp) }), fix: "cc-pets install" });
  } else if (appVersion !== packageVersion) {
    program.push({ level: "warn", title: t("Installed app {appVersion} doesn't match npm package {packageVersion}", { appVersion, packageVersion }), fix: "cc-pets install" });
  } else {
    program.push({ level: "ok", title: t("Installed app {appVersion}", { appVersion }) });
  }
  if (native) program.push({ level: "info", title: native.running ? t("The pet is running") : t("The pet isn't running") });
  const updater = updaterCheck(native);
  if (updater) program.push(updater);
  sections.push({ title: t("Program"), results: program });

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
        ? { level: "info", title: t("Claude quota snapshot updated {age}", { age: formatAge(Date.now() - modified) }) }
        : { level: "info", title: t("No Claude quota snapshot yet (created after Claude Code's first API response)") });
    }
    sections.push({ title: "Claude Code", results: claude });
  } else {
    sections.push({ title: "Claude Code", results: [{ level: "info", title: t("Claude Code CLI not detected, skipped") }] });
  }

  let codexBridgeHooks = 0;
  if (codexDetected) {
    const { results, bridgeHooks } = hookChecks("Codex", path.join(codexHome, "hooks.json"), CODEX_HOOK, LEGACY_CODEX_HOOK);
    codexBridgeHooks = bridgeHooks;
    sections.push({
      title: "Codex",
      results: [
        ...results,
        { level: "info", title: t("Codex only runs CC Pets hooks after you trust them in /hooks (can't be checked automatically)") }
      ]
    });
  } else {
    sections.push({ title: "Codex", results: [{ level: "info", title: t("Codex CLI not detected, skipped") }] });
  }

  sections.push({
    title: t("Shell integration"),
    results: [
      ...shimChecks(),
      ...(codexDetected ? [realBinaryCheck("codex", "CODEX_REAL_BIN")] : []),
      ...(claudeDetected ? [realBinaryCheck("claude", "CLAUDE_REAL_BIN")] : [])
    ]
  });

  if (!isBridgeEnabled()) {
    sections.push({ title: "CC Bridge", results: [{ level: "info", title: t("Off (optional; turn on with cc-pets bridge enable)") }] });
  } else {
    const bridge = [{ level: "ok", title: t("Enabled") }];
    if (claudeDetected) {
      bridge.push(claudeBridgeHooks > 0
        ? { level: "ok", title: t("CC Bridge hooks installed in Claude Code") }
        : { level: "warn", title: t("CC Bridge hooks missing in Claude Code"), fix: "cc-pets bridge enable" });
    }
    if (codexDetected) {
      bridge.push(codexBridgeHooks > 0
        ? { level: "ok", title: t("CC Bridge hooks installed in Codex") }
        : { level: "warn", title: t("CC Bridge hooks missing in Codex"), fix: "cc-pets bridge enable" });
      if (currentOptions().wake) {
        const notice = describeCodexQueue(probeCodexQueue());
        bridge.push(notice
          ? { level: "warn", title: notice }
          : { level: "ok", title: t("Codex supports codex queue, so it can be woken automatically") });
      }
    }
    sections.push({ title: "CC Bridge", results: bridge });
  }

  console.log(t("CC Pets diagnostics (npm package {packageVersion}, {platform} {release})", { packageVersion, platform: os.platform(), release: os.release() }));
  const counts = { ok: 0, warn: 0, fail: 0, info: 0 };
  for (const section of sections) {
    console.log(`\n${section.title}`);
    for (const result of section.results) {
      counts[result.level] += 1;
      console.log(`  ${ICONS[result.level]} ${result.title}`);
      if (result.fix) console.log(`     → ${result.fix}`);
    }
  }
  const warnings = counts.warn !== 1
    ? t("{count} warnings", { count: counts.warn }) : t("{count} warning", { count: counts.warn });
  const errors = counts.fail !== 1
    ? t("{count} errors", { count: counts.fail }) : t("{count} error", { count: counts.fail });
  console.log(t("\nResult: {ok} OK, {warnings}, {errors}.", { ok: counts.ok, warnings, errors }));
  if (counts.fail + counts.warn > 0) console.log(t("Most problems are fixed by cc-pets install; see cc-pets paths for data locations."));
  return counts.fail > 0 ? 1 : 0;
};

// ---------------------------------------------------------------------------

const [command, ...args] = process.argv.slice(2);
if (command === "paths") {
  process.exitCode = printPaths(args.includes("--json"));
} else if (command === "doctor") {
  process.exitCode = runDoctor();
} else {
  console.error(t("Usage: doctor.mjs paths [--json] | doctor"));
  process.exitCode = 2;
}
