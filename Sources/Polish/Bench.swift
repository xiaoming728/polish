import Foundation
import PolishCore

/// 开发用：Polish --bench。用当前配置（Key 取自本地 keys.json，不打印）对输入提示的几种请求方式做消融计时。
/// 每种方式跑 4 次：第 1 次新建连接（冷），后 3 次复用连接（热）；记录首字时间与总耗时。
enum Bench {
    static let polishSample = "帮我看下这个接口为啥慢 好像是数据库的问题 但是我不确定 你帮我分析下然后给出优化方案 要考虑到并发的情况"

    struct Variant {
        let name: String
        let instruction: String
        let input: String
        let extra: String
        var fast = false
    }

    static func run() async {
        let state = await MainActor.run { AppState() }
        let base = await MainActor.run { state.current }
        let key = KeyStore.apiKey(base)
        guard !key.isEmpty else { print("当前配置没有 API Key"); exit(1) }
        print("配置：\(base.preset) / \(base.model)\n")
        let on = #"{"thinking":{"type":"enabled"}}"#
        let variants = [
            Variant(name: "B0 改前：拼音→{en,zh}，思考开", instruction: typingInstruction(.english), input: "nihaoshijie", extra: on),
            Variant(name: "B1 拼音→{en,zh}，关思考 + 限长", instruction: typingInstruction(.english), input: "nihaoshijie", extra: "", fast: true),
            Variant(name: "B2 App 路径：候选词→英文，关思考 + 限长", instruction: translateInstruction(.english), input: "你好世界", extra: "", fast: true),
            Variant(name: "P0 ⌥P 润色改前：思考开", instruction: defaultInstruction, input: polishSample, extra: on),
            Variant(name: "P1 ⌥P 润色现在：默认关思考", instruction: defaultInstruction, input: polishSample, extra: ""),
        ]
        // 交错测量：每轮各跑一次，共 8 轮（第 1 轮为冷连接），把网络波动平均分摊到各组
        var rows = Array(repeating: [(ttft: Double, total: Double)](), count: variants.count)
        var samples = Array(repeating: "", count: variants.count)
        for _ in 0..<8 {
            for (i, v) in variants.enumerated() {
                var p = base
                p.instruction = v.instruction
                p.extraJSON = v.extra
                let t0 = Date()
                var first: Double?
                do {
                    let out = try await Polisher.stream(p, apiKey: key, text: v.input, fast: v.fast) { _ in
                        if first == nil { first = Date().timeIntervalSince(t0) * 1000 }
                    }
                    rows[i].append((first ?? 0, Date().timeIntervalSince(t0) * 1000))
                    samples[i] = out.replacingOccurrences(of: "\n", with: " ")
                } catch {
                    samples[i] = "错误：\(error.localizedDescription)"
                }
            }
        }
        func f(_ x: Double) -> String { String(format: "%5.0f", x) }
        func mid(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        for (i, v) in variants.enumerated() {
            let warm = rows[i].dropFirst()
            print("\(v.name)\n  热连接 n=\(warm.count)：首字中位 \(f(mid(warm.map(\.ttft))))ms  总耗时中位 \(f(mid(warm.map(\.total))))ms  最快 \(f(warm.map(\.total).min() ?? 0))ms  最慢 \(f(warm.map(\.total).max() ?? 0))ms\n  输出：\(samples[i].prefix(70))")
        }
        exit(0)
    }
}
