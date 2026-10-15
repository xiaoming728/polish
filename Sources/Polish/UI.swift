import AppKit
import Charts
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

    var acceptLabel: String { state.copyOnly ? tr("复制", "Copy") : state.terminal ? tr("写回输入框", "Write back") : tr("替换", "Replace") }

    /// 从按下到第一个字出现
    var waiting: Bool { state.phase == .streaming && state.output.isEmpty }
    /// 光边亮度：等待时全亮，流式输出时减半，其余（含面板隐藏）不显示
    var glow: Double { !state.panelShown || state.phase != .streaming ? 0 : waiting ? 1 : 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").foregroundStyle(Color.accentColor)
                Text(state.current.name).font(.caption.weight(.semibold))
                Text("→ \(state.target)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                status
            }
            .allowsHitTesting(false) // 标题行没有按钮：整行交给背后的拖动区
            if case .verifyFailed = state.phase, let (msg, color) = problem {
                banner(msg, color).modifier(ShakeOnAppear())
            } else if let (msg, color) = problem {
                banner(msg, color)
            }
            Group {
                if state.phase == .done {
                    // 完成后可直接修改结果，⏎ 用修改后的内容回填
                    TextEditor(text: $state.output)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .transition(.opacity)
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
                    .transition(.opacity)
                }
            }
            .animation(waiting ? .easeOut(duration: 0.15) : nil, value: waiting) // ⌘1–9 重跑：旧结果淡出
            Spacer(minLength: 0)
            if state.copyOnly {
                Text(tr("没有连上 polish-edit，结果只能复制。若 zsh 草稿被清空，执行 print -z -- $ZLE_LINE_ABORTED 恢复。", "Not connected to polish-edit, so the result can only be copied. If the zsh draft was cleared, run print -z -- $ZLE_LINE_ABORTED to restore it."))
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(tr("原文", "Original"), isExpanded: $showSource) {
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
                        Button(showAllProfiles ? tr("收起", "Less") : tr("更多 \(state.profiles.count - 10) 个", "\(state.profiles.count - 10) more")) { showAllProfiles.toggle() }
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
        .modifier(GlowBorder(cornerRadius: 20, level: glow, failed: { if case .failed = state.phase { return true }; return false }(), done: state.phase == .done))
        .modifier(PopIn(shown: state.panelShown))
    }

    func banner(_ msg: String, _ color: Color) -> some View {
        Text(msg).font(.system(size: 12)).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
    }

    @ViewBuilder var status: some View {
        switch state.phase {
        case .streaming: Text(tr("润色中", "Polishing")).font(.caption).foregroundStyle(.secondary) // 等待由光边表示
        case .done: Label(tr("完成", "Done"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).modifier(BounceOnAppear())
        case .failed: Label(tr("失败", "Failed"), systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
        case .verifyFailed: Label(tr("未替换", "Not replaced"), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder var footer: some View {
        switch state.phase {
        case .streaming:
            KeyHint(state.hotKey.name, tr("取消", "Cancel")); KeyHint("Esc", tr("放弃", "Discard"))
        case .done:
            KeyHint("⏎", acceptLabel)
            KeyHint("⇧⏎", tr("换行", "New line"))
            if !state.copyOnly { KeyHint("⌘C", tr("复制", "Copy")) }
            KeyHint("Esc", tr("放弃", "Discard"))
        case .failed:
            KeyHint(state.hotKey.name, tr("重试", "Retry")); KeyHint("⌘,", tr("设置", "Settings")); KeyHint("Esc", tr("关闭", "Close"))
        case .verifyFailed:
            KeyHint("⌘C", tr("复制结果", "Copy result")); KeyHint("Esc", tr("关闭", "Close"))
        }
    }
}

struct ToastView: View {
    let text: String, icon: String
    @State private var shown = false
    var body: some View {
        Label(text, systemImage: icon).font(.callout)
            .lineLimit(3).frame(maxWidth: 420, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .modifier(PopIn(shown: shown, scale: 1, dy: 6)) // 从下方 6pt 滑入
            .onAppear { shown = true }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var state: AppState
    let rebind: (HotKeySpec) -> Bool
    var body: some View {
        TabView(selection: $state.settingsTab) {
            ProvidersTab(state: state).tabItem { Label(tr("服务商", "Providers"), systemImage: "server.rack") }.tag(0)
            ProfilesTab(state: state).tabItem { Label(tr("场景", "Profiles"), systemImage: "slider.horizontal.3") }.tag(5)
            GeneralTab(state: state, rebind: rebind).tabItem { Label(tr("通用", "General"), systemImage: "gearshape") }.tag(1)
            TerminalTab(state: state).tabItem { Label(tr("终端集成", "Terminal"), systemImage: "terminal") }.tag(2)
            UsageTab().tabItem { Label(tr("使用统计", "Usage"), systemImage: "chart.bar") }.tag(3)
            PermissionTab().tabItem { Label(tr("权限与隐私", "Permissions & Privacy"), systemImage: "lock.shield") }.tag(4)
        }
        .id(state.uiLanguage) // 切换界面语言时重建各页（不观察 state 的子视图不会自己刷新）；tab 在外层，不跳页
        .padding()
        .frame(width: 780, height: 580)
    }
}

/// 场景：名称 + 润色指令（⌘1–9 切换）；连接用「服务商」页当前选中的服务商
struct ProfilesTab: View {
    @ObservedObject var state: AppState
    @State var sel: UUID?

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
                    Button {
                        var p = state.profiles[index ?? 0]
                        p.id = UUID()
                        p.name = tr("新配置", "New Profile")
                        p.instruction = scenes(english: uiEnglish())[0].instruction
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
                Form {
                    TextField(tr("名称", "Name"), text: $state.profiles[i].name)
                    LabeledContent(tr("服务商", "Provider")) {
                        Button("\(state.provider.name) / \(state.provider.model.isEmpty ? tr("未填模型", "no model") : state.provider.model)") { state.settingsTab = 0 }
                            .buttonStyle(.link).help(tr("所有场景共用当前服务商，到「服务商」页切换", "All profiles share the current provider; switch it on the Providers tab"))
                    }
                    Section(tr("润色指令", "Polish Instruction")) {
                        TextEditor(text: $state.profiles[i].instruction).font(.system(size: 12)).frame(height: 260)
                        Button(tr("恢复默认指令", "Restore Default Instruction")) { state.profiles[i].instruction = scenes(english: uiEnglish())[0].instruction }
                    }
                }.formStyle(.grouped)
            }
        }
        .onAppear { if sel == nil { sel = state.currentID } }
    }
}

/// 服务商列表：连接、Key、模型、额外 JSON；所有场景共用当前选中的一个
struct ProvidersTab: View {
    @ObservedObject var state: AppState
    @State var sel: UUID?
    @State var key = ""
    @State var showKey = false
    @State var models: [String] = []
    @State var status = ""
    @State var busy = false

    var index: Int? { state.providers.firstIndex { $0.id == (sel ?? state.providerID) } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $sel) {
                    ForEach(state.providers) { v in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(v.name)
                                Text(v.model.isEmpty ? tr("未填模型", "No model") : v.model).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if v.id == state.providerID { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                        }.tag(Optional(v.id))
                    }
                }
                HStack {
                    Button { // 新建默认服务商，再在右侧选预设
                        let v = defaultProvider()
                        state.providers.append(v)
                        sel = v.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        guard let i = index, state.providers.count > 1 else { return }
                        let id = state.providers[i].id
                        state.providers.remove(at: i)
                        if state.providerID == id { state.providerID = state.providers[0].id }
                        sel = state.providerID
                    } label: { Image(systemName: "minus") }.disabled(state.providers.count <= 1)
                    Spacer()
                    Button(tr("设为当前", "Set as Current")) { if let s = sel { state.providerID = s } }.disabled(sel == nil || sel == state.providerID)
                }.padding(6)
            }.frame(width: 200)
            Divider()
            if let i = index {
                form(i)
            }
        }
        .onAppear { if sel == nil { sel = state.providerID }; loadKey() }
        .onChange(of: sel) { _, _ in loadKey(); models = []; status = "" }
    }

    func loadKey() {
        if let i = index { key = KeyStore.apiKey(state.providers[i].profile()) }
    }

    func form(_ i: Int) -> some View {
        Form {
            TextField(tr("名称", "Name"), text: $state.providers[i].name)
            // 只在用户选预设时套用：onChange 观察 providers[i] 时，切换左侧选中项也会触发，把模型冲成预设默认值
            Picker(tr("服务商", "Provider"), selection: Binding(get: { state.providers[i].preset }, set: { new in
                guard let p = presets.first(where: { $0.name == new }) else { return }
                var v = state.providers[i]
                if v.name == v.preset { v.name = new } // 没改过的名称跟着预设走
                v.preset = new
                v.wire = p.wire
                if !p.baseURL.isEmpty { v.baseURL = p.baseURL }
                v.model = p.model
                state.providers[i] = v
            })) {
                ForEach(presets, id: \.name) { Text($0.name).tag($0.name) }
            }
            Picker(tr("协议", "Protocol"), selection: $state.providers[i].wire) {
                Text(tr("OpenAI 兼容", "OpenAI compatible")).tag(Wire.openAI)
                Text("Anthropic").tag(Wire.anthropic)
            }
            TextField("Base URL", text: $state.providers[i].baseURL)
                .onChange(of: state.providers[i].baseURL) { _, _ in loadKey() } // Key 跟着服务走
            LabeledContent("API Key") {
                HStack {
                    // 密码框禁止向外复制（系统行为）；需要查看或复制时切到明文
                    if showKey { TextField("", text: $key) } else { SecureField("", text: $key) }
                    Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless).help(showKey ? tr("隐藏", "Hide") : tr("显示", "Show"))
                    Text(tr("同一 Base URL 共用", "Shared by the same Base URL")).font(.caption).foregroundStyle(.secondary)
                }
                .onChange(of: key) { _, v in
                    let p = state.providers[i].profile()
                    guard v != KeyStore.apiKey(p) else { return } // 切换服务商时的载入不算修改
                    if !KeyStore.set(keyAccount(p), v) { status = tr("✗ API Key 保存失败", "✗ Failed to save API Key") }
                }
            }
            LabeledContent(tr("模型", "Model")) {
                HStack {
                    TextField("", text: $state.providers[i].model)
                    Menu(tr("从 /models 拉取", "Fetch from /models")) {
                        if models.isEmpty { Text(tr("（暂无，点「刷新列表」）", "(None yet, click “Refresh List”)")) }
                        ForEach(models, id: \.self) { m in Button(m) { state.providers[i].model = m } }
                        Divider()
                        Button(tr("刷新列表", "Refresh List")) {
                            Task {
                                status = tr("拉取中…", "Fetching…")
                                models = await Polisher.fetchModels(state.providers[i].profile(), apiKey: key)
                                status = models.isEmpty ? tr("该服务没有提供模型列表，请手动填写", "This service provides no model list; enter one manually") : tr("已拉取 \(models.count) 个模型", "Fetched \(models.count) models")
                            }
                        }
                    }.fixedSize()
                }
            }
            Section(tr("额外请求体 JSON（可选，按顶层键合并，可覆盖默认的关闭思考等提速参数）", "Extra request body JSON (optional, merged by top-level key; overrides the default speed settings such as thinking off)")) {
                TextEditor(text: $state.providers[i].extraJSON).font(.system(size: 11, design: .monospaced)).frame(height: 50)
            }
            HStack {
                Button(tr("测试连接", "Test Connection")) { test(i) }.disabled(busy)
                Text(status).foregroundStyle(status.hasPrefix("✓") ? .green : status.hasPrefix("✗") ? .red : .secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
        }.formStyle(.grouped)
    }

    func test(_ i: Int) {
        let p = state.providers[i].profile(instruction: defaultInstruction)
        busy = true
        status = tr("测试中…", "Testing…")
        let start = Date()
        let k = key
        Task {
            // 不走 Polisher.start 的看门狗，只有 URLSession 120s 空闲超时：服务端不回时按钮会一直禁用，这里限 10 秒
            let work = Task { try await Polisher.stream(p, apiKey: k, text: "你好") { _ in } }
            let dog = Task { try await Task.sleep(nanoseconds: 10_000_000_000); work.cancel() }
            do {
                _ = try await work.value
                status = String(format: tr("✓ 连接成功 · %.1f 秒", "✓ Connected · %.1f s"), Date().timeIntervalSince(start))
            } catch {
                status = work.isCancelled ? tr("✗ 超时：10 秒内没有完成，检查网络、Base URL 和模型", "✗ Timed out: no reply within 10 s; check the network, Base URL and model")
                    : "✗ " + Polisher.describe(error).localizedDescription
            }
            dog.cancel()
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
            Section {
                LabeledContent(tr("第一次使用？", "New to Polish?")) {
                    Button(tr("使用导引…", "Getting Started…")) { (NSApp.delegate as? Controller)?.openGuide() }
                }
            }
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
                Text(tr("停顿约 0.25 秒后，把正在输入的拼音发给当前配置的模型换算；按 ⌥1 / ⌥2 用所选内容替换刚敲的拼音。只在中文输入法激活时工作；密码框、安全输入和终端中不工作。需要「输入监控」权限。替换时用 Esc 撤销拼音；能读到输入框的应用会先核对光标前的内容，对不上就不删任何字，只把结果复制到剪贴板。","After a pause of about 0.25 s, the pinyin being typed is sent to the current profile’s model; press ⌥1 / ⌥2 to replace it with the chosen text. Works only while a Chinese input method is active; not in password fields, Secure Input or terminals. Requires the Input Monitoring permission. Replacing cancels the pinyin with Esc; in apps whose text field is readable, the text before the cursor is checked first, and if it doesn’t match nothing is deleted — the result is only copied to the clipboard."))
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

/// 使用统计：只读本地 usage/ 下的每日汇总；时间范围只是视图状态，不存设置
struct UsageTab: View {
    enum Range: CaseIterable { case today, d7, d30, d90, year, all, custom }
    @State var range = Range.d7
    @State var start = Date()
    @State var end = Date()
    @State var total = UsageDay()
    @State var days: [String] = []
    @State var daily: [UsageDay] = []
    @State var span: ClosedRange<Date>? // 图表横轴覆盖的日期（各取当天 0 点）；「全部」从最早有记录的一天起
    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    @State var confirmClear = false

    func label(_ r: Range) -> String {
        switch r {
        case .today: return tr("今天", "Today")
        case .d7: return tr("7 天", "7 days")
        case .d30: return tr("30 天", "30 days")
        case .d90: return tr("90 天", "90 days")
        case .year: return tr("今年", "This year")
        case .all: return tr("全部", "All")
        case .custom: return tr("自定义", "Custom")
        }
    }

    func reload() {
        UsageStore.shared.flush() // 内存里还没落盘的当天汇总也算上
        if start > end { (start, end) = (end, start) }
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        let from: Date?, to: Date?
        switch range {
        case .today: (from, to) = (today, today)
        case .d7: (from, to) = (cal.date(byAdding: .day, value: -6, to: today), today)
        case .d30: (from, to) = (cal.date(byAdding: .day, value: -29, to: today), today)
        case .d90: (from, to) = (cal.date(byAdding: .day, value: -89, to: today), today)
        case .year: (from, to) = (cal.dateInterval(of: .year, for: today)?.start, today)
        case .all: (from, to) = (nil, nil)
        case .custom: (from, to) = (start, end)
        }
        (total, days, daily) = UsageDay.load(dir: UsageStore.shared.dir, from: from.map { UsageDay.dayKey($0) }, to: to.map { UsageDay.dayKey($0) })
        let lo = (from ?? days.first.flatMap(Self.dayFormat.date)).map(cal.startOfDay)
        let hi = cal.startOfDay(for: to ?? today)
        span = lo.map { min($0, hi)...max($0, hi) }
    }

    func appName(_ bundle: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { FileManager.default.displayName(atPath: $0.path) } ?? bundle
    }

    func percent(_ n: Int, of d: Int) -> String { d == 0 ? "—" : "\(Int((Double(n) / Double(d) * 100).rounded()))%" }

    func median(_ l: Latency) -> String {
        guard let m = UsageDay.median(total.lat[l.rawValue] ?? []) else { return "—" }
        if m >= Double(UsageDay.buckets - 1) { return tr("4.9 秒以上", "4.9 s or more") }
        return tr("约 \(Int(m * 100) + 50)ms", "about \(Int(m * 100) + 50) ms") // 取所在 100ms 档的中点
    }

    /// 范围长短决定柱子粒度：只有 1 天时看结局构成（nil），≤31 天按天，≤92 天按周，更长按月
    func unit(_ s: ClosedRange<Date>) -> Calendar.Component? {
        let n = (Calendar.current.dateComponents([.day], from: s.lowerBound, to: s.upperBound).day ?? 0) + 1
        return n <= 1 ? nil : n <= 31 ? .day : n <= 92 ? .weekOfYear : .month
    }

    func outcomeName(_ o: PolishOutcome) -> String {
        switch o {
        case .accepted: return tr("替换", "Replaced")
        case .copied: return tr("复制", "Copied")
        case .cancelled: return tr("放弃", "Cancelled")
        case .dismissed: return tr("失焦", "Dismissed")
        case .failed: return tr("失败", "Failed")
        case .verifyFailed: return tr("校验失败", "Verification failed")
        }
    }

    /// 只有一天：时间轴上只有一根柱子没有意义，改看各结局的次数（横向柱，单系列，数值直接标在柱尾）
    var outcomeChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("润色结局", "Polish outcomes")).font(.subheadline)
            Chart(PolishOutcome.allCases, id: \.self) { o in
                let n = total.polishCount(o)
                BarMark(x: .value(tr("次数", "Count"), n), y: .value(tr("结局", "Outcome"), outcomeName(o)))
                    .foregroundStyle(Color.accentColor)
                    .annotation(position: .trailing) { Text("\(n)").font(.caption).foregroundStyle(.secondary) }
            }
            .chartXAxis(.hidden)
            .frame(height: 150)
        }
        .padding(.vertical, 4)
    }

    /// 按天 / 周 / 月的润色次数：采纳 / 其他结局叠成一根柱子（强调色对中性灰，带图例）；横轴覆盖整个范围，没记录的日子留空
    func trendChart(_ unit: Calendar.Component, _ s: ClosedRange<Date>) -> some View {
        let cal = Calendar.current
        let acc = tr("采纳", "Accepted"), other = tr("其他结局", "Other outcomes")
        var bins: [Date: (accepted: Int, all: Int)] = [:]
        for (day, d) in zip(days, daily) {
            guard let date = Self.dayFormat.date(from: day), let k = cal.dateInterval(of: unit, for: date)?.start else { continue }
            bins[k, default: (0, 0)].accepted += d.polishCount(.accepted)
            bins[k, default: (0, 0)].all += d.polishCount()
        }
        let lo = cal.dateInterval(of: unit, for: s.lowerBound)?.start ?? s.lowerBound
        let hi = cal.dateInterval(of: unit, for: s.upperBound)?.end ?? s.upperBound
        let slots = max(1, cal.dateComponents([unit], from: lo, to: hi).value(for: unit) ?? 1)
        let multiYear = cal.component(.year, from: lo) != cal.component(.year, from: s.upperBound)
        // 轴标签最多约 12 个：7 天以内逐天，再长隔几格标一次
        let step = slots <= 12 ? 1 : (slots + 11) / 12
        let format: Date.FormatStyle = unit == .month
            ? (multiYear ? .dateTime.year().month(.defaultDigits) : .dateTime.month(.abbreviated))
            : .dateTime.month(.defaultDigits).day()
        let title = unit == .day ? tr("每天润色次数", "Polishes per day") : unit == .weekOfYear ? tr("每周润色次数", "Polishes per week") : tr("每月润色次数", "Polishes per month")
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            Chart {
                ForEach(bins.sorted { $0.key < $1.key }, id: \.key) { date, c in
                    BarMark(x: .value(tr("日期", "Date"), date, unit: unit), y: .value(tr("次数", "Count"), c.accepted))
                        .foregroundStyle(by: .value(tr("结局", "Outcome"), acc))
                    BarMark(x: .value(tr("日期", "Date"), date, unit: unit), y: .value(tr("次数", "Count"), c.all - c.accepted))
                        .foregroundStyle(by: .value(tr("结局", "Outcome"), other))
                }
            }
            .chartForegroundStyleScale(domain: [acc, other], range: [Color.accentColor, Color.gray.opacity(0.45)])
            .chartXScale(domain: lo...hi)
            .chartXAxis {
                AxisMarks(values: .stride(by: unit, count: step)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: format, centered: true)
                }
            }
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 150)
        }
        .padding(.vertical, 4)
    }

    /// 首字耗时分布：每 100ms 一档的直方图，单系列不需要图例
    func latencyChart(_ h: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("首字耗时分布（最后一档为 4.9 秒以上）", "Time to first token (last bin is 4.9 s or more)")).font(.subheadline)
            Chart(Array(h.enumerated()).filter { $0.element > 0 }, id: \.offset) { i, n in
                BarMark(xStart: .value("ms", i * 100), xEnd: .value("ms", i * 100 + 100), y: .value(tr("次数", "Count"), n))
                    .foregroundStyle(Color.accentColor)
            }
            .chartXScale(domain: 0...(UsageDay.buckets * 100))
            .chartXAxis { AxisMarks(values: .stride(by: 1000)) { v in
                AxisGridLine()
                AxisValueLabel { Text("\((v.as(Int.self) ?? 0) / 1000)s") }
            } }
            .frame(height: 120)
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        // 解开键：[配置, bundle, 来源, 结局]
        let rows = total.polish.map { (UsageDay.fields($0.key), $0.value) }.filter { $0.0.count == 4 }
        let count = total.polishCount()
        let accepted = total.polishCount(.accepted)
        let profiles = Dictionary(grouping: rows, by: { $0.0[0] }).sorted { $0.key < $1.key }
        func failures(_ o: PolishOutcome) -> (Int, String) {
            let byApp = Dictionary(grouping: rows.filter { $0.0[3] == o.rawValue }, by: { $0.0[1] }).mapValues { $0.reduce(0) { $0 + $1.1 } }
            let top = byApp.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3)
            return (byApp.values.reduce(0, +), top.map { "\(appName($0.key)) \($0.value)" }.joined(separator: tr("、", ", ")))
        }
        let hints = Dictionary(total.hint.map { (UsageDay.fields($0.key).last ?? "", $0.value) }, uniquingKeysWith: +)
        let shown = hints[HintOutcome.shown.rawValue] ?? 0

        return Form { Section {
            Picker(tr("时间范围", "Range"), selection: $range) {
                ForEach(Range.allCases, id: \.self) { Text(label($0)).tag($0) }
            }
            if range == .custom {
                DatePicker(tr("开始", "From"), selection: $start, in: ...Date(), displayedComponents: .date)
                DatePicker(tr("结束", "To"), selection: $end, in: ...Date(), displayedComponents: .date)
            }
            if range == .all, let first = days.first {
                Text(tr("自 \(first) 起", "Since \(first)")).font(.caption).foregroundStyle(.secondary)
            }
            if total.isEmpty {
                Text(tr("这段时间没有记录", "No records in this period")).foregroundStyle(.secondary)
            } else {
                if count > 0, let s = span {
                    if let u = unit(s) { trendChart(u, s) } else { outcomeChart }
                }
                if let first = total.lat[Latency.polishFirst.rawValue], first.contains(where: { $0 > 0 }) { latencyChart(first) }
                LabeledContent(tr("润色", "Polish"), value: tr("\(count) 次 · 采纳率 \(percent(accepted, of: count))", "\(count) times · \(percent(accepted, of: count)) accepted"))
                ForEach(profiles, id: \.key) { name, rs in
                    let n = rs.reduce(0) { $0 + $1.1 }
                    let a = rs.filter { $0.0[3] == PolishOutcome.accepted.rawValue }.reduce(0) { $0 + $1.1 }
                    LabeledContent("    " + name, value: tr("\(n) 次 · 采纳率 \(percent(a, of: n))", "\(n) times · \(percent(a, of: n)) accepted"))
                }
                ForEach([(PolishOutcome.failed, tr("失败", "Failed")), (.verifyFailed, tr("校验失败", "Verification failed"))], id: \.0) { o, title in
                    let (n, top) = failures(o)
                    LabeledContent(title, value: n == 0 ? "0" : tr("\(n) 次 · \(top)", "\(n) · \(top)"))
                }
                LabeledContent(tr("耗时中位数", "Median latency"),
                               value: tr("首字 \(median(.polishFirst)) · 总计 \(median(.polishTotal))", "first token \(median(.polishFirst)) · total \(median(.polishTotal))"))
                LabeledContent(tr("输入提示", "Typing hints"),
                               value: tr("出现 \(shown) 次 · ⌥1 选中 \(percent(hints[HintOutcome.chosenEn.rawValue] ?? 0, of: shown)) · ⌥2 选中 \(percent(hints[HintOutcome.chosenZh.rawValue] ?? 0, of: shown))",
                                         "shown \(shown) times · ⌥1 chosen \(percent(hints[HintOutcome.chosenEn.rawValue] ?? 0, of: shown)) · ⌥2 chosen \(percent(hints[HintOutcome.chosenZh.rawValue] ?? 0, of: shown))"))
            }
            HStack {
                Text(tr("只记次数、耗时、应用和配置名，不含任何正文；只存在本机。", "Counts, latency, app and profile names only — never any text. Stored only on this Mac."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("打开文件夹", "Show in Finder")) {
                    let dir = UsageStore.shared.dir
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
                Button(tr("清空统计", "Clear…")) { confirmClear = true }
            }
            .confirmationDialog(tr("清空全部使用统计？", "Clear all usage statistics?"), isPresented: $confirmClear) {
                Button(tr("清空", "Clear"), role: .destructive) {
                    UsageStore.shared.clear()
                    reload()
                }
            } message: {
                Text(tr("删除 usage 文件夹里的所有记录，无法恢复。", "Deletes every record in the usage folder. This can't be undone."))
            }
        } }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .onChange(of: range) { reload() }
        .onChange(of: start) { reload() }
        .onChange(of: end) { reload() }
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
