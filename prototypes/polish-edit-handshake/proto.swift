// PROTOTYPE — 一次性原型，只用于验证「polish-edit 与 app 的通信和握手约定」，不要合入 main。
// 一个二进制两种身份：
//   proto serve            假 app：监听 socket，从 stdin 读命令（arm / confirm / cancel / copy / die）
//   proto --edit <file>    polish-edit（argv[0] 为 polish-edit 时同样进入此模式）
import Foundation

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)

let env = ProcessInfo.processInfo.environment
let sockPath = env["POLISH_SOCK"] ?? NSTemporaryDirectory() + "polish-proto.sock"
let armWindow = 1.5

func makeAddr() -> sockaddr_un {
    var a = sockaddr_un()
    a.sun_family = sa_family_t(AF_UNIX)
    a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let b = Array(sockPath.utf8)
    withUnsafeMutableBytes(of: &a.sun_path) { buf in
        precondition(b.count < buf.count, "socket 路径过长")
        buf.copyBytes(from: b)
        buf[b.count] = 0
    }
    return a
}

func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var a = makeAddr()
    return withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

// 帧格式：一行头部（"EDIT n" / "OK n" / "NO" / "CANCEL"），后跟 n 字节正文
func sendMsg(_ fd: Int32, _ header: String, _ body: Data = Data()) {
    var d = Data((header + "\n").utf8)
    d.append(body)
    d.withUnsafeBytes { p in
        var off = 0
        while off < p.count {
            let n = write(fd, p.baseAddress! + off, p.count - off)
            if n <= 0 { return }
            off += n
        }
    }
}

final class Reader {
    let fd: Int32
    var buf = [UInt8]()
    init(_ fd: Int32) { self.fd = fd }
    func fill() -> Bool {
        var tmp = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &tmp, tmp.count)
        if n <= 0 { return false }
        buf += tmp[0..<n]
        return true
    }
    func line() -> String? {
        while true {
            if let i = buf.firstIndex(of: 10) {
                let s = String(decoding: buf[..<i], as: UTF8.self)
                buf.removeSubrange(...i)
                return s
            }
            if !fill() { return nil }
        }
    }
    func bytes(_ n: Int) -> Data? {
        while buf.count < n { if !fill() { return nil } }
        let d = Data(buf[..<n])
        buf.removeSubrange(..<n)
        return d
    }
}

// MARK: - polish-edit

func fallback(_ path: String) -> Never {
    let visual = env["VISUAL"].flatMap { $0.contains("polish-edit") ? nil : $0 }
    let ed: String = [env["POLISH_FALLBACK_EDITOR"], visual, env["EDITOR"]]
        .compactMap { $0 }.first { !$0.isEmpty } ?? "vi"
    // 经 sh 执行，兼容 "code -w" 这类带参数的编辑器
    let script = "\(ed) \"$1\""
    let strs: [String] = ["/bin/sh", "-c", script, "sh", path]
    var argv: [UnsafeMutablePointer<CChar>?] = strs.map { strdup($0) }
    argv.append(nil)
    execv("/bin/sh", &argv)
    perror("execv")
    exit(1)
}

func runEdit(_ path: String) -> Never {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard withSockaddr({ connect(fd, $0, $1) }) == 0 else { fallback(path) } // app 未运行
    let draft = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
    sendMsg(fd, "EDIT \(draft.count)", draft)
    let r = Reader(fd)
    guard let h = r.line() else { exit(0) } // EOF：app 崩溃或退出 → 不改文件
    if h == "NO" { close(fd); fallback(path) } // 不是 app 触发 / 晚到 / 并发
    if h.hasPrefix("OK "), let n = Int(h.dropFirst(3)), let body = r.bytes(n) {
        try? body.write(to: URL(fileURLWithPath: path)) // 非原子写：原地覆盖，保留 inode
    }
    exit(0) // OK / CANCEL / 其他 一律 0
}

// MARK: - 假 app

func say(_ s: String) { print("[app] \(s)") }

func runServe() -> Never {
    unlink(sockPath)
    let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard withSockaddr({ bind(lfd, $0, $1) }) == 0, listen(lfd, 4) == 0 else { perror("bind"); exit(1) }
    chmod(sockPath, 0o600)
    say("listening \(sockPath)")

    var armedUntil: Date?
    var client: Int32 = -1
    var draft = ""
    var stdinBuf = [UInt8]()

    func finish(_ header: String, _ body: Data = Data()) {
        sendMsg(client, header, body)
        close(client)
        client = -1
        say("state=idle")
    }

    while true {
        var fds = [pollfd(fd: 0, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: lfd, events: Int16(POLLIN), revents: 0)]
        if client >= 0 { fds.append(pollfd(fd: client, events: Int16(POLLIN), revents: 0)) }
        _ = poll(&fds, nfds_t(fds.count), 100)

        if let t = armedUntil, Date() > t {
            armedUntil = nil
            say("握手超时 \(armWindow)s → 降级复制模式；提示：zsh 草稿被清空可用 print -z -- $ZLE_LINE_ABORTED 恢复")
        }

        if fds[0].revents != 0 {
            var tmp = [UInt8](repeating: 0, count: 1024)
            let n = read(0, &tmp, tmp.count)
            if n <= 0 { exit(0) }
            stdinBuf += tmp[0..<n]
            while let i = stdinBuf.firstIndex(of: 10) {
                let cmd = String(decoding: stdinBuf[..<i], as: UTF8.self)
                stdinBuf.removeSubrange(...i)
                switch cmd {
                case "arm":
                    armedUntil = Date().addingTimeInterval(armWindow)
                    say("发送 Ctrl+G，进入待命 \(armWindow)s")
                case "confirm" where client >= 0:
                    let out = draft.replacingOccurrences(of: "DRAFT", with: "POLISHED")
                    say("⏎ 确认 → 回传 \(out.debugDescription)")
                    finish("OK \(out.utf8.count)", Data(out.utf8))
                case "copy" where client >= 0:
                    say("⌘C 复制结果到剪贴板，文件不变")
                    finish("CANCEL")
                case "cancel" where client >= 0:
                    say("Esc 放弃")
                    finish("CANCEL")
                case "die":
                    say("模拟崩溃")
                    exit(9)
                default:
                    say("忽略命令 \(cmd)（client=\(client)）")
                }
            }
        }

        if fds[1].revents != 0 {
            let fd = accept(lfd, nil, nil)
            let r = Reader(fd)
            guard let h = r.line(), h.hasPrefix("EDIT "), let n = Int(h.dropFirst(5)), let body = r.bytes(n) else {
                close(fd); continue
            }
            let text = String(decoding: body, as: UTF8.self)
            if armedUntil != nil && client < 0 {
                armedUntil = nil
                client = fd
                draft = text
                say("握手成功，接手草稿 \(text.debugDescription)，state=previewing")
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    say("输入框为空 → 取消")
                    finish("CANCEL")
                }
            } else {
                say("未待命（或忙），回 NO → polish-edit 转交原编辑器")
                sendMsg(fd, "NO")
                close(fd)
            }
        }

        if client >= 0, fds.count > 2, fds[2].revents != 0 {
            var b: UInt8 = 0
            if read(client, &b, 1) <= 0 {
                say("polish-edit 断开（终端 Ctrl+C）→ 取消请求、关闭面板")
                close(client)
                client = -1
            }
        }
    }
}

let args = CommandLine.arguments
if (args[0] as NSString).lastPathComponent == "polish-edit", args.count > 1 { runEdit(args[1]) }
if args.count > 2, args[1] == "--edit" { runEdit(args[2]) }
if args.count > 1, args[1] == "serve" { runServe() }
print("用法：proto serve | proto --edit <file> | polish-edit <file>")
exit(2)
