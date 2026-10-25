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
import UIKit
import UserNotifications

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
    @State private var isConfirmingRestore = false
    /// 恢复默认后顶上那句提示；两秒后自己收起来。
    @State private var showRestoredToast = false

    /// DanDanPlay 凭据随打包注入（Info.plist），这个页不再写 UserDefaults 覆盖值。

    var body: some View {
        Form {
            // 三路来源都只是开关（Ato 2502：账号是打包时注入的，屏上不该出现
            // 账号、凭据这些字）。DanDanPlay 返回的每条弹幕自带来路标记，
            // 这三颗就是按标记筛——关掉的那一路不画。
            Section("弹幕来源") {
                Toggle(isOn: biliBiliSourceBinding) {
                    Label("BiliBili", systemImage: "tv")
                }
                Toggle(isOn: gamerSourceBinding) {
                    Label("Gamer", systemImage: "gamecontroller")
                }
                Toggle(isOn: danDanSourceBinding) {
                    Label("弹弹play", systemImage: "bubble.left.and.bubble.right")
                }
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
            Section("弹幕显示") {
                Toggle("显示弹幕", isOn: enabledBinding)
                sliderRow(
                    title: "弹幕区域",
                    value: "\(Int((settings.danmakuArea * 100).rounded()))%",
                    binding: areaBinding,
                    range: 0...1,
                    step: 0.125
                )
                sliderRow(
                    title: "弹幕持续时间",
                    value: "\(Int(settings.danmakuDuration.rounded())) 秒",
                    binding: durationBinding,
                    range: 2...16,
                    step: 1
                )
                sliderRow(
                    title: "弹幕行高",
                    value: String(format: "%.1f", settings.danmakuLineHeight),
                    binding: lineHeightBinding,
                    range: 0...3,
                    step: 0.1
                )
                Toggle(isOn: followSpeedBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("弹幕跟随视频倍速")
                        Text("开启后弹幕速度会随视频倍速而改变")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("顶部弹幕", isOn: topBinding)
                Toggle("底部弹幕", isOn: bottomBinding)
                Toggle("滚动弹幕", isOn: scrollBinding)
                Toggle(isOn: massiveBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("海量弹幕")
                        Text("弹幕过多时进行叠加绘制")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: dedupBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("弹幕去重")
                        Text("相同内容弹幕过多时合并为一条弹幕")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("弹幕样式") {
                Toggle("弹幕描边", isOn: borderBinding)
                sliderRow(
                    title: "弹幕描边粗细",
                    value: String(format: "%.1f", settings.danmakuBorderSize),
                    binding: borderSizeBinding,
                    range: 0.1...3,
                    step: 0.1
                )
                Toggle("弹幕颜色", isOn: colorBinding)
                sliderRow(
                    title: "字体大小",
                    value: "\(Int(settings.danmakuFontSize.rounded()))",
                    binding: fontSizeBinding,
                    range: 10...48,
                    step: 1
                )
                sliderRow(
                    title: "字体字重",
                    value: "\(settings.danmakuFontWeight)",
                    binding: fontWeightBinding,
                    range: 1...9,
                    step: 1
                )
                sliderRow(
                    title: "弹幕不透明度",
                    value: "\(Int((settings.danmakuOpacity * 100).rounded()))%",
                    binding: opacityBinding,
                    range: 0.1...1,
                    step: 0.05
                )
            }
            Section {
                Button {
                    isConfirmingRestore = true
                } label: {
                    Text("恢复默认设置")
                }
            } footer: {
                Text("将弹幕相关设置恢复为默认值")
            }
        }
        .kazumiSettingsDetail("弹幕设置")
        .confirmationDialog(
            "恢复默认弹幕设置",
            isPresented: $isConfirmingRestore,
            titleVisibility: .visible
        ) {
            Button("恢复默认", role: .destructive) {
                settings.resetDanmakuSettings()
                withAnimation { showRestoredToast = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { showRestoredToast = false }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            // 逐字照 main（danmaku_settings.dart:82）：让用户知道屏蔽词不会被清。
            Text("弹幕来源、显示和样式设置将恢复为默认值，关键词屏蔽列表不会被清空。")
        }
        .overlay(alignment: .top) {
            if showRestoredToast {
                Text("已恢复默认弹幕设置")
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
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

    private func bool(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    private func double(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    private var enabledBinding: Binding<Bool> { bool(\.danmakuEnabled) }
    private var followSpeedBinding: Binding<Bool> { bool(\.danmakuFollowSpeed) }
    private var topBinding: Binding<Bool> { bool(\.danmakuTop) }
    private var bottomBinding: Binding<Bool> { bool(\.danmakuBottom) }
    private var scrollBinding: Binding<Bool> { bool(\.danmakuScroll) }
    private var massiveBinding: Binding<Bool> { bool(\.danmakuMassive) }
    private var dedupBinding: Binding<Bool> { bool(\.danmakuDeduplication) }
    private var borderBinding: Binding<Bool> { bool(\.danmakuBorder) }
    private var colorBinding: Binding<Bool> { bool(\.danmakuColor) }
    private var biliBiliSourceBinding: Binding<Bool> { bool(\.danmakuBiliBiliSource) }
    private var gamerSourceBinding: Binding<Bool> { bool(\.danmakuGamerSource) }
    private var danDanSourceBinding: Binding<Bool> { bool(\.danmakuDanDanSource) }

    private var fontSizeBinding: Binding<Double> { double(\.danmakuFontSize) }
    private var opacityBinding: Binding<Double> { double(\.danmakuOpacity) }
    private var areaBinding: Binding<Double> { double(\.danmakuArea) }
    private var durationBinding: Binding<Double> { double(\.danmakuDuration) }
    private var lineHeightBinding: Binding<Double> { double(\.danmakuLineHeight) }
    private var borderSizeBinding: Binding<Double> { double(\.danmakuBorderSize) }

    private var fontWeightBinding: Binding<Double> {
        Binding(
            get: { Double(settings.danmakuFontWeight) },
            set: { settings.danmakuFontWeight = Int($0.rounded()) }
        )
    }
}

// MARK: - 下载设置

struct DownloadSettingsScreen: View {
    @Environment(AppRouter.self) private var router
    @Environment(DownloadDirectoryStore.self) private var downloadDirectory
    @State private var message: String?

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
            Section {
                Button {
                    chooseDirectory()
                } label: {
                    HStack {
                        Text("下载位置")
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(downloadDirectory.displayName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if downloadDirectory.hasCustomSelection {
                    Button("改回应用内") {
                        downloadDirectory.reset()
                        message = nil
                    }
                }
            } footer: {
                if let message {
                    Text(message)
                } else {
                    // main 两处都强调「只对之后下载的生效」（download_settings.dart:148）：
                    // 换目录的人最容易以为旧文件会跟着搬过去，这句不能省。
                    Text("选一个文件夹，之后的下载存到那里；没选过就放在应用内。换位置只对之后下载的剧集生效，之前的不会跟着搬。")
                }
            }
        }
        .kazumiSettingsDetail("下载设置")
    }

    private func chooseDirectory() {
        downloadDirectory.choose { result in
            // 面板退场这一拍再改状态，免得提示压在还在退的页面上。
            switch result {
            case .success:
                message = nil
            case .failure(let error):
                if let pickerError = error as? DocumentPickerBridge.PickerError,
                   case .cancelled = pickerError { return }
                message = error.localizedDescription
            }
        }
    }
}

// MARK: - 通知设置

struct NotificationSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var environment
    /// 系统通知权限（进页面时查一次，申请/跳设置回来再查）。
    @State private var permission: UNAuthorizationStatus = .notDetermined
    @State private var isBusy = false
    /// 「查看排程」那一次读出来的已排定提醒。
    @State private var isShowingSchedule = false
    @State private var scheduled: [ScheduledUpdateNotification] = []

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await handlePermissionTap() }
                } label: {
                    HStack {
                        Text("通知权限")
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(permissionLabel)
                            .foregroundStyle(permission == .authorized ? Color.secondary : Color.orange)
                    }
                }
                .disabled(isBusy)
            } header: {
                Text("通知权限")
            } footer: {
                Text(permissionCaption)
            }

            // 一行一个菜单（LP 2532）：左边写「提醒范围」，右边的值点开选，跟深色模式那行一致。
            Section {
                Picker("提醒范围", selection: scopeBinding) {
                    Text("关闭").tag(false)
                    Text("我在追的动画").tag(true)
                }
                .pickerStyle(.menu)
                .disabled(isBusy)
            } footer: {
                Text("「我在追的动画」包含所有标记「在看」的番剧。")
            }

            Section {
                Button {
                    Task { await showSchedule() }
                } label: {
                    HStack {
                        Text("查看排程")
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(scheduledSummary)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("通知排程")
            } footer: {
                Text("按追番列表里每部番的放送时刻排定，最多排未来 7 天。")
            }
        }
        .kazumiSettingsDetail("通知设置")
        .task { await refreshPermission() }
        .sheet(isPresented: $isShowingSchedule) {
            UpdateScheduleSheet(items: scheduled)
        }
        .onChange(of: settings.updateNotificationEnabled) { _, _ in
            Task { await environment.refreshUpdateNotifications() }
        }
    }

    private var scopeBinding: Binding<Bool> {
        Binding(
            get: { settings.updateNotificationEnabled },
            // 打开「我在追的动画」时顺手把通知权限要下来（LP 2530）：没问过就弹系统弹窗，
            // 之前拒过的只能引导去系统设置。没拿到权限就不打开这个范围，
            // 免得留下一个开着却永远不响的开关。
            set: { newValue in
                if newValue {
                    Task { await enableScope() }
                } else {
                    settings.updateNotificationEnabled = false
                }
            }
        )
    }

    private func enableScope() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let outcome = await UpdateNotificationScheduler.shared.ensurePermission()
        await refreshPermission()
        switch outcome {
        case .granted:
            settings.updateNotificationEnabled = true
            await environment.refreshUpdateNotifications()
        case .asked:
            // 弹窗里没允许：范围保持关闭。
            settings.updateNotificationEnabled = false
        case .needsSettings:
            settings.updateNotificationEnabled = false
            if let url = URL(string: UIApplication.openSettingsURLString) {
                await UIApplication.shared.open(url)
            }
        }
    }

    private var permissionLabel: String {
        switch permission {
        case .authorized, .provisional, .ephemeral: "已允许"
        case .denied: "已关闭"
        case .notDetermined: "未询问"
        @unknown default: "未知"
        }
    }

    private var permissionCaption: String {
        switch permission {
        case .authorized, .provisional, .ephemeral:
            "更新提醒会以系统通知送达。"
        case .denied:
            "系统里已经关掉了这个 App 的通知，点这一行去系统设置里打开。"
        case .notDetermined:
            "点这一行申请通知权限。"
        @unknown default:
            "点这一行申请通知权限。"
        }
    }

    private var scheduledSummary: String {
        if !settings.updateNotificationEnabled { return "提醒已关闭" }
        return "查看已排定的更新提醒"
    }

    private func refreshPermission() async {
        permission = await UpdateNotificationScheduler.shared.authorizationStatus()
    }

    /// 点「通知权限」：没问过就申请；拒绝过的只能跳系统设置。
    private func handlePermissionTap() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let outcome = await UpdateNotificationScheduler.shared.ensurePermission()
        await refreshPermission()
        switch outcome {
        case .granted:
            // 拿到权限了就把提醒排上（之前没权限时排不进去）。
            await environment.refreshUpdateNotifications()
        case .asked:
            break
        case .needsSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                await UIApplication.shared.open(url)
            }
        }
    }

    private func showSchedule() async {
        scheduled = await UpdateNotificationScheduler.shared.scheduledNotifications()
        isShowingSchedule = true
    }
}

/// 「通知排程」弹窗：列出已排定的提醒，按时间先后。
private struct UpdateScheduleSheet: View {
    let items: [ScheduledUpdateNotification]

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text("当前没有已排定的提醒。\n标记「在看」的番剧有更新时间数据时，会自动排定。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.body)
                            .font(.subheadline)
                        Text(Self.format(item.fireAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("通知排程")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 EEEE HH:mm"
        return formatter.string(from: date)
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
            // 一段三行照原版 NetworkMirrorSettings：番剧条目、规则仓库、图片。
            // 代理那两行 LP 2559 让删了（iOS 上开 VPN 就够），连说明一起不留。
            Section("访问加速") {
                Picker("番剧条目加速", selection: bangumiAccelerationBinding) {
                    Text("直连").tag(false)
                    Text("镜像").tag(true)
                }
                .pickerStyle(.menu)

                Toggle("规则仓库镜像", isOn: gitProxyBinding)

                Picker("图片加速", selection: imageAccelerationBinding) {
                    Text("直连").tag(ImageAcceleration.direct.rawValue)
                    Text("镜像").tag(ImageAcceleration.mirror.rawValue)
                }
                .pickerStyle(.menu)
            }
        }
        .kazumiSettingsDetail("网络设置")
    }

    private var bangumiAccelerationBinding: Binding<Bool> {
        Binding(
            get: { settings.enableBangumiProxy },
            set: { settings.enableBangumiProxy = $0 }
        )
    }

    private var gitProxyBinding: Binding<Bool> {
        Binding(get: { settings.enableGitProxy }, set: { settings.enableGitProxy = $0 })
    }

    private var imageAccelerationBinding: Binding<String> {
        Binding(
            get: { settings.imageAcceleration },
            set: { settings.imageAcceleration = $0 }
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
