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
    let library: LibraryStore
    let router: AppRouter
    let plugins: PluginsController
    let pluginSearch: PluginSearchService

    private init(settings: SettingsStore, library: LibraryStore, router: AppRouter) {
        self.settings = settings
        self.library = library
        self.router = router
        let plugins = PluginsController()
        plugins.load()
        self.plugins = plugins
        self.pluginSearch = PluginSearchService(plugins: plugins)
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
        ]
        for directory in directories where !manager.fileExists(atPath: directory.path(percentEncoded: false)) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
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
