//
//  KazumiThemeColor.swift
//  Kazumi
//
//  原版可更换的配色方案（lib/bean/settings/color_type.dart）。
//  种子色与原版逐一对应；主色由 Material 3 的 `ColorScheme.fromSeed` 规则
//  预先换算成 T40（浅色）/ T80（深色），与原版界面取到的 primary 完全一致。
//

import SwiftUI
import UIKit

/// 一套配色：种子色 + 浅色 / 深色下实际使用的强调色。
struct KazumiThemeColor: Identifiable, Hashable, Sendable {
    /// 持久化用的标识（不落 UIColor，保证 Codable / 备份可读）。
    let id: String
    let title: String
    /// 原版 `colorThemeTypes` 里的种子色。
    let seed: UInt32
    /// `ColorScheme.fromSeed` 在浅色模式下的 primary（tonal palette T40）。
    let lightPrimary: UInt32
    /// `ColorScheme.fromSeed` 在深色模式下的 primary（tonal palette T80）。
    let darkPrimary: UInt32

    /// 默认项：原版 `Colors.green`，label 为「默认」。
    static let standard = KazumiThemeColor(
        id: "default",
        title: "默认",
        seed: 0xFF4CAF50,
        lightPrimary: 0xFF006E1C,
        darkPrimary: 0xFF78DC77
    )

    /// 与 lib/bean/settings/color_type.dart 的 `colorThemeTypes` 顺序、标签、色值一致。
    static let all: [KazumiThemeColor] = [
        .standard,
        KazumiThemeColor(
            id: "teal",
            title: "青色",
            seed: 0xFF009688,
            lightPrimary: 0xFF006A60,
            darkPrimary: 0xFF67D9C9
        ),
        KazumiThemeColor(
            id: "blue",
            title: "蓝色",
            seed: 0xFF2196F3,
            lightPrimary: 0xFF0061A4,
            darkPrimary: 0xFF9ECAFF
        ),
        KazumiThemeColor(
            id: "indigo",
            title: "靛蓝色",
            seed: 0xFF3F51B5,
            lightPrimary: 0xFF4355B9,
            darkPrimary: 0xFFBAC3FF
        ),
        KazumiThemeColor(
            id: "violet",
            title: "紫罗兰色",
            seed: 0xFF6750A4,
            lightPrimary: 0xFF6750A4,
            darkPrimary: 0xFFCFBCFF
        ),
        KazumiThemeColor(
            id: "pink",
            title: "粉红色",
            seed: 0xFFE91E63,
            lightPrimary: 0xFFBC004B,
            darkPrimary: 0xFFFFB2BE
        ),
        KazumiThemeColor(
            id: "yellow",
            title: "黄色",
            seed: 0xFFFFEB3B,
            lightPrimary: 0xFF695F00,
            darkPrimary: 0xFFDBC90A
        ),
        KazumiThemeColor(
            id: "orange",
            title: "橙色",
            seed: 0xFFFF9800,
            lightPrimary: 0xFF8B5000,
            darkPrimary: 0xFFFFB870
        ),
        KazumiThemeColor(
            id: "deepOrange",
            title: "深橙色",
            seed: 0xFFFF5722,
            lightPrimary: 0xFFB02F00,
            darkPrimary: 0xFFFFB5A0
        ),
    ]

    // MARK: - ARGB 工具

    /// 0xAARRGGBB -> SwiftUI Color。
    /// 供需要非动态色（例如选中态的浅色底）的调用点使用，避免每次手写 UIColor 包装。
    static func swiftUIColor(_ argb: UInt32) -> Color {
        Color(uiColor: color(argb))
    }

    /// 按持久化标识查找；未知标识（例如旧版备份里的 ARGB 字符串）回落到默认绿色。
    static func named(_ id: String) -> KazumiThemeColor {
        all.first { $0.id == id } ?? Self.standard
    }

    /// 当前选中的配色。由 `SettingsStore` 在读写设置时同步，
    /// `KazumiPalette.accent` 据此取色；只允许在主线程访问。
    @MainActor
    static var current: KazumiThemeColor = .standard

    /// 该配色对应的动态强调色（浅色 / 深色自动切换）。
    ///
    /// 动态色由 UIKit 在解析时按 `userInterfaceStyle` 取亮/暗分支，
    /// 必须是稳定且长期存活的同一个实例，因此在主线程按配色缓存。
    @MainActor
    var accentUIColor: UIColor {
        if let cached = Self.uiColorCache[id] { return cached }
        let dark = Self.color(darkPrimary)
        let light = Self.color(lightPrimary)
        let color = UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
        Self.uiColorCache[id] = color
        return color
    }

    @MainActor
    private static var uiColorCache: [String: UIColor] = [:]

    /// 深色模式是否使用纯黑（对应原版 `SettingsKeys.oledEnhance`）。
    /// `KazumiPalette` 的背景色在 `View` 体系之外也可能被求值，因此不做 actor 隔离，
    /// 仅允许主线程写入（设置页与启动装配都在主线程）。
    nonisolated(unsafe) static var oledEnhance = false

    /// 0xAARRGGBB -> UIColor。
    static func color(_ argb: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255
        )
    }
}
