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
        return "\(year)年\(AnimeSeason.seasonString(month: month))季"
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
    /// 原版用 AniList / bangumi-mal 的实测数据，这里按 Bangumi 的 `air_date`
    /// 与每周一集推算 —— 只对当前季度生效，往季不显示（否则会算出几十集）。
    func currentEpisode(for item: BangumiItem) -> Int? {
        guard isCurrentSeason else { return nil }
        guard let first = DateTimeHelper.parseISO(item.airDate) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: first)
        let today = calendar.startOfDay(for: Date())
        guard today >= start else { return nil }
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return days / 7 + 1
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
    func loadSeason(_ date: Date) async {
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
        // 详情页里点亮「在时间表展示」的条目，并进对应星期那一列。
        await mergeCustomEntries(into: &calendar)
        bangumiCalendar = applySort(calendar)
        isTimeOut = bangumiCalendar.allSatisfy(\.isEmpty)

        // 卡片的「HH:mm 更新」胶囊：数据来自 bangumi-mal 的季度表，
        // 拉取失败时保持空表（只少了时间胶囊，不影响列表）。
        await BangumiAirTimeService.shared.ensureLoaded(forSeasonOf: date)
    }

    /// 对应 refreshCustomTimelineEntries：把用户手动点亮的条目并进时间表。
    /// 官方日历里没有的番，按用户设定的放送星期放到那一列。
    private func mergeCustomEntries(into calendar: inout [[BangumiItem]]) async {
        let custom = BangumiTimelineStore.shared.entries.filter { $0.value.showInTimeline }
        guard !custom.isEmpty else { return }
        for (bangumiID, entry) in custom {
            let weekday = max(1, min(7, entry.weekday)) - 1
            guard calendar.indices.contains(weekday) else { continue }
            if calendar[weekday].contains(where: { $0.id == bangumiID }) { continue }
            guard let item = await BangumiAPI.info(id: bangumiID) else { continue }
            calendar[weekday].append(item)
        }
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
            return calendar
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
