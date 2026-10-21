//
//  TimelineController.swift
//  Kazumi
//
//  1:1 翻译 lib/pages/timeline/timeline_controller.dart 的核心路径：
//  * 当前季度走 getCalendar（7 天分组，下标 0 = 周一）；
//  * 历史季度走官方搜索接口（getCalendarBySearch），失败则退回镜像季度表；
//  * 支持按热度 / 评分 / 默认顺序排序。
//

import Observation

/// 与 Dart 的 TimelineSort 一致。
enum TimelineSort: String, CaseIterable, Identifiable, Sendable {
    case popularity
    case rating
    case defaultOrder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .popularity: "热度"
        case .rating: "评分"
        case .defaultOrder: "默认排序"
        }
    }
}

@MainActor
@Observable
final class TimelineController {
    /// 7 天的番剧，下标 0 为周一。
    private(set) var bangumiCalendar: [[BangumiItem]] = []
    private(set) var selectedDate = Date()
    private(set) var isLoading = false
    private(set) var isTimeOut = false
    var sort: TimelineSort = .defaultOrder

    /// 供星期选择器使用的每日数量。
    var counts: [Int] {
        (0..<7).map { index in
            index < bangumiCalendar.count ? bangumiCalendar[index].count : 0
        }
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

    /// 对应 loadSeason。
    func loadSeason(_ date: Date) async {
        guard !isLoading else { return }
        isLoading = true
        isTimeOut = false
        selectedDate = date
        bangumiCalendar = []
        defer { isLoading = false }

        if AnimeSeason.isSameSeason(date, Date()) {
            let calendar = await BangumiAPI.calendar()
            bangumiCalendar = applySort(calendar)
            isTimeOut = bangumiCalendar.allSatisfy(\.isEmpty)
        } else {
            let range = AnimeSeason.seasonRange(for: date)
            let calendar = await seasonCalendar(start: range.start, end: range.end)
            bangumiCalendar = applySort(calendar)
            isTimeOut = bangumiCalendar.allSatisfy(\.isEmpty)
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
