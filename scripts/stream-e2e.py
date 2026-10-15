# 流式请求端到端：本地模拟 OpenAI 兼容 / Anthropic SSE 服务端，用 core-checks stream 走真实 URLSession。
# 用法：swift build && python3 -I scripts/stream-e2e.py [--slow]（--slow 额外跑约 30 秒的首字超时用例）
import http.server, json, os, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
seen = {}
hits = {}


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def sse(self, lines):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for l in lines:
            chunk = (l + "\n").encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
            self.wfile.flush()
            time.sleep(0.02)
        self.wfile.write(b"0\r\n\r\n")

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        case = self.path.split("/")[1]
        seen[case] = (dict(self.headers), body)
        hits[case] = hits.get(case, 0) + 1
        if case == "openai":
            d = lambda s: "data: " + json.dumps({"choices": [{"delta": {"content": s}}]})
            self.sse([": keep-alive", d(""), d("润色"), "", d("后的"), d("文本"), "data: [DONE]"])
        elif case == "anthropic":
            self.sse(["event: message_start", 'data: {"type":"message_start","message":{}}', "",
                      "event: content_block_delta", 'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}', "",
                      'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}',
                      'data: {"type":"message_stop"}'])
        elif case in ("mandatory", "bad400") and (case == "bad400" or "output_config" in body):  # 强制思考模型拒绝提速参数
            payload = json.dumps({"error": {"message": "thinking is mandatory"}}).encode()
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        elif case == "mandatory":
            self.sse(['data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}', 'data: {"type":"message_stop"}'])
        elif case == "unauthorized":
            payload = json.dumps({"error": {"message": "Invalid API key"}}).encode()
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        elif case == "empty":
            self.sse(["data: [DONE]"])
        elif case == "keepalive":  # 只有保活注释行、没有正文：应在首字 30s 时超时
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                for _ in range(20):  # 每 2s 一行保活，持续 40s
                    self.wfile.write(b"e\r\n: keep-alive\n\n\r\n")
                    self.wfile.flush()
                    time.sleep(2)
            except OSError:
                pass  # 客户端超时断开
        elif case == "midstream":
            self.sse(['data: {"choices":[{"delta":{"content":"半"}}]}', 'data: {"error":{"message":"overloaded"}}'])


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{srv.server_address[1]}"


def run(wire, case):
    path = f"{base}/{case}" + ("/v1" if wire == "openAI" else "")
    out = subprocess.run([f"{BIN}/core-checks", "stream", wire, path], capture_output=True, text=True, timeout=60).stdout.strip()
    return out


results = []
def check(ok, name, detail=""):
    results.append(ok)
    print(f"{'✅' if ok else '❌'} {name}  {detail}")

o = run("openAI", "openai")
check(o.startswith("OK deltas=3 润色后的文本"), "OpenAI 兼容：流式拼接、忽略注释与空块", o)
h, b = seen["openai"]
check(h.get("Authorization") == "Bearer k" and b["stream"] is True and b["messages"][1]["content"] == "<text lang=\"zh\">\n原文\n</text>", "OpenAI 兼容：请求头与请求体")

o = run("anthropic", "anthropic")
check(o == "OK deltas=2 Hello world", "Anthropic：text_delta 拼接、message_stop 结束", o)
h, b = seen["anthropic"]
check(h.get("x-api-key") == "k" and h.get("anthropic-version") == "2023-06-01" and b["system"] == "润色", "Anthropic：请求头与 system")

o = run("anthropic", "mandatory")
check(o == "OK deltas=1 ok" and hits["mandatory"] == 2 and "output_config" not in seen["mandatory"][1], "提速参数被 400 拒绝：去掉后自动重试一次", o)
o = run("anthropic", "bad400")
check(o == "ERR HTTP 400：thinking is mandatory" and hits["bad400"] == 2, "重试仍 400：显示服务端消息，不再重试", o)

o = run("openAI", "unauthorized")
check(o == "ERR HTTP 401：Invalid API key", "HTTP 401 显示服务端消息", o)
o = run("openAI", "empty")
check(o.startswith("ERR 模型没有返回内容"), "空响应报错", o)
o = run("openAI", "midstream")
check(o == "ERR 模型返回错误：overloaded", "流内错误", o)

if "--slow" in sys.argv:
    t = time.time()
    o = run("openAI", "keepalive")
    check(o.startswith("ERR 超时：30 秒内没有收到模型的第一个字") and 29 < time.time() - t < 40, "只有保活行：首字 30s 超时", f"{o}（{time.time() - t:.0f}s）")

print(f"\n{sum(results)}/{len(results)} 通过")
sys.exit(0 if all(results) else 1)
