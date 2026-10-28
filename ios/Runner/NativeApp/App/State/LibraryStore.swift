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

    /// 收藏状态名，对应 lib/modules/collect/collect_type.dart 的 CollectType.label。
    /// 收藏库卡片、收藏库筛选栏用的是这一套（未收藏 / 在看 / 想看 / 搁置 / 看过 / 抛弃）。
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

    /// 详情页追番按钮与下拉菜单的文案，对应
    /// lib/bean/widget/collect_button.dart 的 getTypeStringByInt：
    /// 未追 / 在看 / 想看 / 搁置 / 看过 / 抛弃。
    ///
    /// 与 [title] 只差「未追」这一档：按钮上的未收藏状态叫「未追」，
    /// 收藏库里的分类仍叫「未收藏」，两处不要混用。
    /// 追番状态的图标，1:1 翻自原版 `lib/bean/widget/collect_button.dart:83-97`
    /// 的 `getIconByInt`（Material → SF Symbols）：
    /// 在看 heart.fill、想看 star.fill、搁置 hourglass、看过 checkmark、
    /// 抛弃 heart.slash.fill、未收藏 heart。
    var statusSymbol: String {
        switch self {
        case .watching: "heart.fill"
        case .wish: "star.fill"
        case .onHold: "hourglass"
        case .watched: "checkmark"
        case .dropped: "heart.slash.fill"
        case .none: "heart"
        }
    }

    var buttonTitle: String {
        switch self {
        case .none: "未追"
        case .watching: "在看"
        case .wish: "想看"
        case .onHold: "搁置"
        case .watched: "看过"
        case .dropped: "抛弃"
        }
    }

    /// 对应 collect_type_mapper.dart 的 toBangumiCollectionType：
    /// Bangumi 的收藏类型编号与本地编号不同（本地 1=在看，Bangumi 3=在看）。
    /// 写回收藏状态时要用这一套。
    var bangumiCollectionType: Int? {
        switch self {
        case .none: nil
        case .watching: 3
        case .wish: 1
        case .onHold: 4
        case .watched: 2
        case .dropped: 5
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
/// 本端取消过的收藏：番剧 ID + 取消时刻。
///
/// 合并时按时间比：取消比收藏晚就删掉，云盘上还留着的那条不会把收藏「复活」。
/// 跟着 WebDAV 备份一起走，别的设备也能看到这次取消。
struct RemovedEntry: Codable, Hashable, Sendable {
    var id: Int
    var removedAt: Date
}

///
/// 持久化对应原版的 Hive box（`collect` / `history`）：这里换成
/// Application Support/Kazumi/library.json 这一个文件，字段与
/// WebDAV 备份（`WebDAVClient.Payload`）保持一致，备份恢复时直接覆盖即可。
@MainActor
@Observable
final class LibraryStore {
    /// 落盘用的容器；`version` 与 WebDAV 备份一样从 1 起。
    private struct Snapshot: Codable, Sendable {
        var version: Int = 1
        var savedAt: Date = Date()
        var entries: [LibraryEntry]
        var history: [WatchRecord]
        var removedEntries: [RemovedEntry]?
    }

    /// 追番 / 观看历史的存储文件：Application Support/Kazumi/library.json。
    static var defaultFileURL: URL {
        AppEnvironment.storageRoot.appending(path: "library.json")
    }

    private(set) var entries: [LibraryEntry] = []
    private(set) var history: [WatchRecord] = []
    /// 取消过的收藏（ID + 时刻）。旧版没有这份记录，取消会被云盘「复活」，所以要自己记。
    private(set) var removedEntries: [RemovedEntry] = []

    private let fileURL: URL

    init(fileURL: URL = LibraryStore.defaultFileURL) {
        self.fileURL = fileURL
    }

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

    // MARK: - 持久化

    /// 启动时读回上次的追番与历史；文件不存在或损坏时保持空表。
    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            entries = []
            history = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try Self.decoder().decode(Snapshot.self, from: data)
            // 读回时就收敛重复 ID：旧版本可能已经写进过重复记录，
            // 展示层拿到的必须是一份干净的、ID 唯一的数据。
            entries = Self.deduplicated(snapshot.entries)
            history = Self.deduplicated(snapshot.history)
            removedEntries = snapshot.removedEntries ?? []
            KazumiLog.storage.info(
                "Library: 载入 \(self.entries.count, privacy: .public) 条追番 / \(self.history.count, privacy: .public) 条历史"
            )
        } catch {
            // 文件损坏时不阻塞启动：从空表开始，下次写入会覆盖掉坏文件。
            KazumiLog.storage.error(
                "Library: 读取失败 \(error.localizedDescription, privacy: .public)"
            )
            entries = []
            history = []
        }
    }

    /// 写回磁盘。数据量很小（几百条），同步写 + `.atomic` 足够快，
    /// 也不用担心后台任务还没落地就被系统杀掉。
    private func save() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let snapshot = Snapshot(entries: entries, history: history, removedEntries: removedEntries)
            try Self.encoder().encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            KazumiLog.storage.error(
                "Library: 写入失败 \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - 变更

    func replace(entries: [LibraryEntry], history: [WatchRecord]) {
        self.entries = Self.deduplicated(entries)
        self.history = Self.deduplicated(history)
        save()
    }

    /// 同步把合并后的取消记录写回本机。收藏重新加回来的那些不再需要记着。
    func replaceRemovals(_ removals: [RemovedEntry]) {
        let collected = Set(entries.map(\.id))
        removedEntries = removals.filter { !collected.contains($0.id) }
        save()
    }

    func upsert(_ entry: LibraryEntry) {
        // 重新收藏回来了：之前那条取消记录作废。
        if removedEntries.contains(where: { $0.id == entry.id }) {
            removedEntries.removeAll { $0.id == entry.id }
        }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            // 同一部番如果因为合并 / 恢复被写进多份，这里顺手并掉多余的几份：
            // `ForEach` 遇到重复 ID 会直接崩溃，列表里也会出现两张一样的卡片。
            entries = Self.deduplicated(entries)
        } else {
            entries.append(entry)
        }
        save()
    }

    func remove(bangumiID: Int) {
        entries.removeAll { $0.id == bangumiID }
        // 记下取消的时刻：不带这一条，下次同步就会从云盘把它加回来。
        removedEntries.removeAll { $0.id == bangumiID }
        removedEntries.append(RemovedEntry(id: bangumiID, removedAt: Date()))
        save()
    }

    func upsert(_ record: WatchRecord) {
        if let index = history.firstIndex(where: { $0.bangumiID == record.bangumiID }) {
            history[index] = record
        } else {
            history.insert(record, at: 0)
        }
        save()
    }

    /// 只补空着的名字 / 封面，别的字段（进度、集数、时间）一律不动。
    ///
    /// 播放页写记录时，没追过番的条目本地拿不到番剧名和封面（Colo 3554：
    /// `PlayerScreen.swift` 那两处都是 `?? ""`），记录就成了空壳，
    /// 历史列表和「我的」页上只剩一个占位框。补的时候走 Bangumi 取一次。
    func backfillHistoryMeta(bangumiID: Int, name: String, imageURL: String) {
        guard let index = history.firstIndex(where: { $0.bangumiID == bangumiID }) else { return }
        var record = history[index]
        var changed = false
        if record.bangumiName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !name.isEmpty {
            record.bangumiName = name
            changed = true
        }
        if record.imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !imageURL.isEmpty {
            record.imageURL = imageURL
            changed = true
        }
        guard changed else { return }
        history[index] = record
        save()
    }

    func removeHistory(bangumiID: Int) {
        history.removeAll { $0.bangumiID == bangumiID }
        save()
    }

    // MARK: - 去重

    /// 按 ID 去重，保留更新时间较新的那一条（顺序取首次出现的位置）。
    ///
    /// 追番与历史都是以番剧 ID 为主键的表：WebDAV 恢复、Bangumi 同步与本地写入
    /// 三条路径都可能带进同一 ID 的两条记录。SwiftUI 的 `ForEach` 用 ID 做
    /// 身份，重复 ID 会让列表的差量更新错乱（表现为切换筛选后闪退），
    /// 因此在数据进入 store 的那一刻就收敛掉。
    static func deduplicated(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        var indexByID: [Int: Int] = [:]
        var result: [LibraryEntry] = []
        for entry in entries {
            if let index = indexByID[entry.id] {
                if entry.updatedAt > result[index].updatedAt {
                    result[index] = entry
                }
            } else {
                indexByID[entry.id] = result.count
                result.append(entry)
            }
        }
        return result
    }

    static func deduplicated(_ history: [WatchRecord]) -> [WatchRecord] {
        var indexByID: [Int: Int] = [:]
        var result: [WatchRecord] = []
        for record in history {
            if let index = indexByID[record.bangumiID] {
                if record.updatedAt > result[index].updatedAt {
                    result[index] = record
                }
            } else {
                indexByID[record.bangumiID] = result.count
                result.append(record)
            }
        }
        return result
    }

    // MARK: - 编解码

    /// 与 WebDAV 备份保持同一套日期编码（ISO 8601），
    /// 这样本地文件与备份文件可以互相替换、也能人工查看。
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
