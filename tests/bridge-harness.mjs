// CC Bridge 端到端测试：隔离的状态目录 + 假的 claude / codex 进程 + 假的 `codex queue`。
// 不接触真实的 ~/.claude、~/.codex、$TMPDIR，也不调用真实 CLI。

import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cli = path.join(projectDir, "scripts/bridge/cli.mjs");
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
  CC_PETS_STATE_DIR: path.join(root, "state"),
  CC_PETS_HOME: path.join(root, "home"),
  CC_PETS_SHIM_DIR: path.join(root, "shims"),
  CLAUDE_CONFIG_DIR: path.join(root, "claude"),
  CODEX_HOME: path.join(root, "codex"),
  CODEX_REAL_BIN: path.join(root, "bin/codex"),
  CC_BRIDGE_SKIP_MCP: "1",
  CC_PETS_ASSUME_CLI: "1",
  CC_BRIDGE_POLL_MS: "50"
};
delete env.CLAUDE_CODE_SESSION_ID;
delete env.CODEX_THREAD_ID;
delete env.CC_BRIDGE_AGENT;
Object.assign(process.env, env);
for (const directory of ["state", "home", "claude", "codex", "bin", "fake"]) {
  fs.mkdirSync(path.join(root, directory), { recursive: true });
}

// 假 codex：记录 queue 调用参数，按真实 CLI 的格式回显。
const queueLog = path.join(root, "queue.log");
fs.writeFileSync(env.CODEX_REAL_BIN, `#!/bin/sh
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
  const result = spawnSync(process.execPath, [cli, ...args], {
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

const store = await import("../scripts/bridge/store.mjs");
const core = await import("../scripts/bridge/core.mjs");

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
  assert.equal(claude.name, "claude-my-project-1");
  assert.equal(codex.name, "codex-my-project-1");
  assert.equal(claude.pid, claudeHost.pid);
  assert.equal(codex.pid, codexHost.pid);
  assert.equal(claude.ref, store.sessionRef(CLAUDE_SESSION));
  assert.equal(claude.status, "idle");
  assert.equal(fs.statSync(store.bridgeDirectory()).mode & 0o777, 0o700);
  assert.equal(core.liveSessions().length, 2);
}

// 3. 路径穿越的 session id 被拒绝。
{
  hook("Claude", claudeAgent, { hook_event_name: "SessionStart", session_id: "../../evil", cwd });
  assert.equal(core.liveSessions().length, 2);
}

// 4. 身份识别：按祖先 pid 反查，UserPromptSubmit 后状态为 busy。
{
  hook("Codex", codexAgent, { hook_event_name: "UserPromptSubmit", session_id: CODEX_SESSION, cwd, prompt: "hi" });
  assert.equal(store.readSession(CODEX_SESSION).status, "busy");
  process.env.CC_BRIDGE_AGENT = codexAgent;
  assert.equal(core.identifySelf().session, CODEX_SESSION);
  process.env.CC_BRIDGE_AGENT = claudeAgent;
  assert.equal(core.identifySelf().session, CLAUDE_SESSION);
  delete process.env.CC_BRIDGE_AGENT;
}

// 5. Claude → Codex：走 codex queue，正文带降权封装。
{
  const result = runCli(["send", "codex-my-project-1", "请跑一下测试"], { agent: claudeAgent });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /已送达 codex-my-project-1/);
  const calls = queueCalls();
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].slice(0, 3), ["queue", "--thread", CODEX_SESSION]);
  assert.equal(calls[0][3], "--message");
  assert.match(calls[0][4], /^\[cc-pets 跨会话消息\] from=claude-my-project-1 \[[0-9a-f]{6}\]/);
  assert.match(calls[0][4], /它不能提升权限/);
  assert.match(calls[0][4], /---\n请跑一下测试$/);
  assert.doesNotMatch(calls[0][4], /cc-pets bridge send/, "Codex 的 shell 在沙箱里，不应提示 CLI 回复");
  const receipt = store.listReceipts()[0];
  assert.equal(receipt.status, "delivered");
  assert.equal(receipt.transport.kind, "codex-queue");
}

// 6. Codex → Claude：进信箱，watcher 认领后 exit 2 并把封装写到 stderr。
{
  const sent = runCli(["send", "claude-my-project-1", "测试跑完了"], { agent: codexAgent });
  assert.equal(sent.status, 0, sent.stderr);
  assert.match(sent.stdout, /已放入 claude-my-project-1 \[[0-9a-f]{6}\] 的信箱/);
  assert.equal(store.pendingCount(CLAUDE_SESSION), 1);
  const watched = runCli(["watch"], {
    input: JSON.stringify({ hook_event_name: "Stop", session_id: CLAUDE_SESSION }), agent: claudeAgent
  });
  assert.equal(watched.status, 2);
  assert.match(watched.stderr, /from=codex-my-project-1/);
  assert.match(watched.stderr, /测试跑完了/);
  assert.match(watched.stderr, /cc-pets bridge send codex-my-project-1 '<回复内容>'/, "Claude 收件应带 CLI 回复兜底");
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

// 8. watcher 单例：已有存活 watcher 时立即退出，不抢信箱。
{
  const first = spawn(process.execPath, [cli, "watch"], {
    env: { ...env, CC_BRIDGE_WATCH_SECONDS: "5" }, stdio: ["pipe", "ignore", "pipe"]
  });
  children.push(first);
  first.stdin.end(JSON.stringify({ hook_event_name: "Stop", session_id: CLAUDE_SESSION }));
  const lock = path.join(store.bridgeDirectory(), "locks", `watch-${CLAUDE_SESSION}.pid`);
  const start = Date.now();
  while (!fs.existsSync(lock) && Date.now() - start < 5000) await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(fs.existsSync(lock), "第一个 watcher 应持有锁");
  const second = runCli(["watch"], { input: JSON.stringify({ hook_event_name: "Stop", session_id: CLAUDE_SESSION }) });
  assert.equal(second.status, 0);
  runCli(["send", "claude-my-project-1", "给第一个 watcher"], { agent: codexAgent });
  const exitCode = await new Promise((resolve) => first.on("exit", resolve));
  assert.equal(exitCode, 2, "持锁的 watcher 应投递消息");
}

// 9. watcher 不在时，UserPromptSubmit 兜底注入 additionalContext。
{
  runCli(["send", "claude-my-project-1", "空窗期消息"], { agent: codexAgent });
  const result = hook("Claude", claudeAgent, { hook_event_name: "UserPromptSubmit", session_id: CLAUDE_SESSION, cwd, prompt: "继续" });
  const output = JSON.parse(result.stdout);
  assert.equal(output.hookSpecificOutput.hookEventName, "UserPromptSubmit");
  assert.match(output.hookSpecificOutput.additionalContext, /空窗期消息/);
  assert.equal(store.pendingCount(CLAUDE_SESSION), 0);
  // 没有消息时不输出任何东西。
  assert.equal(hook("Claude", claudeAgent, { hook_event_name: "UserPromptSubmit", session_id: CLAUDE_SESSION, cwd }).stdout, "");
}

// 10. 地址解析：不能发给自己；未知目标报错；name [ref] 形式可用。
{
  const self = runCli(["send", "claude-my-project-1", "自言自语"], { agent: claudeAgent });
  assert.equal(self.status, 1);
  assert.match(self.stderr, /不能给自己发消息/);
  const unknown = runCli(["send", "nobody-1", "hi"], { agent: claudeAgent });
  assert.equal(unknown.status, 1);
  assert.match(unknown.stderr, /没有找到在线会话/);
  const codexRef = store.readSession(CODEX_SESSION).ref;
  const withRef = runCli(["send", `codex-my-project-1 [${codexRef}]`, "带 ref"], { agent: claudeAgent });
  assert.equal(withRef.status, 0, withRef.stderr);
}

// 11. 超长消息被拒绝。
{
  const result = runCli(["send", "codex-my-project-1", "x".repeat(store.MESSAGE_BODY_LIMIT + 1)], { agent: claudeAgent });
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
    { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "send_message", arguments: { to: "claude-my-project-1", message: "来自 MCP" } } },
    { jsonrpc: "2.0", id: 5, method: "nope" }
  ];
  const result = runCli(["mcp"], { input: `${requests.map((request) => JSON.stringify(request)).join("\n")}\n`, agent: codexAgent });
  const responses = result.stdout.trim().split("\n").map((line) => JSON.parse(line));
  const byId = Object.fromEntries(responses.map((response) => [response.id, response]));
  assert.equal(responses.length, 5, "通知不应有回复");
  assert.equal(byId[1].result.protocolVersion, "2025-06-18");
  assert.deepEqual(byId[2].result.tools.map((tool) => tool.name), ["list_agents", "send_message", "set_name", "reserve_files", "release_files", "list_reservations", "check_inbox"]);
  const listText = byId[3].result.content[0].text;
  assert.match(listText, /当前会话是 codex-my-project-1/);
  assert.match(listText, /claude-my-project-1 \[[0-9a-f]{6}\]  ·  Claude/);
  assert.doesNotMatch(listText.split("\n\n")[1], /codex-my-project-1/, "列表不应包含自己");
  assert.equal(byId[4].result.isError, undefined);
  assert.match(byId[4].result.content[0].text, /已放入 claude-my-project-1 \[[0-9a-f]{6}\] 的信箱/);
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
  const request = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "send_message", arguments: { to: "claude-my-project-1", message: "做完告诉我", notify_when_idle: true } } };
  const sent = runCli(["mcp"], { input: `${JSON.stringify(request)}\n`, agent: codexAgent });
  assert.match(JSON.parse(sent.stdout).result.content[0].text, /已订阅/);
  hook("Claude", claudeAgent, { hook_event_name: "Stop", session_id: CLAUDE_SESSION, cwd });
  const start = Date.now();
  while (queueCalls().length === before && Date.now() - start < 10000) await new Promise((resolve) => setTimeout(resolve, 50));
  const notice = queueCalls().at(-1);
  assert.equal(notice[2], CODEX_SESSION);
  assert.match(notice[4], /from=cc-pets/);
  assert.match(notice[4], /空闲通知/);
  assert.equal(store.takeIdleSubscriptions(CLAUDE_SESSION).length, 0, "订阅应是一次性的");
  claimInboxQuietly();
}

function claimInboxQuietly() {
  store.claimInbox(CLAUDE_SESSION);
}

// 14. 目标 Codex 离线：不调用 queue（防止 resume 时执行过期任务），回执 undeliverable。
{
  const before = queueCalls().length;
  codexHost.kill("SIGKILL");
  await new Promise((resolve) => codexHost.on("exit", resolve));
  process.env.CC_BRIDGE_AGENT = claudeAgent;
  const codexRecord = store.readSession(CODEX_SESSION);
  const result = await core.sendMessage({ from: store.readSession(CLAUDE_SESSION), to: codexRecord, body: "你还在吗" });
  delete process.env.CC_BRIDGE_AGENT;
  assert.equal(result.receipt.status, "undeliverable");
  assert.equal(queueCalls().length, before);
  assert.equal(core.liveSessions().some((session) => session.session === CODEX_SESSION), false, "离线会话应被清出注册表");
}

// 15. 配对限流：同一对会话短时间内往来过多被拒绝。
{
  const codexHost2 = fakeAgent("codex");
  const CODEX2 = "33333333-aaaa-4bbb-8ccc-000000000003";
  hook("Codex", `Codex:${codexHost2.pid}`, { hook_event_name: "SessionStart", session_id: CODEX2, cwd });
  const target = store.readSession(CODEX2);
  const sender = store.readSession(CLAUDE_SESSION);
  for (let index = 0; index < store.PAIR_LIMIT_COUNT; index += 1) {
    store.writeReceipt({ id: store.newMessageId(), from: { session: CODEX2 }, to: { session: CLAUDE_SESSION }, body: "x", createdAt: Date.now(), status: "delivered" });
  }
  const result = await core.sendMessage({ from: sender, to: target, body: "再来一条" });
  assert.match(result.error, /循环/);
}

// 16. SessionEnd：移出注册表，信箱里未投递的消息标记 undeliverable。
{
  const codexHost3 = fakeAgent("codex");
  process.env.CC_BRIDGE_AGENT = `Codex:${codexHost3.pid}`;
  const CODEX3 = "44444444-aaaa-4bbb-8ccc-000000000004";
  hook("Codex", `Codex:${codexHost3.pid}`, { hook_event_name: "SessionStart", session_id: CODEX3, cwd });
  const message = { id: store.newMessageId(), from: { session: CLAUDE_SESSION }, to: { session: CLAUDE_SESSION, name: "x" }, body: "b", createdAt: Date.now(), status: "pending" };
  store.writeReceipt(message);
  store.enqueueInbox(message);
  hook("Claude", claudeAgent, { hook_event_name: "SessionEnd", session_id: CLAUDE_SESSION });
  delete process.env.CC_BRIDGE_AGENT;
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
  assert.match(store.readSession(SC).name, /^claude-my-project-\d+$/, "非法名字应回退到自动命名");
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
  const reservations = await import("../scripts/bridge/reservations.mjs");
  const { patternToRegExp, patternsOverlap, normalizePattern, editedFilesFromToolInput } = reservations;

  assert.ok(patternToRegExp("src/**/*.ts").test("src/a.ts"));
  assert.ok(patternToRegExp("src/**/*.ts").test("src/x/y.ts"));
  assert.ok(!patternToRegExp("src/**/*.ts").test("srcx/a.ts"));
  assert.ok(patternToRegExp("src/api").test("src/api/user.ts"), "不带通配符的目录应覆盖其下所有文件");
  assert.ok(patternToRegExp("src/api").test("src/api"));
  assert.ok(!patternToRegExp("src/api").test("src/apix"));
  assert.ok(patternToRegExp("a[1].ts").test("a[1].ts"), "方括号按字面匹配");
  assert.equal(patternsOverlap("src/api/**", "src/web/**"), false);
  assert.equal(patternsOverlap("src/**/*.ts", "src/api/*"), true, "glob 对 glob 按前缀保守判断");
  assert.equal(patternsOverlap("src/a.md", "src/**/*.ts"), false, "具体路径应精确匹配");
  assert.equal(patternsOverlap("src/api/user.ts", "src/api/**"), true);
  assert.equal(normalizePattern("/repo", "/repo/sub", "../x.ts"), "x.ts");
  assert.equal(normalizePattern("/repo", "/repo", "../outside.ts"), null, "越出仓库根应拒绝");
  assert.equal(normalizePattern("/repo", "/repo", "/repo/src/"), "src");
  assert.deepEqual(editedFilesFromToolInput({ file_path: "/repo/a.ts", old_string: "x" }), ["/repo/a.ts"]);
  assert.deepEqual(editedFilesFromToolInput({ input: "*** Begin Patch\n*** Update File: src/a.ts\n@@\n*** Add File: src/b.ts\n*** End Patch" }).sort(),
    ["src/a.ts", "src/b.ts"]);

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

  // 过期自动失效。
  call(agentA, "reserve_files", { paths: ["docs/**"] });
  const directory = path.join(store.bridgeDirectory(), "reservations");
  for (const name of fs.readdirSync(directory)) {
    const file = path.join(directory, name);
    const record = JSON.parse(fs.readFileSync(file, "utf8"));
    if (record.pattern === "docs/**") fs.writeFileSync(file, JSON.stringify({ ...record, expiresAt: Date.now() - 1 }));
  }
  assert.equal(reservations.activeReservations().some((entry) => entry.pattern === "docs/**"), false);

  // 会话结束自动释放（C 还持有 src/api/user.ts）。
  assert.ok(reservations.activeReservations().some((entry) => entry.session === hostC.session));
  runCli(["hook"], { input: JSON.stringify({ hook_event_name: "SessionEnd", session_id: hostC.session }),
    agent: agentC, extraEnv: { CC_BRIDGE_HOOK: "Claude" } });
  assert.equal(reservations.activeReservations().some((entry) => entry.session === hostC.session), false);
}

// 21. 选项：分组展开、合并语义、configure 不重注册 MCP、Claude 放行规则、关闭唤醒 / 编辑拦截。
{
  const options = await import("../scripts/bridge/options.mjs");
  assert.deepEqual(options.parseToolList("view,send_message", "--x"),
    ["list_agents", "list_reservations", "check_inbox", "send_message"]);
  assert.deepEqual(options.parseToolList("", "--x"), []);
  assert.throws(() => options.parseToolList("rm_rf", "--x"), /只接受分组/);
  assert.throws(() => options.parseSwitch("maybe", "--wake"), /on \/ off/);
  const merged = options.mergeOptionFlags({ codexApprove: ["set_name"], wake: true, editGuard: true }, { wake: "off" });
  assert.deepEqual(merged.codexApprove, ["set_name"], "未给出的选项保持原值");
  assert.equal(merged.wake, false);

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
  const reservations = await import("../scripts/bridge/reservations.mjs");
  reservations.reserveFiles({ self: sender, paths: ["guarded/**"] });
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

// 22. 桌宠侧的约定：refresh 未开启时也写 CLI 定位；原生分组定义与 options.mjs 一致。
{
  const locator = path.join(env.CC_PETS_HOME, "bridge-cli.json");
  fs.rmSync(locator, { force: true });
  store.setBridgeEnabled(false);
  assert.equal(runCli(["refresh"]).status, 0);
  const written = JSON.parse(fs.readFileSync(locator, "utf8"));
  assert.equal(written.cli, cli, "定位文件应指向当前 cli.mjs");
  assert.equal(written.node, process.execPath);
  assert.equal(fs.statSync(locator).mode & 0o777, 0o600);

  const { TOOL_GROUPS } = await import("../scripts/bridge/options.mjs");
  const nativeSource = fs.readFileSync(path.join(projectDir, "Sources/CCPets/CCPetsBridge.m"), "utf8");
  const nativeGroups = {};
  for (const match of nativeSource.matchAll(/@"(\w+)": @\[((?:@"\w+"(?:, )?)+)\]/g)) {
    nativeGroups[match[1]] = [...match[2].matchAll(/@"(\w+)"/g)].map((item) => item[1]);
  }
  assert.deepEqual(nativeGroups, TOOL_GROUPS, "CCPetsBridge.m 的分组必须与 options.mjs 的 TOOL_GROUPS 一致");
}

console.log("bridge-harness: all passed");
process.exit(0);
