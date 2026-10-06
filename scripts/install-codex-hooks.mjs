#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { detectCodexCLI } from "./detect-cli.mjs";
import { CODEX_HOOK, LEGACY_CODEX_HOOK, isManagedHookCommand } from "./integration-markers.mjs";
import { t } from "./i18n.mjs";

const binary = process.argv[2];
if (!binary) {
  console.error(t("Usage: install-codex-hooks.mjs /absolute/path/to/cc-pets"));
  process.exit(2);
}

// 没装 Codex 就什么都不写。必须 exit 0：install-shell-integration.sh 是 set -eu，
// 这里非零退出会把后面的 Claude Hooks、更新器、shim 和 .zshrc 全部带停，
// 用户会拿到一个装了一半的状态。
if (!detectCodexCLI()) {
  console.log(t("Codex CLI not detected; skipping Codex hooks."));
  console.log(t("If you install Codex later, run cc-pets install to set it up."));
  process.exit(0);
}

const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const hooksPath = path.join(codexHome, "hooks.json");
const marker = CODEX_HOOK.marker;
const managedSignatures = [CODEX_HOOK, LEGACY_CODEX_HOOK];
const shellQuote = (value) => `'${value.replaceAll("'", `'\\''`)}'`;
const command = `${marker} ${shellQuote(path.resolve(binary))} --hook`;
const events = [
  "SessionStart",
  "UserPromptSubmit",
  "PreToolUse",
  "PermissionRequest",
  "PostToolUse",
  "SubagentStart",
  "SubagentStop",
  "Stop"
];

fs.mkdirSync(codexHome, { recursive: true });
let config = {};
if (fs.existsSync(hooksPath)) {
  try {
    config = JSON.parse(fs.readFileSync(hooksPath, "utf8"));
  } catch (error) {
    console.error(t("Can't parse {hooksPath}: {message}", { hooksPath, message: error.message }));
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
      return !managedSignatures.some((signature) => isManagedHookCommand(handler?.command, signature));
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

const temporaryPath = `${hooksPath}.cc-pets.tmp`;
fs.writeFileSync(temporaryPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
fs.renameSync(temporaryPath, hooksPath);
fs.chmodSync(hooksPath, 0o600);
console.log(t("Codex agent hooks installed in {hooksPath}", { hooksPath }));
console.log(t("Next time you start Codex, run /hooks and trust the CC Pets hooks."));
