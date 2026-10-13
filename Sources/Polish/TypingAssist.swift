import AppKit
import Carbon.HIToolbox
import PolishCore
import SwiftUI

/// 输入时中英提示：中文输入法下敲拼音时，在光标上方显示英文（⌥1，默认）和中文（⌥2）两个候选。
/// 选中后用退格撤销刚敲的拼音键（候选态与已上屏两种情况都适用），再粘贴所选文本。
/// 监听用 listen-only tap：不拦截、不阻塞任何按键；⌥1 / ⌥2 只在有结果时临时注册为 Carbon 热键。
@MainActor
final class TypingAssist {
    let state: AppState
    /// 润色流程进行中（预览面板、剪贴板占用）时暂停
    var isBusy: () -> Bool = { false }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var choosing = false
    private var buffer = PinyinBuffer()
    private var debounce: DispatchWorkItem?
    private let polisher = Polisher()
    private var pid: pid_t = 0
    private let panel: NSPanel = {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true // 只显示，不抢焦点、不接收点击：用户还在打字
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }()
    private let model = HintModel()

    init(state: AppState) {
        self.state = state
        panel.contentView = NSHostingView(rootView: TypingHintView(model: model))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            // 只在真的换到另一个普通应用时重置：钥匙串确认框、输入法候选窗等后台进程被激活不算；
            // 提示框首次弹出时系统会对当前应用重发激活通知，也不算（实测 TextEdit）
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let app, app.activationPolicy == .regular else { return }
            MainActor.assumeIsolated {
                guard let self, app.processIdentifier != self.pid else { return }
                Log.write("typing reset: activate \(app.bundleIdentifier ?? "?")")
                self.reset()
            }
        }
    }

    var running: Bool { tap != nil }

    /// 开启监听；失败（缺少权限）返回 false
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        // 没有「输入监控」权限时 listen-only tap 也能创建，但收不到任何按键：先检查，避免静默失效
        guard CGPreflightListenEventAccess() else {
            CGRequestListenEventAccess()
            return false
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            let me = Unmanaged<TypingAssist>.fromOpaque(info!).takeUnretainedValue()
            MainActor.assumeIsolated { me.handle(type, event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            CGRequestListenEventAccess() // 弹出「输入监控」授权
            return false
        }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        source = src
        return true
    }

    func stop() {
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
        }
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        source = nil
        reset()
    }

    func reset() {
        buffer.reset()
        debounce?.cancel()
        polisher.cancel()
        hide()
    }

    private func hide() {
        panel.orderOut(nil)
        HotKey.unregisterExtra(2)
        HotKey.unregisterExtra(3)
    }

    // MARK: 事件

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == Keys.marker { return } // 自己合成的
        guard type == .keyDown else {
            Log.write("typing reset: event type=\(type.rawValue)")
            reset() // 点鼠标：光标可能已移动
            return
        }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        // ⌥1 / ⌥2 由热键处理（会被热键吞掉、不进应用）；这里不能把它当成「结束输入」清掉结果
        if panel.isVisible, flags == .maskAlternate, code == kVK_ANSI_1 || code == kVK_ANSI_2 { return }
        feed(classify(code, flags, event))
    }

    /// 终端里可能在中文输入法的英文模式下敲 sudo 密码，不处理
    private func excludedApp() -> Bool {
        terminalBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
    }

    private func classify(_ code: Int, _ flags: CGEventFlags, _ event: CGEvent) -> TypingKey {
        guard flags.isEmpty, !IsSecureEventInputEnabled(), chineseInputActive(), !excludedApp() else { return .other }
        if code == kVK_Delete { return .backspace }
        var len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &chars)
        guard len == 1, let scalar = Unicode.Scalar(chars[0]) else { return .other }
        let c = Character(scalar)
        if c == "'" { return .apostrophe }
        return ("a"..."z").contains(c) ? .letter(c) : .other
    }

    private func feed(_ k: TypingKey) {
        guard state.typingAssist, !isBusy(), !choosing else { return }
        if polisher.busy {
            let kind: String = { if case .letter = k { return "letter" }; return "\(k)" }()
            Log.write("typing cancel in-flight by key=\(kind)")
        }
        buffer.feed(k)
        debounce?.cancel()
        polisher.cancel()
        guard buffer.ready else {
            hide()
            return
        }
        pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.convert() } }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    /// 中文输入法（输入模式 / 输入法，语言为中文）才处理；ABC 等键盘布局下字母就是英文本身
    private func chineseInputActive() -> Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let typePtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue() as String
        guard type != (kTISTypeKeyboardLayout as String),
              let langPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return false }
        let langs = Unmanaged<CFArray>.fromOpaque(langPtr).takeUnretainedValue() as? [String] ?? []
        return langs.first?.hasPrefix("zh") == true
    }

    // MARK: 转换与显示

    private func convert() {
        let pinyin = buffer.text
        // 密码框不发送
        if let el = Selection.focusedElement() {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &v) == .success, v as? String == kAXSecureTextFieldSubrole as String {
                return
            }
        }
        var p = state.current
        p.instruction = typingInstruction
        let key = Keychain.apiKey(p)
        Log.write("typing convert len=\(pinyin.count)")
        model.pinyin = pinyin
        model.result = nil
        model.error = key.isEmpty && !["localhost", "127.0.0.1", "::1"].contains(URL(string: p.baseURL)?.host ?? "") ? "未配置 API Key（⌥P 菜单 → 设置）" : nil
        show()
        guard model.error == nil else { return }
        polisher.start(p, apiKey: key, text: pinyin, onDelta: { _ in }, onDone: { [weak self] r in
            guard let self, self.buffer.text == pinyin else { return } // 期间又敲了键：结果作废
            switch r {
            case .success(let s):
                if let c = parseConversion(s) { self.model.result = c } else { self.model.error = "无法解析模型结果" }
            case .failure(let e):
                self.model.error = e.localizedDescription
            }
            self.show()
            Log.write("typing result ok=\(self.model.result != nil) error=\(self.model.error ?? "-") frame=\(self.panel.frame)")
            // 只有出结果时才占用 ⌥1 / ⌥2；其余时间不影响它们原本的输入
            if self.model.result != nil {
                HotKey.registerExtra(2, code: kVK_ANSI_1, mods: optionKey) { [weak self] in self?.choose(english: true) }
                HotKey.registerExtra(3, code: kVK_ANSI_2, mods: optionKey) { [weak self] in self?.choose(english: false) }
            }
        })
    }

    private func show() {
        let host = panel.contentView as! NSHostingView<TypingHintView>
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size))
        panel.orderFrontRegardless()
    }

    /// 光标上方（输入法候选窗通常在下方）；取不到光标位置时放在鼠标上方
    private func origin(for size: NSSize) -> NSPoint {
        let el = Selection.focusedElement()
        let caret = el.flatMap(Selection.caretRect)
        Log.write("typing anchor=\(caret == nil ? "mouse" : "caret") role=\(el.flatMap(Selection.role) ?? "nil")")
        let anchor = caret ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        var o = NSPoint(x: anchor.minX, y: anchor.maxY + 6)
        if o.y + size.height > vf.maxY { o.y = anchor.minY - size.height - 6 }
        o.x = min(max(o.x, vf.minX + 4), vf.maxX - size.width - 4)
        return o
    }

    // MARK: 选择

    private func choose(english: Bool) {
        guard !choosing, let r = model.result, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            reset()
            return
        }
        let text = english ? r.en : r.zh
        let count = buffer.text.count
        Log.write("typing choose english=\(english) backspaces=\(count) len=\(text.count)")
        reset()
        choosing = true
        Task {
            // shortcut: 按「敲了几个键就退几格」撤销拼音；输入法若在组合态吞键会多删光标前文字，常规拼音下一一对应
            for _ in 0..<count {
                Keys.post(kVK_Delete, [])
                await sleepMs(8)
            }
            await sleepMs(40)
            await Selection.paste(text)
            choosing = false
        }
    }
}

@MainActor
final class HintModel: ObservableObject {
    @Published var pinyin = ""
    @Published var result: Conversion?
    @Published var error: String?
}

struct TypingHintView: View {
    @ObservedObject var model: HintModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if let r = model.result {
                row("⌥1", r.en, primary: true)
                row("⌥2", r.zh, primary: false)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.pinyin).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: 420, alignment: .leading)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }

    func row(_ key: String, _ text: String, primary: Bool) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(primary ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(text).font(.system(size: 13, weight: primary ? .semibold : .regular)).lineLimit(2)
        }
    }
}
