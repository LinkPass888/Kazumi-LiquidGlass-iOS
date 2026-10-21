//
//  KazumiLayout.swift
//  Kazumi
//
//  自适应布局常量（对照 utils/constants.dart 的 LayoutBreakpoint）。
//  iPhone 单列 + 底部胶囊 Tab；iPad 多列 + 侧边栏 + 顶部胶囊工具条。
//

import SwiftUI

enum KazumiLayout {
    static let compactWidth: CGFloat = 600
    static let mediumWidth: CGFloat = 840
    static let cardSpacing: CGFloat = 8
    static let safePadding: CGFloat = 12
    static let shelfSpacing: CGFloat = 26

    /// 2:3 竖版海报宽度：iPhone 约 128pt，iPad 随列数放大。
    static func posterWidth(containerWidth: CGFloat) -> CGFloat {
        if containerWidth < compactWidth {
            return 128
        } else if containerWidth < mediumWidth {
            return 150
        } else {
            return 172
        }
    }

    /// 自适应列数（iPad 上 2:3 海报铺满整行）。
    static func posterColumns(containerWidth: CGFloat) -> Int {
        let target = posterWidth(containerWidth: containerWidth)
        let count = Int((containerWidth + safePadding) / (target + safePadding))
        return max(2, count)
    }

    /// 16:9 「继续观看」卡片宽度。
    static func episodeCardWidth(containerWidth: CGFloat) -> CGFloat {
        containerWidth < compactWidth ? 268 : 320
    }

    /// Hero 出血位高度。
    static func heroHeight(containerWidth: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        containerWidth < compactWidth ? min(viewportHeight * 0.62, 520) : 460
    }
}
