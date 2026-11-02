// CC Pets Terminal for VS Code and its forks (Cursor, Windsurf, VSCodium, …).
//
// 每个窗口都有自己的 extension host，所以每个窗口各注册一个本机端点。Pet 按 TTY 问遍
// 同一应用的所有窗口：拥有该 TTY 的窗口选中终端，并回报自己的工作区路径；扩展 API 没有
// 前置系统窗口的接口，由 Pet 再"打开"一次这个路径，VS Code 会聚焦已打开它的那个窗口。
//
// 协议与 JetBrains 插件一致：注册文件在 ~/Library/Application Support/CC Pets/ide-instances/，
// 仅监听 127.0.0.1，要求 Bearer 令牌的 POST，拒绝带 Origin 的请求；只提供状态查询和
// 聚焦，不读取终端输出，也不向终端输入。
'use strict';

const vscode = require('vscode');
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');

const REGISTRY_DIR = path.join(os.homedir(), 'Library', 'Application Support', 'CC Pets', 'ide-instances');
const VERSION = require('./package.json').version;

let server;
let registration;
let registryFile;

function run(file, args) {
  return new Promise((resolve) => {
    execFile(file, args, { timeout: 2000 }, (error, stdout) => resolve(error ? '' : String(stdout).trim()));
  });
}

async function ttyForPid(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return '';
  const tty = path.basename(await run('/bin/ps', ['-p', String(pid), '-o', 'tty=']));
  return /^ttys\d{1,8}$/.test(tty) ? tty : '';
}

// extension host 是 Helper 进程，Pet 的 NSRunningApplication 认不出来。沿父进程链找到
// .app/Contents/MacOS/ 下的主程序，Pet 用它校验注册文件属于一个正在运行的应用。
async function hostApplication() {
  let pid = process.ppid;
  for (let depth = 0; depth < 12 && pid > 1; depth++) {
    const comm = await run('/bin/ps', ['-p', String(pid), '-o', 'comm=']);
    const match = comm.match(/^(\/.*?\.app)\/Contents\/MacOS\/[^/]+$/);
    if (match && !match[1].includes('/Contents/Frameworks/')) {
      const bundleID = await run('/usr/bin/plutil',
        ['-extract', 'CFBundleIdentifier', 'raw', '-o', '-', path.join(match[1], 'Contents', 'Info.plist')]);
      return { pid, appPath: match[1], bundleID };
    }
    const parent = parseInt(await run('/bin/ps', ['-p', String(pid), '-o', 'ppid=']), 10);
    if (!Number.isInteger(parent)) break;
    pid = parent;
  }
  return null;
}

// 能被"再次打开"从而前置窗口的路径；空窗口、未保存的多根工作区和远程窗口没有。
function workspacePath() {
  if (vscode.env.remoteName) return '';
  const file = vscode.workspace.workspaceFile;
  if (file) return file.scheme === 'file' ? file.fsPath : '';
  const folders = vscode.workspace.workspaceFolders || [];
  return folders.length === 1 && folders[0].uri.scheme === 'file' ? folders[0].uri.fsPath : '';
}

function status() {
  return {
    schemaVersion: 1,
    kind: 'vscode',
    pluginVersion: VERSION,
    instanceID: registration.instanceID,
    pid: registration.pid,
    extensionHostPid: process.pid,
    ideVersion: vscode.version,
    workspace: workspacePath(),
    windowFocused: vscode.window.state.focused,
  };
}

function withTimeout(promise, ms) {
  return Promise.race([promise, new Promise((resolve) => setTimeout(() => resolve(undefined), ms))]);
}

async function terminalsForTTY(tty) {
  // 远程窗口里终端的 PID 属于远端机器，在本机查 TTY 可能撞上无关进程。
  if (vscode.env.remoteName) return [];
  const matches = [];
  for (const terminal of vscode.window.terminals) {
    const pid = await withTimeout(terminal.processId, 1000);
    if ((await ttyForPid(pid)) === tty) matches.push(terminal);
  }
  return matches;
}

function reply(res, code, body) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': data.length });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 4096) { reject(new Error('too_large')); req.destroy(); } else chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function authorized(req) {
  const expected = Buffer.from(`Bearer ${registration.token}`);
  const given = Buffer.from(String(req.headers.authorization || ''));
  return req.method === 'POST' && !req.headers.origin &&
    given.length === expected.length && crypto.timingSafeEqual(given, expected);
}

async function handle(req, res) {
  if (!authorized(req)) return reply(res, 403, { error: 'unauthorized' });
  if (req.url === '/status') return reply(res, 200, status());
  if (req.url !== '/focus') return reply(res, 404, { error: 'unknown_route' });

  let request;
  try {
    request = JSON.parse(await readBody(req));
  } catch {
    return reply(res, 400, { error: 'invalid_request' });
  }
  const tty = String((request && request.tty) || '').replace(/^\/dev\//, '');
  if (!/^ttys\d{1,8}$/.test(tty)) return reply(res, 400, { error: 'invalid_target' });

  const matches = await terminalsForTTY(tty);
  if (matches.length !== 1) {
    return reply(res, matches.length ? 409 : 404,
      { focused: false, error: matches.length ? 'ambiguous_target' : 'terminal_not_found' });
  }
  // 面板、分屏、编辑器区里的终端都由 show 负责显示并把键盘焦点交给它。
  matches[0].show(false);
  return reply(res, 200, { focused: true, workspace: workspacePath() });
}

function writeRegistration() {
  fs.mkdirSync(REGISTRY_DIR, { recursive: true, mode: 0o700 });
  const info = fs.lstatSync(REGISTRY_DIR);
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid()) {
    throw new Error('Invalid bridge directory');
  }
  fs.chmodSync(REGISTRY_DIR, 0o700);
  const record = { ...status(), port: registration.port, token: registration.token,
    appPath: registration.appPath, bundleID: registration.bundleID,
    extensionsPath: registration.extensionsPath };
  const temporary = path.join(REGISTRY_DIR, `.registration-${registration.instanceID}.tmp`);
  fs.writeFileSync(temporary, JSON.stringify(record), { mode: 0o600, flag: 'w' });
  fs.renameSync(temporary, registryFile);
}

function stop() {
  if (server) server.close();
  server = undefined;
  if (registryFile) {
    try { fs.unlinkSync(registryFile); } catch {}
  }
  registryFile = undefined;
}

async function activate(context) {
  if (process.platform !== 'darwin') return;
  const host = await hostApplication();
  if (!host) {
    console.warn('[CC Pets Terminal] host application not found; bridge disabled');
    return;
  }
  // 不用 environmentVariableCollection：集合一变，VS Code 会自动重启还没交互过的终端
  // （terminal.integrated.environmentChangesRelaunch），已交互的终端挂上"需要重启"提示。
  // 从 JetBrains 终端里用 `code` 启动时继承来的 CC_PETS_IDE_*，由 Pet 按 bundle ID 忽略。
  const instanceID = crypto.randomUUID();
  registration = { instanceID, token: crypto.randomBytes(32).toString('hex'), ...host,
    // 实际的扩展目录（可能被 --extensions-dir 或便携模式改过），Pet 用它判断安装版本。
    extensionsPath: path.dirname(context.extensionPath) };
  registryFile = path.join(REGISTRY_DIR, `${instanceID}.json`);
  server = http.createServer((req, res) => {
    handle(req, res).catch(() => reply(res, 500, { error: 'focus_failed' }));
  });
  server.maxConnections = 8;
  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    registration.port = server.address().port;
    writeRegistration();
  } catch (error) {
    console.warn('[CC Pets Terminal] could not start bridge', error);
    stop();
    return;
  }

  // 工作区变化后，注册文件里的路径只用于展示；聚焦时以 /focus 的实时回报为准。
  context.subscriptions.push(
    vscode.workspace.onDidChangeWorkspaceFolders(() => { try { writeRegistration(); } catch {} }),
    { dispose: stop },
  );
  process.once('exit', stop);
}

module.exports = { activate, deactivate: stop };
