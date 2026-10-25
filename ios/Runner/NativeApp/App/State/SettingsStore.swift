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
        case .off: "原画质，不做处理"
        case .efficiency: "放大 1.5×，轻度锐化"
        case .quality: "放大 2×，锐化更明显"
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
            return ["scale=iw*1.5:ih*1.5:flags=lanczos"]
        case .quality:
            return ["scale=iw*2:ih*2:flags=lanczos"]
        }
    }
}

/// 播放倍速档位。对应原版 `lib/utils/constants.dart` 的 `defaultPlaySpeedList`：
/// 0.25 → 3.0，每档 0.25，共 12 档。播放器菜单与设置页的「默认倍速」共用这一份，
/// 避免两处档位再次走偏。
enum PlaybackSpeed {
    /// 播放器菜单与设置页给的档位：0.5 到 3.0，够用又不至于一长串。
    static let all: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// 档位文案：整数写 `2x`，小数写 `1.25x`（原版菜单是 `${value}x`）。
    static func label(_ value: Double) -> String {
        if value == value.rounded() {
            return "\(Int(value))x"
        }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        return "\(text)x"
    }

    /// 播放器按钮文案：1 倍时写「倍速」，其余写档位（对应原版的按钮用字）。
    static func buttonLabel(_ value: Double) -> String {
        abs(value - 1) < 0.001 ? "倍速" : label(value)
    }

    /// 把任意倍速归到最近的档位（越界自然取首 / 末档）。
    /// 旧备份或旧安装里可能写着不在档位表上的值，直接拿来会让设置页的选择项对不上。
    static func nearest(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return all.min { abs($0 - value) < abs($1 - value) } ?? 1
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
    /// 顶部快进按钮的秒数，沿用原版 `SettingsKeys.buttonSkipTime` 的键名，默认 80。
    static let buttonSkipTime = "buttonSkipTime"
    /// 画面上左右两侧双击快进 / 快退的秒数，默认 15。
    static let doubleTapSkipTime = "doubleTapSkipTime"
    /// 画面长按时的临时倍速（默认 2.0×）。
    static let longPressSpeed = "longPressSpeed"
    /// 默认视频比例（LP 清单「默认视频比例」，默认自动）。
    static let playerAspectRatio = "playerAspectRatio"
    /// 触感反馈总开关（LP 清单「触感反馈」），默认开启。
    static let hapticFeedbackEnabled = "hapticFeedbackEnabled"
    /// 时间表是否显示评分（Ato 2026-10-24：只管时间表，详情页照旧）。
    static let showRating = "showRating"
    /// 进入播放器时跳到上次播放位置，沿用原版 `SettingsKeys.playResume` 的键名，默认开启。
    static let playResume = "playResume"
    /// 后台播放，沿用原版 `SettingsKeys.backgroundPlayback` 的键名，默认关闭。
    static let backgroundPlayback = "backgroundPlayback"
    /// 竖向滑动调节音量和亮度，沿用原版 `SettingsKeys.brightnessVolumeGesture` 的键名，默认开启。
    static let brightnessVolumeGesture = "brightnessVolumeGesture"
    /// 隐身模式（不保留观看记录），沿用原版 `SettingsKeys.privateMode` 的键名，默认关闭。
    static let privateMode = "privateMode"
    /// 控制栏自动隐藏前的停留时长（毫秒），沿用原版
    /// `SettingsKeys.playerControllerLayerDisappearTime` 的键名，默认 4000。
    static let playerControllerLayerDisappearTime = "playerControllerLayerDisappearTime"
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
    /// 本机在云盘上的设备名（弹幕屏蔽词一份一个文件）。
    static let webDAVDeviceID = "webDAVDeviceID"
    static let bangumiAccessToken = "bangumiAccessToken"
    static let bangumiUsername = "bangumiUsername"
    /// 令牌换回来的数字 ID 的缓存。只当缓存用：同步引擎合并前必须自己再问一次
    /// `/v0/me`，不能拿它去拼收藏列表地址——它可能过期。
    static let bangumiUserId = "bangumiUserId"
    static let bangumiSyncEnabled = "bangumiSyncEnabled"
    static let danmakuShieldSyncEnabled = "danmakuShieldSyncEnabled"
    /// 以下键名与默认值对齐 Flutter `lib/services/storage/settings_keys.dart`，
    /// 便于双方生成的设置备份互相恢复。
    static let bangumiSyncEnable = "bangumiSyncEnable"
    static let bangumiSyncPriority = "bangumiSyncPriority"
    static let bangumiImmediateSyncToastEnable = "bangumiImmediateSyncToastEnable"
    static let bangumiAutoMarkWatched = "bangumiAutoMarkWatched"
    static let webDavEnable = "webDavEnable"
    static let webDavEnableHistory = "webDavEnableHistory"
    static let webDavEnableCollect = "webDavEnableCollect"
    static let webDavEnableDanmakuShield = "webDavEnableDanmakuShield"
    static let proxyEnabled = "proxyEnabled"
    static let proxyHost = "proxyHost"
    static let proxyPort = "proxyPort"
    static let meteredNetworkLimit = "meteredNetworkLimit"
    static let updateNotificationEnabled = "updateNotificationEnabled"
    /// 下载并发数，沿用原版 `SettingsKeys.downloadParallelEpisodes` 的键名。
    static let downloadParallelEpisodes = "downloadParallelEpisodes"
    /// 是否随下载一起缓存弹幕，沿用原版 `SettingsKeys.downloadDanmaku` 的键名。
    static let downloadDanmaku = "downloadDanmaku"
    /// 启动页，沿用原版 `SettingsKeys.defaultStartupPage` 的键名。
    static let defaultStartupPage = "defaultStartupPage"
    /// 追番页「在看」列表记住的排序，存 `CollectSort.rawValue`，默认 `updateTime`。
    /// 切分类不写这个键：它只记「在看」里选的排序。
    static let librarySort = "librarySort"
    /// Bangumi 加速（镜像）开关，沿用原版 `SettingsKeys.enableBangumiProxy` 的键名。
    static let enableBangumiProxy = "enableBangumiProxy"
    /// 启动时检查应用更新，沿用原版 `SettingsKeys.autoUpdate` 的键名。
    static let autoUpdate = "autoUpdate"
    /// 启动时检查规则更新，沿用原版 `checkPluginUpdateOnStartup` 的键名。
    static let checkPluginUpdateOnStartup = "checkPluginUpdateOnStartup"
    /// 一起看房间配置
    static let syncPlayEndPoint = "syncPlayEndPoint"
    static let syncPlayRoom = "syncPlayRoom"
    static let syncPlayPassword = "syncPlayPassword"
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

    /// 默认超分辨率档位（对应原版 `defaultSuperResolutionMode`，沿用 `anime4kMode` 键名）。
    var superResolutionMode: SuperResolutionMode {
        didSet { persist(superResolutionMode.rawValue, SettingsKey.anime4kMode) }
    }

    /// 进入播放器时的初始画面比例。播放器里改只影响这一次，不写回这里。
    var defaultAspectRatio: PlayerAspectRatioMode {
        didSet { persist(defaultAspectRatio.rawValue, SettingsKey.playerAspectRatio) }
    }

    /// 触感反馈总开关：关掉后底栏、时间表等处的轻震一起停。
    var hapticFeedbackEnabled: Bool {
        didSet { persist(hapticFeedbackEnabled, SettingsKey.hapticFeedbackEnabled) }
    }

    /// 概览、番剧列表与番剧详情页是否显示评分。
    var showRating: Bool {
        didSet { persist(showRating, SettingsKey.showRating) }
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

    /// 播放器进入时自动跳到上次播放位置（对应原版「自动跳转」开关）。
    var playResume: Bool {
        didSet { persist(playResume, SettingsKey.playResume) }
    }

    /// 退到后台或熄屏时继续播放音频（对应原版「后台播放」开关，默认关闭）。
    var backgroundPlayback: Bool {
        didSet { persist(backgroundPlayback, SettingsKey.backgroundPlayback) }
    }

    /// 画面上竖向滑动调节亮度与音量（对应原版「滑动手势」开关，默认开启）。
    var brightnessVolumeGesture: Bool {
        didSet { persist(brightnessVolumeGesture, SettingsKey.brightnessVolumeGesture) }
    }

    /// 隐身模式：不写入观看记录（对应原版「隐身模式」开关，默认关闭）。
    var privateMode: Bool {
        didSet { persist(privateMode, SettingsKey.privateMode) }
    }

    /// 顶部快进按钮的跳转秒数（对应原版 `buttonSkipTime`，默认 80 秒）。
    var buttonSkipTime: Int {
        didSet { persist(buttonSkipTime, SettingsKey.buttonSkipTime) }
    }

    /// 画面两侧双击的快进 / 快退秒数（默认 15 秒）。
    var doubleTapSkipTime: Int {
        didSet { persist(doubleTapSkipTime, SettingsKey.doubleTapSkipTime) }
    }

    /// 画面长按时的临时倍速（松手恢复原倍速），默认 2 倍。
    var longPressSpeed: Double {
        didSet { persist(longPressSpeed, SettingsKey.longPressSpeed) }
    }

    /// 控制栏自动隐藏前的停留时长（毫秒，对应原版
    /// `playerControllerLayerDisappearTime`，默认 4000；设置页按 1–10 秒、0.5 秒步进调）。
    var playerControllerLayerDisappearTime: Int {
        didSet {
            persist(playerControllerLayerDisappearTime, SettingsKey.playerControllerLayerDisappearTime)
        }
    }

    var bangumiSyncEnabled: Bool {
        didSet {
            persist(bangumiSyncEnabled, SettingsKey.bangumiSyncEnabled)
            bangumiSyncEnable = bangumiSyncEnabled
        }
    }

    var danmakuShieldSyncEnabled: Bool {
        didSet {
            persist(danmakuShieldSyncEnabled, SettingsKey.danmakuShieldSyncEnabled)
            webDavEnableDanmakuShield = danmakuShieldSyncEnabled
        }
    }

    var bangumiSyncEnable: Bool {
        didSet { persist(bangumiSyncEnable, SettingsKey.bangumiSyncEnable) }
    }

    var bangumiSyncPriority: Int {
        didSet { persist(bangumiSyncPriority, SettingsKey.bangumiSyncPriority) }
    }

    var bangumiImmediateSyncToastEnable: Bool {
        didSet { persist(bangumiImmediateSyncToastEnable, SettingsKey.bangumiImmediateSyncToastEnable) }
    }

    var bangumiAutoMarkWatched: Bool {
        didSet { persist(bangumiAutoMarkWatched, SettingsKey.bangumiAutoMarkWatched) }
    }

    var bangumiAccessToken: String {
        didSet {
            persist(bangumiAccessToken, SettingsKey.bangumiAccessToken)
            BangumiAPI.accessToken = bangumiAccessToken
            // 令牌一改，之前那个 ID 就不再代表当前令牌了，清掉免得屏上留着旧身份。
            if bangumiAccessToken != oldValue, !bangumiUserId.isEmpty {
                bangumiUserId = ""
            }
        }
    }

    var bangumiUsername: String {
        didSet { persist(bangumiUsername, SettingsKey.bangumiUsername) }
    }

    /// 令牌换回来的数字 ID，缓存用。令牌清空时一并清掉：没有令牌就没有身份，
    /// 留着一串数字会让「用户 ID」那行替一个已经失效的令牌担保。
    var bangumiUserId: String {
        didSet { persist(bangumiUserId, SettingsKey.bangumiUserId) }
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

    /// 本机在云盘上的设备名，弹幕屏蔽词按设备一份文件（原版也是这个办法）。
    /// 第一次用到时生成 32 位十六进制，之后不再变 —— 变了就等于新设备，
    /// 云盘上会多出一份空文件。
    var webDAVDeviceID: String {
        get {
            if storedWebDAVDeviceID.isEmpty {
                storedWebDAVDeviceID = UUID().uuidString
                    .replacingOccurrences(of: "-", with: "")
                    .lowercased()
            }
            return storedWebDAVDeviceID
        }
        set { storedWebDAVDeviceID = newValue }
    }

    private var storedWebDAVDeviceID: String {
        didSet { persist(storedWebDAVDeviceID, SettingsKey.webDAVDeviceID) }
    }

    var webDAVAutoSync: Bool {
        didSet {
            persist(webDAVAutoSync, SettingsKey.webDAVAutoSync)
            webDavEnable = webDAVAutoSync
        }
    }

    var webDavEnable: Bool {
        didSet { persist(webDavEnable, SettingsKey.webDavEnable) }
    }

    var webDavEnableHistory: Bool {
        didSet { persist(webDavEnableHistory, SettingsKey.webDavEnableHistory) }
    }

    var webDavEnableCollect: Bool {
        didSet { persist(webDavEnableCollect, SettingsKey.webDavEnableCollect) }
    }

    var webDavEnableDanmakuShield: Bool {
        didSet { persist(webDavEnableDanmakuShield, SettingsKey.webDavEnableDanmakuShield) }
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

    /// 追番页「在看」列表上次选的排序（`CollectSort.rawValue`）。
    var librarySort: String {
        didSet { persist(librarySort, SettingsKey.librarySort) }
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

    /// 一起看的房间服务器地址、房间名与口令
    var syncPlayEndPoint: String {
        didSet { persist(syncPlayEndPoint, SettingsKey.syncPlayEndPoint) }
    }

    var syncPlayRoom: String {
        didSet { persist(syncPlayRoom, SettingsKey.syncPlayRoom) }
    }

    var syncPlayPassword: String {
        didSet { persist(syncPlayPassword, SettingsKey.syncPlayPassword) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 旧版 Swift 键 -> Flutter 键的一次性迁移。只在目标键从未写过时复制，
        // 原键保留不删，旧属性仍可读取；旧 UI 改值时由 didSet 同步到新键。
        Self.migrateLegacySetting(defaults, from: SettingsKey.bangumiSyncEnabled, to: SettingsKey.bangumiSyncEnable)
        Self.migrateLegacySetting(defaults, from: SettingsKey.webDAVAutoSync, to: SettingsKey.webDavEnable)
        Self.migrateLegacySetting(
            defaults,
            from: SettingsKey.danmakuShieldSyncEnabled,
            to: SettingsKey.webDavEnableDanmakuShield
        )
        // 主题模式也要用局部变量承载：初始化阶段读实例属性（`themeMode`）
        // 会触发「self 在全部存储属性就绪前被访问」的编译错误。
        //
        // 存的是 rawValue 字符串（见 `themeMode.didSet`），因此不能用
        // `Self.read(..., KazumiThemeMode.system)` —— 那是 `as? KazumiThemeMode`
        // 强转，字符串永远转不过去，重启后会静默回落到「跟随系统」。
        let storedThemeMode = defaults.object(
            forKey: SettingsKey.keyPrefix + SettingsKey.themeMode
        ) as? String
        let resolvedThemeMode = storedThemeMode
            .flatMap { KazumiThemeMode(rawValue: $0) } ?? .system
        themeMode = resolvedThemeMode
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
        // 应用主题的明暗不再需要额外注明：强调色按 SwiftUI 的 `colorScheme` 显式取，
        // 而 `colorScheme` 就是下面那个 `preferredColorScheme` 的结果。
        selectedPluginIndex = Self.read(defaults, SettingsKey.selectedPluginIndex, 0)
        superResolutionMode = SuperResolutionMode(
            rawValue: Self.read(defaults, SettingsKey.anime4kMode, 1)
        ) ?? .off
        defaultAspectRatio = PlayerAspectRatioMode(
            rawValue: Self.read(defaults, SettingsKey.playerAspectRatio, "automatic")
        ) ?? .automatic
        hapticFeedbackEnabled = Self.read(defaults, SettingsKey.hapticFeedbackEnabled, true)
        showRating = Self.read(defaults, SettingsKey.showRating, true)
        danmakuEnabled = Self.read(defaults, SettingsKey.danmakuEnabled, true)
        danmakuOpacity = Self.read(defaults, SettingsKey.danmakuOpacity, 1.0)
        danmakuFontSize = Self.read(defaults, SettingsKey.danmakuFontSize, 20.0)
        danmakuArea = Self.read(defaults, SettingsKey.danmakuArea, 0.5)
        autoPlayNext = Self.read(defaults, SettingsKey.autoPlayNext, true)
        autoSkipOpEd = Self.read(defaults, SettingsKey.autoSkipOpEd, false)
        playSpeed = PlaybackSpeed.nearest(Self.read(defaults, SettingsKey.playSpeed, 1.0))
        playResume = Self.read(defaults, SettingsKey.playResume, true)
        backgroundPlayback = Self.read(defaults, SettingsKey.backgroundPlayback, false)
        brightnessVolumeGesture = Self.read(defaults, SettingsKey.brightnessVolumeGesture, true)
        privateMode = Self.read(defaults, SettingsKey.privateMode, false)
        // 秒数必须为正：备份或旧数据里若写进了 0 / 负数，快进按钮会变成空操作。
        buttonSkipTime = max(1, Self.read(defaults, SettingsKey.buttonSkipTime, 80))
        doubleTapSkipTime = max(1, Self.read(defaults, SettingsKey.doubleTapSkipTime, 15))
        // 长按倍速固定归到菜单里那几档，存进来的怪值不至于让播放器跑飞。
        longPressSpeed = PlaybackSpeed.nearest(Self.read(defaults, SettingsKey.longPressSpeed, 2.0))
        // 与原版滑杆的上下限一致（1–10 秒）；越界值夹回范围内，避免控制栏永不隐藏或瞬间消失。
        playerControllerLayerDisappearTime = min(
            10_000,
            max(1_000, Self.read(defaults, SettingsKey.playerControllerLayerDisappearTime, 4000))
        )
        bangumiSyncEnabled = Self.read(defaults, SettingsKey.bangumiSyncEnabled, false)
        danmakuShieldSyncEnabled = Self.read(defaults, SettingsKey.danmakuShieldSyncEnabled, false)
        bangumiSyncEnable = Self.read(defaults, SettingsKey.bangumiSyncEnable, false)
        bangumiSyncPriority = Self.read(defaults, SettingsKey.bangumiSyncPriority, BangumiSyncPriority.bangumiFirst.rawValue)
        bangumiImmediateSyncToastEnable = Self.read(
            defaults,
            SettingsKey.bangumiImmediateSyncToastEnable,
            true
        )
        bangumiAutoMarkWatched = Self.read(defaults, SettingsKey.bangumiAutoMarkWatched, false)
        bangumiAccessToken = Self.read(defaults, SettingsKey.bangumiAccessToken, "")
        bangumiUsername = Self.read(defaults, SettingsKey.bangumiUsername, "")
        bangumiUserId = Self.read(defaults, SettingsKey.bangumiUserId, "")
        webDAVURL = Self.read(defaults, SettingsKey.webDAVURL, "")
        webDAVUser = Self.read(defaults, SettingsKey.webDAVUser, "")
        webDAVPassword = Self.read(defaults, SettingsKey.webDAVPassword, "")
        webDAVAutoSync = Self.read(defaults, SettingsKey.webDAVAutoSync, false)
        storedWebDAVDeviceID = Self.read(defaults, SettingsKey.webDAVDeviceID, "")
        webDavEnable = Self.read(defaults, SettingsKey.webDavEnable, false)
        webDavEnableHistory = Self.read(defaults, SettingsKey.webDavEnableHistory, false)
        webDavEnableCollect = Self.read(defaults, SettingsKey.webDavEnableCollect, false)
        webDavEnableDanmakuShield = Self.read(defaults, SettingsKey.webDavEnableDanmakuShield, false)
        proxyEnabled = Self.read(defaults, SettingsKey.proxyEnabled, false)
        proxyHost = Self.read(defaults, SettingsKey.proxyHost, "")
        proxyPort = Self.read(defaults, SettingsKey.proxyPort, 0)
        meteredNetworkLimit = Self.read(defaults, SettingsKey.meteredNetworkLimit, false)
        updateNotificationEnabled = Self.read(defaults, SettingsKey.updateNotificationEnabled, true)
        downloadParallelEpisodes = Self.read(defaults, SettingsKey.downloadParallelEpisodes, 2)
        downloadDanmaku = Self.read(defaults, SettingsKey.downloadDanmaku, true)
        defaultStartupPage = Self.read(defaults, SettingsKey.defaultStartupPage, "/tab/popular/")
        librarySort = Self.read(defaults, SettingsKey.librarySort, "updateTime")
        enableBangumiProxy = Self.read(defaults, SettingsKey.enableBangumiProxy, false)
        autoUpdateCheck = Self.read(defaults, SettingsKey.autoUpdate, true)
        checkPluginUpdateOnStartup = Self.read(defaults, SettingsKey.checkPluginUpdateOnStartup, true)
        syncPlayEndPoint = Self.read(defaults, SettingsKey.syncPlayEndPoint, "")
        syncPlayRoom = Self.read(defaults, SettingsKey.syncPlayRoom, "")
        syncPlayPassword = Self.read(defaults, SettingsKey.syncPlayPassword, "")
        // 加速方式在全部存储属性初始化完成后再同步到全局开关。
        BangumiAcceleration.mode = enableBangumiProxy ? .mirror : .direct
        // init 中给存储属性赋初值不会触发 didSet，这里补一次启动时的令牌注入；
        // 之后设置页改令牌、恢复备份都会走 `bangumiAccessToken.didSet`。
        BangumiAPI.accessToken = bangumiAccessToken
    }

    /// 把播放相关设置恢复为出厂值（LP 清单「恢复默认设置」）。
    ///
    /// 只动播放器与超分辨率：解码器、规则、网络、同步这些不在这里，
    /// 所以设置页那颗按钮的确认文案也只提这两块，不夸大范围。
    func resetPlayerSettings() {
        autoPlayNext = true
        playResume = true
        backgroundPlayback = false
        brightnessVolumeGesture = true
        privateMode = false
        playSpeed = 1.0
        buttonSkipTime = 80
        doubleTapSkipTime = 15
        longPressSpeed = 2.0
        playerControllerLayerDisappearTime = 4000
        superResolutionMode = .off
        defaultAspectRatio = .automatic
    }

    private func persist(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: SettingsKey.keyPrefix + key)
    }

    // MARK: - 原始快照（设置备份用）

    /// 弹幕屏蔽词的原文（一条一行）。
    ///
    /// 这个键不在本类建模的属性里：屏蔽词页（DanmakuShieldScreen）自己按同一个
    /// 键名读写，WebDAV 同步也需要整串带出去，所以在这里开一个读写口，
    /// 让两处用同一份键名，避免再出现「写得进、读不出」的偏差。
    var danmakuFilterRulesText: String {
        get { defaults.string(forKey: SettingsKey.keyPrefix + SettingsKey.danmakuFilterRules) ?? "" }
        set { defaults.set(newValue, forKey: SettingsKey.keyPrefix + SettingsKey.danmakuFilterRules)
            // 改完就来一条通知：同步那边防抖 500ms 后上传（原版的时机）。
            NotificationCenter.default.post(name: .kazumiDanmakuRulesChanged, object: nil)
        }
    }

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
    @discardableResult
    func persistRawSetting(_ value: JSONValue, forKey key: String) -> Bool {
        guard let stored = Self.storedValue(from: value) else { return false }
        defaults.set(stored, forKey: SettingsKey.keyPrefix + key)
        return true
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

    private static func read<Value>(_ defaults: UserDefaults, _ key: String, _ fallback: Value) -> Value {
        defaults.object(forKey: SettingsKey.keyPrefix + key) as? Value ?? fallback
    }

    /// 目标键从未写入、且旧键有值时，把旧值按原类型复制到新键。
    ///
    /// 旧键保持原样，既能被旧属性继续读取，也不会丢失用户已存的值。
    private static func migrateLegacySetting(
        _ defaults: UserDefaults,
        from oldKey: String,
        to newKey: String
    ) {
        let newFullKey = SettingsKey.keyPrefix + newKey
        guard defaults.object(forKey: newFullKey) == nil,
              let legacyValue = defaults.object(forKey: SettingsKey.keyPrefix + oldKey) else {
            return
        }
        defaults.set(legacyValue, forKey: newFullKey)
    }
}
