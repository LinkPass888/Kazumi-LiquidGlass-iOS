//
//  KazumiImageCache.swift
//  Kazumi
//
//  网络图片缓存，对应原版 lib/bean/card/network_img_layer.dart 依赖的
//  CachedNetworkImage（磁盘 + 内存两级缓存）：
//
//   * 内存层 NSCache：滚动时立刻拿到首帧，不出现「灰块 → 图片」的闪动；
//   * 磁盘层 Caches 目录：冷启动、杀掉进程后仍然命中，不必重新下载；
//   * 同一个 URL 的并发请求合并成一次（single flight）；
//   * 解码与写盘都在主线程之外完成，避免首帧解码卡住滚动。
//
//  Swift 6 严格并发下 UIImage 不作为值跨隔离域传递：加载方法只负责把图片放进
//  NSCache 并返回是否成功，视图再用同步方法从缓存里取。
//

import CryptoKit
import Foundation
import UIKit

/// 两级图片缓存。NSCache 本身线程安全，因此这个类型可以安全地被并发访问。
final class KazumiImageLoader: @unchecked Sendable {
    static let shared = KazumiImageLoader()

    /// 磁盘缓存保留天数，与原版 cached_network_image 的默认有效期一致。
    private static let maxAge: TimeInterval = 14 * 24 * 60 * 60
    /// 磁盘缓存上限（字节）。
    private static let maxDiskBytes = 300 * 1024 * 1024

    private let memory = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inFlight: [String: Task<Void, Never>] = [:]
    private let directory: URL
    private let session: URLSession

    private init() {
        // 放在 Application Support 而不是 Caches：Caches 会被系统在存储紧张时整目录清掉，
        // 表现就是「重启几次之后封面又全部重新下载」。图片属于可再生数据，但重新
        // 下载的流量与等待完全没必要。
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base
            .appendingPathComponent("Kazumi", isDirectory: true)
            .appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        memory.countLimit = 800
        memory.totalCostLimit = 128 * 1024 * 1024

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        // 除了自己按 SHA256 落盘，再叠一层 HTTP 缓存：即便磁盘文件被外部清理，
        // URLCache 仍可能给出同一张图。
        configuration.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024,
            diskPath: "KazumiHTTPCache"
        )
        session = URLSession(configuration: configuration)

        // 启动时清一轮过期文件；放后台，不阻塞首屏。
        let target = directory
        Task.detached(priority: .utility) {
            KazumiImageLoader.prune(directory: target)
        }
    }

    // MARK: - 同步读内存

    /// 已解码好的图片，命中时视图可以直接当首帧画出来。
    func cachedImage(for key: String) -> UIImage? {
        memory.object(forKey: key as NSString)
    }

    /// 把一个远端地址换算成缓存键（同时做 http -> https 的归一）。
    static func cacheKey(for url: String) -> String {
        normalizedURLString(url)
    }

    /// Bangumi 图床会给出 http / 协议相对地址，统一补成 https 后再算键，
    /// 这样同一张图不会因为地址写法不同而缓存两份。
    static func normalizedURLString(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("http://") {
            return "https://" + trimmed.dropFirst("http://".count)
        }
        return trimmed
    }

    // MARK: - 异步加载

    /// 确保这个地址的图片已经进入内存缓存。返回 true 表示可以立刻取图。
    ///
    /// 同一个 key 上已经在跑的请求会被复用；调用方（视图的 `.task`）被取消时
    /// 不会连带取消下载 —— 图还是要落盘，下次滚动回来才能直接命中。
    @discardableResult
    func load(_ url: String) async -> Bool {
        let key = Self.cacheKey(for: url)
        guard !key.isEmpty else { return false }
        if memory.object(forKey: key as NSString) != nil { return true }

        let task: Task<Void, Never> = lock.withLock {
            if let existing = inFlight[key] { return existing }
            // 闭包里必须显式解包 self：`await self?.fetch(key: key)` 是单表达式，
            // 可选链会让闭包被推断成返回 `Void?`，从而得到 `Task<()?, Never>`，
            // 和 `[String: Task<Void, Never>]` 对不上。
            let created = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.fetch(key: key)
            }
            inFlight[key] = created
            return created
        }
        await task.value
        return memory.object(forKey: key as NSString) != nil
    }

    /// 预取：给列表里即将出现的图片预热缓存，不阻塞调用方。
    func prefetch(_ urls: [String]) {
        for url in urls {
            let key = Self.cacheKey(for: url)
            guard !key.isEmpty, memory.object(forKey: key as NSString) == nil else { continue }
            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.load(key)
            }
        }
    }

    private func fetch(key: String) async {
        defer {
            lock.withLock { _ = inFlight.removeValue(forKey: key) }
        }

        let fileURL = directory.appendingPathComponent(Self.fileName(for: key))

        // 1. 磁盘
        if let data = try? Data(contentsOf: fileURL), let image = await Self.decode(data) {
            store(image, key: key)
            return
        }

        // 2. 网络
        // 缓存 key 始终是原始地址；真正去取的时候按「图片加速」可能换成镜像地址。
        guard let logical = URL(string: key) else { return }
        let remote = BangumiImageRewriter.rewritten(logical)
        do {
            let (data, response) = try await session.data(from: remote)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return
            }
            guard let image = await Self.decode(data) else { return }
            store(image, key: key)
            try? data.write(to: fileURL, options: .atomic)
        } catch {
            // 网络失败就保持空缓存，视图继续显示占位图。
        }
    }

    private func store(_ image: UIImage, key: String) {
        let scale = image.scale
        let cost = Int(image.size.width * image.size.height * scale * scale * 4)
        memory.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// 解码放到后台执行器上，主线程只拿结果。
    private static func decode(_ data: Data) async -> UIImage? {
        guard let raw = UIImage(data: data) else { return nil }
        return await raw.byPreparingForDisplay() ?? raw
    }

    // MARK: - 维护

    /// 清空两级缓存（设置页「清除图片缓存」用）。
    func clear() {
        memory.removeAllObjects()
        let target = directory
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            guard let files = try? manager.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: nil
            ) else { return }
            for file in files {
                try? manager.removeItem(at: file)
            }
        }
    }

    /// 磁盘缓存占用（字节）。
    func diskSizeInBytes() async -> Int {
        let target = directory
        return await Task.detached(priority: .utility) { () -> Int in
            let manager = FileManager.default
            guard let files = try? manager.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: [.fileSizeKey]
            ) else { return 0 }
            var total = 0
            for file in files {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += size
            }
            return total
        }.value
    }

    /// 删掉过期文件；总量仍然超限时按修改时间从旧到新继续删。
    private static func prune(directory: URL) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        let deadline = Date().addingTimeInterval(-maxAge)
        var survivors: [(url: URL, date: Date, size: Int)] = []
        var total = 0

        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            if date < deadline {
                try? manager.removeItem(at: file)
                continue
            }
            survivors.append((file, date, size))
            total += size
        }

        guard total > maxDiskBytes else { return }
        for entry in survivors.sorted(by: { $0.date < $1.date }) {
            guard total > maxDiskBytes else { break }
            try? manager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: - 文件名

    /// 用 URL 的 SHA256 做文件名：长度固定、不含路径分隔符，也避免中文/特殊字符。
    private static func fileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
