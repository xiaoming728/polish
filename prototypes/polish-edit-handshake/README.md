# PROTOTYPE：polish-edit 与 app 的握手（一次性代码，不合入 main）

验证「polish-edit 与 app 的通信和握手约定」（issue #9）定下的约定是否在真实 shell / TUI 中成立。

## 运行

```sh
swiftc -swift-version 5 -O proto.swift -o build/proto && ln -sf proto build/polish-edit
python3 -I run.py                       # zsh 端到端 + 直接调用，14 个用例
python3 -I run_tui.py claude confirm    # 真实 TUI：claude|codex × confirm|cancel（只填输入框，不发送）
```

`proto serve` 是假 app，从 stdin 读命令（`arm`、`confirm`、`cancel`、`copy`、`die`），每个事件都打印状态。`build/polish-edit` 是指向同一个二进制的符号链接，按 argv[0] 进入 `--edit` 模式。

## 约定（原型实现）

- socket：`POLISH_SOCK`，正式实现放在 `~/Library/Application Support/Polish/` 下，权限 0600。
- 帧格式：一行头部，后面跟 n 字节正文。
  - polish-edit → app：`EDIT n` + 草稿。
  - app → polish-edit：`NO`，`CANCEL`，或 `OK n` + 结果。
- app 发送 Ctrl+G 时进入「待命」：同一时间只有一个待命，1.5s 后自动解除。不在待命（或正忙）时回 `NO`。
- polish-edit：
  - 连不上 socket，或收到 `NO` → 交给原编辑器，查找顺序为 `POLISH_FALLBACK_EDITOR` → 非 polish-edit 的 `$VISUAL` → `$EDITOR` → `vi`，通过 `sh -c` 执行，支持带参数的编辑器。
  - 收到 `OK` → 原地写入，不做原子替换，inode 保持不变。
  - 其他情况（包括 EOF）都不改文件。
  - 所有情况一律 `exit 0`。
- app 在预览阶段若发现连接断开（终端里按了 Ctrl+C），就取消请求、关闭面板。

## 结果

| 场景 | 结果 |
|---|---|
| zsh：确认写回 / Esc / ⌘C / 未待命 / 晚到 / app 未运行 / app 崩溃 / 终端 Ctrl+C / 空草稿 | 9/9 ✅ |
| 直接调用：confirm / cancel / copy / die 时都 exit 0、inode 不变；SIGINT 时文件不变 | 5/5 ✅ |
| Claude Code 2.1.296：confirm → 输入框变为 `say POLISHED-1`；cancel → 保留 `say DRAFT-1`；均未提交 | ✅ |
| Codex：confirm / cancel 同上 | ✅ |

## 附带发现

- zsh 中 polish-edit 等待期间按 Ctrl+C，整行会被丢弃（zsh 的常规行为），而 app 能正确感知并取消请求。这是用户主动操作，可以接受。
- zsh 传过来的草稿末尾带 `\n`，Claude/Codex 传过来的不带，正式实现时应原样回传。
- Codex 在 pty 中需要非 0 的窗口尺寸，并且要应答它的终端查询才会渲染。这只影响自动化测试，可供后续「自动化验收范围」参考。
