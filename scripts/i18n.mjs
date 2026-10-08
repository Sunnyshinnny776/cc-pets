// Node 端（cc-pets 子命令、hook、CC Bridge）的多语言，和 App 端 CCPetsL10n 同一套约定：
// 源码里写英文原文，它就是 scripts/locales/<语言>.json 的 key；英文直接原样输出。
// 参数用 {name} 占位，第二个参数传 { name: 值 }。
//
// 支持哪些语言不写在代码里：英文之外，scripts/locales 下有 <语言>.json 的就算支持。
//
// 语言的来源依次是：
//   1. CC_PETS_LANGUAGE（en / zh-Hans / zh…，测试和临时切换用）
//   2. ~/.cc-pets/language（可用 CC_PETS_HOME 覆盖）：桌宠把右键菜单里选定的语言写在这里，
//      这样终端里的输出和桌宠界面是同一种语言
//   3. LC_ALL / LC_MESSAGES / LANG，再退到 Intl 的默认 locale
// 都匹配不上时用英文。匹配规则同 App：先比完整标识或前缀（zh-Hans-CN → zh-Hans），
// 再只比主语言（zh_CN → zh-Hans、ja_JP → ja）。
//
// zsh 脚本通过命令行入口用同一套表：node i18n.mjs <英文原文> [name=value …]，见 i18n.zsh。
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const SOURCE_LANGUAGE = "en";
const localesDirectory = path.join(path.dirname(fileURLToPath(import.meta.url)), "locales");

let cachedSupported;
export function supportedLanguages() {
  if (cachedSupported) return cachedSupported;
  let found = [];
  try {
    found = fs.readdirSync(localesDirectory)
      .filter((name) => name.endsWith(".json"))
      .map((name) => name.slice(0, -".json".length))
      .filter((language) => language !== SOURCE_LANGUAGE)
      .sort();
  } catch {
    found = [];
  }
  cachedSupported = [SOURCE_LANGUAGE, ...found];
  return cachedSupported;
}

// zh_CN.UTF-8 → zh-cn
function normalizedTag(value) {
  return String(value || "").trim().toLowerCase().replace(/_/g, "-").split(".")[0];
}

export function matchLanguage(value, supported = supportedLanguages()) {
  const tag = normalizedTag(value);
  if (!tag || tag === "c" || tag === "posix") return "";
  const exact = supported.find((language) => {
    const lower = language.toLowerCase();
    return tag === lower || tag.startsWith(`${lower}-`);
  });
  if (exact) return exact;
  const base = tag.split("-")[0];
  return supported.find((language) => language.toLowerCase().split("-")[0] === base) || "";
}

function languageFromFile() {
  const home = process.env.CC_PETS_HOME || path.join(os.homedir(), ".cc-pets");
  try {
    return matchLanguage(fs.readFileSync(path.join(home, "language"), "utf8"));
  } catch {
    return "";
  }
}

function languageFromEnvironment() {
  for (const name of ["LC_ALL", "LC_MESSAGES", "LANG"]) {
    const language = matchLanguage(process.env[name]);
    if (language) return language;
  }
  try {
    return matchLanguage(Intl.DateTimeFormat().resolvedOptions().locale);
  } catch {
    return "";
  }
}

let cachedLanguage;
export function currentLanguage() {
  if (cachedLanguage) return cachedLanguage;
  cachedLanguage = matchLanguage(process.env.CC_PETS_LANGUAGE) || languageFromFile() ||
    languageFromEnvironment() || SOURCE_LANGUAGE;
  return cachedLanguage;
}

const tables = new Map();
function table(language) {
  if (!tables.has(language)) {
    try {
      tables.set(language, JSON.parse(fs.readFileSync(path.join(localesDirectory, `${language}.json`), "utf8")));
    } catch {
      tables.set(language, {});
    }
  }
  return tables.get(language);
}

function interpolate(text, values) {
  if (!values) return text;
  return text.replace(/\{([A-Za-z][A-Za-z0-9]*)\}/g, (match, name) =>
    Object.prototype.hasOwnProperty.call(values, name) ? String(values[name]) : match);
}

export function translate(language, text, values) {
  const translated = language === SOURCE_LANGUAGE ? text : (table(language)[text] || text);
  return interpolate(translated, values);
}

export function t(text, values) {
  return translate(currentLanguage(), text, values);
}

// node i18n.mjs <英文原文> [name=value …]
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [text = "", ...pairs] = process.argv.slice(2);
  const values = Object.fromEntries(pairs.map((pair) => {
    const index = pair.indexOf("=");
    return index < 0 ? [pair, ""] : [pair.slice(0, index), pair.slice(index + 1)];
  }));
  process.stdout.write(`${t(text, values)}\n`);
}
