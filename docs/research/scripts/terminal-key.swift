import CoreGraphics
import AppKit

// 用法: swift key.swift <bundleID> <keycode> <ctrl:0|1> ；用 postToPid 向目标进程投递按键（G 的 keycode=5）
let a = CommandLine.arguments
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: a[1]).first else { print("not running"); exit(1) }
for down in [true, false] {
    let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .combinedSessionState), virtualKey: CGKeyCode(a[2])!, keyDown: down)!
    e.flags = a[3] == "1" ? .maskControl : []
    e.postToPid(app.processIdentifier)
    usleep(50_000)
}
