import AppKit
import PolishCore
import SwiftUI

// MARK: - 预览面板（跟随光标的紧凑浮层，见「预览面板、小提示与设置界面的形态」）

struct KeyHint: View {
    let k: String, t: String
    init(_ k: String, _ t: String) { self.k = k; self.t = t }
    var body: some View {
        HStack(spacing: 3) {
            Text(k).font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(t).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct PanelView: View {
    @ObservedObject var state: AppState
    @State var showSource = false

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
            if let (msg, color) = problem {
                Text(msg).font(.system(size: 12)).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }
            if !state.output.isEmpty || state.phase == .streaming {
                ScrollView {
                    Text(state.output + (state.phase == .streaming ? "▍" : ""))
                        .font(.system(size: 13)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            HStack(spacing: 12) { footer }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
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
        let n = min(state.profiles.count, 9)
        let switchHint = n > 1 ? "⌘1–\(n)" : nil
        switch state.phase {
        case .streaming:
            KeyHint(state.hotKey.name, "取消"); KeyHint("Esc", "放弃")
            if let s = switchHint { KeyHint(s, "换配置") }
        case .done:
            KeyHint("⏎", acceptLabel)
            if !state.copyOnly { KeyHint("⌘C", "复制") }
            KeyHint("Esc", "放弃")
            if let s = switchHint { KeyHint(s, "换配置重跑") }
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
    var body: some View {
        TabView {
            ProfilesTab(state: state).tabItem { Label("配置", systemImage: "slider.horizontal.3") }
            GeneralTab(state: state, rebind: rebind).tabItem { Label("通用", systemImage: "gearshape") }
            TerminalTab().tabItem { Label("终端集成", systemImage: "terminal") }
            PermissionTab().tabItem { Label("权限与隐私", systemImage: "lock.shield") }
        }
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
                        p.name = "新配置"
                        p.instruction = defaultInstruction
                        state.profiles.append(p)
                        sel = p.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        guard let i = index, state.profiles.count > 1 else { return }
                        let id = state.profiles[i].id
                        Keychain.set(id.uuidString, "") // 只清旧版按配置存的 Key；按服务存的 Key 可能被其他场景共用
                        state.profiles.remove(at: i)
                        if state.currentID == id { state.currentID = state.profiles[0].id }
                        sel = state.currentID
                    } label: { Image(systemName: "minus") }.disabled(state.profiles.count <= 1)
                    Spacer()
                    Button("设为当前") { if let s = sel { state.currentID = s } }.disabled(sel == nil || sel == state.currentID)
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
        if let i = index { key = Keychain.apiKey(state.profiles[i]) }
    }

    func form(_ i: Int) -> some View {
        Form {
            TextField("名称", text: $state.profiles[i].name)
            Picker("服务商", selection: $state.profiles[i].preset) {
                ForEach(presets, id: \.name) { Text($0.name).tag($0.name) }
            }
            .onChange(of: state.profiles[i].preset) { _, new in
                guard let p = presets.first(where: { $0.name == new }) else { return }
                state.profiles[i].wire = p.wire
                if !p.baseURL.isEmpty { state.profiles[i].baseURL = p.baseURL }
                state.profiles[i].model = p.model
            }
            Picker("协议", selection: $state.profiles[i].wire) {
                Text("OpenAI 兼容").tag(Wire.openAI)
                Text("Anthropic").tag(Wire.anthropic)
            }
            TextField("Base URL", text: $state.profiles[i].baseURL)
                .onChange(of: state.profiles[i].baseURL) { _, _ in loadKey() } // Key 跟着服务走
            LabeledContent("API Key") {
                HStack {
                    // 密码框禁止向外复制（系统行为）；需要查看或复制时切到明文
                    if showKey { TextField("", text: $key) } else { SecureField("", text: $key) }
                    Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless).help(showKey ? "隐藏" : "显示")
                    Text("同一服务的场景共用").font(.caption).foregroundStyle(.secondary)
                }
                .onChange(of: key) { _, v in
                    guard v != Keychain.apiKey(state.profiles[i]) else { return } // 切换配置时的载入不算修改
                    if !Keychain.set(keyAccount(state.profiles[i]), v) { status = "✗ API Key 保存到钥匙串失败" }
                }
            }
            LabeledContent("模型") {
                HStack {
                    TextField("", text: $state.profiles[i].model)
                    Menu("从 /models 拉取") {
                        if models.isEmpty { Text("（暂无，点「刷新列表」）") }
                        ForEach(models, id: \.self) { m in Button(m) { state.profiles[i].model = m } }
                        Divider()
                        Button("刷新列表") {
                            Task {
                                status = "拉取中…"
                                models = await Polisher.fetchModels(state.profiles[i], apiKey: key)
                                status = models.isEmpty ? "该服务没有提供模型列表，请手动填写" : "已拉取 \(models.count) 个模型"
                            }
                        }
                    }.fixedSize()
                }
            }
            Section("润色指令") {
                TextEditor(text: $state.profiles[i].instruction).font(.system(size: 12)).frame(height: 110)
                Button("恢复默认指令") { state.profiles[i].instruction = defaultInstruction }
            }
            Section("额外请求体 JSON（可选，按顶层键合并，写各家方言参数）") {
                TextEditor(text: $state.profiles[i].extraJSON).font(.system(size: 11, design: .monospaced)).frame(height: 50)
            }
            HStack {
                Button("测试连接") { test(i) }.disabled(busy)
                Text(status).foregroundStyle(status.hasPrefix("✓") ? .green : status.hasPrefix("✗") ? .red : .secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
        }.formStyle(.grouped)
    }

    func test(_ i: Int) {
        let p = state.profiles[i]
        busy = true
        status = "测试中…"
        let start = Date()
        Task {
            do {
                _ = try await Polisher.stream(p, apiKey: key, text: "你好") { _ in }
                status = String(format: "✓ 连接成功 · %.1f 秒", Date().timeIntervalSince(start))
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
    @State var hint = "至少包含 ⌘ / ⌥ / ⌃ 之一；被其他应用占用时会提示并保留原快捷键。"

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
                hint = "需要至少包含 ⌘ / ⌥ / ⌃ 中的一个修饰键。"
                return nil
            }
            let spec = HotKeySpec(code: UInt32(e.keyCode), mods: HotKey.carbonMods(f),
                                  name: hotkeyName(control: f.contains(.control), option: f.contains(.option), shift: f.contains(.shift), command: f.contains(.command), key: ch))
            hint = rebind(spec) ? "已改为 \(spec.name)，立即生效。" : "\(spec.name) 已被占用，保留 \(state.hotKey.name)。"
            stop()
            return nil
        }
    }

    var body: some View {
        Form {
            Section("快捷键") {
                LabeledContent("润色选中文字") {
                    HStack {
                        Text(recording ? "请按下新的快捷键…" : state.hotKey.name)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .frame(minWidth: 150).padding(.vertical, 4)
                            .background(Color.primary.opacity(recording ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 6))
                        Button(recording ? "取消" : "录制") { recording ? stop() : record() }
                    }
                }
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Section("回填方式") {
                Picker("", selection: $state.fillMode) {
                    ForEach(FillMode.allCases, id: \.self) { m in
                        VStack(alignment: .leading) {
                            Text(m.rawValue)
                            Text(m.detail).font(.caption).foregroundStyle(.secondary)
                        }.tag(m)
                    }
                }.pickerStyle(.radioGroup).labelsHidden()
            }
            Section("请求") {
                LabeledContent("超时", value: "首字 30 秒 / 总计 120 秒")
                LabeledContent("失败时", value: "不自动重试，原文不动")
                LabeledContent("进行中再按快捷键", value: "取消本次润色")
            }
        }
        .formStyle(.grouped)
        .onDisappear { stop() }
    }
}

struct SnippetBox: View {
    let title: String, code: String
    @State var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(copied ? "已复制 ✓" : "复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }
            }
            Text(code).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct TerminalTab: View {
    /// 取当前 .app 的实际位置；路径含空格时用单引号包住
    var editor: String {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/polish-edit").path
        return path.contains(" ") ? "'\(path)'" : path
    }

    var zsh: String {
        """
        # Polish：zsh 输入行按 Ctrl+G 交给 polish-edit（放在 bindkey -v / -e 之后）
        autoload -Uz edit-command-line
        zle -N polish-edit-command-line edit-command-line
        zstyle ':zle:polish-edit-command-line' editor \(editor)
        bindkey -M emacs '^G' polish-edit-command-line
        bindkey -M viins '^G' polish-edit-command-line
        bindkey -M vicmd '^G' polish-edit-command-line
        """
    }

    var aliases: String {
        """
        alias claude='POLISH_FALLBACK_EDITOR="${VISUAL:-$EDITOR}" VISUAL=\(editor) claude'
        alias codex='POLISH_FALLBACK_EDITOR="${VISUAL:-$EDITOR}" VISUAL=\(editor) codex'
        """
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("在终端（Terminal、Ghostty、iTerm2）中按快捷键时，Polish 会发送 Ctrl+G，由 polish-edit 接管整段草稿；确认后写回输入框，不会自动执行或发送。请把下面两段加到 ~/.zshrc 末尾，然后重开终端。")
                    .fixedSize(horizontal: false, vertical: true)
                SnippetBox(title: "1. zsh 输入行", code: zsh)
                SnippetBox(title: "2. Claude Code / Codex", code: aliases)
                Label("bash 不支持：Ctrl+X Ctrl+E 编辑后会直接执行命令。bash 中改为润色终端选区后复制。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Label("ssh 到远程或未配置的 zsh 中，Ctrl+G 会清空当前行；执行 print -z -- $ZLE_LINE_ABORTED 可恢复。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                Label("移动 Polish.app 后需要重新复制上面的片段。", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(4)
        }
    }
}

struct PermissionTab: View {
    @State var trusted = Permissions.trusted
    var body: some View {
        Form {
            Section("权限") {
                HStack {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(trusted ? .green : .red)
                    Text("辅助功能")
                    Spacer()
                    Button("刷新") { trusted = Permissions.trusted }
                    Button("打开系统设置") { Permissions.openSettings() }
                }
                Text("读取选区和回填需要辅助功能权限。ad-hoc 签名的应用每次重新构建后都要重新授权（先在列表中移除旧条目再添加）。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("隐私") {
                Text("只发送本次选中的文字（终端中为当前输入框草稿）；不监听键盘输入；日志不含正文和 Key；API Key 存在钥匙串；临时占用剪贴板后会恢复，期间若被其他程序改动则不恢复。")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped)
    }
}
