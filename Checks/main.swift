// 断言自检：swift run core-checks。预期值来自协议文档的示例与 design.md 的约定。
import Foundation
import PolishCore

// core-checks serve：用真实 EditServer 充当可脚本化的「假 app」，供 scripts/terminal-e2e.py 驱动。
// stdin 命令：arm / confirm / cancel / die；每个事件打印一行 [app] 日志。
if CommandLine.arguments.dropFirst().first == "serve" {
    setvbuf(stdout, nil, _IONBF, 0)
    MainActor.assumeIsolated {
        let server = EditServer()
        var draft = ""
        server.onEdit = { d in
            draft = d
            print("[app] 握手成功，接手草稿 \(d.debugDescription)")
            if d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("[app] 输入框为空 → 取消")
                server.reply(.cancel)
            }
        }
        server.onTimeout = { print("[app] 握手超时 → 降级") }
        server.onDisconnect = { print("[app] polish-edit 断开 → 取消请求") }
        do { try server.start() } catch { print("[app] 启动失败 \(error)"); exit(1) }
        print("[app] listening \(Paths.socket)")
        FileHandle.standardInput.readabilityHandler = { h in
            let cmds = String(decoding: h.availableData, as: UTF8.self).split(separator: "\n").map(String.init)
            if cmds.isEmpty { exit(0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for c in cmds {
                        switch c {
                        case "arm": server.arm(); print("[app] 待命")
                        case "confirm":
                            let out = draft.replacingOccurrences(of: "DRAFT", with: "POLISHED")
                            print("[app] 确认 → \(out.debugDescription)")
                            server.reply(.ok(Data(out.utf8)))
                        case "cancel", "copy": print("[app] 放弃"); server.reply(.cancel)
                        case "die": print("[app] 模拟崩溃"); exit(9)
                        default: print("[app] 忽略 \(c)")
                        }
                    }
                }
            }
        }
    }
    dispatchMain()
}

nonisolated(unsafe) var stash: AnyObject?

// core-checks stream <openAI|anthropic> <baseURL>：真实 URLSession 流式请求，供 scripts/stream-e2e.py 对照模拟服务端
if CommandLine.arguments.dropFirst().first == "stream" {
    let a = CommandLine.arguments
    let p = Profile(name: "e2e", preset: "e2e", wire: Wire(rawValue: a[2])!, baseURL: a[3], model: "m", instruction: "润色", extraJSON: "")
    MainActor.assumeIsolated {
        var deltas = 0
        let polisher = Polisher() // 与 app 一样必须持有：start() 内部只弱引用自身
        stash = polisher
        polisher.start(p, apiKey: "k", text: "原文", onDelta: { _ in deltas += 1 }, onDone: { r in
            switch r {
            case .success(let s): print("OK deltas=\(deltas) \(s)")
            case .failure(let e): print("ERR \(e.localizedDescription)")
            }
            exit(0)
        })
    }
    dispatchMain()
}

var failures = 0
func check(_ ok: Bool, _ name: String, file: String = #file, line: Int = #line) {
    if ok { print("✅ \(name)") } else { failures += 1; print("❌ \(name)  (\(line))") }
}

// MARK: StreamDecoder — OpenAI 兼容

do {
    var d = StreamDecoder(wire: .openAI)
    check(d.feed(line: #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}"#) == nil, "OpenAI：空 content 不产出")
    check(d.feed(line: #"data: {"choices":[{"index":0,"delta":{"content":"你好"}}]}"#) == .text("你好"), "OpenAI：content 增量")
    check(d.feed(line: #"data:{"choices":[{"delta":{"reasoning_content":"想"}}]}"#) == nil, "OpenAI：忽略思考内容，data: 后无空格也能解析")
    check(d.feed(line: ": OPENROUTER PROCESSING") == nil, "OpenAI：忽略注释行")
    check(d.feed(line: #"data: {"choices":[]}"#) == nil, "OpenAI：容忍空 choices（usage 块）")
    check(d.feed(line: "data: [DONE]") == .done, "OpenAI：[DONE] 结束")
    check(d.feed(line: #"data: {"error":{"message":"rate limited"}}"#) == .failure("rate limited"), "OpenAI：流内错误")
}

// MARK: StreamDecoder — Anthropic

do {
    var d = StreamDecoder(wire: .anthropic)
    check(d.feed(line: "event: content_block_delta") == nil, "Anthropic：event 行不产出")
    check(d.feed(line: #"data: {"type":"message_start","message":{"id":"msg_1"}}"#) == nil, "Anthropic：message_start 不产出")
    check(d.feed(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#) == .text("Hi"), "Anthropic：text_delta")
    check(d.feed(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"x"}}"#) == nil, "Anthropic：忽略 thinking_delta")
    check(d.feed(line: #"data: {"type":"ping"}"#) == nil, "Anthropic：ping")
    check(d.feed(line: #"data: {"type":"message_stop"}"#) == .done, "Anthropic：message_stop 结束")
    check(d.feed(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) == .failure("Overloaded"), "Anthropic：error 事件")
}

// MARK: 请求构造

func body(_ r: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
}

do {
    let p = Profile(name: "默认", preset: "DeepSeek", wire: .openAI, baseURL: "https://api.deepseek.com/", model: "deepseek-chat",
                    instruction: "润色", extraJSON: #"{"temperature":0.3,"thinking":{"type":"disabled"}}"#)
    let r = try makeRequest(p, apiKey: "sk-1", text: "原文")
    check(r.url?.absoluteString == "https://api.deepseek.com/chat/completions", "OpenAI：URL 拼接并去掉末尾斜杠")
    check(r.httpMethod == "POST", "OpenAI：POST")
    check(r.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1", "OpenAI：Bearer 鉴权")
    check(r.value(forHTTPHeaderField: "Content-Type") == "application/json", "OpenAI：JSON 请求体")
    let b = body(r)
    check(b["model"] as? String == "deepseek-chat" && b["stream"] as? Bool == true, "OpenAI：model + stream")
    let msgs = b["messages"] as? [[String: String]] ?? []
    check(msgs.count == 2 && msgs[0] == ["role": "system", "content": "润色"]
          && msgs[1] == ["role": "user", "content": "<text>\n原文\n</text>"], "OpenAI：system 指令 + <text> 包裹原文")
    check(b["temperature"] as? Double == 0.3 && (b["thinking"] as? [String: String]) == ["type": "disabled"], "额外 JSON 合并到顶层")
}

do {
    let p = Profile(name: "C", preset: "Anthropic", wire: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-sonnet-5-5",
                    instruction: "润色", extraJSON: #"{"max_tokens":1024}"#)
    let r = try makeRequest(p, apiKey: "ak", text: "原文")
    check(r.url?.absoluteString == "https://api.anthropic.com/v1/messages", "Anthropic：URL")
    check(r.value(forHTTPHeaderField: "x-api-key") == "ak" && r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01"
          && r.value(forHTTPHeaderField: "Authorization") == nil, "Anthropic：x-api-key + anthropic-version，无 Bearer")
    let b = body(r)
    check(b["system"] as? String == "润色", "Anthropic：system 为顶层字段")
    check((b["messages"] as? [[String: String]]) == [["role": "user", "content": "<text>\n原文\n</text>"]], "Anthropic：只有 user 消息")
    check(b["max_tokens"] as? Int == 1024, "Anthropic：额外 JSON 覆盖默认 max_tokens")
    let plain = Profile(name: "C", preset: "Anthropic", wire: .anthropic, baseURL: "https://api.anthropic.com", model: "m", instruction: "", extraJSON: "")
    check(body(try makeRequest(plain, apiKey: "ak", text: "x"))["max_tokens"] as? Int == 4096, "Anthropic：默认 max_tokens 4096")

    let m = try makeModelsRequest(p, apiKey: "ak")
    check(m.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000" && m.httpMethod == "GET", "Anthropic：/v1/models?limit=1000")
}

do {
    let bad = Profile(name: "x", preset: "自定义", wire: .openAI, baseURL: "https://x.test/v1", model: "m", instruction: "", extraJSON: "{oops")
    var threw = false
    do { _ = try makeRequest(bad, apiKey: "k", text: "t") } catch RequestError.badExtraJSON { threw = true }
    check(threw, "额外 JSON 非法时报 badExtraJSON")
    var threwURL = false
    do { _ = try makeRequest(Profile(name: "x", preset: "自定义", wire: .openAI, baseURL: "not a url", model: "m", instruction: "", extraJSON: ""),
                             apiKey: "k", text: "t") } catch RequestError.badURL { threwURL = true }
    check(threwURL, "Base URL 非法时报 badURL")
    let m = try makeModelsRequest(Profile(name: "x", preset: "自定义", wire: .openAI, baseURL: "https://x.test/v1", model: "", instruction: "", extraJSON: ""), apiKey: "k")
    check(m.url?.absoluteString == "https://x.test/v1/models" && m.value(forHTTPHeaderField: "Authorization") == "Bearer k", "OpenAI：/models")
    check(parseModels(Data(#"{"object":"list","data":[{"id":"b"},{"id":"a"}]}"#.utf8)) == ["a", "b"], "parseModels：取 data[].id 并排序")
    check(parseModels(Data("garbage".utf8)) == [], "parseModels：非法响应返回空")
}

// MARK: 握手帧

do {
    check(encode(.edit(Data("echo 你好\n".utf8))) == Data("EDIT 12\necho 你好\n".utf8), "encode EDIT：长度按字节计")
    check(encode(.no) == Data("NO\n".utf8) && encode(.cancel) == Data("CANCEL\n".utf8), "encode NO / CANCEL")

    // try? 会压平可选值，分不清「抛错」与「等待」，所以显式区分三种结果
    func pull(_ r: inout FrameReader) -> String {
        do { return try r.next().map { "\($0)" } ?? "wait" } catch { return "throw" }
    }
    var r = FrameReader()
    r.append(Data("OK 5\nab".utf8))
    check(pull(&r) == "wait", "半帧：等待更多字节")
    r.append(Data("cdeNO\nCAN".utf8))
    check(pull(&r) == "\(EditMessage.ok(Data("abcde".utf8)))", "粘包：先取出完整 OK 帧")
    check(pull(&r) == "no", "粘包：再取出 NO")
    check(pull(&r) == "wait", "剩余半个头部：等待")
    r.append(Data("CEL\n".utf8))
    check(pull(&r) == "cancel", "补齐后得到 CANCEL")

    var bad = FrameReader()
    bad.append(Data("HELLO\n".utf8))
    check(pull(&bad) == "throw", "未知头部抛错")
    var neg = FrameReader()
    neg.append(Data("EDIT -1\n".utf8))
    check(pull(&neg) == "throw", "非法长度抛错")
}

// MARK: 原编辑器查找

do {
    check(fallbackEditor(env: ["POLISH_FALLBACK_EDITOR": "nvim", "VISUAL": "code -w", "EDITOR": "vim"]) == "nvim", "优先 POLISH_FALLBACK_EDITOR")
    check(fallbackEditor(env: ["POLISH_FALLBACK_EDITOR": "", "VISUAL": "code -w", "EDITOR": "vim"]) == "code -w", "空值跳过，取 VISUAL")
    check(fallbackEditor(env: ["VISUAL": "/Applications/Polish.app/Contents/MacOS/polish-edit", "EDITOR": "vim"]) == "vim", "VISUAL 指向 polish-edit 时跳过")
    check(fallbackEditor(env: [:]) == "vi", "都没有时用 vi")
}

// MARK: 结果整理

do {
    check(finalize("\n  润色后  \n", original: "原文") == "润色后", "去掉首尾空白")
    check(finalize("<text>\n润色后\n</text>", original: "原文") == "润色后", "去掉模型带回的 <text> 包裹")
    check(finalize("润色后", original: "echo hi\n") == "润色后\n", "原文以换行结尾时补回换行（zsh 草稿）")
    check(finalize("第一行\n\n第二行", original: "x") == "第一行\n\n第二行", "保留内部换行")
}

print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
