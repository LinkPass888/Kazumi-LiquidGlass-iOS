//
//  KazumiLogBuffer.swift
//  Kazumi
//
//  os.Logger 的写入无法被 App 自身读回，而「运行日志」页需要可复制的文本，
//  因此在关键路径（规则检索、选源、播放）额外写一份环形缓冲。
//  使用 OSAllocatedUnfairLock 保护，Sendable 且不阻塞主线程。
//

import Foundation
import os

final class KazumiLogBuffer: Sendable {
    static let shared = KazumiLogBuffer()

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case plugin
        case network
        case player

        var id: String { rawValue }

        var title: String {
            switch self {
            case .plugin: "规则"
            case .network: "网络"
            case .player: "播放"
            }
        }
    }

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let category: Category
        let timestamp: Date
        let message: String
    }

    /// 每个分类最多保留的条数，超出后丢弃最旧的记录。
    private static let capacity = 200

    private let storage = OSAllocatedUnfairLock(initialState: [Category: [Entry]]())

    func append(_ message: String, category: Category) {
        let entry = Entry(category: category, timestamp: Date(), message: message)
        storage.withLock { buckets in
            var items = buckets[category] ?? []
            items.append(entry)
            if items.count > Self.capacity {
                items.removeFirst(items.count - Self.capacity)
            }
            buckets[category] = items
        }
    }

    func snapshot() -> [Entry] {
        storage.withLock { buckets in
            buckets.values.flatMap { $0 }.sorted { $0.timestamp < $1.timestamp }
        }
    }

    func clear(_ category: Category) {
        storage.withLock { $0[category] = [] }
    }
}

extension KazumiLogBuffer {
    /// 记录规则检索结果（与 os.Logger 的输出并行写入缓冲）。
    static func plugin(_ message: String) {
        KazumiLog.plugin.info("\(message, privacy: .public)")
        shared.append(message, category: .plugin)
    }

    static func network(_ message: String) {
        KazumiLog.network.info("\(message, privacy: .public)")
        shared.append(message, category: .network)
    }

    static func player(_ message: String) {
        KazumiLog.player.info("\(message, privacy: .public)")
        shared.append(message, category: .player)
    }
}
