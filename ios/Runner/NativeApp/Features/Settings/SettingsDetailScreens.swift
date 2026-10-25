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
    @State private var isConfirmingRestore = false
    /// 恢复默认后顶上那句提示；两秒后自己收起来。
    @State private var showRestoredToast = false

    var body: some View {
        Form {
            Section("播放行为") {
                // 顺序照 main 的「播放行为」一段（Ato 2026-10-24：这三颗提到第一批）。
                Toggle(isOn: backgroundPlaybackBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("后台播放")
                        Text("应用退到后台或熄屏时继续播放音频")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
                        Text("自动跳转到上次播放的位置")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: brightnessVolumeGestureBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("滑动手势")
                        Text("竖向滑动调节音量和亮度")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: privateModeBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("隐身模式")
                        Text("不保留观看记录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("播放参数") {
                Picker("默认倍速", selection: playSpeedBinding) {
                    // 与原版播放器菜单同一份档位，避免两处再次走偏。
                    ForEach(PlaybackSpeed.all, id: \.self) { speed in
                        Text(PlaybackSpeed.label(speed)).tag(speed)
                    }
                }
                captionRow("跳过时长", caption: "顶栏跳过按钮的跳过秒数") {
                    // LP 2026-10-25：一次加 1 秒，上限 90 秒（默认 80）。
                    Stepper(value: buttonSkipTimeBinding, in: 5...90, step: 1) {
                        LabeledContent("跳过时长", value: "\(settings.buttonSkipTime) 秒")
                    }
                }
                captionRow("双击快进时长", caption: "左右两侧双击和左右两个快进按钮的秒数") {
                    Picker("双击快进时长", selection: doubleTapSkipTimeBinding) {
                        ForEach(Self.doubleTapSkipOptions, id: \.self) { seconds in
                            Text("\(seconds) 秒").tag(seconds)
                        }
                    }
                }
                captionRow("长按倍速", caption: "长按屏幕时的倍速") {
                    Picker("长按倍速", selection: longPressSpeedBinding) {
                        ForEach(PlaybackSpeed.all, id: \.self) { speed in
                            Text(PlaybackSpeed.label(speed)).tag(speed)
                        }
                    }
                }
                captionRow("控制栏消失时间", caption: "播放控制器自动隐藏前的停留时长") {
                    HStack {
                        Text("控制栏消失时间")
                        Spacer(minLength: 8)
                        Text(controlBarHideLabel)
                            .foregroundStyle(.secondary)
                    }
                    // 原版滑杆范围 1–10 秒、0.5 秒一档（divisions 18），默认 4 秒。
                    Slider(value: controlBarHideBinding, in: 1...10, step: 0.5)
                }
                captionRow("默认视频比例", caption: "进入播放器时的视频比例，播放器里也能临时改") {
                    Picker("默认视频比例", selection: aspectRatioBinding) {
                        ForEach(PlayerAspectRatioMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }
            }
            Section {
                // 不带 role: .destructive——恢复默认本来就不删用户数据，
                // 染成红色会读成「要丢东西」（main 那颗也是普通按钮）。
                Button {
                    isConfirmingRestore = true
                } label: {
                    Text("恢复默认设置")
                }
            } footer: {
                Text("将播放相关设置恢复为默认值")
            }
        }
        .kazumiSettingsDetail("播放设置")
        .confirmationDialog(
            "恢复默认播放设置",
            isPresented: $isConfirmingRestore,
            titleVisibility: .visible
        ) {
            Button("恢复", role: .destructive) {
                settings.resetPlayerSettings()
                withAnimation { showRestoredToast = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { showRestoredToast = false }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("播放设置将恢复为默认值。")
        }
        .overlay(alignment: .top) {
            if showRestoredToast {
                Text("已恢复默认播放设置")
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
    }

    /// 「标题 + 控件 + 说明小字」的一行。设置页每行都要有一句人话说明。
    private func captionRow<Content: View>(
        _ title: String,
        caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var autoPlayNextBinding: Binding<Bool> {
        Binding(get: { settings.autoPlayNext }, set: { settings.autoPlayNext = $0 })
    }

    private var playResumeBinding: Binding<Bool> {
        Binding(get: { settings.playResume }, set: { settings.playResume = $0 })
    }

    private var backgroundPlaybackBinding: Binding<Bool> {
        Binding(get: { settings.backgroundPlayback }, set: { settings.backgroundPlayback = $0 })
    }

    private var brightnessVolumeGestureBinding: Binding<Bool> {
        Binding(
            get: { settings.brightnessVolumeGesture },
            set: { settings.brightnessVolumeGesture = $0 }
        )
    }

    private var privateModeBinding: Binding<Bool> {
        Binding(get: { settings.privateMode }, set: { settings.privateMode = $0 })
    }

    private var playSpeedBinding: Binding<Double> {
        Binding(get: { settings.playSpeed }, set: { settings.playSpeed = $0 })
    }

    /// 画面两侧双击的秒数档位：5 秒到 1 分钟，够用又不至于滑一长串。
    private static let doubleTapSkipOptions = [5, 10, 15, 20, 30, 45, 60]

    private var doubleTapSkipTimeBinding: Binding<Int> {
        Binding(
            get: { settings.doubleTapSkipTime },
            set: { settings.doubleTapSkipTime = max(1, $0) }
        )
    }

    /// 长按画面时的临时倍速，松手回到原来的倍速。
    private var longPressSpeedBinding: Binding<Double> {
        Binding(get: { settings.longPressSpeed }, set: { settings.longPressSpeed = $0 })
    }

    private var buttonSkipTimeBinding: Binding<Int> {
        Binding(
            get: { settings.buttonSkipTime },
            set: { settings.buttonSkipTime = min(90, max(1, $0)) }
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

    private var aspectRatioBinding: Binding<PlayerAspectRatioMode> {
        Binding(
            get: { settings.defaultAspectRatio },
            set: { settings.defaultAspectRatio = $0 }
        )
    }
}

// MARK: - 弹幕设置

struct DanmakuSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router

    /// DanDanPlay 凭据随打包注入（Info.plist），这个页不再写 UserDefaults 覆盖值。

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
            // LP 2026-10-24：弹弹play 的账号不在这里手填，是打包时从变量注入的，
            // 设置页只留一句说明（Ato 同日同定）。Ato 2026-10-24 后补：没凭据时
            // 不许做成「能点但没反应」——直接把状态写在行上，说明写清缺什么。
            // 三路来源（BiliBili／Gamer／弹弹play）第二批才接，这版只有弹弹play 这一行。
            Section {
                LabeledContent("DanDanPlay") {
                    Text(DanDanCredentials.isConfigured ? "已配置" : "未配置")
                        .foregroundStyle(DanDanCredentials.isConfigured ? Color.secondary : Color.orange)
                }
            } header: {
                Text("弹幕来源")
            } footer: {
                Text(
                    DanDanCredentials.isConfigured
                        ? "账号随打包注入，不需要在这里填写。"
                        : "这一版还没拿到弹弹play 的凭据，所以加载不出弹幕。凭据是打包时注入的，这个页填不了。"
                )
            }
            Section {
                Button {
                    router.push(.danmakuShield)
                } label: {
                    Label("关键词屏蔽", systemImage: "eye.slash")
                }
            } footer: {
                Text("按关键词过滤掉不想看的弹幕，规则可同步到 WebDAV。")
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
    @Environment(AppRouter.self) private var router

    var body: some View {
        Form {
            Section {
                Button {
                    router.push(.download)
                } label: {
                    Label("下载管理", systemImage: "arrow.down.circle")
                }
            } footer: {
                Text("下载管理里可以查看已下载的剧集。")
            }
            // LP 清单里下载设置还有并发、分片、缓存弹幕、下载位置四样；
            // Ato 2026-10-24：这一版没有下载器，四个控件一个不放，只留一句实话。
            Section("说明") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("播放时保存的剧集也会出现在下载管理里；这一版还没有下载队列。")
                    Text("并发设置（同时下载集数、分片并发数）要等下载器做出来才有意义，这一版先不放。")
                    Text("文件固定在应用内，iOS 不允许改到别处。")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .kazumiSettingsDetail("下载设置")
    }
}

// MARK: - 通知设置

struct NotificationSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Form {
            Section("提醒") {
                Toggle("追番更新提醒", isOn: notifyBinding)
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

}

// MARK: - 外观设置

struct ThemeSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @State private var isShowingThemeColorSheet = false

    var body: some View {
        Form {
            Section("主题") {
                captionRow("深色模式", caption: "跟随系统时按系统的明暗自动切换") {
                    Picker("深色模式", selection: themeBinding) {
                        ForEach(KazumiThemeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }
                captionRow("配色", caption: "选一个强调色，按钮与选中态都用它") {
                    Button {
                        isShowingThemeColorSheet = true
                    } label: {
                        HStack {
                            Label("配色", systemImage: "paintpalette")
                            Spacer()
                            Text(settings.themeColor.title)
                                .foregroundStyle(.secondary)
                            KazumiThemeColorSwatch(color: settings.themeColor, size: 18)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("显示效果") {
                Toggle(isOn: glassBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("液态玻璃效果")
                        Text("按钮与弹层用半透明玻璃材质")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // 「OLED优化」中间没有空格，照 main 的写法。
                Toggle(isOn: oledBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OLED优化")
                        Text("深色模式下使用纯黑背景")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: hapticBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("触感反馈")
                        Text("关掉后底栏、时间表等处的轻震一起停")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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

    private var hapticBinding: Binding<Bool> {
        Binding(
            get: { settings.hapticFeedbackEnabled },
            set: { settings.hapticFeedbackEnabled = $0 }
        )
    }

    /// 「控件 + 说明小字」的一行，与播放设置页一致。
    private func captionRow<Content: View>(
        _ title: String,
        caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                VStack(alignment: .leading, spacing: 4) {
                    Picker("启动界面设置", selection: startupBinding) {
                        ForEach(Self.startupPages, id: \.value) { page in
                            Text(page.title).tag(page.value)
                        }
                    }
                    Text("设置应用开启时的默认页面")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("显示") {
                Toggle(isOn: showRatingBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示评分")
                        Text("关闭后隐藏概览和番剧列表中的评分信息")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .kazumiSettingsDetail("界面设置")
    }

    private var showRatingBinding: Binding<Bool> {
        Binding(get: { settings.showRating }, set: { settings.showRating = $0 })
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
