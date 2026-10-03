#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { detectCodexCLI } from "./detect-cli.mjs";
import { CODEX_HOOK, LEGACY_CODEX_HOOK, isManagedHookCommand } from "./integration-markers.mjs";

const binary = process.argv[2];
if (!binary) {
  console.error("用法: install-codex-hooks.mjs /absolute/path/to/cc-pets");
  process.exit(2);
}

// 没装 Codex 就什么都不写。必须 exit 0：install-shell-integration.sh 是 set -eu，
// 这里非零退出会把后面的 Claude Hooks、更新器、shim 和 .zshrc 全部带停，
// 用户会拿到一个装了一半的状态。
if (!detectCodexCLI()) {
  console.log("未检测到 Codex CLI，跳过 Codex Hooks 安装。");
  console.log("之后安装了 Codex，执行 cc-pets install 即可补装。");
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
    console.error(`无法解析 ${hooksPath}: ${error.message}`);
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
console.log(`Codex Agent Hooks 已安装到 ${hooksPath}`);
console.log("下次启动 Codex 后，请执行 /hooks 并信任 CC Pets Hooks。");
