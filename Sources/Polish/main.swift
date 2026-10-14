import AppKit
import PolishCore

// Contents/MacOS/polish-edit 是指向本二进制的符号链接：按 argv[0] 分发为终端编辑器入口。
// 编辑器可能收到额外参数（如 +行号），文件路径总是最后一个。
if (CommandLine.arguments[0] as NSString).lastPathComponent == "polish-edit" {
    EditClient.run(CommandLine.arguments.count > 1 ? CommandLine.arguments.last : nil)
}

if CommandLine.arguments.contains("--bench") { // 开发用：输入提示请求方式的消融计时
    FileHandle.standardError.write(Data("bench: start\n".utf8))
    Task.detached { await Bench.run() }
    RunLoop.main.run()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = Controller()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(controller) { app.run() }
}
