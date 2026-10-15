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

/// 单个流式润色请求。首字（无数据）超时 30s，总计 120s；只在提速参数被 400 拒绝时重试一次（见 stream）。
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

    /// 输入提示（fast）的结果缓存：句中「本句 + 这个词」与上屏后的「本句」常是同一文本，退格重打、来回切候选也会重复
    static var cache: [String: String] = [:]
    /// 输入提示失败后的退避：配置错误 / 限流时每敲一个键就失败一次，同一连接 15s 内直接回上次的错误，不再请求
    static var backoff: [String: (until: Date, error: Error)] = [:]
    /// 本次运行里拒绝过提速参数、去掉后成功的连接：之后直接不带，免得每次先挨一个 400
    static var speedRejected: Set<String> = []

    /// 连接 + 请求方式：换服务商、模型或额外 JSON 都是新的键（退避随之解除）
    static func connection(_ p: Profile, fast: Bool) -> String {
        [p.wire.rawValue, p.baseURL, p.model, p.extraJSON, fast ? "fast" : "full"].joined(separator: "\u{1}")
    }

    public func start(_ p: Profile, apiKey: String, text: String, fast: Bool = false,
               onDelta: @escaping (String) -> Void, onDone: @escaping (Result<String, Error>) -> Void) {
        cancel()
        generation += 1
        let gen = generation
        let conn = Self.connection(p, fast: fast) + "\u{1}" + apiKey // 改了 Key 立即解除退避（只在内存里）
        let cacheKey = [conn, p.instruction, text].joined(separator: "\u{1}")
        if fast {
            if let hit = Self.cache[cacheKey] { return onDone(.success(hit)) }
            if let b = Self.backoff[conn], b.until > Date() { return onDone(.failure(b.error)) }
        }
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
                if fast {
                    // shortcut: 满了整个清空，不做 LRU；一天几千次输入提示，500 条足够命中重复
                    if Self.cache.count >= 500 { Self.cache.removeAll() }
                    Self.cache[cacheKey] = out
                    Self.backoff[conn] = nil
                }
                onDone(.success(out))
            } catch {
                guard self?.generation == gen else { return } // 看门狗刚超时又被新请求取代：旧失败不能落到新请求头上
                let failure: Error
                if let reason = watch.reason {
                    failure = PolishError(message: reason)
                } else {
                    guard !Task.isCancelled else { return } // 用户取消：不回调，也不算失败
                    failure = Self.describe(error)
                }
                self?.task = nil
                if fast { Self.backoff[conn] = (Date().addingTimeInterval(15), failure) }
                onDone(.failure(failure))
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
    /// speed：带提速参数；强制思考的模型以 400 拒绝时去掉提速参数重试一次（用户的额外 JSON 照常带上）
    public static func stream(_ p: Profile, apiKey: String, text: String, fast: Bool = false, speed: Bool = true, onDelta: @escaping (String) -> Void) async throws -> String {
        let conn = connection(p, fast: fast)
        let speed = speed && !speedRejected.contains(conn)
        var req = try fast ? fastRequest(p, apiKey: apiKey, text: text, speed: speed) : makeRequest(p, apiKey: apiKey, text: text, speed: speed)
        req.timeoutInterval = 120 // 空闲超时兜底；首字与总时长由 start() 的看门狗控制
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 && speed && (speedApplied(p) || (fast && !fastOverrides(p).isEmpty)) {
            let out = try await stream(p, apiKey: apiKey, text: text, fast: fast, speed: false, onDelta: onDelta)
            speedRejected.insert(conn) // 只在去掉后成功时记下：别的原因的 400 不能让之后的请求都丢掉关思考
            return out
        }
        guard (200..<300).contains(status) else {
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.utf8.count > 4096 { break }
            }
            throw PolishError(message: "HTTP \(status)：\(serverMessage(body))")
        }
        var decoder = StreamDecoder(wire: p.wire)
        var raw = "", out = "", reasoned = false
        loop: for try await line in bytes.lines {
            switch decoder.feed(line: line) {
            case .text(let s)?:
                raw += s
                let visible = stripThinking(raw)
                reasoned = reasoned || visible.count < raw.count
                guard visible != out else { continue } // 还在内联的 <think> 里：不显示，也不算首字
                out = visible
                await MainActor.run { onDelta(out) }
            case .reasoning?:
                reasoned = true
            case .done?:
                break loop
            case .failure(let m)?:
                throw PolishError(message: "模型返回错误：\(m)")
            case nil:
                continue
            }
        }
        guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PolishError(message: reasoned
                ? "模型只输出了推理、没有正文（推理可能用完了 max_tokens）。换不强制思考的模型，或在「额外请求体 JSON」里关闭思考 / 调大 max_tokens。"
                : "模型没有返回内容。请检查模型名称或「额外请求体 JSON」。")
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
