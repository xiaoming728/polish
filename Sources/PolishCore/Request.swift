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

/// 润色请求：指令作 system，原文包在 <text> 中声明为待润色文本；额外 JSON 按顶层键覆盖默认值。
public func makeRequest(_ p: Profile, apiKey: String, text: String) throws -> URLRequest {
    let user = ["role": "user", "content": "<text>\n\(text)\n</text>"]
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
