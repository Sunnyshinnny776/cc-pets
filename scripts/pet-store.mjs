#!/usr/bin/env node

// cc-pets 自己的素材仓库。素材可以来自多个"源"（source），但一律落到 ~/.cc-pets/pets，
// 不碰 ~/.petdex/pets 和 ~/.codex/pets——那两个目录是别的工具在写，混在一起就没法
// "只看自己装的宠物"。桌宠端（discoverPetOptions）只要发现这个目录有内容，就只认它。
//
// 目录名保持素材本名（boba 就是 boba），来源记在宠物目录内的 .source.json 里。这样
// 桌宠端不需要知道"源"这回事，右键菜单里也不会出现 boba@petdex 这种名字；同名素材
// 的冲突交给 --as 显式改名解决，那是低频事件，不值得为它把所有目录名都变丑。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { t } from "./i18n.mjs";

// 一个源的完整定义就是这几项。以后接自建 registry 时在这里加一行即可，
// 命令、目录结构和桌宠端都不用动。
const SOURCES = {
  petdex: {
    label: "PetDex",
    manifestUrl: "https://petdex.dev/api/manifest",
    // 清单是远端数据，理论上可以指向任意地址。下载前把 host 卡死，
    // 免得一次清单投毒就变成"从任意地址往本地写文件"。
    assetHosts: ["assets.petdex.dev"],
    referer: "https://petdex.dev/",
    homepage: "https://petdex.dev"
  }
};
// 请求素材源时自报家门：对方运维从日志里能看出流量来自 CC Pets 而不是一串默认 UA，
// 想联系或限流都有个明确的对象。版本号跟着 package.json 走，不另外维护一份。
const USER_AGENT = (() => {
  let version = "0.0.0";
  try {
    version = JSON.parse(
      fs.readFileSync(new URL("../package.json", import.meta.url), "utf8")
    ).version;
  } catch {
    // 版本读不到不该让下载失败，退回占位版本号即可。
  }
  return `cc-pets/${version} (+https://github.com/Sunnyshinnny776/cc-pets)`;
})();

// 不能 add、只会出现在已装素材里的来源。桌宠的"导入 Codex 素材"开关会写 source: "codex"。
const LOCAL_SOURCE_LABELS = { codex: t("Codex (imported)") };
const DEFAULT_SOURCE = process.env.CC_PETS_SOURCE || "petdex";
const SIDECAR_NAME = ".source.json";
const MANIFEST_TTL_MS = 6 * 60 * 60 * 1000;

const untilde = (value) => (value.startsWith("~/") ? path.join(os.homedir(), value.slice(2)) : value);
const petsRoot = () => {
  const override = process.env.CC_PETS_PETS_DIR;
  if (override && override.length > 0) return path.resolve(untilde(override));
  return path.join(os.homedir(), ".cc-pets", "pets");
};
// 与 CC Bridge、cc-pets clean 一致：CC_PETS_HOME 可覆盖 ~/.cc-pets。
const cachePath = (sourceName) =>
  path.join(process.env.CC_PETS_HOME || path.join(os.homedir(), ".cc-pets"), "cache", `manifest-${sourceName}.json`);
// 每个源都可以单独用环境变量改清单地址，主要给测试和自建源的本地联调用。
const manifestUrlFor = (sourceName) =>
  process.env[`CC_PETS_MANIFEST_URL_${sourceName.toUpperCase()}`] || SOURCES[sourceName].manifestUrl;

const dim = (text) => `[2m${text}[0m`;
const cyan = (text) => `[36m${text}[0m`;
const green = (text) => `[32m${text}[0m`;
const red = (text) => `[31m${text}[0m`;

const fail = (message) => {
  console.error(red(message));
  process.exit(1);
};

// slug 直接用作目录名，而它来自远端清单，必须自己校验，不能指望上游。
const isSafeSlug = (slug) =>
  typeof slug === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(slug) && !slug.includes("..");

// 本地名由用户通过 --as 指定，可以用中文等 Unicode 字母。路径分隔符、空白和
// 控制字符不在允许集内；首字符必须是字母或数字，避免生成隐藏目录。
const isSafeLocalName = (name) =>
  typeof name === "string" &&
  /^[\p{L}\p{N}][\p{L}\p{N}\p{M}._-]*$/u.test(name) &&
  !name.includes("..");

// "petdex:boba" -> { source: "petdex", slug: "boba" }；不带前缀就用默认源。
function parseSpec(spec) {
  const separator = spec.indexOf(":");
  if (separator === -1) return { source: DEFAULT_SOURCE, slug: spec };
  const source = spec.slice(0, separator);
  const slug = spec.slice(separator + 1);
  if (!SOURCES[source]) {
    fail(t('Unknown pet source "{source}". Available sources: {SOURCES}', { source, SOURCES: Object.keys(SOURCES).join(", ") }));
  }
  return { source, slug };
}

async function fetchManifest(sourceName, { refresh }) {
  const cache = cachePath(sourceName);
  if (!refresh) {
    try {
      const stat = fs.statSync(cache);
      if (Date.now() - stat.mtimeMs < MANIFEST_TTL_MS) {
        const cached = JSON.parse(fs.readFileSync(cache, "utf8"));
        if (Array.isArray(cached?.pets)) return cached.pets;
      }
    } catch {
      // 缓存缺失或损坏都当作没有缓存，直接回源。
    }
  }
  const response = await fetch(manifestUrlFor(sourceName), {
    redirect: "follow",
    headers: { "User-Agent": USER_AGENT }
  });
  if (!response.ok) fail(t("Failed to fetch the {label} pet list: HTTP {status}", { label: SOURCES[sourceName].label, status: response.status }));
  const body = await response.json();
  if (!Array.isArray(body?.pets)) fail(t("The {label} pet list has an unexpected format", { label: SOURCES[sourceName].label }));
  fs.mkdirSync(path.dirname(cache), { recursive: true });
  fs.writeFileSync(cache, JSON.stringify(body));
  return body.pets;
}

async function download(url, source) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    throw new Error(t("Invalid pet URL: {url}", { url }));
  }
  if (parsed.protocol !== "https:" || !source.assetHosts.includes(parsed.hostname)) {
    throw new Error(t("Untrusted pet source: {url}", { url: parsed.hostname || url }));
  }
  const response = await fetch(parsed, {
    headers: { Referer: source.referer, "User-Agent": USER_AGENT }
  });
  if (!response.ok) throw new Error(t("Download failed {pathname} -> HTTP {status}", { pathname: parsed.pathname, status: response.status }));
  return Buffer.from(await response.arrayBuffer());
}

function readSidecar(directory) {
  try {
    const raw = JSON.parse(fs.readFileSync(path.join(directory, SIDECAR_NAME), "utf8"));
    return typeof raw?.source === "string" ? raw : null;
  } catch {
    return null;
  }
}

// 已经存在的目录不能闷声覆盖：可能是另一个源的同名素材，也可能是用户自己手放的图。
function assertInstallable(directory, sourceName, localName) {
  if (!fs.existsSync(directory)) return;
  const sidecar = readSidecar(directory);
  if (sidecar?.source === sourceName) return;
  const owner = sidecar ? t("came from {source}", { source: sidecar.source }) : t("wasn't installed by cc-pets pet (no source record)");
  throw new Error(
    t("{localName} already exists and {owner}. Install it under another name: ", { localName, owner }) +
      `cc-pets pet add ${sourceName}:${localName} --as ${localName}-${sourceName}`
  );
}

async function installPet(pet, sourceName, localName) {
  const source = SOURCES[sourceName];
  if (!isSafeSlug(pet.slug)) throw new Error(t("Invalid pet name: {slug}", { slug: pet.slug }));
  const directory = path.join(petsRoot(), localName);
  assertInstallable(directory, sourceName, localName);

  const [meta, sprite] = await Promise.all([
    download(pet.petJsonUrl, source),
    download(pet.spritesheetUrl, source)
  ]);
  const extension = new URL(pet.spritesheetUrl).pathname.endsWith(".png") ? "png" : "webp";
  fs.mkdirSync(directory, { recursive: true });
  // 同一只宠物换过格式时，旧的 spritesheet 会留下来抢加载顺序，先清掉。
  for (const stale of ["spritesheet.webp", "spritesheet.png"]) {
    if (stale !== `spritesheet.${extension}`) fs.rmSync(path.join(directory, stale), { force: true });
  }
  // pet.json 原样落盘，不掺自己的字段——保持上游原始内容，以后比对和更新才干净。
  fs.writeFileSync(path.join(directory, "pet.json"), meta);
  fs.writeFileSync(path.join(directory, `spritesheet.${extension}`), sprite);
  fs.writeFileSync(
    path.join(directory, SIDECAR_NAME),
    `${JSON.stringify({ source: sourceName, slug: pet.slug, installedAt: new Date().toISOString() }, null, 2)}\n`
  );
  return directory;
}

function installedPets() {
  const root = petsRoot();
  let entries;
  try {
    entries = fs.readdirSync(root, { withFileTypes: true });
  } catch {
    return [];
  }
  return entries
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
    .map((entry) => {
      const sidecar = readSidecar(path.join(root, entry.name));
      return { name: entry.name, source: sidecar?.source ?? null, slug: sidecar?.slug ?? null };
    })
    .sort((a, b) => a.name.localeCompare(b.name));
}

async function commandAdd(args) {
  const refresh = args.includes("--refresh");
  const asIndex = args.indexOf("--as");
  const alias = asIndex === -1 ? null : args[asIndex + 1];
  if (asIndex !== -1 && (!alias || alias.startsWith("--"))) fail(t("--as needs a name after it."));
  if (alias && !isSafeLocalName(alias)) fail(t("Invalid --as name: {alias}", { alias }));

  // asIndex 为 -1 时 asIndex + 1 是 0，会把第一个位置参数当成 --as 的取值吃掉。
  const aliasValueIndex = asIndex === -1 ? -1 : asIndex + 1;
  const positional = args.filter(
    (value, index) => !value.startsWith("--") && index !== aliasValueIndex);
  const specs = [...new Set(positional)];
  if (specs.length === 0) fail(t("Usage: {cyan}", { cyan: cyan(t("cc-pets pet add [source:]<name> [name...] [--as <local-name>]")) }));
  if (alias && specs.length > 1) fail(t("--as can only rename one pet at a time."));

  // 按源分组，同一个源只拉一次清单。
  const wanted = specs.map(parseSpec);
  const bySource = new Map();
  for (const item of wanted) {
    if (!bySource.has(item.source)) bySource.set(item.source, []);
    bySource.get(item.source).push(item.slug);
  }

  let failed = 0;
  let installed = 0;
  for (const [sourceName, slugs] of bySource) {
    const pets = await fetchManifest(sourceName, { refresh });
    const index = new Map(pets.map((pet) => [pet.slug, pet]));
    for (const slug of slugs) {
      const pet = index.get(slug);
      if (!pet) {
        failed += 1;
        console.error(t("{red} {sourceName}:{slug}: not in the pet list", { red: red("×"), sourceName, slug }));
        continue;
      }
      const localName = alias ?? slug;
      try {
        const directory = await installPet(pet, sourceName, localName);
        installed += 1;
        const renamed = localName === slug ? "" : dim(` (${sourceName}:${slug})`);
        console.log(`${green("✓")} ${localName}${renamed} ${dim(`→ ${directory}`)}`);
      } catch (error) {
        failed += 1;
        console.error(`${red("×")} ${sourceName}:${slug}: ${error.message}`);
      }
    }
  }

  if (installed > 0) {
    console.log(dim(t("Pets directory: {petsRoot}", { petsRoot: petsRoot() })));
    console.log(dim(t("Click “Rescan” in the pet menu or restart the pet to see new pets.")));
  }
  if (failed > 0) process.exit(1);
}

async function commandSearch(args) {
  const refresh = args.includes("--refresh");
  const positional = args.filter((value) => !value.startsWith("--"));
  // 关键词本身也可以带源前缀：`cc-pets pet search petdex:otter`。
  const scoped = positional.length > 0 && positional[0].includes(":")
    ? parseSpec(positional[0])
    : { source: DEFAULT_SOURCE, slug: positional.join(" ") };
  const sourceName = scoped.source;
  const keyword = [scoped.slug, ...positional.slice(1)].join(" ").trim().toLowerCase();

  const pets = await fetchManifest(sourceName, { refresh });
  const matched = keyword.length === 0
    ? pets
    : pets.filter((pet) =>
        `${pet.slug} ${pet.displayName ?? ""} ${pet.submittedBy ?? ""}`.toLowerCase().includes(keyword));
  if (matched.length === 0) fail(t('No pets on {label} match "{keyword}".', { label: SOURCES[sourceName].label, keyword }));
  const shown = matched.slice(0, 60);
  for (const pet of shown) {
    const author = pet.submittedBy ? dim(` by ${pet.submittedBy}`) : "";
    console.log(`  ${cyan(pet.slug)}  ${pet.displayName ?? ""}${author}`);
  }
  if (matched.length > shown.length) {
    console.log(dim(t("  … {length} results, showing the first {shown}.", { length: matched.length, shown: shown.length })));
  }
  console.log(dim(t("Install one: cc-pets pet add {sourceName}:{slug}", { sourceName, slug: shown[0].slug })));
}

function commandList() {
  const pets = installedPets();
  if (pets.length === 0) {
    console.log(dim(t("No pets in {petsRoot} yet.", { petsRoot: petsRoot() })));
    console.log(dim(t("Try: cc-pets pet add boba")));
    return;
  }
  const groups = new Map();
  for (const pet of pets) {
    const key = pet.source ?? "__unknown__";
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(pet);
  }
  // 有来源记录的源按名字排在前面，手放的素材垫底。
  const keys = [...groups.keys()].sort((a, b) => {
    if (a === "__unknown__") return 1;
    if (b === "__unknown__") return -1;
    return a.localeCompare(b);
  });
  for (const key of keys) {
    const label = key === "__unknown__"
      ? t("Local pets (no source record)")
      : SOURCES[key]?.label ?? LOCAL_SOURCE_LABELS[key] ?? key;
    console.log(`  ${label}`);
    for (const pet of groups.get(key)) {
      // 目录名和上游 slug 不一致时（--as 改过名）把原名标出来。
      const origin = pet.slug && pet.slug !== pet.name ? dim(` (${key}:${pet.slug})`) : "";
      console.log(`    ${cyan(pet.name)}${origin}`);
    }
  }
  console.log(dim(t("{length} in total, in {petsRoot}", { length: pets.length, petsRoot: petsRoot() })));
}

function commandRemove(args) {
  const names = args.filter((value) => !value.startsWith("--"));
  if (names.length === 0) fail(t("Usage: {cyan}", { cyan: cyan(t("cc-pets pet remove <name> [name...]")) }));
  const root = petsRoot();
  let removed = 0;
  for (const name of names) {
    if (!isSafeLocalName(name)) {
      console.error(t("{red} {name}: invalid name", { red: red("×"), name }));
      continue;
    }
    const directory = path.join(root, name);
    if (!fs.existsSync(directory)) {
      console.error(t("{red} {name}: not installed", { red: red("×"), name }));
      continue;
    }
    const sidecar = readSidecar(directory);
    fs.rmSync(directory, { recursive: true, force: true });
    removed += 1;
    console.log(t("{green} Removed {name}{source}", { green: green("✓"), name, source: sidecar ? dim(t(" (from {source})", { source: sidecar.source })) : "" }));
  }
  if (removed < names.length) process.exit(1);
}

function commandSource() {
  for (const [name, source] of Object.entries(SOURCES)) {
    const marker = name === DEFAULT_SOURCE ? green(t(" (default)")) : "";
    console.log(`  ${cyan(name)}${marker}  ${source.label} ${dim(source.homepage)}`);
  }
  console.log(dim(t("Change the default source with CC_PETS_SOURCE, or prefix a name with `source:`.")));
}

function commandDir() {
  const root = petsRoot();
  fs.mkdirSync(root, { recursive: true });
  console.log(root);
}

function usage() {
  console.log([
    "",
    t("  {cyan} — install pets into cc-pets' own directory", { cyan: cyan("cc-pets pet") }),
    "",
    t("    {cyan} [source:]<name>...     download pets to {petsRoot}", { cyan: cyan("add"), petsRoot: dim(petsRoot()) }),
    t("    {cyan} [source:][keyword]  search pets (no keyword lists all)", { cyan: cyan("search") }),
    t("    {cyan}                       list installed pets, grouped by source", { cyan: cyan("list") }),
    t("    {cyan} <name>...           remove installed pets", { cyan: cyan("remove") }),
    t("    {cyan}                     list available sources", { cyan: cyan("source") }),
    t("    {cyan}                        print the pets directory", { cyan: cyan("dir") }),
    "",
    `  ${dim(t("Names can have a source prefix (petdex:boba); otherwise the default source is used: ") + DEFAULT_SOURCE + t("."))}`,
    `  ${dim(t("--as <local-name> installs under another directory name (any language) to avoid name clashes."))}`,
    `  ${dim(t("--refresh forces a refresh of the pet list cache (cached for 6 hours by default)."))}`,
    `  ${dim(t("CC_PETS_PETS_DIR changes the pets directory; CC_PETS_SOURCE changes the default source."))}`,
    "",
    `  ${dim("$")} cc-pets pet search otter`,
    `  ${dim("$")} cc-pets pet add boba`,
    `  ${dim("$")} cc-pets pet add petdex:boba --as boba-petdex`,
    t("  {dim} cc-pets pet add boba --as bubble-tea", { dim: dim("$") }),
    ""
  ].join("\n"));
}

const [command, ...args] = process.argv.slice(2);
if (!SOURCES[DEFAULT_SOURCE]) {
  fail(t('CC_PETS_SOURCE points to an unknown source "{DEFAULT_SOURCE}". Available sources: {SOURCES}', { DEFAULT_SOURCE, SOURCES: Object.keys(SOURCES).join(", ") }));
}
switch (command) {
  case "add":
  case "install":
    await commandAdd(args);
    break;
  case "search":
    await commandSearch(args);
    break;
  case "list":
  case "ls":
    commandList();
    break;
  case "remove":
  case "rm":
    commandRemove(args);
    break;
  case "source":
  case "sources":
    commandSource();
    break;
  case "dir":
    commandDir();
    break;
  case undefined:
  case "help":
  case "--help":
  case "-h":
    usage();
    break;
  default:
    console.error(red(t("Unknown subcommand: {command}", { command })));
    usage();
    process.exit(2);
}
