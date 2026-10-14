import AppKit
import Carbon.HIToolbox
import PolishCore
import SwiftUI

/// 输入时中英提示：中文输入法下敲拼音时，在光标上方显示英文（⌥1，默认）和中文（⌥2）两个候选。
/// 选中后用退格撤销刚敲的拼音键（候选态与已上屏两种情况都适用），再粘贴所选文本。
/// 监听用 listen-only tap：不拦截、不阻塞任何按键；⌥1 / ⌥2 只在有结果时临时注册为 Carbon 热键。
/// 选词上屏的内容和中文标点累积成一句，整句翻译常驻在提示框里，直到点鼠标、切换应用或回车。
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
    private var sentence = "" // 本句已上屏的中文
    private var sentenceDebounce: DispatchWorkItem?
    private let sentencePolisher = Polisher()
    private var candidates: (pinyin: String, list: [String]) = ("", []) // convert 读到的候选，上屏时取用
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
        clearSentence()
        hide()
    }

    private func clearSentence() {
        sentence = ""
        sentenceDebounce?.cancel()
        sentencePolisher.cancel()
        model.sentence = ""
        model.translation = nil
        model.sentenceError = nil
    }

    /// 收起单词提示；本句还有内容时面板保留，只显示整句
    private func hide() {
        HotKey.unregisterExtra(2)
        HotKey.unregisterExtra(3)
        guard !sentence.isEmpty else { return panel.orderOut(nil) }
        model.pinyin = ""
        model.en = nil
        model.zh = nil
        model.error = nil
        show()
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
        trackSentence(code, flags, event) // 先于 feed：feed 遇到空格等会清空拼音
        feed(classify(code, flags, event))
    }

    /// 终端里可能在中文输入法的英文模式下敲 sudo 密码，不处理
    private func excludedApp() -> Bool {
        terminalBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
    }

    private func typedChar(_ event: CGEvent) -> Character? {
        var len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &chars)
        return len == 1 ? Unicode.Scalar(chars[0]).map(Character.init) : nil
    }

    /// 上屏：有拼音时空格 / 数字 / 标点选中候选（标点再跟一个全角标点）；没拼音时标点直接上屏、退格删掉上一个字
    private func trackSentence(_ code: Int, _ flags: CGEventFlags, _ event: CGEvent) {
        guard state.typingAssist, !isBusy(), !choosing else { return }
        if code == kVK_Return { return clearSentence() } // 回车：消息已发出或换了行，开始新的一句
        guard flags.subtracting(.maskShift).isEmpty, !IsSecureEventInputEnabled(), chineseInputActive(), !excludedApp() else { return }
        let c = typedChar(event)
        let punct = c.flatMap { chinesePunctuation[$0] }
        var add = ""
        if !buffer.text.isEmpty {
            let digit = flags.isEmpty ? c?.wholeNumberValue.flatMap { (1...9).contains($0) ? $0 : nil } : nil
            guard (flags.isEmpty && code == kVK_Space) || digit != nil || punct != nil else { return }
            let pick = digit.map { $0 - 1 } ?? buffer.highlight
            guard let word = committed(pick) else {
                Log.write("typing sentence: commit unknown (pick=\(pick))")
                return
            }
            add = word
        } else if code == kVK_Delete, flags.isEmpty, !sentence.isEmpty {
            sentence.removeLast()
            return sentence.isEmpty ? clearSentence() : sentenceChanged()
        }
        add += punct ?? ""
        guard !add.isEmpty else { return }
        sentence += add
        sentenceChanged()
    }

    /// 刚上屏的是哪个候选：用 convert 读到的；按键太快还没读到就现读（输入法此时多半还没收起候选窗）
    private func committed(_ index: Int) -> String? {
        let list = candidates.pinyin == buffer.text ? candidates.list : IME.candidates().list
        if index < list.count { return list[index] }
        // 读不到候选窗（用的是模型推断的中文）：只有首选可信
        return index == 0 && list.isEmpty && model.pinyin == buffer.text ? model.zh : nil
    }

    private func sentenceChanged() {
        sentenceDebounce?.cancel()
        sentencePolisher.cancel()
        model.sentence = sentence
        model.translation = nil
        model.sentenceError = nil
        show()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.translateSentence() } }
        sentenceDebounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func translateSentence() {
        let s = sentence
        let p = state.current
        let key = KeyStore.apiKey(p)
        if key.isEmpty && !["localhost", "127.0.0.1", "::1"].contains(URL(string: p.baseURL)?.host ?? "") {
            model.sentenceError = "未配置 API Key（⌥P 菜单 → 设置）"
            return show()
        }
        let t0 = Date()
        sentencePolisher.start(sentenceProfile(p), apiKey: key, text: s, fast: true, onDelta: { _ in }, onDone: { [weak self] r in
            guard let self, self.sentence == s else { return } // 期间又上屏了新内容：结果作废
            switch r {
            case .success(let out):
                if let t = parseSentence(out) { self.model.translation = t } else { self.model.sentenceError = "无法解析模型结果" }
            case .failure(let e):
                self.model.sentenceError = e.localizedDescription
            }
            Log.write("typing sentence len=\(s.count) ok=\(self.model.translation != nil) pairs=\(self.model.translation?.pairs.count ?? 0) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
            self.show()
        })
    }

    private func classify(_ code: Int, _ flags: CGEventFlags, _ event: CGEvent) -> TypingKey {
        guard flags.isEmpty, !IsSecureEventInputEnabled(), chineseInputActive(), !excludedApp() else { return .other }
        if code == kVK_Delete { return .backspace }
        if !buffer.text.isEmpty, code == kVK_RightArrow { return .candidateNext }
        if !buffer.text.isEmpty, code == kVK_LeftArrow { return .candidatePrev }
        guard let c = typedChar(event) else { return .other }
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
        candidates = (pinyin, list)
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
        buffer.reset()
        debounce?.cancel()
        polisher.cancel()
        sentence += text // 选中的内容也算本句上屏
        sentenceChanged()
        hide()
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
    @Published var sentence = ""
    @Published var translation: SentenceTranslation?
    @Published var sentenceError: String?
}

struct TypingHintView: View {
    @ObservedObject var model: HintModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.sentence.isEmpty { sentenceView }
            if !model.sentence.isEmpty && !model.pinyin.isEmpty { Divider() }
            if model.pinyin.isEmpty {
            } else if let e = model.error {
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

    static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .brown, .red]

    /// 整句：中文、英文里对应的词同色
    @ViewBuilder var sentenceView: some View {
        let pairs = model.translation?.pairs ?? []
        line(model.sentence, pairs.map(\.zh), wholeWords: false, weight: .regular)
        if let t = model.translation {
            line(t.en, pairs.map(\.en), wholeWords: true, weight: .semibold)
        } else if let e = model.sentenceError {
            Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    /// 面板整体 fixedSize（按内容定大小），文本拿不到宽度上限不会换行：先量出单行宽度，超过 400 就固定 400 宽换行
    func line(_ text: String, _ parts: [String], wholeWords: Bool, weight: Font.Weight) -> some View {
        let w = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: weight == .semibold ? .semibold : .regular)]).width
        return Text(colored(text, parts, wholeWords: wholeWords)).font(.system(size: 13, weight: weight))
            .frame(width: min(ceil(w) + 2, 400), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    func colored(_ text: String, _ parts: [String], wholeWords: Bool) -> AttributedString {
        var out = AttributedString()
        var at = text.startIndex
        for (r, i) in colorRanges(text, parts, wholeWords: wholeWords) {
            out += AttributedString(text[at..<r.lowerBound])
            var seg = AttributedString(text[r])
            seg.foregroundColor = Self.palette[i % Self.palette.count]
            out += seg
            at = r.upperBound
        }
        return out + AttributedString(text[at...])
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
