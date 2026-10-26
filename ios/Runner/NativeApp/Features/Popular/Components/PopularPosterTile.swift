//
//  PopularPosterTile.swift
//  Kazumi
//
//  推荐页货架里的一张海报（Colo 规格 §3）：96×144、圆角 12、无遮罩无角标，
//  下面两行 12pt 居中标题。
//
//  为什么带名字：Bangumi 的封面是日文原版图，用户认的是中文译名，两样对不上
//  不是个别现象；两行 12pt 在 96 宽里装 16 个字，正好接上追番页 15 字的标准。
//

import SwiftUI

struct PopularPosterTile: View {
    let poster: PopularPoster
    var zoomNamespace: Namespace.ID?

    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    /// 规格 §3 的固定尺寸：宽屏也不放大，货架靠「露出更多张」传达还有内容。
    static let width: CGFloat = 96
    static let height: CGFloat = 144
    static let cornerRadius: CGFloat = 12
    /// 标题两行的高度（12pt / 行高 1.3 × 2）。
    ///
    /// 31 会裁掉第二行：两行实高 ≈ 12×1.2 + 3.6 + 12×1.2 ≈ 31.8，比 31 高，
    /// 于是第二行被切、只剩一个省略号（Colo 2781 看到的现象）。留 34 给两行腾地方。
    static let titleHeight: CGFloat = 34
    /// 一行总高：144 + 6 + 34。
    static let totalHeight: CGFloat = height + 6 + titleHeight

    var body: some View {
        Button {
            router.push(.bangumiInfo(bangumiID: poster.id))
        } label: {
            VStack(spacing: 6) {
                BangumiRemoteImage(url: poster.imageURL)
                    .frame(width: Self.width, height: Self.height)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))

                Text(poster.displayName)
                    .font(.system(size: 12))
                    .lineSpacing(1.3 * 12 - 12)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: Self.width, height: Self.titleHeight, alignment: .top)
            }
            .frame(width: Self.width)
        }
        .buttonStyle(.plain)
        .kazumiZoomSource(id: poster.id, namespace: zoomNamespace)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(poster.displayName)
        .accessibilityHint("打开详情")
    }
}
