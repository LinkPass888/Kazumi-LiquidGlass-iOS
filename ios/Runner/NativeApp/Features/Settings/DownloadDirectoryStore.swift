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
        return name.isEmpty ? savedPath : name
    }

    /// 选过一个外部目录（不管这次解析成功没有）。
    var hasCustomSelection: Bool { !savedPath.isEmpty }

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
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            KazumiLog.storage.warning("下载目录：书签换不回地址，退回应用内")
            reset()
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            KazumiLog.storage.warning("下载目录：书签解析到了但拿不到访问权，退回应用内")
            reset()
            return
        }
        stopAccessing()
        scopedURL = url
        isAccessing = true
        hasAccess = true
        savedPath = url.path(percentEncoded: false)
        defaults.set(savedPath, forKey: Self.pathKey)
        // 书签过期就趁这次有访问权重新做一份，下次启动还能用。
        if stale { persistBookmark(for: url) }
    }

    // MARK: - 内部

    private func adopt(_ url: URL) -> Result<Void, Error> {
        // 选择器给的是临时授权：先开，开完才能读书签、也才能判断真能不能写。
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }

        guard opened else {
            return .failure(DirectoryError.noAccess)
        }
        guard persistBookmark(for: url) else {
            return .failure(DirectoryError.bookmarkFailed)
        }
        guard FileManager.default.isWritableFile(atPath: url.path(percentEncoded: false)) else {
            return .failure(DirectoryError.notWritable)
        }
        stopAccessing()
        savedPath = url.path(percentEncoded: false)
        defaults.set(savedPath, forKey: Self.pathKey)
        // 书签已经存好：从现在起走 restoreAccess 那条路拿常驻访问权。
        restoreAccess()
        return .success(())
    }

    @discardableResult
    private func persistBookmark(for url: URL) -> Bool {
        guard let data = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return false }
        defaults.set(data.base64EncodedString(), forKey: Self.bookmarkKey)
        return true
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
