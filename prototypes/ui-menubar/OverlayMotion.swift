// PROTOTYPE：浮层视觉改进（风格统一 / 出现消失动画 / 等待流光）的改前改后对照，一次性代码，不合入 main。
// 运行：./run.sh motion [--dark|--light] [--reduce]
// 左栏「改前」照搬现有写法，右栏「改后」是要移植进 Sources/Polish 的写法；两栏共用同一份假数据，按脚本循环播放。
import AppKit
import NaturalLanguage
import SwiftUI

let args = CommandLine.arguments
/// 原型里模拟「减弱动态效果」；正式代码读 accessibilityReduceMotion / NSWorkspace
let reduceMotion = args.contains("--reduce") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
func tr(_ zh: String, _ en: String) -> String { args.contains("--en") ? en : zh }

// MARK: - 共用的假数据

@MainActor final class HintModel: ObservableObject {
    @Published var pinyin = ""
    @Published var en: String?
    @Published var zh: String?
    @Published var pairs: [(zh: String, en: String)] = []
    @Published var shown = false // 改后：窗口可见；驱动出现动画和流光，隐藏前先置 false
}

enum Phase: Equatable { case streaming, done, failed(String), verifyFailed(String) }

@MainActor final class PanelModel: ObservableObject {
    @Published var phase = Phase.streaming
    @Published var output = ""
    @Published var profile = "通用润色"
    @Published var shown = false
}

func wordTags(_ text: String) -> [(Range<String.Index>, NLTag)] {
    let t = NLTagger(tagSchemes: [.lexicalClass])
    t.string = text
    var r: [(Range<String.Index>, NLTag)] = []
    t.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
        if let tag { r.append((range, tag)) }
        return true
    }
    return r
}

func ranges(_ text: String, _ parts: [String]) -> [(Range<String.Index>, Int)] {
    parts.enumerated().compactMap { i, p in text.range(of: p).map { ($0, i) } }
}

// MARK: - 改前（照搬 TypingHintView / PanelView / ToastView）

struct BeforeHint: View {
    @ObservedObject var model: HintModel
    static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .brown, .red]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.en != nil || model.zh != nil {
                if let en = model.en { row("⌥1", en, primary: true) } else { pending("⌥1") }
                if let zh = model.zh { row("⌥2", zh, primary: false) } else { pending("⌥2") }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ProgressView().controlSize(.small).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("正在翻译").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Text(model.pinyin).font(.system(size: 13)).lineLimit(3)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PanelBackground(cornerRadius: 16))
    }
    func pending(_ key: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Badge(key: key, primary: false)
            ProgressView().controlSize(.mini).padding(.top, 2)
            Text("翻译中…").font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
    func row(_ key: String, _ text: String, primary: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Badge(key: key, primary: primary)
            VStack(alignment: .leading, spacing: 3) {
                Text(colored(text, primary: primary)).font(.system(size: 13, weight: primary ? .semibold : .regular))
                if primary { Text(legend(text)).font(.system(size: 10)).lineLimit(2) }
            }
        }
    }
    func pos(_ tag: NLTag) -> (String, Color)? {
        switch tag {
        case .noun: return ("名词", .blue)
        case .verb: return ("动词", .orange)
        case .adjective: return ("形容词", .purple)
        case .adverb: return ("副词", .pink)
        case .determiner: return ("限定词", .secondary)
        case .interjection: return ("感叹词", .red)
        default: return nil
        }
    }
    func colored(_ text: String, primary: Bool) -> AttributedString {
        var r = AttributedString(text)
        for (range, i) in ranges(text, model.pairs.map { primary ? $0.en : $0.zh }) {
            if let a = Range(range, in: r) { r[a].foregroundColor = Self.palette[i % Self.palette.count] }
        }
        return r
    }
    func legend(_ text: String) -> AttributedString {
        var r = AttributedString()
        let pairs = ranges(text, model.pairs.map(\.en))
        for (range, tag) in wordTags(text) {
            guard let (label, color) = pos(tag) else { continue }
            var item = AttributedString((r.characters.isEmpty ? "" : "  ·  ") + text[range] + "（" + label + "）")
            item.foregroundColor = pairs.first { $0.0.overlaps(range) }.map { Self.palette[$0.1 % Self.palette.count] } ?? color
            r += item
        }
        return r
    }
}

struct Badge: View {
    let key: String, primary: Bool
    var body: some View {
        Text(key).font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(primary ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

struct BeforePanel: View {
    @ObservedObject var m: PanelModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").foregroundStyle(.purple)
                Text(m.profile).font(.caption.weight(.semibold))
                Text("→ 备忘录").font(.caption).foregroundStyle(.secondary)
                Spacer()
                switch m.phase {
                case .streaming: HStack(spacing: 4) { ProgressView().controlSize(.small); Text("润色中").font(.caption) }
                case .done: Label("完成", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                case .failed: Label("失败", systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                case .verifyFailed: Label("未替换", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
            problem(m.phase)
            Text(m.output + (m.phase == .streaming ? "▍" : "")).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            footer(m.phase)
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PanelBackground(cornerRadius: 20))
    }
}

@ViewBuilder func problem(_ p: Phase) -> some View {
    switch p {
    case .failed(let s): Banner(text: s, color: .red)
    case .verifyFailed(let s): Banner(text: s, color: .orange)
    default: EmptyView()
    }
}

struct Banner: View {
    let text: String, color: Color
    var body: some View {
        Text(text).font(.system(size: 12)).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

@ViewBuilder func footer(_ p: Phase) -> some View {
    HStack(spacing: 12) {
        switch p {
        case .streaming: Key("⌥P", tr("取消", "Cancel")); Key("Esc", tr("放弃", "Discard"))
        case .done: Key("⏎", tr("替换", "Replace")); Key("⌘C", tr("复制", "Copy")); Key("Esc", tr("放弃", "Discard"))
        default: Key("⌘C", tr("复制结果", "Copy result")); Key("Esc", tr("关闭", "Close"))
        }
    }
}

struct Key: View {
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

struct BeforeToast: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill").font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
    }
}

struct PanelBackground: ViewModifier { // 与正式代码一致，不改
    let cornerRadius: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape).overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}

// MARK: - 改后：以下是要移植的部件

/// 出现：淡入 + 0.96→1 + 上移 dy；只在 shown 变为 true 时播放，减弱动态效果时只淡入
struct PopIn: ViewModifier {
    let shown: Bool
    var scale: CGFloat = 0.96
    var dy: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        let still = shown || reduce || reduceMotion
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(still ? 1 : scale)
            .offset(y: still ? 0 : dy)
            .animation(shown ? .spring(duration: 0.15) : nil, value: shown)
    }
}

/// 等待中的扫光：一道高光从左到右循环扫过文字；active 为 false 时移除，循环动画随之停止
struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content.foregroundStyle(active ? .secondary : .primary)
            .overlay { if active && !reduce && !reduceMotion { ShimmerBand().mask(content) } }
    }
}

struct ShimmerBand: View {
    @State private var x: CGFloat = 0
    var body: some View {
        GeometryReader { g in
            let band = max(60, g.size.width * 0.35)
            LinearGradient(colors: [.clear, .primary, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: -band + x * (g.size.width + band))
        }
        .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { x = 1 } }
    }
}

/// ⌥P 面板外圈的旋转描边光：画在玻璃背景外面一层
struct GlowRing: View {
    let cornerRadius: CGFloat
    let tint: Color
    @State private var angle = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        GeometryReader { g in
            let d = hypot(g.size.width, g.size.height)
            AngularGradient(colors: [tint.opacity(0.1), tint, tint.opacity(0.45), tint.opacity(0.1), tint.opacity(0.1)], center: .center)
                .frame(width: d, height: d)
                .rotationEffect(.degrees(angle))
                .position(x: g.size.width / 2, y: g.size.height / 2)
        }
        .mask(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(lineWidth: 1.5))
        .allowsHitTesting(false)
        .onAppear {
            guard !reduce, !reduceMotion else { return }
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { angle = 360 }
        }
    }
}

/// 校验失败的提示条：出现时左右轻晃一次（250ms）
struct ShakeOnAppear: ViewModifier {
    @State private var n = 0
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 0.0, trigger: n) { v, x in v.offset(x: x) } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(-6, duration: 0.05); LinearKeyframe(6, duration: 0.07)
                    LinearKeyframe(-3, duration: 0.07); LinearKeyframe(0, duration: 0.06)
                }
            }
            .onAppear { if !reduce && !reduceMotion { n += 1 } }
    }
}

/// 完成图标：出现时 bounce 一次
struct BounceOnAppear: ViewModifier {
    @State private var n = 0
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content.symbolEffect(.bounce, value: n).onAppear { if !reduce && !reduceMotion { n += 1 } }
    }
}

struct AfterHint: View {
    @ObservedObject var model: HintModel
    static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal]
    var waiting: Bool { model.en == nil && model.zh == nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !waiting {
                Group {
                    if let en = model.en { row("⌥1", en, primary: true) } else { pending("⌥1") }
                    if let zh = model.zh { row("⌥2", zh, primary: false) } else { pending("⌥2") }
                }.transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("正在翻译", "Translating")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(model.pinyin).font(.system(size: 13)).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(Shimmer(active: model.shown))
                }.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: waiting) // 只在「翻译中 ↔ 结果」切换时交叉淡化，拼音变化不动画
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(minWidth: 240, alignment: .leading)
        .modifier(PanelBackground(cornerRadius: 16))
        .modifier(PopIn(shown: model.shown))
    }
    func pending(_ key: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Badge(key: key, primary: false)
            Text(tr("翻译中…", "Translating…")).font(.system(size: 13)).modifier(Shimmer(active: model.shown))
        }
    }
    func row(_ key: String, _ text: String, primary: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Badge(key: key, primary: primary)
            VStack(alignment: .leading, spacing: 3) {
                Text(colored(text, primary: primary)).font(.system(size: 13, weight: primary ? .semibold : .regular))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if primary {
                    Text(legend(text)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    func pos(_ tag: NLTag) -> String? {
        switch tag {
        case .noun: return tr("名词", "noun")
        case .verb: return tr("动词", "verb")
        case .adjective: return tr("形容词", "adj.")
        case .adverb: return tr("副词", "adv.")
        case .determiner: return tr("限定词", "det.")
        case .interjection: return tr("感叹词", "interj.")
        default: return nil
        }
    }
    func colored(_ text: String, primary: Bool) -> AttributedString {
        var r = AttributedString(text)
        for (range, i) in ranges(text, model.pairs.map { primary ? $0.en : $0.zh }) {
            if let a = Range(range, in: r) { r[a].foregroundColor = Self.palette[i % Self.palette.count] }
        }
        return r
    }
    func legend(_ text: String) -> String {
        wordTags(text).compactMap { range, tag in pos(tag).map { text[range] + tr("（\($0)）", " (\($0))") } }.joined(separator: "  ·  ")
    }
}

struct AfterPanel: View {
    @ObservedObject var m: PanelModel
    var waiting: Bool { m.phase == .streaming && m.output.isEmpty }
    var glow: Double { !m.shown || m.phase != .streaming ? 0 : waiting ? 1 : 0.5 }
    @State private var failFlash = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").foregroundStyle(Color.accentColor)
                Text(m.profile).font(.caption.weight(.semibold))
                Text(tr("→ 备忘录", "→ Notes")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                switch m.phase {
                case .streaming: Text(tr("润色中", "Polishing")).font(.caption).foregroundStyle(.secondary)
                case .done: Label(tr("完成", "Done"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).modifier(BounceOnAppear())
                case .failed: Label(tr("失败", "Failed"), systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                case .verifyFailed: Label(tr("未替换", "Not replaced"), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
            if case .verifyFailed(let s) = m.phase { Banner(text: s, color: .orange).modifier(ShakeOnAppear()) } else { problem(m.phase) }
            Group {
                if waiting {
                    Text("▍").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).transition(.opacity)
                } else {
                    Text(m.output + (m.phase == .streaming ? "▍" : "")).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).transition(.opacity)
                }
            }
            .animation(waiting ? .easeOut(duration: 0.15) : nil, value: waiting) // ⌘1–9 重跑：旧结果淡出
            Spacer(minLength: 0)
            footer(m.phase)
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PanelBackground(cornerRadius: 20))
        .overlay {
            if glow > 0 || failFlash {
                GlowRing(cornerRadius: 20, tint: failFlash ? .orange : .accentColor).opacity(failFlash ? 1 : glow).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: glow)
        .onChange(of: m.phase) { _, p in
            guard case .failed = p else { return }
            failFlash = true
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { failFlash = false } }
        }
        .modifier(PopIn(shown: m.shown))
    }
}

struct AfterToast: View {
    let text: String
    @State private var shown = false
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill").font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .modifier(PopIn(shown: shown, scale: 1, dy: 6))
            .onAppear { shown = true }
    }
}

// MARK: - 窗口层：改前 / 改后各自的显示、隐藏逻辑

func makePanel() -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.level = .floating
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.ignoresMouseEvents = true
    return p
}

@MainActor final class HintWindow {
    let panel = makePanel()
    let after: Bool
    let model: HintModel
    var anchor = NSPoint.zero
    var dismissal = 0
    var lastWaiting: Bool?
    let probe: NSHostingController<AfterHint>
    init(model: HintModel, after: Bool) {
        self.model = model
        self.after = after
        probe = NSHostingController(rootView: AfterHint(model: model))
        panel.contentView = after ? NSHostingView(rootView: AnyView(AfterHint(model: model))) : NSHostingView(rootView: AnyView(BeforeHint(model: model)))
    }
    func size() -> NSSize {
        let host = panel.contentView!
        host.layoutSubtreeIfNeeded()
        guard after else { return host.fittingSize }
        // 宽度随内容：按最宽 420 测量，内容不足 240 时由 minWidth 撑开
        let s = probe.sizeThatFits(in: NSSize(width: 420, height: 10_000))
        return NSSize(width: ceil(min(max(s.width, 240), 420)), height: ceil(s.height))
    }
    func show() {
        dismissal += 1
        panel.alphaValue = 1
        let s = size()
        let frame = NSRect(x: anchor.x, y: anchor.y, width: s.width, height: s.height)
        let waiting = model.en == nil && model.zh == nil
        // 只在「翻译中 ↔ 结果」切换时过渡窗口尺寸；每次拼音变化直接设置
        if after, panel.isVisible, model.shown, lastWaiting != waiting, !reduceMotion {
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.12
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        lastWaiting = waiting
        panel.orderFrontRegardless()
        if after, !model.shown { model.shown = true }
    }
    func fadeOut() {
        dismissal += 1
        let current = dismissal
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = after ? 0.1 : 0.25
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                guard self.dismissal == current else { return }
                if self.after { self.model.shown = false } // 先停流光再隐藏
                self.panel.orderOut(nil)
            }
        }
    }
}

@MainActor final class PanelWindow {
    let panel = makePanel()
    let after: Bool
    let model: PanelModel
    var frame = NSRect.zero
    init(model: PanelModel, after: Bool) {
        self.model = model
        self.after = after
        let host = NSHostingView(rootView: after ? AnyView(AfterPanel(m: model)) : AnyView(BeforePanel(m: model)))
        host.sizingOptions = []
        panel.contentView = host
    }
    func show() {
        if !panel.isVisible { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
        if after, !model.shown { model.shown = true }
    }
    func hide() { // ⌥P 面板关闭不加动画：⏎ 替换要立刻让出焦点
        if after { model.shown = false }
        panel.orderOut(nil)
    }
}

@MainActor final class ToastWindow {
    let panel = makePanel()
    let after: Bool
    var anchor = NSPoint.zero
    var gen = 0
    init(after: Bool) { self.after = after }
    func show(_ text: String) {
        gen += 1
        let host = NSHostingView(rootView: after ? AnyView(AfterToast(text: text)) : AnyView(BeforeToast(text: text)))
        panel.contentView = host
        panel.alphaValue = 1
        panel.setFrame(NSRect(origin: anchor, size: host.fittingSize), display: true)
        panel.orderFrontRegardless()
    }
    func hide() {
        guard after else { return panel.orderOut(nil) }
        gen += 1
        let current = gen
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { if self.gen == current { self.panel.orderOut(nil) } }
        }
    }
}

// MARK: - 舞台与脚本

struct Stage: View {
    var body: some View {
        HStack(spacing: 0) {
            column(tr("改前", "Before"))
            Divider()
            column(tr("改后", "After"))
        }
        .frame(width: 1200, height: 760)
        .background(.background)
    }
    func column(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.bold())
            Text(reduceMotion ? "减弱动态效果：开" : (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "深色" : "浅色"))
                .foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
                .overlay(alignment: .topLeading) { Text("备忘录 · 输入框").font(.caption).foregroundStyle(.secondary).padding(8) }
                .frame(height: 90)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor final class Demo: NSObject, NSApplicationDelegate {
    var stage: NSWindow!
    let hint = HintModel(), panel = PanelModel()
    var hints: [HintWindow] = [], panels: [PanelWindow] = [], toasts: [ToastWindow] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        stage = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        stage.title = "Polish 浮层动效对照"
        stage.contentView = NSHostingView(rootView: Stage())
        stage.center()
        stage.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let f = stage.frame
        for (i, after) in [false, true].enumerated() {
            let x = f.minX + CGFloat(i) * 600 + 24
            let h = HintWindow(model: hint, after: after); h.anchor = NSPoint(x: x, y: f.maxY - 330); hints.append(h)
            let p = PanelWindow(model: panel, after: after); p.frame = NSRect(x: x, y: f.minY + 60, width: 460, height: 270); panels.append(p)
            let t = ToastWindow(after: after); t.anchor = NSPoint(x: x, y: f.minY + 140); toasts.append(t)
        }
        if let s = args.firstIndex(of: "--snap").map({ Double(args[$0 + 1])! }) { // 截图用：播放到第 s 秒停住
            run(stopAt: s)
        } else {
            run(stopAt: nil)
        }
    }

    func at(_ t: Double, _ f: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated(f) }
    }

    func run(stopAt: Double?) {
        let en = "Hello world, the weather is really nice today"
        let zh = "你好世界，今天天气真好"
        let typed = ["n", "ni", "nih", "nihao", "nihaos", "nihaoshi", "nihaoshijie", "nihaoshijie jintian", "nihaoshijie jintiantianqi", "nihaoshijie jintiantianqi zhenhao"]
        let result = "今天天气真好，适合出去走走。我们下午三点在公园门口见，记得带上相机。"
        var steps: [(Double, @MainActor () -> Void)] = []
        // 输入提示：逐键变化（不应有动画）→ ⌥1 先出、⌥2 后出 → 淡出
        for (i, p) in typed.enumerated() {
            steps.append((0.3 + Double(i) * 0.18, { [self] in
                hint.pinyin = p; hint.en = nil; hint.zh = nil; hint.pairs = []
                hints.forEach { $0.show() }
            }))
        }
        steps.append((3.4, { [self] in
            hint.en = en
            hint.pairs = [("你好", "Hello"), ("世界", "world"), ("今天", "today"), ("天气", "weather"), ("真好", "really nice")]
            hints.forEach { $0.show() }
        }))
        steps.append((3.9, { [self] in hint.zh = zh; hints.forEach { $0.show() } }))
        steps.append((5.6, { [self] in hints.forEach { $0.fadeOut() } }))
        // ⌥P：等待（光边全亮旋转）→ 流式（光边减半）→ 完成（bounce、光边淡出）
        steps.append((6.2, { [self] in panel.phase = .streaming; panel.output = ""; panel.profile = tr("通用润色", "General"); panels.forEach { $0.show() } }))
        let chunks = stride(from: 0, through: result.count, by: 3).map { String(result.prefix($0)) }
        for (i, c) in chunks.enumerated() { steps.append((8.0 + Double(i) * 0.06, { [self] in panel.output = c })) }
        steps.append((8.0 + Double(chunks.count) * 0.06 + 0.1, { [self] in panel.output = result; panel.phase = .done }))
        // ⌘2 换配置重跑：旧结果淡出，新结果流式出现
        steps.append((11.0, { [self] in panel.profile = tr("正式邮件", "Formal email"); panel.phase = .streaming; panel.output = "" }))
        for (i, c) in chunks.enumerated() { steps.append((12.0 + Double(i) * 0.05, { [self] in panel.output = c })) }
        steps.append((12.0 + Double(chunks.count) * 0.05 + 0.1, { [self] in panel.output = result; panel.phase = .done }))
        // ⏎ 替换但校验失败：面板立刻收起，再弹出失败提示条（晃一下）
        steps.append((14.6, { [self] in panels.forEach { $0.hide() } }))
        steps.append((14.8, { [self] in panel.phase = .verifyFailed(tr("回填前校验失败：原来的选中内容已变化。为防止误覆盖，没有替换。", "Verification failed: the selection changed, so nothing was replaced.")); panels.forEach { $0.show() } }))
        steps.append((16.6, { [self] in panels.forEach { $0.hide() } }))
        // 完成胶囊
        steps.append((16.8, { [self] in toasts.forEach { $0.show(tr("已替换", "Replaced")) } }))
        steps.append((18.4, { [self] in toasts.forEach { $0.hide() } }))
        // 请求失败：光边变橙色闪一下
        steps.append((19.0, { [self] in panel.phase = .streaming; panel.output = ""; panels.forEach { $0.show() } }))
        steps.append((20.4, { [self] in panel.phase = .failed(tr("401 Unauthorized：API Key 无效", "401 Unauthorized: invalid API key")) }))
        steps.append((22.2, { [self] in panels.forEach { $0.hide() } }))
        let loop = 23.0
        for (t, f) in steps {
            if let s = stopAt, t > s { continue }
            at(t, f)
        }
        if stopAt == nil, !args.contains("--once") { at(loop) { [self] in run(stopAt: nil) } }
        if args.contains("--once") { at(loop) { NSApp.terminate(nil) } }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let demo = Demo()
    app.delegate = demo
    app.setActivationPolicy(.regular)
    app.run()
}
