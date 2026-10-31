//
//  DownloadDirectoryStore.swift
//  Kazumi
//
//  下载目录：默认在应用内（Application Support/Kazumi/downloads），
//  用户可以选「文件」App 里的一个文件夹（或 iCloud 盘里的）当下载目录。
//
//  外部目录这次选择给的只是一个临时授权，App 一退出就没了，所以选完立刻
//  做一份安全作用域书签存起来，下次启动用书签换回访问权（原版
//  lib/services/download/download_directory_service.dart 也是这个办法）。
//  书签和路径都不进设置备份：那是这台设备的沙箱状态，拷到别的机器上无效。
//

import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class DownloadDirectoryStore {
    /// 与 main 的 settings 键同名（settings_keys.dart 里的 downloadDirectory /
    /// downloadDirectoryBookmark），这样两版的设置备份里这两个键的口径一致。
    private static let pathKey = "downloadDirectory"
    private static let bookmarkKey = "downloadDirectoryBookmark"

    private let defaults: UserDefaults
    /// 选过的目录路径。书签这次没解析成功时也留着，页面不会在启动那一瞬
    /// 闪回「应用内」；真正能不能写由 `hasAccess` 说了算。
    private(set) var savedPath: String
    /// 这次启动有没有真的拿到访问权。
    private(set) var hasAccess = false

    /// 解析成功的外部目录；访问结束时要在 deinit 之前 stop。
    private var scopedURL: URL?
    private var isAccessing = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.savedPath = defaults.string(forKey: Self.pathKey) ?? ""
        restoreAccess()
    }

    @MainActor
    deinit {
        // 访问权是常驻的（下载、写入都靠它），实例销毁时得放掉。
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: - 当前位置

    /// 现在真正会写进去的目录：外部目录拿到访问权就是它，否则回应用内。
    var directoryURL: URL {
        if let scopedURL { return scopedURL }
        return Self.defaultDirectory
    }

    /// 页面右侧那行字：选过就显示文件夹名，没选过或换不回访问权就是「应用内」。
    var displayName: String {
        guard !savedPath.isEmpty else { return "应用内" }
        let name = (savedPath as NSString).lastPathComponent
        if name.isEmpty { return savedPath }
        // 「文件」App 里那个以 App 命名的文件夹，在磁盘上叫 File Provider Storage。
        // 直接把系统内部名摆到设置行里，用户不知道那是什么（LP 5226 那一轮会问）。
        if name == "File Provider Storage" {
            return Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? "应用内"
        }
        return name
    }

    /// 选过一个外部目录（不管这次解析成功没有）。
    var hasCustomSelection: Bool { !savedPath.isEmpty }

    /// 选了目录、但这次没拿到访问权。
    ///
    /// 以前这种情况是静默的：`directoryURL` 悄悄回退到应用内目录，页面右侧还写着
    /// 用户选的那个文件夹名——看上去就是「自定义下载目录不好使」（LP 5218）。
    /// 现在把这个状态摆到页面上，不再默默写去别的地方。
    var customUnavailable: Bool { !savedPath.isEmpty && !hasAccess }

    /// 应用内目录。下载列表、播放器落盘都从这里取默认值。
    static var defaultDirectory: URL {
        AppEnvironment.storageRoot.appending(path: "downloads", directoryHint: .isDirectory)
    }

    // MARK: - 选目录

    /// 打开系统的文件夹选择器。选完存路径与书签；取消则什么都不改。
    func choose(completion: ((Result<Void, Error>) -> Void)? = nil) {
        DocumentPickerBridge.open(types: [.folder], asCopy: false) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    completion?(.failure(DocumentPickerBridge.PickerError.cancelled))
                    return
                }
                completion?(self.adopt(url))
            case .failure(let error):
                completion?(.failure(error))
            }
        }
    }

    /// 换回应用内目录，并把存下来的路径与书签一起清掉。
    func reset() {
        stopAccessing()
        savedPath = ""
        hasAccess = false
        defaults.removeObject(forKey: Self.pathKey)
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    /// 书签换回访问权。启动时跑一次；换不回来（文件夹被删、盘没挂）就
    /// 退回应用内并忘掉那条路径——留着一个写不进去的目录比退回更糟。
    func restoreAccess() {
        guard let raw = defaults.string(forKey: Self.bookmarkKey), !raw.isEmpty,
              let data = Data(base64Encoded: raw) else {
            if !savedPath.isEmpty { reset() }
            return
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            // iOS 上安全域是书签自带的，不能传 .withSecurityScope（那个选项 macOS 才有）。
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            log("下载目录：书签换不回地址，退回应用内")
            reset()
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            log("下载目录：书签解析到了但拿不到访问权，退回应用内")
            reset()
            return
        }
        stopAccessing()
        scopedURL = url
        isAccessing = true
        hasAccess = true
        savedPath = url.path(percentEncoded: false)
        defaults.set(savedPath, forKey: Self.pathKey)
        log("下载目录：书签已接回访问权 \(savedPath)")
        // 书签过期就趁这次有访问权重新做一份，下次启动还能用。
        if stale { persistBookmark(for: url) }
    }

    // MARK: - 内部

    private func adopt(_ url: URL) -> Result<Void, Error> {
        // 之前已经持有这个目录的访问权就别重复开：重复开又不关会漏。
        let alreadyOpen = isAccessing && scopedURL == url
        // 选择器给的是临时授权：先开，开完才能读书签、也才能判断真能不能写。
        // 成功时不当场放掉，由下面接管成常驻。
        let opened = alreadyOpen || url.startAccessingSecurityScopedResource()
        guard opened else {
            return .failure(DirectoryError.noAccess)
        }
        func bail(_ error: DirectoryError) -> Result<Void, Error> {
            if !alreadyOpen { url.stopAccessingSecurityScopedResource() }
            return .failure(error)
        }

        guard persistBookmark(for: url) else {
            return bail(.bookmarkFailed)
        }
        guard FileManager.default.isWritableFile(atPath: url.path(percentEncoded: false)) else {
            return bail(.notWritable)
        }

        // 访问权直接接管成常驻，不再「先放掉、再靠书签重开」：
        // 刚 stopAccessing 立刻 startAccessing 有拿不回来的情况，
        // 那时表现就是选了文件夹点打开、位置还停在应用内（LP 5218）。
        if !alreadyOpen {
            stopAccessing()
        }
        scopedURL = url
        isAccessing = true
        hasAccess = true
        savedPath = url.path(percentEncoded: false)
        defaults.set(savedPath, forKey: Self.pathKey)
        // 书签刚由选择器给的新地址生成，趁现在有访问权重做一份，下次冷启动能直接接上。
        persistBookmark(for: url)
        KazumiLogBuffer.storage("下载目录：已接管访问权 \(savedPath)")
        return .success(())
    }

    @discardableResult
    private func persistBookmark(for url: URL) -> Bool {
        // iOS 上从安全域 URL 生成的书签自带安全域，不用（也不能）加 .withSecurityScope。
        guard let data = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return false }
        defaults.set(data.base64EncodedString(), forKey: Self.bookmarkKey)
        return true
    }

    /// 写进「运行日志 → 存储」一栏：这条路径失败时 os.Logger 是看不见的，
    /// 而这正是用户能自己翻出来看的地方。
    private func log(_ message: String) {
        KazumiLog.storage.warning("\(message, privacy: .public)")
        KazumiLogBuffer.storage(message)
    }

    private func stopAccessing() {
        guard isAccessing, let scopedURL else { return }
        scopedURL.stopAccessingSecurityScopedResource()
        isAccessing = false
        self.scopedURL = nil
    }

    enum DirectoryError: LocalizedError {
        case noAccess
        case bookmarkFailed
        case notWritable

        var errorDescription: String? {
            switch self {
            case .noAccess: return "打不开这个文件夹"
            case .bookmarkFailed: return "记不住这个文件夹，换一个试试"
            case .notWritable: return "这个文件夹不能写，换一个试试"
            }
        }
    }
}
