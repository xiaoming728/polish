import Foundation

/// ~/.zshrc 里由 Polish 管理的片段：用标记行包住，安装时替换同 id 的旧块，卸载时只删这一块，别的内容一字不动
public enum RcBlock {
    static func begin(_ id: String) -> String { "# >>> polish \(id) >>>" }
    static func end(_ id: String) -> String { "# <<< polish \(id) <<<" }

    public static func has(_ rc: String, id: String) -> Bool {
        range(rc.components(separatedBy: "\n"), id: id) != nil
    }

    public static func install(_ rc: String, id: String, body: String) -> String {
        var s = remove(rc, id: id)
        if !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
        if !s.isEmpty { s += "\n" }
        return s + [begin(id), body, end(id)].joined(separator: "\n") + "\n"
    }

    public static func remove(_ rc: String, id: String) -> String {
        var lines = rc.components(separatedBy: "\n")
        guard let r = range(lines, id: id) else { return rc }
        // 连同安装时补的那一行空行一起删
        let lower = r.lowerBound > 0 && lines[r.lowerBound - 1].isEmpty ? r.lowerBound - 1 : r.lowerBound
        lines.removeSubrange(lower...r.upperBound)
        return lines.joined(separator: "\n")
    }

    /// 只认成对的标记；只有开始没有结束（被手改坏）时不动，免得删掉用户自己的内容
    static func range(_ lines: [String], id: String) -> ClosedRange<Int>? {
        guard let a = lines.firstIndex(of: begin(id)),
              let b = lines[a...].firstIndex(of: end(id)) else { return nil }
        return a...b
    }
}
