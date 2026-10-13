# Polish 设计方案与研发计划

个人用的 macOS 菜单栏应用：按全局快捷键，读取当前选中的文字（终端里读取输入框草稿），交给大模型润色，确认后安全地写回原处。

本文汇总 [Wayfinder 地图](https://github.com/xiaoming728/polish/issues/1) 上的全部决策，是 0.0.1 的实施规格。各项决策的依据都在对应工单里，这里只给结论。

## 1. 最小可用版本（0.0.1）的功能与边界

**包含**
- 菜单栏常驻（无 Dock 图标），全局快捷键默认 ⌥P，可以录制修改。
- GUI 应用：读选区 → 流式润色 → 按回填方式（预览 / 自动替换 / 小提示确认）写回。
- 终端（Terminal.app、Ghostty、iTerm2）：发送 Ctrl+G，由 `polish-edit` 接管整段草稿 → 润色 → 写回输入框，不自动执行或发送。zsh、Claude Code、Codex 均可用。
- 多套配置（服务商 + Base URL + 模型 + 润色指令 + 额外请求体 JSON），API Key 存在钥匙串。
- 默认带 6 个场景（⌘1–6）：默认润色、精简、结构化、仅纠错、译成英文、译成中文。不收「扩写 / 补充细节」，因为会凭空添加需求。老用户首次升级时补齐一次，沿用第一套配置的服务连接。
- 两种协议：OpenAI 兼容（Chat Completions）、Anthropic Messages。附带常见厂商预设。
- 设置界面：配置、通用、终端集成、权限与隐私。
- 输入时中英提示（2026-10-13 新增，默认开启，可在菜单关闭）：中文输入法下敲拼音时，在光标上方显示「⌥1 英文（默认）/ ⌥2 中文」。按键后撤销刚敲的拼音键，再粘贴所选内容。

**输入时中英提示的实现**
- 用 session 级 **listen-only** CGEvent tap 识别按键，不拦截、不阻塞任何按键。只在当前输入源是中文输入法（非键盘布局）时，累积 a–z 和 `'`。遇到空格、回车、数字、标点、方向键、修饰键组合、鼠标点击或切换应用时清空。
- 停顿 0.35 秒且至少 2 个字母时，用当前配置的服务连接加专用指令请求模型，模型返回 `{"en","zh"}`。期间再敲键，旧结果作废。
- 提示框不接收鼠标、不抢焦点。⌥1 / ⌥2 只在已出结果时临时注册为 Carbon 热键，提示消失即注销。按下后：先发与拼音键数相同的退格，再走剪贴板 + ⌘V。本 app 合成的按键带 `eventSourceUserData` 标记，事件监听会忽略。
- 隐私：推翻了 grill 时「不监听输入」的决定。只在中文输入法下读取拼音键。Secure Input、AXSecureTextField 和终端中不工作（终端里可能在英文模式下敲 sudo 密码）。润色流程进行中时暂停。AX 调用超时 0.25s，避免拖住主线程。
- 残余风险：退格撤销按键数计算。输入法若在组合态吞键，会多删光标前的文字，可用 ⌘Z 撤销。

**不包含**：账号、云同步、历史记录、OCR、语音、插件系统、开机自启、Developer ID 签名与公证、Gemini 和 Azure 的专用协议、bash 下的回填（bash 中降级为复制）。

## 2. 实现路线比较

| 路线 | 优点 | 缺点 |
|---|---|---|
| **Swift 原生 + SwiftPM（采用）** | AX、CGEvent、Carbon、Keychain 都是一手 API；体积小；不抢焦点的浮动面板容易做 | 本机没有 Xcode，只能用 CLT，测试框架不可用（用断言自检代替） |
| Electron / Tauri | UI 迭代快 | 系统 API 都要绕原生桥；常驻内存大；非激活浮动面板和焦点控制更难 |

不使用第三方依赖。快捷键自写 Carbon 实现，见「快捷键实现：修补 KeyboardShortcuts 还是自写 Carbon 热键」。

## 3. 用户流程与界面

**GUI**：选中文字 → ⌥P → 选区附近出现紧凑预览面板，流式显示结果 → ⏎ 替换 / ⌘C 复制 / Esc 放弃 / ⌘1–9 换配置重跑。润色进行中再按 ⌥P 即取消。
- 没有选中文字（2026-10-13 用户改为）：自动选中当前输入框里**光标前的全部内容**，再按选区流程处理；放弃或复制时把光标放回原处。AX 能读到输入框的值和光标位置时直接设置选区，否则只在焦点是文本控件时，用 ⇧⌘↑ 加 ⌘C 兜底。光标前也没有内容时，才提示「没有可润色的文字」。
- 自动替换模式：完成后直接回填；失败或校验不通过时弹出面板。
- 小提示确认模式：完成后出现「润色完成 · ⏎ 替换」胶囊，不展开全文。

**终端**：在输入框写好草稿 → ⌥P → 同样的预览面板 → ⏎ 写回输入框（不提交）。

**界面形态**（见「预览面板、小提示与设置界面的形态」）
- 预览面板：跟随光标的紧凑浮层，原文折叠。面板是非激活面板，不抢前台 App 的焦点。
- 小提示：光标旁的胶囊。
- 菜单：润色 / 取消、当前配置、回填方式、设置…、退出；未授权时顶部显示权限警告。
- 设置：四个标签页，与 UI 原型一致。

## 4. 数据流程

```
⌥P ─┬─ 前台是终端 ─→ 发送 Ctrl+G，进入待命 1.5s
    │                  ├─ polish-edit 通过 socket 发来草稿 ─→ 润色 ─→ 预览 ─→ OK(结果) / CANCEL ─→ polish-edit 写文件并 exit 0
    │                  └─ 超时 ─→ 降级：读取终端选区，只提供复制；提示可用 ZLE_LINE_ABORTED 恢复
    └─ 其他 App ─→ 读选区（AX 优先，⌘C 兜底）─→ 润色 ─→ 回填（校验 → ⌘V → 恢复剪贴板）
```

**读选区**
1. 取系统焦点元素的 `kAXSelectedTextAttribute`。
2. 读不到时，对该 App 设置一次 `AXEnhancedUserInterface`（Chromium）和 `AXManualAccessibility`（Electron）。设置后约有 2 秒防抖，所以本次直接走 ⌘C 兜底，下一次再用 AX。
3. ⌘C 兜底使用哨兵法：先往剪贴板写入随机哨兵，发送 ⌘C，最多等 300ms；剪贴板仍是哨兵就视为「没有选区」。完成后恢复原剪贴板。
4. 通过 ⌘C 读到的文本，在「自动替换」模式下也强制改为预览确认。

**模型请求**
- 系统提示 = 配置里的润色指令；用户消息 = `<text>\n原文\n</text>`。
- OpenAI 兼容：`POST {base}/chat/completions`，Bearer 鉴权，读取 `choices[0].delta.content`，以 `[DONE]` 结束，忽略 `:` 注释行和空块。
- Anthropic：`POST {base}/v1/messages`，带 `x-api-key` 和 `anthropic-version: 2023-06-01`，`max_tokens` 为 4096，读取 `content_block_delta` 中的 `text_delta`，以 `message_stop` 结束，收到 `error` 事件即报错。
- 额外请求体 JSON 按顶层键合并进请求体，覆盖默认值。
- 超时：首字 30s、总计 120s。不自动重试。
- 同一时间只允许一个请求。

**终端握手**（见「polish-edit 与 app 的通信和握手约定」）
- socket 位于 `~/Library/Application Support/Polish/edit.sock`，权限 0600。
- 帧格式：一行头部 + n 字节正文。
  - polish-edit → app：`EDIT n`。
  - app → polish-edit：`NO`，`CANCEL`，或 `OK n`。
- polish-edit 就是 app 二进制本身：`Contents/MacOS/polish-edit` 是指向主二进制的符号链接，按 argv[0] 分发。
- 连不上、或收到 `NO` 时交给原编辑器，查找顺序为 `POLISH_FALLBACK_EDITOR` → 非 polish-edit 的 `$VISUAL` → `$EDITOR` → `vi`。

## 5. 异常处理

| 情况 | 处理 |
|---|---|
| 焦点或选区在润色期间变了 | 回填前重新读取选区（用原来的读取方式），与原文逐字比对，并检查前台 pid 是否不变；不一致则不替换，面板显示原因，只保留 ⌘C |
| 剪贴板 | 读取和回填前保存所有条目，事后恢复；回填时写入的内容带 `org.nspasteboard.TransientType` 标记；恢复前若 changeCount 已被他人改动，则不恢复 |
| 并发 | 只有一个活动请求；进行中再按快捷键 = 取消；同一时间只有一个终端待命 |
| 请求失败或超时 | 原文不动；面板显示错误（含 HTTP 状态和服务端消息）；按快捷键可重试 |
| 投递按键时用户还按着 ⌥ | 用 privateState 事件源，并显式设置 flags |
| 终端 Ctrl+C、app 崩溃 | polish-edit 不改文件，exit 0；app 发现断开后取消请求、关闭面板 |

## 6. 权限、密钥与打包

- **权限**：辅助功能（AX 读取、CGEvent 投递）。首次启动时请求授权；未授权时菜单顶部显示警告。全局快捷键（Carbon）不需要权限。
- **密钥**：传统 login keychain（`kSecClassGenericPassword`，service 为 `Polish`，account 为 `base:<Base URL>`，同一服务的场景共用一个 Key；兼容早期按配置 id 存的 Key 并自动迁移）。ad-hoc 签名下不能用 data protection keychain。
- **其他设置**：配置、回填方式、快捷键存在 UserDefaults。
- **打包**：`scripts/build-app.sh`。步骤为 `swift build -c release` → 组装 `build/Polish.app`（Info.plist 含 `LSUIElement`）→ 创建 `polish-edit` 符号链接 → `codesign -s -` 做 ad-hoc 签名 → `codesign --verify --strict` 校验。
- **已知代价**：ad-hoc 签名的身份随每次重建变化，重建后需要重新授予辅助功能权限，钥匙串也可能弹窗确认。

## 7. 研发计划与验收

**阶段 1：PolishCore（纯逻辑，可自动验证）**
- 内容：SSE 解析、两种协议的请求构造与增量提取、额外 JSON 合并、厂商预设、握手帧编解码、原编辑器查找、快捷键显示名。
- 验收：`swift run core-checks` 全部通过。

**阶段 2：App 外壳**
- 内容：菜单栏、Carbon 快捷键与录制、设置界面、钥匙串、配置持久化。
- 验收：`scripts/build-app.sh` 成功，并通过 `codesign --verify --strict`；启动后菜单栏出现图标，设置能保存和读回。

**阶段 3：GUI 流程**
- 内容：AX 读取、⌘C 兜底、预览面板、小提示、三种回填方式、校验与剪贴板恢复。

**阶段 4：终端流程**
- 内容：Ctrl+G 投递、socket 服务端、polish-edit、降级。
- 验收：沿用握手原型的 pty 用例（zsh 端到端），改为调用真实的 `polish-edit`。

**兼容矩阵**（0.0.1 手工验收；✅ 表示调研已实测过前置条件）

| App | 读取 | 回填 | 期望 |
|---|---|---|---|
| Terminal.app + zsh | Ctrl+G 握手 | polish-edit 写文件 | ✅ 写回输入行，不执行 |
| Ghostty + Claude Code / Codex | Ctrl+G 握手 | polish-edit 写文件 | ✅ 写回输入框，不提交 |
| Terminal / Ghostty + bash | 降级：AX / ⌘C 读终端选区 | 仅复制 | 结果进剪贴板 |
| Chrome / Arc 网页输入框 | AX（首次可能走 ⌘C） | ⌘V | 替换选区 |
| Safari / 备忘录 / 原生文本框 | AX | ⌘V | 替换选区 |
| Claude 桌面版（Electron） | AX（设置 AXManualAccessibility 后）/ ⌘C | ⌘V | 替换选区 |
| iTerm2 | Ctrl+G 握手 | polish-edit | 未实测 |

**未实测、需人工确认**：iTerm2；Secure Keyboard Entry 开启时的行为；Safari 页面正文（非输入框）的选区读取；⌘V 是否进入撤销栈；ssh 远程会话。
