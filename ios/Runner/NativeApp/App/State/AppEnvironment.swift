//
//  AppEnvironment.swift
//  Kazumi
//
//  应用级依赖装配点（对应原项目的 coreModule）。
//  采用「组合根」模式：所有单例在这里创建，通过 Environment 注入到视图层，
//  Step 2~4 的模块只需要在这里多加一行，视图代码无需感知具体实现。
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppEnvironment {
    struct StartupFailure: Identifiable, Sendable {
        let id = UUID()
        let message: String
    }

    struct LaunchResult {
        let environment: AppEnvironment
        let failure: StartupFailure?
    }

    /// 应用根依赖（与原 coreModule 的单例注册一一对应）。
    let settings: SettingsStore
    /// 下载目录：设置页选的文件夹、播放器落盘、下载列表三处共用一份，
    /// 「落在哪儿」才不会一处一套。
    let downloadDirectory: DownloadDirectoryStore
    let library: LibraryStore
    let router: AppRouter
    let plugins: PluginsController
    let pluginSearch: PluginSearchService
    let updates: AppUpdateService
    /// 追番同步引擎：设置页、详情页与播放器共用一份，三处对「连没连上」才一致。
    let bangumiSync: BangumiSyncEngine
    /// 「自动标记看过」的消费端，播放器把进度喂给它。
    let bangumiProgress: BangumiProgressService
    /// 离线缓存：解析、排队、落盘、记录一份，播放页与下载页共用。
    @MainActor let downloads: DownloadCenter

    private init(settings: SettingsStore, library: LibraryStore, router: AppRouter) {
        self.settings = settings
        let downloadDirectory = DownloadDirectoryStore(defaults: .standard)
        self.downloadDirectory = downloadDirectory
        self.library = library
        self.router = router
        let plugins = PluginsController()
        plugins.load()
        self.plugins = plugins
        self.pluginSearch = PluginSearchService(plugins: plugins)
        self.updates = AppUpdateService()
        self.bangumiSync = BangumiSyncEngine(settings: settings, library: library)
        self.bangumiProgress = BangumiProgressService(settings: settings)
        // 用局部变量传参：闭包里读 self 的成员会被判成「初始化完成前捕获 self」。
        let store = downloadDirectory
        self.downloads = MainActor.assumeIsolated {
            DownloadCenter(directory: store, plugins: plugins, settings: settings)
        }
    }

    /// 与原 main.dart 一致：先确保存储目录可用，失败时返回错误页而不是崩溃。
    static func makeAtLaunch() -> LaunchResult {
        do {
            try AppEnvironment.prepareStorageDirectories()
            let settings = SettingsStore()
            let library = LibraryStore()
            library.load()
            let router = AppRouter(defaultStartupPage: settings.defaultStartupPage)
            let environment = AppEnvironment(settings: settings, library: library, router: router)
            return LaunchResult(environment: environment, failure: nil)
        } catch {
            KazumiLog.storage.error("存储初始化失败：\(error.localizedDescription, privacy: .public)")
            // 仍然构造一个可用的内存环境，保证错误页能正常渲染。
            let environment = AppEnvironment(
                settings: SettingsStore(defaults: UserDefaults(suiteName: "kazumi.ephemeral") ?? .standard),
                library: LibraryStore(),
                router: AppRouter()
            )
            return LaunchResult(
                environment: environment,
                failure: StartupFailure(message: error.localizedDescription)
            )
        }
    }

    /// Application Support/hive 对应原工程的存储根目录；原生版改为 Application Support/Kazumi。
    static func prepareStorageDirectories() throws {
        // 图片解码要按屏幕倍率算目标像素，而 UIScreen 只能在主线程读：启动时写一次。
        KazumiImageLoader.screenScale = UIScreen.main.scale
        let manager = FileManager.default
        let support = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appending(path: "Kazumi", directoryHint: .isDirectory)
        let directories = [
            root,
            root.appending(path: "rules", directoryHint: .isDirectory),
            root.appending(path: "cache", directoryHint: .isDirectory),
            root.appending(path: "images", directoryHint: .isDirectory),
            root.appending(path: "snapshots", directoryHint: .isDirectory),
            root.appending(path: "downloads", directoryHint: .isDirectory),
        ]
        for directory in directories where !manager.fileExists(atPath: directory.path(percentEncoded: false)) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// 重排番剧更新提醒（设置页改开关、追番列表变动、启动时都走这里）。
    ///
    /// 关掉时只清空已排定的，不再排新的；开着时先把「在看」那些番的放送
    /// 时刻补上（季度数据没加载过就没有时刻可算），再交给排定器。
    func refreshUpdateNotifications() async {
        guard settings.updateNotificationEnabled else {
            await UpdateNotificationScheduler.shared.cancelAll()
            return
        }
        let watching = library.entries.filter { $0.collectType == .watching }
        guard !watching.isEmpty else {
            await UpdateNotificationScheduler.shared.cancelAll()
            return
        }
        for entry in watching {
            await BangumiAirTimeService.shared.ensureLoaded(
                subjectID: entry.id,
                airDate: entry.airDate
            )
        }
        await UpdateNotificationScheduler.shared.reschedule(watching: watching)
    }

    /// 存储根目录（Step 3 的 JSON 存储与 WebDAV 备份都基于它）。
    static var storageRoot: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL.temporaryDirectory
        return support.appending(path: "Kazumi", directoryHint: .isDirectory)
    }

    /// 图片缓存目录。
    static var imageCacheRoot: URL {
        storageRoot.appending(path: "images", directoryHint: .isDirectory)
    }

    /// 规则目录（内置规则与订阅规则）。
    static var rulesRoot: URL {
        storageRoot.appending(path: "rules", directoryHint: .isDirectory)
    }

    /// 检查剩余空间（对应原 iOS 通道的 getAvailableStorage）。
    static func availableDiskSpace() -> Int64 {
        let values = try? storageRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? -1
    }
}
