// 输入时中英提示端到端验收：在新开的 TextEdit 文档里用中文输入法敲拼音，按 ⌥1 / ⌥2，读回文档内容核对。
// 用法：swiftc -O scripts/typing-e2e.swift -o build/typing-e2e && build/typing-e2e [输入源 ID]
// 前提：/Applications/Polish.app 正在运行，且已授予「辅助功能」与「输入监控」；运行本程序的终端需有辅助功能权限。
// 安全：每次发键前确认前台是本程序打开的 TextEdit 窗口，否则立即中止；结束后恢复原输入法、关闭文档不保存。
import AppKit
import Carbon

// 命令行程序用到 AppKit 时，macOS 会把它算成一个应用并挂在启动它的终端名下（Dock 里多出一个终端图标）。
// 声明为后台进程，不进 Dock（实测：未加时每次运行都在 Dock 里多一个 Ghostty 图标）
NSApplication.shared.setActivationPolicy(.prohibited)

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Polish/polish.log")
let imeID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.tencent.inputmethod.wetype.pinyin"

/// 进程内执行 AppleScript：不另起 osascript 进程（每个 osascript 都会挂在终端名下进 Dock）
func osa(_ script: String) -> String {
    var err: NSDictionary?
    let r = NSAppleScript(source: script)?.executeAndReturnError(&err)
    return (r?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func inputSource(_ id: String) -> TISInputSource? {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    return (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first
}

func currentSourceID() -> String {
    let s = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    return Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(s, kTISPropertyInputSourceID)).takeUnretainedValue() as String
}

func logLines() -> [String] {
    (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
}

var textEditPid: pid_t = 0
var originalSource = currentSourceID()

func cleanup() {
    _ = osa("tell application \"TextEdit\" to if (count of documents) > 0 then close document 1 saving no")
    if let s = inputSource(originalSource) { TISSelectInputSource(s) }
}

func abort(_ msg: String) -> Never {
    print("⛔ 中止：\(msg)")
    cleanup()
    exit(2)
}

func ensureFront() {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == textEditPid else { abort("前台不是测试用的 TextEdit 窗口") }
}

func key(_ code: Int, _ flags: CGEventFlags = []) {
    ensureFront()
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
    usleep(90_000)
}

let codes: [Character: Int] = ["n": kVK_ANSI_N, "i": kVK_ANSI_I, "h": kVK_ANSI_H, "a": kVK_ANSI_A, "o": kVK_ANSI_O,
                               "s": kVK_ANSI_S, "j": kVK_ANSI_J, "e": kVK_ANSI_E]

func waitLog(after count: Int, contains needle: String, timeout: Double) -> String? {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if let l = logLines().dropFirst(count).first(where: { $0.contains(needle) }) { return l }
        usleep(200_000)
    }
    return nil
}

func documentText() -> String { osa("tell application \"TextEdit\" to get text of document 1") }

var failures = 0
func check(_ ok: Bool, _ name: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "✅" : "❌") \(name)  \(detail)")
}

// 准备
print("Polish 日志：", logLines().filter { $0.contains("launch") || $0.contains("typing-assist") }.suffix(2).joined(separator: " | "))
guard let ime = inputSource(imeID) else { abort("找不到输入源 \(imeID)") }
_ = osa("tell application \"TextEdit\" to make new document")
_ = osa("tell application \"TextEdit\" to activate")
usleep(1_200_000)
guard let te = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else { abort("TextEdit 未启动") }
textEditPid = te.processIdentifier
ensureFront()
TISSelectInputSource(ime)
usleep(500_000)
check(currentSourceID() == imeID, "切换到中文输入法", currentSourceID())

func round(_ pinyin: String, english: Bool) {
    let before = documentText()
    let mark = logLines().count
    for c in pinyin { key(codes[c]!) }
    let result = waitLog(after: mark, contains: "typing result", timeout: 15)
    check(result?.contains("ok=true") == true, "「\(pinyin)」：光标上方出现中英结果", result ?? "（15 秒内没有结果）")
    if let anchor = logLines().dropFirst(mark).last(where: { $0.contains("typing anchor") }) {
        check(anchor.contains("anchor=caret") || anchor.contains("anchor=ime"), "「\(pinyin)」：提示框定位在输入行上方", anchor)
    }
    guard result?.contains("ok=true") == true else { return }
    if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] { // 可选：提示框出现时截屏留证
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "\(dir)/hint-\(pinyin).png"]
        try? p.run()
        p.waitUntilExit()
    }
    key(english ? kVK_ANSI_1 : kVK_ANSI_2, .maskAlternate)
    usleep(1_500_000)
    let after = documentText()
    let added = String(after.dropFirst(before.count))
    let noPinyin = !after.contains(pinyin)
    let isChinese = added.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    let isEnglish = !added.isEmpty && added.unicodeScalars.allSatisfy { $0.isASCII }
    check(noPinyin, "「\(pinyin)」：拼音已被撤销", after.debugDescription)
    check(english ? isEnglish : isChinese, "「\(pinyin)」：⌥\(english ? 1 : 2) 输入了\(english ? "英文" : "中文")", added.debugDescription)
    check(!after.contains("¡") && !after.contains("™"), "「\(pinyin)」：⌥\(english ? 1 : 2) 没有漏进应用（¡ / ™）")
}

func candidates() -> [String] {
    guard let we = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.inputmethod.wetype").first else { return [] }
    var texts: [String] = []
    func walk(_ e: AXUIElement) {
        var r: CFTypeRef?, v: CFTypeRef?, c: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r) == .success, r as? String == "AXStaticText",
           AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &v) == .success, let s = v as? String { texts.append(s) }
        if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &c) == .success, let k = c as? [AXUIElement] { k.forEach(walk) }
    }
    var w: CFTypeRef?
    if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(we.processIdentifier), kAXWindowsAttribute as CFString, &w) == .success,
       let ws = w as? [AXUIElement] { ws.forEach(walk) }
    var out: [String] = []
    for (i, t) in texts.enumerated() where Int(t) != nil && i + 1 < texts.count && Int(texts[i + 1]) == nil { out.append(texts[i + 1]) }
    return out
}

/// 切换候选：敲拼音后按 → 两次，提示框应跟随到第 3 个候选，⌥2 上屏的就是它
func roundFollow(_ pinyin: String) {
    let before = documentText()
    let mark = logLines().count
    for c in pinyin { key(codes[c]!) }
    guard waitLog(after: mark, contains: "typing result", timeout: 15) != nil else {
        check(false, "「\(pinyin)」→→：首个结果没出来"); return
    }
    let mark2 = logLines().count
    key(kVK_RightArrow)
    key(kVK_RightArrow)
    let result = waitLog(after: mark2, contains: "typing result", timeout: 15)
    let followed = logLines().dropFirst(mark2).contains { $0.contains("highlight=2 candidate=true") }
    let expected = candidates().dropFirst(2).first ?? "?"
    check(followed && result?.contains("ok=true") == true, "「\(pinyin)」→→：提示框跟随到第 3 个候选「\(expected)」并重新出结果", result ?? "（没有新结果）")
    key(kVK_ANSI_2, .maskAlternate)
    usleep(1_500_000)
    let added = String(documentText().dropFirst(before.count))
    check(added.trimmingCharacters(in: .newlines) == expected, "「\(pinyin)」→→ ⌥2：上屏的是第 3 个候选", "\(added.debugDescription) 期望 \(expected.debugDescription)")
}

func type(_ s: String) { for c in s { key(c == " " ? kVK_Space : codes[c]!) } }

/// 句中 ⌥1：光标前与本句一致 → 删掉本句和拼音换成译文，本句之前的文字一个不少
func roundSentence() {
    let before = documentText()
    type("shijie ")
    let mark = logLines().count
    type("nihao")
    let result = waitLog(after: mark, contains: "typing sentence len=", timeout: 15)
    check(result?.contains("ok=true") == true, "句中「世界 + nihao」：出整句结果", result ?? "（15 秒内没有结果）")
    key(kVK_ANSI_1, .maskAlternate)
    usleep(1_500_000)
    let after = documentText()
    let added = String(after.dropFirst(before.count))
    check(after.hasPrefix(before) && !after.contains("世界") && !after.contains("nihao") && !added.isEmpty && added.unicodeScalars.allSatisfy(\.isASCII),
          "句中 ⌥1：本句换成英文，前文保留", after.debugDescription)
}

/// 输入框被键盘以外的方式改过（本句记录与实际不符）：⌥1 一个字都不删，结果只进剪贴板
func roundMismatch() {
    type("shijie ")
    _ = osa("tell application \"TextEdit\" to set text of document 1 to (text of document 1) & \"改\"")
    usleep(300_000)
    let before = documentText()
    let mark = logLines().count
    type("nihao")
    guard waitLog(after: mark, contains: "typing sentence len=", timeout: 15) != nil else { return check(false, "不一致：整句结果没出来") }
    key(kVK_ANSI_1, .maskAlternate)
    let copied = waitLog(after: mark, contains: "copied only", timeout: 3)
    usleep(500_000)
    let after = documentText()
    check(copied != nil && after.hasPrefix(before), "不一致 ⌥1：不删任何字，提示已复制", after.debugDescription)
    let clip = NSPasteboard.general.string(forType: .string) ?? ""
    check(!clip.isEmpty && clip.unicodeScalars.allSatisfy(\.isASCII), "不一致 ⌥1：译文在剪贴板", clip.debugDescription)
    key(kVK_Escape) // 撤销留在组合态的拼音
}

round("nihao", english: true)
key(kVK_Return)
roundSentence()
key(kVK_Return)
roundMismatch()
key(kVK_Return)
round("shijie", english: false)
key(kVK_Return)
roundFollow("nihao")

cleanup()
print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
