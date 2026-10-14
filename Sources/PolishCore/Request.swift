import Foundation

public struct Profile: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var preset: String
    public var wire: Wire
    public var baseURL: String
    public var model: String
    public var instruction: String
    public var extraJSON: String

    public init(id: UUID = UUID(), name: String, preset: String, wire: Wire, baseURL: String, model: String, instruction: String, extraJSON: String) {
        self.id = id
        self.name = name
        self.preset = preset
        self.wire = wire
        self.baseURL = baseURL
        self.model = model
        self.instruction = instruction
        self.extraJSON = extraJSON
    }
}

public enum RequestError: Error, Equatable {
    case badURL
    case badExtraJSON(String)
}

func endpoint(_ p: Profile, _ path: String) throws -> URL {
    var base = p.baseURL.trimmingCharacters(in: .whitespaces)
    while base.hasSuffix("/") { base.removeLast() }
    guard let url = URL(string: base + path), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
        throw RequestError.badURL
    }
    return url
}

func authorize(_ r: inout URLRequest, _ p: Profile, _ apiKey: String) {
    switch p.wire {
    case .openAI:
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    case .anthropic:
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }
}

/// 关闭思考的方言参数，只对已知服务发送（未知服务乱发会报错）。
/// 润色和输入提示都不需要推理；实测 deepseek-flash 润色首字 1243ms → 633ms。用户可用「额外请求体 JSON」重新打开
public func noThinking(_ p: Profile) -> [String: Any] {
    let host = URL(string: p.baseURL.trimmingCharacters(in: .whitespaces))?.host ?? ""
    if host.hasSuffix("deepseek.com") { return ["thinking": ["type": "disabled"]] }
    if host.contains("dashscope") { return ["enable_thinking": false] }
    return [:]
}

/// 草稿主体语言，标在 <text lang> 上：只靠指令说「用原文语言」时，中文指令下的英文草稿常被译成中文（反之亦然）。
/// NLLanguageRecognizer 会把夹英文术语的中文判成 en，所以按字符计数：一个汉字约抵 3 个字母
public func draftLanguage(_ text: String) -> String? {
    var han = 0, latin = 0, other = 0
    for u in text.unicodeScalars where u.properties.isAlphabetic {
        if u.properties.isIdeographic { han += 1 } else if u.isASCII { latin += 1 } else { other += 1 }
    }
    if han > other && han * 3 >= latin { return "zh" }
    // shortcut: 纯 ASCII 字母一律算英文（不带重音的法语等会误标），有中英以外的用户时再细分
    return han + other == 0 && latin > 0 ? "en" : nil
}

/// 润色请求：指令作 system，原文包在 <text> 中声明为待润色文本；额外 JSON 按顶层键覆盖默认值。
/// tagLanguage：在 <text> 上标主体语言（输入提示不需要，拼音会被误标成 en）
public func makeRequest(_ p: Profile, apiKey: String, text: String, tagLanguage: Bool = true) throws -> URLRequest {
    let lang = tagLanguage ? draftLanguage(text).map { " lang=\"\($0)\"" } ?? "" : ""
    let user = ["role": "user", "content": "<text\(lang)>\n\(text)\n</text>"]
    var body: [String: Any] = ["model": p.model, "stream": true]
    switch p.wire {
    case .openAI:
        body["messages"] = [["role": "system", "content": p.instruction], user]
    case .anthropic:
        body["system"] = p.instruction
        body["messages"] = [user]
        body["max_tokens"] = 4096
    }
    body.merge(noThinking(p)) { _, new in new }
    let extra = p.extraJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    if !extra.isEmpty {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(extra.utf8))) as? [String: Any] else {
            throw RequestError.badExtraJSON("额外请求体必须是 JSON 对象")
        }
        body.merge(obj) { _, new in new }
    }
    var r = URLRequest(url: try endpoint(p, p.wire == .openAI ? "/chat/completions" : "/v1/messages"))
    r.httpMethod = "POST"
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    authorize(&r, p, apiKey)
    r.httpBody = try JSONSerialization.data(withJSONObject: body)
    return r
}

public func makeModelsRequest(_ p: Profile, apiKey: String) throws -> URLRequest {
    var r = URLRequest(url: try endpoint(p, p.wire == .openAI ? "/models" : "/v1/models?limit=1000"))
    r.httpMethod = "GET"
    authorize(&r, p, apiKey)
    return r
}

/// `/models` 只作候选：取 data[].id，失败返回空（调用方降级为手填）。
public func parseModels(_ data: Data) -> [String] {
    let list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [[String: Any]] ?? []
    return list.compactMap { $0["id"] as? String }.sorted()
}
