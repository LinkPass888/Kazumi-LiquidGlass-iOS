//
//  LibraryStore.swift
//  Kazumi
//
//  追番 / 历史 / 播放进度的内存索引（替代 CollectController / HistoryController）。
//  真正的持久化由 Step 3 的 StorageRepository 负责；这里只持有 UI 直接读取的快照，
//  保证 Step 1 即可编译、Step 3 之后无需改动调用方。
//

import Foundation
import Observation

/// 收藏类型，数值与 lib/modules/collect/collect_type.dart 逐一对应，
/// 保证导出 / WebDAV 备份与 Flutter 版互通（watching = 1，planToWatch(想看) = 2）。
enum CollectType: Int, Codable, CaseIterable, Sendable, Identifiable {
    case none = 0
    case watching = 1
    case wish = 2
    case onHold = 3
    case watched = 4
    case dropped = 5

    var id: Int { rawValue }

    /// 可选的收藏状态（排除「未收藏」）。
    static var enabledCases: [CollectType] { [.watching, .wish, .onHold, .watched, .dropped] }

    var title: String {
        switch self {
        case .none: "未收藏"
        case .watching: "在看"
        case .wish: "想看"
        case .onHold: "搁置"
        case .watched: "看过"
        case .dropped: "抛弃"
        }
    }

    var symbolName: String {
        switch self {
        case .none: "plus"
        case .watching: "play.circle"
        case .wish: "bookmark"
        case .onHold: "pause.circle"
        case .watched: "checkmark.circle"
        case .dropped: "xmark.circle"
        }
    }
}


/// 追番条目（对应原项目 BangumiItem 中 UI 需要的字段子集）。
struct LibraryEntry: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    var type: Int
    var name: String
    var nameCn: String
    var summary: String
    var airDate: String
    var imageURL: String
    var rating: Double
    var rank: Int
    var tags: [String]
    var totalEpisodes: Int
    var currentEpisode: Int
    var addedAt: Date
    var updatedAt: Date

    var displayName: String { nameCn.isEmpty ? name : nameCn }

    var collectType: CollectType { CollectType(rawValue: type) ?? .none }
}

/// 观看进度（对应原项目 history 记录）。
struct WatchRecord: Identifiable, Codable, Hashable, Sendable {
    var id: Int { bangumiID }
    var bangumiID: Int
    var bangumiName: String
    var imageURL: String
    var sourceRuleName: String
    var episodeTitle: String
    var episodeNumber: Int
    var progressSeconds: Double
    var durationSeconds: Double
    var updatedAt: Date

    var fraction: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(max(progressSeconds / durationSeconds, 0), 1)
    }

    var isFinished: Bool {
        durationSeconds > 0 && durationSeconds - progressSeconds <= 5
    }
}

/// 追番列表与历史的可观察快照。
@MainActor
@Observable
final class LibraryStore {
    private(set) var entries: [LibraryEntry] = []
    private(set) var history: [WatchRecord] = []

    /// 正在追的番（对应 main.dart 的 _watchingBangumis）。
    var watchingEntries: [LibraryEntry] {
        entries.filter { $0.collectType == .watching }
    }

    /// 继续观看：按更新时间倒序、去掉已看完的记录。
    var upNext: [WatchRecord] {
        history
            .filter { !$0.isFinished && $0.progressSeconds > 5 }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func entry(for bangumiID: Int) -> LibraryEntry? {
        entries.first { $0.id == bangumiID }
    }

    func record(for bangumiID: Int) -> WatchRecord? {
        history.first { $0.bangumiID == bangumiID }
    }

    func replace(entries: [LibraryEntry], history: [WatchRecord]) {
        self.entries = entries
        self.history = history
    }

    func upsert(_ entry: LibraryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    func remove(bangumiID: Int) {
        entries.removeAll { $0.id == bangumiID }
    }

    func upsert(_ record: WatchRecord) {
        if let index = history.firstIndex(where: { $0.bangumiID == record.bangumiID }) {
            history[index] = record
        } else {
            history.insert(record, at: 0)
        }
    }

    func removeHistory(bangumiID: Int) {
        history.removeAll { $0.bangumiID == bangumiID }
    }
}
