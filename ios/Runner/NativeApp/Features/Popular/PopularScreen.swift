import SwiftUI

/// 推荐页：封面上半屏 + 下面几行横向海报架。
///
/// 封面在滚动内容里（LP 2846）：上滑跟着内容一起滚走；下拉到顶时不拉伸、不放大、
/// 不回弹——下拉出来的那段往回补（Colo 2847），视觉上封面钉在屏幕顶端不动；
/// 同时封面自己从中心往四周放大（LP 2869 / Colo 2870）。
/// 这页没有下拉刷新（LP 2823 / Colo 2824）：各行照旧按各自的过期时间自己换新。
struct PopularScreen: View {
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    var zoomNamespace: Namespace.ID?

    @State private var controller = PopularController()
    @Environment(AppRouter.self) private var router

    /// 滚动内容上沿在滚动空间里的 y：0 是原位，负数是上拉过界（下拉出来的那段）。
    @State private var scrollY: CGFloat = 0

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                PopularHero(
                    items: controller.heroItems,
                    zoomNamespace: zoomNamespace,
                    extraHeight: heroExtraHeight
                )
                // 上拉过界时往回补，视觉上封面钉在屏幕顶端不动（Colo 2847 / LP 2887）；
                // 上滑时补偿是 0，封面跟着内容一起滚走（LP 2846）。
                .offset(y: -overPull)

                // 封面底边下面留 24 就够：渐隐到封面底边 600 已经是页面底色，底下不用再留一层
                // 让它化开（LP 2912 / Colo 2913：本周热门回到封面底边下 24，即 624）。
                shelves
                    .padding(.top, 8)
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        // 下拉位移用 onScrollGeometryChange 量（LP 2887）：PreferenceKey 在橡皮筋
        // 回弹那段不更新，补偿算出来一直是 0，封面就跟着内容一起下来。
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newValue in
            scrollY = newValue
        }
        // 封面要铺到状态栏，所以滚动区从屏幕最上方开始算。
        .ignoresSafeArea(edges: .top)
        // 顶栏不在这儿了：它是封面块自己最上面那一层，跟着封面一起滚（LP 2865 / Colo 2866）。
        // 一行都没拉到（缓存空 + 网络也失败）时给个能重试的页；否则就是顶层一个顶栏的空页。
        .overlay {
            if !controller.isLoading, controller.rows.isEmpty, controller.isFailed {
                failureView
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
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

    /// 下拉出来的那段：只在过界时为正，上滑时是 0（Colo 2847）。
    private var overPull: CGFloat {
        max(0, -scrollY)
    }

    /// 下拉过界时封面块多出来的高度：跟下拉位移 1:1 涨，封顶 120（原先是放大倍数封顶 1.22，
    /// 现在改成整块往下长，名称、按钮、渐隐都跟着下来 —— LP 2934）。
    private var heroExtraHeight: CGFloat {
        min(overPull, PopularHero.maxPullDistance)
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
}
