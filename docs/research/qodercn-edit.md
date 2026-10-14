# qodercn 的 polish-edit 集成

2026-10-14，本机 qodercn 1.1.70。

## 根因

Polish 当前「终端中发送的按键」为默认 Ctrl+G。qodercn 的外部编辑器入口为 Ctrl+X，读取 `VISUAL` / `EDITOR`；Ctrl+G 不会调用编辑器，因此 Polish 的 1.5 秒待命窗口超时。不是 socket 连接失败。

历史背景：[issue #9](https://github.com/xiaoming728/polish/issues/9) 定义握手与超时降级；[issue #18](https://github.com/xiaoming728/polish/issues/18) 和提交 `a1931fb` 增加了全局编辑器变量和可选按键，但此前只实测 Claude/Codex，Ctrl+X 说明漏列 Qoder。

## 最小修复

使用现有 Ctrl+X 选项，不新增进程探测或修改握手协议。设置中补列 Qoder / qodercn，超时提示同时提醒检查按键与重新启动 CLI。本机选择 Ctrl+X；默认仍为 Ctrl+G，避免影响 zsh 用户。

该设置对所有终端生效：回到 zsh / Claude Code / Codex 时需选回 Ctrl+G。安装 shell 片段后需在新终端启动 qodercn，已启动进程不会继承新环境变量。

## 验证

独立 pty、真实 qodercn、真实 polish-edit 和 EditServer；只信任测试创建的空目录，不发送提示词，不访问模型。

- `python3 -I scripts/qodercn-e2e.py --key ctrlG`：失败，服务端「待命 → 握手超时 → 降级」，复现报告症状。
- `python3 -I scripts/qodercn-e2e.py`：3/3 通过；传入完整草稿，确认后重新打开编辑器读到写回内容（未发送），取消后再读仍保持原文。

pty 验证不覆盖 Carbon 的 ⌥P 触发及真实终端的 CGEvent 投递；沿用现有按键发送实现。
