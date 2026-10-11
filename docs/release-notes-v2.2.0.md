## English

CC Pets v2.2.0 is the first English-language release, with English and Simplified Chinese available in the app and CLI.

- English menus, panels, dialogs, and CLI.
- Clearer quota labels and trend messages.
- Release highlights follow your UI language.

### Language

- A new **Language** submenu offers **System Default**, **English** and **简体中文**. System Default follows macOS's preferred languages and falls back to English.
- `cc-pets` commands, hooks and CC Bridge messages follow the same choice through `~/.cc-pets/language`; `CC_PETS_LANGUAGE` overrides it per command.
- Added English default lines. An unedited `~/.cc-pets/speech.txt` switches with the language; lines without Chinese, Japanese or Korean text may now be up to 40 characters.
- The update dialog reads highlights only from the release notes section whose heading exactly matches the UI language; a missing section produces no highlights instead of falling back to other text.

### Interface

- Strengthened Today and Last 7 days headings, adjusted label spacing and trend captions, shortened quota window and risk labels, and removed redundant English trend descriptions.
- Update dialogs identify the installed version with “Current version”.
- The English README now shows English screenshots; the Simplified Chinese README keeps Chinese screenshots.

See [CHANGELOG.md](https://github.com/Sunnyshinnny776/cc-pets/blob/v2.2.0/CHANGELOG.md) for the full list.

## 简体中文

CC Pets v2.2.0 作为首个英文语言版本，App 与 CLI 支持英语和简体中文。

- 菜单、面板、弹窗和 CLI 支持英语。
- 额度标签与趋势提示更加清晰。
- 更新要点只读取对应界面语言的段落。

### 界面语言

- 右键菜单新增「语言」，可选「跟随系统」「English」「简体中文」；跟随系统时取 macOS 首选语言，都不匹配时用英文。
- `cc-pets` 命令、hooks 和 CC Bridge 消息通过 `~/.cc-pets/language` 跟随同一设置；`CC_PETS_LANGUAGE` 可按次覆盖。
- 新增英文默认台词。没改过的 `~/.cc-pets/speech.txt` 会随语言切换；不含中日韩文字的句子上限放宽到 40 个字符。
- 更新对话框只读取标题与界面语言完全匹配的 Release 段落；缺少对应段落时不展示要点，不会退回其他文字。

### 界面

- Today 和 Last 7 days 标题加粗，标签间距与趋势图说明位置调整，窗口标题和风险提示精简，移除英文趋势区域的重复说明。
- 更新弹窗以「Current version」标识已安装版本。
- 英文 README 展示英文截图，中文 README 保留中文截图。

完整改动见 [CHANGELOG.zh-CN.md](https://github.com/Sunnyshinnny776/cc-pets/blob/v2.2.0/CHANGELOG.zh-CN.md)。
