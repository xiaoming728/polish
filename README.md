# Polish

个人用的 macOS 菜单栏应用：选中文字后按 **⌥P**，由大模型润色，确认后写回原处。在终端里也能用，可以直接润色 zsh、Claude Code、Codex 输入框里的草稿，写回后不会自动执行或发送。

设计与决策见 [docs/design.md](docs/design.md)。

## 构建与安装

需要 macOS 14+，以及 Swift 6（只装 Command Line Tools 即可，不需要 Xcode）。

```sh
scripts/build-app.sh --install    # 构建、ad-hoc 签名，并安装到 /Applications/Polish.app
open /Applications/Polish.app
```

首次启动后：跟着自动弹出的「使用导引」走（未授权辅助功能或没填 Key 时弹出），之后可在设置 → 通用 → 使用导引… 再次打开。

导引各步对应的手动操作：

1. **授予辅助功能权限**：系统设置 → 隐私与安全性 → 辅助功能 → 打开 Polish。每次重新构建后，都要先移除旧条目再重新添加，因为 ad-hoc 签名的身份会变。
2. **填写配置**：菜单栏魔杖图标 → 设置… → 配置：选服务商，填 API Key（存在本机 `~/Library/Application Support/Polish/keys.json`，仅你的账号可读）和模型，然后点「测试连接」。
3. **终端集成（可选）**：设置 → 终端集成，对「zsh 输入行」和「终端 Agent 与其他程序」分别点「安装」（后者把 `$VISUAL`/`$EDITOR` 指向 polish-edit，Claude Code、Codex、Gemini CLI、OpenCode、Aider 等都适用；不是 Polish 触发时照常打开原编辑器），并按常用的 Agent 选「终端中发送的按键」（Ctrl+G / Ctrl+X Ctrl+E / Ctrl+X / Ctrl+X E）（写入 `~/.zshrc` 末尾带标记的一段，「卸载」只删这一段，改动前备份到 `~/.zshrc.polish-backup`），然后重开终端。
4. **开机自启（可选）**：设置 → 通用 → 「登录时自动启动 Polish」。需从 `/Applications/Polish.app` 启动才能打开；在「系统设置 → 通用 → 登录项」里移除也会同步关闭。

## 使用

**Qoder / qodercn**：在「设置 → 终端集成」选择 **Ctrl+X**；默认 Ctrl+G 不会打开它的外部编辑器。安装「终端 Agent 与其他程序」后，在新终端里重新启动 qodercn，使它继承 `VISUAL/EDITOR`。这个按键设置对所有终端生效，回到 zsh / Claude Code / Codex 时改选 Ctrl+G。

| 操作 | 效果 |
|---|---|
| 选中文字，按 ⌥P | 在选区旁弹出预览，流式显示润色结果 |
| 不选中，光标停在输入框里，按 ⌥P | 自动润色光标前的全部内容（放弃时光标回到原处） |
| ⏎ / ⌘C / Esc | 替换 / 复制 / 放弃（放弃和复制都不改动原文） |
| ⌘1–9 | 换一套配置重新润色 |
| 润色中再按 ⌥P | 取消 |
| 在终端输入框按 ⌥P | 润色整段草稿，⏎ 后写回输入框（不执行） |
| 中文输入法下敲拼音，停顿片刻 | 光标上方出现 ⌥1 英文 / ⌥2 中文，按下即替换刚敲的拼音（菜单可关闭，需要「输入监控」权限） |

回填方式可以在菜单里切换：预览（默认）/ 自动替换 / 小提示确认。

使用统计：设置 → 使用统计，按时间范围查看润色次数、采纳率、失败最多的应用、耗时中位数和输入提示的选中率。只记次数和耗时，不含正文，存在本机 `~/Library/Application Support/Polish/usage/`，可一键清空。

替换前会重新读取选区并与原文逐字比对。如果焦点或选区已经变了，就不替换，只提供复制。

## 开发与验证

```sh
swift build
swift run core-checks              # 纯逻辑断言自检（CLT 下没有 XCTest，用它代替）
python3 -I scripts/stream-e2e.py   # 流式请求：本地模拟服务端，OpenAI 兼容 / Anthropic / 各类错误
python3 -I scripts/terminal-e2e.py # 终端流程：zsh pty + 真实 polish-edit，14 个用例
python3 -I scripts/qodercn-e2e.py  # 本机已登录的 qodercn：握手、写回不发送、取消保留原文
```

代码结构：

- `Sources/PolishCore`：纯逻辑与可自动验证的部分。包括 SSE 解码、请求构造、模型请求、握手帧、socket 服务端和客户端、厂商预设。
- `Sources/Polish`：菜单栏 app。包括快捷键、AX 读取与回填、剪贴板、Key 存储、输入时中英提示、界面。
- `Checks`：断言自检，以及供端到端脚本使用的 `serve` 和 `stream` 子命令。

GUI 流程（AX 读取、⌘V 回填）依赖辅助功能权限和真实应用，按 design.md 第 7 节的兼容矩阵手工验收。
