import Foundation
import PolishCore

enum FillMode: String, Codable, CaseIterable {
    case preview = "预览"
    case auto = "自动替换"
    case toast = "小提示确认"

    var detail: String {
        switch self {
        case .preview: return "弹出预览面板，流式显示结果；⏎ 替换 / ⌘C 复制 / Esc 放弃"
        case .auto: return "完成后校验通过即直接替换；失败或校验不通过时弹出面板"
        case .toast: return "不展开全文，完成后出现小提示，⏎ 替换"
        }
    }
}

enum Phase: Equatable {
    case streaming, done
    case failed(String)
    case verifyFailed(String)
}

/// 持久化设置（UserDefaults；Key 在钥匙串）+ 当前润色会话的显示状态
@MainActor
final class AppState: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var profiles: [Profile] { didSet { save() } }
    @Published var currentID: UUID { didSet { save() } }
    @Published var fillMode: FillMode { didSet { save() } }
    @Published var hotKey: HotKeySpec { didSet { save() } }
    /// 输入时中英提示（中文输入法下敲拼音时显示 ⌥1 英文 / ⌥2 中文）
    @Published var typingAssist: Bool { didSet { save() } }

    @Published var source = ""
    @Published var output = ""
    @Published var phase = Phase.done
    @Published var target = ""
    @Published var terminal = false
    @Published var copyOnly = false

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
        save() // init 中赋值不触发 didSet，补齐的场景要显式保存
        // 0.0.1 早期按配置 id 存 Key；迁移到按服务归属，补齐的场景才能共用。
        // 只做一次，且放到后台：ad-hoc 重建后读钥匙串会弹系统确认框，同步读会卡住启动
        if !defaults.bool(forKey: "keysMigrated") {
            defaults.set(true, forKey: "keysMigrated")
            Task.detached {
                for p in list where Keychain.get(keyAccount(p)) == nil {
                    if let k = Keychain.get(p.id.uuidString) { Keychain.set(keyAccount(p), k) }
                }
            }
        }
    }

    private func save() {
        let enc = JSONEncoder()
        defaults.set(try? enc.encode(profiles), forKey: "profiles")
        defaults.set(currentID.uuidString, forKey: "currentID")
        defaults.set(fillMode.rawValue, forKey: "fillMode")
        defaults.set(try? enc.encode(hotKey), forKey: "hotKey")
        defaults.set(typingAssist, forKey: "typingAssist")
    }
}
