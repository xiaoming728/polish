import Foundation

/// polish-edit 与 app 之间的帧：一行头部（"EDIT n" / "OK n" / "NO" / "CANCEL"），后跟 n 字节正文。
public enum EditMessage: Equatable, Sendable {
    case edit(Data)
    case ok(Data)
    case no
    case cancel
}

public struct FrameError: Error {}

public func encode(_ m: EditMessage) -> Data {
    switch m {
    case .edit(let body): return Data("EDIT \(body.count)\n".utf8) + body
    case .ok(let body): return Data("OK \(body.count)\n".utf8) + body
    case .no: return Data("NO\n".utf8)
    case .cancel: return Data("CANCEL\n".utf8)
    }
}

/// 增量解帧：append 收到的字节，反复 next() 取出完整帧；数据不足返回 nil，格式错误抛错。
public struct FrameReader {
    var buf = Data()
    public init() {}

    public mutating func append(_ d: Data) { buf.append(d) }

    public mutating func next() throws -> EditMessage? {
        guard let nl = buf.firstIndex(of: 10) else { return nil }
        let header = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
        let rest = buf.index(after: nl)
        if header == "NO" || header == "CANCEL" {
            buf = Data(buf[rest...])
            return header == "NO" ? .no : .cancel
        }
        let parts = header.split(separator: " ")
        guard parts.count == 2, ["EDIT", "OK"].contains(parts[0]), let n = Int(parts[1]), n >= 0 else { throw FrameError() }
        guard buf.distance(from: rest, to: buf.endIndex) >= n else { return nil }
        let end = buf.index(rest, offsetBy: n)
        let body = Data(buf[rest..<end])
        buf = Data(buf[end...])
        return parts[0] == "EDIT" ? .edit(body) : .ok(body)
    }
}

/// 未被 app 接手时交给原编辑器：POLISH_FALLBACK_EDITOR → 非 polish-edit 的 VISUAL → EDITOR → vi
public func fallbackEditor(env: [String: String]) -> String {
    let visual = env["VISUAL"].flatMap { $0.contains("polish-edit") ? nil : $0 }
    return [env["POLISH_FALLBACK_EDITOR"], visual, env["EDITOR"]].compactMap { $0 }.first { !$0.isEmpty } ?? "vi"
}
