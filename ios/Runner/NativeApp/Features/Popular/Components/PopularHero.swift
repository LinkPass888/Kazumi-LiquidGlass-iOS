//
//  PopularHero.swift
//  Kazumi
//
//  推荐页焦点区（Colo 竖版规格 v3，LP 2782 定的方向）。
//
//  封面通栏铺满上半屏：600 高、顶边钉在屏幕顶端（LP 2843 / Colo 2844；550 → 600 见 LP 2901 / Colo 2902）。
//  封面在滚动内容里（LP 2846）：上滑跟着内容一起滚走；下拉到顶时不拉伸、不放大、
//  不回弹——下拉出来的那段由外层往回补（Colo 2847），所以视觉上封面钉在屏幕顶端不动；
//  同时封面自己从中心往四周放大（LP 2869 / Colo 2870），看起来就是封面被拽大。
//
//  层级自下而上，越上面越先响应自己（Ato 2852 / Colo 2842）：
//  1. 封面图 ＋ 底边渐隐：点击只挂这一层，整块 600 都是命中区，点哪儿都进详情；
//  2. 顶上 100 高的渐变遮罩：压住封面图，让顶栏那颗大标题读得清；跟着封面一起滚走
//     （Colo 2856，封面一走它就走，不会在货架第一行上糊一条色带），不吃点击；
//  3. 圆点、名称、元信息：`allowsHitTesting(false)`，不吃点击；
//  4. 开始观看、收藏圆钮：各自先响应自己，点它们不进详情；
//  5. 顶栏：封面块最上面那一层 overlay（LP 2865 / Colo 2866）——跟着封面一起滚走，
//     上滑一起消失、滚回来再出现；自己不带底色，标题和两颗圆钮压在顶上那层遮罩上。
//
//  竖版封面塞进 550 高会上下裁掉一截，所以按偏上对齐裁，顶部保留 8%，别把人脸裁掉。
//

import SwiftUI
import UIKit

/// 顶栏点开「热门番组」选的那排标签：与搜索页、constants.dart 的清单一致。
private let heroTags: [String] = [
    "日常", "原创", "校园", "搞笑", "奇幻", "百合", "恋爱", "悬疑",
    "热血", "后宫", "机战", "轻改", "偶像", "治愈", "异世界",
]

struct PopularHero: View {
    let items: [PopularPoster]
    var zoomNamespace: Namespace.ID?
    /// 下拉过界时封面的放大倍数（LP 2938 / Colo 2939 / LP 2944）：外层按位移算好传进来，上滑时是 1。
    /// 图从顶边放大，左右下三个方向一起长。
    var pullScale: CGFloat = 1
    /// 下拉位移（LP 2963）：名称、元信息、开始观看、收藏跟着手指往下走这么多，尺寸不变。
    var pullOffset: CGFloat = 0
    /// 渐隐的位移：文字块那截照手走，再补上「图放大后比文字块多长出来的那截」，
    /// 下沿才能一直贴着图的新底边。
    private var fadeOffset: CGFloat {
        pullOffset + max(0, Self.coverHeight * (pullScale - 1) - pullOffset)
    }

    @Environment(AppRouter.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var colorScheme

    /// 封面块高度（LP 2843 / Colo 2844：400 → 480 → 500 → 550；LP 2901 / Colo 2902：550 → 600）。
    /// 加高是为了把封面底边推到「开始观看」和「本周热门」中间，文字块本身不动（见 `textBottomInset`）。
    static let coverHeight: CGFloat = 600
    /// 文字块离块底的留白（LP 2901 / Colo 2902）：封面加高 50，文字块原地不动，
    /// 所以「开始观看」那排仍在原来的位置，封面底边落到它下面、货架上面。
    static let textBottomInset: CGFloat = 50
    /// 顶上那层渐变遮罩的高度（Colo 2856）。
    static let maskHeight: CGFloat = 100
    /// 文字块（圆点、名称、元信息、按钮，含块底那 50）的高度：标题行数一变它就变，
    /// 所以量出来（`textBlockHeight`）。1 行标题时是 180，块顶落在 420。
    static let textBlockDefaultHeight: CGFloat = 114
    /// 渐隐从圆点那行底下开始（Colo 2930）：圆点整行 14 高，再让 2。
    static let fadeDotsInset: CGFloat = 16
    /// 提前到离封面底边 40 就满页面底色：560 往下的 40 点一直是满底色（Colo 2922），
    /// 最后这一段已经是纯底色，封面底边那条线就露不出来。
    static let fadeFullInset: CGFloat = 40
    /// 下拉时块往下长的封顶位移：再往下拽块也不再变高（原先是放大封顶 1.22）。
    static let maxPullDistance: CGFloat = 120
    /// 下拉放大的封顶比例（Colo 2953）：550 点下拉到 1.22，再往下不再放大。
    static let maxPullScale: CGFloat = 1.22
    /// 还没取到当前条目时给转场源用的兜底 ID（命名空间里没有同 ID 的目标，系统按默认转场走）。
    static let posterSourceFallbackID: Int = -1
    /// 竖版封面偏上对齐时顶部保留的比例。
    static let topReserve: CGFloat = 0.08

    @State private var currentID: Int?
    @State private var isToggling = false
    @State private var toastMessage: String?
    /// 选源面板的载体：与番剧详情页同一套（LP 2903 / Colo 2907）。
    @State private var sourceController: InfoController?
    @State private var isShowingSources = false
    /// 第一次点「开始观看」要先把条目备齐（缓存优先，没有才请求），期间不再接第二次点。
    @State private var isLoadingSources = false
    /// 顶栏本体的实际高度：提示语要落在它下面。
    @State private var topBarHeight: CGFloat = 59
    /// 文字块的实际高度（含块底那 50 的留白），渐隐由它推出来。
    /// 用 `onGeometryChange` 量（`PreferenceKey` 那条路在这版没吃到值）。
    /// 文字块本身的高度（不含块底那 50）。单行标题量出来是 114，两行会更高。
    @State private var textBlockHeight: CGFloat = PopularHero.textBlockDefaultHeight
    /// 圆钮按下时弹一下：缩到 0.8 再回弹，120 毫秒（Colo 2803）。
    @State private var followScale: CGFloat = 1

    private var current: PopularPoster? {
        items.first { $0.id == (currentID ?? items.first?.id) }
    }

    private var collectType: CollectType {
        guard let id = current?.id else { return .none }
        return library.entry(for: id)?.collectType ?? .none
    }

    var body: some View {
    ZStack(alignment: .bottom) {
            // 下拉时只有那张图从顶边放大（LP 2963 / Colo 2939）：横向钉死页宽 402，
            // 纵向往下长，多出来的露在下面。可视宽度不跟着放大，隔壁才不会挤进来（Colo 2959）。
            pager
                .scaleEffect(pullScale, anchor: .top)
                .mask(alignment: .top) {
                    Rectangle()
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.coverHeight * Self.maxPullScale)
                }

            // 顶部那截模糊不参与放大也不位移，钉在原位（LP 2952）。
            mask

            // 底边渐隐挂在封面这一整个 600 高的盒子上，不挂在图里（Colo 2922）：
            // 挂在图上时，它的下沿跟着图片自己的高度走（图只有 582 高），
            // 渐隐就提前 18 点结束，封面底边那条线就露出来了。
            fade
                .offset(y: fadeOffset)

            // 文字块不参与放大，只跟着手指往下移（LP 2963）。
            textBlock
                .offset(y: pullOffset)
        }
        .frame(height: Self.coverHeight)
        // 封面块不做缩放转场，走默认的横向翻页（LP 2976）：缩放转场返回时只飞回一张快照，
        // 渐隐和按钮要等动画结束才出现，看着就是「图先落回、底下一闪」。
        // 不登记源视图，详情页那边会自动回落到系统默认转场。
        // 这里不裁：下拉过界时封面放大，底边要真的往下长出来（LP 2942）。
        // 平时图正好 600 高，没有东西溢出去。

        .onPreferenceChange(TopBarHeightKey.self) { topBarHeight = $0 }
        // 选源面板：直接复用详情页那张（`SourceSheet`）和它那一套回调，
        // 不在推荐页另定一套（LP 2903 / 2904 / Colo 2907）。
        .sheet(isPresented: $isShowingSources) {
            if let current = sourceController {
                SourceSheet(controller: current) { pluginName, result in
                    isShowingSources = false
                    router.push(
                        .player(
                            bangumiID: current.item.id,
                            episode: 1,
                            source: PlaybackSource(
                                pluginName: pluginName,
                                itemName: result.name,
                                detailURL: EpisodeURL.normalize(
                                    baseUrl: environment.plugins.plugin(named: pluginName)?.baseUrl ?? "",
                                    raw: result.src
                                ),
                                directMediaURL: MediaUtility.isMediaURL(result.src) ? result.src : nil
                            )
                        )
                    )
                }
            }
        }
        // 条目换成 5 张以内时把圆点状态收敛回第一张。
        .onAppear {
            if currentID == nil { currentID = items.first?.id }
        }
        .onChange(of: items.first?.id) { _, _ in
            if let first = items.first?.id, !items.contains(where: { $0.id == currentID }) {
                currentID = first
            }
        }
        // 顶栏是封面块最上面那一层（LP 2865 / Colo 2866）：压在封面顶边那 100 高的
        // 遮罩上，跟着封面、跟着内容一起滚。
        .overlay(alignment: .top) {
            topBar
                .padding(.top, Self.statusBarHeight)
        }
        // 提示语摆在顶栏下沿再让 12，不然会压住状态栏的时钟和顶栏那三十四点的大标题。
        .overlay(alignment: .top) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.78)))
                    .padding(.top, toastOffset)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - 封面

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items) { poster in
                    cover(poster)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollIndicators(.hidden)
        // 横向裁在翻页容器这一层：外面那层不能裁（下拉时封面要往下长出来），
        // 但隔壁那张页就在右边，不裁的话它会被一起画出来（LP 2958）。
        .clipped()
    }

    /// 封面图 ＋ 底边渐隐：点击只挂在这一层（Ato 2852），整块都是命中区。
    private func cover(_ poster: PopularPoster) -> some View {
        Button {
            router.push(.bangumiInfo(bangumiID: poster.id))
        } label: {
            ZStack(alignment: .bottom) {
                // 竖图铺满整块：宽度钉在页宽上（`containerRelativeFrame`），高度超出 600 的裁掉。
                //
                // 宽度必须钉：横向 ScrollView 给内容的宽度提议是无穷大，光靠
                // `frame(maxWidth: .infinity)` 撑不开，图会按自己的比例算出一个比页宽更宽的
                // 尺寸（实测 440 对 402），左右各溢出 19 点——左右滑时隔壁那张就从这条缝里
                // 露出来（LP 2899 / Colo 2900）。
                BangumiRemoteImage(url: poster.imageURL)
                    .containerRelativeFrame(.horizontal)
                    // 放大由整块那层统一做（Colo 2953）：图自己再放一次会变成 1.22 的平方。
                    // 这里只管裁：显示尺寸永远等于页宽 402。
                    .clipped()
            }
        }
        .buttonStyle(.plain)
        // 转场源登记在整块封面上，不挂在图那一层（LP 2970 / 2972）：
        // 只挂图的话，返回时系统只把图那一张快照飞回来，渐隐和按钮要等动画结束才出现，
        // 看着就是「图先落回、底下一闪」。
        .accessibilityLabel(poster.displayName)
        .accessibilityHint("打开详情")
    }

    /// 底边渐隐：从圆点那行底下开始往下，把封面渐成页面底色，满底色落在 560，
    /// 再往下 40 点一直是满底色（Colo 2922）。
    ///
    /// 第一档必须是 0（LP 2925 / 2926 / Colo 2930）：之前起手就给 20%，圆点那行以上是原图、
    /// 以下一层白纱，那条台阶看着就像在封面上贴了一张透明白图。
    private var fade: some View {
        // 下沿贴死封面底边 600，高度＝文字块高减去圆点那行（1 行标题时 164，上沿落在 436）。
        // 用块高而不是量绝对位置：下拉时文字块整体位移，绝对位置会带着位移走，块高不会。
        // 文字块本身 ＋ 块底那 50，再补上「图放大后比文字块多长出来的那截」：
        // 下拉时文字块只跟手位移、图却按 1.22 长，不补的话图会在渐隐下面露出一条（LP 2963）。
        let base = max(1, textBlockHeight + Self.textBottomInset)
        let extra = max(0, Self.coverHeight * (pullScale - 1) - pullOffset)
        let height = base + extra
        // 满底色那一点（封面底边往上 40，即 560）在整条渐变的百分之几上。
        let full = min(1, max(0.01, (base - Self.fadeFullInset) / height))
        // 七档等分在渐隐的顶…560 上（Colo 2930），第一档是 0——
        // 顶部那一档要是直接给 20%，圆点那行就会成一条台阶（LP 2925 / 2926）。
        let steps: [CGFloat] = [0, 0.20, 0.40, 0.60, 0.80, 0.90, 0.95]
        var stops = steps.enumerated().map { index, opacity in
            Gradient.Stop(
                color: pageBackground.opacity(opacity),
                location: full * CGFloat(index) / CGFloat(steps.count)
            )
        }
        // 满底色落在 560，600 往上这 40 点一直是满底色（Colo 2922）。
        stops.append(.init(color: pageBackground, location: full))
        stops.append(.init(color: pageBackground, location: 1))
        return LinearGradient(
            stops: stops,
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .allowsHitTesting(false)
    }

    /// 页面真正的底色：封面块下面那块没有自己刷底色，用的是系统背景
    /// （浅色纯白、深色纯黑）。渐隐收尾必须用它，用 `KazumiPalette.background`
    /// （浅色是 0.98）在 600 处会差 5 级，正好显出一条线。
    private var pageBackground: Color { Color(uiColor: .systemBackground) }

    /// 顶上那 100 高的渐变遮罩：顶部 55% 页面底色 → 末端全透明（Colo 2856）。
    /// 它是封面块里的一层，跟着封面一起滚走，所以封面不在了它也不会压在货架上。
    private var mask: some View {
        LinearGradient(
            colors: [
                KazumiPalette.background(for: colorScheme).opacity(0.55),
                KazumiPalette.background(for: colorScheme).opacity(0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: Self.maskHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    // MARK: - 文字

    private var textBlock: some View {
        VStack(spacing: 0) {
            // 圆点、名称、元信息不吃点击（Ato 2852）：点击只挂封面图那一层，
            // 文字压在上面也不会把按钮的点击吃掉。
            VStack(spacing: 0) {
                dots
                    .padding(.bottom, 14)

                Text(current?.displayName ?? "")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if let meta = current?.metaLine {
                    Text(meta)
                        .font(.system(size: 13))
                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                        .padding(.top, 6)
                }
            }
            // 量文字块本身（不含块底那 50）：渐隐的高度＝它＋`textBottomInset`。
            // 之前这条量在了圆点那行上，量到的是圆点胶囊的 14，渐隐就只剩十几点、
            // 看着像整条没了（Colo 2922 那一版起就一直在犯）。
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { textBlockHeight = $0 }
            .allowsHitTesting(false)

            actions
                .padding(.top, 14)
        }
        // 文字块贴块底：开始观看那排压在块底上，名称落在块底往上 78（Colo 2853 / 2868）。
        // 1 行标题时正好是 78，2 行会更高——78 说的是单行那个位置。
        // 块底从 550 抬到 600 之后文字块跟着留出这 50，屏上位置一点不变（LP 2901 / Colo 2902）。
        .padding(.bottom, Self.textBottomInset)
    }

    private var actions: some View {
        ZStack {
            playButton

            HStack {
                Spacer()
                followButton
                    .padding(.trailing, 16)
            }
        }
        .frame(height: 40)
    }

    private var playButton: some View {
        Button {
            guard let poster = current else { return }
            openSources(poster)
        } label: {
            Label(playTitle, systemImage: "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(height: 40)
                .background(Capsule().fill(KazumiPalette.accent(for: colorScheme)))
        }
        .buttonStyle(.plain)
        .disabled(isLoadingSources)
        .accessibilityLabel(playTitle)
        .accessibilityHint("选择播放源")
    }

    /// 三个名字全 App 统一（Camo 2950）：没记录「开始观看」、看了一半「继续观看」、
    /// 看完了「重新观看」——最后一档原来也叫「开始观看」，跟历史页的「重新观看」撞了。
    private var playTitle: String {
        guard let id = current?.id, let record = library.record(for: id) else { return "开始观看" }
        return record.isFinished ? "重新观看" : "继续观看"
    }

    /// 收藏圆钮：玻璃底 ＋ 一层轻投影（Colo 2864 / 2866），压在封面上也要托得出来。
    private var followButton: some View {
        Button {
            guard let poster = current else { return }
            bounceFollow()
            Task { await toggleFollow(poster) }
        } label: {
            Image(systemName: collectType == .none ? "plus" : collectType.statusSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                .frame(width: 36, height: 36)
                .kazumiGlassCapsule(interactive: true)
                .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .scaleEffect(followScale)
        .disabled(isToggling)
        .accessibilityLabel(collectType == .none ? "收藏" : "已\(collectType.title)")
        .accessibilityValue(collectType.title)
        .accessibilityHint("切换追番状态")
    }

    // MARK: - 圆点

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(items) { poster in
                let selected = poster.id == (currentID ?? items.first?.id)
                Capsule(style: .continuous)
                    // 未选中的点 25% 墨压在封面上等于不存在，改 55%（Colo 2916）。
                    .fill(selected ? KazumiPalette.accent(for: colorScheme) : Color.black.opacity(0.55))
                    .frame(width: selected ? 18 : 6, height: 6)
            }
        }
        // 圆点底下垫一条胶囊底（Colo 2916）：亮封面、暗封面都读得出来。
        // 白 50%、左右各留 8（宽＝圆点总宽 +16）、高 14、圆角 7。
        .padding(.horizontal, 8)
        .frame(height: 14)
        .background(Capsule(style: .continuous).fill(.white.opacity(0.5)))
        .animation(.easeOut(duration: 0.2), value: currentID)
    }

    // MARK: - 顶栏

    /// 顶栏：左边的大标题点开选标签（原版就是它），右边搜索和观看历史。
    /// 它是封面块最上面那一层 overlay，跟着封面一起滚（LP 2865 / Colo 2866）。
    @ViewBuilder
    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Menu {
                Button {
                    router.push(.popularList(.trending))
                } label: {
                    Text("热门番组")
                }
                ForEach(heroTags, id: \.self) { tag in
                    Button(tag) { router.push(.popularList(.tag(tag))) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("热门番组")
                        .font(.system(size: 34, weight: .semibold))
                        // 压在封面上的字得有一层才读得清（Colo 2864）：就这一层，别更重。
                        .shadow(color: .black.opacity(0.30), radius: 8, y: 1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel("热门番组")
            .accessibilityHint("选标签")

            Spacer()

            circleButton(symbol: "magnifyingglass", label: "搜索") {
                router.push(.search(keyword: ""))
            }
            circleButton(symbol: "clock", label: "观看历史") {
                router.push(.history)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TopBarHeightKey.self, value: proxy.size.height)
            }
        )
    }

    /// 顶栏那两颗圆钮：36 玻璃正圆、命中区给到 44（Colo 2864 / 2866）。
    /// 玻璃就是全 App 那一套 `kazumiGlassCapsule`（iOS 26 上只有系统 `glassEffect`），
    /// 跟详情页返回 / 更多同一副面孔，不在这儿另立一份。
    ///
    /// 不压 tint、不加投影（LP 2897 / Colo 2898）：上一版为了让它透出封面压了一层
    /// 黑 tint，结果看着是两颗黑圆；发亮的根子在垫底那层材质上，已经在 `LiquidGlass`
    /// 里按系统版本分开了，这里不用再补任何颜色。
    private func circleButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .kazumiGlassCapsule(interactive: true)
        }
        .buttonStyle(.plain)
        // 画 36，点按区域给到 44。
        .hitTarget44()
        .accessibilityLabel(label)
    }

    // MARK: - 动作

    /// 「开始观看」：与番剧详情页那颗按钮同一条路（LP 2903 / 2904 / Colo 2907）——
    /// 弹同一张「选择播放源」面板（`SourceSheet`），在那里选源、进去开播；
    /// 播哪一话、用哪条规则全由播放器自己按观看记录接上，与详情页一致。
    ///
    /// 面板要一个 `InfoController`，所以先把条目备齐：缓存优先（从列表/以前进过
    /// 详情页都有），没有才请求一次。同一部番点第二次直接用已经建好的那份。
    private func openSources(_ poster: PopularPoster) {
        if let controller = sourceController, controller.item.id == poster.id {
            isShowingSources = true
            return
        }
        guard !isLoadingSources else { return }
        isLoadingSources = true
        Task {
            defer { isLoadingSources = false }
            // `??` 右边是 autoclosure，不能放 await，只能分两步写。
            var cachedItem = BangumiSubjectCache.shared.item(for: poster.id)
            if cachedItem == nil {
                cachedItem = await BangumiAPI.info(id: poster.id)
            }
            let item = cachedItem
                ?? BangumiItem(id: poster.id, name: poster.name, nameCn: poster.nameCn)
            let controller = InfoController(item: item, plugins: environment.plugins)
            controller.applyCachedEpisodes()
            sourceController = controller
            isShowingSources = true
        }
    }

    /// 收藏圆钮：轻点是「在看 ↔ 未收藏」两态切换。
    ///
    /// 口径与详情页那颗钮一致（`BangumiInfoScreen.collect`）：自动同步开着就推
    /// Bangumi，推不成功整次作废。其余状态（想看 / 搁置 / 看过 / 抛弃）在详情页的
    /// 状态菜单里选——这里只留一个「快速」入口，不铺一整排。
    private func toggleFollow(_ poster: PopularPoster) async {
        guard !isToggling else { return }
        isToggling = true
        defer { isToggling = false }

        let next: CollectType = collectType == .none ? .watching : .none
        let syncEnabled = settings.bangumiSyncEnable
        guard syncEnabled else {
            applyCollect(poster, next)
            withAnimation { toastMessage = toastText(for: next) }
            scheduleToastClear()
            return
        }
        let pushed = await environment.bangumiSync.pushCollectible(bangumiID: poster.id, type: next)
        guard pushed else {
            withAnimation { toastMessage = "同步到 Bangumi 失败，已取消本次状态修改" }
            scheduleToastClear()
            return
        }
        applyCollect(poster, next)
        withAnimation { toastMessage = toastText(for: next) }
        scheduleToastClear()
    }

    /// 按下去弹一下：缩到 0.8 再回弹，120 毫秒（Colo 2803）。
    private func bounceFollow() {
        withAnimation(.easeInOut(duration: 0.12)) { followScale = 0.8 }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55).delay(0.12)) { followScale = 1 }
    }

    /// 报一句状态：加的那下说状态名（在看），取消的那下用菜单里那一项的字（Camo 2805）。
    private func toastText(for type: CollectType) -> String {
        type == .none ? "已取消追番" : "已标为\(type.title)"
    }

    private func applyCollect(_ poster: PopularPoster, _ type: CollectType) {
        if type == .none {
            library.remove(bangumiID: poster.id)
            BangumiTimelineStore.shared.dropIfNotWatching(poster.id, collectType: .none)
            return
        }
        library.upsert(
            LibraryEntry(
                id: poster.id,
                type: type.rawValue,
                name: poster.name,
                nameCn: poster.nameCn,
                summary: poster.summary,
                airDate: poster.airDate,
                imageURL: poster.imageURL,
                rating: poster.rating,
                rank: 0,
                tags: [],
                totalEpisodes: poster.totalEpisodes,
                currentEpisode: 0,
                addedAt: library.entry(for: poster.id)?.addedAt ?? Date(),
                updatedAt: Date()
            )
        )
        BangumiTimelineStore.shared.dropIfNotWatching(poster.id, collectType: type)
    }

    private func scheduleToastClear() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            withAnimation { toastMessage = nil }
        }
    }

    /// 提示语摆在顶栏下沿再让 12：顶栏自己跟着封面滚，所以它的高度得量出来。
    private var toastOffset: CGFloat {
        Self.statusBarHeight + topBarHeight + 12
    }

    /// 状态栏那一截的高度：顶栏要压在它下面。
    ///
    /// 这里不用 GeometryReader 读 `safeAreaInsets`：封面为了铺到屏幕顶，给滚动区加了
    /// `ignoresSafeArea(edges: .top)`，加完之后在里面读到的顶部内边距是 0。
    /// 直接问窗口的状态栏拿，与列表页读屏宽是同一套写法。
    private static var statusBarHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.statusBarManager?.statusBarFrame.height ?? 44
    }

    private var background: Color {
        KazumiPalette.background(for: colorScheme)
    }
}

/// 顶栏本体的实际高度：提示语要落在它下面，所以量一下。
private struct TopBarHeightKey: PreferenceKey {
    // 必须是 `let`：`var` 在严格并发下是非隔离的全局可变状态，编译不过。
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
