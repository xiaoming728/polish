# 无 Xcode 的构建、打包与 ad-hoc 签名行为（调研 #6）

环境：macOS 27.2，Command Line Tools，Swift 6.3.3，无 Xcode。下文"实测"项都在本机跑过；"未实测"项需要人工观察，文末给出验证步骤。

## 结论

- 只用 CLT 时，KeyboardShortcuts 3.1.0 原版**编译失败**，打约 20 行补丁后 `swift build -c release` 才能通过。
- 手工组装 .app 并 ad-hoc 签名后，能用 `open` 启动并正常退出（实测）。
- `MenuBarExtra` 和 `Settings` 在 SwiftPM 可执行目标里可以用（实测编译、启动通过）。
- 有两个坑需要写进设计：
  - 资源 bundle 的位置和严格签名校验冲突。
  - ad-hoc 签名的身份由 cdhash 决定，每次重建都会变，辅助功能授权和 Keychain 很可能受影响（未实测）。

## 1. KeyboardShortcuts

- **原版失败原因**：`Recorder.swift` 里有 3 个 `#Preview`，`ConflictPolicy.swift` 用了 `@Entry`。这两类宏要用 SwiftUI 宏插件，而插件只随 Xcode 提供。
- **补丁（`patch-ks.sh`）**：删除 3 处 `#Preview`，把 `@Entry` 改成手写的 `EnvironmentKey`。补丁后 release 和 debug 都能通过。上游 issue #240（release 编译崩溃）在 Swift 6.3.3 下没有复现。
- **资源 bundle 的查找位置**：`Bundle.module` 只在 `.app` **根目录**找 `KeyboardShortcuts_KeyboardShortcuts.bundle`，不找 `Contents/Resources`。找不到时，会回退到编译时的构建目录绝对路径；那里也没有就 `fatalError`。
  - 只放在 `Contents/Resources`、并移走构建目录：Recorder 一渲染就崩溃，退出码 133。
  - 放在 `.app` 根目录：能运行，但 `codesign --verify --strict` 报 `unsealed contents present in the bundle root`。
  - 根目录放一个符号链接指向 `Contents/Resources` 里的 bundle：仍报同样的错，运行正常。
  - 开发机上构建目录还在时，回退路径会掩盖这个问题。验证时必须把构建目录藏起来。
- **能力边界**：
  - 全局热键底层是 Carbon `RegisterEventHotKey`，不会弹权限对话框。
  - Recorder 的冲突检测只覆盖系统符号热键（symbolic hotkeys）和本 App 的主菜单，**检测不到其他 App 注册的全局热键**。
  - 库里"不能只用 Option 修饰"的限制只针对沙盒应用、且只在 macOS 15.0/15.1 上生效，不影响默认键位 ⌥P。

## 2. 组装 .app

- **Info.plist 最小键集**：`CFBundleIdentifier`、`CFBundleName`、`CFBundleExecutable`、`CFBundlePackageType`（APPL）、`CFBundleShortVersionString`、`CFBundleVersion`、`LSMinimumSystemVersion`、`LSUIElement=true`。
- `NSAppleEventsUsageDescription` 只有发送 Apple events 时才需要，本项目不需要。
- 脚本见 `assemble.sh`。第二个参数传 `root` 时，会把资源 bundle 放到根目录，用来复现上面的 unsealed 报错。

## 3. 签名

- `codesign -dv` 显示 `Signature=adhoc`、`TeamIdentifier=not set`。designated requirement 为 `cdhash H"..."`，所以**每次重建身份都会变**。
- `spctl --status` 显示 `assessments disabled`，在本机没有参考价值。

## 4. Keychain

- 在 ad-hoc 签名、没有 entitlement 的情况下，用 `kSecUseDataProtectionKeychain` 调 `SecItemAdd` 返回 **-34018**（实测，`kc-probe.swift`）。
- 结论：只能用传统的 login keychain。

## 5. 未实测项与验证步骤

1. **重建后辅助功能授权是否失效**：给 Demo 授权，修改源码后重新 `assemble`，对比前后两次 `AXIsProcessTrusted()` 的结果。
2. **`tccutil reset Accessibility <bundle-id>` 的效果**：本次没有执行。
3. **重建后传统 Keychain 条目的表现**：是弹窗还是读取失败。
4. **固定的自签名证书能否让 TCC 和 Keychain 的身份保持稳定**。
5. **界面实际显示**：菜单栏图标和设置窗口。
6. **Recorder 实际录入**：录入、以及录入被系统占用的组合键时是否弹冲突提示。
7. **抢同一全局热键**：和其他 App 注册同一组合时的表现。
8. **根目录符号链接方案在别的机器上的表现**：经 zip 分发、带隔离属性的情况。

## 产物

- `demo/Package.swift`、`demo/Sources/Demo/main.swift`：最小可复现包。
- `patch-ks.sh`：KeyboardShortcuts 补丁。
- `assemble.sh`：组装 .app 并签名。
- `kc-probe.swift`：Keychain 探针。只在 /tmp 编译运行过，仓库里这一份没有重新验证。
