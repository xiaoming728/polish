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
            .allowsHitTesting(false) // 标题行没有按钮：整行交给背后的拖动区
            if let (msg, color) = problem {
                Text(msg).font(.system(size: 12)).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }
            if !state.output.isEmpty || state.phase == .streaming {
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(state.profiles.prefix(9).enumerated()), id: \.element.id) { i, p in
                            KeyHint("⌘\(i + 1)", p.name).opacity(p.id == state.currentID ? 1 : 0.55)
                        }
                    }
                }
            }
            HStack(spacing: 12) { footer }
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
    var body: some View {
        TabView {
            ProfilesTab(state: state).tabItem { Label("配置", systemImage: "slider.horizontal.3") }
            GeneralTab(state: state, rebind: rebind).tabItem { Label("通用", systemImage: "gearshape") }
            TerminalTab(state: state).tabItem { Label("终端集成", systemImage: "terminal") }
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
        if let i = index { key = KeyStore.apiKey(state.profiles[i]) }
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
                    guard v != KeyStore.apiKey(state.profiles[i]) else { return } // 切换配置时的载入不算修改
                    if !KeyStore.set(keyAccount(state.profiles[i]), v) { status = "✗ API Key 保存失败" }
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
            Section("输入时中英提示") {
                Toggle("中文输入法下敲拼音时，在光标上方显示 ⌥1 \(state.targetLanguage.name) / ⌥2 中文", isOn: $state.typingAssist)
                LanguagePicker(title: "⌥1 翻译成", selection: Binding(get: { state.targetLanguage }, set: { if let l = $0 { state.targetLanguage = l } }),
                               excluded: .chinese)
                    .disabled(!state.typingAssist)
                LanguagePicker(title: "默认语言", selection: $state.nativeLanguage, followSystem: "跟随系统（\(TypingLanguage.system().name)）")
                    .disabled(!state.typingAssist)
                Toggle("在键盘布局（ABC 等）下输入时，提示译成\(state.native.name)，⌥1 替换（会把敲的文字发给模型；终端、密码框中不工作）", isOn: $state.reverseTyping)
                    .disabled(!state.typingAssist)
                Toggle("英文优先查 macOS 本地词典（牛津英汉汉英词典，离线、即时；短语和查不到的词再问模型）", isOn: $state.localDictionary)
                    .disabled(!state.typingAssist || state.targetLanguage != .english)
                Text("停顿约 0.25 秒后，把正在输入的拼音发给当前配置的模型换算；按 ⌥1 / ⌥2 用所选内容替换刚敲的拼音。只在中文输入法激活时工作；密码框、安全输入和终端中不工作。需要「输入监控」权限。替换时按敲过的键数退格撤销拼音：个别输入法若在组合态吞掉按键，可能多删光标前的字，可用 ⌘Z 撤销。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    Text(selection?.name ?? followSystem ?? "")
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(spacing: 6) {
                    TextField("搜索语言（中文、English、代码）", text: $query)
                        .textFieldStyle(.roundedBorder)
                    List {
                        if let followSystem, query.isEmpty { row(followSystem, nil) }
                        ForEach(TypingLanguage.all.filter { $0 != excluded && $0.matches(query) }) { row($0.name, $0) }
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
                    Label(stale ? "已安装（需更新）" : "已安装", systemImage: stale ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(stale ? .orange : .green)
                }
                Spacer()
                Button(copied ? "已复制 ✓" : "复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }
                if installed {
                    Button("卸载") { apply(RcBlock.remove(rc, id: id), done: "已从 ~/.zshrc 移除「\(title)」") }
                }
                if !installed || stale {
                    Button(stale ? "更新" : "安装") {
                        let clean = replaces.reduce(rc) { RcBlock.remove($0, id: $1) }
                        apply(RcBlock.install(clean, id: id, body: code), done: "已写入 ~/.zshrc：「\(title)」")
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
            message = done + "。新开的终端窗口生效（已打开的窗口执行 source ~/.zshrc）；已在运行的 Agent 要退出后重新启动。改动前的内容备份在 ~/.zshrc.polish-backup。"
        } catch {
            message = "写入 ~/.zshrc 失败：\(error.localizedDescription)"
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
                Text("在终端（Terminal、Ghostty、iTerm2、kitty、WezTerm、Alacritty、Warp 等）中按快捷键时，Polish 会先给当前程序发送下面选定的按键，0.5 秒内没连上再试 Ctrl+G / Ctrl+X 中的另一个，让它用外部编辑器打开草稿，由 polish-edit 读取后立即放回；润色期间 CLI 照常可用，确认后再打开一次写回输入框，不会自动执行或发送。点「安装」把对应片段写到 ~/.zshrc 末尾（带 Polish 标记，「卸载」只删这一段），然后重开终端。")
                    .fixedSize(horizontal: false, vertical: true)
                Picker("优先发送的按键", selection: $state.terminalKey) {
                    ForEach(TerminalKey.allCases, id: \.self) { k in
                        Text("\(k.rawValue)　\(k.detail)").tag(k)
                    }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(message.hasPrefix("写入") ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SnippetBox(title: "zsh 输入行", id: "zsh", code: zsh, rc: $rc, message: $message)
                SnippetBox(title: "终端 Agent 与其他程序", id: "agents", code: agents, replaces: ["claude", "codex"], rc: $rc, message: $message)
                if RcBlock.has(rc, id: "claude") || RcBlock.has(rc, id: "codex") {
                    Label("检测到旧版的 Claude Code / Codex 单独片段，安装上面这一项时会自动替换掉。", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Label("Agent 只在启动时读取编辑器设置：安装前就在运行的会话，按快捷键会打开 vi 等原编辑器。退出后在新终端窗口重新启动即可。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Label("bash 不支持：Ctrl+X Ctrl+E 编辑后会直接执行命令。bash 中改为润色终端选区后复制。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Label("ssh 到远程或未配置的 zsh 中，Ctrl+G 会清空当前行；执行 print -z -- $ZLE_LINE_ABORTED 可恢复。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                Label("移动 Polish.app 后，已安装的片段会显示「需更新」，点一下即可。", systemImage: "arrow.triangle.2.circlepath")
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
                Text("润色时只发送本次选中的文字（终端中为当前输入框草稿）。开启「输入时中英提示」后，会在中文输入法下读取正在敲的拼音键，并把拼音发给当前配置的模型（终端中只发送输入法候选词，不发送按键），可随时在菜单中关闭；日志不含正文和 Key；API Key 存在本机文件（仅你的账号可读）；临时占用剪贴板后会恢复，期间若被其他程序改动则不恢复。")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped)
    }
}
