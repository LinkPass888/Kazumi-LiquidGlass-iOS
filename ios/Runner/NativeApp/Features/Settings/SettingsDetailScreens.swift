//
//  SettingsDetailScreens.swift
//  Kazumi
//
//  设置首页下挂的二级设置页。每一张对应主分支里同名的一个分类：
//    * 播放设置   —— lib/pages/settings/player_settings.dart
//    * 弹幕设置   —— lib/pages/settings/danmaku/danmaku_settings.dart
//    * 下载设置   —— lib/pages/settings/download_settings.dart
//    * 通知设置   —— lib/pages/settings/notification_settings.dart
//    * 外观设置   —— lib/pages/settings/theme_settings_page.dart
//    * 界面设置   —— lib/pages/settings/interface_settings.dart
//    * 网络设置   —— lib/pages/settings/proxy/proxy_settings_page.dart
//    * 更新设置   —— lib/pages/settings/update_settings.dart
//

import SwiftUI

/// 二级设置页的统一外壳（对应原版 SettingsDetailScaffold + SettingsList）。
private struct KazumiSettingsDetailStyle: ViewModifier {
    let title: String

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
    }
}

extension View {
    func kazumiSettingsDetail(_ title: String) -> some View {
        modifier(KazumiSettingsDetailStyle(title: title))
    }
}

// MARK: - 播放设置

struct PlayerSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Form {
            Section("播放行为") {
                Toggle(isOn: autoPlayNextBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动连播")
                        Text("当前视频播放完毕后自动播放下一集")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: playResumeBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动跳转")
                        Text("跳转到上次播放位置")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("播放参数") {
                Picker("默认倍速", selection: playSpeedBinding) {
                    // 与原版播放器菜单同一份档位：0.25 → 3.0，每档 0.25。
                    ForEach(PlaybackSpeed.all, id: \.self) { speed in
                        Text(PlaybackSpeed.label(speed)).tag(speed)
                    }
                }
                Stepper(value: buttonSkipTimeBinding, in: 5...300, step: 5) {
                    LabeledContent("顶部按钮快进时长", value: "\(settings.buttonSkipTime) 秒")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("控制栏消失时间")
                        Spacer(minLength: 8)
                        Text(controlBarHideLabel)
                            .foregroundStyle(.secondary)
                    }
                    // 原版滑杆范围 1–10 秒、0.5 秒一档（divisions 18），默认 4 秒。
                    Slider(value: controlBarHideBinding, in: 1...10, step: 0.5)
                }
            }
            Section {
                Picker("超分辨率", selection: superResolutionBinding) {
                    ForEach(SuperResolutionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                Text("超分辨率")
            } footer: {
                Text("效率档 1.5× 放大并轻度锐化，质量档 2×。滤镜由 FFmpeg 内核执行，播放器里也能随时切换。")
            }
        }
        .kazumiSettingsDetail("播放设置")
    }

    private var autoPlayNextBinding: Binding<Bool> {
        Binding(get: { settings.autoPlayNext }, set: { settings.autoPlayNext = $0 })
    }

    private var playResumeBinding: Binding<Bool> {
        Binding(get: { settings.playResume }, set: { settings.playResume = $0 })
    }

    private var playSpeedBinding: Binding<Double> {
        Binding(get: { settings.playSpeed }, set: { settings.playSpeed = $0 })
    }

    private var buttonSkipTimeBinding: Binding<Int> {
        Binding(
            get: { settings.buttonSkipTime },
            set: { settings.buttonSkipTime = max(1, $0) }
        )
    }

    /// 设置页用秒展示，存储沿用原版的毫秒（`playerControllerLayerDisappearTime`）。
    private var controlBarHideBinding: Binding<Double> {
        Binding(
            get: { Double(settings.playerControllerLayerDisappearTime) / 1000 },
            set: { settings.playerControllerLayerDisappearTime = Int(($0 * 1000).rounded()) }
        )
    }

    private var controlBarHideLabel: String {
        let seconds = Double(settings.playerControllerLayerDisappearTime) / 1000
        return seconds == seconds.rounded()
            ? "\(Int(seconds)) 秒"
            : String(format: "%.1f 秒", seconds)
    }

    private var superResolutionBinding: Binding<SuperResolutionMode> {
        Binding(
            get: { settings.superResolutionMode },
            set: { settings.superResolutionMode = $0 }
        )
    }
}

// MARK: - 弹幕设置

struct DanmakuSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router

    /// DanDanPlay 凭据。构建时未注入（Info.plist 为空）时，用户可以在这里手填。
    @AppStorage(DanDanCredentials.appIDKey) private var danDanAppID = ""
    @AppStorage(DanDanCredentials.secretKey) private var danDanSecret = ""

    var body: some View {
        Form {
            Section("显示") {
                Toggle("显示弹幕", isOn: enabledBinding)
                sliderRow(
                    title: "字号",
                    value: "\(Int(settings.danmakuFontSize))",
                    binding: fontSizeBinding,
                    range: 12...32,
                    step: 1
                )
                sliderRow(
                    title: "不透明度",
                    value: String(format: "%.0f%%", settings.danmakuOpacity * 100),
                    binding: opacityBinding,
                    range: 0.2...1.0,
                    step: 0.05
                )
                sliderRow(
                    title: "显示区域",
                    value: String(format: "%.0f%%", settings.danmakuArea * 100),
                    binding: areaBinding,
                    range: 0.25...1.0,
                    step: 0.05
                )
            }
            Section {
                TextField("AppId", text: $danDanAppID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密钥", text: $danDanSecret)
            } header: {
                Text("DanDanPlay")
            } footer: {
                Text("弹幕取自 DanDanPlay，需要 AppId 与密钥签名。留空时使用构建时注入的凭据；两者都为空就无法加载弹幕。")
            }
            Section {
                Button {
                    router.push(.danmakuShield)
                } label: {
                    Label("弹幕屏蔽规则", systemImage: "eye.slash")
                }
            }
        }
        .kazumiSettingsDetail("弹幕设置")
    }

    /// 「标题 + 当前值 + 滑杆」一行。
    private func sliderRow(
        title: String,
        value: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range, step: step)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { settings.danmakuEnabled }, set: { settings.danmakuEnabled = $0 })
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(get: { settings.danmakuFontSize }, set: { settings.danmakuFontSize = $0 })
    }

    private var opacityBinding: Binding<Double> {
        Binding(get: { settings.danmakuOpacity }, set: { settings.danmakuOpacity = $0 })
    }

    private var areaBinding: Binding<Double> {
        Binding(get: { settings.danmakuArea }, set: { settings.danmakuArea = $0 })
    }
}

// MARK: - 下载设置

struct DownloadSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router

    var body: some View {
        Form {
            Section("缓存") {
                Picker("并发数", selection: parallelBinding) {
                    ForEach(1...8, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                Toggle("缓存弹幕", isOn: danmakuBinding)
            }
            Section {
                Button {
                    router.push(.download)
                } label: {
                    Label("缓存管理", systemImage: "arrow.down.circle")
                }
            } footer: {
                Text("缓存管理里可以查看已缓存的剧集与弹幕。")
            }
        }
        .kazumiSettingsDetail("缓存设置")
    }

    private var parallelBinding: Binding<Int> {
        Binding(
            get: { settings.downloadParallelEpisodes },
            set: { settings.downloadParallelEpisodes = $0 }
        )
    }

    private var danmakuBinding: Binding<Bool> {
        Binding(get: { settings.downloadDanmaku }, set: { settings.downloadDanmaku = $0 })
    }
}

// MARK: - 通知设置

struct NotificationSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Form {
            Section("提醒") {
                Toggle("追番更新提醒", isOn: notifyBinding)
                Toggle("移动网络下限制缓存", isOn: meteredBinding)
            }
        }
        .kazumiSettingsDetail("通知设置")
    }

    private var notifyBinding: Binding<Bool> {
        Binding(
            get: { settings.updateNotificationEnabled },
            set: { settings.updateNotificationEnabled = $0 }
        )
    }

    private var meteredBinding: Binding<Bool> {
        Binding(
            get: { settings.meteredNetworkLimit },
            set: { settings.meteredNetworkLimit = $0 }
        )
    }
}

// MARK: - 外观设置

struct ThemeSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @State private var isShowingThemeColorSheet = false

    var body: some View {
        Form {
            Section("主题") {
                Picker("主题模式", selection: themeBinding) {
                    ForEach(KazumiThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Button {
                    isShowingThemeColorSheet = true
                } label: {
                    HStack {
                        Label("配色方案", systemImage: "paintpalette")
                        Spacer()
                        Text(settings.themeColor.title)
                            .foregroundStyle(.secondary)
                        KazumiThemeColorSwatch(color: settings.themeColor, size: 18)
                    }
                }
                .buttonStyle(.plain)
            }
            Section("显示效果") {
                Toggle("液态玻璃效果", isOn: glassBinding)
                Toggle("OLED 优化", isOn: oledBinding)
            }
        }
        .kazumiSettingsDetail("外观设置")
        .sheet(isPresented: $isShowingThemeColorSheet) {
            ThemeColorSheet(selection: themeColorBinding)
        }
    }

    private var themeBinding: Binding<KazumiThemeMode> {
        Binding(get: { settings.themeMode }, set: { settings.themeMode = $0 })
    }

    private var themeColorBinding: Binding<KazumiThemeColor> {
        Binding(get: { settings.themeColor }, set: { settings.themeColor = $0 })
    }

    private var glassBinding: Binding<Bool> {
        Binding(get: { settings.glassEnabled }, set: { settings.glassEnabled = $0 })
    }

    private var oledBinding: Binding<Bool> {
        Binding(get: { settings.oledEnhance }, set: { settings.oledEnhance = $0 })
    }
}

// MARK: - 界面设置

struct InterfaceSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings

    /// 与原版 interface_settings.dart 的 defaultPageMap 一致。
    private static let startupPages: [(value: String, title: String)] = [
        ("/tab/popular/", "推荐"),
        ("/tab/timeline/", "时间表"),
        ("/tab/collect/", "追番"),
        ("/tab/my/", "我的"),
    ]

    var body: some View {
        Form {
            Section("启动") {
                Picker("启动界面", selection: startupBinding) {
                    ForEach(Self.startupPages, id: \.value) { page in
                        Text(page.title).tag(page.value)
                    }
                }
            }
        }
        .kazumiSettingsDetail("界面设置")
    }

    private var startupBinding: Binding<String> {
        Binding(
            get: { settings.defaultStartupPage },
            set: { settings.defaultStartupPage = $0 }
        )
    }
}

// MARK: - 网络设置

struct NetworkSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Form {
            Section("访问加速") {
                Toggle("Bangumi 镜像加速", isOn: mirrorBinding)
            }
            Section {
                Toggle("使用代理", isOn: proxyEnabledBinding)
                TextField("代理地址", text: proxyHostBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("代理端口", text: proxyPortBinding)
                    .keyboardType(.numberPad)
            } header: {
                Text("代理")
            } footer: {
                Text("代理仅对 Bangumi 接口与规则请求生效。")
            }
        }
        .kazumiSettingsDetail("网络设置")
    }

    private var mirrorBinding: Binding<Bool> {
        Binding(get: { settings.enableBangumiProxy }, set: { settings.enableBangumiProxy = $0 })
    }

    private var proxyEnabledBinding: Binding<Bool> {
        Binding(get: { settings.proxyEnabled }, set: { settings.proxyEnabled = $0 })
    }

    private var proxyHostBinding: Binding<String> {
        Binding(get: { settings.proxyHost }, set: { settings.proxyHost = $0 })
    }

    private var proxyPortBinding: Binding<String> {
        Binding(
            get: { settings.proxyPort > 0 ? String(settings.proxyPort) : "" },
            set: { settings.proxyPort = Int($0) ?? 0 }
        )
    }
}

// MARK: - 更新设置

struct UpdateSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Form {
            Section {
                Toggle("应用更新", isOn: autoUpdateBinding)
                Toggle("规则更新", isOn: pluginUpdateBinding)
            } header: {
                Text("启动时检查更新")
            } footer: {
                Text("应用更新会在启动时比对最新版本并提示更新日志；规则更新会检查已安装规则的版本。")
            }
            Section("应用") {
                LabeledContent("当前版本", value: KazumiAppInfo.fullVersion)
                LabeledContent("规则 API 级别", value: "\(KazumiAppInfo.ruleAPILevel)")
            }
        }
        .kazumiSettingsDetail("更新设置")
    }

    private var autoUpdateBinding: Binding<Bool> {
        Binding(get: { settings.autoUpdateCheck }, set: { settings.autoUpdateCheck = $0 })
    }

    private var pluginUpdateBinding: Binding<Bool> {
        Binding(
            get: { settings.checkPluginUpdateOnStartup },
            set: { settings.checkPluginUpdateOnStartup = $0 }
        )
    }
}
