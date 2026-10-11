## English

CC Pets v2.2.1 adds pet size controls and speech source choices, with menu, editor, and Retina rendering fixes.

- Resize pets from 50% to 200% with sharper sprites.
- Choose pet-specific or default speech lines.
- Keep menus open and refresh editor language.

### Pet size and rendering

The new **Pet Size** menu provides a live 50%–200% slider and **Reset Size**. Scaling keeps the pet's feet in place and persists across pet changes and restarts. Below 100%, status cards and speech bubbles scale down with the pet; at 100% and above they keep their original size. Sprite decoding now accounts for Retina display density and maximum pet size.

### Speech and menus

Choose **Chatter → Line Source → Pet-specific Lines / Default Lines**. Pet-specific lines override shared sections and fall back to shared lines where needed; default lines use only the editable `~/.cc-pets/speech.txt`. The choice applies immediately and persists.

Frequency and line source now have separate Chatter submenus. Choice rows stay open on mouse clicks, update checkmarks immediately, and fit longer English labels. Changing the UI language refreshes the lines editor's titles, buttons, scope labels, and situation descriptions while preserving unsaved text and the selected situation.

### Release notes

The updater reads this committed file from the version tag through raw.githubusercontent.com, then jsDelivr, with the GitHub Release API as a fallback. Highlights use only the exact section for the current UI language.

See [CHANGELOG.md](https://github.com/Sunnyshinnny776/cc-pets/blob/v2.2.1/CHANGELOG.md) for the full list.

## 简体中文

CC Pets v2.2.1 新增宠物大小调整与台词来源选择，并修复菜单、台词编辑器及 Retina 渲染。

- 宠物支持 50%～200% 缩放，精灵图更加清晰。
- 可选择专属台词或默认台词。
- 单选菜单保持展开，编辑器文案随语言刷新。

### 宠物大小与渲染

右键「宠物大小」提供实时调整的 50%～200% 滑动条和「恢复默认」按钮。缩放保持脚底位置不变，切换宠物和重启后仍保留。宠物小于 100% 时状态卡和气泡同比例缩小，达到或超过 100% 时保持原尺寸。精灵图解码适配 Retina 屏幕倍率与最大宠物尺寸。

### 台词与菜单

「碎碎念 → 台词来源」可选择「专属台词」或「默认台词」。专属台词按小节优先使用当前宠物词库，缺少的小节沿用通用台词；默认台词只使用可编辑的 `~/.cc-pets/speech.txt`。选择立即生效并持久保存。

频率和台词来源分别收进碎碎念子菜单。单选行点击后菜单保持展开、勾选立即更新，长英文标题完整显示。切换界面语言时，台词编辑器的标题、按钮、范围标签和情境说明统一刷新，并保留未保存的文本和当前情境。

### 更新说明

更新器从版本 tag 读取这份已提交文件，依次尝试 raw.githubusercontent.com、jsDelivr，最后回退到 GitHub Release API。更新要点只读取与当前界面语言标题完全匹配的段落。

完整改动见 [CHANGELOG.zh-CN.md](https://github.com/Sunnyshinnny776/cc-pets/blob/v2.2.1/CHANGELOG.zh-CN.md)。
