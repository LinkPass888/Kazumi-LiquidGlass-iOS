//
//  KazumiTabShell.swift
//  Kazumi
//
//  与 lib/pages/menu/menu.dart 对应的外壳：
//   * 竖屏：底部标签栏（推荐 / 时间表 / 追番 / 我的），四个入口与原版一致；
//   * 横屏 / iPad：系统会把同一组标签栏改为侧边栏，对应原版的 _sideMenu；
//   * 每个 Tab 各自持有 NavigationStack，切换时保留各自的页面层级；
//   * 每个 NavigationStack 各自持有 `@Namespace`，供卡片 → 详情页的缩放转场使用
//     （见 KazumiZoomTransition.swift）。按栈分配命名空间而不是全局共用一份，
//     是因为同一部番剧可能同时出现在推荐页与追番页，两个 Tab 里各有一张同 ID 的卡片，
//     共用命名空间会让系统无法判断该从哪一张放大。
//

import SwiftUI

struct KazumiTabShell: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        TabView(selection: tabSelection) {
            Tab(AppDestination.popular.title, systemImage: AppDestination.popular.symbolName, value: AppDestination.popular) {
                KazumiNavigationStack(destination: .popular) { zoomNamespace in
                    PopularScreen(zoomNamespace: zoomNamespace)
                }
            }
            Tab(AppDestination.timeline.title, systemImage: AppDestination.timeline.symbolName, value: AppDestination.timeline) {
                KazumiNavigationStack(destination: .timeline) { zoomNamespace in
                    TimelineScreen(zoomNamespace: zoomNamespace)
                }
            }
            Tab(AppDestination.collect.title, systemImage: AppDestination.collect.symbolName, value: AppDestination.collect) {
                KazumiNavigationStack(destination: .collect) { zoomNamespace in
                    LibraryScreen(zoomNamespace: zoomNamespace)
                }
            }
            Tab(AppDestination.my.title, systemImage: AppDestination.my.symbolName, value: AppDestination.my) {
                KazumiNavigationStack(destination: .my) { _ in
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
}

/// 单个标签页的导航栈：持有该栈的导航路径绑定与缩放转场命名空间。
///
/// 放在独立的 View 里是因为 `@Namespace` 只能由 View 持有；
/// 命名空间与 NavigationStack 一一对应，栈内所有页面（根页面、搜索结果、详情页）
/// 拿到的都是同一份，于是卡片与它推入的详情页能对上号。
private struct KazumiNavigationStack<Content: View>: View {
    let destination: AppDestination
    let content: (Namespace.ID) -> Content

    @Namespace private var zoomNamespace
    @Environment(AppRouter.self) private var router

    init(destination: AppDestination, @ViewBuilder content: @escaping (Namespace.ID) -> Content) {
        self.destination = destination
        self.content = content
    }

    var body: some View {
        NavigationStack(path: pathBinding) {
            content(zoomNamespace)
                .navigationDestination(for: AppRoute.self) { route in
                    AppRouteView(route: route, zoomNamespace: zoomNamespace)
                }
        }
    }

    private var pathBinding: Binding<[AppRoute]> {
        Binding(
            get: { router.path(for: destination) },
            set: { router.setPath($0, for: destination) }
        )
    }
}

/// 二级路由 -> 视图，对应 lib/pages/router.dart 的 RouteModule。
struct AppRouteView: View {
    let route: AppRoute
    /// 所在导航栈的缩放转场命名空间；传 nil 时详情页退回系统默认转场。
    var zoomNamespace: Namespace.ID?

    var body: some View {
        switch route {
        case .bangumiInfo(let bangumiID):
            BangumiInfoScreen(bangumiID: bangumiID, zoomNamespace: zoomNamespace)
        case .search(let keyword):
            SearchScreen(initialKeyword: keyword, zoomNamespace: zoomNamespace)
        case .imageSearch(let onPick):
            ImageSearchScreen(onPickKeyword: onPick)
        case .webSearchHistory:
            SearchHistoryScreen()
        case .player(let bangumiID, let episode, let source):
            PlayerScreen(bangumiID: bangumiID, episode: episode, source: source)
        case .pluginEditor(let ruleID):
            PluginEditorScreen(ruleID: ruleID)
        case .pluginTest(let ruleID):
            PluginTestScreen(ruleID: ruleID)
        case .pluginList:
            PluginListView()
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
        case .settingsBackup:
            SettingsBackupScreen()
        case .storage:
            StorageScreen()
        case .notificationSettings:
            NotificationSettingsScreen()
        case .playerSettings:
            PlayerSettingsScreen()
        case .danmakuSettings:
            DanmakuSettingsScreen()
        }
    }
}

