import Foundation

// polish-edit（终端编辑器入口）与 app 内 socket 服务端，协议见 PolishCore/EditProtocol.swift

public enum Paths {
    public static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Polish")
    /// POLISH_SOCK 仅供测试覆盖
    public static var socket: String { ProcessInfo.processInfo.environment["POLISH_SOCK"] ?? support.appendingPathComponent("edit.sock").path }
}

func withUnixAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
    var a = sockaddr_un()
    a.sun_family = sa_family_t(AF_UNIX)
    a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8)
    let fits = withUnsafeMutableBytes(of: &a.sun_path) { buf -> Bool in
        guard bytes.count < buf.count else { return false }
        buf.copyBytes(from: bytes)
        buf[bytes.count] = 0
        return true
    }
    guard fits else { return nil }
    return withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

@discardableResult
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { p in
        var off = 0
        while off < p.count {
            let n = write(fd, p.baseAddress! + off, p.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

// MARK: - polish-edit

public enum EditClient {
    /// 被 zsh / Claude Code / Codex 当作 $VISUAL 调用：把草稿交给 app，等待结果。
    /// 只有收到 OK 才写文件；取消、app 退出、出错一律不改文件并 exit 0。
    public static func run(_ path: String?) -> Never {
        guard let path else {
            fputs("用法：polish-edit <file>\n", stderr)
            exit(2)
        }
        signal(SIGPIPE, SIG_IGN)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, withUnixAddress(Paths.socket, { connect(fd, $0, $1) }) == 0 else { fallback(path) } // app 未运行
        let draft = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        guard writeAll(fd, encode(.edit(draft))) else { fallback(path) }
        var reader = FrameReader()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            do {
                switch try reader.next() {
                case .no?:
                    close(fd)
                    fallback(path) // 不是 app 触发 / 晚到 / 并发
                case .ok(let body)?:
                    try? body.write(to: URL(fileURLWithPath: path)) // 非原子写：原地覆盖
                    exit(0)
                case .cancel?, .edit?:
                    exit(0)
                case nil:
                    break
                }
            } catch {
                exit(0)
            }
            let n = read(fd, &buf, buf.count)
            if n <= 0 { exit(0) } // EOF：app 崩溃或退出
            reader.append(Data(buf[0..<n]))
        }
    }

    static func fallback(_ path: String) -> Never {
        let ed = fallbackEditor(env: ProcessInfo.processInfo.environment)
        // 经 sh 执行，兼容 "code -w" 这类带参数的编辑器
        let args: [String] = ["/bin/sh", "-c", "\(ed) \"$1\"", "sh", path]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)
        execv("/bin/sh", &argv)
        perror("polish-edit: execv")
        exit(1)
    }
}

// MARK: - app 端

/// 「待命」：app 发 Ctrl+G 后 1.5s 内到达的第一个 polish-edit 被接手，其余回 NO。
@MainActor
public final class EditServer {
    public var onEdit: ((String) -> Void)?
    public var onTimeout: (() -> Void)?
    public var onDisconnect: (() -> Void)?

    public init() {}

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var client: Int32 = -1
    private var clientSource: DispatchSourceRead?
    private var armTimer: DispatchWorkItem?
    private var armed = false

    public var hasClient: Bool { client >= 0 }

    public func start() throws {
        try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = Paths.socket
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0, withUnixAddress(path, { bind(listenFD, $0, $1) }) == 0, listen(listenFD, 8) == 0 else {
            throw NSError(domain: "Polish", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "无法监听 \(path)：\(String(cString: strerror(errno)))"])
        }
        chmod(path, 0o600)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptOne() } }
        src.resume()
        acceptSource = src
    }

    public func arm(seconds: Double = 1.5) {
        armTimer?.cancel()
        armed = true
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.armed else { return }
            self.armed = false
            self.onTimeout?()
        }
        armTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    public func disarm() {
        armed = false
        armTimer?.cancel()
    }

    public func reply(_ m: EditMessage) {
        guard client >= 0 else { return }
        writeAll(client, encode(m))
        closeClient()
    }

    private func acceptOne() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 1, tv_usec: 0) // polish-edit 连上后立即发送 EDIT，1s 读不到就放弃
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var reader = FrameReader()
        var buf = [UInt8](repeating: 0, count: 65536)
        var draft: Data?
        while draft == nil {
            let m: EditMessage?
            do { m = try reader.next() } catch { close(fd); return }
            if case .edit(let d)? = m { draft = d; break }
            if m != nil { close(fd); return } // 只接受 EDIT
            let n = read(fd, &buf, buf.count)
            if n <= 0 { close(fd); return }
            reader.append(Data(buf[0..<n]))
        }
        guard armed, client < 0, let draft else {
            writeAll(fd, encode(.no))
            close(fd)
            return
        }
        disarm()
        client = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var b: UInt8 = 0
                if read(fd, &b, 1) <= 0 { // 终端里 Ctrl+C 杀掉了 polish-edit
                    self.closeClient()
                    self.onDisconnect?()
                }
            }
        }
        src.resume()
        clientSource = src
        onEdit?(String(decoding: draft, as: UTF8.self))
    }

    private func closeClient() {
        clientSource?.cancel()
        clientSource = nil
        if client >= 0 { close(client) }
        client = -1
    }
}
