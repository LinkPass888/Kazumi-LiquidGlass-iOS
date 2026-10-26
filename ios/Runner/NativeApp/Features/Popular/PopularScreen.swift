import SwiftUI

/// 推荐页：封面上半屏 + 下面几行横向海报架。
///
/// 封面在滚动内容里（LP 2846）：上滑跟着内容一起滚走；下拉到顶时不拉伸、不放大、
/// 不回弹——下拉出来的那段往回补（Colo 2847），视觉上封面钉在屏幕顶端不动。
/// 这页没有下拉刷新（LP 2823 / Colo 2824）：各行照旧按各自的过期时间自己换新。
struct PopularScreen: View {
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    var zoomNamespace: Namespace.ID?

    @State private var controller = PopularController()
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    /// 顶栏本体的高度，提示语要落在它下面。
    @State private var topBarHeight: CGFloat = 59
    /// 滚动内容上沿在滚动空间里的 y：0 是原位，正数是上拉过界（下拉出来的那段）。
    @State private var contentOffset: CGFloat = 0

    /// 与 constants.dart 的 defaultAnimeTags 一致（跟搜索页那份同一个清单）。
    private static let tags: [String] = [
        "日常", "原创", "校园", "搞笑", "奇幻", "百合", "恋爱", "悬疑",
        "热血", "后宫", "机战", "轻改", "偶像", "治愈", "异世界",
    ]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                PopularHero(
                    items: controller.heroItems,
                    zoomNamespace: zoomNamespace,
                    toastOffset: Self.statusBarHeight + topBarHeight + 12
                )
                // 上拉过界时往回补，视觉上封面钉在屏幕顶端不动（Colo 2847）；
                // 上滑时补偿是 0，封面跟着内容一起滚走（LP 2846）。
                .offset(y: -overPull)

                shelves
                    .padding(.top, 24)
            }
            .padding(.bottom, 40)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ContentOffsetKey.self,
                        value: proxy.frame(in: .named("shelves")).minY
                    )
                }
            )
        }
        .scrollIndicators(.hidden)
        .coordinateSpace(name: "shelves")
        // 封面要铺到状态栏，所以滚动区从屏幕最上方开始算。
        .ignoresSafeArea(edges: .top)
        // 顶栏浮在滚动内容上，不跟着滚，压在最上层（Ato 2852）：
        // 封面再高也不许吃掉它的点击区。
        .overlay(alignment: .top) {
            topBar
                .padding(.top, Self.statusBarHeight)
        }
        // 一行都没拉到（缓存空 + 网络也失败）时给个能重试的页；否则就是顶层一个顶栏的空页。
        .overlay {
            if !controller.isLoading, controller.rows.isEmpty, controller.isFailed {
                failureView
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onPreferenceChange(TopBarHeightKey.self) { topBarHeight = $0 }
        .onPreferenceChange(ContentOffsetKey.self) { contentOffset = $0 }
        .onAppear {
            // 先把缓存画出来，再后台刷新（LP 2733 / Ato 2734）：
            // 冷启动不该对着空页等网。
            controller.paintFromCache()
            Task { await controller.load() }
        }
    }

    /// 四行全空时的错误态：跟列表页那份同一个形状（那里也是「更多」点进去的第一屏）。
    private var failureView: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("无法获取列表")
                .font(.headline)
            Button("重试") {
                Task { await controller.load() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 160)
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

    /// 下拉出来的那段：只在过界时为正，上滑时是 0（Colo 2847）。
    private var overPull: CGFloat {
        max(0, contentOffset)
    }

    /// 下面那几行横向海报架。
    private var shelves: some View {
        LazyVStack(spacing: 24) {
            ForEach(controller.rows) { row in
                PopularShelf(
                    row: row,
                    zoomNamespace: zoomNamespace,
                    onMore: { router.push(.popularList($0)) }
                )
                .padding(.top, 8)
            }
        }
    }

    /// 顶栏：左边的大标题点开选标签（原版就是它），右边搜索和观看历史。
    /// 自己不带底色——那层渐变遮罩搬进封面块了（Colo 2856），封面一走它就走。
    @ViewBuilder
    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Menu {
                Button {
                    router.push(.popularList(.trending))
                } label: {
                    Text("热门番组")
                }
                ForEach(Self.tags, id: \.self) { tag in
                    Button(tag) { router.push(.popularList(.tag(tag))) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("热门番组")
                        .font(.system(size: 34, weight: .semibold))
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

            Button {
                router.push(.search(keyword: ""))
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(KazumiCircleButtonStyle())
            .accessibilityLabel("搜索")

            Button {
                router.push(.history)
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(KazumiCircleButtonStyle())
            .accessibilityLabel("观看历史")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TopBarHeightKey.self, value: proxy.size.height)
            }
        )
    }
}

private struct TopBarHeightKey: PreferenceKey {
    // 必须是 `let`：`var` 在严格并发下是非隔离的全局可变状态，编译不过。
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 滚动内容上沿在滚动空间里的 y：0 是原位，正数是上拉过界。
private struct ContentOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 顶栏那两颗圆钮：36 正圆、半透明白底、按压时缩一下（Colo 样张右上角）。
struct KazumiCircleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 36, height: 36)
            .background(Circle().fill(.gray.opacity(colorScheme == .dark ? 0.32 : 0.14)))
            .foregroundStyle(.primary)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            // 画 36，点按区域给到 44。
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }
}
