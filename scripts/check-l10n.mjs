#!/usr/bin/env node
// 多语言自检。源码里写英文原文，它就是各语言表的 key：
//   - App：L(@"…")（见 Sources/CCPets/CCPetsL10n.h）↔ Resources/<语言>.lproj/Localizable.strings
//   - CLI：Node 的 t("…")（见 scripts/i18n.mjs）和 zsh 的 cc_pets_t "…"（见 scripts/i18n.zsh）
//          ↔ scripts/locales/<语言>.json
// 改了英文原文却忘了改表，那种语言的界面就会漏出英文，而且不报任何错。这里把每种语言的表
// 都和源码逐条对上（有几张表就查几张，加语言不用改这里）：
//   - 缺翻译：代码里有、表里没有 → 失败
//   - 多余：表里有、代码里已经没有 → 失败（多半是英文原文改过了，旧 key 成了孤儿）
//   - 占位符对不上：%@ / %ld / {name} 的个数或名字不一致 → 失败
//   - App 表缺元信息（语言名、Release 段落标题）→ 失败
//   - App 和 CLI 支持的语言不一致 → 失败
//
//   node scripts/check-l10n.mjs                  检查，有问题时退出码 1
//   node scripts/check-l10n.mjs --missing <语言>  只把这种语言缺的 key 按 JSON 打出来，方便补表
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sourceDir = path.join(projectDir, "Sources", "CCPets");
const resourcesDir = path.join(projectDir, "Resources");
const localesDir = path.join(projectDir, "scripts", "locales");
// 与 CCPetsL10n.h 里的 CCPetsLanguageNameKey / CCPetsReleaseNotesSectionKey 一致。
const APP_META_KEYS = ["Language Name", "Release Notes Section"];
const SKIPPED_SCRIPTS = new Set(["check-l10n.mjs", "i18n.mjs", "i18n.zsh"]);

function unescapeC(text) {
  return text.replace(/\\(["\\nt])/g, (_, ch) => ({ n: "\n", t: "\t" })[ch] ?? ch);
}

function lineOf(text, index) {
  return text.slice(0, index).split("\n").length;
}

// L(@"a" "b" @"c") 这类跨行拼接也算一个 key。
function objcKeys() {
  const keys = new Map();
  const call = /\bL\(\s*((?:@?"(?:[^"\\]|\\.)*"\s*)+)\)/g;
  const piece = /@?"((?:[^"\\]|\\.)*)"/g;
  for (const name of fs.readdirSync(sourceDir).filter((file) => file.endsWith(".m")).sort()) {
    const text = fs.readFileSync(path.join(sourceDir, name), "utf8");
    for (const match of text.matchAll(call)) {
      const key = [...match[1].matchAll(piece)].map((part) => unescapeC(part[1])).join("");
      if (!keys.has(key)) keys.set(key, `${name}:${lineOf(text, match.index)}`);
    }
  }
  return keys;
}

function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === "locales" ? [] : walk(full);
    return [full];
  });
}

// Node 端只认 t("…") / t('…') / t(`…`)（模板串里不许有 ${}），第一个参数必须是字面量。
// zsh 端只认 cc_pets_t "…"，第一个参数必须是不含变量的双引号字面量。
function cliKeys() {
  const keys = new Map();
  const nodeCall = /\bt\(\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\$]|\\.)*`)/g;
  const zshCall = /\bcc_pets_t\s+"((?:[^"\\$`]|\\.)*)"/g;
  const files = [...walk(path.join(projectDir, "scripts")), ...walk(path.join(projectDir, "bin"))]
    .filter((file) => !SKIPPED_SCRIPTS.has(path.basename(file)))
    .sort();
  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    const relative = path.relative(projectDir, file);
    const node = /\.(mjs|js)$/.test(file);
    for (const match of text.matchAll(node ? nodeCall : zshCall)) {
      const key = node
        ? unescapeC(match[1].slice(1, -1).replace(/\\'/g, "'").replace(/\\`/g, "`"))
        : match[1].replace(/\\(["\\$`])/g, "$1");
      if (!keys.has(key)) keys.set(key, `${relative}:${lineOf(text, match.index)}`);
    }
  }
  return keys;
}

function readStrings(file) {
  return JSON.parse(execFileSync("/usr/bin/plutil", ["-convert", "json", "-o", "-", file], {
    encoding: "utf8"
  }));
}

// %1$@ 和 %@ 视为同一个占位符，只比较类型的多重集合；{name} 比较名字的集合。
function placeholders(text) {
  const printf = [...text.matchAll(/%(?:\d+\$)?(?:[-+ #0]*\d*(?:\.\d+)?)(l{0,2}[dufsx@]|%)/g)]
    .map((match) => match[1]).filter((type) => type !== "%").sort();
  const slots = [...text.matchAll(/\{([A-Za-z][A-Za-z0-9]*)\}/g)].map((match) => match[1]).sort();
  return JSON.stringify([printf, [...new Set(slots)]]);
}

function check(label, keys, table, metaKeys = []) {
  const problems = [];
  const missing = {};
  for (const key of metaKeys) {
    if (!String(table[key] ?? "").trim()) problems.push(`${label} 缺元信息: ${JSON.stringify(key)}`);
  }
  for (const [key, where] of keys) {
    if (!(key in table)) {
      problems.push(`${label} 缺翻译 (${where}): ${JSON.stringify(key)}`);
      missing[key] = "";
    } else if (placeholders(key) !== placeholders(table[key])) {
      problems.push(`${label} 占位符不一致 (${where}): ${JSON.stringify(key)} → ${JSON.stringify(table[key])}`);
    }
  }
  for (const key of Object.keys(table)) {
    if (!keys.has(key) && !metaKeys.includes(key)) problems.push(`${label} 多余的条目: ${JSON.stringify(key)}`);
  }
  return { problems, missing };
}

const appLanguages = fs.readdirSync(resourcesDir)
  .filter((entry) => entry.endsWith(".lproj"))
  .filter((entry) => fs.existsSync(path.join(resourcesDir, entry, "Localizable.strings")))
  .map((entry) => entry.slice(0, -".lproj".length))
  .sort();
const cliLanguages = fs.readdirSync(localesDir)
  .filter((entry) => entry.endsWith(".json"))
  .map((entry) => entry.slice(0, -".json".length))
  .sort();

const appKeys = objcKeys();
const scriptKeys = cliKeys();
const results = {};
for (const language of appLanguages) {
  results[`App ${language}`] = check(`App ${language}`, appKeys,
    readStrings(path.join(resourcesDir, `${language}.lproj`, "Localizable.strings")), APP_META_KEYS);
}
for (const language of cliLanguages) {
  results[`CLI ${language}`] = check(`CLI ${language}`, scriptKeys,
    JSON.parse(fs.readFileSync(path.join(localesDir, `${language}.json`), "utf8")));
}

const missingIndex = process.argv.indexOf("--missing");
if (missingIndex >= 0) {
  const language = process.argv[missingIndex + 1];
  if (!language) {
    console.error("用法: check-l10n.mjs --missing <语言>");
    process.exit(2);
  }
  // 还没建表的新语言：缺的就是全部 key。
  const all = (keys) => Object.fromEntries([...keys.keys()].map((key) => [key, ""]));
  const app = results[`App ${language}`]?.missing ?? all(appKeys);
  const cli = results[`CLI ${language}`]?.missing ?? all(scriptKeys);
  process.stdout.write(`${JSON.stringify({ app, cli }, null, 2)}\n`);
  process.exit(0);
}

const problems = [];
// App 和 CLI 支持的语言要一致，否则切到某种语言后桌宠和终端各说各的。
for (const language of appLanguages) {
  if (!cliLanguages.includes(language)) problems.push(`缺 scripts/locales/${language}.json（App 已支持 ${language}）`);
}
for (const language of cliLanguages) {
  if (!appLanguages.includes(language)) problems.push(`缺 Resources/${language}.lproj/Localizable.strings（CLI 已支持 ${language}）`);
}
for (const result of Object.values(results)) problems.push(...result.problems);
if (problems.length > 0) {
  for (const problem of problems) console.error(problem);
  console.error(`\n共 ${problems.length} 处多语言问题。`);
  process.exit(1);
}
console.log(`多语言检查通过（en 为源语言，另有 ${appLanguages.join("、")}）。`);
