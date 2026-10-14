import SwiftUI

// 浮层动效：只在状态变化时播放；「减弱动态效果」打开时只保留淡入淡出，循环动画改为静态。

/// 出现：淡入 + 从 scale 放大到 1 + 上移 dy（150ms 弹性）；只在 shown 变为 true 时播放
struct PopIn: ViewModifier {
    let shown: Bool
    var scale: CGFloat = 0.96
    var dy: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        let still = shown || reduce
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(still ? 1 : scale)
            .offset(y: still ? 0 : dy)
            .animation(shown ? .spring(duration: 0.15) : nil, value: shown)
    }
}

/// 等待中的扫光：一道高光从左到右循环扫过文字；active 为 false 时移除高光，循环动画随之停止
struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content.foregroundStyle(active ? .secondary : .primary)
            .overlay { if active && !reduce { ShimmerBand().mask(content) } }
    }
}

private struct ShimmerBand: View {
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

/// 浮层外圈的光边：level 为亮度（0 不显示，视图移除、旋转停止）；
/// failed 变为 true 时橙色闪一下再淡出；done 期间保留淡绿细边（静态），变为 true 时先亮绿加粗闪一下再收细
struct GlowBorder: ViewModifier {
    let cornerRadius: CGFloat
    let level: Double
    let failed: Bool
    let done: Bool
    @State private var flash = false
    @State private var doneFlash = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .overlay { // 画在玻璃背景外面一层
                ZStack {
                    if level > 0 || flash {
                        GlowRing(cornerRadius: cornerRadius, tint: flash ? .orange : .accentColor).opacity(flash ? 1 : level).transition(.opacity)
                    }
                    if done {
                        // 窗口与内容等大，外扩会被裁掉：用描边由粗变细表现「放大再收回」
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.green.opacity(doneFlash ? 1 : 0.4), lineWidth: doneFlash && !reduce ? 3 : 1)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: level)
                .animation(.easeOut(duration: 0.2), value: done)
            }
            .onChange(of: failed) { _, f in
                guard f else { return }
                flash = true
                DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { flash = false } }
            }
            .onChange(of: done) { _, d in
                guard d else { return }
                doneFlash = true
                DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { doneFlash = false } }
            }
    }
}

/// 缓慢旋转的描边光
struct GlowRing: View {
    let cornerRadius: CGFloat
    let tint: Color
    @State private var angle = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        GeometryReader { g in
            let d = hypot(g.size.width, g.size.height) // 旋转时四角也要被渐变盖住
            AngularGradient(colors: [tint.opacity(0.1), tint, tint.opacity(0.45), tint.opacity(0.1), tint.opacity(0.1)], center: .center)
                .frame(width: d, height: d)
                .rotationEffect(.degrees(angle))
                .position(x: g.size.width / 2, y: g.size.height / 2)
        }
        .mask(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(lineWidth: 1.5))
        .allowsHitTesting(false)
        .onAppear {
            guard !reduce else { return }
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { angle = 360 }
        }
    }
}

/// 出现时左右轻晃一次（250ms）
struct ShakeOnAppear: ViewModifier {
    @State private var n = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 0.0, trigger: n) { v, x in v.offset(x: x) } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(-6, duration: 0.05)
                    LinearKeyframe(6, duration: 0.07)
                    LinearKeyframe(-3, duration: 0.07)
                    LinearKeyframe(0, duration: 0.06)
                }
            }
            .onAppear { if !reduce { n += 1 } }
    }
}

/// 出现时图标 bounce 一次
struct BounceOnAppear: ViewModifier {
    @State private var n = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content.symbolEffect(.bounce, value: n).onAppear { if !reduce { n += 1 } }
    }
}
