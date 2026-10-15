import AppKit
import PolishCore
import SwiftUI

/// 使用导引：检查清单，每项是否完成都实时算（窗口打开期间每秒刷新），不另外保存
struct GuideView: View {
    @ObservedObject var state: AppState
    let openSettings: (Int) -> Void
    let close: () -> Void
    @State var trusted = Permissions.trusted
    @State var hasKey = false
    @State var listen = CGPreflightListenEventAccess()
    @State var rc = ZshRc.read()
    @State var promptedAt: Date?
    @State var now = Date()
    let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var terminalInstalled: Bool { ["zsh", "agents", "claude", "codex"].contains { RcBlock.has(rc, id: $0) } }

    func refresh() {
        trusted = Permissions.trusted
        hasKey = !KeyStore.apiKey(state.current).isEmpty
        listen = CGPreflightListenEventAccess()
        rc = ZshRc.read()
        now = Date()
    }

    var body: some View {
        let hk = state.hotKey.name
        VStack(alignment: .leading, spacing: 12) {
            row(trusted, tr("1  辅助功能权限", "1  Accessibility permission"),
                tr("读取选区和替换文字需要它", "Needed to read the selection and replace text"),
                button: tr("打开系统设置", "Open System Settings")) {
                Permissions.prompt()
                Permissions.openSettings()
                promptedAt = Date()
            }
            if !trusted, let p = promptedAt, now.timeIntervalSince(p) >= 10 {
                HStack {
                    Text(tr("已授权仍未打勾？", "Granted but still unchecked?")).font(.caption).foregroundStyle(.secondary)
                    Button(tr("重启 Polish", "Restart Polish")) { relaunch() }.controlSize(.small)
                }.padding(.leading, 28)
            }
            row(hasKey, tr("2  填写 API Key", "2  Enter an API Key"),
                tr("设置 → 服务商：选服务商、填 Key，再点「测试连接」", "Settings → Providers: pick a provider, enter the key, then click “Test Connection”"),
                button: tr("去配置", "Configure")) { openSettings(0) }

            section(tr("可选", "Optional"))
            row(state.typingAssist && listen, tr("输入时中英提示（需输入监控权限）", "Typing hints (needs Input Monitoring)"),
                button: state.typingAssist ? tr("打开系统设置", "Open System Settings") : tr("开启", "Turn On")) {
                if state.typingAssist { // 默认已开，只差授权：申请并打开输入监控设置
                    CGRequestListenEventAccess()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                } else {
                    state.typingAssist = true // 授权提示沿用 syncTypingAssist
                }
            }
            row(terminalInstalled, tr("终端集成（zsh / Claude Code 等）", "Terminal integration (zsh / Claude Code, etc.)"),
                button: tr("去设置", "Set Up")) { openSettings(2) }

            section(tr("快捷键", "Shortcuts"))
            Text(tr("\(hk) 润色 · ⏎ 替换 · ⌘C 复制 · Esc 放弃 · ⌘1–9 换配置", "\(hk) polish · ⏎ replace · ⌘C copy · Esc discard · ⌘1–9 switch profile"))
                .font(.callout)
            HStack {
                Spacer()
                Button(tr("完成", "Done"), action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }

    func row(_ done: Bool, _ title: String, _ detail: String? = nil, button: String? = nil, action: @escaping () -> Void = {}) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            if let button { Button(button, action: action) }
        }
    }

    func section(_ title: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            VStack { Divider() }
        }.padding(.top, 4)
    }

    /// 等本进程退出后再打开自身：两个实例并存时，新实例注册快捷键会和旧实例冲突
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 $0 2>/dev/null; do sleep 0.2; done; open \"$1\"",
                       String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
