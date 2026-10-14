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
        let translate = "把 <text> 中的中文译成自然、地道的英文。只输出译文。"
        let fast = #""max_tokens":60,"temperature":0"#
        let variants = [
            Variant(name: "V0 现状：拼音→{en,zh}", instruction: typingInstruction, input: "nihaoshijie", extra: ""),
            Variant(name: "V1 V0 + max_tokens/temperature", instruction: typingInstruction, input: "nihaoshijie", extra: "{\(fast)}"),
            Variant(name: "V2 V1 + 关闭思考", instruction: typingInstruction, input: "nihaoshijie", extra: #"{"#+fast+#","thinking":{"type":"disabled"}}"#),
            Variant(name: "V3 候选词→英文（短提示）", instruction: translate, input: "你好世界", extra: "{\(fast)}"),
            Variant(name: "V4 V3 + 关闭思考", instruction: translate, input: "你好世界", extra: #"{"#+fast+#","thinking":{"type":"disabled"}}"#),
            Variant(name: "V5 App 实际路径：候选词 + fastRequest", instruction: translateInstruction, input: "你好世界", extra: "", fast: true),
            Variant(name: "P0 ⌥P 润色：默认（思考开）", instruction: defaultInstruction, input: polishSample, extra: ""),
            Variant(name: "P1 ⌥P 润色：关闭思考", instruction: defaultInstruction, input: polishSample, extra: #"{"thinking":{"type":"disabled"}}"#),
        ]
        for v in variants {
            var p = base
            p.instruction = v.instruction
            p.extraJSON = v.extra
            var rows: [(ttft: Double, total: Double)] = []
            var sample = ""
            for _ in 0..<4 {
                let t0 = Date()
                var first: Double?
                do {
                    let out = try await Polisher.stream(p, apiKey: key, text: v.input, fast: v.fast) { _ in
                        if first == nil { first = Date().timeIntervalSince(t0) * 1000 }
                    }
                    rows.append((first ?? 0, Date().timeIntervalSince(t0) * 1000))
                    sample = out.replacingOccurrences(of: "\n", with: " ")
                } catch {
                    sample = "错误：\(error.localizedDescription)"
                    break
                }
            }
            func f(_ x: Double) -> String { String(format: "%5.0f", x) }
            if let cold = rows.first {
                let warm = rows.dropFirst()
                let ttft = warm.map(\.ttft).sorted(), total = warm.map(\.total).sorted()
                let mid = { (a: [Double]) in a.isEmpty ? 0 : a[a.count / 2] }
                print("\(v.name)\n  冷：首字 \(f(cold.ttft))ms 总 \(f(cold.total))ms   热（中位）：首字 \(f(mid(ttft)))ms 总 \(f(mid(total)))ms\n  输出：\(sample.prefix(80))")
            } else {
                print("\(v.name)\n  \(sample.prefix(120))")
            }
        }
        exit(0)
    }
}
