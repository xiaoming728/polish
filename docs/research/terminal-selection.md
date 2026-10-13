# 终端选区读取与按键投递的可行性（issue #3）

环境：macOS 27.2、Swift 6.3、仅 Command Line Tools。本机装有 Terminal.app 和 Ghostty 1.x（build 18109），**未装 iTerm2**。
一次性脚本在 `docs/research/scripts/`（均为探针，非产品代码）。

## 结论要点

1. **AX 读终端选区：Terminal.app 的接口形态成立，Ghostty / iTerm2 未实测。** Terminal.app 的焦点元素是 `AXTextArea`，暴露 `AXSelectedText`、`AXSelectedTextRange`、`AXValue`（实测，无选区时 `AXSelectedText` 返回空串，err=0）。"有选区时是否返回选中文字"没能验证，见未实测项。
2. **终端降级复制模式（⌘C）应作为默认路径设计，AX 只是优化。** 终端里 ⌘C 是"复制选区"，不会像 Ctrl+C 一样发 SIGINT，所以模拟 ⌘C 本身安全；可靠性待用户实测。
3. **Ctrl+G 在 Ghostty 下的编码：从源码看成立，除非程序开启了 kitty 键盘协议。**
   - 默认（legacy）：Ghostty `key_encode.zig` 的 `ctrlSeq` 把 Ctrl+字母映射为 C0 字节，Ctrl+G 得到 `0x07`。
   - 程序若通过 `CSI > 1 u` 开启 kitty "disambiguate" 标志，则 ctrl+key 按规范改发 `CSI 103 ; 5 u`（kitty 规范原文："ctrl + key ... using CSI u sequences instead of legacy ones"）。此时前台程序必须能解析 CSI u，否则收不到 Ctrl+G。是否解析取决于 Claude Code / Codex CLI，未核实。
   - 注意：这是"用户真实按键"的路径。外部程序用 `CGEvent` 投递则要先经过 macOS 事件系统到达终端，再走上面的编码，两段都要验证。
4. **Secure Keyboard Entry：检测用 `IsSecureEventInputEnabled()`，本机实测当前为 `false`。** Apple 旧文档（Ghostty 源码 `SecureInput.swift` 中引用）：开启后"键盘输入只发给有键盘焦点的应用，不会回显给其他通过 event monitor 监听键盘的应用"。据此推断：基于 event tap / monitor 监听按键的方案会失效；Carbon `RegisterEventHotKey` 是否仍触发、CGEvent 投递是否仍有效，**均未实测**（常识认为热键仍可用，但无一手证据，不要据此下结论）。
5. **检测的坑：** secure input 是全局状态，任意应用（密码框、1Password、Ghostty 自身的 Secure Keyboard Entry 菜单项）都可能打开，且 Ghostty 在失焦时会让出。提示文案不要假设是终端造成的；建议在触发热键的瞬间检测并提示"安全输入已开启，可能无法读取/回填"。
6. **辅助功能权限：** 本机运行脚本的宿主进程 `AXIsProcessTrusted() == true`（实测）。产品首次运行仍需引导授权。

## 实测记录

| 项 | 命令 | 结果 |
|---|---|---|
| 辅助功能授权 | `swift scripts/terminal-probe.swift` | `AXIsProcessTrusted: true` |
| Secure input | 同上 | `IsSecureEventInputEnabled: false` |
| Terminal.app 焦点元素 | `swift scripts/terminal-ax.swift com.apple.Terminal` | `AXTextArea`，`AXSelectedText` err=0 值为空串，`AXNumberOfCharacters`=173；属性含 `AXSelectedText`、`AXSelectedTextRanges`、`AXValue`、`AXVisibleCharacterRange` |

实测过程中的事故：试图用 `CGEvent` 合成鼠标双击来制造选区，但目标窗口不在前台，点击落到了用户当前前台的 VS Code 窗口（左上角附近，共 5 次双击）。此后停止一切合成点击，也未向 Terminal 投递按键（Terminal 的前台窗口是用户原有的窗口，不是测试窗口）。**结论：不要用合成鼠标事件做自动化选区测试，必须由用户手动选中。**

## 未实测项与用户一次性验证步骤

先在仓库根目录运行（每个脚本都是独立的 `swift 文件`）。

1. **AX 读到终端选中文字？（Terminal.app / Ghostty / iTerm2 各一次）**
   - 在目标终端里 `echo hello_polish`，用鼠标双击选中 `hello_polish`。
   - 在**另一个终端**或后台（脚本读的是别的 App，自己的终端会被选区取代，建议 `sleep 5; swift ...` 后切回目标终端保持选区）运行：
     `sleep 5; swift docs/research/scripts/terminal-ax.swift <bundleID>`，期间切回目标终端。
     bundleID：`com.apple.Terminal`、`com.mitchellh.ghostty`、`com.googlecode.iterm2`。
   - 预期若 AX 可用：输出 `AXSelectedText ... val: Optional(hello_polish)`；若为空串或 err 非 0，说明该终端读不到，只能走 ⌘C。
   - 运行脚本的宿主 App（你的终端）需要辅助功能授权（本机已有）。
2. **⌘C 降级是否可靠？** 选中文字后手动按 ⌘C，再 `pbpaste`，预期输出选中文字。再确认：在 Ghostty 中 ⌘C 是否受 `copy-on-select` / `keybind` 配置影响（本机 `~/.config/ghostty/config` 未逐项核对）。
3. **CGEvent 投递 Ctrl+G 能否到达前台程序？** 在目标终端运行 `cat -v`，保持其为前台，另一终端无法做到时用延迟：
   `sleep 5; swift docs/research/scripts/terminal-key.swift <bundleID> 5 1`，期间切回目标终端。预期 `cat -v` 显示 `^G`。若无显示，说明合成事件未被终端编码（或需用 `.cghidEventTap` 而非 `postToPid`，脚本当前用 `postToPid`，可改后再试）。
4. **kitty 协议下的 Ctrl+G：** 在 Ghostty 里运行 `printf '\e[>1u'; cat -v`，再重复第 3 步。预期显示 `^[[103;5u`（规范推断，未验证）；之后 `printf '\e[<u'` 复位。再用 Claude Code / Codex CLI 实际试一次 Ctrl+G 是否唤起外部编辑器。
5. **Secure Keyboard Entry 影响：** 在 Terminal.app 菜单"终端 > 安全键盘输入"打开（iTerm2 为 iTerm2 > Secure Keyboard Entry），运行 `swift docs/research/scripts/terminal-probe.swift`，预期 `IsSecureEventInputEnabled: true`。然后在该状态下重复第 1、3 步，并验证 Carbon 热键是否仍触发（需要一个注册了热键的原型，不在本调研范围）。

## 来源

- Ghostty 源码 `src/input/key_encode.zig`（`ctrlSeq`、CSI u 分支）：https://github.com/ghostty-org/ghostty/blob/main/src/input/key_encode.zig
- Kitty keyboard protocol 规范（progressive enhancement、disambiguate escape codes）：https://sw.kovidgoyal.net/kitty/keyboard-protocol/
- Ghostty `SecureInput.swift`（引用 Apple Carbon 旧文档对 secure event input 的描述）：https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/Secure%20Input/SecureInput.swift
- Ghostty 配置参考（kitty 键盘协议相关条目）：https://ghostty.org/docs/config/reference
- 本机实测：见上表。Apple 官方 `IsSecureEventInputEnabled` 文档页为 JS 渲染，本次未能抓取，Carbon 热键与 CGEvent 在 secure input 下的行为因此缺一手来源。
