//
//  AppRouter.swift
//  Kazumi
//
//  与 lib/pages/router.dart + lib/pages/menu/menu.dart 对应的导航状态。
//  五个一级目的地：推荐 / 新番时间表 / 追番收藏 / 以图搜番 / 我的，
//  iPhone 由原生 TabView 渲染为底部悬浮胶囊，iPad 自动变为顶部胶囊 + 侧边栏。
//

import Foundation
import Observation

/// 一级目的地。
enum AppDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case popular
    case timeline
    case collect
    case trace
    case my

    var id: String { rawValue }

    var title: String {
        switch self {
        case .popular: "推荐"
        case .timeline: "新番时间表"
        case .collect: "追番"
        case .trace: "以图搜番"
        case .my: "我的"
        }
    }

    var symbolName: String {
        switch self {
        case .popular: "house"
        case .timeline: "calendar"
        case .collect: "heart"
        case .trace: "camera.viewfinder"
        case .my: "gearshape"
        }
    }

    var selectedSymbolName: String {
        switch self {
        case .popular: "house.fill"
        case .timeline: "calendar"
        case .collect: "heart.fill"
        case .trace: "camera.viewfinder"
        case .my: "gearshape.fill"
        }
    }
}

/// 二级路由（对应原项目 pushNamed 的页面路径）。
enum AppRoute: Hashable, Sendable {
    case bangumiInfo(bangumiID: Int)
    case search(keyword: String)
    case webSearchHistory
    case player(bangumiID: Int, episode: Int)
    case pluginEditor(ruleID: String?)
    case pluginShop
    case history
    case download
    case settings
    case about
    case logs
    case danmakuShield
    case webDAV
}

@MainActor
@Observable
final class AppRouter {
    var selectedDestination: AppDestination = .popular

    /// 每个目的地独立的导航栈，切换 Tab 时保留各自的页面。
    var popularPath: [AppRoute] = []
    var timelinePath: [AppRoute] = []
    var collectPath: [AppRoute] = []
    var tracePath: [AppRoute] = []
    var myPath: [AppRoute] = []

    func path(for destination: AppDestination) -> [AppRoute] {
        switch destination {
        case .popular: popularPath
        case .timeline: timelinePath
        case .collect: collectPath
        case .trace: tracePath
        case .my: myPath
        }
    }

    func setPath(_ path: [AppRoute], for destination: AppDestination) {
        switch destination {
        case .popular: popularPath = path
        case .timeline: timelinePath = path
        case .collect: collectPath = path
        case .trace: tracePath = path
        case .my: myPath = path
        }
    }

    /// 在当前 Tab 内推入页面。
    func push(_ route: AppRoute) {
        setPath(path(for: selectedDestination) + [route], for: selectedDestination)
    }

    func popToRoot() {
        setPath([], for: selectedDestination)
    }
}
