import Foundation
import PolishCore

final class Flag: @unchecked Sendable { var value = false }

struct PolishError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 单个流式润色请求。首字（无数据）超时 30s，总计 120s；不自动重试。
@MainActor
final class Polisher {
    private var task: Task<Void, Never>?
    var busy: Bool { task != nil }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func start(_ p: Profile, apiKey: String, text: String,
               onDelta: @escaping (String) -> Void, onDone: @escaping (Result<String, Error>) -> Void) {
        cancel()
        task = Task { [weak self] in
            let timedOut = Flag()
            let total = Task { // 总时长看门狗
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                if !Task.isCancelled { timedOut.value = true; self?.task?.cancel() }
            }
            defer { total.cancel() }
            do {
                let out = try await Self.stream(p, apiKey: apiKey, text: text, onDelta: onDelta)
                guard !Task.isCancelled else { return }
                self?.task = nil
                onDone(.success(out))
            } catch {
                if timedOut.value {
                    self?.task = nil
                    onDone(.failure(PolishError(message: "超时：超过 120 秒仍未完成。原文未改动。")))
                    return
                }
                guard !Task.isCancelled else { return } // 用户取消：不回调
                self?.task = nil
                onDone(.failure(Self.describe(error)))
            }
        }
    }

    static func describe(_ error: Error) -> Error {
        guard let u = error as? URLError else { return error }
        switch u.code {
        case .timedOut: return PolishError(message: "超时：30 秒内没有收到模型响应。原文未改动。")
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost:
            return PolishError(message: "网络错误：\(u.localizedDescription)")
        default: return PolishError(message: u.localizedDescription)
        }
    }

    static func stream(_ p: Profile, apiKey: String, text: String, onDelta: @escaping (String) -> Void) async throws -> String {
        var req = try makeRequest(p, apiKey: apiKey, text: text)
        req.timeoutInterval = 30
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

    static func fetchModels(_ p: Profile, apiKey: String) async -> [String] {
        guard var req = try? makeModelsRequest(p, apiKey: apiKey) else { return [] }
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return [] }
        return parseModels(data)
    }
}
