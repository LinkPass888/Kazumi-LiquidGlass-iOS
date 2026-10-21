//
//  BangumiPosterCard.swift
//  Kazumi
//
//  1:1 复刻 lib/bean/card/bangumi_card.dart 的 BangumiCardV：
//  竖版海报（宽高比 0.65）+ 下方中文标题（最多 3 行，12 圆角），
//  点击进入详情页。推荐页与搜索结果共用同一个卡片。
//

import SwiftUI

struct BangumiPosterCard: View {
    let item: BangumiItem
    var canTap: Bool = true
    var onTap: ((BangumiItem) -> Void)?

    @Environment(AppRouter.self) private var router

    /// 与 constants.dart 的 StyleString.imgRadius 一致。
    private static let cornerRadius: CGFloat = 12
    /// 与 bangumi_card.dart 的 aspectRatio: 0.65 一致。
    static let coverAspectRatio: CGFloat = 0.65

    var body: some View {
        Button {
            guard canTap else { return }
            if let onTap {
                onTap(item)
            } else {
                router.push(.bangumiInfo(bangumiID: item.id))
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                BangumiRemoteImage(url: item.largeImage)
                    .aspectRatio(Self.coverAspectRatio, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))

                Text(item.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .kerning(0.3)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 与 Dart 版 EdgeInsets.fromLTRB(5, 3, 5, 1) 一致。
                    .padding(.init(top: 3, leading: 5, bottom: 1, trailing: 5))
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.displayName)
    }
}
