import Foundation

/// ~/.zshrc 里由 Polish 管理的片段：用标记行包住，安装时替换同 id 的旧块，卸载时只删这一块，别的内容一字不动
public enum RcBlock {
    static func begin(_ id: String) -> String { "# >>> polish \(id) >>>" }
    static func end(_ id: String) -> String { "# <<< polish \(id) <<<" }

    public static func has(_ rc: String, id: String) -> Bool { body(rc, id: id) != nil }

    /// 已安装块的内容（不含标记行）；用来判断是否需要更新，与块在文件中的位置无关
    public static func body(_ rc: String, id: String) -> String? {
        let lines = rc.components(separatedBy: "\n")
        guard let r = range(lines, id: id) else { return nil }
        return lines[(r.lowerBound + 1)..<r.upperBound].joined(separator: "\n")
    }

    /// 已装过就原地替换（不挪位置），没装过追加到末尾
    public static func install(_ rc: String, id: String, body: String) -> String {
        let block = [begin(id), body, end(id)]
        var lines = rc.components(separatedBy: "\n")
        if let r = range(lines, id: id) {
            lines.replaceSubrange(r, with: block)
            return lines.joined(separator: "\n")
        }
        var s = rc
        if !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
        if !s.isEmpty { s += "\n" }
        return s + block.joined(separator: "\n") + "\n"
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
