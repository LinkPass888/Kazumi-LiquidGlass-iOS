//
//  TimelineController.swift
//  Kazumi
//
//  1:1 翻译 lib/pages/timeline/timeline_controller.dart 的核心路径：
//  * 当前季度走 getCalendar（7 天分组，下标 0 = 周一）；
//  * 历史季度走官方搜索接口（getCalendarBySearch），失败则退回镜像季度表；
//  * 支持按热度 / 评分 / 默认顺序排序。
//

import Foundation
import Observation

/// 与 Dart 的 TimelineSort 一致（默认「默认顺序」，与 timeline_options.dart 的文案一致）。
enum TimelineSort: String, CaseIterable, Identifiable, Sendable {
    case popularity
    case rating
    case defaultOrder

    var id: String { rawValue }

    /// 对应 timeline_options.dart 的 `_TimelineSortLabel`。
    var title: String {
        switch self {
        case .popularity: "热度优先"
        case .rating: "评分优先"
        case .defaultOrder: "默认顺序"
        }
    }
}

@MainActor
@Observable
final class TimelineController {
    /// 与 Flutter 版同名同义的三个「显示范围」开关，默认全部关闭。
    /// 键名沿用 SettingsKeys.timelineNotShowWatchedBangumis 等，备份文件可以互通。
    private enum FilterKeys {
        static let notShowWatched = "kazumi.settings.timelineNotShowWatchedBangumis"
        static let notShowAbandoned = "kazumi.settings.timelineNotShowAbandonedBangumis"
        static let onlyShowWatching = "kazumi.settings.timelineOnlyShowWatchingBangumis"
    }

    /// 7 天的番剧，下标 0 为周一。
    private(set) var bangumiCalendar: [[BangumiItem]] = []

    /// 接口返回的原始日历（未经用户自定义条目合并）。
    /// 每次合并都从它重新开始，改掉星期的番才能从原来那一天挪走。
    private(set) var baseCalendar: [[BangumiItem]] = []
    private(set) var selectedDate = Date()
    private(set) var isLoading = false
    private(set) var isTimeOut = false
    var sort: TimelineSort = .defaultOrder

    /// 隐藏看过的番剧（对应 notShowWatchedBangumis）。
    private(set) var notShowWatchedBangumis: Bool {
        didSet { defaults.set(notShowWatchedBangumis, forKey: FilterKeys.notShowWatched) }
    }

    /// 隐藏抛弃的番剧（对应 notShowAbandonedBangumis）。
    private(set) var notShowAbandonedBangumis: Bool {
        didSet { defaults.set(notShowAbandonedBangumis, forKey: FilterKeys.notShowAbandoned) }
    }

    /// 只看正在追的番剧（对应 onlyShowWatchingBangumis）。
    private(set) var onlyShowWatchingBangumis: Bool {
        didSet { defaults.set(onlyShowWatchingBangumis, forKey: FilterKeys.onlyShowWatching) }
    }

    private let defaults = UserDefaults.standard

    init() {
        notShowWatchedBangumis = defaults.bool(forKey: FilterKeys.notShowWatched)
        notShowAbandonedBangumis = defaults.bool(forKey: FilterKeys.notShowAbandoned)
        onlyShowWatchingBangumis = defaults.bool(forKey: FilterKeys.onlyShowWatching)
    }

    /// 供星期选择器使用的每日数量（过滤前）。
    var counts: [Int] {
        (0..<7).map { index in
            index < bangumiCalendar.count ? bangumiCalendar[index].count : 0
        }
    }

    /// 当前生效的筛选条数（右上角按钮上的角标）。
    var activeFilterCount: Int {
        [onlyShowWatchingBangumis, notShowWatchedBangumis, notShowAbandonedBangumis]
            .filter { $0 }
            .count
    }

    var seasonLabel: String {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: selectedDate)
        let month = calendar.component(.month, from: selectedDate)
        // 年份显式转字符串再拼接：整数插值可能被按千分位渲染成「2,026」。
        // 结果固定为「2026年秋季」，不加分隔符。
        return String(year) + "年" + AnimeSeason.seasonString(month: month) + "季"
    }

    var isCurrentSeason: Bool {
        AnimeSeason.isSameSeason(selectedDate, Date())
    }

    /// 卡片底部的时间胶囊：`HH:mm 更新`（对应 bangumi_timeline_card.dart 的
    /// `formatUpdateTime(updateEpoch) + ' 更新'`）。没有可靠时刻时不显示。
    func updateText(for item: BangumiItem) -> String? {
        guard let time = BangumiAirTimeService.shared.airTime(for: item.id) else { return nil }
        return "\(time) 更新"
    }

    /// 卡片底部的集数胶囊：已经播出到第几集（1-based）。
    ///
    /// 与 Dart 的 `BangumiUpdateTimesService.currentEpisode` 同源：用 bangumi-mal
    /// 季度表里的首播时刻与播出周期推算（`((now - first) ~/ period) + 1`），
    /// 往季同样适用 —— 往季的首播时刻就在那一年，算出来的集数是对的。
    /// 数据还没加载到时返回 nil，卡片少一个胶囊，不影响其余内容。
    func currentEpisode(for item: BangumiItem) -> Int? {
        BangumiAirTimeService.shared.currentEpisode(for: item.id)
    }

    // MARK: - 显示范围

    func setNotShowWatchedBangumis(_ value: Bool) { notShowWatchedBangumis = value }
    func setNotShowAbandonedBangumis(_ value: Bool) { notShowAbandonedBangumis = value }
    func setOnlyShowWatchingBangumis(_ value: Bool) { onlyShowWatchingBangumis = value }

    /// 对应 filterCalendar(watchingIds)：按三个开关过滤每一天。
    /// 收藏类型由调用方（LibraryStore）提供，控制器本身不依赖持久化的追番表。
    func filterCalendar(
        watchingIDs: Set<Int>,
        watchedIDs: Set<Int>,
        droppedIDs: Set<Int>
    ) -> [[BangumiItem]] {
        (0..<7).map { day in
            guard day < bangumiCalendar.count else { return [] }
            return bangumiCalendar[day].filter { item in
                if notShowAbandonedBangumis, droppedIDs.contains(item.id) { return false }
                if notShowWatchedBangumis, watchedIDs.contains(item.id) { return false }
                if onlyShowWatchingBangumis, !watchingIDs.contains(item.id) { return false }
                return true
            }
        }
    }

    /// 对应 clearFilters。
    func clearFilters() {
        notShowAbandonedBangumis = false
        notShowWatchedBangumis = false
        onlyShowWatchingBangumis = false
    }

    /// 对应 loadSeason。
    func loadSeason(_ date: Date, collectTypes: [Int: CollectType] = [:]) async {
        guard !isLoading else { return }
        isLoading = true
        isTimeOut = false
        selectedDate = date
        bangumiCalendar = []
        defer { isLoading = false }

        var calendar: [[BangumiItem]]
        if AnimeSeason.isSameSeason(date, Date()) {
            calendar = await BangumiAPI.calendar()
        } else {
            let range = AnimeSeason.seasonRange(for: date)
            calendar = await seasonCalendar(start: range.start, end: range.end)
        }

        // 先取季度时刻表：卡片上的「HH:mm 更新」与「第 N 话」、以及默认顺序的
        // 排序都依赖它。拉取失败时保持空表，只是少两个胶囊，不影响列表。
        await BangumiAirTimeService.shared.ensureLoaded(forSeasonOf: date)
        // 季度表拿到 MAL id 之后，再用 AniList 补一轮实测时刻：只查还没到
        // 下一集播出时刻的那些番，按 25 部一批，请求量与当季番数无关。
        await BangumiAirTimeService.shared.ensureAniListLoaded(calendar.flatMap { $0.map(\.id) })

        baseCalendar = calendar
        let merged = await mergeCustomEntries(into: groupedBaseCalendar(), collectTypes: collectTypes)
        bangumiCalendar = applySort(merged)
        isTimeOut = bangumiCalendar.allSatisfy(\.isEmpty)
    }

    /// 对应 refreshCustomTimelineEntries：详情页改完星期 / 开关展示后立刻生效。
    ///
    /// 每次都从接口返回的原始日历重新合并，改掉星期的番才能从原来那一天挪走，
    /// 而不是两处都留一份。
    func refreshCustomEntries(collectTypes: [Int: CollectType]) async {
        guard !baseCalendar.isEmpty else { return }
        let merged = await mergeCustomEntries(into: groupedBaseCalendar(), collectTypes: collectTypes)
        bangumiCalendar = applySort(merged)
    }

    /// bangumi 日历按放进时间表的**列**重新分一次桶（0 = 星期一）。
    ///
    /// 分组仍以 bangumi 的星期为准，只在一种情况下换列：更新时刻在凌晨
    /// 0–5 点时，bangumi 记的是前一天的节目日（日曜 24:00 / 25:05），本地
    /// 时钟却已经是第二天，放进第二天才和卡片上的 HH:mm 对得上。规则见
    /// `TimelineColumn.weekday`，与 main 的 `_groupedBaseCalendar` 一致。
    ///
    /// 接口返回空（超时 / 无数据）时保持空表：调用方用 isEmpty 判断是否
    /// 显示「加载失败」，补成 7 个空列表会把它误判成「这周没有番」。
    private func groupedBaseCalendar() -> [[BangumiItem]] {
        guard !baseCalendar.isEmpty else { return [] }
        var grouped: [[BangumiItem]] = Array(repeating: [], count: 7)
        for (day, items) in baseCalendar.enumerated() {
            for item in items {
                let column = TimelineColumn.weekday(
                    bangumiWeekday: day + 1,
                    airTimeOf: item.id
                )
                grouped[column - 1].append(item)
            }
        }
        // 详情页 / 追番页拿不到日历，用这份结果对齐同一列。
        TimelineWeekdayCache.replace(with: grouped)
        return grouped
    }

    /// 把用户设置过的条目并进日历（对应 _applyCustomTimelineEntries）。
    ///
    /// 星期只看两处：bangumi 日历的分组，以及用户点选过的放送星期。
    /// 哪一条算「用户选的」由 `BangumiTimelineStore.resolveWeekdays` 决定。
    private func mergeCustomEntries(
        into calendar: [[BangumiItem]],
        collectTypes: [Int: CollectType]
    ) async -> [[BangumiItem]] {
        guard !calendar.isEmpty else { return calendar }
        let store = BangumiTimelineStore.shared
        guard !store.entries.isEmpty else { return calendar }

        // 日历里已有的番：手动改星期时不用去收藏里找副本。
        var items: [Int: BangumiItem] = [:]
        for day in calendar {
            for item in day {
                items[item.id] = item
            }
        }
        let inCalendar = Set(items.keys)

        let weekdays = store.resolveWeekdays(inCalendar: inCalendar, collectTypes: collectTypes)
        guard !weekdays.isEmpty else { return calendar }

        // 手动添加的条目：日历里没有的番要单独拉一次详情，拉不到的跳过。
        for bangumiID in weekdays.keys where items[bangumiID] == nil {
            if let item = await BangumiAPI.info(id: bangumiID) {
                items[bangumiID] = item
            }
        }

        var merged: [[BangumiItem]] = calendar.map { day in
            day.filter { weekdays[$0.id] == nil }
        }
        while merged.count < 7 { merged.append([]) }
        for (bangumiID, weekday) in weekdays {
            guard let item = items[bangumiID] else { continue }
            let column = BangumiTimelineEntry.normalize(weekday) - 1
            merged[column].append(item)
        }
        return merged
    }

    /// 对应 _getSchedulesBySeason：每页 20 条、最多 4 页，按放送星期分列。
    private func seasonCalendar(start: String, end: String) async -> [[BangumiItem]] {
        if BangumiAcceleration.isMirrorEnabled {
            let mirror = await BangumiAPI.mirrorSeasonCalendar(start: start, end: end)
            if !mirror.isEmpty { return mirror }
        }
        var result: [[BangumiItem]] = Array(repeating: [], count: 7)
        let pageCount = 4
        let limit = 20
        for page in 0..<pageCount {
            let dayLists = await BangumiAPI.calendarBySearch(
                dateRange: [start, end],
                limit: limit,
                offset: page * limit
            )
            guard dayLists.count == 7 else { break }
            for day in 0..<7 {
                result[day].append(contentsOf: dayLists[day])
            }
            if dayLists.allSatisfy(\.isEmpty) { break }
        }
        return result
    }

    /// 对应 changeSort。
    func changeSort(_ sort: TimelineSort) async {
        self.sort = sort
        bangumiCalendar = applySort(bangumiCalendar)
    }

    private func applySort(_ calendar: [[BangumiItem]]) -> [[BangumiItem]] {
        switch sort {
        case .defaultOrder:
            // 与 Dart 的 compareTimelineUpdateTime 一致：同一列内按当天时刻从早到晚，
            // 无时刻的排最后，同序回退 id。时刻来自卡片的同一个 HH:mm。
            let times = BangumiAirTimeService.shared.times
            return calendar.map { day in
                day.sorted { lhs, rhs in
                    let left = times[lhs.id]
                    let right = times[rhs.id]
                    if left == nil, right == nil { return lhs.id < rhs.id }
                    if left == nil { return false }
                    if right == nil { return true }
                    if left == right { return lhs.id < rhs.id }
                    return (left ?? "") < (right ?? "")
                }
            }
        case .popularity:
            return calendar.map { day in
                day.sorted { lhs, rhs in
                    if lhs.votes == rhs.votes { return lhs.rank < rhs.rank }
                    return lhs.votes > rhs.votes
                }
            }
        case .rating:
            return calendar.map { day in
                day.sorted { lhs, rhs in
                    if lhs.ratingScore == rhs.ratingScore { return lhs.votes > rhs.votes }
                    return lhs.ratingScore > rhs.ratingScore
                }
            }
        }
    }
}
