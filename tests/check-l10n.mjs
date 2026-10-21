#!/usr/bin/env node
// 多语言自检（开发和 CI 用，不随用户运行）。源码里写英文原文，它就是各语言表的 key：
//   - 原生代码：L(@"…")（见 Sources/CCPets/Support/CCPetsL10n.h），带参数的写 {name} 占位或 %@
//   - zsh 脚本：cc_pets_t "…"（见 scripts/i18n.zsh）
// 两边共用 Resources/<语言>.lproj/Localizable.strings 一张表。
// 改了英文原文却忘了改表，那种语言的界面就会漏出英文，而且不报任何错。这里把每种语言的表
// 都和源码逐条对上（有几张表就查几张，加语言不用改这里）：
//   - 缺翻译：代码里有、表里没有 → 失败
//   - 多余：表里有、代码里已经没有 → 失败（多半是英文原文改过了，旧 key 成了孤儿）
//   - 占位符对不上：%@ / %ld / {name} 的个数或名字不一致 → 失败
//   - 缺元信息（语言名、Release 段落标题）→ 失败
//
//   node tests/check-l10n.mjs                    检查，有问题时退出码 1
//   node tests/check-l10n.mjs --missing <语言>    只把这种语言缺的 key 按 JSON 打出来，方便补表
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sourceDir = path.join(projectDir, "Sources", "CCPets");
const resourcesDir = path.join(projectDir, "Resources");
// 与 CCPetsL10n.h 里的 CCPetsLanguageNameKey / CCPetsReleaseNotesSectionKey 一致。
const META_KEYS = ["Language Name", "Release Notes Section"];
const SKIPPED_SCRIPTS = new Set(["i18n.zsh"]);

function unescapeC(text) {
  return text.replace(/\\(["\\nt])/g, (_, ch) => ({ n: "\n", t: "\t" })[ch] ?? ch);
}

function lineOf(text, index) {
  return text.slice(0, index).split("\n").length;
}

function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? walk(full) : [full];
  });
}

// L(@"a" "b" @"c") 这类跨行拼接也算一个 key。
// zsh 只认 cc_pets_t "…"，第一个参数必须是不含变量的双引号字面量。
function sourceKeys() {
  const keys = new Map();
  const call = /\bL\(\s*((?:@?"(?:[^"\\]|\\.)*"\s*)+)\)/g;
  const piece = /@?"((?:[^"\\]|\\.)*)"/g;
  // 源码按模块分子目录存放，递归扫描；位置用相对 Sources/CCPets 的路径标注。
  for (const file of walk(sourceDir).filter((file) => file.endsWith(".m")).sort()) {
    const name = path.relative(sourceDir, file);
    const text = fs.readFileSync(file, "utf8");
    for (const match of text.matchAll(call)) {
      const key = [...match[1].matchAll(piece)].map((part) => unescapeC(part[1])).join("");
      if (!keys.has(key)) keys.set(key, `${name}:${lineOf(text, match.index)}`);
    }
  }
  const zshCall = /\bcc_pets_t\s+"((?:[^"\\$`]|\\.)*)"/g;
  const scripts = [...walk(path.join(projectDir, "scripts")), ...walk(path.join(projectDir, "bin"))]
    .filter((file) => !file.endsWith(".mjs") && !SKIPPED_SCRIPTS.has(path.basename(file)))
    .sort();
  for (const file of scripts) {
    const text = fs.readFileSync(file, "utf8");
    for (const match of text.matchAll(zshCall)) {
      const key = match[1].replace(/\\(["\\$`])/g, "$1");
      if (!keys.has(key)) keys.set(key, `${path.relative(projectDir, file)}:${lineOf(text, match.index)}`);
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
  const slots = [...text.matchAll(/\{([A-Za-z][A-Za-z0-9_]*)\}/g)].map((match) => match[1]).sort();
  return JSON.stringify([printf, [...new Set(slots)]]);
}

function check(label, keys, table) {
  const problems = [];
  const missing = {};
  for (const key of META_KEYS) {
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
    if (!keys.has(key) && !META_KEYS.includes(key)) problems.push(`${label} 多余的条目: ${JSON.stringify(key)}`);
  }
  return { problems, missing };
}

const languages = fs.readdirSync(resourcesDir)
  .filter((entry) => entry.endsWith(".lproj"))
  .filter((entry) => fs.existsSync(path.join(resourcesDir, entry, "Localizable.strings")))
  .map((entry) => entry.slice(0, -".lproj".length))
  .sort();

const keys = sourceKeys();
const results = {};
for (const language of languages) {
  results[language] = check(language, keys,
    readStrings(path.join(resourcesDir, `${language}.lproj`, "Localizable.strings")));
}

const missingIndex = process.argv.indexOf("--missing");
if (missingIndex >= 0) {
  const language = process.argv[missingIndex + 1];
  if (!language) {
    console.error("用法: check-l10n.mjs --missing <语言>");
    process.exit(2);
  }
  // 还没建表的新语言：缺的就是全部 key。
  const missing = results[language]?.missing ?? Object.fromEntries([...keys.keys()].map((key) => [key, ""]));
  process.stdout.write(`${JSON.stringify(missing, null, 2)}\n`);
  process.exit(0);
}

const problems = Object.values(results).flatMap((result) => result.problems);
if (problems.length > 0) {
  for (const problem of problems) console.error(problem);
  console.error(`\n共 ${problems.length} 处多语言问题。`);
  process.exit(1);
}
console.log(`多语言检查通过（en 为源语言，另有 ${languages.join("、")}）。`);
