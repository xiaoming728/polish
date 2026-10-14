# 终端流程端到端验收：zsh（pty）+ 真实 polish-edit（Polish 二进制）+ core-checks serve（真实 EditServer）。
# 用法：swift build && python3 -I scripts/terminal-e2e.py
import os, pty, re, select, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
TMP = tempfile.mkdtemp(prefix="polish-e2e-")
BUILD = TMP  # polish-edit 符号链接放这里
os.symlink(os.path.join(BIN, "Polish"), os.path.join(TMP, "polish-edit"))
SOCK = os.path.join(TMP, "s.sock")
FALLBACK = os.path.join(TMP, "fallback-ed")
with open(FALLBACK, "w") as f:  # 模拟用户原编辑器：把内容改成 echo FALLBACK-1
    # E2E_SLOW_FALLBACK=1：模拟新脚本首次执行被系统扫描拖慢（验证测试不依赖固定等待）
    slow = "sleep 0.8\n" if os.environ.get("E2E_SLOW_FALLBACK") else ""
    f.write("#!/bin/sh\n" + slow + "printf 'echo FALLBACK-1' > \"$1\"\n")
os.chmod(FALLBACK, 0o755)
ZDOT = os.path.join(TMP, "zdot")
os.mkdir(ZDOT)
with open(os.path.join(ZDOT, ".zshrc"), "w") as f:
    f.write(f"""PS1='P> '
autoload -Uz edit-command-line
zle -N polish-edit-command-line edit-command-line
zstyle ':zle:polish-edit-command-line' editor {BUILD}/polish-edit
bindkey -M emacs '^G' polish-edit-command-line
""")
ENV = dict(os.environ, POLISH_SOCK=SOCK, VISUAL=FALLBACK, ZDOTDIR=ZDOT, TERM="xterm")
ENV.pop("POLISH_FALLBACK_EDITOR", None)


class App:
    def __init__(self):
        self.p = subprocess.Popen([f"{BIN}/core-checks", "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=ENV, text=True)
        self.log = []
        threading.Thread(target=lambda: [self.log.append(l.rstrip()) for l in self.p.stdout], daemon=True).start()
        time.sleep(0.3)
    def cmd(self, c, wait=0.4):
        self.p.stdin.write(c + "\n"); self.p.stdin.flush(); time.sleep(wait)
    def stop(self):
        if self.p.poll() is None:
            self.p.kill()
        self.p.wait()


class Term:
    def __init__(self):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvpe("zsh", ["zsh", "-i"], ENV)
        self.out = b""
        self.drain(1.0)
    def drain(self, t=0.5):
        end = time.time() + t
        while time.time() < end:
            if select.select([self.fd], [], [], 0.05)[0]:
                try: self.out += os.read(self.fd, 4096)
                except OSError: return
    def key(self, b, wait=0.5):
        os.write(self.fd, b); self.drain(wait)
    def ran(self, word):  # 某条 echo 是否真的被执行（输出行以该词开头）
        text = re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", self.out).decode(errors="replace").replace("\r", "")
        return re.search(rf"(^|\n){word}\n", text) is not None
    def until(self, word, timeout=5.0):  # 等期望输出出现：新建脚本首次执行会被系统安全扫描拖慢 80–400ms，固定等待会偶发失败
        end = time.time() + timeout
        while not self.ran(word) and time.time() < end:
            self.drain(0.1)
        return self.ran(word)
    def close(self):
        try: os.kill(self.pid, 9)
        except ProcessLookupError: pass


results = []
def case(name, ok, app=None, note=""):
    results.append((name, ok))
    print(f"\n{'✅' if ok else '❌'} {name} {note}")
    if app:
        for l in app.log: print("   ", l)


# 1. 确认写回：缓冲区被替换、未执行；按 Enter 才执行
a, t = App(), Term()
t.key(b"echo DRAFT-1"); a.cmd("arm"); t.key(b"\x07"); a.cmd("confirm"); t.drain(0.5)
before = t.ran("POLISHED-1")
t.key(b"\r")
case("确认写回，不自动执行", not before and t.until("POLISHED-1") and not t.ran("DRAFT-1"), a)
a.stop(); t.close()

# 2. Esc 放弃：草稿原样
a, t = App(), Term()
t.key(b"echo DRAFT-1"); a.cmd("arm"); t.key(b"\x07"); a.cmd("cancel"); t.key(b"\r")
case("Esc 放弃，草稿不变", t.until("DRAFT-1") and not t.ran("POLISHED-1"), a)
a.stop(); t.close()

# 3. ⌘C 复制：草稿原样
a, t = App(), Term()
t.key(b"echo DRAFT-1"); a.cmd("arm"); t.key(b"\x07"); a.cmd("copy"); t.key(b"\r")
case("⌘C 复制，草稿不变", t.until("DRAFT-1") and not t.ran("POLISHED-1"), a)
a.stop(); t.close()

# 4. 未待命（用户自己按 Ctrl+G）→ 转交原编辑器
a, t = App(), Term()
t.key(b"echo DRAFT-1"); t.key(b"\x07"); t.key(b"\r")
ok = t.until("FALLBACK-1")
case("非 app 触发 → 转交原编辑器", ok, a)
if not ok and os.environ.get("E2E_DEBUG"):  # 诊断：打印终端现场
    print(re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", t.out).decode(errors="replace").replace("\r", "⏎"))
a.stop(); t.close()

# 5. 晚到（超过 1.5s）→ 降级提示 + 转交原编辑器
a, t = App(), Term()
t.key(b"echo DRAFT-1"); a.cmd("arm", wait=1.8); t.key(b"\x07"); t.key(b"\r")
case("晚到 → 超时降级 + 转交原编辑器", t.until("FALLBACK-1") and any("超时" in l for l in a.log), a)
a.stop(); t.close()

# 6. app 未运行 → 转交原编辑器
t = Term()
t.key(b"echo DRAFT-1"); t.key(b"\x07"); t.key(b"\r")
case("app 未运行 → 转交原编辑器", t.until("FALLBACK-1"))
t.close()

# 7. 预览中 app 崩溃 → 草稿原样
a, t = App(), Term()
t.key(b"echo DRAFT-1"); a.cmd("arm"); t.key(b"\x07"); a.cmd("die"); t.key(b"\r")
case("app 崩溃（EOF）→ 草稿不变", t.until("DRAFT-1") and not t.ran("POLISHED-1"), a)
a.stop(); t.close()

# 8. 终端里 Ctrl+C → app 感知断开；记录 zsh 的表现
a, t = App(), Term()
t.key(b"echo DRAFT-1"); a.cmd("arm"); t.key(b"\x07"); t.key(b"\x03", 0.8); t.key(b"\r")
case("终端 Ctrl+C → app 取消请求", any("断开" in l for l in a.log), a,
     note=f"（Ctrl+C 后按 Enter：DRAFT 被执行={t.ran('DRAFT-1')}）")
a.stop(); t.close()

# 9. 空草稿 → 提示并取消
a, t = App(), Term()
a.cmd("arm"); t.key(b"\x07"); t.key(b"\r")
case("空草稿 → 提示并取消", any("为空" in l for l in a.log), a)
a.stop(); t.close()

# 10. 退出码与文件内容（直接调用 polish-edit）
def direct(action):
    a = App()
    path = os.path.join(TMP, "draft.txt")
    with open(path, "w") as f: f.write("echo DRAFT-1\nline2")
    ino = os.stat(path).st_ino
    a.cmd("arm", 0.1)
    p = subprocess.Popen([f"{BUILD}/polish-edit", path], env=ENV)
    time.sleep(0.4)
    if action == "sigint": p.send_signal(2)
    else: a.cmd(action)
    rc = p.wait(5)
    a.stop()
    return rc, open(path).read(), os.stat(path).st_ino == ino
for action, want in [("confirm", "echo POLISHED-1\nline2"), ("cancel", "echo DRAFT-1\nline2"),
                     ("copy", "echo DRAFT-1\nline2"), ("die", "echo DRAFT-1\nline2")]:
    rc, body, same_ino = direct(action)
    case(f"直接调用 {action}: exit={rc} inode 不变={same_ino}", rc == 0 and body == want and same_ino)
rc, body, _ = direct("sigint")
case(f"直接调用 SIGINT: exit={rc}（被信号杀死，文件不变）", body == "echo DRAFT-1\nline2")

print(f"\n{sum(ok for _, ok in results)}/{len(results)} 通过")
sys.exit(0 if all(ok for _, ok in results) else 1)
