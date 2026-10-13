// 断言自检：swift run core-checks。预期值来自协议文档的示例与 design.md 的约定。
import Foundation
import PolishCore

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

print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
