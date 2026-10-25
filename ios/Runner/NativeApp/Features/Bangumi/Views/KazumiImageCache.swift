//
//  KazumiImageCache.swift
//  Kazumi
//
//  网络图片缓存，对应原版 lib/bean/card/network_img_layer.dart 依赖的
//  CachedNetworkImage（磁盘 + 内存两级缓存）：
//
//   * 磁盘层：按图片 URL 落盘，键就是那个地址，不掺别的；
//   * 内存层 NSCache：滚动时立刻拿到首帧，不出现「灰块 → 图片」的闪动；
//   * 解码按显示尺寸做（对应原版的 memCacheWidth / memCacheHeight）——
//     整张原图解码一张就几十 MB，一屏几十张会把内存缓存挤爆，刚存进去
//     的图立刻被淘汰，视图拿不到就永久停在占位图上；
//   * 同一个 URL 的并发请求合并成一次（single flight）；
//   * 失败不记账、不留状态：取不到就画占位，下次显示再取一次。
//
//  Swift 6 严格并发下 UIImage 不作为值跨隔离域传递：加载方法只负责把图片放进
//  NSCache 并返回是否成功，视图再用同步方法从缓存里取。
//

import CryptoKit
import Foundation
import ImageIO
import UIKit

/// 两级图片缓存。NSCache 本身线程安全，因此这个类型可以安全地被并发访问。
final class KazumiImageLoader: @unchecked Sendable {
    static let shared = KazumiImageLoader()

    /// 磁盘缓存保留天数，与原版 cached_network_image 的默认有效期一致。
    private static let maxAge: TimeInterval = 14 * 24 * 60 * 60
    /// 磁盘缓存上限（字节）。
    private static let maxDiskBytes = 300 * 1024 * 1024
    /// 没量到尺寸时按这个像素解码（约等于一张列表封面的两倍）。
    private static let defaultPixelSize = 600

    /// 屏幕倍率。`UIScreen.main` 只能在主线程读，而尺寸换算要在解码前后随时算，
    /// 所以启动时由 App 写一次进来。
    nonisolated(unsafe) static var screenScale: CGFloat = 3

    /// 内存里存图 + 它当时的解码档位。同一张图只留一份：预取按 600 解的那份
    /// 可以直接给 300 档的小卡片用，不会因为档位不同而互相看不到。
    private final class Entry {
        let image: UIImage
        let bucket: Int
        init(image: UIImage, bucket: Int) {
            self.image = image
            self.bucket = bucket
        }
    }

    private let memory = NSCache<NSString, Entry>()
    private let lock = NSLock()
    private var inFlight: [String: Task<Void, Never>] = [:]
    private let directory: URL
    private let session: URLSession


    private init() {
        // 首选 App 启动时已经建好的存储根（Application Support/Kazumi/images），
        // 它比这里自己拼路径更可靠；其余几个位置按顺序兜底。
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let candidates: [(String, URL?)] = [
            ("准备好的目录", support?.appendingPathComponent("Kazumi/images", isDirectory: true)),
            ("Application Support", support?.appendingPathComponent("Kazumi/Images", isDirectory: true)),
            ("Caches", caches?.appendingPathComponent("Kazumi/Images", isDirectory: true)),
            ("Documents", documents?.appendingPathComponent("Kazumi/Images", isDirectory: true)),
            ("临时目录", URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("KazumiImages", isDirectory: true)),
        ]
        // 逐个试写，用第一个真能写的位置：Application Support 下的子目录
        // 在某些容器里建不出来（大小写不同的同名目录冲突），写盘会一直失败。
        var chosen: URL?
        for (_, target) in candidates {
            guard let target else { continue }
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let probe = target.appendingPathComponent(".probe")
                try Data([0x01]).write(to: probe)
                try? FileManager.default.removeItem(at: probe)
                chosen = target
                break
            } catch {
                continue
            }
        }
        directory = chosen ?? URL(fileURLWithPath: NSTemporaryDirectory())

        memory.countLimit = 600
        // 按显示尺寸解码之后，一张列表封面在内存里只有几百 KB，128 MB 足够
        // 装下整屏加上前后几屏，滚动回来不必重新解码。
        memory.totalCostLimit = 128 * 1024 * 1024

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        // 除了自己按 URL 落盘，再叠一层 HTTP 缓存。
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

    // MARK: - 尺寸

    /// 把视图尺寸换算成解码像素：按屏幕倍率放大，夹在 120…1600 之间。
    static func pixelSize(for size: CGSize) -> Int {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return defaultPixelSize }
        let pixels = Int((longest * screenScale).rounded(.up))
        return min(max(pixels, 120), 1600)
    }

    /// 解码档位：同一张图在小卡片和大封面上分别解一份，按 100 像素归档。
    private static func bucket(_ pixelSize: Int) -> Int {
        max(120, (pixelSize / 100) * 100)
    }

    private static func memoryKey(_ key: String, bucket: Int) -> String {
        "\(key)#\(bucket)"
    }

    /// 够用的档位：命中比需要的略小一档（差 100 像素以内）也认，避免
    /// 300 档的图服务不了 400 档的视图、白解一次。
    private static func satisfies(_ entry: Entry, bucket: Int) -> Bool {
        entry.bucket + 100 >= bucket
    }

    // MARK: - 同步读内存

    /// 已解码好的图片，命中时视图可以直接当首帧画出来。
    func cachedImage(for url: String, pixelSize: Int) -> UIImage? {
        let key = Self.cacheKey(for: url)
        guard !key.isEmpty else { return nil }
        let bucket = Self.bucket(pixelSize)
        let exact = memory.object(forKey: Self.memoryKey(key, bucket: bucket) as NSString)
        if let exact { return exact.image }
        // 档位不同：看看有没有更大的一份，或者略小一点还能用的。
        for candidate in stride(from: bucket + 100, through: bucket + 400, by: 100) {
            if let entry = memory.object(forKey: Self.memoryKey(key, bucket: candidate) as NSString) {
                return entry.image
            }
        }
        for candidate in stride(from: bucket - 100, through: max(100, bucket - 300), by: -100) {
            if let entry = memory.object(forKey: Self.memoryKey(key, bucket: candidate) as NSString),
               Self.satisfies(entry, bucket: bucket) {
                return entry.image
            }
        }
        return nil
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
    /// 同一个地址上已经在跑的请求会被复用；调用方（视图的 `.task`）被取消时
    /// 不会连带取消下载 —— 图还是要落盘，下次滚动回来才能直接命中。
    @discardableResult
    func load(_ url: String, pixelSize: Int = defaultPixelSize) async -> Bool {
        let key = Self.cacheKey(for: url)
        guard !key.isEmpty else { return false }
        let bucket = Self.bucket(pixelSize)
        if cachedImage(for: url, pixelSize: pixelSize) != nil { return true }

        let task: Task<Void, Never> = lock.withLock {
            if let existing = inFlight[key] { return existing }
            let created = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.fetch(key: key, bucket: bucket)
            }
            inFlight[key] = created
            return created
        }
        await task.value
        if cachedImage(for: url, pixelSize: pixelSize) != nil { return true }
        // 那个任务按别的档位解的（例如预取用的是 600，这张要 800）：再解一次。
        await fetch(key: key, bucket: bucket)
        return cachedImage(for: url, pixelSize: pixelSize) != nil
    }

    /// 预取：给列表里即将出现的图片预热缓存，不阻塞调用方。
    func prefetch(_ urls: [String], pixelSize: Int = defaultPixelSize) {
        for url in urls {
            let key = Self.cacheKey(for: url)
            guard !key.isEmpty else { continue }
            guard cachedImage(for: url, pixelSize: pixelSize) == nil else { continue }
            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.load(url, pixelSize: pixelSize)
            }
        }
    }

    private func fetch(key: String, bucket: Int) async {
        defer {
            lock.withLock { _ = inFlight.removeValue(forKey: key) }
        }

        let fileURL = directory.appendingPathComponent(Self.fileName(for: key))

        // 1. 磁盘：命中的是原图字节，再按当前显示尺寸解码。
        if let data = try? Data(contentsOf: fileURL) {
            if let image = await Self.decode(data, pixelSize: bucket) {
                store(image, key: key, bucket: bucket)
                return
            }
            // 文件坏了就删掉，别一直拿它解码失败。
            try? FileManager.default.removeItem(at: fileURL)
        }

        // 2. 网络
        guard let logical = URL(string: key) else { return }
        let remote = BangumiImageRewriter.rewritten(logical)

        // 取图失败重试一次：列表一屏几十张图同时开连，单张偶发失败很正常。
        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(from: remote)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    return
                }
                guard let image = await Self.decode(data, pixelSize: bucket) else {
                    return
                }
                store(image, key: key, bucket: bucket)
                do {
                    try ensureDirectory()
                    try data.write(to: fileURL, options: .atomic)
                } catch {
                    // 写盘失败不影响这次显示，下次再取。
                }
                return
            } catch {
                guard attempt == 0 else { return }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func store(_ image: UIImage, key: String, bucket: Int) {
        let scale = image.scale
        let cost = Int(image.size.width * image.size.height * scale * scale * 4)
        memory.setObject(Entry(image: image, bucket: bucket), forKey: Self.memoryKey(key, bucket: bucket) as NSString, cost: cost)
    }

    /// 按显示尺寸解码（对应原版的 memCacheWidth / memCacheHeight）：
    /// 只解出这么大的位图，内存和耗时都小一个数量级。
    ///
    /// 用 ImageIO 直接出缩略图，而不是先 UIImage(data:) 再缩 —— 后者要先把整张
    /// 原图解码出来，正是「一屏几十张就把内存挤爆」的来源。
    private static func decode(_ data: Data, pixelSize: Int) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> DecodeResult in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return DecodeResult(image: nil)
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(64, pixelSize),
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return DecodeResult(image: UIImage(cgImage: cgImage))
            }
            if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return DecodeResult(image: UIImage(cgImage: cgImage))
            }
            return DecodeResult(image: nil)
        }.value.image
    }

    /// 解码结果。UIImage 不是 Sendable，用一个带 @unchecked 的盒子从后台线程带回来。
    private struct DecodeResult: @unchecked Sendable {
        var image: UIImage?
    }

    // MARK: - 诊断

    /// 缓存目录可能在初始化时没建成（或事后被系统清理），写盘前再确认一次。
    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
                total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
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
