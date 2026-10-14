import AppKit
import SwiftUI

/// 两种浮层使用同一种系统材质，让透明度、深浅色与辅助功能设置由 macOS 处理。
struct PanelBackground: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}

extension NSView {
    /// 浮层窗口的内容图层裁成与背景同样的圆角：焦点窗口的系统阴影按方形窗口计算，不裁会在圆角外露出方角黑框
    func roundCorners(_ radius: CGFloat) {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
}
