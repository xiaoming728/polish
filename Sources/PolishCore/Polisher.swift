import Foundation

/// 看门狗与流之间共享的超时状态（只在主线程读写）
final class Watch: @unchecked Sendable {
    var gotFirst = false
    var reason: String?
}

public struct PolishError: LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// 单个流式润色请求。首字（无数据）超时 30s，总计 120s；不自动重试。
@MainActor
public final class Polisher {
    public init() {}
    private var task: Task<Void, Never>?
    private var generation = 0
    public var busy: Bool { task != nil }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    public func start(_ p: Profile, apiKey: String, text: String, fast: Bool = false,
               onDelta: @escaping (String) -> Void, onDone: @escaping (Result<String, Error>) -> Void) {
        cancel()
        generation += 1
        let gen = generation
        let watch = Watch()
        task = Task { [weak self] in
            // 首字 30s 按「收到第一段正文」计，不受 SSE 保活注释行影响；总计 120s
            let dog = Task {
                let begin = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let t = Date().timeIntervalSince(begin)
                    if !watch.gotFirst && t > 30 { watch.reason = "超时：30 秒内没有收到模型的第一个字。原文未改动。" }
                    if t > 120 { watch.reason = "超时：超过 120 秒仍未完成。原文未改动。" }
                    if watch.reason != nil, !Task.isCancelled { self?.task?.cancel(); return }
                }
            }
            defer { dog.cancel() }
            do {
                let out = try await Self.stream(p, apiKey: apiKey, text: text, fast: fast) { s in
                    watch.gotFirst = true
                    guard self?.generation == gen else { return } // 已被新请求取代：丢弃旧流的增量
                    onDelta(s)
                }
                guard !Task.isCancelled else { return }
                self?.task = nil
                onDone(.success(out))
            } catch {
                guard self?.generation == gen else { return } // 看门狗刚超时又被新请求取代：旧失败不能落到新请求头上
                if let reason = watch.reason {
                    self?.task = nil
                    onDone(.failure(PolishError(message: reason)))
                    return
                }
                guard !Task.isCancelled else { return } // 用户取消：不回调
                self?.task = nil
                onDone(.failure(Self.describe(error)))
            }
        }
    }

    public static func describe(_ error: Error) -> Error {
        guard let u = error as? URLError else { return error }
        switch u.code {
        case .timedOut: return PolishError(message: "超时：长时间没有收到模型数据。原文未改动。")
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost:
            return PolishError(message: "网络错误：\(u.localizedDescription)")
        default: return PolishError(message: u.localizedDescription)
        }
    }

    /// fast：输入提示这类短结果，用 fastRequest（限长、温度 0）
    public static func stream(_ p: Profile, apiKey: String, text: String, fast: Bool = false, onDelta: @escaping (String) -> Void) async throws -> String {
        var req = try fast ? fastRequest(p, apiKey: apiKey, text: text) : makeRequest(p, apiKey: apiKey, text: text)
        req.timeoutInterval = 120 // 空闲超时兜底；首字与总时长由 start() 的看门狗控制
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.utf8.count > 4096 { break }
            }
            throw PolishError(message: "HTTP \(status)：\(serverMessage(body))")
        }
        var decoder = StreamDecoder(wire: p.wire)
        var out = ""
        loop: for try await line in bytes.lines {
            switch decoder.feed(line: line) {
            case .text(let s)?:
                out += s
                await MainActor.run { onDelta(out) }
            case .done?:
                break loop
            case .failure(let m)?:
                throw PolishError(message: "模型返回错误：\(m)")
            case nil:
                continue
            }
        }
        guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PolishError(message: "模型没有返回内容。请检查模型名称或「额外请求体 JSON」。")
        }
        return out
    }

    static func serverMessage(_ body: String) -> String {
        if let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] {
            if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let m = obj["message"] as? String { return m }
            if let e = obj["error"] as? String { return e }
        }
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "（无响应内容）" : String(t.prefix(300))
    }

    public static func fetchModels(_ p: Profile, apiKey: String) async -> [String] {
        guard var req = try? makeModelsRequest(p, apiKey: apiKey) else { return [] }
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return [] }
        return parseModels(data)
    }
}
