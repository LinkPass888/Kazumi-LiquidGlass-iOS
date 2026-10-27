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
            KazumiPalette.cardShape(cornerRadius: Self.cornerRadius, scheme: colorScheme)
        )
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        // LP 2026-10-24：进详情页要整张卡片放大，不是只有封面。
        // 转场源登记在整张卡上（封面＋标题那一块），侧滑返回时也收回到整张卡。
        // 以前只登记封面，所以放大的是海报、标题留在原地不动。
        .kazumiZoomSource(id: entry.id, namespace: zoomNamespace)
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

            statusMenu
                .padding(6)
        }
    }

    private var statusMenu: some View {
        // 菜单里面那份和详情页共用 `CollectStatusMenu`；外面这颗只画符号。
        CollectStatusMenu(current: entry.collectType, onChange: onChangeType) {
            // LP 2026-10-24：不用三个点，直接画当前的追番状态（在看那颗心、想看那颗星…），
            // 一眼就知道这部现在是什么状态；点它还是开菜单改状态。
            // LP 2026-10-24 晚：符号改主题色——白底圆 + 主题色符号，浅色封面上也看得清。
            // LP 2026-10-25：底改成半透明，并且跟着深浅色模式走。
            // 原来写死 `Color.white`：浅色下是块死白、深色下更是突兀的一块白，
            // 也不透封面。改用材质——浅色是磨砂白、深色是磨砂黑，本身带透明度，
            // 封面的颜色透得上来；描边只用来在浅色封面上保住轮廓。
            Image(systemName: entry.collectType.statusSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                )
                .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                .hitTarget44()
                .opacity(isPending ? 0.4 : 1)
        }
        // 这里本来还有一句 .accessibilityLabel("…，修改追番状态")：念不到——
        // 整张卡是 .accessibilityElement(children: .ignore)，子元素的名字被合掉了。
        // 那颗钮该说的话由上面卡片的标签（「片名，在看」）和六项操作来说，
        // 所以整行删掉，不留一个改得再准也没人读的第二出处。
        .disabled(isPending)
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
