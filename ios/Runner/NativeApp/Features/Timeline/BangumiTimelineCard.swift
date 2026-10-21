//
//  BangumiTimelineCard.swift
//  Kazumi
//
//  1:1 复刻 lib/bean/card/bangumi_timeline_card.dart：
//  * 左封面（88pt，同心圆角 16，整体外框圆角 28）、右详情；
//  * 标题 2 行，后面是「评分」与「标签 · 标签」；
//  * 底部是「xx 更新」「第 N 话」两个胶囊 + 正在追的书签图标。
//

import SwiftUI

struct BangumiTimelineCard: View {
    let item: BangumiItem
    var showRating: Bool = true
    var isWatching: Bool = false
    var compact: Bool = false
    var updateText: String?
    var currentEpisode: Int?
    var onTap: (() -> Void)?

    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    /// 与 Dart 版一致的尺寸常量。
    private static let contentPadding: CGFloat = 12
    private static let cornerRadius: CGFloat = 28
    private static let titleFontSize: CGFloat = 16
    private static let labelFontSize: CGFloat = 12

    var body: some View {
        Button {
            if let onTap {
                onTap()
            } else {
                router.push(.bangumiInfo(bangumiID: item.id))
            }
        } label: {
            HStack(alignment: .top, spacing: compact ? 12 : 16) {
                cover
                details
            }
            .padding(Self.contentPadding)
            .frame(maxWidth: .infinity, minHeight: compact ? 144 : 160, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(KazumiPalette.cardSurface(for: colorScheme))
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.displayName)
    }

    // MARK: - 封面

    private var cover: some View {
        BangumiRemoteImage(url: item.largeImage)
            .frame(width: compact ? 80 : 88)
            .aspectRatio(BangumiPosterCard.coverAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius - Self.contentPadding, style: .continuous))
    }

    // MARK: - 右侧详情

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.displayName)
                .font(.system(size: Self.titleFontSize, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8).frame(height: 8)

            HStack(spacing: 8) {
                if showRating {
                    ratingInline
                }
                let supporting = item.supportingText
                if !supporting.isEmpty {
                    Text(supporting)
                        .font(.system(size: Self.labelFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if let updateText {
                    pill(symbol: "clock", text: updateText)
                }
                if let currentEpisode {
                    pill(symbol: "list.play", text: "第 \(currentEpisode) 话")
                }
                if isWatching {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(KazumiPalette.accent)
                        .accessibilityLabel("正在追")
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 评分在标签行左侧，不带胶囊背景：星标 + 分数。
    private var ratingInline: some View {
        Group {
            if item.ratingScore <= 0 {
                Text("暂无评分")
                    .font(.system(size: Self.labelFontSize))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(KazumiPalette.accent)
                    Text(String(format: "%.1f", item.ratingScore))
                        .font(.system(size: Self.labelFontSize, weight: .bold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel("评分 \(String(format: "%.1f", item.ratingScore))")
            }
        }
    }

    private func pill(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: Self.labelFontSize, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(KazumiPalette.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(KazumiPalette.accent.opacity(0.14)))
    }
}
