import AppKit
import Carbon.HIToolbox
import Combine
import PolishCore
import SwiftUI

let terminalBundleIDs: Set<String> = [
    "com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
    "org.alacritty", "dev.warp.Warp-Stable", "co.zeit.hyper", "org.tabby", "com.raphaelamorim.rio",
]

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
func makePanel() -> KeyPanel {
    let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isFloatingPanel = true
    p.level = .floating
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.hidesOnDeactivate = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    return p
}

final class ActionItem: NSMenuItem {
    var handler: () -> Void = {}
    convenience init(_ title: String, on: Bool = false, key: String = "", _ h: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: key)
        handler = h
        target = self
        state = on ? .on : .off
    }
    @objc func fire() { handler() }
}

/// 一次润色的来源：GUI 选区 / 终端 polish-edit / 只能复制（终端握手失败后读到的选区）
enum Origin {
    case gui(Captured)
    case terminal
    case copyOnly

    var name: String {
        switch self {
        case .gui: return "gui"
        case .terminal: return "terminal"
        case .copyOnly: return "copyOnly"
        }
    }
}

/// 一次润色在使用统计里的身份；结局只记一次
typealias UsageRun = (profile: String, bundle: String, origin: String)

@MainActor
func bundleID(_ pid: pid_t) -> String { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?" }

@MainActor
final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let state = AppState()
    let polisher = Polisher()
    let server = EditServer()
    var statusItem: NSStatusItem!
    let panel = makePanel()
    let toast = makePanel()
    var settings: NSWindow?
    var guide: NSWindow?
    var toastTimer: Timer?
    var toastConfirm = false
    var toastFade = 0 // 胶囊淡出的代次：淡出途中又显示新胶囊时，旧的完成回调不能隐藏它
    var origin: Origin?
    var terminalPID: pid_t = 0
    /// 已确认、等第二次握手写回的终端结果；source 是第一次握手读到的草稿，用来确认输入框没被改过
    var writeBack: (source: String, text: String, run: UsageRun?)?
    var run: UsageRun? // 进行中、结局还没记的润色
    var terminalKey: TerminalKey = .ctrlG // 本次握手实际生效的按键，写回时沿用
    var nextKeyAttempt: DispatchWorkItem?
    lazy var typing = TypingAssist(state: state)
    var typingSwitch: AnyCancellable?
    var typingRetry: Timer?
    var capturing = false // 读选区期间（约 0.3s）再按快捷键会让剪贴板快照拍到哨兵，忽略

    func applicationWillTerminate(_ n: Notification) { UsageStore.shared.flush() }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Polish")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        NSApp.mainMenu = editMenu()
        let host = NSHostingView(rootView: PanelView(state: state, onSwitch: { [weak self] in self?.switchProfile($0) }))
        host.sizingOptions = [] // 不让 SwiftUI 内容尺寸约束窗口，否则拉大后会被弹回
        panel.contentView = host
        // ⌥P 面板可拖动（按住空白处）、可拉边缘放大；提示胶囊不需要
        panel.styleMask.insert(.resizable)
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 360, height: 200)
        for w in [panel, toast] {
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lostFocus() }
            }
        }

        HotKey.handler = { [weak self] in self?.trigger() }
        HotKey.install()
        if !HotKey.register(state.hotKey) {
            showToast(tr("快捷键 \(state.hotKey.name) 被其他应用占用，请在设置中更换", "Shortcut \(state.hotKey.name) is used by another app. Change it in Settings"), icon: "exclamationmark.triangle")
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handleKey(e) == true ? nil : e
        }

        server.onEdit = { [weak self] draft in self?.terminalDraft(draft) }
        server.onTimeout = { [weak self] in self?.terminalTimeout() }
        do { try server.start() } catch { showToast(tr("终端集成不可用：\(error.localizedDescription)", "Terminal integration unavailable: \(error.localizedDescription)"), icon: "exclamationmark.triangle") }

        Log.write("launch trusted=\(Permissions.trusted) listenAccess=\(CGPreflightListenEventAccess())")
        // 新用户（未授权或没填 Key）首次启动弹导引，不再同时弹系统授权框；已配置好的老用户升级时直接记为已弹过
        if !state.guideShown && (!Permissions.trusted || KeyStore.apiKey(state.current).isEmpty) {
            openGuide()
        } else {
            state.guideShown = true
            if !Permissions.trusted { Permissions.prompt() }
        }
        syncTypingAssist()
        // 菜单或设置里切换开关都只改状态，这里统一启停（$ 发布的是 willSet，延后一拍读新值）
        typingSwitch = state.$typingAssist.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncTypingAssist() } }
        }
    }

    // MARK: 菜单

    /// 菜单栏应用不显示主菜单，但输入框的 ⌘C/⌘V/⌘X/⌘A/⌘Z 要靠主菜单里的「编辑」项分发，缺了就无法复制粘贴
    func editMenu() -> NSMenu {
        let main = NSMenu()
        let item = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.submenu = edit
        main.addItem(item)
        return main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !Permissions.trusted {
            menu.addItem(ActionItem("⚠️ 未授予辅助功能权限，点此打开系统设置") { Permissions.openSettings() })
            menu.addItem(.separator())
        }
        let busy = polisher.busy
        menu.addItem(ActionItem(busy ? "取消润色（\(state.hotKey.name)）" : "润色选中文字（\(state.hotKey.name)）") { [weak self] in self?.trigger() })
        menu.addItem(.separator())
        let header = NSMenuItem(title: "当前配置", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for p in state.profiles {
            let model = p.model.isEmpty ? "未填模型" : p.model
            menu.addItem(ActionItem("\(p.name)  ·  \(p.preset) / \(model)", on: p.id == state.currentID) { [weak self] in self?.state.currentID = p.id })
        }
        menu.addItem(.separator())
        let fill = NSMenuItem(title: "回填方式", action: nil, keyEquivalent: "")
        fill.submenu = NSMenu()
        for m in FillMode.allCases {
            fill.submenu!.addItem(ActionItem(m.rawValue, on: m == state.fillMode) { [weak self] in self?.state.fillMode = m })
        }
        menu.addItem(fill)
        menu.addItem(ActionItem("输入时中英提示（⌥1 \(state.targetLanguage.name) / ⌥2 中文）", on: state.typingAssist) { [weak self] in
            self?.state.typingAssist.toggle()
        })
        menu.addItem(ActionItem("设置…", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("退出 Polish", key: "q") { NSApp.terminate(nil) })
    }

    /// 按开关启停输入监听；缺少权限时提示（辅助功能或输入监控）
    func syncTypingAssist() {
        typing.isBusy = { [weak self] in self?.origin != nil || self?.polisher.busy == true }
        typing.avoid = { [weak self] in
            guard let self else { return nil }
            let open = [self.panel, self.toast].filter(\.isVisible).map(\.frame)
            return open.isEmpty ? nil : open.reduce(open[0]) { $0.union($1) }
        }
        typingRetry?.invalidate()
        typingRetry = nil
        if state.typingAssist {
            let ok = typing.start()
            Log.write("typing-assist start ok=\(ok)")
            guard !ok else { return }
            showToast(tr("输入时中英提示需要「输入监控」权限：系统设置 → 隐私与安全性 → 输入监控 → 打开 Polish", "Typing hints need Input Monitoring: System Settings → Privacy & Security → Input Monitoring → turn on Polish"), icon: "keyboard", seconds: 6)
            // 授权后自动生效，不用重启
            typingRetry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, self.state.typingAssist else { t.invalidate(); return }
                    if CGPreflightListenEventAccess(), self.typing.start() {
                        Log.write("typing-assist start ok=true (after grant)")
                        t.invalidate()
                    }
                }
            }
        } else {
            typing.stop()
        }
    }

    // MARK: 流程

    func trigger() {
        if capturing { return }
        if polisher.busy {
            cancel()
            return
        }
        if panel.isVisible, case .failed = state.phase, let o = origin { // 失败后再按 = 重试
            begin(o)
            return
        }
        dismiss()
        guard Permissions.trusted else {
            Permissions.prompt()
            showToast(tr("需要辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能", "Accessibility permission required: System Settings → Privacy & Security → Accessibility"), icon: "lock.shield")
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        if terminalBundleIDs.contains(front.bundleIdentifier ?? "") {
            state.target = tr("\(front.localizedName ?? "终端") · 输入框", "\(front.localizedName ?? "Terminal") · Input")
            terminalPID = front.processIdentifier
            record(writeBack?.run, .cancelled) // 上一次的写回还没完成就又按了 ⌥P
            writeBack = nil
            let ime = TISCopyCurrentKeyboardInputSource().map { Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty($0.takeRetainedValue(), kTISPropertyInputSourceID)).takeUnretainedValue() as String } ?? "?"
            Log.write("terminal app=\(front.bundleIdentifier ?? "?") ime=\(ime)")
            // 各家 CLI 的外部编辑器键不同：先发设置里的，没连上再试另一个（Ctrl+G：zsh / Claude / Codex；Ctrl+X：Qoder / Gemini / Qwen）
            sendTerminalKeys([state.terminalKey, state.terminalKey == .ctrlX ? .ctrlG : .ctrlX])
        } else {
            capturing = true
            Task {
                let c = await Selection.capture()
                capturing = false
                guard let c else {
                    showToast(tr("没有可润色的文字：请选中文字，或把光标放在输入框里已写内容的末尾", "Nothing to polish: select text, or put the cursor at the end of what you typed"), icon: "exclamationmark.circle", seconds: 3)
                    return
                }
                state.source = c.text
                state.target = c.appName
                begin(.gui(c))
            }
        }
    }

    func sendTerminalKeys(_ keys: [TerminalKey]) {
        nextKeyAttempt?.cancel()
        guard let k = keys.first else { return }
        terminalKey = k
        server.arm() // 每次发键重新计 1.5s 待命
        Log.write("terminal send \(k)")
        Keys.send(k)
        let rest = Array(keys.dropFirst())
        guard !rest.isEmpty else { return }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.sendTerminalKeys(rest) } }
        nextKeyAttempt = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// 两次握手：第一次读到草稿立即原样放回，润色期间 CLI 照常可用；确认后再握手一次写回，草稿变了就不覆盖
    func terminalDraft(_ draft: String) {
        nextKeyAttempt?.cancel()
        if let w = writeBack {
            writeBack = nil
            guard draft == w.source else {
                record(w.run, .copied)
                server.reply(.cancel)
                copyToPasteboard(w.text)
                showToast(tr("输入框已改动，没有写回。结果已复制到剪贴板", "The input changed, so nothing was written back. The result is on the clipboard"), icon: "exclamationmark.triangle", seconds: 4)
                return
            }
            let ok = server.reply(.ok(Data(w.text.utf8)))
            record(w.run, ok ? .accepted : .copied)
            if ok {
                showToast(tr("已写回输入框（未发送）", "Written back to the input (not sent)"), icon: "checkmark.circle.fill")
            } else {
                copyToPasteboard(w.text)
                showToast(tr("写回失败：polish-edit 已退出。结果已复制到剪贴板", "Write-back failed: polish-edit exited. The result is on the clipboard"), icon: "exclamationmark.triangle", seconds: 4)
            }
            return
        }
        server.reply(.cancel)
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast(tr("输入框为空", "The input is empty"), icon: "exclamationmark.circle")
            return
        }
        state.source = draft
        begin(.terminal)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 1.5s 内没有 polish-edit 连上：降级为「润色终端选区后复制」
    func terminalTimeout() {
        nextKeyAttempt?.cancel()
        Log.write("terminal timeout: polish-edit not connected writeBack=\(writeBack != nil)")
        if let w = writeBack {
            writeBack = nil
            record(w.run, .failed)
            copyToPasteboard(w.text)
            showToast(tr("写回时没有连上 polish-edit。结果已复制到剪贴板", "Not connected to polish-edit when writing back. The result is on the clipboard"), icon: "exclamationmark.triangle", seconds: 4)
            return
        }
        capturing = true
        Task {
            let c = await Selection.capture()
            capturing = false
            if let c {
                state.source = c.text
                state.target = tr("\(c.appName) · 选区（仅复制）", "\(c.appName) · Selection (copy only)")
                begin(.copyOnly)
            } else {
                record((state.current.name, bundleID(terminalPID), "terminal"), .failed) // 握手失败、也没有选区：这次 ⌥P 没开始润色
                showToast(tr("没有连上 polish-edit（已试 Ctrl+G 和 Ctrl+X）：请在 设置 → 终端集成 中安装 shell 片段，安装后需重启 CLI；OpenCode、Aider 等需在设置里选对应按键。若 zsh 草稿被清空，执行 print -z -- $ZLE_LINE_ABORTED 恢复", "Couldn’t connect to polish-edit (tried Ctrl+G and Ctrl+X): install the shell snippet in Settings → Terminal, then restart the CLI; OpenCode, Aider, etc. need their key chosen in Settings. If the zsh draft was cleared, run print -z -- $ZLE_LINE_ABORTED to restore it"),
                          icon: "terminal", seconds: 6)
            }
        }
    }

    var effectiveMode: FillMode {
        switch origin {
        case .copyOnly?: return .preview
        case .gui(let c)? where c.source == .copy && state.fillMode == .auto: return .preview // ⌘C 读到的文本无法 AX 校验，强制预览
        default: return state.fillMode
        }
    }

    func begin(_ o: Origin) {
        finish(.cancelled) // ⌘1–9 换配置重跑：上一次算放弃
        run = (state.current.name, bundleID({ if case .gui(let c) = o { return c.pid }; return terminalPID }()), o.name)
        origin = o
        state.terminal = { if case .terminal = o { return true }; return false }()
        state.copyOnly = { if case .copyOnly = o { return true }; return false }()
        state.output = ""
        state.phase = .streaming
        let p = state.current
        let key = KeyStore.apiKey(p)
        let local = ["localhost", "127.0.0.1", "::1"].contains(URL(string: p.baseURL)?.host ?? "")
        if key.isEmpty && !local {
            fail(tr("配置「\(p.name)」还没有填写 API Key。按 ⌘, 打开设置。", "Profile “\(p.name)” has no API key yet. Press ⌘, to open Settings."))
            return
        }
        if effectiveMode == .preview {
            if !panel.isVisible { showPanel() }
        } else {
            showToast(tr("润色中…  \(state.hotKey.name) 取消", "Polishing…  \(state.hotKey.name) to cancel"), icon: "sparkles", sticky: true)
        }
        let source = state.source
        let t0 = Date()
        var first = true
        polisher.start(p, apiKey: key, text: source, onDelta: { [weak self] s in
            if first {
                first = false
                UsageStore.shared.latency(.polishFirst, ms: Int(Date().timeIntervalSince(t0) * 1000))
            }
            self?.state.output = s
        }, onDone: { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let s):
                UsageStore.shared.latency(.polishTotal, ms: Int(Date().timeIntervalSince(t0) * 1000))
                self.state.output = PolishCore.finalize(s, original: source)
                self.state.phase = .done
                switch self.effectiveMode {
                case .preview: break
                case .auto: self.accept()
                case .toast: self.showToast(tr("润色完成 · ⏎ 替换 · ⌘C 复制 · Esc 放弃", "Polished · ⏎ Replace · ⌘C Copy · Esc Discard"), icon: "checkmark.circle", confirm: true)
                }
            case .failure(let e):
                self.fail(e.localizedDescription)
            }
        })
    }

    func fail(_ msg: String) {
        finish(.failed)
        state.phase = .failed(msg)
        hideToast()
        showPanel() // 任何回填方式下，失败都弹面板
    }

    func accept() {
        guard state.phase == .done, let o = origin else { return }
        let text = state.output
        switch o {
        case .terminal:
            let source = state.source
            let r = run // 结局要等第二次握手
            run = nil
            endSession()
            hideToast()
            Task {
                await sleepMs(60) // 面板收起、按键回到终端后再发
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == terminalPID else {
                    record(r, .copied)
                    copyToPasteboard(text)
                    showToast(tr("前台已不是原终端，没有写回。结果已复制到剪贴板", "The original terminal is no longer in front, so nothing was written back. The result is on the clipboard"), icon: "exclamationmark.triangle", seconds: 4)
                    return
                }
                writeBack = (source, text, r)
                sendTerminalKeys([terminalKey])
            }
        case .copyOnly:
            copyResult()
        case .gui(let c):
            let r = run // 校验期间再按 ⌥P 也不会把这次记成取消
            run = nil
            hidePanel()
            hideToast()
            Task {
                await sleepMs(c.source == .copy ? 150 : 60) // 让焦点回到目标窗口；⌘C 重读需要目标窗口已恢复 key
                let same = NSWorkspace.shared.frontmostApplication?.processIdentifier == c.pid
                let now = same ? await Selection.reread(c) : nil
                guard now == c.text else {
                    record(r, .verifyFailed)
                    state.phase = .verifyFailed(same
                        ? tr("回填前校验失败：原来的选中内容已变化。为防止误覆盖，没有替换。可按 ⌘C 复制结果后手动粘贴。", "Check before replacing failed: the selection changed. Nothing was replaced to avoid overwriting. Press ⌘C to copy the result and paste it yourself.")
                        : tr("回填前校验失败：前台应用已切换。为防止误覆盖，没有替换。可按 ⌘C 复制结果后手动粘贴。", "Check before replacing failed: another app is in front. Nothing was replaced to avoid overwriting. Press ⌘C to copy the result and paste it yourself."))
                    showPanel()
                    return
                }
                await Selection.paste(text)
                record(r, .accepted)
                endSession()
                showToast(tr("已替换", "Replaced"), icon: "checkmark.circle.fill")
            }
        }
    }

    func copyResult() {
        guard !state.output.isEmpty, state.phase != .streaming else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.output, forType: .string)
        finish(.copied)
        restoreAutoSelection()
        endSession()
        showToast(tr("已复制到剪贴板，原文未改动", "Copied to the clipboard; the original is unchanged"), icon: "doc.on.clipboard")
    }

    func cancel() {
        polisher.cancel()
        let wasActive = origin != nil
        dismiss()
        if wasActive { showToast(tr("已取消，原文未改动", "Cancelled; the original is unchanged"), icon: "xmark.circle") }
    }

    /// Esc / 放弃：不改原文
    func dismiss() {
        finish(.cancelled)
        polisher.cancel()
        restoreAutoSelection()
        endSession()
        hideToast()
    }

    /// 放弃自动选中「光标前内容」的会话时，把光标放回原处；校验失败（焦点已变）时不动
    func restoreAutoSelection() {
        guard case .gui(let c)? = origin, c.autoSelect != nil else { return }
        if case .verifyFailed = state.phase { return }
        hidePanel() // 面板仍是 key 窗口时，合成的 → 键会被面板收走
        hideToast()
        Task {
            await sleepMs(60)
            Selection.restoreCaret(c)
        }
    }

    /// 记下这次润色的结局；已记过（run 为空）就不再记：失败后再按 Esc、校验失败后再复制都不会重复
    func finish(_ o: PolishOutcome) {
        record(run, o)
        run = nil
    }

    func record(_ r: UsageRun?, _ o: PolishOutcome) {
        guard let r else { return }
        UsageStore.shared.polish(profile: r.profile, bundle: r.bundle, origin: r.origin, o)
    }

    func endSession() {
        origin = nil
        hidePanel()
    }

    /// 面板 / 待确认提示失焦（用户点了别处）：等同放弃，但不恢复光标——用户点的位置就是新光标
    func lostFocus() {
        DispatchQueue.main.async { [self] in // 回填流程会先自己隐藏面板，等它走完再判断是否真失焦
            let open = (panel.isVisible && !panel.isKeyWindow) || (toastConfirm && toast.isVisible && !toast.isKeyWindow)
            guard open, !panel.isKeyWindow, !toast.isKeyWindow else { return }
            finish(.dismissed)
            polisher.cancel()
            endSession()
            hideToast()
        }
    }

    func switchProfile(_ i: Int) {
        guard i < state.profiles.count else { return }
        state.currentID = state.profiles[i].id
        if let o = origin, panel.isVisible { begin(o) }
    }

    // MARK: 窗口

    func clamp(_ o: NSPoint, _ s: NSSize) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(o) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let x = min(max(o.x, vf.minX + 8), vf.maxX - s.width - 8)
        let y = min(max(o.y, vf.minY + 8), vf.maxY - s.height - 8)
        return NSRect(origin: NSPoint(x: x, y: y), size: s)
    }

    /// 鼠标上方居中（放不下则下方）；x 先夹在鼠标所在屏内，避免 clamp 按原点认错屏
    func anchor(for size: NSSize) -> NSPoint {
        // 翻译浮层开着：放在它上方（放不下放下方），留出间距、不互相遮挡
        if let h = typing.hintFrame {
            let vf = (NSScreen.screens.first { $0.frame.intersects(h) } ?? NSScreen.main!).visibleFrame
            if let f = typingHintFrame(size: size, anchor: h, visibleFrame: vf) { return f.origin }
        }
        let m = NSEvent.mouseLocation
        let vf = (NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main!).visibleFrame
        let x = min(max(m.x - size.width / 2, vf.minX + 8), vf.maxX - size.width - 8)
        let above = m.y + 18
        return NSPoint(x: x, y: above + size.height <= vf.maxY ? above : m.y - size.height - 18)
    }

    func showPanel() {
        // 沿用用户上次拉出来的大小；位置仍跟随本次选区
        let size = panel.frame.width > 0 ? panel.frame.size : NSSize(width: 460, height: 270)
        if !panel.isVisible { panel.setFrame(clamp(anchor(for: size), size), display: true) }
        panel.orderFrontRegardless()
        panel.makeKey()
        if !state.panelShown { state.panelShown = true } // 从隐藏到可见：播放出现动画
    }

    /// 不加淡出：⏎ 替换要立刻把焦点还给目标应用，再重读选区比对
    func hidePanel() {
        state.panelShown = false // 先停光边，再隐藏
        panel.orderOut(nil)
    }

    func showToast(_ text: String, icon: String, sticky: Bool = false, confirm: Bool = false, seconds: Double = 1.8) {
        toastTimer?.invalidate()
        toastConfirm = confirm
        toastFade += 1
        let host = NSHostingView(rootView: ToastView(text: text, icon: icon))
        toast.contentView = host
        let s = host.fittingSize
        toast.setFrame(clamp(anchor(for: s), s), display: true)
        NSAnimationContext.runAnimationGroup { $0.duration = 0; toast.animator().alphaValue = 1 } // 打断还在进行的淡出
        toast.orderFrontRegardless()
        if confirm { toast.makeKey() }
        if !sticky && !confirm {
            toastTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideToast() }
            }
        }
    }

    /// 纯显示的胶囊淡出 100ms；待确认的胶囊是 key 窗口，立刻隐藏，让焦点马上回到目标应用
    func hideToast() {
        let confirm = toastConfirm
        toastConfirm = false
        toastFade += 1
        guard toast.isVisible, !confirm, !toast.isKeyWindow else { return toast.orderOut(nil) }
        let current = toastFade
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            toast.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.toastFade == current else { return }
                self.toast.orderOut(nil)
            }
        }
    }

    func handleKey(_ e: NSEvent) -> Bool {
        guard panel.isKeyWindow || (toast.isKeyWindow && toastConfirm) else { return false }
        // 编辑结果时输入法还在组合：⏎ / Esc 交给输入法确认或取消
        if panel.isKeyWindow, let tv = panel.firstResponder as? NSTextView, tv.hasMarkedText() { return false }
        switch Int(e.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if !e.modifierFlags.intersection([.shift, .option]).isEmpty { return false } // 编辑结果时 ⇧⏎ / ⌥⏎ 换行
            if state.copyOnly { copyResult() } else { accept() }
            return true
        case kVK_Escape:
            dismiss()
            return true
        default: break
        }
        guard e.modifierFlags.contains(.command), let ch = e.charactersIgnoringModifiers else { return false }
        if ch == "c" {
            // 编辑结果时选中了部分文字：照常复制选中部分
            if let tv = panel.firstResponder as? NSTextView, tv.selectedRange().length > 0 { return false }
            copyResult()
            return true
        }
        if ch == "," { openSettings(); return true }
        if let n = Int(ch) { switchProfile(n == 0 ? 9 : n - 1); return true } // ⌘0 是第 10 个
        return false
    }

    /// tab：0 配置 / 1 通用 / 2 终端集成 / 3 使用统计 / 4 权限与隐私；nil 保持上次的标签页
    func openSettings(tab: Int? = nil) {
        if let tab { state.settingsTab = tab }
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(state: state, rebind: { spec in
                guard HotKey.register(spec) else {
                    _ = HotKey.register(self.state.hotKey) // 冲突：恢复旧快捷键
                    return false
                }
                self.state.hotKey = spec
                return true
            }))
            w.center()
            settings = w
        }
        settings!.title = tr("Polish 设置", "Polish Settings") // 每次打开时按当前界面语言刷新
        NSApp.activate(ignoringOtherApps: true)
        settings!.makeKeyAndOrderFront(nil)
        settings!.orderFrontRegardless()
    }

    /// 使用导引：只保留一个窗口，重复打开只提到最前；关闭时释放窗口（连同每秒刷新的计时器）
    func openGuide() {
        if guide == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: GuideView(state: state,
                                                              openSettings: { [weak self] in self?.openSettings(tab: $0) },
                                                              close: { [weak self] in self?.guide?.close() }))
            w.center()
            guide = w
        }
        guide!.title = tr("欢迎使用 Polish", "Welcome to Polish")
        NSApp.activate(ignoringOtherApps: true)
        guide!.makeKeyAndOrderFront(nil)
        guide!.orderFrontRegardless()
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, w === guide else { return }
        state.guideShown = true // 点「完成」或关闭按钮都算看过
        DispatchQueue.main.async { MainActor.assumeIsolated { if self.guide === w { self.guide = nil } } } // 等 close 返回后再释放
    }
}
