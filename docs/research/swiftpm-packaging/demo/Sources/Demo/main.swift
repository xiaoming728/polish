import SwiftUI
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let polish = Self("polish", default: .init(.p, modifiers: [.option]))
}

struct DemoApp: App {
    init() {
        KeyboardShortcuts.onKeyUp(for: .polish) { print("hotkey") }
        // 仅用于一次性启动验证：3 秒后记录 KeyboardShortcuts 资源 bundle 路径并退出
        if ProcessInfo.processInfo.environment["DEMO_AUTOQUIT"] != nil {
            // 强制求值 Recorder 的 body，触发 KeyboardShortcuts 的 Bundle.module 本地化查找
            let v = NSHostingView(rootView: KeyboardShortcuts.Recorder("快捷键", name: .polish))
            try? "\(v.fittingSize)".write(toFile: "/tmp/kspkg/fit.txt", atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NSApp.terminate(nil)
            }
        }
    }
    var body: some Scene {
        MenuBarExtra("Demo", systemImage: "pencil") { Text("hi") }
        Settings { KeyboardShortcuts.Recorder("快捷键", name: .polish).padding() }
    }
}
DemoApp.main()
