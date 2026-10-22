//
//  SettingsStore.swift
//  Kazumi
//
//  设置项的持久化容器（替代 Hive 中的 settings box）。
//  存储实现只依赖 UserDefaults，Step 3 会用同一套 API 把 WebDAV 备份的
//  `settings` 段落写回这里，因此键名刻意与原版保持一致。
//

import CoreFoundation
import Foundation
import Observation
import SwiftUI

/// 主题模式（对照 bean/settings/theme_provider.dart 的 ThemeMode）。
enum KazumiThemeMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// 超分辨率档位。数值与 lib/pages/player/controller/player_super_resolution.dart
/// 的 storageValue 对齐（1=关闭，2=效率档，3=质量档），便于设置备份互通。
///
/// 原版在 mpv 上加载 Anime4K 的 GLSL 着色器；KSPlayer 走 FFmpeg，无法直接吃
/// mpv 着色器，这里用等效的 FFmpeg 滤镜链（lanczos 放大 + 锐化）实现同一档位：
/// 效率档 1.5×，质量档 2×。滤镜只在 KSPlayer 的 FFmpeg 内核下生效。
enum SuperResolutionMode: Int, CaseIterable, Identifiable, Sendable {
    case off = 1
    case efficiency = 2
    case quality = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: "关闭"
        case .efficiency: "效率档"
        case .quality: "质量档"
        }
    }

    var detail: String {
        switch self {
        case .off: "默认禁用超分辨率"
        case .efficiency: "基于 Anime4K 的超分辨率（效率优先）"
        case .quality: "基于 Anime4K 的超分辨率（质量优先）"
        }
    }

    /// 交给 KSOptions.videoFilters 的 FFmpeg 滤镜链。
    ///
    /// 放大用 lanczos（质量优于默认 bicubic），锐化用 unsharp 找回线条；
    /// 关闭时返回空数组，不改变原始管线。
    var videoFilters: [String] {
        switch self {
        case .off:
            return []
        case .efficiency:
            return [
                "scale=iw*1.5:ih*1.5:flags=lanczos",
                "unsharp=5:5:0.6:5:5:0.0",
            ]
        case .quality:
            return [
                "scale=iw*2:ih*2:flags=lanczos",
                "unsharp=5:5:0.9:5:5:0.0",
            ]
        }
    }
}

/// 设置键。命名沿用原项目 setting keys 的语义，便于备份文件互通。
enum SettingsKey {
    /// 设置键在 UserDefaults 里的统一前缀。
    ///
    /// 放在这个非隔离的枚举里：设置备份扩展与静态工具方法都要在
    /// `SettingsStore`（`@MainActor`）之外读取它，避免 Swift 6
    /// 严格并发下的 actor 隔离报错。
    static let keyPrefix = "kazumi.settings."
    static let themeMode = "themeMode"
    static let colorType = "colorType"
    /// 配色方案标识，沿用原版 `SettingsKeys.themeColor` 的键名。
    static let themeColor = "themeColor"
    /// OLED 纯黑，沿用原版 `SettingsKeys.oledEnhance` 的键名。
    static let oledEnhance = "oledEnhance"
    static let glassEnabled = "glassEnabled"
    static let selectedPluginIndex = "selectedPluginIndex"
    static let playerQuality = "playerQuality"
    static let hardwareDecoder = "hardwareDecoder"
    static let anime4kMode = "anime4kMode"
    static let autoPlayNext = "autoPlayNext"
    static let autoSkipOpEd = "autoSkipOpEd"
    static let playSpeed = "playSpeed"
    static let danmakuEnabled = "danmakuEnabled"
    static let danmakuOpacity = "danmakuOpacity"
    static let danmakuFontSize = "danmakuFontSize"
    static let danmakuArea = "danmakuArea"
    static let danmakuFilterRules = "danmakuFilterRules"
    static let danmakuSourcePriority = "danmakuSourcePriority"
    static let webDAVURL = "webDAVURL"
    static let webDAVUser = "webDAVUser"
    static let webDAVPassword = "webDAVPassword"
    static let webDAVAutoSync = "webDAVAutoSync"
    static let bangumiAccessToken = "bangumiAccessToken"
    static let bangumiUsername = "bangumiUsername"
    static let bangumiSyncEnabled = "bangumiSyncEnabled"
    static let danmakuShieldSyncEnabled = "danmakuShieldSyncEnabled"
    static let proxyEnabled = "proxyEnabled"
    static let proxyHost = "proxyHost"
    static let proxyPort = "proxyPort"
    static let meteredNetworkLimit = "meteredNetworkLimit"
    static let updateNotificationEnabled = "updateNotificationEnabled"
    static let playerEntryFullscreen = "playerEntryFullscreen"
    /// 下载并发数，沿用原版 `SettingsKeys.downloadParallelEpisodes` 的键名。
    static let downloadParallelEpisodes = "downloadParallelEpisodes"
    /// 是否随下载一起缓存弹幕，沿用原版 `SettingsKeys.downloadDanmaku` 的键名。
    static let downloadDanmaku = "downloadDanmaku"
    /// 启动页，沿用原版 `SettingsKeys.defaultStartupPage` 的键名。
    static let defaultStartupPage = "defaultStartupPage"
    /// Bangumi 加速（镜像）开关，沿用原版 `SettingsKeys.enableBangumiProxy` 的键名。
    static let enableBangumiProxy = "enableBangumiProxy"
    /// 启动时检查应用更新，沿用原版 `SettingsKeys.autoUpdate` 的键名。
    static let autoUpdate = "autoUpdate"
    /// 启动时检查规则更新，沿用原版 `checkPluginUpdateOnStartup` 的键名。
    static let checkPluginUpdateOnStartup = "checkPluginUpdateOnStartup"
}

/// 可观察的设置存储。所有写入立即同步到磁盘，避免进程被系统回收后丢设置。
@MainActor
@Observable
final class SettingsStore {
    // 键名前缀统一由非隔离的 `SettingsKey.keyPrefix` 提供（备份扩展也读它）。
    // 这里不再包一层嵌套类型或 `@MainActor` 静态属性：`@MainActor` 类型里的
    // 静态属性受 actor 隔离，经由非隔离上下文（如嵌套类型初始化器）读取会触发
    // Swift 6 的「main actor-isolated default value in a nonisolated context」编译错误。
    private let defaults: UserDefaults

    var themeMode: KazumiThemeMode {
        didSet {
            persist(themeMode.rawValue, SettingsKey.themeMode)
            syncAppearance()
        }
    }

    /// 选中的配色方案（对应原版 `themeColor` 设置，默认绿色）。
    var themeColor: KazumiThemeColor {
        didSet {
            persist(themeColor.id, SettingsKey.themeColor)
            KazumiThemeColor.current = themeColor
        }
    }

    /// 深色模式是否使用纯黑背景（对应原版 `oledEnhance`）。
    var oledEnhance: Bool {
        didSet {
            persist(oledEnhance, SettingsKey.oledEnhance)
            KazumiThemeColor.oledEnhance = oledEnhance
        }
    }

    /// 是否启用 iOS 26 液态玻璃（对应 KazumiGlass.enabled）。
    var glassEnabled: Bool {
        didSet { persist(glassEnabled, SettingsKey.glassEnabled) }
    }

    /// 当前选中的规则源下标（对应 PluginsController.currentPlugin）。
    var selectedPluginIndex: Int {
        didSet { persist(selectedPluginIndex, SettingsKey.selectedPluginIndex) }
    }

    /// 是否在播放器进入时即全屏。
    var playerEntryFullscreen: Bool {
        didSet { persist(playerEntryFullscreen, SettingsKey.playerEntryFullscreen) }
    }

    /// 默认超分辨率档位（对应原版 `defaultSuperResolutionMode`，沿用 `anime4kMode` 键名）。
    var superResolutionMode: SuperResolutionMode {
        didSet { persist(superResolutionMode.rawValue, SettingsKey.anime4kMode) }
    }

    var danmakuEnabled: Bool {
        didSet { persist(danmakuEnabled, SettingsKey.danmakuEnabled) }
    }

    var danmakuOpacity: Double {
        didSet { persist(danmakuOpacity, SettingsKey.danmakuOpacity) }
    }

    var danmakuFontSize: Double {
        didSet { persist(danmakuFontSize, SettingsKey.danmakuFontSize) }
    }

    /// 弹幕显示区域（0.25 ~ 1.0 的屏幕高度占比）。
    var danmakuArea: Double {
        didSet { persist(danmakuArea, SettingsKey.danmakuArea) }
    }

    var autoPlayNext: Bool {
        didSet { persist(autoPlayNext, SettingsKey.autoPlayNext) }
    }

    var autoSkipOpEd: Bool {
        didSet { persist(autoSkipOpEd, SettingsKey.autoSkipOpEd) }
    }

    var playSpeed: Double {
        didSet { persist(playSpeed, SettingsKey.playSpeed) }
    }

    var bangumiSyncEnabled: Bool {
        didSet { persist(bangumiSyncEnabled, SettingsKey.bangumiSyncEnabled) }
    }

    var danmakuShieldSyncEnabled: Bool {
        didSet { persist(danmakuShieldSyncEnabled, SettingsKey.danmakuShieldSyncEnabled) }
    }

    var bangumiAccessToken: String {
        didSet { persist(bangumiAccessToken, SettingsKey.bangumiAccessToken) }
    }

    var bangumiUsername: String {
        didSet { persist(bangumiUsername, SettingsKey.bangumiUsername) }
    }

    var webDAVURL: String {
        didSet { persist(webDAVURL, SettingsKey.webDAVURL) }
    }

    var webDAVUser: String {
        didSet { persist(webDAVUser, SettingsKey.webDAVUser) }
    }

    var webDAVPassword: String {
        didSet { persist(webDAVPassword, SettingsKey.webDAVPassword) }
    }

    var webDAVAutoSync: Bool {
        didSet { persist(webDAVAutoSync, SettingsKey.webDAVAutoSync) }
    }

    var proxyEnabled: Bool {
        didSet { persist(proxyEnabled, SettingsKey.proxyEnabled) }
    }

    var proxyHost: String {
        didSet { persist(proxyHost, SettingsKey.proxyHost) }
    }

    var proxyPort: Int {
        didSet { persist(proxyPort, SettingsKey.proxyPort) }
    }

    var meteredNetworkLimit: Bool {
        didSet { persist(meteredNetworkLimit, SettingsKey.meteredNetworkLimit) }
    }

    var updateNotificationEnabled: Bool {
        didSet { persist(updateNotificationEnabled, SettingsKey.updateNotificationEnabled) }
    }

    /// 下载并发数（对应原版 `downloadParallelEpisodes`）。
    var downloadParallelEpisodes: Int {
        didSet { persist(downloadParallelEpisodes, SettingsKey.downloadParallelEpisodes) }
    }

    /// 是否随下载一起缓存弹幕（对应原版 `downloadDanmaku`）。
    var downloadDanmaku: Bool {
        didSet { persist(downloadDanmaku, SettingsKey.downloadDanmaku) }
    }

    /// 启动页（对应原版 `defaultStartupPage`，存的是页面路径）。
    var defaultStartupPage: String {
        didSet { persist(defaultStartupPage, SettingsKey.defaultStartupPage) }
    }

    /// 是否走 Bangumi 镜像加速（对应原版 `enableBangumiProxy`）。
    var enableBangumiProxy: Bool {
        didSet {
            persist(enableBangumiProxy, SettingsKey.enableBangumiProxy)
            BangumiAcceleration.mode = enableBangumiProxy ? .mirror : .direct
        }
    }

    /// 启动时检查应用更新（对应原版 `autoUpdate`，默认开启）。
    var autoUpdateCheck: Bool {
        didSet { persist(autoUpdateCheck, SettingsKey.autoUpdate) }
    }

    /// 启动时检查规则更新（对应原版 `checkPluginUpdateOnStartup`，默认开启）。
    var checkPluginUpdateOnStartup: Bool {
        didSet { persist(checkPluginUpdateOnStartup, SettingsKey.checkPluginUpdateOnStartup) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        themeMode = Self.read(defaults, SettingsKey.themeMode, KazumiThemeMode.system)
        // 原版把 'default' 视为绿色；这里额外兼容旧备份里可能出现的 ARGB 字符串。
        let storedThemeColor = defaults.object(forKey: SettingsKey.keyPrefix + SettingsKey.themeColor) as? String
        let resolvedThemeColor = KazumiThemeColor.named(storedThemeColor ?? KazumiThemeColor.standard.id)
        themeColor = resolvedThemeColor
        // 静态成员不能经由 `self` 读取（等价于访问未初始化完成的实例），
        // 因此局部变量承载读取结果，等构造结束再同步到全局调色板。
        let resolvedOLEDEnhance = Self.read(defaults, SettingsKey.oledEnhance, false)
        let resolvedGlassEnabled = Self.read(defaults, SettingsKey.glassEnabled, true)
        oledEnhance = resolvedOLEDEnhance
        glassEnabled = resolvedGlassEnabled
        // 在全部存储属性初始化完成后再同步全局调色板，避免 'self' 提前访问。
        KazumiThemeColor.current = resolvedThemeColor
        KazumiThemeColor.oledEnhance = resolvedOLEDEnhance
        // 应用主题的明暗要同步给调色板：强调色按它取 T40 / T80 那一档，
        // 不跟随窗口 trait（见 KazumiThemeColor.darkAppearanceOverride）。
        KazumiThemeColor.darkAppearanceOverride = Self.darkAppearance(for: themeMode)
        selectedPluginIndex = Self.read(defaults, SettingsKey.selectedPluginIndex, 0)
        playerEntryFullscreen = Self.read(defaults, SettingsKey.playerEntryFullscreen, true)
        superResolutionMode = SuperResolutionMode(
            rawValue: Self.read(defaults, SettingsKey.anime4kMode, 1)
        ) ?? .off
        danmakuEnabled = Self.read(defaults, SettingsKey.danmakuEnabled, true)
        danmakuOpacity = Self.read(defaults, SettingsKey.danmakuOpacity, 1.0)
        danmakuFontSize = Self.read(defaults, SettingsKey.danmakuFontSize, 20.0)
        danmakuArea = Self.read(defaults, SettingsKey.danmakuArea, 0.5)
        autoPlayNext = Self.read(defaults, SettingsKey.autoPlayNext, true)
        autoSkipOpEd = Self.read(defaults, SettingsKey.autoSkipOpEd, false)
        playSpeed = Self.read(defaults, SettingsKey.playSpeed, 1.0)
        bangumiSyncEnabled = Self.read(defaults, SettingsKey.bangumiSyncEnabled, false)
        danmakuShieldSyncEnabled = Self.read(defaults, SettingsKey.danmakuShieldSyncEnabled, false)
        bangumiAccessToken = Self.read(defaults, SettingsKey.bangumiAccessToken, "")
        bangumiUsername = Self.read(defaults, SettingsKey.bangumiUsername, "")
        webDAVURL = Self.read(defaults, SettingsKey.webDAVURL, "")
        webDAVUser = Self.read(defaults, SettingsKey.webDAVUser, "")
        webDAVPassword = Self.read(defaults, SettingsKey.webDAVPassword, "")
        webDAVAutoSync = Self.read(defaults, SettingsKey.webDAVAutoSync, false)
        proxyEnabled = Self.read(defaults, SettingsKey.proxyEnabled, false)
        proxyHost = Self.read(defaults, SettingsKey.proxyHost, "")
        proxyPort = Self.read(defaults, SettingsKey.proxyPort, 0)
        meteredNetworkLimit = Self.read(defaults, SettingsKey.meteredNetworkLimit, false)
        updateNotificationEnabled = Self.read(defaults, SettingsKey.updateNotificationEnabled, true)
        downloadParallelEpisodes = Self.read(defaults, SettingsKey.downloadParallelEpisodes, 2)
        downloadDanmaku = Self.read(defaults, SettingsKey.downloadDanmaku, true)
        defaultStartupPage = Self.read(defaults, SettingsKey.defaultStartupPage, "/tab/popular/")
        enableBangumiProxy = Self.read(defaults, SettingsKey.enableBangumiProxy, false)
        autoUpdateCheck = Self.read(defaults, SettingsKey.autoUpdate, true)
        checkPluginUpdateOnStartup = Self.read(defaults, SettingsKey.checkPluginUpdateOnStartup, true)
        // 加速方式在全部存储属性初始化完成后再同步到全局开关。
        BangumiAcceleration.mode = enableBangumiProxy ? .mirror : .direct
    }

    private func persist(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: SettingsKey.keyPrefix + key)
    }

    // MARK: - 原始快照（设置备份用）

    /// 已落盘的设置快照：键名（去掉前缀）-> 值。
    ///
    /// 对应原版 `GStorage.rawSettingsSnapshot()`。备份导出以它为底，
    /// 这样本地没有建模、但确实在磁盘上的设置项（旧版留下的快捷键、
    /// 时间表过滤条件、低内存策略等）也能原样带走，
    /// 不会因为「这边没有对应属性」就被静默丢掉。
    func rawSettingsSnapshot() -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix(SettingsKey.keyPrefix) else { continue }
            let name = String(key.dropFirst(SettingsKey.keyPrefix.count))
            guard let json = Self.jsonValue(fromStored: value) else { continue }
            result[name] = json
        }
        return result
    }

    /// 把「本地没有建模」的设置项原样落盘（键名沿用原版 Hive 键名）。
    ///
    /// 原版恢复备份是整段写回设置箱，这边同样不挑键：认得的键由各属性接收，
    /// 认不得的先存着，下次导出还能原样带出去。
    func persistRawSetting(_ value: JSONValue, forKey key: String) {
        guard let stored = Self.storedValue(from: value) else { return }
        defaults.set(stored, forKey: SettingsKey.keyPrefix + key)
    }

    /// UserDefaults 里的值 -> JSONValue。只认标量与字符串列表，
    /// 与 SettingsBackup 支持的取值范围保持一致。
    private static func jsonValue(fromStored value: Any) -> JSONValue? {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            // UserDefaults 把布尔、整数、浮点都包成 NSNumber，
            // 且 Bool 也会以 NSNumber 的身份回来，所以先按 CFBoolean 的类型区分，
            // 否则 true 会被写成 1。
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            // 整数值按 Int 存（备份里 2 与 2.0 对 Flutter 是两种类型），
            // 带小数的才写 double。
            let doubleValue = number.doubleValue
            if doubleValue == doubleValue.rounded(),
               doubleValue <= Double(Int.max),
               doubleValue >= Double(Int.min) {
                return .int(number.intValue)
            }
            return .double(doubleValue)
        case let array as [Any]:
            // 只认字符串列表：混合类型数组不是设置项（与原版 _encodeValue 一致）。
            var strings: [String] = []
            for item in array {
                guard let text = item as? String else { return nil }
                strings.append(text)
            }
            return .array(strings.map(JSONValue.string))
        default:
            return nil
        }
    }

    /// JSONValue -> 可写入 UserDefaults 的值。对象与 null 不是设置项，返回 nil。
    private static func storedValue(from value: JSONValue) -> Any? {
        switch value {
        case .null, .object:
            return nil
        case .bool(let flag):
            return flag
        case .int(let number):
            return number
        case .double(let number):
            return number
        case .string(let text):
            return text
        case .array(let items):
            let strings: [String] = items.compactMap { item in
                if case .string(let text) = item { return text }
                return nil
            }
            guard strings.count == items.count else { return nil }
            return strings
        }
    }

    /// 应用主题对应的明暗（跟随系统时返回 nil，交给 trait collection 判断）。
    private static func darkAppearance(for mode: KazumiThemeMode) -> Bool? {
        switch mode {
        case .system: nil
        case .light: false
        case .dark: true
        }
    }

    /// 把当前主题模式同步给全局调色板（强调色 / 页面背景都按它取色）。
    private func syncAppearance() {
        KazumiThemeColor.darkAppearanceOverride = Self.darkAppearance(for: themeMode)
    }

    private static func read<Value>(_ defaults: UserDefaults, _ key: String, _ fallback: Value) -> Value {
        defaults.object(forKey: SettingsKey.keyPrefix + key) as? Value ?? fallback
    }
}
