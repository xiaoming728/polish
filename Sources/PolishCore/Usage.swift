import Foundation

// 使用统计：每天一个汇总文件 usage/YYYY-MM-DD.json，只有次数、耗时直方图、bundle id、配置名，不含任何正文。
// 不保存逐条事件：够回答「哪些功能在用、采纳率、哪里失败或慢」，又不会积累可还原使用轨迹的明细。

public enum PolishOutcome: String, CaseIterable {
    case accepted, copied, cancelled, dismissed, failed
    case verifyFailed = "verify_failed"
}

public enum HintOutcome: String {
    case shown
    case chosenEn = "chosen_en"
    case chosenZh = "chosen_zh"
}

public enum Latency: String {
    case polishFirst = "polish_first", polishTotal = "polish_total", hintFirst = "hint_first"
}

/// 一天（或合并后多天）的汇总。polish / hint 的键是用 | 连接的字段，字段里的 % 和 | 先做百分号转义
public struct UsageDay: Codable, Equatable {
    public var polish: [String: Int] = [:]
    public var hint: [String: Int] = [:]
    public var lat: [String: [Int]] = [:]
    public init() {}

    public static let buckets = 50 // 100ms 一档；最后一档是 4.9s 及以上

    public static func key(_ fields: [String]) -> String {
        fields.map { $0.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "|", with: "%7C") }.joined(separator: "|")
    }

    public static func fields(_ key: String) -> [String] {
        key.split(separator: "|", omittingEmptySubsequences: false).map { String($0).removingPercentEncoding ?? String($0) }
    }

    public static func bucket(ms: Int) -> Int { min(max(ms, 0) / 100, buckets - 1) }

    public mutating func addPolish(profile: String, bundle: String, origin: String, _ o: PolishOutcome) {
        polish[Self.key([profile, bundle, origin, o.rawValue]), default: 0] += 1
    }

    public mutating func addHint(bundle: String, _ o: HintOutcome) {
        hint[Self.key([bundle, o.rawValue]), default: 0] += 1
    }

    public mutating func addLatency(_ l: Latency, ms: Int) {
        var h = lat[l.rawValue] ?? []
        if h.count < Self.buckets { h += Array(repeating: 0, count: Self.buckets - h.count) }
        h[Self.bucket(ms: ms)] += 1
        lat[l.rawValue] = h
    }

    public mutating func merge(_ o: UsageDay) {
        polish.merge(o.polish, uniquingKeysWith: +)
        hint.merge(o.hint, uniquingKeysWith: +)
        for (k, h) in o.lat {
            var a = lat[k] ?? []
            if a.count < h.count { a += Array(repeating: 0, count: h.count - a.count) }
            for (i, n) in h.enumerated() { a[i] += n }
            lat[k] = a
        }
    }

    /// 润色次数；给了结局就只数这一种
    public func polishCount(_ o: PolishOutcome? = nil) -> Int {
        polish.reduce(0) { n, kv in o == nil || Self.fields(kv.key).last == o?.rawValue ? n + kv.value : n }
    }

    public var isEmpty: Bool { polish.isEmpty && hint.isEmpty && lat.values.allSatisfy { $0.allSatisfy { $0 == 0 } } }

    /// 直方图中位数所在的档（偶数个样本取中间两个的平均档位，可能是 .5）；没有样本为 nil
    public static func median(_ h: [Int]) -> Double? {
        let n = h.reduce(0, +)
        guard n > 0 else { return nil }
        func at(_ rank: Int) -> Int { // 第 rank 个样本（从 1 起）所在档
            var seen = 0
            for (i, c) in h.enumerated() {
                seen += c
                if seen >= rank { return i }
            }
            return h.count - 1
        }
        return Double(at((n + 1) / 2) + at(n / 2 + 1)) / 2
    }

    /// 本地时区的日期键 YYYY-MM-DD
    public static func dayKey(_ d: Date, _ tz: TimeZone = .current) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        let x = c.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", x.year!, x.month!, x.day!)
    }

    /// 合并目录里日期在 [from, to]（首尾都含，前后颠倒时交换；nil 表示不限）的文件；坏文件跳过。
    /// days：实际读到的日期，升序；daily：与 days 一一对应的当天汇总
    public static func load(dir: URL, from: String?, to: String?) -> (total: UsageDay, days: [String], daily: [UsageDay]) {
        var lo = from, hi = to
        if let a = lo, let b = hi, a > b { (lo, hi) = (b, a) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var total = UsageDay(), days: [String] = [], daily: [UsageDay] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let day = String(name.dropLast(5))
            guard day.count == 10, lo.map({ day >= $0 }) ?? true, hi.map({ day <= $0 }) ?? true,
                  let data = FileManager.default.contents(atPath: dir.appendingPathComponent(name).path),
                  let d = try? JSONDecoder().decode(UsageDay.self, from: data) else { continue }
            total.merge(d)
            days.append(day)
            daily.append(d)
        }
        return (total, days, daily)
    }
}

/// 当天汇总放内存，有变化后最多 5 秒合并写一次；跨过午夜换新文件。写入失败直接忽略
@MainActor
public final class UsageStore {
    public static let shared = UsageStore(dir: Paths.support.appendingPathComponent("usage"))

    public let dir: URL
    private var day = ""
    private var data = UsageDay()
    private var dirty = false
    private var scheduled = false

    public init(dir: URL) { self.dir = dir }

    public func polish(profile: String, bundle: String, origin: String, _ o: PolishOutcome) {
        update { $0.addPolish(profile: profile, bundle: bundle, origin: origin, o) }
    }

    public func hint(bundle: String, _ o: HintOutcome) { update { $0.addHint(bundle: bundle, o) } }

    public func latency(_ l: Latency, ms: Int) { update { $0.addLatency(l, ms: ms) } }

    private func update(_ change: (inout UsageDay) -> Void) {
        let today = UsageDay.dayKey(Date())
        if today != day {
            flush() // 前一天的剩余写进前一天的文件
            day = today
            // 同一天重启过：接着已有文件累加（坏文件当作空）
            data = FileManager.default.contents(atPath: file(today).path).flatMap { try? JSONDecoder().decode(UsageDay.self, from: $0) } ?? UsageDay()
        }
        change(&data)
        dirty = true
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.flush()
            }
        }
    }

    private func file(_ day: String) -> URL { dir.appendingPathComponent("\(day).json") }

    public func flush() {
        guard dirty else { return }
        dirty = false
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil,
              let bytes = try? enc.encode(data) else { return }
        // 与 keys.json 相同：先以 0600 建临时文件再原子改名
        let url = file(day), tmp = url.appendingPathExtension("tmp")
        unlink(tmp.path)
        if FileManager.default.createFile(atPath: tmp.path, contents: bytes, attributes: [.posixPermissions: 0o600]) {
            rename(tmp.path, url.path)
        }
    }

    /// 清空统计：删除整个目录和内存中的当天汇总
    public func clear() {
        data = UsageDay()
        dirty = false
        try? FileManager.default.removeItem(at: dir)
    }
}
