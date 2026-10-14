import Foundation
import PolishCore

/// 设置界面文字：按「界面语言」设置选中文或英文；未设置时跟随系统首选语言（中文系统用中文，其余用英文）
func tr(_ zh: String, _ en: String) -> String {
    let lang = UserDefaults.standard.string(forKey: "uiLanguage")
        ?? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en")
    return lang == "en" ? en : zh
}

enum FillMode: String, Codable, CaseIterable {
    case preview = "预览"
    case auto = "自动替换"
    case toast = "小提示确认"

    var name: String {
        switch self {
        case .preview: return tr(rawValue, "Preview")
        case .auto: return tr(rawValue, "Replace automatically")
        case .toast: return tr(rawValue, "Confirm in toast")
        }
    }

    var detail: String {
        switch self {
        case .preview: return tr("弹出预览面板，流式显示结果；⏎ 替换 / ⌘C 复制 / Esc 放弃", "Show a preview panel that streams the result; ⏎ replace / ⌘C copy / Esc discard")
        case .auto: return tr("完成后校验通过即直接替换；失败或校验不通过时弹出面板", "Replace as soon as the result passes checks; show the panel on failure")
        case .toast: return tr("不展开全文，完成后出现小提示，⏎ 替换", "Show a small toast when done instead of the full text; ⏎ replace")
        }
    }
}

/// 终端里按快捷键时投递给前台程序的「用外部编辑器编辑」按键；各家 Agent 不同，用户按常用的选
enum TerminalKey: String, CaseIterable {
    case ctrlG = "Ctrl+G"
    case ctrlXCtrlE = "Ctrl+X Ctrl+E"
    case ctrlX = "Ctrl+X"
    case ctrlXE = "Ctrl+X E"

    var detail: String {
        switch self {
        case .ctrlG: return tr("zsh 输入行、Claude Code、Codex", "zsh line editor, Claude Code, Codex")
        case .ctrlXCtrlE: return tr("zsh 输入行、Claude Code、Aider 等 readline / prompt_toolkit 类", "zsh line editor, Claude Code, Aider and other readline / prompt_toolkit apps")
        case .ctrlX: return tr("Qoder / qodercn、Gemini CLI、Qwen Code（zsh 输入行不可用）", "Qoder / qodercn, Gemini CLI, Qwen Code (not for the zsh line editor)")
        case .ctrlXE: return tr("OpenCode（zsh 输入行不可用）", "OpenCode (not for the zsh line editor)")
        }
    }
}

enum Phase: Equatable {
    case streaming, done
    case failed(String)
    case verifyFailed(String)
}

/// 持久化设置（UserDefaults；Key 在本地 keys.json，见 KeyStore）+ 当前润色会话的显示状态
@MainActor
final class AppState: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var profiles: [Profile] { didSet { save() } }
    @Published var currentID: UUID { didSet { save() } }
    @Published var fillMode: FillMode { didSet { save() } }
    @Published var hotKey: HotKeySpec { didSet { save() } }
    /// 输入时中英提示（中文输入法下敲拼音时显示 ⌥1 英文 / ⌥2 中文）
    @Published var typingAssist: Bool { didSet { save() } }
    /// 输入提示的英文先查 macOS 本地词典，查不到再问模型
    @Published var localDictionary: Bool { didSet { save() } }
    /// 输入提示 ⌥1 的翻译目标语言
    @Published var targetLanguage: TypingLanguage { didSet { save() } }
    /// 用户的默认语言；nil 跟随系统首选语言
    @Published var nativeLanguage: TypingLanguage? { didSet { save() } }
    /// 在键盘布局（ABC 等）下输入时，提示译成默认语言（⌥1）；会把键盘布局下敲的文字发给模型，默认关
    @Published var reverseTyping: Bool { didSet { save() } }
    @Published var terminalKey: TerminalKey { didSet { save() } }
    /// 设置界面语言："zh" / "en"；nil 跟随系统（tr 直接读 UserDefaults）
    @Published var uiLanguage: String? { didSet { save() } }
    /// 使用导引已弹出过（关闭即算）；之后启动不再自动弹出
    @Published var guideShown: Bool { didSet { save() } }
    /// 设置窗口当前标签页，不持久化；openSettings(tab:) 从外部切换
    @Published var settingsTab = 0

    @Published var source = ""
    @Published var output = ""
    @Published var phase = Phase.done
    @Published var target = ""
    @Published var terminal = false
    @Published var copyOnly = false

    var native: TypingLanguage { nativeLanguage ?? .system() }
    var current: Profile { profiles.first { $0.id == currentID } ?? profiles[0] }

    init() {
        let dec = JSONDecoder()
        let ps = defaults.data(forKey: "profiles").flatMap { try? dec.decode([Profile].self, from: $0) } ?? []
        // 首次启动给出全部默认场景；老用户只补齐一次（之后删掉的场景不再加回来）
        let seeded = defaults.bool(forKey: "scenesSeeded")
        let list = ps.isEmpty ? sceneProfiles(base: defaultProfile()) : seeded ? ps : addMissingScenes(ps)
        defaults.set(true, forKey: "scenesSeeded")
        profiles = list
        currentID = defaults.string(forKey: "currentID").flatMap(UUID.init).flatMap { id in list.contains { $0.id == id } ? id : nil } ?? list[0].id
        fillMode = defaults.string(forKey: "fillMode").flatMap(FillMode.init) ?? .preview
        hotKey = defaults.data(forKey: "hotKey").flatMap { try? dec.decode(HotKeySpec.self, from: $0) } ?? .standard
        typingAssist = defaults.object(forKey: "typingAssist") as? Bool ?? true
        localDictionary = defaults.object(forKey: "localDictionary") as? Bool ?? true
        targetLanguage = defaults.string(forKey: "targetLanguage").flatMap(TypingLanguage.init) ?? .english
        nativeLanguage = defaults.string(forKey: "nativeLanguage").flatMap(TypingLanguage.init)
        reverseTyping = defaults.bool(forKey: "reverseTyping")
        terminalKey = defaults.string(forKey: "terminalKey").flatMap(TerminalKey.init) ?? .ctrlG
        uiLanguage = defaults.string(forKey: "uiLanguage")
        guideShown = defaults.bool(forKey: "guideShown")
        save() // init 中赋值不触发 didSet，补齐的场景要显式保存
    }

    private func save() {
        let enc = JSONEncoder()
        defaults.set(try? enc.encode(profiles), forKey: "profiles")
        defaults.set(currentID.uuidString, forKey: "currentID")
        defaults.set(fillMode.rawValue, forKey: "fillMode")
        defaults.set(try? enc.encode(hotKey), forKey: "hotKey")
        defaults.set(typingAssist, forKey: "typingAssist")
        defaults.set(localDictionary, forKey: "localDictionary")
        defaults.set(targetLanguage.rawValue, forKey: "targetLanguage")
        defaults.set(nativeLanguage?.rawValue, forKey: "nativeLanguage")
        defaults.set(reverseTyping, forKey: "reverseTyping")
        defaults.set(terminalKey.rawValue, forKey: "terminalKey")
        defaults.set(uiLanguage, forKey: "uiLanguage")
        defaults.set(guideShown, forKey: "guideShown")
    }
}
