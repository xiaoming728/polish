# 本机 qodercn 集成验收；不提交提示词。先 swift build，再 python3 -I scripts/qodercn-e2e.py。
# --key ctrlG 可复现错误的编辑器快捷键；默认验证 Ctrl+X。
import argparse
import os
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--key", choices=["ctrlG", "ctrlX"], default="ctrlX")
args = parser.parse_args()
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
binary = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=root, text=True).strip()
cli = shutil.which("qodercn")
assert cli, "需要本机安装并登录 qodercn"

with tempfile.TemporaryDirectory(prefix="polish-qoder-e2e-") as tmp:
    editor = os.path.join(tmp, "polish-edit")
    os.symlink(os.path.join(binary, "Polish"), editor)
    env = dict(os.environ, POLISH_SOCK=os.path.join(tmp, "s.sock"),
               VISUAL=editor, EDITOR=editor, TERM="xterm-256color")
    app = subprocess.Popen([os.path.join(binary, "core-checks"), "serve"], env=env,
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    log = []
    threading.Thread(target=lambda: [log.append(line.rstrip()) for line in app.stdout], daemon=True).start()
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(cli, [cli, "--cwd", tmp, "--setting-sources", "user"], env)

    def drain(seconds):
        output = b""
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if select.select([fd], [], [], 0.05)[0]:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                output += chunk
                if b"\x1b[6n" in chunk:
                    os.write(fd, b"\x1b[1;1R")
        return output

    def command(text):
        app.stdin.write(text + "\n")
        app.stdin.flush()

    def handshake(want):
        before = len(log)
        command("arm")
        drain(0.1)
        os.write(fd, b"\x07" if args.key == "ctrlG" else b"\x18")
        end = time.monotonic() + 2
        while time.monotonic() < end:
            drain(0.05)
            if any("握手成功" in line and want in line for line in log[before:]):
                return
        raise AssertionError(f"{args.key} 未能连接 polish-edit，期望草稿 {want!r}；事件：{log[before:]}")

    try:
        screen = drain(4)
        assert b"trust" in screen.lower(), "未到达新目录信任提示，CLI 启动状态不符合预期"
        os.write(fd, b"\r")  # 仅信任测试创建的空目录；从不向输入框发送 Enter
        drain(4)
        os.write(fd, b"POLISH-QODER-DRAFT")
        drain(0.3)
        handshake("POLISH-QODER-DRAFT")
        command("confirm")
        drain(0.5)
        handshake("POLISH-QODER-POLISHED")  # 写回后仍在输入框中，没有发送
        command("cancel")
        drain(0.5)
        handshake("POLISH-QODER-POLISHED")  # 取消保留原文
        command("cancel")
        print("qodercn：握手、确认写回且未发送、取消保留原文，3/3 通过")
    finally:
        os.kill(pid, signal.SIGKILL)
        os.close(fd)
        app.kill()
        app.wait(timeout=5)
