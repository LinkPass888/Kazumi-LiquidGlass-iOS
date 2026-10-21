//
//  BangumiTimelineStore.swift
//  Kazumi
//
//  对应 lib/services/storage/bangumi_timeline_store.dart：
//  详情页里「放送星期」与「是否在时间表展示」的持久化。
//  原版用 Hive 存，本地版用 UserDefaults 存一份 JSON，字段语义与原版一致。
//

import Foundation
import Observation

/// 时间表自定义条目。
@MainActor
@Observable
final class BangumiTimelineStore {
    static let shared = BangumiTimelineStore()

    /// 单个番剧的自定义信息。
    struct Entry: Codable, Hashable, Sendable {
        /// 放送星期（1 = 周一 ... 7 = 周日）。
        var weekday: Int
        /// 用户是否手动改过星期。改过就以这里的为准，不再用条目的默认开播日。
        var weekdayCustom: Bool
        /// 是否在时间表里展示。
        var showInTimeline: Bool
    }

    private static let storageKey = "kazumi.timeline.entries"

    /// bangumiID -> 自定义信息。
    private(set) var entries: [Int: Entry] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = Self.load(defaults)
    }

    func entry(for bangumiID: Int) -> Entry? {
        entries[bangumiID]
    }

    /// 对应 setWeekday：手动指定放送星期。
    func setWeekday(_ weekday: Int, for bangumiID: Int) {
        var entry = entries[bangumiID] ?? Entry(weekday: weekday, weekdayCustom: true, showInTimeline: false)
        entry.weekday = weekday
        entry.weekdayCustom = true
        entries[bangumiID] = entry
        save()
    }

    /// 对应 setShowInTimeline：点亮 / 熄灭「在时间表展示」。
    func setShowInTimeline(_ value: Bool, for bangumiID: Int, weekday: Int) {
        var entry = entries[bangumiID] ?? Entry(weekday: weekday, weekdayCustom: false, showInTimeline: false)
        entry.showInTimeline = value
        entry.weekday = weekday
        entries[bangumiID] = entry
        save()
    }

    private func save() {
        let payload = entries.mapValues { entry in
            [
                "weekday": entry.weekday,
                "weekdayCustom": entry.weekdayCustom,
                "showInTimeline": entry.showInTimeline,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(_ defaults: UserDefaults) -> [Int: Entry] {
        guard let data = defaults.data(forKey: storageKey),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [:] }
        var result: [Int: Entry] = [:]
        for (key, value) in object {
            guard let id = Int(key) else { continue }
            result[id] = Entry(
                weekday: value["weekday"] as? Int ?? 1,
                weekdayCustom: value["weekdayCustom"] as? Bool ?? false,
                showInTimeline: value["showInTimeline"] as? Bool ?? false
            )
        }
        return result
    }
}