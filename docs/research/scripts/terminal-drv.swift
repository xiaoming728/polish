import ApplicationServices
import AppKit

// 用法: swift drv.swift <cmd> <pid> [args]
// 每次投递事件前都校验：前台进程 pid 必须等于目标 pid，否则中止（exit 2）。
let a = CommandLine.arguments
let cmd = a[1]
let pid = pid_t(a[2])!
let ax = AXUIElementCreateApplication(pid)

func get(_ e: AXUIElement, _ k: String) -> AnyObject? {
    var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v as AnyObject?
}
func rect(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(get(e, kAXPositionAttribute) as! AXValue, .cgPoint, &p)
    AXValueGetValue(get(e, kAXSizeAttribute) as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}
func guardFront() {
    let f = NSWorkspace.shared.frontmostApplication
    guard f?.processIdentifier == pid else {
        print("ABORT: frontmost=\(f?.bundleIdentifier ?? "?") pid=\(f?.processIdentifier ?? 0), expected pid \(pid)"); exit(2)
    }
}
func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
    guardFront()
    for d in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: d)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
        usleep(60_000)
    }
}

switch cmd {
case "info":
    let f = NSWorkspace.shared.frontmostApplication
    print("frontmost:", f?.bundleIdentifier ?? "?", f?.processIdentifier ?? 0)
    if let w = get(ax, kAXFocusedWindowAttribute) {
        let w = w as! AXUIElement
        print("window title:", get(w, kAXTitleAttribute) ?? "nil", "frame:", rect(w))
    }
    if let e = get(ax, kAXFocusedUIElementAttribute) {
        let e = e as! AXUIElement
        print("focused role:", get(e, kAXRoleAttribute) ?? "nil", "frame:", rect(e))
    }
case "dblclick", "tripleclick": // 参数: dx dy 相对焦点窗口左上角
    guardFront()
    let w = get(ax, kAXFocusedWindowAttribute) as! AXUIElement
    let r = rect(w)
    let p = CGPoint(x: r.minX + Double(a[3])!, y: r.minY + Double(a[4])!)
    guard r.contains(p) else { print("ABORT: point outside window"); exit(2) }
    guardFront(); CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap); usleep(200_000)
    for i in 1...(cmd == "dblclick" ? 2 : 3) {
        for t in [CGEventType.leftMouseDown, .leftMouseUp] {
            guardFront()
            let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
            e.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            e.post(tap: .cghidEventTap)
            usleep(40_000)
        }
    }
    print("clicked at", p)
case "sel":
    let e = get(ax, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
    print("AXSelectedText:", e.flatMap { get($0, kAXSelectedTextAttribute) } ?? "nil")
case "text":
    let e = get(ax, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
    let s = (e.flatMap { get($0, kAXValueAttribute) } as? String) ?? ""
    print(s.split(separator: "\n").filter { !$0.allSatisfy { $0 == " " } }.suffix(14).joined(separator: "\n"))
case "ctrlg": key(5, .maskControl)
case "cmdc": key(8, .maskCommand)
default: print("unknown")
}
