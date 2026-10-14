import AppKit
import Carbon.HIToolbox
import CoreServices
import PolishCore

// MARK: - 全局快捷键（Carbon，无需权限）

struct HotKeySpec: Codable, Equatable {
    var code: UInt32
    var mods: UInt32
    var name: String
    static let standard = HotKeySpec(code: UInt32(kVK_ANSI_P), mods: UInt32(optionKey), name: "⌥P")
}

enum HotKey {
    nonisolated(unsafe) static var handler: (() -> Void)?
    nonisolated(unsafe) static var ref: EventHotKeyRef?
    /// 临时热键（id ≥ 2），如输入提示显示时的 ⌥1 / ⌥2
    nonisolated(unsafe) static var extra: [UInt32: (ref: EventHotKeyRef, run: () -> Void)] = [:]

    static func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { id == 1 ? HotKey.handler?() : HotKey.extra[id]?.run() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func registerExtra(_ id: UInt32, code: Int, mods: Int, _ run: @escaping () -> Void) {
        unregisterExtra(id)
        var r: EventHotKeyRef?
        if RegisterEventHotKey(UInt32(code), UInt32(mods), EventHotKeyID(signature: 0x504C_5348, id: id), GetApplicationEventTarget(), 0, &r) == noErr, let r {
            extra[id] = (r, run)
        }
    }

    static func unregisterExtra(_ id: UInt32) {
        if let e = extra.removeValue(forKey: id) { UnregisterEventHotKey(e.ref) }
    }

    /// 注册失败（多为被其他应用占用）返回 false，且不保留任何注册
    static func register(_ s: HotKeySpec) -> Bool {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        return RegisterEventHotKey(s.code, s.mods, EventHotKeyID(signature: 0x504C_5348, id: 1), GetApplicationEventTarget(), 0, &ref) == noErr
    }

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}

// MARK: - 合成按键

enum Keys {
    /// 标记本 app 合成的按键，事件监听据此忽略
    static let marker: Int64 = 0x504C_5348

    /// privateState 事件源 + 显式 flags：用户此时可能还按着 ⌥，不能让它混进投递的按键
    static func post(_ key: Int, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: down)
            e?.flags = flags
            e?.setIntegerValueField(.eventSourceUserData, value: marker)
            e?.post(tap: .cghidEventTap)
        }
    }
    static func copy() { post(kVK_ANSI_C, .maskCommand) }
    static func paste() { post(kVK_ANSI_V, .maskCommand) }
    static func send(_ k: TerminalKey) {
        switch k {
        case .ctrlG: post(kVK_ANSI_G, .maskControl)
        case .ctrlX: post(kVK_ANSI_X, .maskControl)
        case .ctrlXCtrlE: post(kVK_ANSI_X, .maskControl); post(kVK_ANSI_E, .maskControl)
        case .ctrlXE: post(kVK_ANSI_X, .maskControl); post(kVK_ANSI_E, [])
        }
    }
}

// MARK: - 剪贴板快照

/// shortcut: 只保存各类型的现成数据，文件 promise 等延迟提供的类型恢复后会丢失；润色只涉及文本，需要时再升级
struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func take() -> ClipboardSnapshot {
        let items = NSPasteboard.general.pasteboardItems?.map { item in
            Dictionary(item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }, uniquingKeysWith: { a, _ in a })
        } ?? []
        return ClipboardSnapshot(items: items)
    }

    func restore() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items.map { dict in
            let it = NSPasteboardItem()
            for (t, v) in dict { it.setData(v, forType: t) }
            return it
        })
    }
}

let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

func sleepMs(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

// MARK: - 选区读取（AX 优先，⌘C 兜底）

struct Captured {
    enum Source { case ax, copy }
    let text: String
    let source: Source
    let pid: pid_t
    let appName: String
    let role: String? // 焦点元素的 AX role，回填前辅助校验
    /// 没有选区时由 app 自动选中「光标前的内容」；放弃时据此恢复光标
    enum AutoSelect { case ax(caret: Int), keys }
    var autoSelect: AutoSelect? = nil
}

@MainActor
enum Selection {
    static var enabledPids = Set<pid_t>()

    /// AX 调用最多等 0.25s：目标应用无响应时不能拖住主线程（输入提示、快捷键都在主线程）
    static let systemWide: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(e, 0.25)
        return e
    }()

    static func focusedElement() -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func role(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func axSelectedText(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// 只对 Chromium / Electron 应用打开网页无障碍：AXEnhancedUserInterface 对其他应用有副作用（窗口动画、frame 读错）
    static func isChromiumOrElectron(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL?.appendingPathComponent("Contents/Frameworks"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return names.contains { $0.hasSuffix(".framework") && ($0.contains("Electron") || $0.contains("Chrom") || $0.contains("Edge") || $0.contains("Brave") || $0.hasPrefix("Arc")) }
    }

    /// Chromium 只认 AXEnhancedUserInterface，Electron 用 AXManualAccessibility；生效有约 2s 防抖，所以本次仍走 ⌘C
    static func enableAX(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard isChromiumOrElectron(app), enabledPids.insert(pid).inserted else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// 选区的屏幕矩形（AX 坐标原点在主屏左上角，转换为 Cocoa 坐标）
    static func bounds(_ el: AXUIElement) -> CGRect? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let range else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, range, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r), r.width > 0 || r.height > 0 else { return nil }
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// 光标（插入点）的屏幕矩形：有选区用选区；否则取光标前一个字符的矩形，贴在其右侧
    static func caretRect(_ el: AXUIElement) -> CGRect? {
        var r: CFTypeRef?
        var range = CFRange()
        // 空文档在输入法组合态下可能连选区范围都读不到：直接退回输入框第一行
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r) == .success, let r,
              CFGetTypeID(r) == AXValueGetTypeID(), AXValueGetValue(r as! AXValue, .cfRange, &range) else { return firstLine(el) }
        if range.length > 0 { return bounds(el) }
        for probe in [CFRange(location: range.location, length: 0), CFRange(location: max(range.location - 1, 0), length: 1)] {
            var p = probe
            guard let pv = AXValueCreate(.cfRange, &p) else { continue }
            var v: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, pv, &v) == .success,
                  let v, CFGetTypeID(v) == AXValueGetTypeID() else { continue }
            var b = CGRect.zero
            guard AXValueGetValue(v as! AXValue, .cgRect, &b), b.height > 0 else { continue }
            let h = NSScreen.screens.first?.frame.height ?? 0
            let x = probe.length == 1 ? b.maxX : b.minX
            return CGRect(x: x, y: h - b.maxY, width: 1, height: b.height)
        }
        return firstLine(el) // 空输入框（或输入法组合态下）没有可测量的字符：退回输入框第一行
    }

    /// 输入框左上角的一行高矩形（Cocoa 坐标）
    static func firstLine(_ el: AXUIElement) -> CGRect? {
        guard let f = frame(el) else { return nil }
        let line = min(f.height, 20)
        return CGRect(x: f.minX + 4, y: f.maxY - line - 4, width: 1, height: line)
    }

    /// 元素的屏幕矩形（Cocoa 坐标）
    static func frame(_ el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success, let pv,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success, let sv else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &pos), AXValueGetValue(sv as! AXValue, .cgSize, &size), size.height > 0 else { return nil }
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: pos.x, y: h - pos.y - size.height, width: size.width, height: size.height)
    }

    /// 哨兵法：剪贴板仍是哨兵即视为没有选区；结束后恢复原剪贴板
    static func readViaCopy() async -> String? {
        let pb = NSPasteboard.general
        let snap = ClipboardSnapshot.take()
        let sentinel = "polish-sentinel-\(UUID().uuidString)"
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(sentinel, forType: .string)
        item.setData(Data(), forType: transientType) // 剪贴板管理器不记录哨兵
        pb.writeObjects([item])
        let start = pb.changeCount
        Keys.copy()
        var text: String?
        var seen = start
        for _ in 0..<15 {
            await sleepMs(20)
            if pb.changeCount != start {
                await sleepMs(30) // 有的应用分多次写入剪贴板
                text = pb.string(forType: .string)
                seen = pb.changeCount
                break
            }
        }
        if pb.changeCount == seen { snap.restore() } // 期间被用户或其他程序改过就不恢复
        guard let t = text, t != sentinel, !t.isEmpty else { return nil }
        return t
    }

    static let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]

    /// 选区优先；没有选区时自动选中输入框里光标前的全部内容，再按选区流程处理
    static func capture() async -> Captured? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let name = app.localizedName ?? "前台应用"
        let el = focusedElement()
        if let el, let t = axSelectedText(el) {
            if !t.isEmpty {
                return Captured(text: t, source: .ax, pid: pid, appName: name, role: role(el))
            }
            // AX 明确告诉我们没有选区：不走 ⌘C（VS Code 等无选区时会复制整行）
            if let c = selectBeforeCaretAX(el, pid: pid, name: name) { return c }
            return await selectBeforeCaretKeys(el, pid: pid, name: name)
        }
        enableAX(app)
        if let t = await readViaCopy() {
            return Captured(text: t, source: .copy, pid: pid, appName: name, role: el.flatMap(role))
        }
        return await selectBeforeCaretKeys(el, pid: pid, name: name)
    }

    /// AX：读取输入框的值和光标位置，把 [0, 光标) 设为选区
    static func selectBeforeCaretAX(_ el: AXUIElement, pid: pid_t, name: String) -> Captured? {
        var v: CFTypeRef?, r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let value = v as? String,
              AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r) == .success, let r,
              CFGetTypeID(r) == AXValueGetTypeID() else { return nil }
        var caret = CFRange()
        guard AXValueGetValue(r as! AXValue, .cfRange, &caret), caret.length == 0, caret.location > 0,
              caret.location <= (value as NSString).length else { return nil }
        let before = (value as NSString).substring(to: caret.location)
        guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var range = CFRange(location: 0, length: caret.location)
        guard let rv = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, rv) == .success,
              axSelectedText(el) == before else { return nil } // 设置后读回核对，防止应用不支持
        return Captured(text: before, source: .ax, pid: pid, appName: name, role: role(el), autoSelect: .ax(caret: caret.location))
    }

    /// 兜底：⇧⌘↑ 选到输入框开头再 ⌘C。只在焦点是文本控件时做，避免在网页正文里乱选；
    /// 完全读不到焦点元素（微信 4.x 等自绘界面不暴露 AX）时也做，否则这类应用无法润色光标前内容
    static func selectBeforeCaretKeys(_ el: AXUIElement?, pid: pid_t, name: String) async -> Captured? {
        let r = el.flatMap(role)
        guard el == nil || r.map(editableRoles.contains) == true else { return nil }
        Keys.post(kVK_UpArrow, [.maskCommand, .maskShift])
        await sleepMs(80)
        guard let t = await readViaCopy(), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Keys.post(kVK_RightArrow, []) // 收起可能产生的空选区，光标回到原处
            return nil
        }
        return Captured(text: t, source: .copy, pid: pid, appName: name, role: r, autoSelect: .keys)
    }

    /// 放弃 / 复制时撤销自动选区，光标回到原来的位置（目标应用仍在前台时）
    static func restoreCaret(_ c: Captured) {
        guard let a = c.autoSelect, NSWorkspace.shared.frontmostApplication?.processIdentifier == c.pid else { return }
        switch a {
        case .ax(let caret):
            var range = CFRange(location: caret, length: 0)
            if let el = focusedElement(), let rv = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, rv)
            }
        case .keys:
            Keys.post(kVK_RightArrow, []) // 选区是「开头 → 原光标」，按 → 收起到原光标
        }
    }

    /// 回填前用原来的方式重新读取选区，用于逐字比对
    static func reread(_ c: Captured) async -> String? {
        switch c.source {
        case .ax:
            guard let el = focusedElement(), role(el) == c.role else { return nil } // 换了另一种控件
            return axSelectedText(el)
        case .copy:
            if let t = await readViaCopy() { return t }
            // 微信等应用在面板拿走焦点时会清掉选区：原选区若是整个输入框，⌘A 能原样选回；
            // 调用方仍逐字比对，选回的内容不一致就不替换。焦点不是文本控件时不 ⌘A，免得选中整页
            guard c.role.map(editableRoles.contains) ?? true else { return nil }
            Keys.post(kVK_ANSI_A, .maskCommand)
            await sleepMs(80)
            return await readViaCopy()
        }
    }

    /// 写入结果 → ⌘V → 稍后恢复剪贴板（期间被他人改过则不恢复）
    static func paste(_ text: String) async {
        let pb = NSPasteboard.general
        let snap = ClipboardSnapshot.take()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        pb.writeObjects([item])
        let ours = pb.changeCount
        Keys.paste()
        await sleepMs(800) // 慢应用（Electron）可能晚处理 ⌘V，过早恢复会粘进旧内容
        if pb.changeCount == ours { snap.restore() }
    }
}

// MARK: - API Key 存储
// 本地文件 ~/Library/Application Support/Polish/keys.json（目录 0700、文件 0600）。
// 用户 2026-10-14 要求：所有数据存本地目录，禁止使用钥匙串（无团队 ID 的签名下钥匙串每次升级都弹确认框）。

enum KeyStore {
    static let url = Paths.support.appendingPathComponent("keys.json")
    nonisolated(unsafe) static var cache: [String: String]?

    static func all() -> [String: String] {
        if let c = cache { return c }
        let d = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = d
        return d
    }

    /// 返回是否保存成功（空值即删除）
    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        var d = all()
        d[account] = value.isEmpty ? nil : value
        guard (try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil,
              let data = try? JSONEncoder().encode(d) else { return false }
        // 先以 0600 创建临时文件再原子改名：任何时刻都不存在他人可读的副本
        let tmp = url.appendingPathExtension("tmp")
        unlink(tmp.path)
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(tmp.path, url.path) == 0 else { return false }
        cache = d
        return true
    }

    /// 配置用的 Key：按服务归属（keyAccount），同一服务的场景共用
    static func apiKey(_ p: Profile) -> String { all()[keyAccount(p)] ?? "" }
}

enum Permissions {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// MARK: - 运行日志（~/Library/Logs/Polish/polish.log；只记状态与长度，不记正文和拼音内容）

enum Log {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Polish")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("polish.log")
    }()

    static func write(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        guard let h = try? FileHandle(forWritingTo: url) else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    }
}

// MARK: - 输入法候选窗

enum IME {
    /// 当前输入法候选窗里当前页的候选，及候选窗的屏幕矩形（读输入法进程的 AX 树；读不到返回空，调用方退回模型推断）
    @MainActor
    static func candidates() -> (list: [String], frame: CGRect?) {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let bp = TISGetInputSourceProperty(src, kTISPropertyBundleID) else { return ([], nil) }
        let bundleID = Unmanaged<CFString>.fromOpaque(bp).takeUnretainedValue() as String
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return ([], nil) }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.1) // 在打字路径上：宁可读不到也不能卡
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success, let windows = v as? [AXUIElement] else { return ([], nil) }
        var texts: [String] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 6, texts.count < 40 else { return }
            var r: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r) == .success, r as? String == kAXStaticTextRole as String {
                var t: CFTypeRef?
                if AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &t) == .success, let s = t as? String, !s.isEmpty { texts.append(s) }
            }
            var c: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &c) == .success, let kids = c as? [AXUIElement] {
                for k in kids { walk(k, depth + 1) }
            }
        }
        var frame: CGRect?
        for w in windows {
            let before = texts.count
            walk(w, 0)
            if frame == nil, texts.count > before { frame = Selection.frame(w) } // 有候选文字的窗口才是候选窗
        }
        return (candidateList(texts), frame)
    }
}

// MARK: - macOS 本地词典（词典 App 自带的「牛津英汉汉英词典」）

enum LocalDictionary {
    private typealias CopyAll = @convention(c) () -> Unmanaged<CFSet>?
    private typealias GetName = @convention(c) (DCSDictionary) -> Unmanaged<CFString>?

    /// 只查汉英词典：默认查询会先命中汉语词典（中文释义）。枚举词典是私有 API，按符号动态取，取不到就当没有词典
    private static let dict: DCSDictionary? = {
        let h = dlopen(nil, RTLD_NOW)
        guard let all = dlsym(h, "DCSCopyAvailableDictionaries"), let short = dlsym(h, "DCSDictionaryGetShortName") else { return nil }
        let set = unsafeBitCast(all, to: CopyAll.self)()?.takeRetainedValue() as NSSet? ?? []
        let name = unsafeBitCast(short, to: GetName.self)
        return set.first { (name($0 as! DCSDictionary)?.takeUnretainedValue() as String?) == "Simplified Chinese - English" } as! DCSDictionary?
    }()

    /// 词的第一个英文义项；短语、未收录或没装该词典时返回 nil（实测单词 1–2ms）
    static func english(_ word: String) -> String? {
        guard let dict else { return nil }
        let def = DCSCopyTextDefinition(dict, word as CFString, CFRange(location: 0, length: (word as NSString).length))?.takeRetainedValue() as String?
        return def.flatMap(dictionaryGloss)
    }
}
