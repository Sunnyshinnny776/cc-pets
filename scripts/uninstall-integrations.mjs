#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  CLAUDE_HOOK, CODEX_HOOK, CREATED_STATUS_LINE_MARKER, LEGACY_CLAUDE_HOOK, LEGACY_CODEX_HOOK,
  LEGACY_STATUS_LINE_MARKER, SHIM_END_MARKER, SHIM_START_MARKER, STATUS_LINE_END_MARKER,
  STATUS_LINE_MARKER, STATUS_LINE_START_MARKER, isManagedHookCommand, isManagedStatusLine,
  resolveStatusLineScript
} from "./integration-markers.mjs";

const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const claudeHome = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");
const preparingInstall = process.argv[2] === "--prepare-install";
const shellRC = process.argv[preparingInstall ? 3 : 2];

const currentCodexHook = CODEX_HOOK;
const legacyCodexHook = LEGACY_CODEX_HOOK;
const currentClaudeHook = CLAUDE_HOOK;
const legacyClaudeHook = LEGACY_CLAUDE_HOOK;
const currentStatusLineMarker = STATUS_LINE_MARKER;
const legacyStatusLineMarker = LEGACY_STATUS_LINE_MARKER;
const statusLineStartMarker = STATUS_LINE_START_MARKER;
const statusLineEndMarker = STATUS_LINE_END_MARKER;
const createdStatusLineMarker = CREATED_STATUS_LINE_MARKER;

function removeStatusLinePrelude(scriptPath) {
  if (!scriptPath || !fs.existsSync(scriptPath)) return { changed: false, created: false };
  const stats = fs.statSync(scriptPath);
  if (!stats.isFile()) return { changed: false, created: false };
  const original = fs.readFileSync(scriptPath, "utf8");
  const expression = new RegExp(
    `(?:^|\\n)${escapeRegExp(statusLineStartMarker)}\\n[\\s\\S]*?\\n${escapeRegExp(statusLineEndMarker)}(?=\\n|$)`,
    "g"
  );
  const updated = original
    .replace(expression, "")
    .replace(/^\n+/, "")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/\n*$/, "\n");
  if (updated === original) return { changed: false, created: false };
  const created = updated === `#!/bin/zsh\n${createdStatusLineMarker}\n`;
  if (created) {
    fs.unlinkSync(scriptPath);
  } else {
    const temporaryPath = `${scriptPath}.cc-pets.tmp`;
    fs.writeFileSync(temporaryPath, updated, { mode: stats.mode });
    fs.renameSync(temporaryPath, scriptPath);
    fs.chmodSync(scriptPath, stats.mode);
  }
  return { changed: true, created };
}

function writeJSON(filePath, value) {
  const temporaryPath = `${filePath}.cc-pets.tmp`;
  fs.writeFileSync(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporaryPath, filePath);
  fs.chmodSync(filePath, 0o600);
}

function removeHookHandlers(config, markers) {
  if (!config?.hooks || typeof config.hooks !== "object" || Array.isArray(config.hooks)) return false;
  let changed = false;
  for (const [event, groups] of Object.entries(config.hooks)) {
    if (!Array.isArray(groups)) continue;
    const filteredGroups = groups.flatMap((group) => {
      if (!group || !Array.isArray(group.hooks)) return [group];
      const handlers = group.hooks.filter((handler) =>
        !markers.some((signature) => isManagedHookCommand(handler?.command, signature))
      );
      if (handlers.length !== group.hooks.length) changed = true;
      return handlers.length > 0 ? [{ ...group, hooks: handlers }] : [];
    });
    if (filteredGroups.length > 0) config.hooks[event] = filteredGroups;
    else delete config.hooks[event];
  }
  if (Object.keys(config.hooks).length === 0) delete config.hooks;
  return changed;
}

function updateJSON(filePath, updater) {
  if (!fs.existsSync(filePath)) return false;
  let config;
  try {
    config = JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    console.error(`无法解析 ${filePath}，未做修改: ${error.message}`);
    process.exitCode = 1;
    return false;
  }
  if (!config || typeof config !== "object" || Array.isArray(config)) return false;
  if (!updater(config)) return false;
  writeJSON(filePath, config);
  return true;
}

const codexHooksPath = path.join(codexHome, "hooks.json");
const codexSignatures = preparingInstall
  ? [legacyCodexHook]
  : [currentCodexHook, legacyCodexHook];
const codexChanged = updateJSON(codexHooksPath, (config) =>
  removeHookHandlers(config, codexSignatures)
);

const claudeSettingsPath = path.join(claudeHome, "settings.json");
const claudeSignatures = preparingInstall
  ? [legacyClaudeHook]
  : [currentClaudeHook, legacyClaudeHook];
const statusLineMarkers = preparingInstall
  ? [legacyStatusLineMarker]
  : [currentStatusLineMarker, legacyStatusLineMarker];
const claudeChanged = updateJSON(claudeSettingsPath, (config) => {
  let changed = removeHookHandlers(config, claudeSignatures);
  const command = typeof config.statusLine?.command === "string" ? config.statusLine.command : "";
  if (statusLineMarkers.some((marker) => isManagedStatusLine(command, marker))) {
    const match = command.match(/'([A-Za-z0-9+/=]*)'\s*$/);
    const originalCommand = match ? Buffer.from(match[1], "base64").toString("utf8") : "";
    if (originalCommand) config.statusLine = { ...config.statusLine, command: originalCommand };
    else delete config.statusLine;
    changed = true;
  }
  if (!preparingInstall) {
    const scriptPath = resolveStatusLineScript(config.statusLine?.command);
    const statusLineResult = removeStatusLinePrelude(scriptPath);
    if (statusLineResult.created) delete config.statusLine;
    if (statusLineResult.changed) changed = true;
  }
  return changed;
});

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function removeMarkedBlock(text, startMarker, endMarker) {
  const expression = new RegExp(
    `(^|\\n)${escapeRegExp(startMarker)}\\n[\\s\\S]*?${escapeRegExp(endMarker)}(?=\\n|$)`,
    "g"
  );
  return text.replace(expression, "");
}

let shellChanged = false;
if (shellRC && fs.existsSync(shellRC)) {
  const original = fs.readFileSync(shellRC, "utf8");
  // cc-pets-codex / cc-pets-claude 是 alias 时代的段落。alias 区分大小写，挡不住
  // Claude / CODEX 这类写法，已被 cc-pets-shims 的 PATH shim 取代；安装前的
  // --prepare-install 会走到这里，顺带把老段落迁移掉。
  let updated = removeMarkedBlock(original, SHIM_START_MARKER, SHIM_END_MARKER);
  updated = removeMarkedBlock(updated, "# >>> cc-pets-codex >>>", "# <<< cc-pets-codex <<<");
  updated = removeMarkedBlock(updated, "# >>> cc-pets-claude >>>", "# <<< cc-pets-claude <<<");
  updated = removeMarkedBlock(updated, "# >>> codex-pet >>>", "# <<< codex-pet <<<");
  updated = removeMarkedBlock(updated, "# >>> claude-pet >>>", "# <<< claude-pet <<<");
  updated = updated.replace(/\n{3,}/g, "\n\n");
  if (updated !== original) {
    const mode = fs.statSync(shellRC).mode;
    const temporaryPath = `${shellRC}.cc-pets.tmp`;
    fs.writeFileSync(temporaryPath, updated, { mode });
    fs.renameSync(temporaryPath, shellRC);
    shellChanged = true;
  }
}

// shim 只在真正卸载时删：--prepare-install 之后紧接着就是重建，删了反而在
// 重建失败时留下一个没有 codex / claude 的 PATH 目录。
let shimChanged = false;
const shimDirectory = process.env.CC_PETS_SHIM_DIR || path.join(os.homedir(), ".cc-pets", "shims");
if (!preparingInstall && fs.existsSync(shimDirectory)) {
  for (const name of ["codex", "claude"]) {
    const shimPath = path.join(shimDirectory, name);
    // lstat：shim 是软链，目标包被 npm uninstall 删掉后 existsSync 会是 false。
    let stats = null;
    try {
      stats = fs.lstatSync(shimPath);
    } catch {
      continue;
    }
    if (!stats.isSymbolicLink()) continue;
    if (!fs.readlinkSync(shimPath).endsWith(`/bin/${name}-with-pet`)) continue;
    fs.rmSync(shimPath, { force: true });
    shimChanged = true;
  }
  if (fs.readdirSync(shimDirectory).length === 0) fs.rmdirSync(shimDirectory);
}

// CC Bridge 只在真正卸载时移除；重装时由 install-shell-integration.sh 的 bridge refresh 接管。
// MCP 注册只在确实开启过时才去调用 claude / codex 注销，避免卸载时无谓地拉起它们的 CLI。
if (!preparingInstall) {
  const bridge = await import("./bridge/install.mjs");
  const bridgeStore = await import("./bridge/store.mjs");
  bridgeStore.migrateLegacyFlag();
  for (const line of bridge.uninstall({ unregisterMcp: bridgeStore.isBridgeEnabled() })) console.log(line);
  bridgeStore.setBridgeEnabled(false);
}

const action = preparingInstall ? "已迁移" : "已移除";
if (codexChanged) console.log(`${action} ${codexHooksPath} 中的 CC Pets Hooks。`);
if (claudeChanged) console.log(`${action} ${claudeSettingsPath} 中的 CC Pets Hooks，并恢复原 status line。`);
if (shellChanged) console.log(`${action} ${shellRC} 中的 CC Pets shell 集成。`);
if (shimChanged) console.log(`${action} ${shimDirectory} 中的 codex / claude shim。`);
if (!codexChanged && !claudeChanged && !shellChanged && !shimChanged && !preparingInstall) {
  console.log("未发现需要移除的 CC Pets 集成。 ");
}
