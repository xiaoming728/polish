import AppKit
import Carbon.HIToolbox
import PolishCore
import NaturalLanguage
import SwiftUI

/// 上屏键放行前读候选（跑在 tap 线程）：主动 tap 拦着上屏键时输入法还没收到它，候选窗一定还在，
/// 读取不再和输入法收起候选窗赛跑。只在有未上屏拼音时读，其余按键原样立即放行。
/// 读得到候选窗的输入法，上屏键前没有候选窗即为英文（直接上屏）模式：held.direct
final class CommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _ime: pid_t = 0
    private var _imeID = ""
    private var _known = false
    private var _held: (pinyin: String, list: [String], direct: Bool) = ("", [], false)
    private var pinyin = PinyinBuffer() // 只在 tap 线程读写
    private var lastLetter = Date.distantPast // 只在 tap 线程读写

    static let knownKey = "readableIMEs" // 读到过候选窗的输入法 bundle ID：据此才能把「没有候选窗」判为英文模式

    /// 当前中文输入法；不是中文输入法时 pid 为 0（主线程更新）
    func setIME(_ pid: pid_t, bundleID: String) {
        let known = (UserDefaults.standard.stringArray(forKey: Self.knownKey) ?? []).contains(bundleID)
        lock.withLock { _ime = pid; _imeID = bundleID; _known = known }
    }

    var ime: pid_t { lock.withLock { _ime } }
    /// 当前输入法的候选窗读得到：没有候选窗就是英文模式
    var known: Bool { lock.withLock { _known } }

    /// 读到了候选：记住这个输入法（持久化，重启后第一次就能识别英文模式）
    func learned() {
        let id: String? = lock.withLock {
            guard !_known, !_imeID.isEmpty else { return nil }
            _known = true
            return _imeID
        }
        guard let id else { return }
        let d = UserDefaults.standard
        d.set(Array(Set((d.stringArray(forKey: Self.knownKey) ?? []) + [id])), forKey: Self.knownKey)
    }

    /// 最近一次上屏键前读到的候选；pinyin 与主线程缓冲一致才可用
    var held: (pinyin: String, list: [String], direct: Bool) { lock.withLock { _held } }

    func hold(_ type: CGEventType, _ event: CGEvent) {
        guard type == .keyDown else { return pinyin.reset() }
        guard event.getIntegerValueField(.eventSourceUserData) != Keys.marker else { return }
        let pid = ime
        let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard pid != 0, flags.isEmpty else { return pinyin.reset() }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let k = TypingKey.classify(code: code, char: event.typedCharacter, composing: !pinyin.text.isEmpty)
        if k == .other, !pinyin.text.isEmpty {
            // 候选窗在最后一个字母后约 80ms 内画出；之后仍没有，就是英文模式（直接上屏），不再等
            // shortcut: 输入法候选窗读不到 AX 时既会漏读、也无法识别英文模式；遇到再按输入法单独处理
            let deadline = min(Date().addingTimeInterval(0.08), max(Date(), lastLetter.addingTimeInterval(0.08)))
            let known = self.known
            var list = IME.candidates(pid: pid, deadline: deadline.addingTimeInterval(0.02)).list
            while list.isEmpty, known, Date() < deadline {
                usleep(5000)
                list = IME.candidates(pid: pid, deadline: deadline.addingTimeInterval(0.02)).list
            }
            if !list.isEmpty { learned() }
            let read = (pinyin.text, list, list.isEmpty && known)
            lock.withLock { _held = read }
        }
        if case .letter = k { lastLetter = Date() }
        pinyin.feed(k)
    }
}

/// 输入时中英提示：中文输入法下敲拼音时，在光标上方显示英文（⌥1，默认）和中文（⌥2）两个候选。
/// 选中后先核对输入框，用 Esc 撤销组合态的拼音、退格删掉本句已上屏的字，再粘贴所选文本（choose）。
/// 监听用独立线程上的主动 tap：只有上屏键会被拦到读完候选（CommitGate），处理都异步回主线程；⌥1 / ⌥2 只在有结果时临时注册为 Carbon 热键。
/// 选词上屏的内容和中文标点累积成一句，提示框显示「整句 + 正在敲的词」的英文 / 中文，常驻到点鼠标、切换应用、回车或输入框清空；
/// 这时 ⌥1 / ⌥2 退格删掉整句再粘贴。
@MainActor
final class TypingAssist {
    let state: AppState
    /// 润色流程进行中（预览面板、剪贴板占用）时暂停
    var isBusy: () -> Bool = { false }
    /// 润色面板 / 提示的位置：翻译浮层不能遮挡它们
    var avoid: () -> CGRect? = { nil }
    /// 正在显示的翻译浮层；润色面板据此避让
    var hintFrame: CGRect? { panel.isVisible && panel.alphaValue > 0 ? panel.frame : nil }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapLoop: CFRunLoop?
    nonisolated let gate = CommitGate()
    private var choosing = false
    private var buffer = PinyinBuffer()
    private var debounce: DispatchWorkItem?
    private var candidateRead: DispatchWorkItem?
    private var emptyCheck: DispatchWorkItem?
    private var selectAll = false // 上一个键是 ⌘A
    private let polisher = Polisher()
    private var sentence = "" // 本句已上屏的中英文
    private var sentenceNeedsConversion = false // 没读到候选而暂存的拼音，区别于已确认英文
    private var sentenceIncomplete = false // 终端漏读候选后只展示前文，不能再按整句退格
    private var sentenceDebounce: DispatchWorkItem?
    private let sentencePolisher = Polisher()
    private var sentenceResult: (text: String, t: SentenceTranslation)? // 本句（不含正在敲的词）的翻译
    private var candidates: (pinyin: String, list: [String]) = ("", []) // convert 读到的候选，上屏时取用
    private var reverseText = "" // 反向提示：键盘布局 / 输入法英文模式下本段敲的文字
    private var direct = false // 本段是输入法的英文模式（字母直接上屏），按反向提示处理
    private var lastInput: [pid_t: CGRect] = [:] // 各应用最近一次可信的输入位置：读不到光标和候选窗时沿用
    private var pid: pid_t = 0
    private var hintAnchor: CGRect? // 首次可信的输入位置，本次提示期间固定
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
    private var dismissal = 0

    init(state: AppState) {
        self.state = state
        panel.contentView = NSHostingView(rootView: TypingHintView(model: model))
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIME() }
        }
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
        // 主动 tap 才能在输入法收到上屏键之前读候选；放在独立线程，主线程卡顿不会拖慢全局键盘
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            let me = Unmanaged<TypingAssist>.fromOpaque(info!).takeUnretainedValue()
            me.gate.hold(type, event)
            let copy = event.copy() ?? event // 放行后系统可能复用原事件
            DispatchQueue.main.async { MainActor.assumeIsolated { me.handle(type, copy) } }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            CGRequestListenEventAccess() // 弹出「输入监控」授权
            return false
        }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        let ready = DispatchSemaphore(value: 0)
        var loop: CFRunLoop?
        let thread = Thread {
            loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, src, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Polish typing tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        source = src
        tapLoop = loop
        refreshIME()
        return true
    }

    func stop() {
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
        }
        if let src = source, let loop = tapLoop {
            CFRunLoopRemoveSource(loop, src, .commonModes)
            CFRunLoopStop(loop)
        }
        tap = nil
        source = nil
        tapLoop = nil
        reset()
    }

    /// 告诉 tap 线程当前是不是中文输入法、进程是哪个（TIS 只能在主线程调用）
    private func refreshIME() {
        let ime = chineseInputActive() ? IME.current() : nil
        gate.setIME(ime?.pid ?? 0, bundleID: ime?.bundleID ?? "")
    }

    func reset() {
        buffer.reset()
        reverseText = ""
        direct = false
        model.reverse = false
        debounce?.cancel()
        polisher.cancel()
        clearSentence()
        hide()
    }

    private func clearSentence() {
        sentence = ""
        sentenceNeedsConversion = false
        sentenceIncomplete = false
        model.notice = nil
        candidates = ("", [])
        sentenceDebounce?.cancel()
        sentencePolisher.cancel()
        sentenceResult = nil
        hintAnchor = nil
        imeFrame = nil
        model.pairs = []
    }

    /// 没有正在敲的词：本句为空就收起，否则显示本句的翻译（还没出来时显示等待）
    private func hide() {
        HotKey.unregisterExtra(2)
        HotKey.unregisterExtra(3)
        guard !sentence.isEmpty else {
            hintAnchor = nil
            imeFrame = nil
            return fadeOut()
        }
        let r = sentenceResult?.text == sentence ? sentenceResult?.t : nil
        model.pinyin = sentence
        model.en = r?.en
        model.zh = r.map { sentenceNeedsConversion ? $0.zh ?? sentence : sentence }
        model.pairs = r?.pairs ?? []
        model.error = nil
        model.notice = sentenceIncomplete ? "输入未完整读取，以下仅为前文；按 ⌥P 润色整段" : nil
        show()
        registerKeys()
    }

    private func fadeOut() {
        HotKey.unregisterExtra(2)
        HotKey.unregisterExtra(3)
        dismissal += 1
        let current = dismissal
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.dismissal == current else { return }
                    self.panel.orderOut(nil)
                }
            }
        }
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
        if fieldCleared(code, flags), !sentence.isEmpty { return reset() } // 每个键都要过一遍：记录 ⌘A
        if reverseActive() {
            if direct { buffer.feed(classify(code, flags, event)) } // 切回中文模式时拼音不丢
            return trackReverse(code, flags, event)
        }
        if !reverseText.isEmpty { // 从键盘布局切回了输入法，或首选英文候选的结果已过时：只清反向状态，正在敲的拼音保留（退格计数靠它）
            reverseText = ""
            model.reverse = false
            polisher.cancel()
        }
        // 中文输入法下 Shift+字母：输入法直接上屏大写字母，本段按英文开始（如 Hello）；若输入法其实开始组合，requestReverse 会切回拼音
        if sentence.isEmpty, buffer.text.isEmpty, flags == .maskShift, typedChar(event)?.isLetter == true, chineseInputActive(), reverseAllowed() {
            enterDirect()
            return trackReverse(code, flags, event)
        }
        // 输入法英文模式：上屏键前没有候选窗。本句为空时整段按外文反向提示；句中的英文交给 trackSentence 原样记入
        if sentence.isEmpty, !buffer.text.isEmpty, classify(code, flags, event) == .other, directCommit(), reverseAllowed() {
            enterDirect()
            return trackReverse(code, flags, event)
        }
        trackSentence(code, flags, event) // 先于 feed：feed 遇到空格等会清空拼音
        feed(classify(code, flags, event))
    }

    /// 终端里可能在中文输入法的英文模式下敲 sudo 密码：只处理读得到候选窗的输入，敲的字母不发给模型
    private func inTerminal() -> Bool {
        terminalBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
    }

    /// 输入框被清空就收起整句：⌘A 后删除 / 剪切、⌘⌫ 按键推断（微信等读不到输入框的应用只能这样）；
    /// 其他删除类按键稍后读输入框字数，能读到且为 0 也收起
    private func fieldCleared(_ code: Int, _ flags: CGEventFlags) -> Bool {
        let deletes = code == kVK_Delete || code == kVK_ForwardDelete
        let cut = flags == .maskCommand && code == kVK_ANSI_X
        defer { selectAll = flags == .maskCommand && code == kVK_ANSI_A }
        if (selectAll && ((flags.isEmpty && deletes) || cut)) || (flags == .maskCommand && code == kVK_Delete) {
            Log.write("typing sentence: field cleared by key")
            return true
        }
        if deletes || cut || (flags == .maskCommand && code == kVK_ANSI_Z) {
            emptyCheck?.cancel()
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
                guard let self, !self.sentence.isEmpty, self.buffer.text.isEmpty, let el = Selection.focusedElement() else { return }
                var v: CFTypeRef?
                // 字数而不是整段文本：大文档每次复制全文太贵
                if AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &v) == .success, (v as? Int) == 0 {
                    Log.write("typing sentence: field empty")
                    self.reset()
                }
            } }
            emptyCheck = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
        }
        return false
    }

    private func typedChar(_ event: CGEvent) -> Character? { event.typedCharacter }

    /// 上屏：有拼音时空格 / 数字 / 标点选中候选（标点再跟一个全角标点）；没拼音时标点直接上屏、退格删掉上一个字
    private func trackSentence(_ code: Int, _ flags: CGEventFlags, _ event: CGEvent) {
        guard state.typingAssist, !isBusy(), !choosing else { return }
        if code == kVK_Return, buffer.text.isEmpty || !flags.isEmpty { return clearSentence() }
        guard !sentenceIncomplete, flags.subtracting(.maskShift).isEmpty, !IsSecureEventInputEnabled(), chineseInputActive() else { return }
        if code == kVK_Return {
            // 中文组合态回车确认原始字母，不是提交消息；终端未知字母仍不发送。
            guard !inTerminal() || committed(buffer.highlight) != nil else { return clearSentence() }
            sentence += buffer.text
            sentenceChanged()
            return
        }
        let c = typedChar(event)
        let punct = c.flatMap { chinesePunctuation[$0] }
        var add = ""
        if !buffer.text.isEmpty {
            let digit = flags.isEmpty ? c?.wholeNumberValue.flatMap { (1...9).contains($0) ? $0 : nil } : nil
            let literal = c.flatMap { $0 != "'" && ($0.isNumber || $0.isPunctuation || $0.isSymbol) ? String($0) : nil }
            guard (flags.isEmpty && code == kVK_Space) || digit != nil || literal != nil else { return }
            let pick = digit.map { $0 - 1 } ?? buffer.highlight
            if directCommit() {
                // 英文模式：字母连同这个键（空格、数字、标点）原样上屏，是已确认的英文
                sentence += buffer.text + (c.map(String.init) ?? "")
                return sentenceChanged()
            } else if let word = committed(pick) {
                add = word
            } else if inTerminal() {
                guard !sentence.isEmpty else { return clearSentence() } // 没有可信前文：不处理终端未知输入。
                Log.write("typing sentence: commit unknown in terminal, preserve prefix buf=\(buffer.text.count) held=\(gate.held.pinyin.count)/\(gate.held.list.count) ime=\(gate.ime)")
                // shortcut: 终端漏读后只保留前文，能可靠读取完整输入时恢复整句跟踪
                sentenceIncomplete = true
                sentenceDebounce?.cancel()
                if sentenceResult?.text != sentence { requestSentence("") }
                return
            } else {
                // 没读到候选（打字太快、候选窗已收起）：先记拼音，整句请求时让模型补成中文
                Log.write("typing sentence: commit unknown (pick=\(pick)), keep pinyin buf=\(buffer.text.count) held=\(gate.held.pinyin.count)/\(gate.held.list.count) ime=\(gate.ime)")
                add = buffer.text.replacingOccurrences(of: "'", with: "")
                sentenceNeedsConversion = true
            }
            if digit == nil { add += punct ?? literal ?? "" }
        } else if code == kVK_Delete, flags.isEmpty, !sentence.isEmpty {
            sentence.removeLast()
            return sentence.isEmpty ? clearSentence() : sentenceChanged() // feed 随后 hide 刷新显示
        } else if let c {
            // 终端没有已知中文输入时不记录直输按键，避免把密码交给模型。
            guard !inTerminal() || !sentence.isEmpty else { return }
            if c.isNumber || c.isPunctuation || c.isSymbol || (c == " " && !sentence.isEmpty) {
                add = punct ?? String(c)
            }
        }
        guard !add.isEmpty else { return }
        sentence += add
        sentenceChanged()
    }

    /// 刚上屏的是哪个候选：优先用上屏键放行前读到的（CommitGate），其次 convert / 提前读取的，最后现读
    private func committed(_ index: Int) -> String? {
        let held = gate.held
        let list = held.pinyin == buffer.text && !held.list.isEmpty ? held.list
            : candidates.pinyin == buffer.text ? candidates.list : IME.candidates().list
        return index < list.count ? list[index] : nil
    }

    private func sentenceChanged() {
        pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        sentenceDebounce?.cancel()
        sentencePolisher.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            guard let self, self.buffer.text.isEmpty else { return } // 已经在敲下一个词：由 convert 连同这个词一起请求
            self.requestSentence("")
        } }
        sentenceDebounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    /// 翻译「本句 + tail」（tail：正在敲的词，候选或拼音；没有为空）。结果直接显示成 ⌥1 / ⌥2
    private func requestSentence(_ tail: String, pinyinTail: Bool = false) {
        let s = sentence, pinyin = buffer.text, highlight = buffer.highlight
        let unresolved = sentenceNeedsConversion
        let p = state.current
        let key = KeyStore.apiKey(p)
        if key.isEmpty && !["localhost", "127.0.0.1", "::1"].contains(URL(string: p.baseURL)?.host ?? "") {
            model.error = "未配置 API Key（⌥P 菜单 → 设置）"
            return show()
        }
        let t0 = Date()
        sentencePolisher.start(sentenceProfile(p, state.targetLanguage), apiKey: key, text: s + tail, fast: true, onDelta: { _ in }, onDone: { [weak self] r in
            // 期间上屏了新内容、又敲键或换了候选：结果作废
            guard let self, self.sentence == s, (self.sentenceIncomplete && tail.isEmpty) || (self.buffer.text == pinyin && self.buffer.highlight == highlight), self.sentenceNeedsConversion == unresolved else { return }
            switch r {
            case .success(let out):
                guard let t = parseSentence(out) else { self.model.error = "无法解析模型结果"; break }
                // 本句里没读到候选、先记下的拼音换成模型补全的中文（退格计数要按中文）
                if unresolved, let zh = t.zh {
                    if tail.isEmpty {
                        self.sentence = zh
                        self.sentenceNeedsConversion = false
                    } else if !pinyinTail, zh.hasSuffix(tail) {
                        self.sentence = String(zh.dropLast(tail.count))
                        self.sentenceNeedsConversion = false
                    }
                }
                if tail.isEmpty { self.sentenceResult = (self.sentence, t) }
                self.model.en = t.en
                // 没有拼音时用用户实际打的字，不用模型「改过」的
                self.model.zh = unresolved || pinyinTail ? t.zh ?? self.sentence + tail : s + tail
                self.model.pairs = t.pairs
            case .failure(let e):
                self.model.error = e.localizedDescription
            }
            Log.write("typing sentence len=\(s.count + tail.count) ok=\(self.model.en != nil) pairs=\(self.model.pairs.count) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
            self.show()
            self.registerKeys()
        })
    }

    private func classify(_ code: Int, _ flags: CGEventFlags, _ event: CGEvent) -> TypingKey {
        guard flags.isEmpty, !IsSecureEventInputEnabled(), chineseInputActive() else { return .other }
        return .classify(code: code, char: typedChar(event), composing: !buffer.text.isEmpty)
    }

    private func feed(_ k: TypingKey) {
        guard state.typingAssist, !isBusy(), !choosing else { return }
        if polisher.busy {
            let kind: String = { if case .letter = k { return "letter" }; return "\(k)" }()
            Log.write("typing cancel in-flight by key=\(kind)")
        }
        buffer.feed(k)
        if buffer.text.isEmpty { candidates = ("", []) }
        debounce?.cancel()
        polisher.cancel()
        guard buffer.ready, !sentenceIncomplete else {
            hide()
            return
        }
        pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        // 尽早读一次候选：打字快时空格常在 convert 之前按下，那时再读候选窗已经收起
        let pinyin = buffer.text
        let read = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            guard let self, self.buffer.text == pinyin, self.candidates.pinyin != pinyin else { return }
            let (list, frame) = IME.candidates()
            if !list.isEmpty { self.candidates = (pinyin, list) }
            if let frame { self.imeFrame = frame }
        } }
        candidateRead?.cancel()
        candidateRead = read
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: read)
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

    private func secureFieldFocused() -> Bool {
        guard let el = Selection.focusedElement() else { return false }
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &v) == .success && v as? String == kAXSecureTextFieldSubrole as String
    }

    // MARK: 反向提示：非中文输入（键盘布局、输入法英文模式、其他语言输入法）译回默认语言

    /// 终端里键盘布局下敲的可能是命令或密码，不发给模型
    /// 终端里同样工作：密码提示时终端开启安全输入（Ghostty 自动，Terminal.app 需手动开「安全键盘输入」）则不处理
    private func reverseAllowed() -> Bool {
        state.typingAssist && state.reverseTyping && !isBusy() && !choosing && !IsSecureEventInputEnabled()
    }

    private func reverseActive() -> Bool {
        reverseAllowed() && (direct || !chineseInputActive()) // 键盘布局、其他语言的输入法都译回默认语言
    }

    /// 这次上屏键前没有候选窗：输入法处于英文模式，敲的字母直接上屏
    private func directCommit() -> Bool {
        let held = gate.held
        return held.pinyin == buffer.text && held.direct
    }

    /// 把正在敲的字母转为反向提示的本段文字
    private func enterDirect() {
        Log.write("typing direct: input method in English mode")
        let typed = buffer.text
        reset()
        direct = true
        reverseText = typed
    }

    /// 本段到回车、点鼠标、带 ⌘⌃⌥ 的组合键或方向键等为止；停顿后整段翻译，⌥1 退格删掉本段再粘贴译文
    private func trackReverse(_ code: Int, _ flags: CGEventFlags, _ event: CGEvent) {
        if !direct, !buffer.text.isEmpty || !sentence.isEmpty { reset() } // 从中文输入法切过来
        // shortcut: ⌥e 等死键输入的重音字母也当作结束本段，需要时再跟踪死键状态
        guard flags.subtracting(.maskShift).isEmpty else { return reset() }
        if code == kVK_Delete {
            guard !reverseText.isEmpty else { return }
            reverseText.removeLast()
        } else if let c = typedChar(event), c == " " || c.isLetter || c.isNumber || c.isPunctuation || c.isSymbol {
            reverseText.append(c)
        } else {
            return reset()
        }
        pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        debounce?.cancel()
        polisher.cancel()
        HotKey.unregisterExtra(2) // 旧译文对应的不是现在这段文字
        guard reverseText.filter(\.isLetter).count >= 2 else { return hide() }
        if panel.isVisible {
            model.en = nil
            model.pinyin = reverseText
            show()
        }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.requestReverse() } }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private func requestReverse() {
        if direct, !IME.candidates().list.isEmpty { // 切回了中文模式：正在敲的是拼音
            Log.write("typing direct: back to composing")
            direct = false
            reverseText = ""
            model.reverse = false
            return buffer.ready ? convert() : hide()
        }
        let text = reverseText
        guard !secureFieldFocused() else { return hide() }
        let p = state.current
        let key = KeyStore.apiKey(p)
        model.reverse = true
        model.pinyin = text
        model.en = nil
        model.zh = text // ⌥2 始终是用户敲的原文，不管是不是默认语言
        model.pairs = []
        model.error = key.isEmpty && !["localhost", "127.0.0.1", "::1"].contains(URL(string: p.baseURL)?.host ?? "") ? "未配置 API Key（⌥P 菜单 → 设置）" : nil
        show()
        guard model.error == nil else { return }
        Log.write("typing reverse request len=\(text.count) direct=\(direct)")
        var q = sentenceProfile(p, state.native) // 一段文字比单词长：沿用整句的限长
        q.instruction = reverseInstruction(from: state.targetLanguage, to: state.native)
        let t0 = Date()
        polisher.start(q, apiKey: key, text: text, fast: true, onDelta: { _ in }, onDone: { [weak self] r in
            guard let self, self.reverseText == text else { return } // 期间又敲了键：结果作废
            switch r {
            case .success(let s):
                // 敲的本来就是默认语言时译文与原文相同，照样显示：⌥2 原文始终在
                self.model.en = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'` \n"))
            case .failure(let e):
                self.model.error = e.localizedDescription
            }
            Log.write("typing reverse len=\(text.count) ok=\(self.model.en != nil) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
            self.show()
            self.registerKeys()
        })
    }

    // MARK: 转换与显示

    private func convert() {
        let pinyin = buffer.text
        if secureFieldFocused() { return } // 密码框不发送
        let t0 = Date()
        var p = state.current
        let key = KeyStore.apiKey(p)
        // 读输入法当前高亮的候选：中文不必等模型；英文只需翻译这个词（比拼音推断短、快）
        let highlight = buffer.highlight
        let (list, frame) = IME.candidates()
        if let frame { imeFrame = frame }
        candidates = (pinyin, list)
        if !list.isEmpty { gate.learned() }
        let candidate = buffer.highlight < list.count ? list[buffer.highlight] : nil
        Log.write("typing convert len=\(pinyin.count) highlight=\(buffer.highlight) candidate=\(candidate != nil) readMs=\(Int(Date().timeIntervalSince(t0) * 1000))")
        // 切过的候选已不在当前页、或读不到候选窗：无法确定用户看到的是哪个词，宁可不显示
        // 终端：没有候选窗可能是在输入法英文模式下敲密码，字母绝不发给模型
        if list.isEmpty, gate.known { // 读得到候选窗的输入法却没有候选窗：英文模式
            guard sentence.isEmpty, reverseAllowed() else { return hide() }
            enterDirect()
            return requestReverse()
        }
        if candidate == nil && (buffer.highlight > 0 || inTerminal()) {
            hide()
            return
        }
        // 输入法把英文单词排在当前高亮（敲 hello 时首选是 hello）：用户在敲英文，译回默认语言；⌥1 用 Esc 撤销拼音再粘贴
        if let c = candidate, sentence.isEmpty, c.contains(where: \.isLetter), c.unicodeScalars.allSatisfy(\.isASCII), reverseAllowed() {
            reverseText = pinyin
            return requestReverse()
        }
        HotKey.unregisterExtra(2)
        HotKey.unregisterExtra(3)
        if !sentence.isEmpty { // 句中：整句连同这个词一起翻译
            model.pinyin = sentence + pinyin
            model.en = nil
            model.zh = candidate.map { sentence + $0 }
            model.pairs = []
            model.error = nil
            show()
            registerKeys()
            return requestSentence(candidate ?? pinyin.replacingOccurrences(of: "'", with: ""), pinyinTail: candidate == nil)
        }
        model.pinyin = pinyin
        model.en = nil
        model.zh = candidate
        model.pairs = []
        // 本地词典收录的词直接出英文，不走网络、不需要 Key；短语和未收录的词再交给模型
        if state.localDictionary, state.targetLanguage == .english, let c = candidate, let en = LocalDictionary.english(c) {
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
        p.instruction = candidate == nil ? typingInstruction(state.targetLanguage) : translateInstruction(state.targetLanguage)
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
        guard panel.isVisible, panel.alphaValue > 0, !sentenceNeedsConversion, !sentenceIncomplete else { return } // 本句里还有没补全的拼音：不知道该退几格
        if model.en != nil { HotKey.registerExtra(2, code: kVK_ANSI_1, mods: optionKey) { [weak self] in self?.choose(english: true) } }
        if model.zh != nil { HotKey.registerExtra(3, code: kVK_ANSI_2, mods: optionKey) { [weak self] in self?.choose(english: false) } }
    }

    private func show() {
        dismissal += 1 // 新结果出现时，旧淡出的完成回调不能隐藏它
        model.language = model.reverse ? state.native : state.targetLanguage
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        let host = panel.contentView as! NSHostingView<TypingHintView>
        // @Published 的布局更新是异步的，先同步渲染，否则成功结果会按等待态高度定位。
        host.rootView = TypingHintView(model: model)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard let origin = origin(for: size) else { fadeOut(); return }
        panel.setContentSize(size)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    /// 首次显示时按输入位置定位；等待和结果共用锚点，本次输入期间不跟随光标。
    private func origin(for size: NSSize) -> NSPoint? {
        if hintAnchor == nil {
            let el = Selection.focusedElement()
            let caret = inTerminal() ? nil : el.flatMap(Selection.caretRect)
            let currentIME = IME.candidates().frame
            if let frame = currentIME { imeFrame = frame }
            // 候选窗在输入行下方：往上补一行高，给输入文字留出空间。
            let ime = imeFrame.map { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height + 22) }
            let currentCaret = inTerminal() ? nil : el.flatMap(Selection.bounds)
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            if let found = currentIME != nil ? ime : currentCaret ?? ime ?? caret {
                hintAnchor = found
                lastInput[front] = found
            } else {
                // 英文模式没有候选窗、微信和终端又读不到光标：沿用这个应用上次的输入位置，没有再按窗口底部估算
                hintAnchor = lastInput[front] ?? windowBottom(front)
            }
            Log.write("typing anchor fixed=\(hintAnchor != nil) terminal=\(inTerminal())")
        }
        guard let anchor = hintAnchor else { return nil }
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main!
        return typingHintFrame(size: size, anchor: anchor, visibleFrame: screen.visibleFrame, avoid: avoid())?.origin
    }

    /// shortcut: 按聚焦窗口底部 110pt 当作输入区（微信、终端 Agent 的输入框都在底部）；能读到真实输入位置后改用 lastInput
    private func windowBottom(_ pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        var w: CFTypeRef?
        guard pid != 0, AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w) == .success, let w,
              let f = Selection.frame(w as! AXUIElement) else { return nil }
        return CGRect(x: f.minX + 16, y: f.minY, width: 1, height: min(110, f.height))
    }

    // MARK: 选择

    private func choose(english: Bool) {
        guard !choosing, !sentenceIncomplete, let text = english ? model.en : model.zh, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            reset()
            return
        }
        // 已上屏、要退格删掉的：本句，或反向提示里直接上屏的英文；组合态的拼音（含首选英文候选）用 Esc 撤销，不按键数退格
        let committed = model.reverse ? (direct ? reverseText : "") : sentence
        let pinyinKeys = model.reverse ? (direct ? 0 : reverseText.count) : buffer.text.count
        Log.write("typing choose english=\(english) committed=\(committed.count) pinyin=\(pinyinKeys) len=\(text.count)")
        reset()
        choosing = true
        Task {
            defer { choosing = false }
            // 终端（AX value 是整屏回滚）和不暴露焦点的应用（微信 4.x）只能信本句记录；文本控件却读不到内容是偶发失败，重试一次仍不行就不删
            let el = inTerminal() ? nil : Selection.focusedElement()
            var before = el.flatMap(Selection.textBeforeCaret)
            if before == nil, let el, Selection.role(el).map(Selection.editableRoles.contains) == true {
                await sleepMs(30)
                before = Selection.textBeforeCaret(el)
                guard before != nil else { return copyOnly(text) }
            }
            // 读得到输入框就先核对；对不上（漏记、光标移走、输入法把拼音换成了别的字）一个字都不删
            guard let count = replaceDeletes(before: before, committed: committed, pinyinKeys: pinyinKeys) else { return copyOnly(text) }
            if pinyinKeys > 0 {
                // 候选窗还在才能确定 Esc 会被输入法吃掉，而不是落到应用里（关掉对话框等）
                guard let ime = IME.current(), IME.candidates(pid: ime.pid, deadline: Date().addingTimeInterval(0.1)).window != nil else { return copyOnly(text) }
                Keys.post(kVK_Escape, [])
                await sleepMs(30)
                if let el, before != nil { // Esc 后光标前必须恰好以要删的字结尾，防止输入法把 Esc 当成上屏
                    let end = Date().addingTimeInterval(0.2)
                    var ok = false
                    while !ok, Date() < end {
                        ok = Selection.textBeforeCaret(el).flatMap { replaceDeletes(before: $0, committed: committed, pinyinKeys: 0) } == count
                        if !ok { await sleepMs(25) }
                    }
                    guard ok else { return copyOnly(text) }
                }
            }
            // 期间切走了应用：退格会落到别处
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return copyOnly(text) }
            for _ in 0..<count {
                Keys.post(kVK_Delete, [])
                await sleepMs(8)
            }
            await sleepMs(40)
            await Selection.paste(text)
        }
    }

    /// 不替换：结果放进剪贴板，提示框说明后淡出
    private func copyOnly(_ text: String) {
        Log.write("typing choose: field mismatch, copied only")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.pinyin = ""
        model.en = nil
        model.zh = nil
        model.pairs = []
        model.notice = nil
        model.error = tr("已复制，未替换", "Copied, not replaced")
        show()
        let current = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in MainActor.assumeIsolated {
            guard let self, self.dismissal == current else { return }
            self.fadeOut()
        } }
    }
}

@MainActor
final class HintModel: ObservableObject {
    @Published var pinyin = ""
    @Published var en: String?
    @Published var zh: String?
    @Published var error: String?
    @Published var notice: String?
    @Published var pairs: [SentencePair] = [] // 中英对应的词，同色显示
    @Published var language = TypingLanguage.english // ⌥1 译文的语言
    @Published var reverse = false // 反向提示：⌥1 译成默认语言，⌥2 是用户敲的原文
}

struct TypingHintView: View {
    @ObservedObject var model: HintModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let notice = model.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if model.en != nil || model.zh != nil {
                if let en = model.en { row("⌥1", en, primary: true) } else { pending("⌥1") }
                if let zh = model.zh { row("⌥2", zh, primary: false) } else if !model.reverse { pending("⌥2") }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ProgressView().controlSize(.small).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("正在翻译").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Text(model.pinyin).font(.system(size: 13)).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PanelBackground(cornerRadius: 16))
    }

    func pending(_ key: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(model.notice == nil ? key : (key == "⌥1" ? model.language.name : "中文")).font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
            ProgressView().controlSize(.mini).padding(.top, 2)
            Text("翻译中…").font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    func row(_ key: String, _ text: String, primary: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(model.notice == nil ? key : (key == "⌥1" ? model.language.name : "中文")).font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(primary ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
            VStack(alignment: .leading, spacing: 3) {
                Text(model.pairs.isEmpty ? (primary ? annotated(text) : AttributedString(text)) : colored(text, primary: primary))
                    .font(.system(size: 13, weight: primary ? .semibold : .regular))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if primary && model.language == .english {
                    Text(legend(text)).font(.system(size: 10)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .brown, .red]

    private func colored(_ text: String, primary: Bool) -> AttributedString {
        var result = primary ? annotated(text) : AttributedString(text)
        for word in colorRanges(text, model.pairs.map { primary ? $0.en : $0.zh }, wholeWords: primary && model.language.spaced) {
            if let range = Range(word.range, in: result) {
                result[range].foregroundColor = Self.palette[word.index % Self.palette.count]
            }
        }
        return result
    }

    private func annotation(_ tag: NLTag) -> (String, Color)? {
        switch tag {
        case .noun: return ("名词", .blue)
        case .verb: return ("动词", .orange)
        case .adjective: return ("形容词", .purple)
        case .adverb: return ("副词", .pink)
        case .pronoun: return ("代词", .teal)
        case .preposition: return ("介词", .green)
        case .conjunction: return ("连词", .indigo)
        case .determiner: return ("限定词", .secondary)
        case .number: return ("数词", .brown)
        case .interjection: return ("感叹词", .red)
        case .particle: return ("助词", .mint)
        default: return nil
        }
    }

    private func annotated(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard model.language == .english else { return result } // 词性标注只做英文
        for word in englishWordTags(text) {
            if let (_, color) = annotation(word.tag), let range = Range(word.range, in: result) {
                result[range].foregroundColor = color
            }
        }
        return result
    }

    private func legend(_ text: String) -> AttributedString {
        var result = AttributedString()
        let pairs = colorRanges(text, model.pairs.map(\.en), wholeWords: true)
        // 整句逐词分析：对应关系只决定颜色，不决定英文词性。
        for word in englishWordTags(text) {
            guard let (label, color) = annotation(word.tag) else { continue }
            var item = AttributedString((result.characters.isEmpty ? "" : "  ·  ") + text[word.range] + "（" + label + "）")
            let pair = pairs.first { $0.range.overlaps(word.range) }
            item.foregroundColor = pair.map { Self.palette[$0.index % Self.palette.count] } ?? color
            result += item
        }
        return result
    }
}
