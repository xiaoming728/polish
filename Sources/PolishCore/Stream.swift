import Foundation

public enum Wire: String, Codable, CaseIterable, Sendable {
    case openAI, anthropic
}

/// 整理模型输出：去首尾空白与 <text> / <text lang="…"> 包裹；原文以换行结尾（zsh 草稿）时补回换行。
public func finalize(_ result: String, original: String) -> String {
    var s = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("<text>") || s.hasPrefix("<text "), s.hasSuffix("</text>"), let open = s.firstIndex(of: ">") {
        s = String(s[s.index(after: open)...].dropLast(7)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return original.hasSuffix("\n") ? s + "\n" : s
}

public enum StreamEvent: Equatable, Sendable {
    case text(String)
    case reasoning // 独立字段里的推理分片：不显示，只用来在没有正文时说明原因
    case done
    case failure(String)
}

/// 去掉正文开头内联的推理块 <think>…</think>（Ollama / LM Studio / vLLM 未开推理解析、MiniMax 等把推理写进 content）。
/// 流式时推理还没结束（含标签只到一半）返回空，正文开始后才有内容
public func stripThinking(_ raw: String) -> String {
    let s = raw.drop { $0.isWhitespace }
    let open = "<think>"
    if s.count < open.count { return open.hasPrefix(s) && !s.isEmpty ? "" : raw }
    guard s.hasPrefix(open) else { return raw }
    guard let end = s.range(of: "</think>") else { return "" }
    return String(s[end.upperBound...].drop { $0.isWhitespace })
}

/// 逐行解码 SSE。URLSession 的 `lines` 会丢掉空行，所以不依赖空行分帧：
/// 只看 `data:` 行，Anthropic 的事件类型从 JSON 的 `type` 字段读取。
public struct StreamDecoder {
    public let wire: Wire
    public init(wire: Wire) { self.wire = wire }

    public mutating func feed(line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil } // event: / 注释 / 其他
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return nil }
        if let err = obj["error"] as? [String: Any] {
            return .failure(err["message"] as? String ?? "\(err)")
        }
        switch wire {
        case .openAI:
            let delta = ((obj["choices"] as? [[String: Any]])?.first?["delta"]) as? [String: Any]
            guard let s = delta?["content"] as? String, !s.isEmpty else {
                // DeepSeek / 百炼 / 硅基流动用 reasoning_content，OpenRouter / Ollama 用 reasoning
                let r = (delta?["reasoning_content"] as? String) ?? (delta?["reasoning"] as? String)
                return r?.isEmpty == false ? .reasoning : nil
            }
            return .text(s)
        case .anthropic:
            switch obj["type"] as? String {
            case "content_block_delta":
                let delta = obj["delta"] as? [String: Any]
                if delta?["type"] as? String == "thinking_delta" { return .reasoning }
                guard delta?["type"] as? String == "text_delta", let s = delta?["text"] as? String, !s.isEmpty else { return nil }
                return .text(s)
            case "message_stop":
                return .done
            default:
                return nil
            }
        }
    }
}
