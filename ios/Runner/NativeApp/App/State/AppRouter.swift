//
//  AppRouter.swift
//  Kazumi
//
//  与 lib/pages/router.dart + lib/pages/menu/menu.dart 对应的导航状态。
//  一级目的地与 App 底部标签栏一一对应：推荐 / 时间表 / 追番 / 我的。
//  （原版底部只有这四个入口；搜索是顶栏按钮推入的二级页面，不是标签页，
//   以图搜番则是搜索页顶栏里的按钮，同样不是独立入口。）
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
    ///
    /// 时间表用日历符号：原版在详情页里点亮「在时间表展示」时用的就是
    /// CupertinoIcons.calendar（见 bangumi_info_card.dart），底部入口用同一个符号，
    /// 两处能对上。原版菜单里的 Icons.timeline 在 SF Symbols 里没有对应图形。
    var symbolName: String {
        switch self {
        case .popular: "house"
        case .timeline: "calendar"
        case .collect: "heart"
        case .my: "gearshape"
        }
    }

    var selectedSymbolName: String {
        switch self {
        case .popular: "house.fill"
        case .timeline: "calendar.circle.fill"
        case .collect: "heart.fill"
        case .my: "gearshape.fill"
        }
    }

    /// 从原版的启动页路径解析出要打开的标签。
    ///
    /// 原版把启动页存成页面路径（'/tab/popular/'、'/tab/timeline/' 这类，
    /// 见 interface_settings.dart 的 defaultPageMap），这里按最后一段匹配。
    static func from(startupPage: String) -> AppDestination {
        let trimmed = startupPage.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let component = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        switch component.lowercased() {
        case "timeline": return .timeline
        case "collect": return .collect
        case "my": return .my
        default: return .popular
        }
    }
}

/// 二级路由（对应原项目 pushNamed 的页面路径）。
enum AppRoute: Hashable, Sendable {
    case bangumiInfo(bangumiID: Int)
    case search(keyword: String)
    case webSearchHistory
    /// 以图搜番：从搜索页顶栏进入的二级页面（原版路径 /search/image）。
    /// `onPick` 由 SearchScreen 传入，用于把识别到的番名直接填进搜索框。
    case imageSearch(onPick: @MainActor @Sendable (String) -> Void)
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
    /// 设置备份：导出 / 导入旧版（Flutter）导出的设置备份文本。
    case settingsBackup
}

extension AppRoute {
    /// 与 Dart 的页面路径语义一致：导航栈只比较「去了哪一页」，不比较闭包这类附属数据。
    /// `.imageSearch` 的回调在页面内部重新绑定，因此这里用分支序号参与哈希与相等比较。
    static func == (lhs: AppRoute, rhs: AppRoute) -> Bool {
        lhs.kind == rhs.kind && lhs.associatedValuesEqual(rhs)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hashAssociatedValues(into: &hasher)
    }

    /// 分支序号：声明顺序，新增分支时追加在末尾即可。
    var kind: Int {
        switch self {
        case .bangumiInfo: 0
        case .search: 1
        case .webSearchHistory: 2
        case .imageSearch: 3
        case .player: 4
        case .pluginEditor: 5
        case .pluginShop: 6
        case .history: 7
        case .download: 8
        case .settings: 9
        case .about: 10
        case .logs: 11
        case .danmakuShield: 12
        case .webDAV: 13
        case .settingsBackup: 14
        }
    }

    private func associatedValuesEqual(_ other: AppRoute) -> Bool {
        switch (self, other) {
        case let (.bangumiInfo(lhs), .bangumiInfo(rhs)):
            lhs == rhs
        case let (.search(lhs), .search(rhs)):
            lhs == rhs
        case (.webSearchHistory, .webSearchHistory):
            true
        case (.imageSearch, .imageSearch):
            // 回调不参与相等比较，页面自己持有识别状态。
            true
        case let (.player(lhsID, lhsEpisode, lhsSource), .player(rhsID, rhsEpisode, rhsSource)):
            lhsID == rhsID && lhsEpisode == rhsEpisode && lhsSource == rhsSource
        case let (.pluginEditor(lhs), .pluginEditor(rhs)):
            lhs == rhs
        case (.pluginShop, .pluginShop),
             (.history, .history),
             (.download, .download),
             (.settings, .settings),
             (.about, .about),
             (.logs, .logs),
             (.danmakuShield, .danmakuShield),
             (.webDAV, .webDAV),
             (.settingsBackup, .settingsBackup):
            true
        default:
            false
        }
    }

    private func hashAssociatedValues(into hasher: inout Hasher) {
        switch self {
        case .bangumiInfo(let bangumiID):
            hasher.combine(bangumiID)
        case .search(let keyword):
            hasher.combine(keyword)
        case .player(let bangumiID, let episode, let source):
            hasher.combine(bangumiID)
            hasher.combine(episode)
            hasher.combine(source)
        case .pluginEditor(let ruleID):
            hasher.combine(ruleID)
        case .webSearchHistory,
             .imageSearch,
             .pluginShop,
             .history,
             .download,
             .settings,
             .about,
             .logs,
             .danmakuShield,
             .webDAV,
             .settingsBackup:
            break
        }
    }
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

    /// 启动时打开的标签（对应原版的 defaultStartupPage）。
    init(defaultStartupPage: String = "/tab/popular/") {
        selectedDestination = AppDestination.from(startupPage: defaultStartupPage)
    }

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

    /// 从搜索页打开以图搜番（对应原版 context.pushNamed('/search/image')）。
    func pushImageSearch(onPick: @escaping @MainActor @Sendable (String) -> Void) {
        push(.imageSearch(onPick: onPick))
    }

    func popToRoot() {
        setPath([], for: selectedDestination)
    }
}
