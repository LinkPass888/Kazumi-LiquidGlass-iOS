//
//  AppRouter.swift
//  Kazumi
//
//  与 lib/pages/router.dart + lib/pages/menu/menu.dart 对应的导航状态。
//  一级目的地与 App 底部标签栏一一对应：推荐 / 时间表 / 追番 / 我的。
//  （原版底部只有这四个入口；搜索是顶栏按钮推入的二级页面，不是标签页。）
//

import Foundation
import Observation

/// 一级目的地。
enum AppDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case popular
    case timeline
    case collect
    case my

    var id: String { rawValue }

    /// 与 menu.dart 的 LiquidGlassBarItem label 一致。
    var title: String {
        switch self {
        case .popular: "推荐"
        case .timeline: "时间表"
        case .collect: "追番"
        case .my: "我的"
        }
    }

    /// 与 menu.dart 的 sfSymbol 一致。
    var symbolName: String {
        switch self {
        case .popular: "house"
        case .timeline: "timeline.selection"
        case .collect: "heart"
        case .my: "gearshape"
        }
    }

    var selectedSymbolName: String {
        switch self {
        case .popular: "house.fill"
        case .timeline: "timeline.selection"
        case .collect: "heart.fill"
        case .my: "gearshape.fill"
        }
    }
}

/// 二级路由（对应原项目 pushNamed 的页面路径）。
enum AppRoute: Hashable, Sendable {
    case bangumiInfo(bangumiID: Int)
    case search(keyword: String)
    case webSearchHistory
    /// 播放：bangumiID + 集数；由选源面板进入时带上规则名与分集页面地址。
    case player(bangumiID: Int, episode: Int, source: PlaybackSource?)

    /// 兼容原有调用点：只带 bangumiID 与集数时，视为「待选源」。
    static func player(bangumiID: Int, episode: Int) -> AppRoute {
        .player(bangumiID: bangumiID, episode: episode, source: nil)
    }

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

/// 选源结果（对应 lib/pages/video/video_playback_args.dart 的核心字段）。
struct PlaybackSource: Hashable, Sendable {
    /// 规则名，用于取出插件的 UA / Referer / 解析器版本。
    var pluginName: String
    /// 搜索结果的条目名。
    var itemName: String
    /// 条目详情页地址（章节抓取的输入）。
    var detailURL: String
    /// 直接可播的媒体地址（旧版解析器已还原出 m3u8/mp4 时）。
    var directMediaURL: String?
}



@MainActor
@Observable
final class AppRouter {
    var selectedDestination: AppDestination = .popular

    /// 每个目的地独立的导航栈，切换 Tab 时保留各自的页面。
    var popularPath: [AppRoute] = []
    var timelinePath: [AppRoute] = []
    var collectPath: [AppRoute] = []
    var myPath: [AppRoute] = []

    func path(for destination: AppDestination) -> [AppRoute] {
        switch destination {
        case .popular: popularPath
        case .timeline: timelinePath
        case .collect: collectPath
        case .my: myPath
        }
    }

    func setPath(_ path: [AppRoute], for destination: AppDestination) {
        switch destination {
        case .popular: popularPath = path
        case .timeline: timelinePath = path
        case .collect: collectPath = path
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
