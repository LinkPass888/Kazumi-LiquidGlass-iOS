//
//  KazumiTabShell.swift
//  Kazumi
//
//  与 lib/pages/menu/menu.dart 对应的外壳：
//   * 竖屏：底部标签栏（推荐 / 时间表 / 追番 / 我的），四个入口与原版一致；
//   * 横屏 / iPad：系统会把同一组标签栏改为侧边栏，对应原版的 _sideMenu；
//   * 每个 Tab 各自持有 NavigationStack，切换时保留各自的页面层级。
//

import SwiftUI

struct KazumiTabShell: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        TabView(selection: tabSelection) {
            Tab(AppDestination.popular.title, systemImage: AppDestination.popular.symbolName, value: AppDestination.popular) {
                navigationStack(for: .popular) {
                    PopularScreen()
                }
            }
            Tab(AppDestination.timeline.title, systemImage: AppDestination.timeline.symbolName, value: AppDestination.timeline) {
                navigationStack(for: .timeline) {
                    TimelineScreen()
                }
            }
            Tab(AppDestination.collect.title, systemImage: AppDestination.collect.symbolName, value: AppDestination.collect) {
                navigationStack(for: .collect) {
                    LibraryScreen()
                }
            }
            Tab(AppDestination.my.title, systemImage: AppDestination.my.symbolName, value: AppDestination.my) {
                navigationStack(for: .my) {
                    ProfileScreen()
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }

    /// Tab 选中项与 AppDestination 的双向绑定。
    private var tabSelection: Binding<AppDestination> {
        Binding(
            get: { router.selectedDestination },
            set: { router.selectedDestination = $0 }
        )
    }

    /// 每个标签页各自持有 NavigationStack，切换时保留各自的页面层级。
    private func navigationStack<Content: View>(
        for destination: AppDestination,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack(path: pathBinding(for: destination)) {
            content()
                .navigationDestination(for: AppRoute.self) { route in
                    AppRouteView(route: route)
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

/// 二级路由 -> 视图，对应 lib/pages/router.dart 的 RouteModule。
struct AppRouteView: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .bangumiInfo(let bangumiID):
            BangumiInfoScreen(bangumiID: bangumiID)
        case .search(let keyword):
            SearchScreen(initialKeyword: keyword)
        case .imageSearch(let onPick):
            ImageSearchScreen(onPickKeyword: onPick)
        case .webSearchHistory:
            SearchHistoryScreen()
        case .player(let bangumiID, let episode, let source):
            PlayerScreen(bangumiID: bangumiID, episode: episode, source: source)
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

