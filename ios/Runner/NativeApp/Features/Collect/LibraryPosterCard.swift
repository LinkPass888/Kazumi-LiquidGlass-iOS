//
//  LibraryPosterCard.swift
//  Kazumi
//
//  追番页「卡片」布局的一颗海报卡片（specs 见
//  design/kazumi-library-cards-spec.md §四）：
//  * 竖版海报（宽高比 0.65）在上，标题在下；
//  * 整张卡片任意位置都能点开详情，只有封面右下角那颗状态钮例外；
//  * 那颗钮画的是当前追番状态本身（在看一颗心、想看一颗星…），
//    贴在封面角上而不是页脚——页脚放它要占 26 点，等于每个标题少两个字。
//

import SwiftUI

struct LibraryPosterCard: View {
    let entry: LibraryEntry
    /// 正在改收藏状态：菜单降到 0.4 并禁用，卡片本身仍可点。
    let isPending: Bool
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    var zoomNamespace: Namespace.ID?
    var onOpen: () -> Void
    var onChangeType: (CollectType) -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// 封面宽高比，与 `BangumiPosterCard.coverAspectRatio` 同一套。
    private static let coverAspectRatio = BangumiPosterCard.coverAspectRatio
    /// 标题两行的高度。跟着动态字体走：写死 34 的话，最大字号那一档
    /// 标题会长到页脚外面去。默认档量出来仍是 34，屏上不变。
    @ScaledMetric(relativeTo: .footnote) private var titleBlockHeight: CGFloat = 34
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
        // 整张卡片（封面、标题、空白）都是命中区。
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .onTapGesture { onOpen() }
        // 整卡合成一个元素。读屏念到这张卡时听到的是「片名，在看」——
        // 这是状态唯一念得出来的地方，不许撤。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        // 角上那颗钮被合成掉了，读屏够不到它，所以把菜单里的事做成这张卡的操作：
        // 五项状态名，最后一项是动作名「取消追番」。
        .accessibilityActions {
            ForEach(CollectType.enabledCases) { type in
                Button(type.buttonTitle) { onChangeType(type) }
            }
            Button("取消追番") { onChangeType(.none) }
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
        // 菜单里面那份和详情页共用 `CollectStatusMenu`；外面这颗只画符号。
        CollectStatusMenu(current: entry.collectType, onChange: onChangeType) {
            // LP 2026-10-24：不用三个点，直接画当前的追番状态（在看那颗心、想看那颗星…），
            // 一眼就知道这部现在是什么状态；点它还是开菜单改状态。
            Image(systemName: entry.collectType.statusSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    // 0.55 而不是 0.42：评分和状态名都撤掉以后，角上这颗符号
                    // 是卡片上唯一说状态的地方，白符号压白封面要按正文的 4.5:1 取。
                    Circle().fill(.black.opacity(0.55))
                )
                .hitTarget44()
                .opacity(isPending ? 0.4 : 1)
        }
        .disabled(isPending)
        .accessibilityLabel(Text("\(entry.collectType.title)，修改追番状态"))
    }

    // MARK: - 页脚

    /// 页脚只有标题。LP 2026-10-24：卡片上不显示评分；Ato 同日定：
    /// 状态已经在封面角上那颗符号上了，同一张卡不说两遍，
    /// 所以原来那行元信息（评分 / 状态名）整行去掉，也不留一条空横线。
    private var footer: some View {
        Text(entry.displayName)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .lineSpacing(1)
            .multilineTextAlignment(.leading)
            .frame(height: titleBlockHeight, alignment: .topLeading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 与屏上同一句话：卡片上不显示评分，念出来的也不念；
    /// 状态名必须留着——角上那颗钮读屏念不到。
    private var accessibilityLabel: String {
        [entry.displayName, entry.collectType.title].joined(separator: "，")
    }
}
