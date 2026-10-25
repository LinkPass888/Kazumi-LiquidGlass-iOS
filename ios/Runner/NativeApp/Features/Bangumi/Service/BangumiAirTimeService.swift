//
//  BangumiAirTimeService.swift
//  Kazumi
//
//  放送时刻（「每周六 20:00」里的 20:00）。
//
//  对应原版 lib/services/bangumi_update_times.dart 的一部分：原版从
//  bangumi-mal 的季度 JSON（https://github.com/LinkPass888/bangumi-mal，CC BY 4.0）
//  取每部番的开播时刻与播出周期，再换算成本地时间。季度文件地址形如
//  `data/seasons/{年}/{季首月}.json`，季首月只可能是 1 / 4 / 7 / 10，
//  items 以 bangumi id 为键，含 `begin`（ISO UTC）与 `broadcast`（`R/<ISO>/P7D`）。
//
//  这里只做详情页需要的那一件事：算出「几点播」，格式化成 HH:mm。
//  取不到就返回 nil，详情页那一行只显示星期，不显示时刻。
//

import Foundation
import Observation

/// 某部番的放送时刻表（对应 Dart 的 BangumiUpdateEntry 子集）。
struct BangumiAirSchedule: Hashable, Sendable {
    /// 首播时刻（本地时区，含具体钟点）。
    var first: Date
    /// 播出周期（秒），即 `R/<ISO>/P7D` 里的 7 天。
    var period: TimeInterval

    /// 已经播出到第几集（1-based）；尚未开播返回 nil。
    ///
    /// 与 Dart 的 `currentEpisode` 同一套算式：`((now - first) ~/ period) + 1`。
    func currentEpisode(now: Date = Date()) -> Int? {
        guard period > 0 else { return nil }
        let elapsed = now.timeIntervalSince(first)
        guard elapsed >= 0 else { return nil }
        return Int(elapsed / period) + 1
    }
}


@MainActor
@Observable
final class BangumiAirTimeService {
    static let shared = BangumiAirTimeService()

    /// bangumi id -> "20:00"
    private(set) var times: [Int: String] = [:]
    /// bangumi id -> 首播时刻 + 周期（时间表卡片的「第 N 话」用它推算）。
    private(set) var schedules: [Int: BangumiAirSchedule] = [:]
    private(set) var isLoading = false

    /// 已经成功加载过的季度（"2025-10"）。
    private var loadedSeasons = Set<String>()
    private var inFlight: [String: Task<Void, Never>] = [:]

    /// 季度数据 7 天更新一次，与原版 _maxAge 一致。
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    private let directory: URL
    private let session: URLSession

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = caches.appendingPathComponent("KazumiAirTimes", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    // MARK: - 查询

    /// 某部番的播出时刻（本地时间 "HH:mm"），没有数据返回 nil。
    func airTime(for subjectID: Int) -> String? {
        times[subjectID]
    }

    /// 某部番的首播时刻与周期（更新提醒按它推算下一集），没有数据返回 nil。
    func schedule(for subjectID: Int) -> BangumiAirSchedule? {
        schedules[subjectID]
    }

    /// 加载这部番所属季度（以及当前季度，兼顾跨季番）的时刻表。
    func ensureLoaded(subjectID: Int, airDate: String) async {
        guard times[subjectID] == nil else { return }

        var seasons = Self.season(of: airDate).map { [$0] } ?? []
        seasons.append(Self.currentSeason())
        for season in Set(seasons.map(\.id)) where !loadedSeasons.contains(season) {
            await loadSeason(id: season)
        }
    }

    /// 加载某个日期所属季度（以及当前季度）的时刻表。
    ///
    /// 时间表页整季展示时会一次性需要几十部番的时刻，逐部调用
    /// `ensureLoaded(subjectID:airDate:)` 会重复建任务；这里按季度去重，
    /// 一个季度只发一次请求。
    func ensureLoaded(forSeasonOf date: Date) async {
        let target = Self.season(of: date)
        let current = Self.currentSeason()
        for season in [target, current] where !loadedSeasons.contains(season.id) {
            await loadSeason(id: season.id)
        }
    }

    // MARK: - 季度

    private struct Season: Hashable {
        let year: Int
        let month: Int
        var id: String { String(format: "%04d-%02d", year, month) }
    }

    /// Date -> 所在季度。
    private static func season(of date: Date) -> Season {
        let components = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month], from: date)
        let year = components.year ?? 2024
        let month = components.month ?? 1
        return Season(year: year, month: ((month - 1) / 3) * 3 + 1)
    }

    /// "yyyy-MM-dd" -> 所在季度；解析不出来返回 nil。
    private static func season(of airDate: String) -> Season? {
        let parts = airDate.split(separator: "-")
        guard parts.count >= 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              (1...12).contains(month)
        else { return nil }
        return Season(year: year, month: ((month - 1) / 3) * 3 + 1)
    }

    private static func currentSeason() -> Season {
        let components = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month], from: Date())
        let year = components.year ?? 2024
        let month = components.month ?? 1
        return Season(year: year, month: ((month - 1) / 3) * 3 + 1)
    }

    private static func remoteURL(for season: Season) -> URL? {
        let month = String(format: "%02d", season.month)
        return URL(string: "https://linkpass888.github.io/bangumi-mal/data/seasons/\(season.year)/\(month).json")
    }

    private func cacheURL(for season: Season) -> URL {
        directory.appendingPathComponent("\(season.id).json")
    }

    // MARK: - 加载

    private func loadSeason(id: String) async {
        if let running = inFlight[id] {
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetchSeason(id: id)
        }
        inFlight[id] = task
        await task.value
        inFlight[id] = nil
    }

    private func fetchSeason(id: String) async {
        isLoading = true
        defer {
            isLoading = false
            loadedSeasons.insert(id)
        }

        let components = id.split(separator: "-")
        guard components.count == 2,
              let year = Int(components[0]),
              let month = Int(components[1])
        else { return }
        let season = Season(year: year, month: month)
        let fileURL = cacheURL(for: season)

        // 1. 本地缓存（7 天内直接用）
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < Self.maxAge,
           let data = try? Data(contentsOf: fileURL) {
            apply(data)
            return
        }

        // 2. 远端
        guard let remote = Self.remoteURL(for: season) else { return }
        do {
            let (data, response) = try await session.data(from: remote)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return
            }
            apply(data)
            try? data.write(to: fileURL, options: .atomic)
        } catch {
            // 拉不到就保持空表，详情页只显示星期。
        }
    }

    private func apply(_ data: Data) {
        for (subjectID, schedule) in Self.parse(data) {
            times[subjectID] = Self.timeText(schedule.first)
            schedules[subjectID] = schedule
        }
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 解析季度 JSON，返回「bangumi id -> 首播时刻 + 周期」。
    private static func parse(_ data: Data) -> [Int: BangumiAirSchedule] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [String: Any]
        else { return [:] }

        var result: [Int: BangumiAirSchedule] = [:]
        for (key, value) in items {
            guard let subjectID = Int(key), let entry = value as? [String: Any] else { continue }
            let beginText = entry["begin"] as? String ?? ""
            let broadcast = entry["broadcast"] as? String ?? ""
            // 与原版 deriveBangumiMalEntry 一致：begin 只有日期（或年月）时
            // 拿不出可信的播出时刻，不显示。
            guard beginText.count > 10 else { continue }
            guard let period = parseBroadcastPeriod(broadcast) else { continue }
            guard let begin = parseInstant(beginText) else { continue }
            result[subjectID] = BangumiAirSchedule(first: begin, period: period)
        }
        return result
    }

    /// `R/<ISO>/P7D` 里的周期；解析不出来（或为 0）返回 nil。
    ///
    /// 这里只用来判断「这条记录有没有可靠时刻」，与时刻本身无关。
    private static func parseBroadcastPeriod(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("R/") else { return nil }
        let parts = trimmed.split(separator: "/")
        guard parts.count == 3 else { return nil }
        let period = String(parts[2])
        guard period.hasPrefix("P") else { return nil }
        var seconds: TimeInterval = 0
        var digits = ""
        for character in period.dropFirst() {
            if character.isNumber {
                digits.append(character)
            } else if character == "D" {
                seconds += (Double(digits) ?? 0) * 86_400
                digits = ""
            } else if character == "H" {
                seconds += (Double(digits) ?? 0) * 3_600
                digits = ""
            } else if character == "T" {
                digits = ""
            } else {
                return nil
            }
        }
        return seconds > 0 ? seconds : nil
    }

    /// 解析带时刻的 ISO 时间戳（`Z` 或 `+00:00`，可带小数秒）。
    private static func parseInstant(_ text: String) -> Date? {
        for formatter in instantFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static let instantFormatters: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFraction, plain]
    }()
}
