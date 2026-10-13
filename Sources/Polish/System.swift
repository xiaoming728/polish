import AppKit
import Carbon.HIToolbox
import Security

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

    static func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
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
    /// privateState 事件源 + 显式 flags：用户此时可能还按着 ⌥，不能让它混进投递的按键
    static func post(_ key: Int, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
    static func copy() { post(kVK_ANSI_C, .maskCommand) }
    static func paste() { post(kVK_ANSI_V, .maskCommand) }
    static func ctrlG() { post(kVK_ANSI_G, .maskControl) }
}

// MARK: - 剪贴板快照

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

func sleepMs(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

// MARK: - 选区读取（AX 优先，⌘C 兜底）

struct Captured {
    enum Source { case ax, copy }
    let text: String
    let source: Source
    let pid: pid_t
    let appName: String
    let bounds: CGRect? // Cocoa 坐标
}

@MainActor
enum Selection {
    static var enabledPids = Set<pid_t>()

    static func focusedElement() -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func axSelectedText(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// Chromium 只认 AXEnhancedUserInterface，Electron 用 AXManualAccessibility；生效有约 2s 防抖，所以本次仍走 ⌘C
    static func enableAX(_ pid: pid_t) {
        guard enabledPids.insert(pid).inserted else { return }
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

    /// 哨兵法：剪贴板仍是哨兵即视为没有选区；结束后恢复原剪贴板
    static func readViaCopy() async -> String? {
        let pb = NSPasteboard.general
        let snap = ClipboardSnapshot.take()
        let sentinel = "polish-sentinel-\(UUID().uuidString)"
        pb.clearContents()
        pb.setString(sentinel, forType: .string)
        let start = pb.changeCount
        Keys.copy()
        var text: String?
        for _ in 0..<15 {
            await sleepMs(20)
            if pb.changeCount != start {
                await sleepMs(30) // 有的应用分多次写入剪贴板
                text = pb.string(forType: .string)
                break
            }
        }
        snap.restore()
        guard let t = text, t != sentinel, !t.isEmpty else { return nil }
        return t
    }

    static func capture() async -> Captured? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let name = app.localizedName ?? "前台应用"
        if let el = focusedElement() {
            if let t = axSelectedText(el), !t.isEmpty {
                return Captured(text: t, source: .ax, pid: pid, appName: name, bounds: bounds(el))
            }
            enableAX(pid)
        } else {
            enableAX(pid)
        }
        guard let t = await readViaCopy() else { return nil }
        return Captured(text: t, source: .copy, pid: pid, appName: name, bounds: focusedElement().flatMap(bounds))
    }

    /// 回填前用原来的方式重新读取选区，用于逐字比对
    static func reread(_ c: Captured) async -> String? {
        switch c.source {
        case .ax: return focusedElement().flatMap(axSelectedText)
        case .copy: return await readViaCopy()
        }
    }

    /// 写入结果 → ⌘V → 稍后恢复剪贴板（期间被他人改过则不恢复）
    static func paste(_ text: String) async {
        let pb = NSPasteboard.general
        let snap = ClipboardSnapshot.take()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])
        let ours = pb.changeCount
        Keys.paste()
        await sleepMs(400)
        if pb.changeCount == ours { snap.restore() }
    }
}

// MARK: - 钥匙串（ad-hoc 签名只能用传统 login keychain）

enum Keychain {
    static let service = "Polish"

    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
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
