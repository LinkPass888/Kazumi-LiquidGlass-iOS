//
//  KazumiPalette.swift
//  Kazumi
//
//  Apple TV App 风格的暗色画布 + iOS 26 液态玻璃质感的语义色。
//  色值与渐变在浅色 / 深色下分别取色，保证海报出血位的文字始终可读。
//

import SwiftUI

enum KazumiPalette {
    /// 强调色，对齐原项目主题的粉色系主色。
    static let accent = Color(red: 0.94, green: 0.29, blue: 0.55)

    /// 页面背景：与原版 Scaffold 的 surface 一致，浅色近白、深色近黑。
    static func background(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.07) : Color(red: 0.98, green: 0.98, blue: 0.99)
    }

    /// 卡片底色（对应 Material 的 surfaceContainerLow / 时间表卡片）。
    static func cardSurface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.12) : .white
    }

    static func heroBackground(for scheme: ColorScheme) -> LinearGradient {
        let base = scheme == .dark ? Color(white: 0.05) : Color(red: 0.97, green: 0.96, blue: 0.97)
        let elevated = scheme == .dark ? Color(white: 0.12) : Color(red: 0.93, green: 0.92, blue: 0.95)
        return LinearGradient(
            colors: [elevated, base],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Hero 剧照底部与背景融合的渐隐。
    static func heroFade(for scheme: ColorScheme) -> LinearGradient {
        let base = scheme == .dark ? Color(white: 0.05) : Color(red: 0.97, green: 0.96, blue: 0.97)
        return LinearGradient(
            stops: [
                .init(color: base.opacity(0), location: 0),
                .init(color: base.opacity(0.35), location: 0.45),
                .init(color: base.opacity(0.88), location: 0.78),
                .init(color: base, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func secondaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.68) : .black.opacity(0.58)
    }

    static func tertiaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.45) : .black.opacity(0.38)
    }

    /// 播放进度条轨道。
    static func progressTrack(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.16) : .black.opacity(0.10)
    }

    /// 海报圆角（Apple TV App 的 2:3 竖版海报使用连续圆角）。
    static let posterCornerRadius: CGFloat = 14
    static let cardCornerRadius: CGFloat = 20
    static let pillCornerRadius: CGFloat = 26
}
