//
//  SearchResultCard.swift
//  Kazumi
//
//  搜索结果网格里的那张卡（Colo 3053 / kazumi-search-results-layout.md）：
//  * 卡宽由网格算好传进来（402 屏 2 列时是 179）；
//  * 封面比例 0.7（179×256），12 圆角；
//  * 封面下 10 → 标题（两行、14 半粗、行高 1.4）；
//  * 再 4 → 元信息行：星 14 ＋ 分数 ＋ 年份。
//
//  和列表页共用的 `BangumiPosterCard` 分开：那张是 main 的 bangumi_card（0.65、
//  标题 15 三行、没有元信息行），列表页按它来；搜索结果是另一套排法。
//

import SwiftUI

struct SearchResultCard: View {
    let item: BangumiItem
    /// 网格算出来的列宽，卡片按它铺满。
    let width: CGFloat
    var zoomNamespace: Namespace.ID?

    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    /// 封面宽高比（Colo 3053）。
    private static let coverAspectRatio: CGFloat = 0.7
    private static let cornerRadius: CGFloat = 12
    /// 标题行高 1.4 在 14 号字上是 19.6，行间距补 5.6。
    private static let titleSize: CGFloat = 14
    private static let titleLineSpacing: CGFloat = 5.6

    private var year: String {
        String(item.airDate.prefix(4))
    }

    var body: some View {
        Button {
            // zoom 走默认（true）：跟时间表、追番页那张卡一样，点开时卡片原地放大成详情页。
            // 原来这里写死 false，所以搜索结果点进去是普通的横向推入（LP 3096）。
            router.push(.bangumiInfo(bangumiID: item.id))
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                BangumiRemoteImage(url: item.largeImage)
                    .frame(width: width, height: width / Self.coverAspectRatio)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))

                Text(item.displayName)
                    .font(.system(size: Self.titleSize, weight: .semibold))
                    .lineSpacing(Self.titleLineSpacing)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)

                metaRow
                    .padding(.top, 4)
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .kazumiZoomSource(id: item.id, namespace: zoomNamespace)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.displayName)
        .accessibilityHint("打开详情")
    }

    /// 元信息行：星 ＋ 分数 ＋ 年份，拿不到的项直接省掉。
    private var metaRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .font(.system(size: 14))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
            if item.ratingScore > 0 {
                Text(String(format: "%.1f", item.ratingScore))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if !year.isEmpty, year.count == 4 {
                Text(year)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
