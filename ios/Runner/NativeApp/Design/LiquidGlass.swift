//
//  LiquidGlass.swift
//  Kazumi
//
//  iOS 26 原生液态玻璃封装：
//   * glassEffect / GlassEffectContainer 直接由系统渲染（折射、镜面高光、形变）；
//   * 关闭玻璃时退回可读的实色卡片，避免低性能设备上出现闪烁。
//

import SwiftUI

extension View {
    /// 悬浮胶囊：Tab 栏、顶部工具条、播放器 OSD 的通用外观。
    func kazumiGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(KazumiGlassShapeModifier(shape: AnyShape(Capsule(style: .continuous)), tint: tint, interactive: interactive))
    }

    /// 浮动卡片：选集面板、弹幕设置、详情页信息块。
    func kazumiGlassCard(cornerRadius: CGFloat = KazumiPalette.cardCornerRadius, tint: Color? = nil) -> some View {
        modifier(
            KazumiGlassShapeModifier(
                shape: AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)),
                tint: tint,
                interactive: false
            )
        )
    }

    /// 让相邻玻璃元素可以互相融合（Apple TV 风格的分组浮层）。
    func kazumiGlassContainer(spacing: CGFloat = 16) -> some View {
        modifier(KazumiGlassContainerModifier(spacing: spacing))
    }
}

private struct KazumiGlassShapeModifier: ViewModifier {
    let shape: AnyShape
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        content.background {
            if let tint {
                shape
                    .fill(tint.opacity(0.18))
            }
            shape
                .fill(.ultraThinMaterial)
            // AnyShape 擦除了 InsettableShape 约束，只能用 stroke（strokeBorder 不可用）。
            shape
                .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
        }
        .contentShape(shape)
        .modifier(KazumiNativeGlassEffect(shape: shape, tint: tint, interactive: interactive))
    }
}

/// iOS 26 原生玻璃效果，独立成 ViewModifier 以便编译期做可用性判断。
private struct KazumiNativeGlassEffect: ViewModifier {
    let shape: AnyShape
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
            } else {
                content.glassEffect(.regular.interactive(interactive), in: shape)
            }
        } else {
            content
        }
    }
}

private struct KazumiGlassContainerModifier: ViewModifier {
    let spacing: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// 播放器与首页共用的玻璃进度条（16:9 卡片内嵌）。
struct KazumiGlassProgressBar: View {
    var progress: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.22))
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(0, proxy.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 4)
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
    }
}
