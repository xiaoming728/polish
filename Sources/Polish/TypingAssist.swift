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
    private var imeFrame: CGRect? // 输入法候选窗：读不到光标的应用（微信等）用它定位
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
            // 只在真的换到另一个普通应用时重置：系统授权弹窗、输入法候选窗等后台进程被激活不算；
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
        if !buffer.text.isEmpty, code == kVK_RightArrow { return .candidateNext }
        if !buffer.text.isEmpty, code == kVK_LeftArrow { return .candidatePrev }
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
        // 切换候选：等输入法重绘后立即换算；打字：流畅打字按键间隔约 150ms，250ms 仍能合并连续输入
        let delay = (k == .candidateNext || k == .candidatePrev) ? 0.1 : 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
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
        let t0 = Date()
        var p = state.current
        let key = KeyStore.apiKey(p)
        // 读输入法当前高亮的候选：中文不必等模型；英文只需翻译这个词（比拼音推断短、快）
        let highlight = buffer.highlight
        let (list, frame) = IME.candidates()
        imeFrame = frame
        let candidate = buffer.highlight < list.count ? list[buffer.highlight] : nil
        Log.write("typing convert len=\(pinyin.count) highlight=\(buffer.highlight) candidate=\(candidate != nil) readMs=\(Int(Date().timeIntervalSince(t0) * 1000))")
        // 切过的候选已不在当前页、或读不到候选窗：无法确定用户看到的是哪个词，宁可不显示
        if candidate == nil && buffer.highlight > 0 {
            hide()
            return
        }
        HotKey.unregisterExtra(2)
        HotKey.unregisterExtra(3)
        model.pinyin = pinyin
        model.en = nil
        model.zh = candidate
        // 本地词典收录的词直接出英文，不走网络、不需要 Key；短语和未收录的词再交给模型
        if state.localDictionary, let c = candidate, let en = LocalDictionary.english(c) {
            model.en = en
            model.error = nil
            show()
            registerKeys()
            Log.write("typing dictionary hit ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
            return
        }
        model.error = key.isEmpty && !["localhost", "127.0.0.1", "::1"].contains(URL(string: p.baseURL)?.host ?? "") ? "未配置 API Key（⌥P 菜单 → 设置）" : nil
        show()
        if candidate != nil { registerKeys() }
        guard model.error == nil else { return }
        p.instruction = candidate == nil ? typingInstruction : translateInstruction
        polisher.start(p, apiKey: key, text: candidate ?? pinyin, fast: true, onDelta: { _ in }, onDone: { [weak self] r in
            guard let self, self.buffer.text == pinyin, self.buffer.highlight == highlight else { return } // 期间又敲键或换了候选：结果作废
            switch r {
            case .success(let s):
                if candidate != nil {
                    self.model.en = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'` \n"))
                } else if let c = parseConversion(s) {
                    self.model.en = c.en
                    self.model.zh = c.zh
                } else {
                    self.model.error = "无法解析模型结果"
                }
            case .failure(let e):
                self.model.error = e.localizedDescription
            }
            self.show()
            Log.write("typing result ok=\(self.model.en != nil && self.model.zh != nil) error=\(self.model.error ?? "-") ms=\(Int(Date().timeIntervalSince(t0) * 1000)) frame=\(self.panel.frame)")
            self.registerKeys()
        })
    }

    /// 只有对应结果已经出来时才占用 ⌥1 / ⌥2；其余时间不影响它们原本的输入
    private func registerKeys() {
        if model.en != nil { HotKey.registerExtra(2, code: kVK_ANSI_1, mods: optionKey) { [weak self] in self?.choose(english: true) } }
        if model.zh != nil { HotKey.registerExtra(3, code: kVK_ANSI_2, mods: optionKey) { [weak self] in self?.choose(english: false) } }
    }

    private func show() {
        let host = panel.contentView as! NSHostingView<TypingHintView>
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size))
        panel.orderFrontRegardless()
    }

    /// 光标上方（输入法候选窗通常在下方）；取不到光标位置时按候选窗推算，再不行放在鼠标上方
    private func origin(for size: NSSize) -> NSPoint {
        let el = Selection.focusedElement()
        let caret = el.flatMap(Selection.caretRect)
        // 候选窗贴在光标那一行下方：往上补一行高，提示就落在光标行上方而不盖住它
        let ime = imeFrame.map { CGRect(x: $0.minX, y: $0.minY, width: 1, height: $0.height + 22) }
        Log.write("typing anchor=\(caret != nil ? "caret" : ime != nil ? "ime" : "mouse") role=\(el.flatMap(Selection.role) ?? "nil") caret=\(caret.map { "\($0)" } ?? "-") ime=\(imeFrame.map { "\($0)" } ?? "-")")
        let anchor = caret ?? ime ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        var o = NSPoint(x: anchor.minX, y: anchor.maxY + 6)
        if o.y + size.height > vf.maxY { o.y = anchor.minY - size.height - 6 }
        o.x = min(max(o.x, vf.minX + 4), vf.maxX - size.width - 4)
        return o
    }

    // MARK: 选择

    private func choose(english: Bool) {
        guard !choosing, let text = english ? model.en : model.zh, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            reset()
            return
        }
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
    @Published var en: String?
    @Published var zh: String?
    @Published var error: String?
}

struct TypingHintView: View {
    @ObservedObject var model: HintModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if model.en != nil || model.zh != nil {
                if let en = model.en { row("⌥1", en, primary: true) } else { pending("⌥1") }
                if let zh = model.zh { row("⌥2", zh, primary: false) } else { pending("⌥2") }
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

    func pending(_ key: String) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            ProgressView().controlSize(.mini)
        }
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
