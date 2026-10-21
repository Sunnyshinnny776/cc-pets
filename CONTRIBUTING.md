# Contributing

English | [简体中文](./CONTRIBUTING.zh-CN.md)

Thank you for contributing to CC Pets. Before submitting a change:

1. Keep the change focused on one clear problem and avoid unrelated formatting.
2. Submit only original assets or assets with an explicit license that permits modification and redistribution.
3. Never submit Codex or Claude sessions, quota caches, API keys, cookies, personal paths, or other sensitive information.
4. Run `npm test` and confirm that the native build, hooks, quota collection, uninstall, and wrapper tests pass.
5. Update `README.md` and `CHANGELOG.md` for user-visible behavior changes.

For a substantial feature, open a GitHub Issue before sending a Pull Request so the
scope can be agreed on first.

## Branch and release policy

Develop, test, and prepare preview releases on `publish`. Preview releases must be
marked as GitHub prereleases and use a prerelease version such as `2.2.1-rc.1`.
Install preview builds explicitly; the automatic updater accepts stable versions only.
`main` is reserved for stable releases, including the stable GitHub Release and tag.
Complete implementation, documentation, screenshots, and validation on `publish`
before submitting to `main`; repeat integration checks there before a stable release.
The latest stable GitHub release is **v2.3.0**, covering the Main menu, multiple accounts, token usage by model, and the native runtime.
See [release status](docs/release-status.md) for validation and handoff details.

## Localization

UI text is written in English in the source, and that text is the key into every
other language's table:

- Objective-C: wrap user-visible strings in `L(@"…")` (`Sources/CCPets/Support/CCPetsL10n.h`).
  Use `%1$@` / `%2$@` when a translation needs a different argument order. Command-line
  output can instead use `{name}` placeholders filled by `CCPetsInterpolate(L(@"…"), @{…})`.
- zsh: use `cc_pets_t "…" name="$value"` from `scripts/i18n.zsh`, which looks the text up
  through the native `cc-pets --localize`. The text must be a literal; put variables in
  `{name}` placeholders, never directly in the text.

The app, the command-line tools and the zsh scripts share one table per language:
`Resources/<language>.lproj/Localizable.strings`.

When you add or change an English string, update its key in every table.
`node tests/check-l10n.mjs` (also part of `npm test`) reports missing, stale and
mismatched-placeholder entries for each language.

### Adding a language

Adding a language only adds files; no code changes are needed. For a language `xx`
(use the macOS identifier, such as `ja` or `zh-Hant`):

1. `Resources/xx.lproj/Localizable.strings`: copy the `zh-Hans` table and translate
   each value. Set the two metadata entries: `"Language Name"` (the name shown in the
   **Language** menu, written in that language) and `"Release Notes Section"` (the
   heading of that language's section in GitHub release notes; separate alternatives
   with `|`).
2. `Resources/xx.lproj/InfoPlist.strings`: translate `NSAppleEventsUsageDescription`.
3. Optional: `Resources/phrases.default.xx.txt` with default pet lines, translated from
   `phrases.default.en.txt`. Without it the pet falls back to the English lines.

`node tests/check-l10n.mjs --missing xx` lists the keys still to translate. The app
discovers languages from the `.lproj` directories, `build.sh` writes
`CFBundleLocalizations` from them, and `package.json` already includes them by pattern.

### GitHub Release notes

Every GitHub Release body must keep each language in its own section. Use the exact
headings `## English` and `## 简体中文`, followed by that language's top-level bullet
highlights. The updater reads only the section whose heading exactly matches the
current UI language; it never falls back to the full body or another language. If the
matching section is missing, the update dialog shows no highlights and does not guess
from other text. Keep the English and Simplified Chinese bullets semantically aligned.

Write the body in `docs/release-notes-vX.Y.Z.md`, commit it before creating the tag,
and publish with `gh release create vX.Y.Z --notes-file docs/release-notes-vX.Y.Z.md`.
The updater reads this file from the tag (raw.githubusercontent.com, then jsDelivr)
and only falls back to the rate-limited GitHub Release API, so editing the Release on
GitHub afterwards does not change the in-app highlights.

For every release, update `package.json`, both READMEs, both changelogs, the cover
version, and `docs/release-status.md` together. Move shipped changes from
`Unreleased` into the dated version section and preserve historical entries and
release notes. Keep exactly three top-level highlights per language, each at most
50 characters; use prose for additional detail and link to the matching tagged
changelog. Verify the final body with the app's release-note parser before tagging,
and publish that committed file without regenerating the body on GitHub.

## Asset requirements

- Use PNG or WebP with a transparent background.
- Built-in assets use an `8×9` grid. External Codex/PetDex assets support
  `spriteVersionNumber` v1 (`1536×1872`, `8×9`) and v2 (`1536×2288`, `8×11`),
  with `192×208` cells.
- The nine animation rows contain `6/8/8/4/5/8/6/6/6` frames. Keep unused cells transparent.
- State the asset author, source, and license in the Pull Request.
