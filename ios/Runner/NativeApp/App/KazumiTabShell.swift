//
//  KazumiTabShell.swift
//  Kazumi
//
//  iOS 26 自适应标签栏（.sidebarAdaptable）：
//   * iPhone 竖屏：底部悬浮液态玻璃胶囊栏；
//   * iPhone 横屏 / iPad：顶部悬浮胶囊 + 左侧可折叠液态玻璃侧边栏；
//   * 每个 Tab 各自持有 NavigationStack，切换时保留页面层级。
//

import SwiftUI

struct KazumiTabShell: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TabView(selection: tabSelection) {
            destinationTab(.popular) {
                PopularScreen()
            }
            destinationTab(.timeline) {
                TimelineScreen()
            }
            destinationTab(.collect) {
                LibraryScreen()
            }
            destinationTab(.trace) {
                TraceScreen()
            }
            destinationTab(.my) {
                ProfileScreen()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .background(KazumiPalette.heroBackground(for: colorScheme).ignoresSafeArea())
    }

    /// Tab 选中项与 AppDestination 的双向绑定。
    private var tabSelection: Binding<AppDestination> {
        Binding(
            get: { router.selectedDestination },
            set: { router.selectedDestination = $0 }
        )
    }

    @ViewBuilder
    private func destinationTab<Content: View>(
        _ destination: AppDestination,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Tab(destination.title, systemImage: destination.symbolName, value: destination) {
            NavigationStack(path: pathBinding(for: destination)) {
                content()
                    .navigationDestination(for: AppRoute.self) { route in
                        AppRouteView(route: route)
                    }
            }
        }
    }

    private func pathBinding(for destination: AppDestination) -> Binding<[AppRoute]> {
        Binding(
            get: { router.path(for: destination) },
            set: { router.setPath($0, for: destination) }
        )
    }
}

/// 二级路由 -> 视图。Step 5 完成全部实现，此处先接好跳转路径。
struct AppRouteView: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .bangumiInfo(let bangumiID):
            BangumiInfoScreen(bangumiID: bangumiID)
        case .search(let keyword):
            SearchScreen(initialKeyword: keyword)
        case .webSearchHistory:
            SearchHistoryScreen()
        case .player(let bangumiID, let episode):
            PlayerScreen(bangumiID: bangumiID, episode: episode)
        case .pluginEditor(let ruleID):
            PluginEditorScreen(ruleID: ruleID)
        case .pluginShop:
            PluginShopScreen()
        case .history:
            WatchHistoryScreen()
        case .download:
            DownloadScreen()
        case .settings:
            SettingsScreen()
        case .about:
            AboutScreen()
        case .logs:
            LogScreen()
        case .danmakuShield:
            DanmakuShieldScreen()
        case .webDAV:
            WebDAVScreen()
        }
    }
}
