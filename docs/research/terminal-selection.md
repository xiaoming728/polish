# 终端选区读取与按键投递的可行性（issue #3）

环境：macOS 27.2、Swift 6.3、仅 Command Line Tools。本机装有 Terminal.app 和 Ghostty（build 18109），**未装 iTerm2**。Claude Code 2.1.296、Codex（nvm 安装）。
脚本在 `docs/research/scripts/`（一次性探针，非产品代码）。第二轮补测经用户授权，只操作自己新开的窗口，每次投递事件前校验前台 pid。

## 结论要点

1. **AX 读终端选区：Terminal.app 和 Ghostty 均成立（实测）。** 双击选中 `hello_polish` 后，两者的 `kAXFocusedUIElement`（`AXTextArea`）都返回 `kAXSelectedText = hello_polish`。无选区时：Terminal 返回空串，Ghostty 返回错误 -25212（无值），实现要同时处理这两种形态。iTerm2 未实测。
2. **⌘C + `pbpaste` 在两个终端均可靠（实测）。** 先写入哨兵 `SENTINEL` 再按 ⌘C，`pbpaste` 得到选中文字。哨兵法同时能区分"没有选区"（⌘C 不改剪贴板，`pbpaste` 仍是哨兵），可用于判断读取失败。
3. **CGEvent 投递 Ctrl+G 成立（实测）。** 用 `CGEvent`（keycode 5 + `maskControl`，`.cghidEventTap`）：
   - Terminal.app，`/bin/cat -v`：显示 `^G`。
   - Ghostty，普通模式：`^G`（0x07）。
   - Ghostty，程序开启 kitty 协议（`printf '\e[>1u'`）：显示 `^[[103;5u`，与 kitty 规范和 Ghostty 源码推断一致。此时前台程序必须能解析 CSI u。
   - **Claude Code 2.1.296（Ghostty 内）**：以 `VISUAL=<写入固定文本的脚本>` 启动，CGEvent 发 Ctrl+G 后，输入框出现 `POLISHED_BY_TEST`，未提交。**Codex 同样成立。** 说明两者能处理 Ctrl+G，包括 Claude Code 自身开启 kitty 协议后的编码。
4. **Secure Keyboard Entry：未实测。** 检测用 `IsSecureEventInputEnabled()`（本机当前 `false`，实测）。Apple 旧文档（Ghostty `SecureInput.swift` 引用）：开启后"键盘输入只发给有键盘焦点的应用，不回显给其他监听键盘的应用"。据此推断 event tap 类方案会失效；Carbon 热键与 CGEvent 在其下的行为无一手证据。它是全局状态，密码框等任何应用都可能触发，提示文案不要假设是终端造成的。
5. **辅助功能权限：** 脚本宿主进程 `AXIsProcessTrusted() == true`（实测）。

## 实现要点（从实测得出）

- **Ghostty 需要先发 `mouseMoved` 再点击**：不先移动鼠标时，合成的双击没有产生选区；加了移动事件和 200ms 等待后成功。Terminal.app 不需要。这只影响测试，不影响产品（产品读用户已有的选区）。
- **Ghostty 的 `AXValue` 可读全屏文字**（含 TUI 输入框内容），可用于自动化验证回填是否生效。
- **不要用合成鼠标事件做自动化选区测试而不校验前台应用**：第一轮曾因此误点到用户的 VS Code（5 次双击），第二轮起每次投递前校验前台 pid，不符即中止。
- `cat` 在本机被 alias 成 `bat`，测试须写 `/bin/cat -v`。
- Ghostty 的 `open -na Ghostty --args -e ...` 偶尔会忽略 `-e`（窗口回到默认 shell），需检查窗口标题后再投递事件。

## 实测记录

| 项 | 方法 | 结果 |
|---|---|---|
| 辅助功能 / Secure input | `terminal-probe.swift` | `true` / `false` |
| Terminal AX 选区 | `terminal-drv dblclick` + `sel` | `AXSelectedText: hello_polish` |
| Ghostty AX 选区 | 同上（先 mouseMoved） | `AXSelectedText: hello_polish`；无选区时 err -25212 |
| ⌘C + pbpaste（Terminal、Ghostty） | `terminal-drv cmdc` | `hello_polish` |
| Ctrl+G，Terminal，`/bin/cat -v` | `terminal-drv ctrlg` | `^G` |
| Ctrl+G，Ghostty 普通 / kitty | 同上 | `^G` / `^[[103;5u` |
| Ctrl+G → `$VISUAL`，Claude Code、Codex，Ghostty | `terminal-visual-test.sh` 作 VISUAL | 输入框出现 `POLISHED_BY_TEST`，未提交 |

测完已关闭自己开的窗口；Claude Code / Codex 进程用 `kill` 结束（未走 Ctrl+C）。

## 仍未实测

1. **iTerm2**：AX 选区、⌘C、Ctrl+G 均未测（未安装）。
2. **Secure Keyboard Entry 开启时**：Carbon 热键是否仍触发、CGEvent 投递与 AX 读取是否仍有效。用户验证：在 Terminal"终端 > 安全键盘输入"打开后，`swift docs/research/scripts/terminal-probe.swift` 应输出 `true`，再重复上述 AX / Ctrl+G 步骤（`terminal-drv` 需先 `swiftc` 编译，参数见脚本头注释）；热键部分需要一个注册了热键的原型。
3. **Terminal.app 内的 Claude Code / Codex Ctrl+G 回填**：只在 Ghostty 内测过。
4. **真实用户选区与合成选区的差异**：鼠标拖选、多行选区、滚动后选区、折行文字的 `AXSelectedText` 内容（是否带硬换行）未测。
5. **键盘修饰键冲突**：用户按住 ⌥ 时（⌥P 触发热键瞬间）投递 Ctrl+G，修饰键是否污染事件，未测。

## 来源

- Ghostty 源码 `src/input/key_encode.zig`：https://github.com/ghostty-org/ghostty/blob/main/src/input/key_encode.zig
- Kitty keyboard protocol：https://sw.kovidgoyal.net/kitty/keyboard-protocol/
- Ghostty `SecureInput.swift`：https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/Secure%20Input/SecureInput.swift
- 本机实测：见上表。Apple `IsSecureEventInputEnabled` 官方文档页为 JS 渲染，未能抓取。
