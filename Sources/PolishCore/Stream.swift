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
    case done
    case failure(String)
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
            guard let s = delta?["content"] as? String, !s.isEmpty else { return nil }
            return .text(s)
        case .anthropic:
            switch obj["type"] as? String {
            case "content_block_delta":
                let delta = obj["delta"] as? [String: Any]
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
