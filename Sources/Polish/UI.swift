import AppKit
import PolishCore
import ServiceManagement
import SwiftUI

// MARK: - 预览面板（跟随光标的紧凑浮层，见「预览面板、小提示与设置界面的形态」）

struct KeyHint: View {
    let k: String, t: String
    init(_ k: String, _ t: String) { self.k = k; self.t = t }
    var body: some View {
        HStack(spacing: 3) {
            if !k.isEmpty {
                Text(k).font(.system(size: 11, weight: .medium, design: .rounded)).fixedSize()
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
            Text(t).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) // 不截断，太长就折行
        }
    }
}

/// 自动换行的横向排列：一行放不下就折到下一行；单项比整行还宽时压到整行宽（文字折行）
struct FlowLayout: Layout {
    var spacing: CGFloat = 10, lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (v, f) in zip(subviews, arrange(bounds.width, subviews).frames) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            var s = v.sizeThatFits(.unspecified)
            if s.width > width { s = v.sizeThatFits(ProposedViewSize(width: width, height: nil)) } // 超宽项按行宽折行，不截断
            if x > 0, x + s.width > width { x = 0; y += line + lineSpacing; line = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: s))
            x += s.width + spacing
            line = max(line, s.height)
            maxX = max(maxX, x - spacing)
        }
        return (frames, CGSize(width: maxX, height: y + line))
    }
}

/// 垫在面板背后：按住空白处（标题行、边距）拖动窗口。SwiftUI 内容不响应 isMovableByWindowBackground
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with e: NSEvent) { window?.performDrag(with: e) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ v: NSView, context: Context) {}
}

struct PanelView: View {
    @ObservedObject var state: AppState
    var onSwitch: (Int) -> Void = { _ in }
    @State var showSource = false
    @State var showAllProfiles = false

    var problem: (String, Color)? {
        switch state.phase {
        case .failed(let m): return (m, .red)
        case .verifyFailed(let m): return (m, .orange)
        default: return nil
        }
    }

    var acceptLabel: String { state.copyOnly ? "复制" : state.terminal ? "写回输入框" : "替换" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").foregroundStyle(.purple)
                Text(state.current.name).font(.caption.weight(.semibold))
                Text("→ \(state.target)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                status
            }
            .allowsHitTesting(false) // 标题行没有按钮：整行交给背后的拖动区
            if let (msg, color) = problem {
                Text(msg).font(.system(size: 12)).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }
            if state.phase == .done {
                // 完成后可直接修改结果，⏎ 用修改后的内容回填
                TextEditor(text: $state.output)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
            } else if !state.output.isEmpty || state.phase == .streaming {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(state.output + (state.phase == .streaming ? "▍" : ""))
                            .font(.system(size: 13)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .onChange(of: state.output) { proxy.scrollTo("end", anchor: .bottom) } // 流式输出时始终跟到最新一行
                }
            }
            Spacer(minLength: 0)
            if state.copyOnly {
                Text("没有连上 polish-edit，结果只能复制。若 zsh 草稿被清空，执行 print -z -- $ZLE_LINE_ABORTED 恢复。")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("原文", isExpanded: $showSource) {
                ScrollView {
                    Text(state.source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 60)
            }.font(.caption)
            if state.profiles.count > 1, state.phase == .streaming || state.phase == .done {
                // 默认列前 10 个（⌘1…⌘9、⌘0），其余点「更多」展开；都可点击切换
                FlowLayout {
                    ForEach(Array(state.profiles.prefix(showAllProfiles ? state.profiles.count : 10).enumerated()), id: \.element.id) { i, p in
                        Button { onSwitch(i) } label: {
                            KeyHint(i < 9 ? "⌘\(i + 1)" : i == 9 ? "⌘0" : "", p.name).opacity(p.id == state.currentID ? 1 : 0.55)
                        }.buttonStyle(.plain)
                    }
                    if state.profiles.count > 10 {
                        Button(showAllProfiles ? "收起" : "更多 \(state.profiles.count - 10) 个") { showAllProfiles.toggle() }
                            .buttonStyle(.link).font(.system(size: 11))
                    }
                }
            }
            FlowLayout(spacing: 12) { footer }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragArea())
        .modifier(PanelBackground(cornerRadius: 20))
    }

    @ViewBuilder var status: some View {
        switch state.phase {
        case .streaming: HStack(spacing: 4) { ProgressView().controlSize(.small); Text("润色中").font(.caption) }
        case .done: Label("完成", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed: Label("失败", systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
        case .verifyFailed: Label("未替换", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder var footer: some View {
        switch state.phase {
        case .streaming:
            KeyHint(state.hotKey.name, "取消"); KeyHint("Esc", "放弃")
        case .done:
            KeyHint("⏎", acceptLabel)
            KeyHint("⇧⏎", "换行")
            if !state.copyOnly { KeyHint("⌘C", "复制") }
            KeyHint("Esc", "放弃")
        case .failed:
            KeyHint(state.hotKey.name, "重试"); KeyHint("⌘,", "设置"); KeyHint("Esc", "关闭")
        case .verifyFailed:
            KeyHint("⌘C", "复制结果"); KeyHint("Esc", "关闭")
        }
    }
}

struct ToastView: View {
    let text: String, icon: String
    var body: some View {
        Label(text, systemImage: icon).font(.callout)
            .lineLimit(3).frame(maxWidth: 420, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
    }
}

// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var state: AppState
    let rebind: (HotKeySpec) -> Bool
    @State var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            ProfilesTab(state: state).tabItem { Label(tr("配置", "Profiles"), systemImage: "slider.horizontal.3") }.tag(0)
            GeneralTab(state: state, rebind: rebind).tabItem { Label(tr("通用", "General"), systemImage: "gearshape") }.tag(1)
            TerminalTab(state: state).tabItem { Label(tr("终端集成", "Terminal"), systemImage: "terminal") }.tag(2)
            PermissionTab().tabItem { Label(tr("权限与隐私", "Permissions & Privacy"), systemImage: "lock.shield") }.tag(3)
        }
        .id(state.uiLanguage) // 切换界面语言时重建各页（不观察 state 的子视图不会自己刷新）；tab 在外层，不跳页
        .padding()
        .frame(width: 780, height: 580)
    }
}

struct ProfilesTab: View {
    @ObservedObject var state: AppState
    @State var sel: UUID?
    @State var key = ""
    @State var showKey = false
    @State var models: [String] = []
    @State var status = ""
    @State var busy = false

    var index: Int? { state.profiles.firstIndex { $0.id == (sel ?? state.currentID) } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $sel) {
                    ForEach(state.profiles) { p in
                        HStack {
                            Text(p.name)
                            Spacer()
                            if p.id == state.currentID { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                        }.tag(Optional(p.id))
                    }
                }
                HStack {
                    Button { // 复制当前选中配置的服务连接，Key 自动共用
                        var p = state.profiles[index ?? 0]
                        p.id = UUID()
                        p.name = tr("新配置", "New Profile")
                        p.instruction = defaultInstruction
                        state.profiles.append(p)
                        sel = p.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        guard let i = index, state.profiles.count > 1 else { return }
                        let id = state.profiles[i].id
                        state.profiles.remove(at: i)
                        if state.currentID == id { state.currentID = state.profiles[0].id }
                        sel = state.currentID
                    } label: { Image(systemName: "minus") }.disabled(state.profiles.count <= 1)
                    Spacer()
                    Button(tr("设为当前", "Set as Current")) { if let s = sel { state.currentID = s } }.disabled(sel == nil || sel == state.currentID)
                }.padding(6)
            }.frame(width: 200)
            Divider()
            if let i = index {
                form(i)
            }
        }
        .onAppear { if sel == nil { sel = state.currentID }; loadKey() }
        .onChange(of: sel) { _, _ in loadKey(); models = []; status = "" }
    }

    func loadKey() {
        if let i = index { key = KeyStore.apiKey(state.profiles[i]) }
    }

    func form(_ i: Int) -> some View {
        Form {
            TextField(tr("名称", "Name"), text: $state.profiles[i].name)
            Picker(tr("服务商", "Provider"), selection: $state.profiles[i].preset) {
                ForEach(presets, id: \.name) { Text($0.name).tag($0.name) }
            }
            .onChange(of: state.profiles[i].preset) { _, new in
                guard let p = presets.first(where: { $0.name == new }) else { return }
                state.profiles[i].wire = p.wire
                if !p.baseURL.isEmpty { state.profiles[i].baseURL = p.baseURL }
                state.profiles[i].model = p.model
            }
            Picker(tr("协议", "Protocol"), selection: $state.profiles[i].wire) {
                Text(tr("OpenAI 兼容", "OpenAI compatible")).tag(Wire.openAI)
                Text("Anthropic").tag(Wire.anthropic)
            }
            TextField("Base URL", text: $state.profiles[i].baseURL)
                .onChange(of: state.profiles[i].baseURL) { _, _ in loadKey() } // Key 跟着服务走
            LabeledContent("API Key") {
                HStack {
                    // 密码框禁止向外复制（系统行为）；需要查看或复制时切到明文
                    if showKey { TextField("", text: $key) } else { SecureField("", text: $key) }
                    Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless).help(showKey ? tr("隐藏", "Hide") : tr("显示", "Show"))
                    Text(tr("同一服务的场景共用", "Shared by profiles of the same service")).font(.caption).foregroundStyle(.secondary)
                }
                .onChange(of: key) { _, v in
                    guard v != KeyStore.apiKey(state.profiles[i]) else { return } // 切换配置时的载入不算修改
                    if !KeyStore.set(keyAccount(state.profiles[i]), v) { status = tr("✗ API Key 保存失败", "✗ Failed to save API Key") }
                }
            }
            LabeledContent(tr("模型", "Model")) {
                HStack {
                    TextField("", text: $state.profiles[i].model)
                    Menu(tr("从 /models 拉取", "Fetch from /models")) {
                        if models.isEmpty { Text(tr("（暂无，点「刷新列表」）", "(None yet, click “Refresh List”)")) }
                        ForEach(models, id: \.self) { m in Button(m) { state.profiles[i].model = m } }
                        Divider()
                        Button(tr("刷新列表", "Refresh List")) {
                            Task {
                                status = tr("拉取中…", "Fetching…")
                                models = await Polisher.fetchModels(state.profiles[i], apiKey: key)
                                status = models.isEmpty ? tr("该服务没有提供模型列表，请手动填写", "This service provides no model list; enter one manually") : tr("已拉取 \(models.count) 个模型", "Fetched \(models.count) models")
                            }
                        }
                    }.fixedSize()
                }
            }
            Section(tr("润色指令", "Polish Instruction")) {
                TextEditor(text: $state.profiles[i].instruction).font(.system(size: 12)).frame(height: 110)
                Button(tr("恢复默认指令", "Restore Default Instruction")) { state.profiles[i].instruction = defaultInstruction }
            }
            Section(tr("额外请求体 JSON（可选，按顶层键合并，写各家方言参数）", "Extra request body JSON (optional, merged by top-level key, for provider-specific parameters)")) {
                TextEditor(text: $state.profiles[i].extraJSON).font(.system(size: 11, design: .monospaced)).frame(height: 50)
            }
            HStack {
                Button(tr("测试连接", "Test Connection")) { test(i) }.disabled(busy)
                Text(status).foregroundStyle(status.hasPrefix("✓") ? .green : status.hasPrefix("✗") ? .red : .secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
        }.formStyle(.grouped)
    }

    func test(_ i: Int) {
        let p = state.profiles[i]
        busy = true
        status = tr("测试中…", "Testing…")
        let start = Date()
        Task {
            do {
                _ = try await Polisher.stream(p, apiKey: key, text: "你好") { _ in }
                status = String(format: tr("✓ 连接成功 · %.1f 秒", "✓ Connected · %.1f s"), Date().timeIntervalSince(start))
            } catch {
                status = "✗ " + Polisher.describe(error).localizedDescription
            }
            busy = false
        }
    }
}

struct GeneralTab: View {
    @ObservedObject var state: AppState
    let rebind: (HotKeySpec) -> Bool
    @State var recording = false
    @State var monitor: Any?
    @State var hint = tr("至少包含 ⌘ / ⌥ / ⌃ 之一；被其他应用占用时会提示并保留原快捷键。", "Must include at least one of ⌘ / ⌥ / ⌃; if another app already uses it, you will be told and the old shortcut is kept.")
    // 不存 UserDefaults：每次从系统读，用户在「系统设置 → 登录项」里改了也能对上
    @State var loginStatus = SMAppService.mainApp.status
    @State var loginError: String?
    let installed = Bundle.main.bundleURL.path.hasPrefix("/Applications/")

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
    }

    func record() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil } // Esc 取消录制
            let f = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !f.intersection([.command, .option, .control]).isEmpty, let ch = e.charactersIgnoringModifiers, !ch.isEmpty else {
                hint = tr("需要至少包含 ⌘ / ⌥ / ⌃ 中的一个修饰键。", "Include at least one of the ⌘ / ⌥ / ⌃ modifiers.")
                return nil
            }
            let spec = HotKeySpec(code: UInt32(e.keyCode), mods: HotKey.carbonMods(f),
                                  name: hotkeyName(control: f.contains(.control), option: f.contains(.option), shift: f.contains(.shift), command: f.contains(.command), key: ch))
            hint = rebind(spec) ? tr("已改为 \(spec.name)，立即生效。", "Changed to \(spec.name), effective now.") : tr("\(spec.name) 已被占用，保留 \(state.hotKey.name)。", "\(spec.name) is already in use; keeping \(state.hotKey.name).")
            stop()
            return nil
        }
    }

    var body: some View {
        Form {
            Section(tr("界面语言", "Language")) {
                Picker(tr("设置界面", "Settings window"), selection: $state.uiLanguage) {
                    Text(tr("跟随系统", "System default")).tag(String?.none)
                    Text("中文").tag(String?.some("zh"))
                    Text("English").tag(String?.some("en"))
                }
            }
            Section(tr("启动", "Startup")) {
                HStack {
                    Toggle(tr("登录时自动启动 Polish", "Open Polish at login"),
                           isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: setLogin))
                        .disabled(!installed)
                    if let e = loginError { Text(e).font(.caption).foregroundStyle(.red) }
                }
                if !installed {
                    Text(tr("请先运行 scripts/build-app.sh --install 安装到 /Applications，再从那里启动 Polish 后打开此开关。",
                            "Install with scripts/build-app.sh --install and launch Polish from /Applications first."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if loginStatus == .requiresApproval {
                    HStack {
                        Text(tr("需要在「系统设置 → 通用 → 登录项」中允许 Polish。", "Allow Polish in System Settings → General → Login Items."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(tr("打开登录项设置", "Open Login Items")) { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            .onAppear { loginStatus = SMAppService.mainApp.status }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                loginStatus = SMAppService.mainApp.status
            }
            Section(tr("快捷键", "Shortcut")) {
                LabeledContent(tr("润色选中文字", "Polish selected text")) {
                    HStack {
                        Text(recording ? tr("请按下新的快捷键…", "Press the new shortcut…") : state.hotKey.name)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .frame(minWidth: 150).padding(.vertical, 4)
                            .background(Color.primary.opacity(recording ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 6))
                        Button(recording ? tr("取消", "Cancel") : tr("录制", "Record")) { recording ? stop() : record() }
                    }
                }
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("输入时中英提示", "Typing Hints")) {
                Toggle(tr("中文输入法下敲拼音时，在光标上方显示 ⌥1 \(state.targetLanguage.uiName) / ⌥2 中文", "While typing pinyin in a Chinese input method, show ⌥1 \(state.targetLanguage.uiName) / ⌥2 Chinese above the cursor"), isOn: $state.typingAssist)
                LanguagePicker(title: tr("⌥1 翻译成", "⌥1 translates to"), selection: Binding(get: { state.targetLanguage }, set: { if let l = $0 { state.targetLanguage = l } }),
                               excluded: .chinese)
                    .disabled(!state.typingAssist)
                LanguagePicker(title: tr("默认语言", "Default language"), selection: $state.nativeLanguage, followSystem: tr("跟随系统（\(TypingLanguage.system().uiName)）", "System default (\(TypingLanguage.system().uiName))"))
                    .disabled(!state.typingAssist)
                Toggle(tr("用英文或其他语言输入时（ABC 等键盘布局、输入法的英文模式、其他语言输入法），提示译回\(state.native.uiName)，⌥1 替换（会把敲的文字发给模型；密码框与安全输入时不工作）", "When typing in English or another language (ABC and other keyboard layouts, an input method’s English mode, other-language input methods), suggest a translation back to \(state.native.uiName); ⌥1 replaces (sends what you type to the model; off in password fields and Secure Input)"), isOn: $state.reverseTyping)
                    .disabled(!state.typingAssist)
                Toggle(tr("英文优先查 macOS 本地词典（牛津英汉汉英词典，离线、即时；短语和查不到的词再问模型）", "Look up English in the macOS dictionary first (Oxford Chinese Dictionary, offline and instant; phrases and missing words go to the model)"), isOn: $state.localDictionary)
                    .disabled(!state.typingAssist || state.targetLanguage != .english)
                Text(tr("停顿约 0.25 秒后，把正在输入的拼音发给当前配置的模型换算；按 ⌥1 / ⌥2 用所选内容替换刚敲的拼音。只在中文输入法激活时工作；密码框、安全输入和终端中不工作。需要「输入监控」权限。替换时按敲过的键数退格撤销拼音：个别输入法若在组合态吞掉按键，可能多删光标前的字，可用 ⌘Z 撤销。", "After a pause of about 0.25 s, the pinyin being typed is sent to the current profile’s model; press ⌥1 / ⌥2 to replace it with the chosen text. Works only while a Chinese input method is active; not in password fields, Secure Input or terminals. Requires the Input Monitoring permission. Replacing backspaces once per typed key: if an input method swallows keys while composing, it may delete extra characters before the cursor; undo with ⌘Z."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(tr("回填方式", "Apply Result")) {
                Picker("", selection: $state.fillMode) {
                    ForEach(FillMode.allCases, id: \.self) { m in
                        VStack(alignment: .leading) {
                            Text(m.name)
                            Text(m.detail).font(.caption).foregroundStyle(.secondary)
                        }.tag(m)
                    }
                }.pickerStyle(.radioGroup).labelsHidden()
            }
            Section(tr("请求", "Requests")) {
                LabeledContent(tr("超时", "Timeout"), value: tr("首字 30 秒 / 总计 120 秒", "30 s to first token / 120 s total"))
                LabeledContent(tr("失败时", "On failure"), value: tr("不自动重试，原文不动", "No automatic retry; original text untouched"))
                LabeledContent(tr("进行中再按快捷键", "Shortcut while running"), value: tr("取消本次润色", "Cancels the current polish"))
            }
        }
        .formStyle(.grouped)
        .onDisappear { stop() }
    }
}

/// ~/.zshrc 的读写；.zshrc 是符号链接（dotfiles 仓库）时改链接指向的文件，不把链接换成普通文件
enum ZshRc {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc").resolvingSymlinksInPath()
    }
    static func read() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// 每次改动前把改动前的内容备份到 ~/.zshrc.polish-backup
    static func write(_ s: String) throws {
        let old = read()
        guard s != old else { return }
        let backup = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc.polish-backup")
        if FileManager.default.fileExists(atPath: url.path) { try old.write(to: backup, atomically: true, encoding: .utf8) }
        try s.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// 可搜索的语言下拉：点开后输入中文名、英文名、本地名或代码过滤（系统认识的全部语言）
struct LanguagePicker: View {
    let title: String
    @Binding var selection: TypingLanguage?
    var followSystem: String? = nil // 非 nil 时第一项是「跟随系统」（selection 为 nil）
    var excluded: TypingLanguage? = nil
    @State private var open = false
    @State private var query = ""

    var body: some View {
        LabeledContent(title) {
            Button { open.toggle() } label: {
                HStack(spacing: 4) {
                    Text(selection?.uiName ?? followSystem ?? "")
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(spacing: 6) {
                    TextField(tr("搜索语言（中文、English、代码）", "Search languages (English, 中文, code)"), text: $query)
                        .textFieldStyle(.roundedBorder)
                    List {
                        if let followSystem, query.isEmpty { row(followSystem, nil) }
                        ForEach(TypingLanguage.all.filter { $0 != excluded && $0.matches(query) }) { row($0.uiName, $0) }
                    }
                    .listStyle(.plain)
                }
                .padding(8)
                .frame(width: 260, height: 320)
                .onAppear { query = "" }
            }
        }
    }

    private func row(_ name: String, _ lang: TypingLanguage?) -> some View {
        Button {
            selection = lang
            open = false
        } label: {
            HStack {
                Text(name)
                Spacer()
                if lang == selection { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SnippetBox: View {
    let title: String, id: String, code: String
    /// 安装时一并清掉的旧版片段 id
    var replaces: [String] = []
    @Binding var rc: String
    @Binding var message: String?
    @State var copied = false

    var installed: Bool { RcBlock.has(rc, id: id) }
    /// 装过但内容与当前不同（如 Polish.app 换了位置）
    var stale: Bool { RcBlock.body(rc, id: id).map { $0 != code } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                if installed {
                    Label(stale ? tr("已安装（需更新）", "Installed (update needed)") : tr("已安装", "Installed"), systemImage: stale ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(stale ? .orange : .green)
                }
                Spacer()
                Button(copied ? tr("已复制 ✓", "Copied ✓") : tr("复制", "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }
                if installed {
                    Button(tr("卸载", "Uninstall")) { apply(RcBlock.remove(rc, id: id), done: tr("已从 ~/.zshrc 移除「\(title)」", "Removed “\(title)” from ~/.zshrc")) }
                }
                if !installed || stale {
                    Button(stale ? tr("更新", "Update") : tr("安装", "Install")) {
                        let clean = replaces.reduce(rc) { RcBlock.remove($0, id: $1) }
                        apply(RcBlock.install(clean, id: id, body: code), done: tr("已写入 ~/.zshrc：「\(title)」", "Wrote “\(title)” to ~/.zshrc"))
                    }
                        .buttonStyle(.borderedProminent)
                }
            }
            Text(code).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func apply(_ new: String, done: String) {
        do {
            try ZshRc.write(new)
            rc = ZshRc.read()
            message = done + tr("。新开的终端窗口生效（已打开的窗口执行 source ~/.zshrc）；已在运行的 Agent 要退出后重新启动。改动前的内容备份在 ~/.zshrc.polish-backup。", ". Takes effect in new terminal windows (run source ~/.zshrc in open ones); restart running Agents. The previous content is backed up to ~/.zshrc.polish-backup.")
        } catch {
            message = tr("写入 ~/.zshrc 失败：\(error.localizedDescription)", "Failed to write ~/.zshrc: \(error.localizedDescription)")
        }
    }
}

struct TerminalTab: View {
    @ObservedObject var state: AppState
    @State var rc = ZshRc.read()
    @State var message: String?

    /// 取当前 .app 的实际位置；路径含空格时用单引号包住
    var editor: String {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/polish-edit").path
        return path.contains(" ") ? "'\(path)'" : path
    }

    var zsh: String {
        """
        # Polish：zsh 输入行按 Ctrl+G 或 Ctrl+X Ctrl+E 交给 polish-edit（放在 bindkey -v / -e 之后）
        autoload -Uz edit-command-line
        zle -N polish-edit-command-line edit-command-line
        zstyle ':zle:polish-edit-command-line' editor \(editor)
        bindkey -M emacs '^G' polish-edit-command-line
        bindkey -M viins '^G' polish-edit-command-line
        bindkey -M vicmd '^G' polish-edit-command-line
        bindkey -M emacs '^X^E' polish-edit-command-line
        bindkey -M viins '^X^E' polish-edit-command-line
        """
    }

    /// 所有按 $VISUAL / $EDITOR 唤起外部编辑器的程序都走 polish-edit；不是 Polish 触发的照常转交原编辑器。
    /// 嵌套 shell 继承到的已是 polish-edit 时不覆盖 POLISH_FALLBACK_EDITOR，免得转交给自己
    var agents: String {
        """
        # Polish：终端里的 Agent（Claude Code、Codex、Gemini CLI、OpenCode、Aider…）唤起外部编辑器时交给 polish-edit；
        # 不是 Polish 触发的（如自己运行 git commit）照常打开原来的编辑器
        [[ "${VISUAL:-$EDITOR}" == *polish-edit* ]] || export POLISH_FALLBACK_EDITOR="${VISUAL:-$EDITOR}"
        export VISUAL=\(editor) EDITOR=\(editor)
        """
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(tr("在终端（Terminal、Ghostty、iTerm2、kitty、WezTerm、Alacritty、Warp 等）中按快捷键时，Polish 会先给当前程序发送下面选定的按键，0.5 秒内没连上再试 Ctrl+G / Ctrl+X 中的另一个，让它用外部编辑器打开草稿，由 polish-edit 读取后立即放回；润色期间 CLI 照常可用，确认后再打开一次写回输入框，不会自动执行或发送。点「安装」把对应片段写到 ~/.zshrc 末尾（带 Polish 标记，「卸载」只删这一段），然后重开终端。", "When you press the shortcut in a terminal (Terminal, Ghostty, iTerm2, kitty, WezTerm, Alacritty, Warp, etc.), Polish first sends the key chosen below to the current program, and if nothing connects within 0.5 s tries the other of Ctrl+G / Ctrl+X, so the program opens the draft in an external editor; polish-edit reads it and puts it right back. The CLI stays usable while polishing; after you confirm, it opens once more to write the result back into the input box, without running or sending it. Click “Install” to append the snippet to the end of ~/.zshrc (marked by Polish; “Uninstall” removes only that block), then reopen the terminal."))
                    .fixedSize(horizontal: false, vertical: true)
                Picker(tr("优先发送的按键", "Key to send first"), selection: $state.terminalKey) {
                    ForEach(TerminalKey.allCases, id: \.self) { k in
                        Text("\(k.rawValue)　\(k.detail)").tag(k)
                    }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(message.hasPrefix(tr("写入", "Failed")) ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SnippetBox(title: tr("zsh 输入行", "zsh line editor"), id: "zsh", code: zsh, rc: $rc, message: $message)
                SnippetBox(title: tr("终端 Agent 与其他程序", "Terminal Agents and other programs"), id: "agents", code: agents, replaces: ["claude", "codex"], rc: $rc, message: $message)
                if RcBlock.has(rc, id: "claude") || RcBlock.has(rc, id: "codex") {
                    Label(tr("检测到旧版的 Claude Code / Codex 单独片段，安装上面这一项时会自动替换掉。", "Found the old separate Claude Code / Codex snippets; installing the item above replaces them."), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Label(tr("Agent 只在启动时读取编辑器设置：安装前就在运行的会话，按快捷键会打开 vi 等原编辑器。退出后在新终端窗口重新启动即可。", "Agents read the editor setting only at startup: sessions started before installing open vi or the old editor. Quit and restart them in a new terminal window."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Label(tr("bash 不支持：Ctrl+X Ctrl+E 编辑后会直接执行命令。bash 中改为润色终端选区后复制。", "bash is not supported: Ctrl+X Ctrl+E runs the command right after editing. In bash, polish a terminal selection and copy it instead."), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Label(tr("ssh 到远程或未配置的 zsh 中，Ctrl+G 会清空当前行；执行 print -z -- $ZLE_LINE_ABORTED 可恢复。", "Over ssh or in an unconfigured zsh, Ctrl+G clears the current line; run print -z -- $ZLE_LINE_ABORTED to restore it."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                Label(tr("移动 Polish.app 后，已安装的片段会显示「需更新」，点一下即可。", "After moving Polish.app, installed snippets show “update needed”; just click it."), systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(4)
        }
        .onAppear { rc = ZshRc.read() } // 用户可能在外面手改过
    }
}

struct PermissionTab: View {
    @State var trusted = Permissions.trusted
    var body: some View {
        Form {
            Section(tr("权限", "Permissions")) {
                HStack {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(trusted ? .green : .red)
                    Text(tr("辅助功能", "Accessibility"))
                    Spacer()
                    Button(tr("刷新", "Refresh")) { trusted = Permissions.trusted }
                    Button(tr("打开系统设置", "Open System Settings")) { Permissions.openSettings() }
                }
                Text(tr("读取选区和回填需要辅助功能权限。ad-hoc 签名的应用每次重新构建后都要重新授权（先在列表中移除旧条目再添加）。", "Reading the selection and writing results back need the Accessibility permission. Ad-hoc signed builds must be re-authorized after every rebuild (remove the old entry from the list, then add it again)."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(tr("隐私", "Privacy")) {
                Text(tr("润色时只发送本次选中的文字（终端中为当前输入框草稿）。开启「输入时中英提示」后，会在中文输入法下读取正在敲的拼音键，并把拼音发给当前配置的模型（终端中只发送输入法候选词，不发送按键），可随时在菜单中关闭；日志不含正文和 Key；API Key 存在本机文件（仅你的账号可读）；临时占用剪贴板后会恢复，期间若被其他程序改动则不恢复。", "Polishing sends only the selected text (in terminals, the current input draft). With “Typing Hints” on, Polish reads the pinyin keys you type in a Chinese input method and sends the pinyin to the current profile’s model (in terminals only input-method candidates are sent, not keystrokes); you can turn it off from the menu at any time. Logs contain no text or keys; API Keys are stored in a local file readable only by your account; the clipboard is borrowed briefly and restored, unless another program changes it meanwhile."))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped)
    }
}

extension TypingLanguage {
    /// 设置界面里显示的语言名，跟随界面语言
    var uiName: String { tr(name, Locale(identifier: "en").localizedString(forLanguageCode: rawValue) ?? rawValue) }
}
