import os from "node:os";
import path from "node:path";

// CC Pets 写进 Claude Code / Codex 配置里的条目怎么认。安装、卸载、cc-pets doctor 共用这一份，
// 以免哪天改了写法，doctor 还按旧规则说"一切正常"。

export const CODEX_HOOK = { marker: "CC_PETS_CODEX_AGENT_HOOK=1", executable: "cc-pets" };
export const LEGACY_CODEX_HOOK = { marker: "CODEX_PET_AGENT_HOOK=1", executable: "codex-pet" };
export const CLAUDE_HOOK = { marker: "CC_PETS_CLAUDE_AGENT_HOOK=1", executable: "cc-pets" };
export const LEGACY_CLAUDE_HOOK = { marker: "CLAUDE_PET_AGENT_HOOK=1", executable: "codex-pet" };

export const STATUS_LINE_MARKER = "CC_PETS_CLAUDE_STATUS_LINE=1";
export const LEGACY_STATUS_LINE_MARKER = "CLAUDE_PET_STATUS_LINE=1";
export const STATUS_LINE_START_MARKER = "# >>> cc-pets-statusline >>>";
export const STATUS_LINE_END_MARKER = "# <<< cc-pets-statusline <<<";
export const CREATED_STATUS_LINE_MARKER = "# CC Pets created this status line script";

export const SHIM_START_MARKER = "# >>> cc-pets-shims >>>";
export const SHIM_END_MARKER = "# <<< cc-pets-shims <<<";

export const isManagedHookCommand = (value, signature) =>
  typeof value === "string" &&
  value.startsWith(`${signature.marker} `) &&
  value.endsWith(`/.build/release/${signature.executable}' --hook`);

export const isManagedStatusLine = (value, marker) =>
  typeof value === "string" &&
  value.startsWith(`${marker} `) &&
  /\/bin\/claude-statusline-with-pet' '[A-Za-z0-9+/=]*'$/.test(value);

// `bash ~/x.sh` 这类带解释器前缀的命令同样指向一个被就地注入过的脚本；带 -c 的不算，
// `-c` 后面是命令串而非脚本路径。install-claude-hooks.mjs 另有一份返回更多字段的解析，规则一致。
const interpreterPattern =
  /^(?:\/usr\/bin\/env\s+)?(?:[^\s'"]*\/)?(?:ba|z|k|da)?sh((?:\s+-[A-Za-z]+)*)\s+(.+)$/s;

const unquote = (value) => {
  const quoted = value.match(/^(['"])(.*)\1$/s);
  return quoted ? quoted[2] : value;
};

export const resolveStatusLineScript = (value) => {
  if (typeof value !== "string") return null;
  let candidate = unquote(value.trim());
  const interpreted = candidate.match(interpreterPattern);
  if (interpreted && !/-[A-Za-z]*c(?=\s|$)/.test(interpreted[1])) {
    candidate = unquote(interpreted[2].trim());
  }
  if (candidate.startsWith("~/")) candidate = path.join(os.homedir(), candidate.slice(2));
  if (!path.isAbsolute(candidate) || /[\s;&|<>`$()]/.test(candidate)) return null;
  return path.resolve(candidate);
};
