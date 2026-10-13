# Chromium / Electron / WebKit 输入框的 AX 读取与焦点校验

对应 issue：xiaoming728/polish#4（母地图 #1）。调研日期 2026-10-13，环境 macOS 27.2、Swift 6.3、仅 Command Line Tools。

标记约定：**[源码]** 来自一手源码，**[实测]** 本机脚本结果，**[推断]** 由源码推出但未运行验证，**[未实测]** 需人工操作或授权，见末尾验证步骤。

## 结论（先看这里）

1. 激活属性因框架而异，不能一刀切：
   - Chrome / Chromium 系（Chrome、Arc 等）只响应 `AXEnhancedUserInterface`，**不支持** `AXManualAccessibility`。
   - Electron 两者都响应，官方文档推荐 `AXManualAccessibility`。
   - Safari / WebKit 无需激活开关。
   - 因此首版策略：按 App 先对 app 元素读 `AXManualAccessibility` 是否可设；可设则设它（Electron）；否则对 Chromium 设 `AXEnhancedUserInterface`；设完用结果不用等返回值。
2. 开启有延迟：Chromium 与 Electron 把 `AXEnhancedUserInterface` / `AXManualAccessibility` 的启用做了 **2 秒防抖**（"没有新请求满 2 秒后才启用"）。所以首次读取必须"设置 → 重试读取"，不能设完立刻当结果。设置动作应只做一次且常驻（不要每次润色都先 true 再 false，会反复重置 2 秒计时，且 false 会触发关闭）。
3. 即使不设属性，Chromium 在 Sonoma 之后只要有 AT 访问 `accessibilityRole` 就会进 `kNativeAPIs` 模式，但该模式**不含网页内容**（页面内输入框读不到），仅原生壳层可见。所以网页内输入框仍须 `AXEnhancedUserInterface` 触发完整树。
4. 读选区的判据：先 `kAXSelectedTextAttribute`；为空或失败时，对 WebKit 页面文字退回 `AXSelectedTextMarkerRange` + `AXStringForTextMarkerRange`（Easydict 的 SelectedTextKit 就是这么做的）；再不行才退到 ⌘C。WebKit 的 `AXSelectedText` 只在文本控件上提供。
5. 焦点元素不变校验：`CFEqual` 可以用但不能当唯一判据。建议组合判据：`CFEqual(focused)` **或**（同 pid + 同 role + 同 frame + `AXSelectedTextRange` 未变 + 焦点窗口 `CFEqual`）；回填前再取一次选区文本与润色前的原文比对，这是最强的"内容没变"校验。`CFEqual` 的稳定性**未实测**。
6. `⌘V` 替换选区并进入撤销栈：Chromium/WebKit 的粘贴走编辑命令，按源码推断会替换选区并进入撤销栈，**未实测**，需用户按末尾步骤验证。
7. `AXEnhancedUserInterface` 的已知副作用：窗口动画使窗口管理器读到错误 frame（Rectangle 的做法是移动窗口前先关掉）；Chromium 上开启会触发昂贵的网页无障碍处理（性能）。我们只需在读取时短暂开启，**但**关闭会再次触发 2 秒防抖，且 Rectangle 之类可能把它关掉导致我们的读取失效，需要每次读取前重新检查并必要时重设。
8. 本机特别发现：本机 `ChatGPT.app`（bundle `com.openai.codex`）**不是 Electron**（Frameworks 里只有 Codex Framework 与 Sparkle，没有 Electron Framework），Claude.app 是 Electron 42.7.0。Arc 本机未安装。验证矩阵据此调整。

## 一、各框架的激活机制（一手源码）

### Chromium（Chrome、Arc）

- **[源码]** 官方设计文档：Mac 上 Chromium 根据客户端（如 VoiceOver）是否在主应用上设置了 `AXEnhancedUserInterface` 来开关无障碍；覆盖方式是 `--force-renderer-accessibility` 或 `chrome://accessibility`。
  出处：https://www.chromium.org/developers/design-documents/accessibility/
- **[源码]** `BrowserCrApplication.accessibilitySetValue:forAttribute:` 只识别 `@"AXEnhancedUserInterface"`，调用 `enableScreenReaderCompleteModeAfterDelay:`；注释说明"macOS Sonoma 起会出现 AXEnhancedUserInterface 的瞬间开关抖动，所以去抖：等变化稳定后再更新"。实现：计数器 + `performSelector:afterDelay:` 的 `kTwoSecondDelay = 2.0`，期间有新请求则取消重计时；若 VoiceOver 已显式开启则忽略其他 AT 的请求。
  出处：https://github.com/chromium/chromium/blob/main/chrome/browser/chrome_browser_application_mac.mm （函数 `enableScreenReaderCompleteModeAfterDelay:`、`accessibilitySetValue:forAttribute:`）
- **[源码]** 同文件 `accessibilityRole`：对非 VoiceOver 的 AT（如语音控制），当无障碍处于关闭状态时，访问 `accessibilityRole` 会创建 scoped mode；Sonoma 精简版本下目标是 `ui::AXMode::kNativeAPIs`，否则 `kAXModeBasic`。
  出处：同上。
- **[源码]** `kNativeAPIs` 的定义注释："如果下面其他模式都没设置，网页内容不可访问"；`kAXModeBasic = kNativeAPIs | kWebContents`，`kAXModeComplete` 另含 `kInlineTextBoxes | kExtendedProperties`。
  出处：https://github.com/chromium/chromium/blob/main/ui/accessibility/ax_mode.h
- **[源码]** PWA 的 app shim（`app_shim_application.mm`）同样只认 `AXEnhancedUserInterface`，且只处理"设为 true"。
  出处：https://github.com/chromium/chromium/blob/main/chrome/app_shim/app_shim_application.mm
- **[实测]** 本机 Chrome 155.0.8059.40（pid 2922，运行中）对 app 元素：`AXEnhancedUserInterface` 在属性名列表中、可设置（`AXUIElementIsAttributeSettable` 成功）、当前值 0；`AXManualAccessibility` 不在列表中，读取与 settable 查询都返回 `-25205`（`kAXErrorAttributeUnsupported`）。与源码一致。脚本：`/tmp/ax-research/probe.swift`（只读，未 set 任何属性）。

### Electron（Claude 桌面版等）

- **[源码]** Electron 的 `AtomApplication`：`accessibilityAttributeNames` 追加 `AXManualAccessibility`，`accessibilityIsAttributeSettable` 对它返回 YES；`accessibilitySetValue` 对 `AXEnhancedUserInterface` 与 `AXManualAccessibility` 都走同一条带 2 秒防抖的启用路径；读取 `AXManualAccessibility` 返回当前是否处于 `kAXModeComplete`。其余逻辑（`accessibilityRole` 探测、计数器、2 秒延迟）与 Chromium 一致（注释写明复制自 chrome_browser_application_mac.mm）。
  出处：https://github.com/electron/electron/blob/main/shell/browser/mac/electron_application.mm
- **[源码]** Electron 官方教程明确写出第三方 AT 在 macOS 上应通过 `AXManualAccessibility` 打开，并给出 Swift / ObjC 示例；也说明系统辅助工具（如 VoiceOver）优先于该设置。
  出处：https://github.com/electron/electron/blob/main/docs/tutorial/accessibility.md
- **[推断]** 因此对 Electron 应用设 `AXManualAccessibility` 或 `AXEnhancedUserInterface` 都有效，前者是官方推荐，后者受"VoiceOver 已开启则忽略"之外无差别。应用若魔改了 `AtomApplication`（例如自带 NSApplication 子类）则可能不响应，需逐个 App 验证。

### WebKit（Safari）

- **[源码]** `WebAccessibilityObjectWrapperMac.mm` 里 `NSAccessibilitySelectedTextAttribute` / `SelectedTextRange` 仅在 `AttributePrecondition::IsTextControl` 时提供（属性表项 `{ NSAccessibilitySelectedTextAttribute, { handleSelectedTextAttribute, textControlPreconditions } }`），设置也仅限 `isTextControl()`；而选区的通用表示是 `NSAccessibilitySelectedTextMarkerRangeAttribute`。
  出处：https://github.com/WebKit/WebKit/blob/main/Source/WebCore/accessibility/mac/WebAccessibilityObjectWrapperMac.mm
- **[推断]** Safari 没有 Chromium 式的"需要 AT 打开"开关（本次在 WebKit 源码里未找到等价的 app 级激活属性）。但 contenteditable 是否被算作 text control、ProseMirror 类编辑器能否直接读到 `AXSelectedText`，源码层面未能确认，**[未实测]**。

## 二、读选区的做法（开源工具）

- **Easydict / SelectedTextKit（tisfeng）**：取 frontmost app 的 pid → `AXUIElementCreateApplication` → `focusedUIElement` → `selectedText`；失败或为空时，用 `AXSelectedTextMarkerRange` + 参数化属性 `AXStringForTextMarkerRange` 兜底；`auto` 策略再退到"菜单栏 Edit → Copy 的 AXPress"，再退到模拟 ⌘C；`apiDisabled`（无权限）直接返回不再尝试。它**没有**设置 `AXManualAccessibility` / `AXEnhancedUserInterface`（用 `AXManualAccessibility`/`AXEnhancedUserInterface` 搜索 tisfeng/Easydict 与 SelectedTextKit 均无命中，搜索时间 2026-10-13），所以 Electron/Chromium 页面内读不到时只能靠菜单复制或 ⌘C。
  出处：https://github.com/tisfeng/SelectedTextKit/blob/main/Sources/SelectedTextKit/Accessibility/AXManager.swift 、https://github.com/tisfeng/SelectedTextKit/blob/main/Sources/SelectedTextKit/TextSelection/SelectedTextManager.swift
- **Raycast**：扩展 API 只有 `getSelectedText()`（"获取最前台应用的选中文字"），典型示例是 `getSelectedText` → 处理 → `Clipboard.paste`；实现不开源，内部机制未知，不作结论依据。
  出处：https://developers.raycast.com/api-reference/environment
- **PopClip**：API 文档说明 `popclip.pasteText(text, {restore})` 是"把文字放进剪贴板再调用目标 App 的 Paste 命令，可选恢复原剪贴板；目标 App 没有 Paste 命令则退化为复制"。这印证"回填 = 写剪贴板 + 触发粘贴 + 恢复剪贴板"是业内通行做法。读取选区的内部实现未公开。
  出处：https://www.popclip.app/dev/popclip.d.ts
- **窗口管理器（副作用佐证）**：Rectangle 文档说明它在移动/缩放窗口时关闭 `AXEnhancedUserInterface`，因为其动画窗口更新会产生错误 frame，并提到 Chromium 系浏览器恢复该模式时会开启昂贵的网页无障碍处理，所以对已知 Chromium 浏览器默认不恢复。AeroSpace 也把 `AXEnhancedUserInterface` 作为可写属性。
  出处：https://github.com/rxhanson/Rectangle/blob/main/TerminalCommands.md （"Control Enhanced UI handling"）、https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/util/accessibility.swift

## 三、问题逐项回答

### Q1 设置后能否稳定读到焦点元素与选中文字？首次是否有延迟？

- 机制上能（见上），但 **启用有 2 秒防抖** **[源码]**。推荐流程：
  1. 判断目标 App 类型：读 app 元素 `AXManualAccessibility` 是否可设（**[实测]** Chrome 返回 unsupported）。
  2. 设对应属性（只在"该 pid 尚未设过"时设一次，记录已设 pid）。
  3. 读 `kAXFocusedUIElementAttribute`；失败（`kAXErrorNoValue` 等）或 role 不是文本类，则以 0.3~0.5 秒间隔重试，最多约 3 秒（超过 2 秒防抖加网页树生成时间）。重试数字是**建议**，需实测校准。
  4. 取 `kAXSelectedTextAttribute`；空则试 TextMarker 兜底；仍空则回退到 ⌘C。
- 编辑器选区的限制 **[源码]**：Chromium 仅对 `IsTextField()` 节点列出 `AXSelectedText` / `AXSelectedTextRange`，`accessibilitySelectedText` 在没有"可见光标或选区"时返回 nil；`AXSelectedTextRange` 的偏移是相对该文本框的。contenteditable / ProseMirror 是否被算成 text field，**[未实测]**。
  出处：https://github.com/chromium/chromium/blob/main/ui/accessibility/platform/browser_accessibility_cocoa.mm
- 本机各 App 实测：Chrome 的属性探测已做（只读）；Claude / ChatGPT(Codex) / Safari / Arc 当时未运行，且按约束不去启动或操作它们，其余全部 **[未实测]**。

### Q2 `CFEqual` 能否作为"焦点元素不变"依据？

- **[源码]** `AXUIElement` 是 CF 类型，头文件说明可用于 CFRetain / CFRelease / CFEqual 等多态函数（SDK `HIServices/AXUIElement.h`，未说明跨调用稳定性）。
- **[源码]** Chromium 的 `accessibilityFocusedUIElement` 返回 `focus_node->GetNativeViewAccessible()`，即每个 AX 节点对应的原生包装对象；节点在页面 DOM 重建或导航时可能被销毁重建，此时同一输入框的前后两次引用将不相等。
  出处：https://github.com/chromium/chromium/blob/main/ui/accessibility/platform/browser_accessibility_cocoa.mm （`accessibilityFocusedUIElement`）
- **[推断]** 用户在 1~3 秒的 LLM 等待期间输入框不变化时，`CFEqual` 应成立；富文本编辑器（ProseMirror）在输入、聚焦移动时会重渲染节点，可能不成立。**[未实测]**。
- 建议判据（从强到弱）：
  1. 回填前重新读取选区文本，与润色前原文逐字相等（内容校验，最关键）。
  2. 前台 App pid / bundle id 未变，焦点窗口 `CFEqual`（窗口元素比网页内节点稳定），窗口 title 未变。
  3. 焦点元素 `CFEqual` 为真，**或** role + subrole + frame 相等且 `AXSelectedTextRange` 未变。
  4. 满足 1 即可放行；仅满足 3 而 1 无法取到（例如读取靠 ⌘C 兜底）时降级为"预览确认"，不自动回填。

### Q3 模拟 ⌘V 是否替换选区并进入撤销栈？

- **[推断]** Chromium 的粘贴是编辑命令，通过 `ReplaceSelectionCommand`（继承 `CompositeEditCommand`）完成，复合编辑命令会作为一个 undo step 记录；WebKit 同源（Blink 来自 WebKit 的 editing 代码）。故应替换选区并可被 ⌘Z 一次撤销。
  出处：https://github.com/chromium/chromium/blob/main/third_party/blink/renderer/core/editing/commands/replace_selection_command.cc
- 实际表现（含 ProseMirror 的粘贴处理器、Electron 应用自定义粘贴、粘贴时是否带格式）**[未实测]**。回填时应写入 plain text（`NSPasteboard` 的 `.string`），并在粘贴后恢复原剪贴板（PopClip 的 `restore` 做法）。

### Q4 `AXEnhancedUserInterface` 副作用

- **[源码]** 窗口动画问题与 Chromium 性能问题见 Rectangle 文档（上文）。
- **[源码]** 关闭也会走 2 秒防抖路径；Sonoma 起系统会"瞬间开关"该属性，Chromium 为此加了去抖。
- 对本应用的建议：
  - 只对需要读取的目标 App 在读取时设置；默认不在后台长期保持。
  - 设置前读取原值，若原值已是 true 就不动它；本应用不要在读取后把它设回 false（避免触发关闭防抖、也避免覆盖 VoiceOver/其他 AT）。
  - 与 Rectangle / yabai 等窗口管理器共存时，对方可能把它关掉，所以每次读取前重新检查。
  - 对 Electron 优先用 `AXManualAccessibility`，其不会让 Chromium 层打印 AXError，且语义就是"第三方 AT 请求"。
  - 这些副作用的实际表现（动画、卡顿、与具体窗口管理器的交互）**[未实测]**。

## 四、本机已完成的实测

| 项 | 方法 | 结果 |
| --- | --- | --- |
| 当前进程是否有辅助功能授权 | `AXIsProcessTrusted()`（`/tmp/ax-research/trust.swift`） | `true`（运行脚本的终端宿主已授权） |
| Chrome 是否列出/可设两个属性 | 只读：`AXUIElementCopyAttributeNames` / `IsAttributeSettable` / `CopyAttributeValue`（`/tmp/ax-research/probe.swift`） | `AXEnhancedUserInterface`：已列出、可设、值 0；`AXManualAccessibility`：-25205 不支持 |
| 其他 App 是否安装 | `ls /Applications` | Claude（Electron 42.7.0）、ChatGPT（com.openai.codex，非 Electron）、Chrome 155.0.8059.40、Safari 27.2 已装；Arc 未装 |

没有设置过任何目标 App 的属性，没有向任何输入框输入或粘贴内容，没有启动用户的其他应用。

## 五、未实测项与用户验证步骤

以下均需要用户自己操作。建议先把下面脚本存到仓库外的 `/tmp/ax-research/verify.swift`，用 `swiftc verify.swift -o verify` 编译，在已授权辅助功能的终端里运行 `./verify <bundleID> [set]`。脚本只读（带 `set` 参数时仅对 app 元素设置激活属性）。

```swift
import AppKit
import ApplicationServices
// 用法：./verify <bundleID> [set]  ；运行后 5 秒内把焦点切到目标 App 的输入框并选中一段文字
let id = CommandLine.arguments[1]
let doSet = CommandLine.arguments.count > 2
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { print("未运行"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
if doSet {
  let r1 = AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, true as CFTypeRef)
  let r2 = AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
  print("set Manual:", r1.rawValue, "Enhanced:", r2.rawValue)
}
func focused() -> AXUIElement? {
  var v: CFTypeRef?
  guard AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &v) == .success else { return nil }
  return (v as! AXUIElement)
}
func str(_ e: AXUIElement, _ a: String) -> String {
  var v: CFTypeRef?
  let r = AXUIElementCopyAttributeValue(e, a as CFString, &v)
  return r == .success ? String(describing: v!) : "err\(r.rawValue)"
}
print("5 秒后开始，请切到目标输入框并选中文字")
Thread.sleep(forTimeInterval: 5)
let t0 = Date()
var first: AXUIElement?
for i in 0..<20 { // 每 0.5 秒重试，最多 10 秒，测首次延迟
  if let f = focused() {
    let sel = str(f, kAXSelectedTextAttribute)
    print(String(format: "t=%.1fs try#%d role=%@ selText=%@", Date().timeIntervalSince(t0), i, str(f, kAXRoleAttribute), sel))
    if !sel.hasPrefix("err") { first = f; break }
  } else { print(String(format: "t=%.1fs try#%d 无焦点元素", Date().timeIntervalSince(t0), i)) }
  Thread.sleep(forTimeInterval: 0.5)
}
guard let f1 = first else { print("读取失败"); exit(0) }
print("selRange:", str(f1, kAXSelectedTextRangeAttribute), "frame:", str(f1, "AXFrame"))
print("3 秒后再取一次焦点元素比较 CFEqual（期间请勿动）")
Thread.sleep(forTimeInterval: 3)
if let f2 = focused() { print("CFEqual 同一输入框(静止):", CFEqual(f1, f2)) }
print("现在请在同一输入框里输入一个字符后（5 秒内）...")
Thread.sleep(forTimeInterval: 5)
if let f3 = focused() { print("CFEqual 输入后:", CFEqual(f1, f3), "selRange:", str(f3, kAXSelectedTextRangeAttribute)) }
```

按目标 App 逐项验证（每项记录：读取成功与否、首次成功用时、`CFEqual` 结果）：

1. **Claude 桌面版（Electron）**：先不带 `set` 参数运行一次（基线，预期读不到），再带 `set` 运行；在聊天输入框（ProseMirror/contenteditable）选中文字。记录首次成功是第几次重试（预期约 2 秒后）。
2. **ChatGPT/Codex 桌面版**：同上，另外先看 `AXManualAccessibility` 是否可设（本机它不是 Electron，行为未知）。
3. **Chrome**：网页里的 `<textarea>`、`<input>`、contenteditable（如 https://github.com 评论框、Notion 之类）各测一次；带 `set` 时它只会对 `AXEnhancedUserInterface` 成功。
4. **Arc（未安装）**：安装后重复 Chrome 的步骤；Arc 是 Chromium 系，预期同 Chrome。
5. **Safari**：不带 `set` 直接测；测 `<textarea>`、contenteditable；并用选中网页正文（非输入框）测 `AXSelectedText` 是否为空（预期空，需要 TextMarker 兜底）。
6. **⌘V 撤销栈**（人工）：在上述每个编辑器里，选中一段文字，手动复制一段别的文字，按 ⌘V，确认选区被替换；再按 ⌘Z，确认一次撤销回到原文（而不是需要多次或无效）。再用 PopClip 或 Easydict 类工具已有的"替换"功能观察实际现象亦可。
7. **`AXEnhancedUserInterface` 副作用**：对 Chrome 带 `set` 运行后，用 Rectangle 或系统窗口管理操作（拖动/缩放窗口）观察动画与卡顿；在"活动监视器"里看 Chrome 的 CPU 是否明显升高；可重启 Chrome 复原。
8. **`CFEqual` 稳定性**：脚本最后一步对比"静止"与"输入一个字符后"的结果，在每个编辑器各测一次，结论决定第 5 条判据里 `CFEqual` 能否作为主判据。

## 六、遗留风险

- 2 秒防抖加网页 AX 树生成，可能让首次润色多出 2~3 秒等待，需要在设计里决定是否在菜单栏应用启动或 App 被激活时预热（预设属性），代价是对所有 Chromium/Electron 目标 App 常驻开启无障碍（性能与上文副作用）。
- 以上"按 App 类型选属性"的探测依赖 `AXManualAccessibility` 是否在 app 元素的属性列表里，已在 Chrome 上实测其不支持；Electron 一侧需用户实测确认。
