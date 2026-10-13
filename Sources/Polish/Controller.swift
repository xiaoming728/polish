import AppKit
import Carbon.HIToolbox
import PolishCore
import SwiftUI

let terminalBundleIDs: Set<String> = ["com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2"]

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
    case copyOnly(CGRect?)
}

@MainActor
final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state = AppState()
    let polisher = Polisher()
    let server = EditServer()
    var statusItem: NSStatusItem!
    let panel = makePanel()
    let toast = makePanel()
    var settings: NSWindow?
    var toastTimer: Timer?
    var toastConfirm = false
    var origin: Origin?
    var capturing = false // 读选区期间（约 0.3s）再按快捷键会让剪贴板快照拍到哨兵，忽略

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Polish")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        NSApp.mainMenu = editMenu()
        panel.contentView = NSHostingView(rootView: PanelView(state: state))

        HotKey.handler = { [weak self] in self?.trigger() }
        HotKey.install()
        if !HotKey.register(state.hotKey) {
            showToast("快捷键 \(state.hotKey.name) 被其他应用占用，请在设置中更换", icon: "exclamationmark.triangle")
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handleKey(e) == true ? nil : e
        }

        server.onEdit = { [weak self] draft in self?.terminalDraft(draft) }
        server.onTimeout = { [weak self] in self?.terminalTimeout() }
        server.onDisconnect = { [weak self] in
            guard let self, case .terminal? = self.origin else { return }
            self.polisher.cancel()
            self.endSession()
            self.showToast("已取消（polish-edit 已退出），原文未改动", icon: "xmark.circle")
        }
        do { try server.start() } catch { showToast("终端集成不可用：\(error.localizedDescription)", icon: "exclamationmark.triangle") }

        if !Permissions.trusted { Permissions.prompt() }
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
        menu.addItem(ActionItem("设置…", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("退出 Polish", key: "q") { NSApp.terminate(nil) })
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
            showToast("需要辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能", icon: "lock.shield")
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        if terminalBundleIDs.contains(front.bundleIdentifier ?? "") {
            state.target = "\(front.localizedName ?? "终端") · 输入框"
            server.arm()
            Keys.ctrlG()
        } else {
            capturing = true
            Task {
                let c = await Selection.capture()
                capturing = false
                guard let c else {
                    showToast("没有可润色的文字：请选中文字，或把光标放在输入框里已写内容的末尾", icon: "exclamationmark.circle", seconds: 3)
                    return
                }
                state.source = c.text
                state.target = c.appName
                begin(.gui(c))
            }
        }
    }

    func terminalDraft(_ draft: String) {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            server.reply(.cancel)
            showToast("输入框为空", icon: "exclamationmark.circle")
            return
        }
        state.source = draft
        begin(.terminal)
    }

    /// 1.5s 内没有 polish-edit 连上：降级为「润色终端选区后复制」
    func terminalTimeout() {
        capturing = true
        Task {
            let c = await Selection.capture()
            capturing = false
            if let c {
                state.source = c.text
                state.target = "\(c.appName) · 选区（仅复制）"
                begin(.copyOnly(c.bounds))
            } else {
                showToast("没有连上 polish-edit：请在 设置 → 终端集成 中安装 shell 片段。若 zsh 草稿被清空，执行 print -z -- $ZLE_LINE_ABORTED 恢复",
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
        origin = o
        state.terminal = { if case .terminal = o { return true }; return false }()
        state.copyOnly = { if case .copyOnly = o { return true }; return false }()
        state.output = ""
        state.phase = .streaming
        let p = state.current
        let key = Keychain.get(p.id.uuidString) ?? ""
        let local = ["localhost", "127.0.0.1", "::1"].contains(URL(string: p.baseURL)?.host ?? "")
        if key.isEmpty && !local {
            fail("配置「\(p.name)」还没有填写 API Key。按 ⌘, 打开设置。")
            return
        }
        if effectiveMode == .preview {
            if !panel.isVisible { showPanel() }
        } else {
            showToast("润色中…  \(state.hotKey.name) 取消", icon: "sparkles", sticky: true)
        }
        let source = state.source
        polisher.start(p, apiKey: key, text: source, onDelta: { [weak self] s in
            self?.state.output = s
        }, onDone: { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let s):
                self.state.output = PolishCore.finalize(s, original: source)
                self.state.phase = .done
                switch self.effectiveMode {
                case .preview: break
                case .auto: self.accept()
                case .toast: self.showToast("润色完成 · ⏎ 替换 · ⌘C 复制 · Esc 放弃", icon: "checkmark.circle", confirm: true)
                }
            case .failure(let e):
                self.fail(e.localizedDescription)
            }
        })
    }

    func fail(_ msg: String) {
        state.phase = .failed(msg)
        hideToast()
        showPanel() // 任何回填方式下，失败都弹面板
    }

    func accept() {
        guard state.phase == .done, let o = origin else { return }
        let text = state.output
        switch o {
        case .terminal:
            let delivered = server.reply(.ok(Data(text.utf8)))
            endSession()
            if delivered {
                showToast("已写回输入框（未发送）", icon: "checkmark.circle.fill")
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                showToast("写回失败：polish-edit 已退出。结果已复制到剪贴板", icon: "exclamationmark.triangle", seconds: 4)
            }
        case .copyOnly:
            copyResult()
        case .gui(let c):
            hidePanel()
            hideToast()
            Task {
                await sleepMs(c.source == .copy ? 150 : 60) // 让焦点回到目标窗口；⌘C 重读需要目标窗口已恢复 key
                let same = NSWorkspace.shared.frontmostApplication?.processIdentifier == c.pid
                let now = same ? await Selection.reread(c) : nil
                guard now == c.text else {
                    state.phase = .verifyFailed(same
                        ? "回填前校验失败：原来的选中内容已变化。为防止误覆盖，没有替换。可按 ⌘C 复制结果后手动粘贴。"
                        : "回填前校验失败：前台应用已切换。为防止误覆盖，没有替换。可按 ⌘C 复制结果后手动粘贴。")
                    showPanel()
                    return
                }
                await Selection.paste(text)
                endSession()
                showToast("已替换", icon: "checkmark.circle.fill")
            }
        }
    }

    func copyResult() {
        guard !state.output.isEmpty, state.phase != .streaming else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.output, forType: .string)
        if case .terminal? = origin { server.reply(.cancel) }
        restoreAutoSelection()
        endSession()
        showToast("已复制到剪贴板，原文未改动", icon: "doc.on.clipboard")
    }

    func cancel() {
        polisher.cancel()
        let wasActive = origin != nil
        dismiss()
        if wasActive { showToast("已取消，原文未改动", icon: "xmark.circle") }
    }

    /// Esc / 放弃：不改原文
    func dismiss() {
        polisher.cancel()
        if case .terminal? = origin { server.reply(.cancel) }
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

    func endSession() {
        origin = nil
        hidePanel()
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

    /// 选区下方（放不下则上方）；取不到选区位置时放在鼠标旁
    func anchor(for size: NSSize) -> NSPoint {
        var rect: CGRect?
        switch origin {
        case .gui(let c)?: rect = c.bounds
        case .copyOnly(let b)?: rect = b
        default: break
        }
        guard let r = rect else {
            let m = NSEvent.mouseLocation
            return NSPoint(x: m.x + 12, y: m.y - size.height - 18)
        }
        let below = NSPoint(x: r.minX, y: r.minY - size.height - 6)
        let vf = (NSScreen.screens.first { $0.frame.contains(r.origin) } ?? NSScreen.main!).visibleFrame
        return below.y >= vf.minY ? below : NSPoint(x: r.minX, y: r.maxY + 6)
    }

    func showPanel() {
        let size = NSSize(width: 460, height: 270)
        if !panel.isVisible { panel.setFrame(clamp(anchor(for: size), size), display: true) }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hidePanel() { panel.orderOut(nil) }

    func showToast(_ text: String, icon: String, sticky: Bool = false, confirm: Bool = false, seconds: Double = 1.8) {
        toastTimer?.invalidate()
        toastConfirm = confirm
        let host = NSHostingView(rootView: ToastView(text: text, icon: icon))
        toast.contentView = host
        let s = host.fittingSize
        toast.setFrame(clamp(anchor(for: s), s), display: true)
        toast.orderFrontRegardless()
        if confirm { toast.makeKey() }
        if !sticky && !confirm {
            toastTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideToast() }
            }
        }
    }

    func hideToast() {
        toastConfirm = false
        toast.orderOut(nil)
    }

    func handleKey(_ e: NSEvent) -> Bool {
        guard panel.isKeyWindow || (toast.isKeyWindow && toastConfirm) else { return false }
        switch Int(e.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if state.copyOnly { copyResult() } else { accept() }
            return true
        case kVK_Escape:
            dismiss()
            return true
        default: break
        }
        guard e.modifierFlags.contains(.command), let ch = e.charactersIgnoringModifiers else { return false }
        if ch == "c" { copyResult(); return true }
        if ch == "," { openSettings(); return true }
        if let n = Int(ch), n >= 1 { switchProfile(n - 1); return true }
        return false
    }

    func openSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Polish 设置"
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
        NSApp.activate(ignoringOtherApps: true)
        settings!.makeKeyAndOrderFront(nil)
        settings!.orderFrontRegardless()
    }
}
