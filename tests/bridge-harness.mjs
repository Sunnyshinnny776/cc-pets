// CC Bridge 端到端测试：隔离的状态目录 + 假的 claude / codex 进程 + 假的 `codex queue`。
// 不接触真实的 ~/.claude、~/.codex、$TMPDIR，也不调用真实 CLI。
// 被测的是原生的 `cc-pets bridge`；状态直接读写磁盘上的文件（格式由原生端定义，桌宠也读同一份）。
// 不经过进程边界的纯逻辑（模式匹配、选项解析、codex queue 探测）见 bridge-units-harness.m。

import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binary = path.join(projectDir, ".build/release/cc-pets");
const root = fs.mkdtempSync("/tmp/cc-bridge-");
const children = [];

const cleanup = () => {
  for (const child of children) {
    try {
      child.kill("SIGKILL");
    } catch {
      // 已退出。
    }
  }
  fs.rmSync(root, { recursive: true, force: true });
};
process.on("exit", cleanup);

const env = {
  ...process.env,
  // 输出断言使用中文；单独运行时也不受开发机语言影响。
  CC_PETS_LANGUAGE: "zh-Hans",
  CC_PETS_LOCALIZATION_DIR: path.join(projectDir, "Resources"),
  CC_PETS_STATE_DIR: path.join(root, "state"),
  CC_PETS_HOME: path.join(root, "home"),
  CC_PETS_SHIM_DIR: path.join(root, "shims"),
  CLAUDE_CONFIG_DIR: path.join(root, "claude"),
  CODEX_HOME: path.join(root, "codex"),
  // bridge enable/disable 作用于 $HOME 下登记的账号 Home，CLAUDE_CONFIG_DIR / CODEX_HOME 挡不住；
  // 不换 HOME 会改到开发机上真实的 ~/.claude、~/.codex。
  HOME: path.join(root, "user-home"),
  CODEX_REAL_BIN: path.join(root, "bin/codex"),
  CC_BRIDGE_SKIP_MCP: "1",
  CC_PETS_ASSUME_CLI: "1",
  CC_BRIDGE_POLL_MS: "50"
};
delete env.CLAUDE_CODE_SESSION_ID;
delete env.CODEX_THREAD_ID;
delete env.CC_BRIDGE_AGENT;
Object.assign(process.env, env);
for (const directory of ["state", "home", "claude", "codex", "bin", "fake", "user-home"]) {
  fs.mkdirSync(path.join(root, directory), { recursive: true });
}
// 把测试用的配置目录挂成官方默认 Home 并登记，和 cc-pets install 的效果一致。
fs.symlinkSync(env.CLAUDE_CONFIG_DIR, path.join(env.HOME, ".claude"));
fs.symlinkSync(env.CODEX_HOME, path.join(env.HOME, ".codex"));
{
  const registered = spawnSync(binary, ["profile", "ensure-defaults"], { env, encoding: "utf8" });
  assert.equal(registered.status, 0, registered.stderr);
}

// 假 codex：记录 queue 调用参数，按真实 CLI 的格式回显。
const queueLog = path.join(root, "queue.log");
fs.writeFileSync(env.CODEX_REAL_BIN, `#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "codex-cli 9.9.9"
  exit 0
fi
if [ "$1" = "queue" ] && [ "$2" = "--help" ]; then
  echo "Usage: codex queue [OPTIONS] --thread <THREAD> --message <TEXT>"
  exit 0
fi
if [ "$1" = "queue" ]; then
  printf '%s\\0' "$@" >> '${queueLog}'
  printf '\\036' >> '${queueLog}'
  echo "Queued message fake-$$ for thread $3."
  exit 0
fi
exit 1
`, { mode: 0o755 });

// 假的 CLI 宿主进程：可执行文件名分别叫 claude / codex，ps 里的命令行才能被识别。
const fakeAgent = (name) => {
  const link = path.join(root, "fake", name);
  if (!fs.existsSync(link)) fs.symlinkSync("/bin/sleep", link);
  // detached = 新会话（setsid），不带控制终端。否则在交互终端里跑测试（如 npm publish）时，
  // 子进程会继承那个终端的 tty，tty 列就不再是 "-"，与 CI / 无终端环境下的结果不一致。
  const child = spawn(link, ["600"], { stdio: "ignore", detached: true });
  children.push(child);
  return child;
};

const runCli = (args, { input = "", agent, extraEnv = {} } = {}) => {
  const result = spawnSync(binary, ["bridge", ...args], {
    input,
    env: { ...env, ...(agent ? { CC_BRIDGE_AGENT: agent } : {}), ...extraEnv },
    encoding: "utf8"
  });
  return { status: result.status, stdout: result.stdout, stderr: result.stderr };
};

const hook = (provider, agent, payload) => runCli(["hook"], {
  input: JSON.stringify(payload), agent, extraEnv: { CC_BRIDGE_HOOK: provider }
});

const queueCalls = () => fs.existsSync(queueLog)
  ? fs.readFileSync(queueLog, "utf8").split("\x1e").filter(Boolean).map((line) => line.split("\0").filter(Boolean))
  : [];

// 状态文件的直接读写，对应原生 CCPetsBridgeStore 的目录布局。
const readJson = (file) => {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
};
const jsonFiles = (directory) => {
  try {
    return fs.readdirSync(directory).filter((name) => name.endsWith(".json")).sort();
  } catch {
    return [];
  }
};
const writeState = (file, value) => {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
};
const store = {
  MESSAGE_BODY_LIMIT: 16 * 1024,
  PAIR_LIMIT_COUNT: 20,
  bridgeDirectory: () => path.join(env.CC_PETS_STATE_DIR, `cc-bridge-${process.getuid()}`),
  isBridgeEnabled: () => fs.existsSync(path.join(env.CC_PETS_HOME, "bridge-enabled")),
  readBridgeOptions: () => readJson(path.join(env.CC_PETS_HOME, "bridge-enabled")) ?? {},
  setBridgeEnabled: (enabled, options = {}) => {
    const file = path.join(env.CC_PETS_HOME, "bridge-enabled");
    if (enabled) writeState(file, options);
    else fs.rmSync(file, { force: true });
  },
  sessionRef: (sessionId) => crypto.createHash("sha1").update(sessionId).digest("hex").slice(0, 6),
  readSession: (sessionId) => readJson(path.join(store.bridgeDirectory(), "sessions", `${sessionId}.json`)),
  listSessions: () => jsonFiles(path.join(store.bridgeDirectory(), "sessions"))
    .map((name) => readJson(path.join(store.bridgeDirectory(), "sessions", name))).filter(Boolean),
  listReceipts: () => jsonFiles(path.join(store.bridgeDirectory(), "sent"))
    .map((name) => readJson(path.join(store.bridgeDirectory(), "sent", name))).filter(Boolean),
  readReceipt: (id) => readJson(path.join(store.bridgeDirectory(), "sent", `${id}.json`)),
  writeReceipt: (message) => writeState(path.join(store.bridgeDirectory(), "sent", `${message.id}.json`), message),
  enqueueInbox: (message) => writeState(path.join(store.bridgeDirectory(), "inbox", message.to.session, `${message.id}.json`), message),
  pendingCount: (sessionId) => jsonFiles(path.join(store.bridgeDirectory(), "inbox", sessionId)).length,
  claimInbox: (sessionId) => {
    for (const name of jsonFiles(path.join(store.bridgeDirectory(), "inbox", sessionId))) {
      fs.rmSync(path.join(store.bridgeDirectory(), "inbox", sessionId, name), { force: true });
    }
  },
  subscriptions: (sessionId) => jsonFiles(path.join(store.bridgeDirectory(), "subscriptions", sessionId)),
  newMessageId: () => `m${Date.now().toString(36)}${crypto.randomBytes(5).toString("hex")}`,
  reservations: () => jsonFiles(path.join(store.bridgeDirectory(), "reservations"))
    .map((name) => readJson(path.join(store.bridgeDirectory(), "reservations", name))).filter(Boolean)
};
// 在线会话按原生 `bridge list` 的输出算：它会顺手把已退出的会话清出注册表。
const liveSessionNames = () => runCli(["list"]).stdout.split("\n")
  .map((line) => line.match(/^(\S+) \[[0-9a-f]{6}\]/)?.[1]).filter(Boolean);
// 当前会话由原生端按祖先进程识别（CC_BRIDGE_AGENT 覆盖），从 list_agents 的抬头里取出名字。
const identifyAs = (agent) => {
  const result = runCli(["mcp"], {
    input: `${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_agents", arguments: {} } })}\n`, agent
  });
  return JSON.parse(result.stdout).result.content[0].text.match(/当前会话是 (\S+) \[/)?.[1] ?? null;
};

const claudeHost = fakeAgent("claude");
const codexHost = fakeAgent("codex");
const claudeAgent = `Claude:${claudeHost.pid}`;
const codexAgent = `Codex:${codexHost.pid}`;
const CLAUDE_SESSION = "11111111-aaaa-4bbb-8ccc-000000000001";
const CODEX_SESSION = "22222222-aaaa-4bbb-8ccc-000000000002";
const cwd = path.join(root, "My Project");

// 1. 未开启时 hook 完全不落盘。
{
  const result = hook("Claude", claudeAgent, { hook_event_name: "SessionStart", session_id: CLAUDE_SESSION, cwd });
  assert.equal(result.status, 0);
  assert.equal(result.stdout, "");
  assert.equal(fs.existsSync(store.bridgeDirectory()), false, "未开启时不应创建状态目录");
}

store.setBridgeEnabled(true);

// 2. 注册：名字、ref、pid、目录权限。
{
  hook("Claude", claudeAgent, { hook_event_name: "SessionStart", session_id: CLAUDE_SESSION, cwd });
  hook("Codex", codexAgent, { hook_event_name: "SessionStart", session_id: CODEX_SESSION, cwd });
  const claude = store.readSession(CLAUDE_SESSION);
  const codex = store.readSession(CODEX_SESSION);
  // 默认名字：<账号名>.<项目目录名>.<动物>；测试环境没有账号名，退回 provider。
  assert.match(claude.name, /^claude\.my-project\.[a-z]+$/);
  assert.match(codex.name, /^codex\.my-project\.[a-z]+$/);
  assert.equal(claude.pid, claudeHost.pid);
  assert.equal(codex.pid, codexHost.pid);
  assert.equal(claude.ref, store.sessionRef(CLAUDE_SESSION));
  assert.equal(claude.status, "idle");
  assert.equal(fs.statSync(store.bridgeDirectory()).mode & 0o777, 0o700);
  assert.equal(liveSessionNames().length, 2);
}
const CLAUDE_NAME = store.readSession(CLAUDE_SESSION).name;
const CODEX_NAME = store.readSession(CODEX_SESSION).name;
const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const CLAUDE_ADDRESS = `${CLAUDE_NAME} [${store.sessionRef(CLAUDE_SESSION)}]`;
const CODEX_ADDRESS = `${CODEX_NAME} [${store.sessionRef(CODEX_SESSION)}]`;
// 自动名称的中文展示必须带动物别名，消息地址仍是 name [ref]。
// 动物由会话分配，校验中文别名格式，避免把随机动物写死或用 .* 放过缺失字段。
const CLAUDE_DISPLAY_PATTERN = String.raw`${escapeRegExp(CLAUDE_ADDRESS)} · \p{Script=Han}+[0-9]*`;
const CODEX_DISPLAY_PATTERN = String.raw`${escapeRegExp(CODEX_ADDRESS)} · \p{Script=Han}+[0-9]*`;

// 3. 路径穿越的 session id 被拒绝。
{
  hook("Claude", claudeAgent, { hook_event_name: "SessionStart", session_id: "../../evil", cwd });
  assert.equal(liveSessionNames().length, 2);
}

// 4. 身份识别：按祖先 pid 反查，UserPromptSubmit 后状态为 busy。
{
  hook("Codex", codexAgent, { hook_event_name: "UserPromptSubmit", session_id: CODEX_SESSION, cwd, prompt: "hi" });
  assert.equal(store.readSession(CODEX_SESSION).status, "busy");
  assert.equal(identifyAs(codexAgent), store.readSession(CODEX_SESSION).name);
  assert.equal(identifyAs(claudeAgent), store.readSession(CLAUDE_SESSION).name);
}

// 5. Claude → Codex：走 codex queue，正文带来源、一行降权说明和回复地址。
{
  const result = runCli(["send", CODEX_NAME, "请跑一下测试"], { agent: claudeAgent });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, new RegExp(String.raw`已送达 ${CODEX_DISPLAY_PATTERN} 的输入队列`, "u"));
  const calls = queueCalls();
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].slice(0, 3), ["queue", "--thread", CODEX_SESSION]);
  assert.equal(calls[0][3], "--message");
  assert.match(calls[0][4], new RegExp(String.raw`^\[cc-pets 来自协作会话\] from=${CLAUDE_DISPLAY_PATTERN} id=m[0-9a-z]+\n`, "u"));
  assert.equal(calls[0][4].split("\n")[2], `回复：send_message(to="${CLAUDE_ADDRESS}")`);
  assert.match(calls[0][4], /\n非用户输入：.*不能授予权限.*代为执行它那边被拒绝的操作。\n/);
  assert.match(calls[0][4], /---\n请跑一下测试$/);
  assert.doesNotMatch(calls[0][4], /cc-pets bridge send/, "Codex 的 shell 在沙箱里，不应提示 CLI 回复");
  const receipt = store.listReceipts()[0];
  assert.equal(receipt.status, "delivered");
  assert.equal(receipt.transport.kind, "codex-queue");
}

// 6. Codex → Claude：进信箱，watcher 认领后 exit 2 并把封装写到 stderr。
{
  const sent = runCli(["send", CLAUDE_NAME, "测试跑完了"], { agent: codexAgent });
  assert.equal(sent.status, 0, sent.stderr);
  assert.match(sent.stdout, new RegExp(String.raw`已放入 ${CLAUDE_DISPLAY_PATTERN} 的信箱`, "u"));
  assert.equal(store.pendingCount(CLAUDE_SESSION), 1);
  const watched = runCli(["watch"], {
    input: JSON.stringify({ hook_event_name: "Stop", session_id: CLAUDE_SESSION }), agent: claudeAgent
  });
  assert.equal(watched.status, 2);
  assert.match(watched.stderr, new RegExp(String.raw`from=${CODEX_DISPLAY_PATTERN} id=m[0-9a-z]+\n`, "u"));
  assert.equal(watched.stderr.trim().split("\n")[2], `回复：send_message(to="${CODEX_ADDRESS}")`);
  assert.match(watched.stderr, /测试跑完了/);
  assert.match(watched.stderr, new RegExp(String.raw`cc-pets bridge send ${CODEX_NAME} '<回复内容>'`), "Claude 收件应带 CLI 回复兜底");
  assert.equal(store.pendingCount(CLAUDE_SESSION), 0);
}

// 7. watcher 空等到期后 exit 0，并释放锁。
{
  const watched = runCli(["watch"], {
    input: JSON.stringify({ hook_event_name: "Stop", session_id: CLAUDE_SESSION }),
    extraEnv: { CC_BRIDGE_WATCH_SECONDS: "0.2" }
  });
  assert.equal(watched.status, 0);
  assert.equal(fs.existsSync(path.join(store.bridgeDirectory(), "locks", `watch-${CLAUDE_SESSION}.pid`)), false);
}

// 8. watcher 接替：新 watcher 取代旧的并重新计时，同一时间只有一个在投递。
{
  const first = spawn(binary, ["bridge", "watch"], {
    env: { ...env, CC_BRIDGE_WATCH_SECONDS: "30" }, stdio: ["pipe", "ignore", "pipe"]
  });
  children.push(first);
  first.stdin.end(JSON.stringify({ hook_event_name: "Stop", session_id: CLAUDE_SESSION }));
  const lock = path.join(store.bridgeDirectory(), "locks", `watch-${CLAUDE_SESSION}.pid`);
  const start = Date.now();
  while (!fs.existsSync(lock) && Date.now() - start < 5000) await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(fs.existsSync(lock), "第一个 watcher 应持有锁");
  const firstExit = new Promise((resolve) => first.on("exit", resolve));
  const second = spawn(binary, ["bridge", "watch"], {
    env: { ...env, CC_BRIDGE_WATCH_SECONDS: "30" }, stdio: ["pipe", "ignore", "pipe"]
  });
  children.push(second);
  const secondExit = new Promise((resolve) => second.on("exit", resolve));
  second.stdin.end(JSON.stringify({ hook_event_name: "Stop", session_id: CLAUDE_SESSION }));
  assert.equal(await firstExit, 0, "旧 watcher 应被取代并正常退出");
  runCli(["send", CLAUDE_NAME, "给接替的 watcher"], { agent: codexAgent });
  assert.equal(await secondExit, 2, "接替的 watcher 应投递消息");
  assert.equal(fs.existsSync(lock), false, "投递后应释放锁");
}

// 9. watcher 不在时，UserPromptSubmit 兜底注入 additionalContext。
{
  runCli(["send", CLAUDE_NAME, "空窗期消息"], { agent: codexAgent });
  const result = hook("Claude", claudeAgent, { hook_event_name: "UserPromptSubmit", session_id: CLAUDE_SESSION, cwd, prompt: "继续" });
  const output = JSON.parse(result.stdout);
  assert.equal(output.hookSpecificOutput.hookEventName, "UserPromptSubmit");
  assert.match(output.hookSpecificOutput.additionalContext, /空窗期消息/);
  assert.equal(store.pendingCount(CLAUDE_SESSION), 0);
  // 没有新消息时仍提供当前身份，但不能再次投递上一条消息。
  const identityOnly = JSON.parse(hook("Claude", claudeAgent, { hook_event_name: "UserPromptSubmit", session_id: CLAUDE_SESSION, cwd }).stdout);
  assert.equal(identityOnly.hookSpecificOutput.additionalContext, output.hookSpecificOutput.additionalContext.split("\n\n")[0]);
}

// 10. 地址解析：不能发给自己；未知目标报错；name [ref] 形式可用。
{
  const self = runCli(["send", CLAUDE_NAME, "自言自语"], { agent: claudeAgent });
  assert.equal(self.status, 1);
  assert.match(self.stderr, /不能给自己发消息/);
  const unknown = runCli(["send", "nobody-1", "hi"], { agent: claudeAgent });
  assert.equal(unknown.status, 1);
  assert.match(unknown.stderr, /没有找到在线会话/);
  const codexRef = store.readSession(CODEX_SESSION).ref;
  const withRef = runCli(["send", `${CODEX_NAME} [${codexRef}]`, "带 ref"], { agent: claudeAgent });
  assert.equal(withRef.status, 0, withRef.stderr);
}

// 11. 超长消息被拒绝。
{
  const result = runCli(["send", CODEX_NAME, "x".repeat(store.MESSAGE_BODY_LIMIT + 1)], { agent: claudeAgent });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /上限/);
}

// 12. MCP：握手、工具列表、list_agents / send_message / check_inbox。
{
  const requests = [
    { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } } },
    { jsonrpc: "2.0", method: "notifications/initialized" },
    { jsonrpc: "2.0", id: 2, method: "tools/list" },
    { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "list_agents", arguments: {} } },
    { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "send_message", arguments: { to: CLAUDE_NAME, message: "来自 MCP" } } },
    { jsonrpc: "2.0", id: 5, method: "nope" }
  ];
  const result = runCli(["mcp"], { input: `${requests.map((request) => JSON.stringify(request)).join("\n")}\n`, agent: codexAgent });
  const responses = result.stdout.trim().split("\n").map((line) => JSON.parse(line));
  const byId = Object.fromEntries(responses.map((response) => [response.id, response]));
  assert.equal(responses.length, 5, "通知不应有回复");
  assert.equal(byId[1].result.protocolVersion, "2025-06-18");
  assert.deepEqual(byId[2].result.tools.map((tool) => tool.name), ["list_agents", "send_message", "set_name", "reserve_files", "release_files", "list_reservations", "check_inbox"]);
  const listText = byId[3].result.content[0].text;
  assert.match(listText, new RegExp(String.raw`当前会话是 ${CODEX_DISPLAY_PATTERN}`, "u"));
  assert.match(listText, new RegExp(String.raw`${CLAUDE_DISPLAY_PATTERN}  ·  Claude`, "u"));
  assert.doesNotMatch(listText.split("\n\n")[1], new RegExp(String.raw`${CODEX_NAME}`), "列表不应包含自己");
  assert.equal(byId[4].result.isError, undefined);
  assert.match(byId[4].result.content[0].text, new RegExp(String.raw`已放入 ${CLAUDE_DISPLAY_PATTERN} 的信箱`, "u"));
  assert.equal(byId[5].error.code, -32601);
  // "pet / 桌宠"别名：server instructions 与主要工具描述都要带上，且注明业务代码里的 pet 不算。
  assert.match(byId[1].result.instructions, /pet、桌宠、cc-pets/);
  for (const name of ["list_agents", "send_message", "reserve_files"]) {
    const description = byId[2].result.tools.find((tool) => tool.name === name).description;
    assert.match(description, /用 pet 发给 web/, `${name} 的描述应包含 pet 别名`);
    assert.match(description, /业务代码里的 pet，不要调用本工具/, `${name} 的描述应排除业务代码里的 pet`);
  }

  const inbox = runCli(["mcp"], {
    input: `${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "check_inbox", arguments: {} } })}\n`,
    agent: claudeAgent
  });
  assert.match(JSON.parse(inbox.stdout).result.content[0].text, /来自 MCP/);
}

// 13. 空闲订阅：Stop 后订阅者收到一次性通知（经 codex queue 投给 Codex 订阅者）。
{
  const before = queueCalls().length;
  const request = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "send_message", arguments: { to: CLAUDE_NAME, message: "做完告诉我", notify_when_idle: true } } };
  const sent = runCli(["mcp"], { input: `${JSON.stringify(request)}\n`, agent: codexAgent });
  assert.match(JSON.parse(sent.stdout).result.content[0].text, /已订阅/);
  hook("Claude", claudeAgent, { hook_event_name: "Stop", session_id: CLAUDE_SESSION, cwd });
  const start = Date.now();
  while (queueCalls().length === before && Date.now() - start < 10000) await new Promise((resolve) => setTimeout(resolve, 50));
  const notice = queueCalls().at(-1);
  assert.equal(notice[2], CODEX_SESSION);
  assert.match(notice[4], /from=cc-pets/);
  assert.match(notice[4], /空闲通知/);
  assert.equal(store.subscriptions(CLAUDE_SESSION).length, 0, "订阅应是一次性的");
  claimInboxQuietly();
}

function claimInboxQuietly() {
  store.claimInbox(CLAUDE_SESSION);
}

// 14. 目标 Codex 离线：不调用 queue（防止 resume 时执行过期任务），离线会话被清出注册表。
{
  const before = queueCalls().length;
  codexHost.kill("SIGKILL");
  await new Promise((resolve) => codexHost.on("exit", resolve));
  const codexName = store.readSession(CODEX_SESSION).name;
  const result = runCli(["send", codexName, "你还在吗"], { agent: claudeAgent });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /没有找到在线会话/);
  assert.equal(queueCalls().length, before);
  assert.equal(store.readSession(CODEX_SESSION), null, "离线会话应被清出注册表");
}

// 15. 配对限流：同一对会话短时间内往来过多被拒绝。
{
  const codexHost2 = fakeAgent("codex");
  const CODEX2 = "33333333-aaaa-4bbb-8ccc-000000000003";
  hook("Codex", `Codex:${codexHost2.pid}`, { hook_event_name: "SessionStart", session_id: CODEX2, cwd });
  const target = store.readSession(CODEX2);
  for (let index = 0; index < store.PAIR_LIMIT_COUNT; index += 1) {
    store.writeReceipt({ id: store.newMessageId(), from: { session: CODEX2 }, to: { session: CLAUDE_SESSION }, body: "x", createdAt: Date.now(), status: "delivered" });
  }
  const result = runCli(["send", target.name, "再来一条"], { agent: claudeAgent });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /循环/);
}

// 16. SessionEnd：移出注册表，信箱里未投递的消息标记 undeliverable。
{
  const codexHost3 = fakeAgent("codex");
  const CODEX3 = "44444444-aaaa-4bbb-8ccc-000000000004";
  hook("Codex", `Codex:${codexHost3.pid}`, { hook_event_name: "SessionStart", session_id: CODEX3, cwd });
  const message = { id: store.newMessageId(), from: { session: CLAUDE_SESSION }, to: { session: CLAUDE_SESSION, name: "x" }, body: "b", createdAt: Date.now(), status: "pending" };
  store.writeReceipt(message);
  store.enqueueInbox(message);
  hook("Claude", claudeAgent, { hook_event_name: "SessionEnd", session_id: CLAUDE_SESSION });
  assert.equal(store.readSession(CLAUDE_SESSION), null);
  assert.equal(store.readReceipt(message.id).status, "undeliverable");
}

// 17. 安装 / 卸载：保留用户已有配置，只增删自己的条目；Codex 审批块可移除。
{
  const settingsPath = path.join(env.CLAUDE_CONFIG_DIR, "settings.json");
  const hooksPath = path.join(env.CODEX_HOME, "hooks.json");
  const configPath = path.join(env.CODEX_HOME, "config.toml");
  const userSettings = { theme: "dark", hooks: { Stop: [{ hooks: [{ type: "command", command: "echo user" }] }] } };
  fs.writeFileSync(settingsPath, `${JSON.stringify(userSettings, null, 2)}\n`);
  fs.writeFileSync(hooksPath, `${JSON.stringify({ hooks: { Stop: [{ hooks: [{ type: "command", command: "echo codex-user" }] }] } }, null, 2)}\n`);
  const userToml = 'model = "x"\n\n[mcp_servers.other]\ncommand = "y"\n';
  fs.writeFileSync(configPath, userToml);

  store.setBridgeEnabled(false);
  const enabled = runCli(["enable", "--codex-approve=list_agents,check_inbox"]);
  assert.equal(enabled.status, 0, enabled.stderr);
  assert.equal(store.isBridgeEnabled(), true);
  const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  assert.equal(settings.theme, "dark");
  assert.equal(settings.hooks.Stop[0].hooks[0].command, "echo user");
  const bridgeHandlers = Object.values(settings.hooks).flat().flatMap((group) => group.hooks)
    .filter((handler) => handler.command.startsWith("CC_BRIDGE_HOOK=Claude"));
  assert.equal(bridgeHandlers.length, 7);
  const claudePreToolUse = settings.hooks.PreToolUse.find((group) => group.hooks.some((handler) => handler.command.startsWith("CC_BRIDGE_HOOK=")));
  assert.equal(claudePreToolUse.matcher, "Edit|Write|MultiEdit|NotebookEdit", "预留提醒只应挂在编辑类工具上");
  const watchers = Object.entries(settings.hooks).flatMap(([event, groups]) => groups.flatMap((group) => group.hooks)
    .filter((handler) => handler.asyncRewake === true).map((handler) => ({ event, handler })));
  assert.deepEqual(watchers.map((entry) => entry.event).sort(), ["SessionStart", "Stop"],
    "watcher 不应挂在 UserPromptSubmit 上（回合中途触发会显示成报错）");
  assert.ok(watchers.every((entry) => entry.handler.timeout === 3600));
  const codexHooks = JSON.parse(fs.readFileSync(hooksPath, "utf8"));
  assert.equal(codexHooks.hooks.Stop[0].hooks[0].command, "echo codex-user");
  assert.equal(Object.values(codexHooks.hooks).flat().flatMap((group) => group.hooks)
    .filter((handler) => handler.command.startsWith("CC_BRIDGE_HOOK=Codex")).length, 5);
  const toml = fs.readFileSync(configPath, "utf8");
  assert.match(toml, /\[mcp_servers\.cc-bridge\.tools\.list_agents\]\napproval_mode = "approve"/);
  assert.doesNotMatch(toml, /tools\.send_message/);

  // 重复 enable 不会叠加条目。
  runCli(["enable"]);
  const again = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  assert.equal(Object.values(again.hooks).flat().flatMap((group) => group.hooks)
    .filter((handler) => handler.command.startsWith("CC_BRIDGE_HOOK=")).length, 7);
  assert.match(fs.readFileSync(configPath, "utf8"), /tools\.list_agents/, "不带选项的 enable 应保留原选项");
  runCli(["enable", "--codex-approve="]);
  assert.doesNotMatch(fs.readFileSync(configPath, "utf8"), /cc-bridge/, "--codex-approve= 应清空审批块");

  const disabled = runCli(["disable"]);
  assert.equal(disabled.status, 0, disabled.stderr);
  assert.equal(store.isBridgeEnabled(), false);
  assert.deepEqual(JSON.parse(fs.readFileSync(settingsPath, "utf8")), userSettings);
  assert.equal(JSON.parse(fs.readFileSync(hooksPath, "utf8")).hooks.Stop[0].hooks[0].command, "echo codex-user");
  assert.equal(fs.readFileSync(configPath, "utf8"), userToml);
}

// 18. 自定义名字：CC_BRIDGE_NAME 注册、重名追加序号、非法名字回退、set_name 改名与冲突。
{
  store.setBridgeEnabled(true);
  const hostA = fakeAgent("claude");
  const hostB = fakeAgent("claude");
  const hostC = fakeAgent("claude");
  const SA = "55555555-aaaa-4bbb-8ccc-000000000005";
  const SB = "66666666-aaaa-4bbb-8ccc-000000000006";
  const SC = "77777777-aaaa-4bbb-8ccc-000000000007";
  runCli(["hook"], { input: JSON.stringify({ hook_event_name: "SessionStart", session_id: SA, cwd }),
    agent: `Claude:${hostA.pid}`, extraEnv: { CC_BRIDGE_HOOK: "Claude", CC_BRIDGE_NAME: "Frontend" } });
  runCli(["hook"], { input: JSON.stringify({ hook_event_name: "SessionStart", session_id: SB, cwd }),
    agent: `Claude:${hostB.pid}`, extraEnv: { CC_BRIDGE_HOOK: "Claude", CC_BRIDGE_NAME: "frontend" } });
  runCli(["hook"], { input: JSON.stringify({ hook_event_name: "SessionStart", session_id: SC, cwd }),
    agent: `Claude:${hostC.pid}`, extraEnv: { CC_BRIDGE_HOOK: "Claude", CC_BRIDGE_NAME: "bad name [x]" } });
  assert.equal(store.readSession(SA).name, "frontend", "名字应统一转小写");
  assert.equal(store.readSession(SB).name, "frontend-2", "重名应追加序号");
  assert.match(store.readSession(SC).name, /^claude\.my-project\.[a-z]+$/, "非法名字应回退到自动命名");
  // 已注册的会话再次收到事件不会被 CC_BRIDGE_NAME 改名。
  runCli(["hook"], { input: JSON.stringify({ hook_event_name: "UserPromptSubmit", session_id: SA, cwd }),
    agent: `Claude:${hostA.pid}`, extraEnv: { CC_BRIDGE_HOOK: "Claude", CC_BRIDGE_NAME: "other" } });
  assert.equal(store.readSession(SA).name, "frontend");

  const call = (agent, name, args) => JSON.parse(runCli(["mcp"], {
    input: `${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } })}\n`, agent
  }).stdout).result;
  const renamed = call(`Claude:${hostC.pid}`, "set_name", { name: "api-server" });
  assert.equal(renamed.isError, undefined, renamed.content[0].text);
  assert.equal(store.readSession(SC).name, "api-server");
  const conflict = call(`Claude:${hostC.pid}`, "set_name", { name: "frontend" });
  assert.equal(conflict.isError, true);
  assert.match(conflict.content[0].text, /已被 frontend/);
  const invalid = call(`Claude:${hostC.pid}`, "set_name", { name: "has space" });
  assert.equal(invalid.isError, true);
  // 改名后新名字可寻址。
  const sent = runCli(["send", "api-server", "改名后能收到吗"], { agent: `Claude:${hostA.pid}` });
  assert.equal(sent.status, 0, sent.stderr);
  // CLI 改名。
  const cliRename = runCli(["name", "web"], { agent: `Claude:${hostB.pid}` });
  assert.equal(cliRename.status, 0, cliRename.stderr);
  assert.equal(store.readSession(SB).name, "web");
  // list_agents 带 tty 列（假宿主进程没有控制终端，显示为 -）。
  assert.match(call(`Claude:${hostA.pid}`, "list_agents", {}).content[0].text, /api-server \[[0-9a-f]{6}\]  ·  Claude  ·  (idle|busy)  ·  -  ·/);

  // 多账号：默认名字以账号名开头；同账号同项目的会话动物各不相同；超长目录名截断后仍不超过 40 个字符。
  const hostD = fakeAgent("claude");
  const hostE = fakeAgent("claude");
  const hostF = fakeAgent("claude");
  const SD = "88888888-aaaa-4bbb-8ccc-000000000008";
  const SE = "99999999-aaaa-4bbb-8ccc-000000000009";
  const SF = "aaaaaaaa-aaaa-4bbb-8ccc-00000000000a";
  const register = (host, session, profileName, directory = cwd) => runCli(["hook"], {
    input: JSON.stringify({ hook_event_name: "SessionStart", session_id: session, cwd: directory }),
    agent: `Claude:${host.pid}`, extraEnv: { CC_BRIDGE_HOOK: "Claude", CC_PETS_PROFILE_NAME: profileName }
  });
  register(hostD, SD, "Claude X");
  register(hostE, SE, "Claude X");
  register(hostF, SF, "工作号", path.join(root, "a-really-long-project-directory-name-for-names"));
  const nameD = store.readSession(SD).name;
  const nameE = store.readSession(SE).name;
  const nameF = store.readSession(SF).name;
  assert.match(nameD, /^claude-x\.my-project\.[a-z]+$/);
  assert.match(nameE, /^claude-x\.my-project\.[a-z]+$/);
  assert.notEqual(nameD, nameE, "同前缀的在线会话不应重名");
  assert.match(nameF, /^claude\.a-really-long[a-z-]*\.[a-z]+$/, "账号名无法转成 slug 时退回 provider");
  assert.ok(nameF.length <= 40, nameF);
}

// 19. 从旧名 Agent Bus 迁移：旧开关、旧标记 hooks、旧审批块在 enable 后被清理，不留两套。
{
  const settingsPath = path.join(env.CLAUDE_CONFIG_DIR, "settings.json");
  const hooksPath = path.join(env.CODEX_HOME, "hooks.json");
  const configPath = path.join(env.CODEX_HOME, "config.toml");
  store.setBridgeEnabled(false);
  fs.writeFileSync(path.join(env.CC_PETS_HOME, "bus-enabled"), `${JSON.stringify({ codexApprove: ["list_agents"] })}\n`);
  const legacyHook = (provider, sub) => ({ type: "command", command: `CC_PETS_BUS_HOOK=${provider} '/n' '/old/scripts/bus/cli.mjs' ${sub}` });
  fs.writeFileSync(settingsPath, JSON.stringify({ hooks: {
    Stop: [{ hooks: [legacyHook("Claude", "hook")] }, { hooks: [{ type: "command", command: "echo keep" }] }],
    UserPromptSubmit: [{ hooks: [{ ...legacyHook("Claude", "watch"), asyncRewake: true }] }]
  } }, null, 2));
  fs.writeFileSync(hooksPath, JSON.stringify({ hooks: { Stop: [{ hooks: [legacyHook("Codex", "hook")] }] } }, null, 2));
  fs.writeFileSync(configPath, 'model = "x"\n\n# >>> cc-pets-bus >>>\n[mcp_servers.cc-pets-bus.tools.list_agents]\napproval_mode = "approve"\n# <<< cc-pets-bus <<<\n');

  const refreshed = runCli(["refresh"]);
  assert.equal(refreshed.status, 0, refreshed.stderr);
  assert.equal(fs.existsSync(path.join(env.CC_PETS_HOME, "bus-enabled")), false, "旧开关应被迁移");
  assert.equal(store.isBridgeEnabled(), true, "迁移后仍应视为已开启，refresh 才会重写集成");
  assert.deepEqual(store.readBridgeOptions().codexApprove, ["list_agents"], "应保留旧版的审批选项");
  const commands = (file) => Object.values(JSON.parse(fs.readFileSync(file, "utf8")).hooks).flat()
    .flatMap((group) => group.hooks).map((handler) => handler.command);
  assert.equal(commands(settingsPath).filter((command) => command.startsWith("CC_PETS_BUS_HOOK=")).length, 0);
  assert.equal(commands(settingsPath).filter((command) => command.startsWith("CC_BRIDGE_HOOK=")).length, 7);
  assert.ok(commands(settingsPath).includes("echo keep"));
  assert.equal(commands(hooksPath).filter((command) => command.startsWith("CC_PETS_BUS_HOOK=")).length, 0);
  const toml = fs.readFileSync(configPath, "utf8");
  assert.doesNotMatch(toml, /cc-pets-bus/);
  assert.match(toml, /\[mcp_servers\.cc-bridge\.tools\.list_agents\]/);
}

// 20. 文件预留：模式匹配、冲突、编辑前提醒、释放、过期、会话结束自动释放。
{
  // 模式匹配、路径规范化、补丁解析等纯逻辑见 bridge-units-harness.m，这里只测端到端。
  const reservations = { activeReservations: () => store.reservations() };
  const hostA = store.listSessions().find((session) => session.name === "frontend");
  const hostC = store.listSessions().find((session) => session.name === "api-server");
  assert.ok(hostA && hostC, "沿用第 18 组注册的会话");
  const agentA = `Claude:${hostA.pid}`;
  const agentC = `Claude:${hostC.pid}`;
  const call = (agent, name, args = {}) => JSON.parse(runCli(["mcp"], {
    input: `${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } })}\n`, agent
  }).stdout).result;
  const preToolUse = (agent, sessionId, toolInput) => runCli(["hook"], {
    input: JSON.stringify({ hook_event_name: "PreToolUse", session_id: sessionId, cwd, tool_name: "Edit", tool_input: toolInput }),
    agent, extraEnv: { CC_BRIDGE_HOOK: "Claude" }
  });

  const reserved = call(agentA, "reserve_files", { paths: ["src/api/**"], reason: "重构登录接口" });
  assert.equal(reserved.isError, undefined, reserved.content[0].text);
  assert.match(reserved.content[0].text, /预留 1 处/);
  assert.doesNotMatch(reserved.content[0].text, /重叠/);

  const conflicted = call(agentC, "reserve_files", { paths: ["src/api/user.ts"], ttl_minutes: 10 });
  assert.match(conflicted.content[0].text, /重叠/);
  assert.match(conflicted.content[0].text, /frontend \[[0-9a-f]{6}\]/);
  assert.match(conflicted.content[0].text, /重构登录接口/);

  const outside = call(agentA, "reserve_files", { paths: ["/etc/passwd"] });
  assert.equal(outside.isError, true, "仓库外路径应拒绝");
  assert.equal(call(agentA, "reserve_files", { paths: ["a"], ttl_minutes: 0 }).isError, true);

  // 首次拦截、重试放行：C 第一次改 A 预留的文件 → deny 并说明；重试 → 放行；
  // A 改自己预留的 → 不拦；改未预留的 → 不拦。
  const denied = preToolUse(agentC, hostC.session, { file_path: path.join(cwd, "src/api/login.ts") });
  const decision = JSON.parse(denied.stdout).hookSpecificOutput;
  assert.equal(decision.hookEventName, "PreToolUse");
  assert.equal(decision.permissionDecision, "deny", "第一次应暂停");
  assert.match(decision.permissionDecisionReason, /src\/api\/login\.ts：src\/api\/\*\*  ·  frontend/);
  assert.match(decision.permissionDecisionReason, /直接重试同一操作即可放行/);
  assert.match(decision.permissionDecisionReason, /在给用户的回复里说明/, "放行后应告知用户预留情况");
  assert.equal(preToolUse(agentC, hostC.session, { file_path: path.join(cwd, "src/api/login.ts") }).stdout, "",
    "重试应放行");
  assert.equal(preToolUse(agentC, hostC.session, { file_path: path.join(cwd, "src/api/other.ts") }).stdout, "",
    "同一处预留确认过之后，改其下其他文件也放行");
  assert.equal(preToolUse(agentA, hostA.session, { file_path: path.join(cwd, "src/api/login.ts") }).stdout, "");
  assert.equal(preToolUse(agentC, hostC.session, { file_path: path.join(cwd, "README.md") }).stdout, "");
  // Codex 的补丁输入同样会被拦（另一个会话 B 尚未确认过）。
  const hostB = store.listSessions().find((session) => session.name === "web");
  const codexDenied = runCli(["hook"], {
    input: JSON.stringify({ hook_event_name: "PreToolUse", session_id: hostB.session, cwd, tool_name: "apply_patch",
      tool_input: { command: `*** Begin Patch\n*** Add File: ${path.join(cwd, "src/api/new.ts")}\n+x\n*** End Patch` } }),
    agent: `Claude:${hostB.pid}`, extraEnv: { CC_BRIDGE_HOOK: "Codex" }
  });
  assert.equal(JSON.parse(codexDenied.stdout).hookSpecificOutput.permissionDecision, "deny");

  const listed = call(agentC, "list_agents").content[0].text;
  assert.ok(reservations.activeReservations().some((entry) => entry.session === hostC.session),
    "list_agents 不能把调用者自己的预留当成孤儿删掉");
  assert.match(listed, /frontend \[[0-9a-f]{6}\].*预留 1 处/);
  assert.match(call(agentC, "list_reservations").content[0].text, /src\/api\/\*\*.*frontend/);
  assert.match(call(agentC, "list_reservations", { path: "src/api/x.ts" }).content[0].text, /frontend/);

  // 续期：重复预留同一路径不产生第二条，且保留已放行名单（C 不会被重新拦）。
  call(agentA, "reserve_files", { paths: ["src/api/**"], reason: "重构登录接口" });
  assert.equal(reservations.activeReservations().filter((entry) => entry.session === hostA.session).length, 1);
  assert.equal(preToolUse(agentC, hostC.session, { file_path: path.join(cwd, "src/api/login.ts") }).stdout, "",
    "续期后已确认的会话仍应放行");

  // 释放后不再提醒。
  assert.match(call(agentA, "release_files").content[0].text, /已释放 1 处/);
  assert.equal(preToolUse(agentC, hostC.session, { file_path: path.join(cwd, "src/api/login.ts") }).stdout, "");

  // 过期自动失效（下一次读取预留时顺手清掉）。
  call(agentA, "reserve_files", { paths: ["docs/**"] });
  const directory = path.join(store.bridgeDirectory(), "reservations");
  for (const name of fs.readdirSync(directory)) {
    const file = path.join(directory, name);
    const record = JSON.parse(fs.readFileSync(file, "utf8"));
    if (record.pattern === "docs/**") fs.writeFileSync(file, JSON.stringify({ ...record, expiresAt: Date.now() - 1 }));
  }
  assert.doesNotMatch(call(agentC, "list_reservations").content[0].text, /docs\/\*\*/);
  assert.equal(reservations.activeReservations().some((entry) => entry.pattern === "docs/**"), false);

  // 会话结束自动释放（C 还持有 src/api/user.ts）。
  assert.ok(reservations.activeReservations().some((entry) => entry.session === hostC.session));
  runCli(["hook"], { input: JSON.stringify({ hook_event_name: "SessionEnd", session_id: hostC.session }),
    agent: agentC, extraEnv: { CC_BRIDGE_HOOK: "Claude" } });
  assert.equal(reservations.activeReservations().some((entry) => entry.session === hostC.session), false);
}

// 21. 选项：分组展开、合并语义、configure 不重注册 MCP、Claude 放行规则、关闭唤醒 / 编辑拦截。
{
  // 分组展开、合并语义等解析逻辑见 bridge-units-harness.m。
  const settingsPath = path.join(env.CLAUDE_CONFIG_DIR, "settings.json");
  const hooksPath = path.join(env.CODEX_HOME, "hooks.json");
  const configPath = path.join(env.CODEX_HOME, "config.toml");
  fs.writeFileSync(settingsPath, `${JSON.stringify({ permissions: { allow: ["Bash(npm test)"], deny: ["Read(.env)"] } }, null, 2)}\n`);
  fs.writeFileSync(hooksPath, "{}\n");
  fs.writeFileSync(configPath, 'model = "x"\n');
  store.setBridgeEnabled(false);

  assert.equal(runCli(["configure", "--wake=off"]).status, 1, "未开启时 configure 应失败");
  const enabled = runCli(["enable", "--approve=view,send"]);
  assert.equal(enabled.status, 0, enabled.stderr);
  let settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  assert.deepEqual(settings.permissions.allow, ["Bash(npm test)", "mcp__cc-bridge__list_agents",
    "mcp__cc-bridge__list_reservations", "mcp__cc-bridge__check_inbox", "mcp__cc-bridge__send_message"]);
  assert.deepEqual(settings.permissions.deny, ["Read(.env)"], "不碰用户其他权限规则");
  assert.match(fs.readFileSync(configPath, "utf8"), /tools\.send_message\]/);

  // configure：关闭唤醒与编辑拦截 → 不装 watcher、不装 PreToolUse；只改 Claude 放行，Codex 不变。
  const configured = runCli(["configure", "--wake=off", "--edit-guard=off", "--claude-allow=name"]);
  assert.equal(configured.status, 0, configured.stderr);
  assert.match(configured.stdout, /自动唤醒空闲会话：关/);
  settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  const claudeHandlers = Object.entries(settings.hooks).flatMap(([event, groups]) =>
    groups.flatMap((group) => group.hooks.map((handler) => ({ event, handler }))));
  assert.equal(claudeHandlers.filter((entry) => entry.handler.asyncRewake).length, 0, "关闭唤醒后不应安装 watcher");
  assert.equal(claudeHandlers.filter((entry) => entry.event === "PreToolUse").length, 0, "关闭拦截后不应安装 PreToolUse");
  assert.deepEqual(settings.permissions.allow, ["Bash(npm test)", "mcp__cc-bridge__set_name"]);
  const codexHooks = JSON.parse(fs.readFileSync(hooksPath, "utf8"));
  assert.equal(codexHooks.hooks.PreToolUse, undefined);
  assert.match(fs.readFileSync(configPath, "utf8"), /tools\.send_message\]/, "只改 Claude 时 Codex 审批不变");
  assert.deepEqual(store.readBridgeOptions().claudeAllow, ["set_name"]);

  // 关闭唤醒：发给 Codex 的消息不走 codex queue，进信箱；watcher 直接退出；编辑拦截不生效。
  const liveCodex = fakeAgent("codex");
  const CODEX5 = "88888888-aaaa-4bbb-8ccc-000000000008";
  hook("Codex", `Codex:${liveCodex.pid}`, { hook_event_name: "SessionStart", session_id: CODEX5, cwd });
  const sender = store.listSessions().find((session) => session.name === "frontend");
  const queueBefore = queueCalls().length;
  const sent = runCli(["send", store.readSession(CODEX5).name, "不唤醒"], { agent: `Claude:${sender.pid}` });
  assert.equal(sent.status, 0, sent.stderr);
  assert.match(sent.stdout, /未开启自动唤醒/);
  assert.equal(queueCalls().length, queueBefore, "关闭唤醒后不应调用 codex queue");
  assert.equal(store.pendingCount(CODEX5), 1);
  const injected = hook("Codex", `Codex:${liveCodex.pid}`, { hook_event_name: "UserPromptSubmit", session_id: CODEX5, cwd });
  assert.match(JSON.parse(injected.stdout).hookSpecificOutput.additionalContext, /不唤醒/, "用户开口时带入");
  const watched = runCli(["watch"], { input: JSON.stringify({ hook_event_name: "Stop", session_id: sender.session }),
    extraEnv: { CC_BRIDGE_WATCH_SECONDS: "5" } });
  assert.equal(watched.status, 0, "关闭唤醒后 watcher 应立即退出");
  const reserved = JSON.parse(runCli(["mcp"], {
    input: `${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "reserve_files", arguments: { paths: ["guarded/**"] } } })}\n`,
    agent: `Claude:${sender.pid}`
  }).stdout).result;
  assert.equal(reserved.isError, undefined, reserved.content[0].text);
  const unguarded = runCli(["hook"], {
    input: JSON.stringify({ hook_event_name: "PreToolUse", session_id: CODEX5, cwd, tool_name: "apply_patch",
      tool_input: { command: `*** Begin Patch\n*** Add File: ${path.join(cwd, "guarded/a.ts")}\n*** End Patch` } }),
    agent: `Codex:${liveCodex.pid}`, extraEnv: { CC_BRIDGE_HOOK: "Codex" }
  });
  assert.equal(unguarded.stdout, "", "关闭拦截后不应暂停编辑");

  // disable：Claude 放行规则一并移除，用户自己的规则保留。
  runCli(["disable"]);
  settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  assert.deepEqual(settings.permissions, { allow: ["Bash(npm test)"], deny: ["Read(.env)"] });
}

// 22. 桌宠侧的约定：refresh 未开启时也写 CLI 定位（cc-pets 本身 + 终端里的 PATH，桌宠从 Finder 启动时没有 nvm 的 PATH）。
{
  const locator = path.join(env.CC_PETS_HOME, "bridge-cli.json");
  fs.rmSync(locator, { force: true });
  store.setBridgeEnabled(false);
  assert.equal(runCli(["refresh"]).status, 0);
  const written = JSON.parse(fs.readFileSync(locator, "utf8"));
  assert.equal(written.binary, binary, "定位文件应指向当前的 cc-pets");
  assert.equal(written.path, env.PATH);
  assert.equal(fs.statSync(locator).mode & 0o777, 0o600);
}

// 23. codex queue 能力探测：新版支持、旧版把 queue 当成交互参数打出总帮助、找不到可执行文件。
{
  // 探测本身的各种情况见 bridge-units-harness.m；这里测 enable 时把不支持的情况写进报告。
  const oldCodex = path.join(root, "bin/codex-old");
  fs.writeFileSync(oldCodex, `#!/bin/sh
if [ "$1" = "--version" ]; then echo "codex-cli 0.100.0"; exit 0; fi
echo "Codex CLI"
echo "If no subcommand is specified, options will be forwarded to the interactive CLI."
exit 0
`, { mode: 0o755 });
  // enable 时把不支持的情况写进报告；不支持也照样开启。
  store.setBridgeEnabled(false);
  // 探测只在注册 MCP 时跑，所以这里要放开 CC_BRIDGE_SKIP_MCP；claude 换成假的，绝不能碰到真实 CLI。
  const fakeClaude = path.join(root, "bin/claude-noop");
  fs.writeFileSync(fakeClaude, "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  const enabled = runCli(["enable"], {
    extraEnv: { CODEX_REAL_BIN: oldCodex, CLAUDE_REAL_BIN: fakeClaude, CC_BRIDGE_SKIP_MCP: "0" }
  });
  assert.equal(enabled.status, 0, enabled.stderr);
  assert.match(enabled.stdout, /不支持 codex queue/);
  assert.equal(store.isBridgeEnabled(), true);
  runCli(["disable"], { extraEnv: { CODEX_REAL_BIN: oldCodex, CLAUDE_REAL_BIN: fakeClaude } });
}

// 24. 共享宿主下的显式 session_id：多个 Codex 会话共用一个 app-server PID 时，
// 不传参数一律拒绝冒认；传参数只认属于当前宿主的在线会话，无效时不回退到 PID 匹配。
{
  store.setBridgeEnabled(true);
  const sharedHost = fakeAgent("codex");
  const otherHost = fakeAgent("codex");
  const recipientHost = fakeAgent("claude");
  const shared = `Codex:${sharedHost.pid}`;
  const SHARED_A = "88888888-aaaa-4bbb-8ccc-000000000008";
  const SHARED_B = "99999999-aaaa-4bbb-8ccc-000000000009";
  const OTHER = "aaaaaaaa-aaaa-4bbb-8ccc-00000000000a";
  const RECIPIENT = "bbbbbbbb-aaaa-4bbb-8ccc-00000000000b";

  // SessionStart 与 UserPromptSubmit 都把当前 session_id 注入上下文。
  const started = JSON.parse(hook("Codex", shared, { hook_event_name: "SessionStart", session_id: SHARED_A, cwd }).stdout);
  assert.equal(started.hookSpecificOutput.hookEventName, "SessionStart");
  assert.match(started.hookSpecificOutput.additionalContext, new RegExp(`session_id 是 ${SHARED_A}`));
  hook("Codex", shared, { hook_event_name: "SessionStart", session_id: SHARED_B, cwd });
  hook("Codex", `Codex:${otherHost.pid}`, { hook_event_name: "SessionStart", session_id: OTHER, cwd });
  hook("Claude", `Claude:${recipientHost.pid}`, { hook_event_name: "SessionStart", session_id: RECIPIENT, cwd });
  const prompted = JSON.parse(hook("Codex", shared, { hook_event_name: "UserPromptSubmit", session_id: SHARED_B, cwd }).stdout);
  assert.match(prompted.hookSpecificOutput.additionalContext, new RegExp(`session_id 是 ${SHARED_B}`));
  const recipientName = store.readSession(RECIPIENT).name;

  const call = (name, args, agent = shared) => JSON.parse(runCli(["mcp"], {
    input: `${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } })}\n`, agent
  }).stdout).result;

  // 所有工具的 schema 都带可选的 session_id。
  const listed = JSON.parse(runCli(["mcp"], {
    input: `${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} })}\n`, agent: shared
  }).stdout).result.tools;
  assert.ok(listed.length > 0);
  for (const tool of listed) {
    assert.equal(tool.inputSchema.properties.session_id?.type, "string", `${tool.name} 缺少 session_id`);
    assert.ok(!(tool.inputSchema.required ?? []).includes("session_id"), `${tool.name} 不应强制 session_id`);
  }

  // 不传参数：同一 PID 下两个会话，只能匿名查看，不能以会话身份操作。
  const anonymous = call("list_agents", {});
  assert.equal(anonymous.isError, undefined);
  assert.match(anonymous.content[0].text, /当前会话身份缺失或不明确/);
  assert.doesNotMatch(anonymous.content[0].text, /当前会话是 /);
  const before = store.listReceipts().length;
  const refused = call("send_message", { to: recipientName, message: "不该发出" });
  assert.equal(refused.isError, true);
  assert.match(refused.content[0].text, /多个会话共享宿主 PID/);
  assert.equal(store.listReceipts().length, before, "身份不明确时不应产生消息");

  // 传参数：同一 PID 下的两个会话各自被正确识别，发出的消息 from 对得上。
  for (const [sessionId, body] of [[SHARED_A, "来自 A"], [SHARED_B, "来自 B"]]) {
    const self = store.readSession(sessionId);
    const listedAs = call("list_agents", { session_id: sessionId });
    assert.equal(listedAs.isError, undefined, listedAs.content[0].text);
    assert.match(listedAs.content[0].text, new RegExp(String.raw`当前会话是 ${self.name} \[${self.ref}\]`));
    const sent = call("send_message", { session_id: sessionId, to: recipientName, message: body });
    assert.equal(sent.isError, undefined, sent.content[0].text);
    const id = sent.content[0].text.match(/(m[0-9a-z]+)\s*$/)?.[1];
    assert.ok(id, sent.content[0].text);
    const receipt = store.readReceipt(id);
    assert.equal(receipt.from.session, sessionId);
    assert.equal(receipt.from.name, self.name);
    assert.equal(receipt.body, undefined, "回执不应保存正文");
  }

  // 无效的显式身份：一律报错，且不回退到 PID 唯一匹配（OTHER 所在宿主只有它一个会话，
  // 回退的话会被认出来）。
  const invalidIds = [
    ["另一宿主的会话", SHARED_A, `Codex:${otherHost.pid}`],
    ["不存在的会话", "cccccccc-aaaa-4bbb-8ccc-00000000000c", `Codex:${otherHost.pid}`],
    ["provider 不符", RECIPIENT, `Codex:${otherHost.pid}`],
    ["路径穿越", "../../evil", `Codex:${otherHost.pid}`],
    ["空串", "", `Codex:${otherHost.pid}`],
    ["null", null, `Codex:${otherHost.pid}`],
    ["非字符串", 42, `Codex:${otherHost.pid}`]
  ];
  for (const [label, sessionId, agent] of invalidIds) {
    for (const [name, args] of [["list_agents", {}], ["send_message", { to: recipientName, message: "x" }]]) {
      const count = store.listReceipts().length;
      const result = call(name, { ...args, session_id: sessionId }, agent);
      assert.equal(result.isError, true, `${label} / ${name} 应报错：${result.content[0].text}`);
      assert.match(result.content[0].text, /无效的 session_id/, `${label} / ${name}`);
      assert.equal(store.listReceipts().length, count, `${label} / ${name} 不应产生消息`);
    }
  }
  // 对照：同一宿主不传参数时 PID 唯一匹配仍然可用，说明上面的报错来自显式参数校验。
  assert.equal(identifyAs(`Codex:${otherHost.pid}`), store.readSession(OTHER).name);

  // 离线后同一个 ID 不再可用。
  sharedHost.kill("SIGKILL");
  await new Promise((resolve) => sharedHost.once("exit", resolve));
  const offline = call("list_agents", { session_id: SHARED_A });
  assert.equal(offline.isError, true);
  assert.match(offline.content[0].text, /无效的 session_id/);
}

// 25. config.toml：只动自己的管理块。用户多行字符串里的连续空行和长得像标记的文本都要逐字保留。
{
  const configPath = path.join(env.CODEX_HOME, "config.toml");
  const userToml = [
    'prompt = """',
    "first",
    "",
    "",
    "",
    "# >>> cc-bridge >>>",
    "not a block",
    "# <<< cc-bridge <<<",
    '"""',
    "literal = \'\'\'",
    "",
    "",
    "",
    "\'\'\'",
    "",
    "",
    "",
    'model = "x"',
    ""
  ].join("\n");
  fs.writeFileSync(configPath, userToml);
  store.setBridgeEnabled(false);
  assert.equal(runCli(["enable", "--codex-approve=check_inbox"]).status, 0);
  const installed = fs.readFileSync(configPath, "utf8");
  assert.ok(installed.startsWith(userToml), "enable 只能在文件末尾追加管理块");
  assert.match(installed, /tools\.check_inbox/);
  assert.equal(runCli(["configure", "--codex-approve=list_agents"]).status, 0);
  const reconfigured = fs.readFileSync(configPath, "utf8");
  assert.ok(reconfigured.startsWith(userToml), "configure 不应改动用户内容");
  assert.doesNotMatch(reconfigured.slice(userToml.length), /check_inbox/, "旧管理块应被替换");
  assert.equal(reconfigured.match(/>>> cc-bridge >>>/g).length, 2, "只应多出一个真实的管理块");
  assert.equal(runCli(["disable"]).status, 0);
  assert.equal(fs.readFileSync(configPath, "utf8"), userToml, "disable 后应逐字还原");

  // 没有管理块时什么都不写。
  const untouched = 'model = "x"   \n\n\n\n';
  fs.writeFileSync(configPath, untouched);
  assert.equal(runCli(["enable"]).status, 0);
  assert.equal(runCli(["disable"]).status, 0);
  assert.equal(fs.readFileSync(configPath, "utf8"), untouched, "没有管理块时不应改写文件");
  store.setBridgeEnabled(true);
}

// 26. 显式 session_id 被拒绝时说明原因。
{
  const host = fakeAgent("codex");
  const otherHost = fakeAgent("codex");
  const SESSION = "cccccccc-aaaa-4bbb-8ccc-00000000000c";
  hook("Codex", `Codex:${host.pid}`, { hook_event_name: "SessionStart", session_id: SESSION, cwd });
  const call = (agent, session_id) => JSON.parse(runCli(["mcp"], {
    input: `${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_agents", arguments: { session_id } } })}\n`, agent
  }).stdout).result;
  const foreign = call(`Codex:${otherHost.pid}`, SESSION);
  assert.equal(foreign.isError, true);
  assert.match(foreign.content[0].text, /属于其他宿主进程/);
  const unknown = call(`Codex:${host.pid}`, "dddddddd-aaaa-4bbb-8ccc-00000000000d");
  assert.equal(unknown.isError, true);
  assert.match(unknown.content[0].text, /不是已注册的在线会话/);
}

// 27. 没有 SessionEnd 的离线会话：消息、回执、订阅都要收尾，正文不能留在磁盘上。
{
  const bridgeDirectory = store.bridgeDirectory();
  const victim = fakeAgent("claude");
  const survivor = fakeAgent("claude");
  const VICTIM = "eeeeeeee-aaaa-4bbb-8ccc-00000000000e";
  const SURVIVOR = "ffffffff-aaaa-4bbb-8ccc-00000000000f";
  hook("Claude", `Claude:${victim.pid}`, { hook_event_name: "SessionStart", session_id: VICTIM, cwd });
  hook("Claude", `Claude:${survivor.pid}`, { hook_event_name: "SessionStart", session_id: SURVIVOR, cwd });
  const pending = (to, createdAt = Date.now()) => {
    const message = { id: store.newMessageId(), from: { session: SURVIVOR, name: "s", ref: "000000" }, to: { session: to, name: "x" }, body: "正文", createdAt, status: "pending" };
    store.writeReceipt(message);
    store.enqueueInbox(message);
    return message;
  };

  // 被查询到离线时立即收尾。
  const lost = pending(VICTIM);
  writeState(path.join(bridgeDirectory, "subscriptions", VICTIM, `${SURVIVOR}.json`), { subscriber: SURVIVOR, createdAt: Date.now() });
  victim.kill("SIGKILL");
  await new Promise((resolve) => victim.once("exit", resolve));
  runCli(["list"]);
  assert.equal(store.readSession(VICTIM), null);
  assert.equal(store.readReceipt(lost.id).status, "undeliverable");
  for (const kind of ["inbox", "claimed", "subscriptions"]) {
    assert.equal(fs.existsSync(path.join(bridgeDirectory, kind, VICTIM)), false, `${kind} 目录应被清理`);
  }

  // 注册表已经没有记录的孤儿信箱，由 SessionStart 扫描兜底。
  const ORPHAN = "12121212-aaaa-4bbb-8ccc-000000000012";
  const orphaned = pending(ORPHAN);
  writeState(path.join(bridgeDirectory, "subscriptions", ORPHAN, `${SURVIVOR}.json`), { subscriber: SURVIVOR, createdAt: Date.now() });
  // 在线会话里过期的消息要收尾，没过期的不动。
  const dayAndAHalf = 36 * 60 * 60 * 1000;
  const expired = pending(SURVIVOR, Date.now() - dayAndAHalf);
  const fresh = pending(SURVIVOR);
  // 已经没有信箱文件、却还停在 pending 的旧回执。
  const stranded = { id: store.newMessageId(), from: { session: SURVIVOR }, to: { session: ORPHAN }, body: "正文", createdAt: Date.now() - dayAndAHalf, status: "pending" };
  store.writeReceipt(stranded);
  const started = hook("Claude", `Claude:${survivor.pid}`, { hook_event_name: "SessionStart", session_id: SURVIVOR, cwd });
  assert.match(JSON.parse(started.stdout).hookSpecificOutput.additionalContext, /session_id 是/);
  assert.equal(store.readReceipt(orphaned.id).status, "undeliverable");
  assert.equal(fs.existsSync(path.join(bridgeDirectory, "inbox", ORPHAN)), false);
  assert.equal(fs.existsSync(path.join(bridgeDirectory, "subscriptions", ORPHAN)), false);
  assert.equal(store.readReceipt(expired.id).status, "expired");
  assert.equal(store.readReceipt(fresh.id).status, "pending");
  assert.equal(store.readReceipt(stranded.id).status, "expired");
  assert.deepEqual(jsonFiles(path.join(bridgeDirectory, "inbox", SURVIVOR)), [`${fresh.id}.json`]);

  // 正常结束时订阅也要清掉。
  writeState(path.join(bridgeDirectory, "subscriptions", SURVIVOR, "someone.json"), { subscriber: "someone", createdAt: Date.now() });
  hook("Claude", `Claude:${survivor.pid}`, { hook_event_name: "SessionEnd", session_id: SURVIVOR });
  assert.equal(fs.existsSync(path.join(bridgeDirectory, "subscriptions", SURVIVOR)), false);
}

// 28. 预留：参数校验零副作用；目录与 glob 的冲突能被发现；并发时不丢冲突、不丢确认。
{
  const hostA = fakeAgent("claude");
  const hostB = fakeAgent("claude");
  const agentA = `Claude:${hostA.pid}`;
  const agentB = `Claude:${hostB.pid}`;
  // macOS 的 /tmp 本身是软链；预留记录里的仓库根是物理路径。
  const repo = path.join(fs.realpathSync(root), "reservation-repo");
  fs.mkdirSync(repo, { recursive: true });
  hook("Claude", agentA, { hook_event_name: "SessionStart", session_id: "13131313-aaaa-4bbb-8ccc-000000000013", cwd: repo });
  hook("Claude", agentB, { hook_event_name: "SessionStart", session_id: "14141414-aaaa-4bbb-8ccc-000000000014", cwd: repo });
  const request = (name, args) => `${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } })}\n`;
  const call = (agent, name, args = {}) => JSON.parse(runCli(["mcp"], { input: request(name, args), agent }).stdout).result;
  const callAsync = (agent, name, args) => new Promise((resolve, reject) => {
    const child = spawn(binary, ["bridge", "mcp"], { env: { ...env, CC_BRIDGE_AGENT: agent }, stdio: ["pipe", "pipe", "ignore"] });
    let output = "";
    child.stdout.on("data", (chunk) => { output += chunk; });
    child.on("error", reject);
    child.on("close", () => resolve(JSON.parse(output).result));
    child.stdin.end(request(name, args));
  });

  call(agentA, "reserve_files", { paths: ["src/api", "keep.ts"] });
  for (const paths of ["src/api", null, 42, [42]]) {
    const refused = call(agentA, "release_files", { paths });
    assert.equal(refused.isError, true, `paths=${JSON.stringify(paths)} 应报错`);
    assert.match(refused.content[0].text, /字符串数组/);
  }
  assert.equal(store.reservations().filter((entry) => entry.root === repo).length, 2, "非法参数不能释放任何预留");

  const overlapping = call(agentB, "reserve_files", { paths: ["src/**/*.ts"] });
  assert.match(overlapping.content[0].text, /src\/api/, "目录与其下文件的 glob 应报冲突");
  call(agentB, "release_files");
  assert.match(call(agentA, "release_files").content[0].text, /已释放 2 处/);

  // 两个会话同时预留同一路径：无论谁先，后写的一方都必须看到冲突。
  for (let round = 0; round < 10; round += 1) {
    const target = `race-${round}.ts`;
    const results = await Promise.all([agentA, agentB].map((agent) => callAsync(agent, "reserve_files", { paths: [target] })));
    assert.ok(results.some((result) => /重叠|⚠️/.test(result.content[0].text)), `第 ${round} 轮两边都没看到冲突`);
  }
  call(agentA, "release_files");
  call(agentB, "release_files");

  // 多个会话同时第一次编辑同一处预留：确认名单不能互相覆盖。
  call(agentA, "reserve_files", { paths: ["shared/**"] });
  const editors = Array.from({ length: 6 }, (_, index) => {
    const host = fakeAgent("claude");
    const session = `15151515-aaaa-4bbb-8ccc-00000000001${index}`;
    hook("Claude", `Claude:${host.pid}`, { hook_event_name: "SessionStart", session_id: session, cwd: repo });
    return { agent: `Claude:${host.pid}`, session };
  });
  await Promise.all(editors.map(({ agent, session }) => new Promise((resolve, reject) => {
    const child = spawn(binary, ["bridge", "hook"], { env: { ...env, CC_BRIDGE_AGENT: agent, CC_BRIDGE_HOOK: "Claude" }, stdio: ["pipe", "ignore", "ignore"] });
    child.on("error", reject);
    child.on("close", resolve);
    child.stdin.end(JSON.stringify({ hook_event_name: "PreToolUse", session_id: session, cwd: repo, tool_name: "Edit", tool_input: { file_path: "shared/a.ts" } }));
  })));
  const shared = store.reservations().find((entry) => entry.root === repo && entry.pattern === "shared/**");
  assert.equal(shared.acknowledgedBy.length, editors.length, "并发确认不应丢失");
  call(agentA, "release_files");
}

// 29. 限流：并发发送不能一起越过上限，超出的请求不留下回执。
{
  const senderHost = fakeAgent("claude");
  const receiverHost = fakeAgent("claude");
  const SENDER = "16161616-aaaa-4bbb-8ccc-000000000016";
  const RECEIVER = "17171717-aaaa-4bbb-8ccc-000000000017";
  hook("Claude", `Claude:${senderHost.pid}`, { hook_event_name: "SessionStart", session_id: SENDER, cwd });
  hook("Claude", `Claude:${receiverHost.pid}`, { hook_event_name: "SessionStart", session_id: RECEIVER, cwd });
  const receiverName = store.readSession(RECEIVER).name;
  for (let index = 0; index < store.PAIR_LIMIT_COUNT - 2; index += 1) {
    store.writeReceipt({ id: store.newMessageId(), from: { session: SENDER }, to: { session: RECEIVER }, body: "x", createdAt: Date.now(), status: "delivered" });
  }
  const results = await Promise.all(Array.from({ length: 8 }, (_, index) => new Promise((resolve, reject) => {
    const child = spawn(binary, ["bridge", "send", receiverName, `并发 ${index}`], { env: { ...env, CC_BRIDGE_AGENT: `Claude:${senderHost.pid}` }, stdio: "ignore" });
    child.on("error", reject);
    child.on("close", resolve);
  })));
  assert.equal(results.filter((status) => status === 0).length, 2, "只应放行到上限为止");
  const paired = store.listReceipts().filter((receipt) => receipt.from?.session === SENDER && receipt.to?.session === RECEIVER);
  assert.equal(paired.length, store.PAIR_LIMIT_COUNT, "回执数不应超过上限");
}

// 30. 软链：一个会话从软链路径进入目录，另一个从物理路径进入，预留仍然互相可见。
{
  const physicalRepo = path.join(fs.realpathSync(root), "linked-repo-real");
  const aliasRepo = path.join(fs.realpathSync(root), "linked-repo-alias");
  fs.mkdirSync(physicalRepo, { recursive: true });
  fs.symlinkSync(physicalRepo, aliasRepo);
  const viaAlias = fakeAgent("claude");
  const viaPhysical = fakeAgent("claude");
  const ALIAS = "18181818-aaaa-4bbb-8ccc-000000000018";
  const PHYSICAL = "19191919-aaaa-4bbb-8ccc-000000000019";
  hook("Claude", `Claude:${viaAlias.pid}`, { hook_event_name: "SessionStart", session_id: ALIAS, cwd: aliasRepo });
  hook("Claude", `Claude:${viaPhysical.pid}`, { hook_event_name: "SessionStart", session_id: PHYSICAL, cwd: physicalRepo });
  const reserved = JSON.parse(runCli(["mcp"], {
    input: `${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "reserve_files", arguments: { paths: ["new.ts"] } } })}\n`,
    agent: `Claude:${viaAlias.pid}`
  }).stdout).result;
  assert.notEqual(reserved.isError, true, reserved.content[0].text);
  const edit = runCli(["hook"], {
    input: JSON.stringify({ hook_event_name: "PreToolUse", session_id: PHYSICAL, cwd: physicalRepo, tool_name: "Write", tool_input: { file_path: path.join(physicalRepo, "new.ts") } }),
    agent: `Claude:${viaPhysical.pid}`, extraEnv: { CC_BRIDGE_HOOK: "Claude" }
  });
  assert.equal(JSON.parse(edit.stdout).hookSpecificOutput.permissionDecision, "deny", "尚不存在的新文件也应命中预留");
}

// 31. 卸载：只认真正的 MCP 声明，路径或其他服务器参数里出现相同文字不算；真正的声明不能漏。
{
  const configPath = path.join(env.CODEX_HOME, "config.toml");
  const disableWithMcp = () => {
    store.setBridgeEnabled(true);
    return runCli(["disable"], { extraEnv: { CC_BRIDGE_SKIP_MCP: "0" } });
  };
  for (const unrelated of [
    '[projects."/Users/me/cc-bridge"]\ntrust_level = "trusted"\n',
    '[mcp_servers.my-cc-bridge-tools]\ncommand = "cc-bridge"\n',
    '[mcp_servers.other.env]\ncc-bridge = "1"\n',
    'note = """\n[mcp_servers.cc-bridge]\n"""\n',
    'mcp_servers = { other = { cc-bridge = 1, note = "cc-bridge = 1" } }\n',
    // 单引号键是字面量，这里的 - 不是连字符。
    "['mcp_servers'.'cc\\u002dbridge']\ncommand = 'x'\n",
    // 不合法的转义不解码，也就不等于 cc-bridge。
    '["mcp_servers"."cc\\uZZZZbridge"]\ncommand = "x"\n'
  ]) {
    fs.writeFileSync(configPath, unrelated);
    const result = disableWithMcp();
    assert.equal(result.status, 0, `不应误报：${unrelated}\n${result.stdout}`);
  }
  // 假 codex 的 mcp remove 总是失败，所以“没能移除”的报错证明确实认出了声明。
  for (const declared of [
    '["mcp_servers"."cc-bridge"]\ncommand = "x"\n',
    '["mcp_servers"."cc\\u002dbridge"]\ncommand = "x"\n',
    '["mcp_servers"."cc\\U0000002dbridge"]\ncommand = "x"\n',
    '"mcp\\u005fservers".cc-bridge.command = "x"\n',
    'mcp_servers = { "cc\\u002dbridge" = { command = "x" } }\n',
    "[ 'mcp_servers' . cc-bridge ]\ncommand = 'x'\n",
    '[["mcp_servers"."cc-bridge".items]]\ncommand = "x"\n',
    '"mcp_servers".cc-bridge.command = "x"\n',
    '"mcp_servers" = { "other" = {}, "cc-bridge" = { command = "x" } }\n',
    '[mcp_servers.cc-bridge]\ncommand = "x"\n',
    '[mcp_servers."cc-bridge"]\ncommand = "x"\n',
    '[mcp_servers]\ncc-bridge = { command = "x" }\n',
    'mcp_servers.cc-bridge.command = "x"\n',
    'mcp_servers = { cc-bridge = { command = "x" } }\n'
  ]) {
    fs.writeFileSync(configPath, declared);
    const result = disableWithMcp();
    assert.equal(result.status, 1, `应识别出声明：${declared}`);
    assert.match(result.stdout, /cc-bridge/);
  }
  fs.writeFileSync(configPath, 'model = "x"\n');
  store.setBridgeEnabled(true);
}

// 32. CLI 参数：正文可以写任意文字；拼错的选项和缺值的参数要报错。
{
  const host = fakeAgent("claude");
  const peer = fakeAgent("claude");
  const SESSION = "20202020-aaaa-4bbb-8ccc-000000000020";
  const PEER = "21212121-aaaa-4bbb-8ccc-000000000021";
  hook("Claude", `Claude:${host.pid}`, { hook_event_name: "SessionStart", session_id: SESSION, cwd });
  hook("Claude", `Claude:${peer.pid}`, { hook_event_name: "SessionStart", session_id: PEER, cwd });
  const peerName = store.readSession(PEER).name;
  const agent = `Claude:${host.pid}`;
  const sent = runCli(["send", peerName, "改一下", "--from", "参数"], { agent });
  assert.equal(sent.status, 0, sent.stderr);
  const receipt = store.listReceipts().filter((entry) => entry.to?.session === PEER).at(-1);
  const delivered = readJson(path.join(store.bridgeDirectory(), "inbox", PEER, `${receipt.id}.json`));
  assert.equal(delivered.body, "改一下 --from 参数", "正文里的 --from 不是选项");
  assert.equal(receipt.from.session, SESSION);
  const explicit = runCli(["send", "--from", store.readSession(SESSION).name, peerName, "显式身份"]);
  assert.equal(explicit.status, 0, explicit.stderr);
  const trailing = runCli(["send", "--from"], { agent });
  assert.equal(trailing.status, 1);
  assert.match(trailing.stderr, /--from 需要一个值/);

  const typo = runCli(["configure", "--wkae=off"]);
  assert.equal(typo.status, 1);
  assert.match(typo.stderr, /未知选项：--wkae=off/);
  assert.equal(store.readBridgeOptions().wake ?? true, true, "选项报错时不能改配置");
  const missing = runCli(["configure", "--wake"]);
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /--wake 需要一个值/);
}

// 33. MCP：非法 UTF-8 也要回复，后面的请求不受影响；身份不明时不查 MCP 进程自己的目录。
{
  const request = `${JSON.stringify({ jsonrpc: "2.0", id: 7, method: "ping" })}\n`;
  const result = spawnSync(binary, ["bridge", "mcp"], {
    input: Buffer.concat([Buffer.from([0xff, 0xfe, 0x0a]), Buffer.from(request)]),
    env, encoding: "utf8"
  });
  const [invalid, ping] = result.stdout.trim().split("\n").map((line) => JSON.parse(line));
  assert.equal(invalid.error.code, -32700);
  assert.equal(ping.id, 7);

  const anonymous = JSON.parse(runCli(["mcp"], {
    input: `${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_reservations", arguments: {} } })}\n`,
    agent: "Codex:999999"
  }).stdout).result;
  assert.equal(anonymous.isError, true);
  assert.match(anonymous.content[0].text, /当前会话身份缺失或不明确/);
}

// 34. 回执不含正文：信箱里的消息送达后，磁盘上不再有这段文字。
{
  const reader = fakeAgent("claude");
  const writer = fakeAgent("claude");
  const READER = "22222222-bbbb-4bbb-8ccc-000000000022";
  const WRITER = "23232323-bbbb-4bbb-8ccc-000000000023";
  hook("Claude", `Claude:${reader.pid}`, { hook_event_name: "SessionStart", session_id: READER, cwd });
  hook("Claude", `Claude:${writer.pid}`, { hook_event_name: "SessionStart", session_id: WRITER, cwd });
  const secret = "PLAINTEXT-MARKER-34";
  assert.equal(runCli(["send", store.readSession(READER).name, secret], { agent: `Claude:${writer.pid}` }).status, 0);
  const injected = hook("Claude", `Claude:${reader.pid}`, { hook_event_name: "UserPromptSubmit", session_id: READER, cwd });
  assert.match(JSON.parse(injected.stdout).hookSpecificOutput.additionalContext, new RegExp(secret));
  const scan = (directory) => fs.readdirSync(directory, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile()).some((entry) => fs.readFileSync(path.join(entry.parentPath, entry.name), "utf8").includes(secret));
  assert.equal(scan(store.bridgeDirectory()), false, "送达后正文不应留在状态目录");
}

// 35. codex queue 超时：结果未知，消息进信箱兜底，并告诉发送方可能重复。明确失败时不这么说。
{
  const receiver = fakeAgent("codex");
  const sender = fakeAgent("claude");
  const RECEIVER = "24242424-bbbb-4bbb-8ccc-000000000024";
  const SENDER = "25252525-bbbb-4bbb-8ccc-000000000025";
  hook("Codex", `Codex:${receiver.pid}`, { hook_event_name: "SessionStart", session_id: RECEIVER, cwd });
  hook("Claude", `Claude:${sender.pid}`, { hook_event_name: "SessionStart", session_id: SENDER, cwd });
  const slowCodex = path.join(root, "bin/codex-slow");
  fs.writeFileSync(slowCodex, "#!/bin/sh\nexec sleep 5\n", { mode: 0o755 });
  const failingCodex = path.join(root, "bin/codex-failing");
  fs.writeFileSync(failingCodex, "#!/bin/sh\necho nope >&2\nexit 1\n", { mode: 0o755 });
  const name = store.readSession(RECEIVER).name;
  const agent = `Claude:${sender.pid}`;
  const timedOut = runCli(["send", name, "超时的消息"], { agent, extraEnv: { CODEX_REAL_BIN: slowCodex, CC_BRIDGE_QUEUE_TIMEOUT_SECONDS: "0.2" } });
  assert.equal(timedOut.status, 0, timedOut.stderr);
  assert.match(timedOut.stdout, /可能以相同的消息 id 到达两次/);
  const uncertain = store.listReceipts().find((entry) => entry.uncertain === true);
  assert.equal(uncertain.status, "pending");
  assert.equal(store.pendingCount(RECEIVER), 1, "超时后仍要进信箱，不能丢");
  const failed = runCli(["send", name, "失败的消息"], { agent, extraEnv: { CODEX_REAL_BIN: failingCodex } });
  assert.equal(failed.status, 0, failed.stderr);
  assert.doesNotMatch(failed.stdout, /到达两次/);
  assert.equal(store.pendingCount(RECEIVER), 2);
}

// 36. release_files：不传 paths 才是全部释放，空数组什么都不释放。
{
  const host = fakeAgent("claude");
  const repo = path.join(fs.realpathSync(root), "empty-release-repo");
  fs.mkdirSync(repo, { recursive: true });
  hook("Claude", `Claude:${host.pid}`, { hook_event_name: "SessionStart", session_id: "26262626-bbbb-4bbb-8ccc-000000000026", cwd: repo });
  const call = (name, args = {}) => JSON.parse(runCli(["mcp"], {
    input: `${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } })}\n`, agent: `Claude:${host.pid}`
  }).stdout).result;
  const held = () => store.reservations().filter((entry) => entry.root === repo).length;
  call("reserve_files", { paths: ["a.ts", "b.ts"] });
  const nothing = call("release_files", { paths: [] });
  assert.notEqual(nothing.isError, true);
  assert.match(nothing.content[0].text, /没有可释放/);
  assert.equal(held(), 2, "空数组不应释放任何预留");
  call("release_files");
  assert.equal(held(), 0);
}

// 37. disable：未投递的消息立即收尾，已送达的回执留作记录。
{
  const bridgeDirectory = store.bridgeDirectory();
  const host = fakeAgent("claude");
  const SESSION = "27272727-bbbb-4bbb-8ccc-000000000027";
  hook("Claude", `Claude:${host.pid}`, { hook_event_name: "SessionStart", session_id: SESSION, cwd });
  const queued = { id: store.newMessageId(), from: { session: "x" }, to: { session: SESSION, name: "x" }, body: "正文", createdAt: Date.now(), status: "pending" };
  store.writeReceipt(queued);
  store.enqueueInbox(queued);
  const done = { id: store.newMessageId(), from: { session: "x" }, to: { session: SESSION, name: "x" }, createdAt: Date.now(), status: "delivered" };
  store.writeReceipt(done);
  const disabled = runCli(["disable"]);
  assert.equal(disabled.status, 0, disabled.stderr);
  const receipt = store.readReceipt(queued.id);
  assert.equal(receipt.status, "undeliverable");
  assert.match(receipt.reason, /CC Bridge/);
  assert.equal(fs.existsSync(path.join(bridgeDirectory, "inbox", SESSION)), false, "未投递的正文不应留在磁盘上");
  assert.equal(store.readReceipt(done.id).status, "delivered", "已送达的回执应保留");
  store.setBridgeEnabled(true);
}

// 38. codex queue 无法启动（找不到可执行文件、接收方 Home 未知）：消息照常进信箱，不能抛异常丢掉。
{
  const receiver = fakeAgent("codex");
  const sender = fakeAgent("claude");
  const RECEIVER = "28282828-bbbb-4bbb-8ccc-000000000028";
  const SENDER = "29292929-bbbb-4bbb-8ccc-000000000029";
  hook("Codex", `Codex:${receiver.pid}`, { hook_event_name: "SessionStart", session_id: RECEIVER, cwd });
  hook("Claude", `Claude:${sender.pid}`, { hook_event_name: "SessionStart", session_id: SENDER, cwd });
  const agent = `Claude:${sender.pid}`;
  const name = store.readSession(RECEIVER).name;
  const noBinary = runCli(["send", name, "找不到 codex"], { agent, extraEnv: { CODEX_REAL_BIN: "", PATH: "/nonexistent" } });
  assert.equal(noBinary.status, 0, noBinary.stderr);
  assert.equal(store.pendingCount(RECEIVER), 1);
  const record = store.readSession(RECEIVER);
  delete record.home;
  delete record.profileId;
  writeState(path.join(store.bridgeDirectory(), "sessions", `${RECEIVER}.json`), record);
  const noHome = runCli(["send", name, "Home 未知"], { agent });
  assert.equal(noHome.status, 0, noHome.stderr);
  assert.equal(store.pendingCount(RECEIVER), 2);
  assert.equal(store.listReceipts().filter((entry) => entry.to?.session === RECEIVER).every((entry) => entry.status === "pending"), true);
}

// 39. 发送卡在 codex queue 时用户关闭 Bridge：回退信箱要被拒绝，正文不能留在磁盘上。
{
  const receiver = fakeAgent("codex");
  const sender = fakeAgent("claude");
  const RECEIVER = "30303030-bbbb-4bbb-8ccc-000000000030";
  const SENDER = "31313131-bbbb-4bbb-8ccc-000000000031";
  hook("Codex", `Codex:${receiver.pid}`, { hook_event_name: "SessionStart", session_id: RECEIVER, cwd });
  hook("Claude", `Claude:${sender.pid}`, { hook_event_name: "SessionStart", session_id: SENDER, cwd });
  const started = path.join(root, "queue-started");
  const slowCodex = path.join(root, "bin/codex-marking");
  // 握手而不是超时：假 codex 一直等到 disable 做完才失败退出，负载再高时序也不变。
  const proceed = path.join(root, "queue-proceed");
  fs.writeFileSync(slowCodex, `#!/bin/sh\ntouch '${started}'\nwhile [ ! -e '${proceed}' ]; do sleep 0.02; done\nexit 1\n`, { mode: 0o755 });
  const name = store.readSession(RECEIVER).name;
  const sending = spawn(binary, ["bridge", "send", name, "关闭时还在发"], {
    env: { ...env, CC_BRIDGE_AGENT: `Claude:${sender.pid}`, CODEX_REAL_BIN: slowCodex }, stdio: "ignore"
  });
  children.push(sending);
  const finished = new Promise((resolve) => sending.on("exit", resolve));
  const start = Date.now();
  while (!fs.existsSync(started) && Date.now() - start < 20000) await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(fs.existsSync(started), "发送应已进入 codex queue");
  assert.equal(runCli(["disable"]).status, 0);
  fs.writeFileSync(proceed, "");
  assert.equal(await finished, 1, "被拒绝的投递应报告失败");
  assert.equal(store.pendingCount(RECEIVER), 0, "Bridge 关闭后不应写入信箱");
  const receipt = store.listReceipts().find((entry) => entry.from?.session === SENDER);
  assert.equal(receipt.status, "undeliverable");
  store.setBridgeEnabled(true);
}

// 40. 会话结束时，还在等待的 watcher 随之退出；已离线的目标不再收信。
{
  const host = fakeAgent("claude");
  const SESSION = "32323232-bbbb-4bbb-8ccc-000000000032";
  hook("Claude", `Claude:${host.pid}`, { hook_event_name: "SessionStart", session_id: SESSION, cwd });
  const watcher = spawn(binary, ["bridge", "watch"], { env: { ...env, CC_BRIDGE_WATCH_SECONDS: "30" }, stdio: ["pipe", "ignore", "ignore"] });
  children.push(watcher);
  const exited = new Promise((resolve) => watcher.on("exit", resolve));
  watcher.stdin.end(JSON.stringify({ hook_event_name: "Stop", session_id: SESSION }));
  const lock = path.join(store.bridgeDirectory(), "locks", `watch-${SESSION}.pid`);
  const start = Date.now();
  while (!fs.existsSync(lock) && Date.now() - start < 5000) await new Promise((resolve) => setTimeout(resolve, 20));
  hook("Claude", `Claude:${host.pid}`, { hook_event_name: "SessionEnd", session_id: SESSION });
  assert.equal(await exited, 0, "SessionEnd 后 watcher 应退出");
}

console.log("bridge-harness: all passed");
process.exit(0);
