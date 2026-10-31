//
//  DownloadDirectoryStore.swift
//  Kazumi
//
//  下载目录：默认在应用内（Documents/Download），
//  用户可以选「文件」App 里的一个文件夹（或 iCloud 盘里的）当下载目录。
//
//  外部目录这次选择给的只是一个临时授权，App 一退出就没了，所以选完立刻
//  做一份安全作用域书签存起来，下次启动用书签换回访问权（原版
//  lib/services/download/download_directory_service.dart 也是这个办法）。
//  书签和路径都不进设置备份：那是这台设备的沙箱状态，拷到别的机器上无效。
//
//  默认目录为什么在 Documents 而不是 Application Support：「文件」App 只能看见
//  Documents，「我的 iPhone」里才会出现以 App 命名的那个文件夹，下完的东西用户
//  才拿得到（LP 5262）。Application Support 下的目录它永远看不见。
//  老版本下在 Application Support，启动时把那里整个搬过来（见 `migrateLegacyDirectories`）。
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
    /// 老目录已经搬过了。只搬一次：搬完会把老目录删掉，第二次再搬也没东西了。
    private static let migratedKey = "downloadDirectoryMigratedToDocuments"

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
        // 必须在 DownloadCenter 读记录之前跑：记录里的文件名是相对下载目录的，
        // 目录还没搬就校验文件，会把好端端的下载全判成「文件不在」。
        migrateLegacyDirectories(defaults: defaults)
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
    ///
    /// 固定在 Documents/Download：「文件」App 只能看见 Documents，
    /// 下完的东西要在「我的 iPhone」里拿得到（LP 5262）。
    static var defaultDirectory: URL { AppEnvironment.downloadRoot }

    /// 把老目录里的下载整个搬进现在的下载目录，只搬一次。
    ///
    /// 只改默认目录不会搬文件——文件留在 Application Support 里，「文件」App
    /// 看不见，下载管理页还按记录算它已下完：勾还在、点进去放不了、想重下又被
    /// 同一个判据挡住（Fuck 5263）。所以这里搬一次。
    ///
    /// 搬手的外部目录（以前自己选过的那个）也一并并进来，并进完才丢掉那个选择：
    /// 留着一个指向已经搬空的文件夹的选择，只会让页面右边写着一个不存在的目录。
    /// 一件搬不动就整轮不算成功，老文件原样留着，下次启动再试。
    private func migrateLegacyDirectories(defaults: UserDefaults) {
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        let target = Self.defaultDirectory
        let legacy = [AppEnvironment.legacyDownloadRoot]
            + (savedPath.isEmpty ? [] : [URL(fileURLWithPath: savedPath)])
        var movedAny = false
        var failed = false
        for source in legacy {
            guard !source.path.isEmpty,
                  source.path != target.path,
                  FileManager.default.fileExists(atPath: source.path)
            else { continue }
            do {
                try Self.merge(source: source, into: target)
                movedAny = true
                KazumiLogBuffer.storage(
                    "下载目录：已把 \(source.lastPathComponent) 搬进 \(target.lastPathComponent)"
                )
            } catch {
                failed = true
                KazumiLogBuffer.storage(
                    "下载目录：\(source.lastPathComponent) 搬不动：\(error.localizedDescription)"
                )
            }
        }
        guard !failed else { return }
        defaults.set(true, forKey: Self.migratedKey)
        if movedAny && !savedPath.isEmpty {
            reset()
        }
    }

    /// 把 source 整个并进 target；target 里已有的同名项跳过。搬不动就抛，由调用方当失败处理。
    private static func merge(source: URL, into target: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        guard let items = try? fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        ) else { return }
        for item in items {
            let destination = target.appendingPathComponent(item.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.moveItem(at: item, to: destination)
        }
        // 源目录空了就删掉；还有东西就留着，下次启动再搬。
        try? fileManager.removeItem(at: source)
    }

    // MARK: - 选目录

    /// 打开系统的文件夹选择器。选完存路径与书签；取消则什么都不改。
    func choose(completion: ((Result<Void, Error>) -> Void)? = nil) {
        // 面板的起点：App 自己的「文稿」目录（在「文件」App 里就是「我的 iPhone > Kazumi」）。
        // 不给起点就会落在空的「Recents」，那里的「打开」是灰的，点了没反应。
        let start = (try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ))
        DocumentPickerBridge.open(types: [.folder], asCopy: false, startingDirectory: start) { [weak self] result in
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
        KazumiLogBuffer.storage("下载目录：拿到临时授权=\(opened)，路径 \(url.path(percentEncoded: false))")
        guard opened else {
            return .failure(DirectoryError.noAccess)
        }
        func bail(_ error: DirectoryError) -> Result<Void, Error> {
            if !alreadyOpen { url.stopAccessingSecurityScopedResource() }
            return .failure(error)
        }

        let bookmarked = persistBookmark(for: url)
        KazumiLogBuffer.storage("下载目录：书签=\(bookmarked ? "成" : "败")")
        guard bookmarked else {
            return bail(.bookmarkFailed)
        }
        let writable = FileManager.default.isWritableFile(atPath: url.path(percentEncoded: false))
        KazumiLogBuffer.storage("下载目录：可写=\(writable ? "是" : "否")")
        guard writable else {
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
