import ApplicationServices
import AppKit

// 用法: swift ax.swift <bundleID> ；读取该 App 的焦点元素与选中文字
let bid = CommandLine.arguments[1]
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else { print("not running"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ a: String) -> (AXError, AnyObject?) {
    var v: CFTypeRef?; let r = AXUIElementCopyAttributeValue(e, a as CFString, &v); return (r, v as AnyObject?)
}
let (r, f) = attr(ax, kAXFocusedUIElementAttribute)
print("focusedUIElement err:", r.rawValue)
guard let fe = f else { exit(0) }
let el = fe as! AXUIElement
for a in [kAXRoleAttribute, kAXSubroleAttribute, kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute, kAXNumberOfCharactersAttribute] {
    let (e, v) = attr(el, a)
    print(a, "err:", e.rawValue, "val:", String(describing: v).prefix(200))
}
var names: CFArray?
AXUIElementCopyAttributeNames(el, &names)
print("attrs:", names as? [String] ?? [])
