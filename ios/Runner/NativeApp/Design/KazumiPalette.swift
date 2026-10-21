//
//  KazumiPalette.swift
//  Kazumi
//
//  Apple TV App 风格的暗色画布 + iOS 26 液态玻璃质感的语义色。
//  色值与渐变在浅色 / 深色下分别取色，保证海报出血位的文字始终可读。
//

import SwiftUI
import UIKit

enum KazumiPalette {
    /// 强调色。
    ///
    /// 取色方式与原版一致：原项目用 `ColorScheme.fromSeed(seedColor:)` 生成主题，
    /// 界面上的 primary 并不是种子色本身，而是种子色在对应亮度下的 tonal palette
    /// 里取出的一档（Material 3 的 T40 / T80，见 `KazumiThemeColor`）。
    /// 返回 `UIColor` 承载的动态色，SwiftUI 每次渲染都会按当时的浅色 / 深色与
    /// 当前配色重新解析，因此切换配色后所有调用点自动跟随。
    @MainActor
    static var accent: Color {
        Color(uiColor: KazumiThemeColor.current.accentUIColor)
    }

    /// 按当前浅色 / 深色取的强调色。
    ///
    /// 主题色的两档数值来自 Material 3：浅色模式是 T40（深），深色模式是 T80（浅）。
    /// 这里**显式**按 `colorScheme` 取，不走 `UIColor` 的动态解析 ——
    /// 动态色最终由 UIKit 的 trait collection 决定，自绘顶栏、隐藏导航栏这些
    /// 场景下它和 SwiftUI 的 colorScheme 可能对不上，就会出现「深色模式用了
    /// 浅色模式的色、浅色模式用了深色模式的色」这种对调。
    static func accent(for scheme: ColorScheme) -> Color {
        let theme = KazumiThemeColor.current
        return KazumiThemeColor.swiftUIColor(
            scheme == .dark ? theme.darkPrimary : theme.lightPrimary
        )
    }

    /// 强调色上的前景色（对应 Material 的 onPrimary）：
    /// 浅色模式强调色深 → 白字；深色模式强调色浅 → 黑字。
    static func onAccent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : .white
    }

    /// 页面背景：与原版 Scaffold 的 surface 一致，浅色近白、深色近黑。
    /// 深色下默认取近黑（`Color(white: 0.07)`），开启 OLED 优化时用纯黑。
    static func background(for scheme: ColorScheme) -> Color {
        if scheme == .dark {
            return KazumiThemeColor.oledEnhance ? .black : Color(white: 0.07)
        }
        return Color(red: 0.98, green: 0.98, blue: 0.99)
    }

    /// 卡片底色（对应 Material 的 surfaceContainerLow / 时间表卡片）。
    static func cardSurface(for scheme: ColorScheme) -> Color {
        if scheme == .dark {
            return KazumiThemeColor.oledEnhance ? Color(white: 0.05) : Color(white: 0.12)
        }
        return .white
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
