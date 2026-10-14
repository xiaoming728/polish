# zsh 的 Ctrl+G 编辑器绑定实测

环境：macOS，zsh 5.9（`/bin/zsh`），bash 3.2.57（`/bin/bash`）。用 Python `pty` 驱动交互式 shell，向 pty 写入 `\x07`（等价于终端收到 Ctrl+G 后发给前台程序的字节）。脚本见 [`zsh-ctrlg/`](zsh-ctrlg/)：`run.py <case>`，`zdot/.zshrc` 为被测片段，`bin/polish-edit` 是桩（存在触发标记文件时写入固定两行文本，否则 `exec` 原编辑器），`bin/fallback-ed` 模拟用户原编辑器。

## 结论

1. **可行**。zsh 自带的 `edit-command-line` 编辑完成后只替换缓冲区，不执行；必须再按 Enter 才会执行。
2. **不需要包装函数和局部 VISUAL**。`edit-command-line` 会先读取 `zstyle :zle:$WIDGET editor`，因此给它起个别名 widget，再用 zstyle 指定编辑器即可。`$VISUAL`/`$EDITOR` 保持不变，git 等不受影响，polish-edit 也能直接用 `$VISUAL` 作为原编辑器：

   ```zsh
   # --- polish ---
   autoload -Uz edit-command-line
   zle -N polish-edit-command-line edit-command-line
   zstyle ':zle:polish-edit-command-line' editor polish-edit
   bindkey -M emacs '^G' polish-edit-command-line
   bindkey -M viins '^G' polish-edit-command-line
   bindkey -M vicmd '^G' polish-edit-command-line
   # --- /polish ---
   ```

   片段必须放在 `bindkey -v`/`-e` **之后**：`bindkey -v` 会重置 keymap，覆盖先前的绑定（已实测）。
3. **⚠️ 未绑定时 zsh 的 Ctrl+G 会丢弃整行草稿**：emacs keymap 下默认绑定是 `send-break`，输入行被清空并显示新提示符；vi keymap（viins/vicmd）下默认是 `list-expand`。本机真实 `~/.zshrc` 使用 emacs keymap，Ctrl+G 为 `send-break`。因此 app 不能在"不确定 zsh 已安装绑定"的情况下向 zsh 发送 Ctrl+G。
4. **bash 3.2 下 Ctrl+G 只响铃**（readline `abort`），输入行原样保留，按 Enter 照常执行。确认降级为复制模式的判定（bash 的 Ctrl+X Ctrl+E 会在编辑后直接执行）。

## 用例结果

| 用例 | 操作 | 结果 |
|---|---|---|
| default | `zsh -f`，输入 `echo DRAFT`，按 Ctrl+G，按 Enter | 行被 `send-break` 清空，Enter 执行空行；**草稿丢失** |
| bound | 已绑定，触发 polish，按 Ctrl+G，按 Enter | 缓冲区被替换为两行 `echo POLISHED-1/2`；按 Enter 后两行才执行 |
| bound-noenter | 同上，但 Ctrl+G 之后不按 Enter | `POLISHED-1` 从未输出，说明没有自动执行 |
| fallback | 已绑定，**未**触发 polish | polish-edit 转交 `$VISUAL`（fallback-ed），收到 `echo DRAFT`，结果回到缓冲区 |
| multiline / multi-fb | 在 `for>` 续行提示符（PS2）下按 Ctrl+G | 编辑器收到**完整**的 `PREBUFFER+BUFFER`（`for i in 1 2; do` + `echo $i`）；回写走 `print -z` + `send-break`，会出现新的主提示符并显示整段文本，仍需按 Enter 才执行 |
| vi / vicmd | `bindkey -v` 后，在插入模式和命令模式下分别按 Ctrl+G | 与 emacs 模式相同 |
| gitvisual | 编辑后执行 `echo $VISUAL` | `VISUAL=fallback-ed`，未被修改 |
| bash | `bash --norc`，输入 `echo DRAFT`，按 Ctrl+G，按 Enter | 只响铃，行保留，Enter 后输出 `DRAFT` |

## 补充

- `edit-command-line` 在 vim/emacs 编辑器下会传入光标位置参数；polish-edit 不匹配 `*vim*`/`*emacs*`，只收到文件路径这一个参数。但如果 polish-edit 转交给 vim，就**拿不到**光标定位参数，只是退化为打开文件，属于可以接受的小损失。
- 有活动区域（`REGION_ACTIVE`）时，只编辑区域内的文本。
- 未测：其他 zsh 插件（如 zsh-vi-mode、oh-my-zsh 自定义 keymap）对绑定的覆盖；app 如何判断前台是"已绑定的 zsh"，留给通信与握手约定一单。
