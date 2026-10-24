//
//  LibraryPosterCard.swift
//  Kazumi
//
//  追番页「卡片」布局的一颗海报卡片（specs 见
//  design/kazumi-library-cards-spec.md §四）：
//  * 竖版海报（宽高比 0.65）在上，标题与元信息在下；
//  * 整张卡片任意位置都能点开详情，只有封面右下角的「…」例外；
//  * 「…」贴在封面角上而不是页脚——页脚放它要占 26 点，等于每个标题少两个字。
//

import SwiftUI

struct LibraryPosterCard: View {
    let entry: LibraryEntry
    /// 正在改收藏状态：菜单降到 0.4 并禁用，卡片本身仍可点。
    let isPending: Bool
    /// 「全部」分类里没有状态胶囊，用元信息行末尾的状态名补上。
    var showsStatus: Bool = false
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    var zoomNamespace: Namespace.ID?
    var onOpen: () -> Void
    var onChangeType: (CollectType) -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// 封面宽高比，与 `BangumiPosterCard.coverAspectRatio` 同一套。
    private static let coverAspectRatio = BangumiPosterCard.coverAspectRatio
    /// 标题两行的高度：一行 `.footnote` 约 17，两行 34。
    /// 固定住之后同一行的卡片等高，标题长短不把网格撑歪。
    private static let titleBlockHeight: CGFloat = 34
    private static let cornerRadius: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(KazumiPalette.cardSurface(for: colorScheme))
        )
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        // 整张卡片（封面、标题、元信息、空白）都是命中区。
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .onTapGesture { onOpen() }
        // 整卡合成一个元素（更新 Label 见下），并把它当按钮。
        // 读屏用不了封面角上那颗「…」（它在这个元素里面被合掉了），
        // 所以把「改收藏状态」做成这个元素的自定义操作——读屏转到这里时，
        // 操作里会多出五个分类，选一个就改，不用先去够那颗小按钮。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .accessibilityActions {
            ForEach(CollectType.enabledCases) { type in
                Button(type.title) { onChangeType(type) }
            }
        }
    }

    // MARK: - 封面

    private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            // 先立一个比例确定的框（宽由网格给，高 = 宽 / 0.65），再把图铺满它。
            // 直接把图 .aspectRatio(.fit) 是不行的：`BangumiRemoteImage` 会
            // 铺满可用空间（maxHeight 无限），网格里每张封面各长各的，行就叠在一起。
            Color.clear
                .aspectRatio(Self.coverAspectRatio, contentMode: .fit)
                .overlay {
                    BangumiRemoteImage(url: entry.imageURL)
                }
                .clipped()
                // 只把封面登记成转场源：放大时菜单不跟着长。
                .kazumiZoomSource(id: entry.id, namespace: zoomNamespace)

            statusMenu
                .padding(6)
        }
    }

    private var statusMenu: some View {
        Menu {
            ForEach(CollectType.enabledCases) { type in
                Button(type.title) { onChangeType(type) }
            }
        } label: {
            // LP 2026-10-24：不用三个点，直接画当前的追番状态（在看那颗心、想看那颗星…），
            // 一眼就知道这部现在是什么状态；点它还是开菜单改状态。
            Image(systemName: entry.collectType.statusSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(.black.opacity(0.42))
                )
                .hitTarget44()
                .opacity(isPending ? 0.4 : 1)
        }
        .menuOrder(.fixed)
        .disabled(isPending)
        .accessibilityLabel(Text("修改追番状态"))
        .accessibilityHint(Text("当前是\(entry.collectType.title)"))
    }

    // MARK: - 页脚

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.displayName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .lineSpacing(1)
                .multilineTextAlignment(.leading)
                .frame(height: Self.titleBlockHeight, alignment: .topLeading)

            metaText
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 元信息行：只写追番状态，且在「全部」里才写。
    /// 缺哪项省哪项；一项都没有时整行不占位（返回 nil，不是空 Text）。
    /// 这里**没有「看到第几话」**：原版追番卡片的明细行只有评分和状态
    /// （lib/pages/collect/collect_library_card.dart），而且今天全仓没有一处
    /// 会写 currentEpisode，印出来只会说假话。等播放能回写进度再加。
    @ViewBuilder
    private var metaText: some View {
        let parts = metaParts
        if !parts.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Text(" · ")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(part.text)
                        .font(.caption2)
                        .foregroundStyle(part.isAccent ? KazumiPalette.accent(for: colorScheme) : .secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct MetaPart {
        var text: String
        var isAccent: Bool = false
    }

    private var metaParts: [MetaPart] {
        // LP 2026-10-24：卡片上不再显示评分，这一行只留追番状态。
        var parts: [MetaPart] = []
        if showsStatus {
            parts.append(MetaPart(text: entry.collectType.title))
        }
        return parts
    }

    private var accessibilityLabel: String {
        var parts = [entry.displayName, entry.collectType.title]
        return parts.joined(separator: "，")
    }
}
