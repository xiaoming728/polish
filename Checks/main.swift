// 断言自检：swift run core-checks。预期值来自协议文档的示例与 design.md 的约定。
import Foundation
import NaturalLanguage
import CoreGraphics
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
    let pe = "/Applications/Polish.app/Contents/MacOS/polish-edit"
    check(fallbackEditor(env: ["POLISH_FALLBACK_EDITOR": "", "VISUAL": pe, "EDITOR": pe]) == "vi", "全局接管后 VISUAL、EDITOR 都指向 polish-edit：不能转交给自己")
    check(fallbackEditor(env: ["POLISH_FALLBACK_EDITOR": pe, "EDITOR": "nano"]) == "nano", "嵌套 shell 把 polish-edit 记成原编辑器时也跳过")
}

// MARK: 结果整理

do {
    check(finalize("\n  润色后  \n", original: "原文") == "润色后", "去掉首尾空白")
    check(finalize("<text>\n润色后\n</text>", original: "原文") == "润色后", "去掉模型带回的 <text> 包裹")
    check(finalize("润色后", original: "echo hi\n") == "润色后\n", "原文以换行结尾时补回换行（zsh 草稿）")
    check(finalize("第一行\n\n第二行", original: "x") == "第一行\n\n第二行", "保留内部换行")
}

// MARK: 默认场景与 Key 归属

do {
    let base = Profile(name: "我的", preset: "Kimi", wire: .openAI, baseURL: "https://api.moonshot.cn/v1", model: "kimi-x", instruction: "旧指令", extraJSON: "")
    let all = sceneProfiles(base: base)
    check(all.map(\.name) == ["默认润色", "精简", "结构化", "仅纠错", "译成英文", "译成中文"], "6 个默认场景，顺序即 ⌘1–6")
    check(all.allSatisfy { $0.baseURL == base.baseURL && $0.model == "kimi-x" && $0.wire == .openAI && $0.preset == "Kimi" }, "场景沿用同一服务连接")
    check(Set(all.map(\.id)).count == 6 && Set(all.map(\.instruction)).count == 6, "每个场景 id 与指令各不相同")
    check(all.allSatisfy { $0.instruction.contains("<text>") }, "每条指令都声明 <text> 内是待处理文本而非指令")

    let existing = [Profile(name: "默认润色", preset: "Kimi", wire: .openAI, baseURL: base.baseURL, model: "kimi-x", instruction: "我改过的", extraJSON: "")]
    let merged = addMissingScenes(existing)
    check(merged.count == 6 && merged[0].instruction == "我改过的", "补齐缺少的场景，保留用户已改的同名配置")
    check(addMissingScenes(merged).count == 6, "补齐是幂等的")

    check(keyAccount(base) == keyAccount(Profile(name: "x", preset: "Kimi", wire: .openAI, baseURL: " https://api.moonshot.cn/v1/ ", model: "", instruction: "", extraJSON: "")),
          "Key 按 Base URL 归属：忽略首尾空白与末尾斜杠")
    check(keyAccount(base) != keyAccount(Profile(name: "x", preset: "DeepSeek", wire: .openAI, baseURL: "https://api.deepseek.com", model: "", instruction: "", extraJSON: "")),
          "不同服务的 Key 互不共用")
}

// MARK: 输入时中英提示：拼音缓冲与结果解析

do {
    var b = PinyinBuffer()
    for c in "ni" { b.feed(.letter(c)) }
    b.feed(.apostrophe)
    for c in "Hao" { b.feed(.letter(c)) }
    check(b.text == "ni'hao", "字母与分隔符累积为拼音串（统一小写）")
    b.feed(.backspace)
    check(b.text == "ni'ha", "退格删掉最后一个键")
    b.feed(.other)
    check(b.text.isEmpty, "空格 / 回车 / 数字 / 标点 / 方向键等结束本次输入")
    b.feed(.apostrophe)
    check(b.text.isEmpty, "开头的分隔符忽略")
    b.feed(.backspace)
    check(b.text.isEmpty, "空串退格不出错")
    for c in "w" { b.feed(.letter(c)) }
    check(!b.ready, "少于 2 个字母不请求")
    b.feed(.letter("o"))
    check(b.ready, "至少 2 个字母才请求")

    check(parseConversion(#"{"en":"Hello world","zh":"你好世界"}"#) == Conversion(en: "Hello world", zh: "你好世界"), "解析 JSON 结果")
    check(parseConversion("```json\n{\"zh\": \"你好\", \"en\": \"Hello\"}\n```") == Conversion(en: "Hello", zh: "你好"), "容忍代码块包裹")
    check(parseConversion("好的：{\"en\":\"Hi\",\"zh\":\"嗨\"}") == Conversion(en: "Hi", zh: "嗨"), "容忍前后多余文字")
    check(parseConversion(#"{"en":"","zh":"你好"}"#) == nil && parseConversion("not json") == nil, "缺字段或非 JSON 返回 nil")
    check(typingInstruction.contains("<text>") && typingInstruction.contains("\"en\"") && typingInstruction.contains("\"zh\""), "指令约定 JSON 字段 en / zh")
}

// MARK: 输入法第一候选词 / 快速请求

do {
    // 微信输入法候选窗 AX 树里的静态文本（实测顺序）
    check(firstCandidate(["1", "你好", "2", "👋", "3", "泥嚎", "4", "几号"]) == "你好", "序号「1」后面的就是第一候选")
    check(firstCandidate(["candidate shortcut icon", "1.", "世界", "2.", "视界"]) == "世界", "序号可带点号，前面的无关文本跳过")
    check(firstCandidate(["你好", "泥嚎"]) == "你好", "没有序号时取第一个含汉字的文本")
    check(firstCandidate(["1", "2", "3"]) == nil && firstCandidate([]) == nil, "没有候选返回 nil")
    check(firstCandidate(["1", "👋", "2", "你好"]) == "👋", "第一候选是表情时照用（用户看到的就是它）")

    var p = Profile(name: "x", preset: "DeepSeek", wire: .openAI, baseURL: "https://api.deepseek.com", model: "m", instruction: "i", extraJSON: "")
    let b = body(try fastRequest(p, apiKey: "k", text: "你好"))
    check(b["max_tokens"] as? Int == 60 && b["temperature"] as? Double == 0, "输入提示请求限制输出长度、温度 0")
    check((b["thinking"] as? [String: String]) == ["type": "disabled"], "DeepSeek：关闭思考（实测：开着思考时 60 token 全被思考用掉，正文为空）")
    p.extraJSON = #"{"max_tokens":200}"#
    check(body(try fastRequest(p, apiKey: "k", text: "你好"))["max_tokens"] as? Int == 200, "用户的额外 JSON 仍可覆盖")

    let qwen = Profile(name: "x", preset: "百炼", wire: .openAI, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "m", instruction: "i", extraJSON: "")
    check(body(try fastRequest(qwen, apiKey: "k", text: "t"))["enable_thinking"] as? Bool == false, "百炼：enable_thinking=false")
    let other = Profile(name: "x", preset: "自定义", wire: .openAI, baseURL: "https://example.com/v1", model: "m", instruction: "i", extraJSON: "")
    let ob = body(try fastRequest(other, apiKey: "k", text: "t"))
    check(ob["max_tokens"] == nil && ob["thinking"] == nil && ob["temperature"] as? Double == 0, "未知服务：不限长、不发方言参数（防推理模型空结果 / 报错），只设温度 0")
    let claude = Profile(name: "x", preset: "Anthropic", wire: .anthropic, baseURL: "https://api.anthropic.com", model: "m", instruction: "i", extraJSON: "")
    let cb = body(try fastRequest(claude, apiKey: "k", text: "t"))
    check(cb["max_tokens"] as? Int == 60 && cb["thinking"] == nil, "Anthropic：默认不思考，直接限长")
    check(translateInstruction.contains("<text>") && !translateInstruction.contains("JSON"), "翻译指令只要译文，不要 JSON")
}

// MARK: ⌥P 润色也默认关闭思考（实测 deepseek-flash 首字 1243ms → 633ms）

do {
    let ds = Profile(name: "x", preset: "DeepSeek", wire: .openAI, baseURL: "https://api.deepseek.com", model: "m", instruction: "i", extraJSON: "")
    let b = body(try makeRequest(ds, apiKey: "k", text: "t"))
    check((b["thinking"] as? [String: String]) == ["type": "disabled"] && b["max_tokens"] == nil, "润色：DeepSeek 关闭思考，但不限长（润色结果可能很长）")
    var keep = ds
    keep.extraJSON = #"{"thinking":{"type":"enabled"}}"#
    check((body(try makeRequest(keep, apiKey: "k", text: "t"))["thinking"] as? [String: String]) == ["type": "enabled"], "润色：用户可用额外 JSON 打开思考")
    let other = Profile(name: "x", preset: "自定义", wire: .openAI, baseURL: "https://example.com/v1", model: "m", instruction: "i", extraJSON: "")
    let ob = body(try makeRequest(other, apiKey: "k", text: "t"))
    check(ob["thinking"] == nil && ob["enable_thinking"] == nil, "润色：未知服务不发方言参数")
}

// MARK: 切换候选时跟随高亮（实测微信输入法：→ +1，← −1；↓ 展开多行面板、= 改分词，无法推算）

do {
    let texts = ["candidate shortcut icon", "1", "你好", "2", "👋", "3", "泥嚎", "4", "几号"]
    check(candidateList(texts) == ["你好", "👋", "泥嚎", "几号"], "按序号取出当前页候选列表")
    check(candidateList(["你好", "泥嚎"]) == ["你好", "泥嚎"], "没有序号时取含汉字的文本")

    var b = PinyinBuffer()
    for c in "nihao" { b.feed(.letter(c)) }
    check(b.highlight == 0, "打字后高亮在第 1 个")
    b.feed(.candidateNext); b.feed(.candidateNext)
    check(b.highlight == 2 && b.text == "nihao", "→ 两次：高亮第 3 个，拼音不变")
    b.feed(.candidatePrev)
    check(b.highlight == 1, "← 一次：回到第 2 个")
    b.feed(.candidatePrev); b.feed(.candidatePrev)
    check(b.highlight == 0, "不会小于第 1 个")
    b.feed(.candidateNext)
    b.feed(.letter("a"))
    check(b.highlight == 0, "再打字：输入法重新排候选，高亮回到第 1 个")
    b.feed(.candidateNext)
    b.feed(.backspace)
    check(b.highlight == 0, "退格同样回到第 1 个")
    b.feed(.other)
    check(b.text.isEmpty && b.highlight == 0, "其他键结束输入")
}

// MARK: macOS 本地词典（牛津英汉汉英词典）释义取首个英文义项；样例为真实 DCSCopyTextDefinition 输出

do {
    let cases: [(String, String?)] = [
        ("电脑 diànnǎo noun computer▸ 个人电脑 personal computer (PC) ▸ 电脑程序 computer program", "computer"),
        ("苹果 pínɡɡuǒ noun apple ", "apple"),
        ("中国 Zhōnɡɡuó noun China▸ 中国人 Chinese", "China"),
        ("世界 shìjiè noun ① （一切事物） world▸ 创造新世界 create a new world ② ［Buddhism］ universe", "world"),
        ("我 wǒ pronoun ① （指一人） （用作主语） I; （用作宾语） me; （表所属关系） my▸ 告诉我 tell me", "I"),
        ("好 hǎo A. adjective ① （令人满意） good▸ 好地方 nice place", "good"),
        ("再见 zàijiàn verb polite expression goodbye ", "goodbye"),
        ("输入法 shūrùfǎ noun ［Computing］ input method ", "input method"),
        ("人工智能 rénɡōnɡ zhìnénɡ noun ［Computing］ artificial intelligence (AI)▸ 人工智能语言 artificial intelligence language", "artificial intelligence"),
        ("因为 yīnwèi A. preposition because of▸ 他因为… B. conjunction because▸", "because of"),
        ("一下 yīxià A. numeral-classifier compound [used after a verb as its complement, indicating an act or an attempt] once▸ 看一下 have a look", "once"),
        ("是 shì A. pronoun ① literary （这） this, that▸ 是日 that day", "this"),
        ("学习 xuéxí verb ① （获取知识技能） study▸ 学习文化 learn to read and write", "study"),
        ("世界 shìjiè ①名 佛教指无限的时间和空间。大千世界", nil),
        ("", nil),
    ]
    for (def, want) in cases {
        check(dictionaryGloss(def) == want, "词典释义 → \(want ?? "nil")（实际 \(dictionaryGloss(def) ?? "nil")）")
    }
}

// MARK: 提示面板避开输入行，靠边时留在屏幕内

do {
    let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
    let size = CGSize(width: 420, height: 90)
    for anchor in [CGRect(x: 200, y: 300, width: 1, height: 22),
                   CGRect(x: 790, y: 570, width: 1, height: 22),
                   CGRect(x: 0, y: 2, width: 1, height: 22)] {
        let frame = typingHintFrame(size: size, anchor: anchor, visibleFrame: screen)
        check(frame != nil && screen.contains(frame!) && !frame!.intersects(anchor), "提示避开输入行且不超出屏幕：\(anchor)")
        if let frame {
            check(frame.minY >= anchor.maxY + 16 || frame.maxY <= anchor.minY - 16, "提示与输入区域至少间隔 16pt")
        }
    }
    check(typingHintFrame(size: size, anchor: screen, visibleFrame: screen) == nil, "上下都放不下时不覆盖输入区域")
}

// MARK: 英文词性标注：只标注单词，保留原始字符串范围

do {
    let text = "The curious cat eats fresh apples quickly."
    let tags = englishWordTags(text)
    let words = tags.map { String(text[$0.range]) }
    check(words == ["The", "curious", "cat", "eats", "fresh", "apples", "quickly"], "词性标注保留单词范围，不包含标点和空白")
    check(tags.first { String(text[$0.range]) == "cat" }?.tag == .noun, "cat 标注为名词")
    check(tags.first { String(text[$0.range]) == "eats" }?.tag == .verb, "eats 标注为动词")
    check(tags.first { String(text[$0.range]) == "quickly" }?.tag == .adverb, "quickly 标注为副词")
    check(englishWordTags("").isEmpty && englishWordTags("... 🙂").isEmpty, "空串、标点和表情不产生词性标签")
}

// MARK: 终端一键安装 / 卸载：~/.zshrc 中的标记块

do {
    let user = "export PATH=/x:$PATH\nalias ll='ls -l'\n"
    let a = RcBlock.install(user, id: "zsh", body: "bindkey A")
    check(a.hasPrefix(user) && RcBlock.has(a, id: "zsh") && a.contains("bindkey A"), "安装：追加到末尾，原内容不动")
    check(RcBlock.remove(a, id: "zsh") == user, "卸载：恢复成安装前一字不差")
    let b = RcBlock.install(a, id: "claude", body: "alias claude=x")
    check(RcBlock.remove(RcBlock.remove(b, id: "zsh"), id: "claude") == user, "多块各自卸载，互不影响")
    check(RcBlock.has(RcBlock.remove(b, id: "zsh"), id: "claude"), "卸 zsh 不碰 claude 块")
    let re = RcBlock.install(b, id: "zsh", body: "bindkey B")
    check(!re.contains("bindkey A") && re.contains("bindkey B") && re.components(separatedBy: "# >>> polish zsh >>>").count == 2, "重复安装：替换旧块（如 app 换了位置），不重复追加")
    check(RcBlock.install("", id: "zsh", body: "x") == "# >>> polish zsh >>>\nx\n# <<< polish zsh <<<\n", "空文件也能装")
    check(RcBlock.install("abc", id: "zsh", body: "x").hasPrefix("abc\n\n# >>>"), "原文件末尾没换行时补上")
    let broken = user + "# >>> polish zsh >>>\nmine\n"
    check(RcBlock.remove(broken, id: "zsh") == broken && !RcBlock.has(broken, id: "zsh"), "只有开始标记（被手改坏）：不删任何内容")
    check(RcBlock.remove(user, id: "zsh") == user, "没装过时卸载：原样")
    // 回归：三块都装好后，非最后一块不能被判成「需更新」（之前用「重装后是否变化」判断，块会被挪到末尾）
    let three = RcBlock.install(RcBlock.install(RcBlock.install(user, id: "claude", body: "C"), id: "codex", body: "X"), id: "zsh", body: "Z")
    check(RcBlock.body(three, id: "claude") == "C" && RcBlock.body(three, id: "codex") == "X" && RcBlock.body(three, id: "zsh") == "Z", "按内容判断是否最新，与位置无关")
    check(RcBlock.body(user, id: "claude") == nil, "没装过：无内容")
    let upd = RcBlock.install(three, id: "claude", body: "C2")
    check(upd == three.replacingOccurrences(of: "\nC\n", with: "\nC2\n"), "更新：原地替换，不挪位置")
    check(RcBlock.install(three, id: "codex", body: "X") == three, "内容相同再装：文件不变")
    check(RcBlock.body(RcBlock.install(user, id: "zsh", body: "a\nb"), id: "zsh") == "a\nb", "多行内容原样取回")
}

// MARK: 整句翻译：解析、着色区间、请求参数

do {
    let t = parseSentence(#"```json\n{"zh":"你好，世界。","en":"Hello, World.","pairs":[["你好","Hello"],["世界","World"]]}\n```"#)
    check(t == SentenceTranslation(zh: "你好，世界。", en: "Hello, World.", pairs: [SentencePair(zh: "你好", en: "Hello"), SentencePair(zh: "世界", en: "World")]), "解析整句译文与词对应")
    check(parseSentence(#"{"en":"Hi","pairs":"bad"}"#) == SentenceTranslation(en: "Hi", pairs: []), "pairs 格式不对：只保留译文")
    check(parseSentence(#"{"en":"Hi","zh":""}"#)?.zh == nil, "zh 为空当作没给")
    check(hasPinyin("你好shijie。") && !hasPinyin("你好，世界。") && !hasPinyin("１２"), "识别句中残留的拼音")
    check(parseSentence(#"{"pairs":[]}"#) == nil && parseSentence("no") == nil, "缺译文返回 nil")

    func spans(_ text: String, _ parts: [String], _ whole: Bool) -> [String] {
        colorRanges(text, parts, wholeWords: whole).map { "\(text[$0.range])#\($0.index)" }
    }
    check(spans("你好，世界。", ["你好", "世界"], false) == ["你好#0", "世界#1"], "中文按词着色")
    check(spans("Hello, World.", ["world", "hello"], true) == ["Hello#1", "World#0"], "英文语序不同、大小写不同也能对上，按位置排序")
    check(spans("It is I", ["I"], true) == ["I#0"] && spans("It is I", ["I"], true).count == 1, "整词匹配：I 不命中 It")
    check(spans("好好", ["好", "好"], false) == ["好#0", "好#1"], "重复词依次占用不同位置")
    check(spans("abc", ["x", ""], true).isEmpty, "找不到或空的不着色")

    let ds = Profile(name: "d", preset: "DeepSeek", wire: .openAI, baseURL: "https://api.deepseek.com", model: "deepseek-chat", instruction: "润色", extraJSON: "")
    let sp = sentenceProfile(ds)
    check(sp.instruction == sentenceInstruction, "整句用整句指令")
    if !fastOverrides(ds).isEmpty, fastOverrides(ds)["max_tokens"] != nil {
        check(body(try! fastRequest(sp, apiKey: "k", text: "你好"))["max_tokens"] as? Int == 400, "限长服务整句放宽到 400")
    }
    var mine = ds; mine.extraJSON = #"{"max_tokens":99}"#
    check(body(try! fastRequest(sentenceProfile(mine), apiKey: "k", text: "x"))["max_tokens"] as? Int == 99, "用户自定义 max_tokens 优先")
    check(chinesePunctuation[","] == "，" && chinesePunctuation["."] == "。", "中文标点映射")
}

print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
