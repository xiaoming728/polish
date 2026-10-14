import SwiftUI

/// 两种浮层使用同一种系统材质，让透明度、深浅色与辅助功能设置由 macOS 处理。
struct PanelBackground: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        glass(content, shape).overlay(shape.strokeBorder(Color.primary.opacity(0.1))) // 两种浮层同一条细边框
    }

    @ViewBuilder
    private func glass(_ content: Content, _ shape: RoundedRectangle) -> some View {
        if #available(macOS 26, *) {
            // 玻璃的通透度随面积和窗口焦点变化（小提示框更透），统一着色让两种浮层底色一致
            content.glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.5)), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
