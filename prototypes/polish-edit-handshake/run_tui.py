# PROTOTYPE — 在真实 Claude Code / Codex TUI 里验证握手（只往输入框填草稿，不按 Enter，不会发送消息）
# 用法：python3 -I run_tui.py claude|codex confirm|cancel
import os, pty, re, select, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")
tool, action = sys.argv[1], sys.argv[2]
TMP = tempfile.mkdtemp(prefix="polish-tui-")
SOCK = os.path.join(TMP, "s.sock")
ENV = dict(os.environ, POLISH_SOCK=SOCK, VISUAL=f"{BUILD}/polish-edit", POLISH_FALLBACK_EDITOR="false", TERM="xterm-256color")

app = subprocess.Popen([f"{BUILD}/proto", "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=ENV, text=True)
log = []
threading.Thread(target=lambda: [log.append(l.rstrip()) for l in app.stdout], daemon=True).start()
def cmd(c):
    app.stdin.write(c + "\n"); app.stdin.flush(); time.sleep(0.5)

pid, fd = pty.fork()
if pid == 0:
    os.chdir(os.path.expanduser("~/IdeaProjects/polish"))  # 已信任的目录，避免信任弹窗
    os.execvpe(tool, [tool], ENV)
import fcntl, struct, termios
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))  # 默认 0x0 时 Codex 不渲染
out = b""
def drain(t):
    global out
    end = time.time() + t
    while time.time() < end:
        if select.select([fd], [], [], 0.05)[0]:
            try: chunk = os.read(fd, 65536)
            except OSError: return
            out += chunk
            # 充当最小终端：应答 Codex 启动时的查询，否则它不渲染
            for q, a in [(b"\x1b]10;?", b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\"), (b"\x1b]11;?", b"\x1b]11;rgb:0000/0000/0000\x1b\\"),
                         (b"\x1b[?u", b"\x1b[?0u"), (b"\x1b[c", b"\x1b[?62c"), (b"\x1b[6n", b"\x1b[1;1R")]:
                for _ in range(chunk.count(q)):
                    os.write(fd, a)
def screen_tail():
    return re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][0-9A-Za-z]|\x1b[=>]", "", out.decode(errors="replace"))[-1500:]

drain(8)
os.write(fd, b"say DRAFT-1"); drain(1.5)
mark = len(out)
cmd("arm"); os.write(fd, b"\x07"); drain(2)
cmd(action); drain(3)
after = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", out[mark:].decode(errors="replace"))
print("\n".join(log))
print("---- 回填后屏幕片段 ----")
print(screen_tail())
print("---- 判定 ----")
print("握手成功:", any("握手成功" in l for l in log))
print("出现 POLISHED-1:", "POLISHED-1" in after)
print("输入框仍有 DRAFT-1:", "DRAFT-1" in screen_tail())
# 清空输入框后退出，不发送任何消息
try:
    os.write(fd, b"\x15"); drain(0.3)
    for _ in range(3):
        os.write(fd, b"\x03"); drain(0.5)
except OSError:
    pass  # TUI 已退出
try: os.kill(pid, 9)
except ProcessLookupError: pass
app.kill()
