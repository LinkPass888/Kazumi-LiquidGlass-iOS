//
//  PlayerScreen.swift
//  Kazumi
//
//  对应 lib/pages/video/video_page.dart 的原生实现：
//  * 顶部 16:9 播放区（KSPlayer 基础画面 + 弹幕层），浮着返回与标题；
//  * 播放条：播放 / 暂停、进度、弹幕开关、超分辨率、倍速；
//  * 下方是线路与分集切换，解析中显示进度与解析日志，失败时给出原因与重试。
//

import AVFoundation
import SwiftUI

/// 视频比例（对应原版 `lib/pages/player/controller/player_aspect_ratio.dart` 的四档）。
/// 与原版一样，播放器里的选择只在本次播放内生效，不写回设置。
enum PlayerAspectRatioMode: String, CaseIterable, Identifiable {
    case automatic
    case crop
    case stretch
    case ratio4x3

    var id: String { rawValue }

    /// 与原版 `PlayerAspectRatio.label` 逐字一致。
    var label: String {
        switch self {
        case .automatic: "自动"
        case .crop: "裁切填充"
        case .stretch: "拉伸填充"
        case .ratio4x3: "4:3"
        }
    }

    /// 播放区本身的宽高比：只有 4:3 会换盒子，其余沿用 16:9。
    var frameAspectRatio: CGFloat {
        self == .ratio4x3 ? 4.0 / 3.0 : 16.0 / 9.0
    }

    /// 交给 AVPlayerLayer 的填充方式（原版 `BoxFit` 的等价物）。
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .automatic: .resizeAspect
        case .crop: .resizeAspectFill
        case .stretch, .ratio4x3: .resize
        }
    }
}

struct PlayerScreen: View {
    var bangumiID: Int
    var episode: Int
    var source: PlaybackSource?

    @State private var controller: PlayerController?
    @State private var surface = PlayerSurfaceModel()
    @State private var danmakuEnabled = true
    @State private var playbackRate: Float = 1.0
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var isEditingSkipSeconds = false
    @State private var skipSecondsInput = ""
    @State private var skipSecondsError: String?

    // 本批新增：画面比例、控制栏自动隐藏、锁定、长按临时倍速。
    @State private var aspectRatioMode: PlayerAspectRatioMode = .automatic
    @State private var controlsVisible = true
    @State private var isLocked = false
    /// 每次交互 +1，body 上的 `.task(id:)` 据此取消上一轮自动隐藏并重新计时。
    @State private var hideGeneration = 0
    @State private var isTemporarySpeed = false
    @State private var rateBeforeTemporarySpeed: Float = 1.0
    /// 本次按压是否已经进入长按状态（用来区分「松手时是短按还是长按结束」）。
    @State private var longPressFired = false

    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let controller {
                VStack(spacing: 0) {
                    playerArea(controller)
                    controlsLayer
                    detailArea(controller)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) { toastView }
        .overlay { skipSecondsDialog }
        .animation(.easeOut(duration: 0.2), value: surface.toastMessage)
        .onChange(of: surface.isPlaying) { _, playing in
            // 暂停时不允许隐藏（简报要求）；重新起播后重新计时。
            if playing {
                scheduleControlsHide()
            } else {
                showControls()
            }
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            if scrubbing {
                showControls()
            } else {
                scheduleControlsHide()
            }
        }
        .onChange(of: isEditingSkipSeconds) { _, editing in
            if editing {
                showControls()
            } else {
                scheduleControlsHide()
            }
        }
        // 自动隐藏：用 `.task(id:)` 而不是自建 Task，离开页面时系统会自己取消。
        .task(id: hideGeneration) {
            guard canHideControls else { return }
            let seconds = Double(settings.playerControllerLayerDisappearTime) / 1000
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            guard canHideControls else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                controlsVisible = false
            }
        }
        .task {
            guard controller == nil else { return }
            // 先把两个 store 取成局部常量：闭包会长期挂在 surface 上，
            // 这样试不会把整个 View（含 @Environment 包装器）一起捕获。
            let settingsStore = settings
            let library = environment.library
            danmakuEnabled = settingsStore.danmakuEnabled
            playbackRate = Float(settingsStore.playSpeed)
            let created = PlayerController(
                bangumiID: bangumiID,
                episode: episode,
                source: source,
                plugins: environment.plugins,
                library: library
            )
            controller = created
            // 默认倍速：以前只读了一次没交给播放器，现在存进画面模型，
            // 就绪 / 重新起播时由它补一次（AVPlayer 会回到 1.0）。
            surface.setPlaybackRate(Float(settingsStore.playSpeed))
            // 自动连播：正常播完后根据设置决定是否切到下一集。
            surface.onFinish = { [weak created] surface in
                guard let created else { return }
                // 播完先落一次进度：结尾 5 秒内会归零，当作「已看完」的边界。
                persistWatchProgress(
                    library: library,
                    controller: created,
                    position: surface.currentTime,
                    duration: surface.duration
                )
                guard settingsStore.autoPlayNext else { return }
                guard created.currentEpisode < created.episodes.count else {
                    // 已是末集：停下来并给一句提示，不静默什么都不做。
                    surface.toastMessage = "已经是最新一集"
                    return
                }
                let next = created.currentEpisode + 1
                surface.prepareForNewEpisode()
                Task { await created.selectEpisode(next) }
            }
            resumeIfNeeded(library: library, controller: created)
            await created.start()
        }
        .task {
            // 播放期间定期落一次进度；退出与播完时还会各写一次。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                guard let controller else { continue }
                persistProgress(controller)
            }
        }
        .onDisappear {
            // 先摘掉结束回调，避免关闭播放器时的 finish 又被当成「播完」触发连播。
            surface.onFinish = nil
            // 长按手势若被系统取消，松手回调不会来，退出时兜一次恢复。
            endTemporarySpeed()
            if let controller { persistProgress(controller) }
            surface.stop()
            controller?.stop()
        }
    }

    // MARK: - 播放区

    @ViewBuilder
    private func playerArea(_ controller: PlayerController) -> some View {
        ZStack {
            // 视频画面自己响应点击：点一下切换播放 / 暂停（底部按钮仍是主入口）。
            // 控制栏隐藏时，点一下先把控制栏叫回来；长按 0.5 秒临时加速。
            videoSurface(controller)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 24) {
                    longPressFired = true
                    beginTemporarySpeed()
                } onPressingChanged: { pressing in
                    handleSurfacePressing(pressing)
                }

            VStack(spacing: 6) {
                topBar(controller)
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible && !isLocked)
                if let notice = danmakuNotice(controller) {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.black.opacity(0.45)))
                }
                Spacer()
            }

            if let error = surface.errorMessage {
                errorOverlay(error, controller: controller)
            }

            // 锁定键：锁住时其它控制都收起来，只有它必须一直可点。
            if controlsVisible || isLocked {
                HStack {
                    Spacer(minLength: 0)
                    lockButton
                }
                .padding(.trailing, 10)
                .padding(.bottom, 10)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        // 四档比例：只有 4:3 会改变播放区盒子，其余仍是 16:9。
        .aspectRatio(aspectRatioMode.frameAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    /// 画面按压：短按切控制栏 / 播放暂停，长按临时倍速（对应原版
    /// `player_item.dart` 的 onLongPressStart / onLongPressEnd）。
    ///
    /// 用 `onLongPressGesture` 的 pressing 回调而不是两个手势叠加：
    /// 同一次按压只会走一条分支，长按松手不会再触发一次短按。
    private func handleSurfacePressing(_ pressing: Bool) {
        guard !isLocked else { return }
        if pressing {
            longPressFired = false
        } else if longPressFired {
            longPressFired = false
            endTemporarySpeed()
        } else {
            handleSurfaceTap()
        }
    }

    private func handleSurfaceTap() {
        guard !isLocked else { return }
        if !controlsVisible {
            showControls()
        } else {
            surface.togglePlay()
            noteInteraction()
        }
    }

    /// 长按临时加速：原版按住期间用 `defaultShortcutForwardPlaySpeed`（默认 2.0），
    /// 松手恢复按下前的速度，不写回设置。
    private func beginTemporarySpeed() {
        guard !isLocked else { return }
        // 长按中再按一次也重新记起点，避免上一次手势被系统取消后卡在 2x。
        isTemporarySpeed = true
        rateBeforeTemporarySpeed = playbackRate
        surface.setPlaybackRate(2.0)
        surface.toastMessage = PlaybackSpeed.label(2.0)
    }

    private func endTemporarySpeed() {
        guard isTemporarySpeed else { return }
        isTemporarySpeed = false
        surface.setPlaybackRate(rateBeforeTemporarySpeed)
    }

    private var lockButton: some View {
        Button {
            toggleLock()
        } label: {
            Image(systemName: isLocked ? "lock" : "lock.open")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.black.opacity(0.35)))
                .hitTarget44()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLocked ? "解锁面板" : "锁定面板")
    }

    private func toggleLock() {
        isLocked.toggle()
        if isLocked {
            // 锁定后收走全部控制与画面手势，只留锁定键。
            withAnimation(.easeOut(duration: 0.2)) {
                controlsVisible = false
            }
            scheduleControlsHide()
        } else {
            showControls()
        }
    }

    // MARK: - 控制栏自动隐藏

    private var canHideControls: Bool {
        controlsVisible && surface.isPlaying && !isScrubbing && !isLocked && !isEditingSkipSeconds
    }

    /// 按「控制栏消失时间」设置重新计时；不能隐藏时 `.task(id:)` 会直接返回。
    private func scheduleControlsHide() {
        hideGeneration &+= 1
    }

    private func showControls() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) {
                controlsVisible = true
            }
        }
        scheduleControlsHide()
    }

    /// 任何一次控件交互都算「有操作」，重新计时。
    private func noteInteraction() {
        showControls()
    }

    /// 黑底 + 视频画面（或解析中的状态）。拆出来是为了只在画面上挂手势，
    /// 不把顶栏按钮与错误遮罩的点击也当成「点画面暂停」。
    @ViewBuilder
    private func videoSurface(_ controller: PlayerController) -> some View {
        ZStack {
            Color.black

            if let text = controller.playbackURL, let url = URL(string: text) {
                KSPlayerContainer(
                    url: url,
                    referer: controller.referer,
                    userAgent: controller.userAgent,
                    videoFilters: settings.superResolutionMode.videoFilters,
                    videoGravity: aspectRatioMode.videoGravity,
                    danmaku: controller.danmakuComments,
                    danmakuEnabled: danmakuEnabled,
                    danmakuOpacity: settings.danmakuOpacity,
                    danmakuFontSize: settings.danmakuFontSize,
                    danmakuArea: settings.danmakuArea,
                    surface: surface
                )
            } else {
                statusOverlay(controller)
            }
        }
    }

    private func topBar(_ controller: PlayerController) -> some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.black.opacity(0.35)))
                    .hitTarget44()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            // 从历史进入时 `source` 是空值，标题得用控制器里重建出来的那个。
            Text(controller.source?.itemName ?? "播放")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 4)

            skipForwardButton
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        // 点顶栏任意位置也算一次交互（按钮自己的动作照常执行）。
        .simultaneousGesture(TapGesture().onEnded { noteInteraction() })
    }

    /// 顶部快进按钮：单击快进，长按修改秒数（对应原版 player_item_panel 的快进按钮）。
    private var skipForwardButton: some View {
        controlLabel("goforward", text: "\(settings.buttonSkipTime)s")
            .contentShape(Capsule(style: .continuous))
            // 单击与长按必须互斥：两个手势各挂一次时，长按松手会再触发
            // 一次单击，用户点开「跳过秒数」的同时画面已经快进了。
            .gesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in presentSkipSecondsDialog() }
                    .exclusively(
                        before: TapGesture().onEnded {
                            surface.skipForward(seconds: Double(settings.buttonSkipTime))
                        }
                    )
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("快进")
            .accessibilityHint("快进\(settings.buttonSkipTime)秒，长按修改时间")
            .accessibilityAddTraits(.isButton)
    }

    private func errorOverlay(_ message: String, controller: PlayerController) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("重新加载") {
                surface.errorMessage = nil
                Task { await controller.retry() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.55))
    }

    private func danmakuNotice(_ controller: PlayerController) -> String? {
        switch controller.danmakuStatus {
        case .loading:
            return danmakuEnabled ? "正在加载弹幕…" : nil
        case .unavailable, .failed:
            return danmakuEnabled ? controller.danmakuMessage : nil
        case .idle, .ready:
            return nil
        }
    }

    private func statusOverlay(_ controller: PlayerController) -> some View {
        VStack(spacing: 10) {
            switch controller.phase {
            case .idle, .searchingSource, .resolvingChapters, .parsingMedia:
                ProgressView()
                    .tint(.white)
                Text(phaseTitle(controller.phase))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                // 切集时先亮一下目标集数，代替原版的「正在加载${集标题}」
                // （原生这边只有 URL，没有集标题）。
                if showsEpisodeLoadingLine(controller.phase) {
                    Text("正在加载第 \(controller.currentEpisode) 话")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                if let last = controller.logLines.last, showsLogLine(controller.phase) {
                    Text(last)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .padding(.horizontal, 24)
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                HStack(spacing: 10) {
                    Button("重试") {
                        Task { await controller.retry() }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("返回选源") { dismiss() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            case .ready:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func phaseTitle(_ phase: PlayerController.Phase) -> String {
        switch phase {
        case .idle: "准备中…"
        case .searchingSource: "正在查找播放源…"
        case .resolvingChapters: "正在抓取剧集列表…"
        case .parsingMedia: "正在解析播放地址…"
        case .ready: ""
        case .failed: ""
        }
    }

    /// 「正在加载第 N 话」只在真正要播某一集时出现；查找播放源阶段还没定集数。
    private func showsEpisodeLoadingLine(_ phase: PlayerController.Phase) -> Bool {
        switch phase {
        case .idle, .resolvingChapters, .parsingMedia: true
        case .searchingSource, .ready, .failed: false
        }
    }

    /// 查找播放源阶段顶行已经是「正在查找播放源…」，不再叠一行同义的日志。
    private func showsLogLine(_ phase: PlayerController.Phase) -> Bool {
        phase != .searchingSource
    }

    // MARK: - 播放条

    /// 控制栏容器：隐藏时留一个透明点击区，点哪里都能把控制栏叫回来。
    private var controlsLayer: some View {
        ZStack {
            playerControls
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
            if !controlsVisible && !isLocked {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { showControls() }
            }
        }
    }

    private var playerControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(timeText(isScrubbing ? scrubValue : surface.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                scrubber
                Text(timeText(surface.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }

            HStack(spacing: 8) {
                controlButton(symbol: "backward.end.fill") { previousEpisode() }
                controlButton(symbol: surface.isPlaying ? "pause.fill" : "play.fill") {
                    surface.togglePlay()
                    noteInteraction()
                }
                controlButton(symbol: "forward.end.fill") { nextEpisode() }
                controlButton(symbol: danmakuEnabled ? "text.bubble.fill" : "text.bubble") {
                    danmakuEnabled.toggle()
                    noteInteraction()
                }
                superResolutionMenu
                speedControl
                aspectRatioMenu
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black)
        // 点中任意一个控件都算一次交互（按钮自己的动作照常执行）。
        .simultaneousGesture(TapGesture().onEnded { noteInteraction() })
    }

    /// 进度条：在系统 Slider 后面再画一段「已缓冲」。缓冲段比轨道略高，
    /// 两侧会露出来，保证它不会比已播段短、也始终看得见。
    private var scrubber: some View {
        ZStack(alignment: .leading) {
            GeometryReader { proxy in
                let total = max(1, surface.duration)
                // 已缓冲永远不短于已播：内核上报滞后时至少画到当前位置。
                let buffered = max(surface.currentTime, surface.bufferedTime)
                Capsule()
                    .fill(.white.opacity(0.28))
                    .frame(width: proxy.size.width * min(1, max(0, buffered / total)), height: 6)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            Slider(
                value: scrubBinding,
                in: 0...max(1, surface.duration),
                onEditingChanged: onScrub
            )
            .tint(KazumiPalette.accent(for: colorScheme))
        }
    }

    private func controlButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 32)
                .background(Capsule().fill(.white.opacity(0.12)))
                .hitTarget44()
        }
        .buttonStyle(.plain)
    }

    private func controlLabel(_ symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(.white.opacity(0.12)))
    }

    private var superResolutionMenu: some View {
        Menu {
            ForEach(SuperResolutionMode.allCases) { mode in
                Button {
                    settings.superResolutionMode = mode
                    noteInteraction()
                } label: {
                    if settings.superResolutionMode == mode {
                        Label("\(mode.title) · \(mode.detail)", systemImage: "checkmark")
                    } else {
                        Text("\(mode.title) · \(mode.detail)")
                    }
                }
            }
        } label: {
            controlLabel("sparkles", text: settings.superResolutionMode.title)
        }
    }

    /// 倍速：两侧的 －/＋ 按原版档位逐档调，中间菜单直选 12 档。
    /// 原版在播放器里选速不写回设置，这里也不写。
    private var speedControl: some View {
        HStack(spacing: 2) {
            speedStepButton(symbol: "minus", delta: -1)
            speedMenu
            speedStepButton(symbol: "plus", delta: 1)
        }
        .padding(.horizontal, 4)
        .background(Capsule().fill(.white.opacity(0.12)))
    }

    private var speedMenu: some View {
        Menu {
            ForEach(PlaybackSpeed.all, id: \.self) { rate in
                Button {
                    applySpeed(Float(rate))
                    noteInteraction()
                } label: {
                    if abs(playbackRate - Float(rate)) < 0.01 {
                        Label(PlaybackSpeed.label(rate), systemImage: "checkmark")
                    } else {
                        Text(PlaybackSpeed.label(rate))
                    }
                }
            }
        } label: {
            Text(PlaybackSpeed.buttonLabel(Double(playbackRate)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(minWidth: 34)
                .padding(.vertical, 7)
        }
    }

    private func speedStepButton(symbol: String, delta: Int) -> some View {
        Button {
            stepSpeed(by: delta)
            noteInteraction()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta > 0 ? "加速" : "减速")
    }

    private func applySpeed(_ rate: Float) {
        playbackRate = rate
        surface.setPlaybackRate(rate)
    }

    /// 逐档加减；到头时给一句提示，不再静默什么都不做。
    private func stepSpeed(by delta: Int) {
        let current = Double(playbackRate)
        let index = PlaybackSpeed.all.firstIndex { abs($0 - current) < 0.001 }
            ?? PlaybackSpeed.all.enumerated()
                .min(by: { abs($0.element - current) < abs($1.element - current) })?.offset
            ?? 0
        let target = index + delta
        guard PlaybackSpeed.all.indices.contains(target) else {
            surface.toastMessage = delta > 0 ? "已达倍速上限" : "已达倍速下限"
            return
        }
        applySpeed(Float(PlaybackSpeed.all[target]))
    }

    private var aspectRatioMenu: some View {
        Menu {
            ForEach(PlayerAspectRatioMode.allCases) { mode in
                Button {
                    aspectRatioMode = mode
                    noteInteraction()
                } label: {
                    if aspectRatioMode == mode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            controlLabel("aspectratio", text: aspectRatioMode.label)
        }
    }

    private var scrubBinding: Binding<Double> {
        Binding(
            get: { isScrubbing ? scrubValue : surface.currentTime },
            set: { scrubValue = $0 }
        )
    }

    private func onScrub(_ editing: Bool) {
        if editing {
            scrubValue = surface.currentTime
            isScrubbing = true
        } else {
            isScrubbing = false
            surface.seek(to: scrubValue)
        }
    }

    private func timeText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "00:00" }
        let total = Int(value)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - 进度与续播

    /// 把当前播放位置写进观看历史（对应原版 history 记录）。
    private func persistProgress(_ controller: PlayerController) {
        persistWatchProgress(
            library: environment.library,
            controller: controller,
            position: surface.currentTime,
            duration: surface.duration
        )
    }

    /// 进入播放器时按「自动跳转」设置恢复同一集的播放位置。
    /// 只有存的正是当前这一集才续播，换集不迁跳（保留现有行为）。
    private func resumeIfNeeded(library: LibraryStore, controller: PlayerController) {
        guard settings.playResume else { return }
        guard let record = library.record(for: controller.bangumiID) else { return }
        guard record.episodeNumber == controller.currentEpisode else { return }
        guard record.progressSeconds > 1 else { return }
        // 存在结尾 5 秒内的一律当已看完，不续播（避免一进去就结束）。
        if record.durationSeconds > 0, record.progressSeconds >= record.durationSeconds - 5 {
            return
        }
        surface.pendingResumeTime = record.progressSeconds
    }

    // MARK: - 上一集 / 下一集

    private func previousEpisode() {
        guard let controller else { return }
        // 章节还没抓回来时不报「已经是第一集」，否则正常加载会被误报成边界。
        guard !controller.episodes.isEmpty else { return }
        guard controller.currentEpisode > 1 else {
            surface.toastMessage = "已经是第一集"
            return
        }
        persistProgress(controller)
        surface.prepareForNewEpisode()
        let target = controller.currentEpisode - 1
        Task { await controller.selectEpisode(target) }
    }

    private func nextEpisode() {
        guard let controller else { return }
        guard !controller.episodes.isEmpty else { return }
        guard controller.currentEpisode < controller.episodes.count else {
            surface.toastMessage = "已经是最新一集"
            return
        }
        persistProgress(controller)
        surface.prepareForNewEpisode()
        let target = controller.currentEpisode + 1
        Task { await controller.selectEpisode(target) }
    }

    // MARK: - 提示

    @ViewBuilder
    private var toastView: some View {
        if let message = surface.toastMessage {
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .padding(.top, 8)
                // 自动消失只做纯赋值：出入场交给 body 上那个 .animation(value:)。
                // task 以文案为 id，快速连点时上一条定时器自然作废。
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    if surface.toastMessage == message {
                        surface.toastMessage = nil
                    }
                }
        }
    }

    /// 「跳过秒数」弹框：对应原版 player_item_panel 的 _showForwardChange。
    @ViewBuilder
    private var skipSecondsDialog: some View {
        if isEditingSkipSeconds {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { dismissSkipSecondsDialog() }
                VStack(spacing: 14) {
                    Text("跳过秒数")
                        .font(.headline)
                    HStack(spacing: 8) {
                        TextField("秒", text: $skipSecondsInput)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                        Text("秒")
                            .foregroundStyle(.secondary)
                    }
                    if let error = skipSecondsError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 12) {
                        Button("取消") { dismissSkipSecondsDialog() }
                            .buttonStyle(.bordered)
                        Spacer(minLength: 0)
                        Button("确定") { commitSkipSeconds() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
                .frame(maxWidth: 320)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                )
                .padding(40)
            }
            .transition(.opacity)
        }
    }

    private func presentSkipSecondsDialog() {
        skipSecondsInput = "\(settings.buttonSkipTime)"
        skipSecondsError = nil
        withAnimation(.easeOut(duration: 0.15)) {
            isEditingSkipSeconds = true
        }
    }

    private func dismissSkipSecondsDialog() {
        withAnimation(.easeOut(duration: 0.15)) {
            isEditingSkipSeconds = false
        }
    }

    private func commitSkipSeconds() {
        let text = skipSecondsInput.trimmingCharacters(in: .whitespaces)
        guard let value = Int(text) else {
            skipSecondsError = "请输入数字"
            return
        }
        guard value > 0 else {
            skipSecondsError = "请输入大于0的数字"
            return
        }
        settings.buttonSkipTime = value
        dismissSkipSecondsDialog()
    }

    // MARK: - 线路与选集

    private func detailArea(_ controller: PlayerController) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if controller.roads.count > 1 {
                    roadPicker(controller)
                }
                if !controller.episodes.isEmpty {
                    episodeList(controller)
                }
            }
            .padding(16)
        }
        .background(KazumiPalette.background(for: colorScheme))
    }

    private func roadPicker(_ controller: PlayerController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("线路")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(controller.roads.enumerated()), id: \.offset) { index, road in
                        let selected = controller.selectedRoad == index
                        Button {
                            // 同一条线路不重起播；换线路直接接着播（对应本批要求）。
                            guard index != controller.selectedRoad else { return }
                            persistProgress(controller)
                            surface.prepareForNewEpisode()
                            Task { await controller.selectRoad(index) }
                        } label: {
                            Text(road.name.isEmpty ? "线路 \(index + 1)" : road.name)
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(
                                            selected
                                                ? KazumiPalette.accent(for: colorScheme)
                                                : KazumiPalette.cardSurface(for: colorScheme)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// 选集：一行一集（对应原版 `_EpisodeRow` 的列表形态）。
    /// 原版没有「已看」标记，这里也不做；当前集只标「正在播放」。
    private func episodeList(_ controller: PlayerController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选集")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVStack(spacing: 6) {
                ForEach(Array(controller.episodes.enumerated()), id: \.offset) { index, _ in
                    let number = index + 1
                    let selected = controller.currentEpisode == number
                    Button {
                        switchEpisode(to: number, controller: controller)
                    } label: {
                        HStack(spacing: 10) {
                            // 带具体集号时用「话」，与原版计数一致。
                            Text("第 \(number) 话")
                                .font(.subheadline.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.white : Color.primary)
                            Spacer(minLength: 8)
                            if selected {
                                Text("正在播放")
                                    .font(.caption)
                                    .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    selected
                                        ? KazumiPalette.accent(for: colorScheme)
                                        : KazumiPalette.cardSurface(for: colorScheme)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func switchEpisode(to number: Int, controller: PlayerController) {
        // 点当前集是空操作（原版同样早退）；但上一次加载失败时允许重点重试。
        guard number != controller.currentEpisode || surface.errorMessage != nil else { return }
        persistProgress(controller)
        surface.prepareForNewEpisode()
        Task { await controller.selectEpisode(number) }
    }
}

/// 把一次播放位置写进观看历史（对应原版 history 记录）。
///
/// 抽成文件内自由函数是为了让 `surface.onFinish` 那个长期存活的开包
/// 也能直接写进度，而不必把整个 View 捕进去。
/// 距离结尾 5 秒以内视为已看完，进度归零保存，下次从头播（对应原版
/// `nearEndWatchedThreshold`）。
@MainActor
private func persistWatchProgress(
    library: LibraryStore,
    controller: PlayerController,
    position: Double,
    duration: Double
) {
    guard position.isFinite, position > 0 else { return }
    var progress = position
    if duration > 0, progress >= duration - 5 {
        progress = 0
    }
    let source = controller.source
    library.upsert(WatchRecord(
        bangumiID: controller.bangumiID,
        bangumiName: source?.itemName ?? "",
        imageURL: library.entry(for: controller.bangumiID)?.imageURL ?? "",
        sourceRuleName: source?.pluginName ?? "",
        // 原生这边只有 URL，没有集标题，留空由历史页回退成「第 N 话」。
        episodeTitle: "",
        episodeNumber: controller.currentEpisode,
        progressSeconds: progress,
        durationSeconds: duration.isFinite && duration > 0 ? duration : 0,
        updatedAt: Date()
    ))
}
