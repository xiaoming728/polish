import AppKit
import SwiftUI

/// 两种浮层使用同一种系统材质，让透明度、深浅色与辅助功能设置由 macOS 处理。
struct PanelBackground: ViewModifier {
    let cornerRadius: CGFloat

    /// 系统玻璃 / 材质随窗口焦点变色（浅色下焦点窗口明显更白），翻译弹框又不能抢焦点；
    /// 叠一层接近焦点外观的底色，两种浮层的颜色和透明度一致，只透出少量玻璃
    private static let fill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.31, alpha: 0.8) : NSColor(white: 0.9, alpha: 0.8)
    })

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            content.background(Self.fill, in: shape).glassEffect(.regular, in: shape)
        } else {
            content.background(Self.fill, in: shape).background(.regularMaterial, in: shape)
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
