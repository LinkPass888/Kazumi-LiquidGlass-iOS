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
import AVKit
import MediaPlayer
import SwiftUI
import UIKit

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

    /// 交给 mpv 渲染层的填充方式。
    var fillMode: MPVPlayerContainer.MPVFillMode {
        switch self {
        case .automatic, .ratio4x3: .fit
        case .crop: .crop
        case .stretch: .stretch
        }
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

/// 画面下面那一片的两个页：左边选集（线路 + 集数），右边这部番的吐槽。
enum PlayerDetailTab: String, CaseIterable, Identifiable {
    case episodes = "选集"
    case comments = "评论"

    var id: String { rawValue }
}

/// 「更多」面板里的三页：主列表和两个二级页（定时关闭 / 超分辨率 / 画面比例）。
/// 用 popover 自己翻页，不依赖 Menu 的嵌套菜单——那样菜单一开就没法挡自动隐藏。
/// 更多菜单里能打开的那几个页面，一次只有一张。
enum PlayerSheet: String, Identifiable {
    case danmakuSettings
    case airPlay
    case externalPlay
    case syncPlay
    case videoInfo

    var id: String { rawValue }
}

/// 一次竖滑浮层要显示的内容：调的是亮度还是音量，现在到多少。
struct GestureHUDValue: Equatable {
    enum Kind { case brightness, volume }

    var kind: Kind
    var value: Double

    /// Colo 2026-10-24 定的：横条左边固定一颗 15pt 图标，
    /// 亮度 `sun.max`、音量 `speaker.wave.2`，不跟着档位换。
    var symbol: String {
        switch kind {
        case .brightness: return "sun.max"
        case .volume: return "speaker.wave.2"
        }
    }
}

/// 画面这一次拖动调的是哪一路（起手时定死，中途不改）。
enum DragAxis {
    case seek
    case brightness
    case volume
    /// 贴着左边缘往右拖：这是侧滑返回，画面手势这一路什么都不做。
    case ignored
}

/// 系统音量：改音量时 iOS 自己会在屏幕边上弹那条音量浮条，所以这里只负责换算，
/// 不再画第二条（两条叠在一起是原版被吐槽的地方）。
@MainActor
final class PlayerVolumeControl {
    static let shared = PlayerVolumeControl()

    /// MPVolumeView 内部的音量滑杆；拿到之后系统音量就能直接写。
    weak var slider: UISlider?

    var current: Double {
        if let slider { return Double(slider.value) }
        return Double(AVAudioSession.sharedInstance().outputVolume)
    }

    func set(_ value: Double) {
        guard let slider else { return }
        slider.value = Float(min(1, max(0, value)))
        slider.sendActions(for: .touchUpInside)
    }
}

/// 把 MPVolumeView 塞进视图树（1×1、几乎全透明），只为拿到它的音量滑杆。
private struct SystemVolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.showsRouteButton = false
        view.alpha = 0.01
        DispatchQueue.main.async {
            if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
                PlayerVolumeControl.shared.slider = slider
            }
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// 音量浮层里那条系统音量滑杆：直接用 `MPVolumeView`，不自绘。
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsRouteButton = false
        view.showsVolumeSlider = true
        view.tintColor = .white
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct PlayerScreen: View {
    var bangumiID: Int
    var episode: Int
    var source: PlaybackSource?

    @State private var controller: PlayerController?
    @State private var surface = PlayerSurfaceModel()
    @State private var danmakuEnabled = true
    /// 横屏底栏那个发弹幕的输入框：草稿、焦点。
    /// 画面量出来的宽度：横屏两行底栏按它判断。
    @State private var surfaceWidth: CGFloat = 0
    /// 播放区所在容器的尺寸（全屏时要按它铺满，见 `boxAspectRatio`）。
    @State private var containerSize: CGSize = .zero
    /// 播放页四周的安全区内缩（全屏时画面要绕过刘海，按它算窗口尺寸）。
    @State private var containerInsets = EdgeInsets()
    @State private var danmakuDraft = ""
    @FocusState private var danmakuFieldFocused: Bool
    @State private var playbackRate: Float = 1.0
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var isEditingSkipSeconds = false
    @State private var skipSecondsInput = ""
    @State private var skipSecondsError: String?

    // 本批新增：画面比例、控制栏自动隐藏、锁定、长按临时倍速。
    @State private var aspectRatioMode: PlayerAspectRatioMode = .automatic
    @State private var controlsVisible = true
    /// 「更多」/ 倍速面板：自己握开关，好让控制层知道菜单还开着。
    ///
    /// 系统菜单不把开合告诉代码，所以另挂了一个 `SystemMenuProbe` 看它在不在，
    /// 下面的 `.task` 靠它把「菜单已经收了」这件事认出来。
    /// 每次交互 +1，body 上的 `.task(id:)` 据此取消上一轮自动隐藏并重新计时。
    @State private var hideGeneration = 0
    /// 「更多」菜单开着：开着的时候不自动收控制栏，否则菜单会变成一张点不动的死图。
    @State private var menuOpen = false
    @State private var menuOpenedAt = Date()
    @State private var probeSawMenu = false
    @State private var probeLastSeen = Date()
    /// 收藏钮点下去的缩放（Colo 2026-10-28：0.15 秒的 spring 弹一下）。
    @State private var collectScale: CGFloat = 1
    @State private var isTemporarySpeed = false
    @State private var rateBeforeTemporarySpeed: Float = 1.0
    /// 本次按压是否已经进入长按状态（用来区分「松手时是短按还是长按结束」）。
    /// 全屏：画面占满窗口、横屏、隐藏状态栏，选集与线路区收起。
    /// 对应原版 `fillsWindow = fullscreen || (maxWidth > maxHeight)`。
    @State private var isFullscreen = false
    /// 这一轮全屏里是否真的横过屏；用来区分「刚进来还没转」和「用户转回去了」。
    @State private var sawLandscape = false
    /// 亮度 / 音量的横条浮层：左半边调亮度、右半边调音量，都自己画。
    @State private var gestureHUD: GestureHUDValue?
    /// 横滑调进度时中间那朵「+15s」。
    @State private var seekHUD: Int?
    /// 双击中间那朵播放 / 暂停符号。
    @State private var playPauseHUD: String?
    /// 这一串拖动在调什么：进度、亮度还是音量。起手时按方向定死，中途不再改。
    @State private var dragAxis: DragAxis?
    /// 起手那一刻的亮度或音量。
    @State private var dragValueStart: Double?
    /// 横滑起手时这一集的进度，以及滑到哪儿（松手才真 seek）。
    @State private var seekDragStart: Double?
    @State private var seekDragTarget: Double?
    /// 浮层淡出的定时器，下一次滑动会把它作废重排。
    @State private var hudHideTask: Task<Void, Never>?
    /// 最近一次长按触发的时间：长按松手后系统仍会补一次短按，用它挡掉。
    @State private var lastLongPressAt: Date?
    /// 画面下面那片选中的页。
    @State private var detailTab: PlayerDetailTab = .episodes
    /// 这部番的吐槽（按需加载，进页面不拉）。
    @State private var comments: [BangumiCommentItem] = []
    @State private var commentTotal = 0
    @State private var isLoadingComments = false
    @State private var commentLoadFailed = false
    /// 评论：最新优先还是最早优先；切换时只在本地重排，不再请求。
    @State private var isCommentsAscending = false
    /// 当前看的是哪一集的评论（nil 就是整部番），切集时用。
    @State private var commentEpisode: Int?
    /// 100 集以上时，快速跳到某一块（每 100 集一块）。
    @State private var episodeGridPage = 0
    /// 更多菜单里几个「开个页面」的入口。收到一个枚举里，
    /// 一次只可能有一张：几个布尔各自为真时后弹的那张会被系统吞掉。
    @State private var activeSheet: PlayerSheet?
    /// 「播放信息」里点了媒体地址后的「已复制」提示，1.2 秒后自动收回。
    @State private var mediaURLCopied = false
    @State private var mediaURLCopiedTask: Task<Void, Never>?
    /// 横屏选集：从右侧滑进来的玻璃窗口（LP 3637 要的，不再是铺满整屏的面板）。
    @State private var showsEpisodesPanel = false
    /// 定时关闭：还剩多少秒，nil 就是没定。
    /// 侧滑返回时页面跟着手走多少点。
    /// 这一次拖动是不是从左边边缘起手、按侧滑返回处理。
    @State private var sleepTimerRemaining: Int?
    @State private var sleepTimerTask: Task<Void, Never>?
    /// 片头片尾弹窗：AniSkip 的时间轴 + 倒数 / 撤销 / 切集三态。
    @State private var skipPill = SkipSegmentPillModel()

    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    /// 主题色分深浅两档，菜单跟着走（Colo 3344）。
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// 画面那一半（body 的前半截）。
    ///
    /// 从 body 里拆出来的：整条修饰符链太长，编译器的类型检查会超时
    /// （`unable to type-check this expression in reasonable time`）。
    /// 拆成两段后各段单独求解，逻辑一行没改。
    private var playbackScaffold: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                if let controller {
                // 全屏与竖屏用同一棵树，只把下面那块收起来：
                // 分成两支的话，切全屏时 SwiftUI 会把播放器整个拆掉重建，
                // 画面从 0 重新起播（LP 3624「切全屏进度归零」）。
                // 铺满还是 16:9 由画面自己的 PlayerBoxModifier 决定。
                VStack(spacing: 0) {
                    playerArea(controller)
                    if !isFullscreen {
                        episodeArea(controller)
                    }
                }
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 上下两条压暗：整屏画，跟控制层同一个透明度一起淡出。
            screenMasks
                .opacity(controlsShown ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: controlsVisible)

            // 横屏选集：右侧滑进来的玻璃窗口（LP 3637）。
            // 左边压暗一层，点它就收；不铺满整屏，画面还看得见。
            if showsEpisodesPanel, let controller {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { closeEpisodesPanel() }

                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    episodesPanel(controller)
                }
                // 贴死右边缘，别被右侧安全区内缩出一截黑
                // （LP 2026-10-27，Colo §14.5）。
                .ignoresSafeArea(.container, edges: .trailing)
                .transition(.move(edge: .trailing))
            }
        }
        }
        .animation(.easeOut(duration: 0.12), value: showsEpisodesPanel)
        .background(Color.black.ignoresSafeArea())
        // 竖屏全屏不做：先真的横过屏，之后用户又转回竖屏，才退出全屏。
        // 只看「现在是不是竖的」会误判——刚点全屏、屏幕还没来得及转的那一帧
        // 本来就是竖的，那样一进就被自己的判据弹出来（LP 2026-10-25 现场）。
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        containerSize = proxy.size
                        containerInsets = proxy.safeAreaInsets
                    }
                    .onChange(of: proxy.size) { _, size in
                        containerSize = size
                        containerInsets = proxy.safeAreaInsets
                        if size.width > size.height {
                            sawLandscape = true
                        } else if isFullscreen, sawLandscape {
                            sawLandscape = false
                            exitFullscreen()
                        }
                    }
            }
        }
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .overlay(alignment: .top) { toastView }
        .overlay { skipSecondsDialog }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
    }

    var body: some View {
        playbackScaffold
        // 竖屏侧滑返回：导航栏藏了之后系统的手势会失效，这里把它接回来（全屏时不认）。

        .animation(.easeOut(duration: 0.2), value: surface.toastMessage)
        // 弹幕拉不到的时候说一句原因（Ato：对不上号 / 接口失败要说，
        // 「这集本来就没弹幕」是正常情况，安静地不显示）。
        .onChange(of: controller?.danmakuMessage) { _, message in
            if let message, !message.isEmpty {
                surface.toastMessage = message
            }
        }
        // 退出全屏时把选集窗口收掉：它只属于横屏，留着会压在竖屏的选集区上。
        .onChange(of: isFullscreen) { _, fullscreen in
            if !fullscreen, showsEpisodesPanel {
                closeEpisodesPanel()
            }
        }
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
        // 片头片尾弹窗：跟播放内核同一个 250ms 节拍（快照泵就是这条节拍），
        // 位置 / 时长喂进去、seek 和切集请求接出来。时间轴只查一次，
        // 用户把 AniSkip 关了就把手上这份清掉。
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if let controller {
                    controller.maybeLoadSkipSegments(
                        duration: surface.duration,
                        enabled: settings.aniSkipLookup
                    )
                    skipPill.segments = settings.aniSkipLookup ? controller.skipSegments : .empty
                }
                skipPill.position = surface.currentTime
                skipPill.duration = surface.duration
                skipPill.isScrubbing = isScrubbing
                skipPill.update()
                if let target = skipPill.consumeSeekTarget() {
                    surface.seek(to: target)
                }
                if skipPill.consumeNextEpisodeRequest() {
                    nextEpisode()
                }
            }
        }
        // 后台播放关着就退到后台即暂停；开着则让音频会话保持可播，
        // 熄屏 / 切出去继续出声（LP 清单「后台播放」，默认关）。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            if !settings.backgroundPlayback, surface.isPlaying {
                surface.pause()
            }
            if let controller {
                persistProgress(controller)
            }
        }
        .onChange(of: settings.backgroundPlayback) { _, _ in
            applyAudioSessionPolicy()
        }
        .onChange(of: isEditingSkipSeconds) { _, editing in
            if editing {
                showControls()
            } else {
                scheduleControlsHide()
            }
        }
        // 自动隐藏：用 `.task(id:)` 而不是自建 Task，离开页面时系统会自己取消。
        .task {
            // 看菜单还在不在：在就不收控制栏，收了就恢复自动隐藏。
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                if menuOpen {
                    if SystemMenuProbe.isPresented {
                        probeSawMenu = true
                        probeLastSeen = Date()
                    } else if probeSawMenu, Date().timeIntervalSince(probeLastSeen) > 1.2 {
                        // 菜单已经收了：控制栏恢复自动隐藏。
                        menuOpen = false
                        probeSawMenu = false
                        scheduleControlsHide()
                    } else if !probeSawMenu, Date().timeIntervalSince(menuOpenedAt) > 45 {
                        // 探测器没认出来（换过实现就不一定认得出），留个上限，别把控制栏钉死。
                        menuOpen = false
                        scheduleControlsHide()
                    }
                }
            }
        }
        .task(id: hideGeneration) {
            guard canHideControls else { return }
            let seconds = Double(settings.playerControllerLayerDisappearTime) / 1000
            var remaining = seconds
            var sawMenu = false
            while true {
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled, canHideControls else { return }
                // 系统菜单（`Menu`）开着就停在原地：它不报开合，只能看它在不在。
                if SystemMenuProbe.isPresented {
                    NSLog("[controls] 探测到菜单，先不收")
                    sawMenu = true
                    remaining = 0.4
                    continue
                }
                if sawMenu {
                    // 菜单刚关掉：重新按设置全额起算，不是接着漏下的时间收。
                    sawMenu = false
                    remaining = seconds
                    continue
                }
                NSLog("[controls] 收层（菜单没探测到）")
                withAnimation(.easeOut(duration: 0.2)) {
                    controlsVisible = false
                }
                return
            }
        }
        .task {
            await bootstrapPlaybackIfNeeded()
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
            // 带着全屏状态离开会把整个 App 锁在横屏，退出时一定回竖屏。
            exitFullscreen()
            if let controller { persistProgress(controller) }
            surface.stop()
            controller?.stop()
            // 退出播放器时把观看记录并进云盘（原版 player_item.dart:375 也是这个时机）。
            syncHistoryIfNeeded()
        }
    }

    /// 各种半屏页面的内容。抽成方法是因为原来这段 switch 直接写在 `.sheet` 里，
    /// 修饰符链一长，编译器的类型检查就超时了。
    @ViewBuilder
    private func sheetContent(_ sheet: PlayerSheet) -> some View {
        switch sheet {
        case .danmakuSettings:
            NavigationStack {
                DanmakuSettingsScreen()
                    .navigationTitle("弹幕设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // 右上角关闭：跟下滑关闭是同一个动作。标题居中，
                        // 左边不放东西，也不再加「取消」（Colo 2026-10-27）。
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                dismissKeyboard()
                                activeSheet = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("关闭")
                        }
                    }
            }
            .environment(settings)
            .environment(environment.router)
        case .airPlay:
            airPlaySheet
        case .externalPlay:
            externalPlaySheet
        case .syncPlay:
            SyncPlaySheet(
                settings: settings,
                showingSyncPlay: Binding(
                    get: { activeSheet == .syncPlay },
                    set: { if !$0 { activeSheet = nil } }
                ),
                surface: surface
            )
        case .videoInfo:
            videoInfoSheet
        }
    }

    /// 进页面时把播放器建起来（原来直接写在 `.task` 闭包里）。
    ///
    /// 搬出来是因为那个闭包太大了：编译器的类型检查在那里超时（413 行）。
    /// 逻辑一行没改。
    private func bootstrapPlaybackIfNeeded() async {
        guard controller == nil else { return }
        // 先把两个 store 取成局部常量：闭包会长期挂在 surface 上，
        // 这样试不会把整个 View（含 @Environment 包装器）一起捕获。
        let settingsStore = settings
        let library = environment.library
        danmakuEnabled = settingsStore.danmakuEnabled
        applyAudioSessionPolicy()
        playbackRate = Float(settingsStore.playSpeed)
        // 默认视频比例：设置页选的那一档作为这次播放的起点，
        // 播放器里再改只影响这一次（与原版一样不写回设置）。
        aspectRatioMode = settingsStore.defaultAspectRatio
        let created = PlayerController(
            bangumiID: bangumiID,
            episode: episode,
            source: source,
            plugins: environment.plugins,
            library: library
        )
        controller = created
        // 默认倍速：就绪 / 重新起播时由画面模型再补一次（AVPlayer 会回到 1.0）。
        let startSpeed = Float(settingsStore.playSpeed)
        surface.setPlaybackRate(startSpeed)
        // 自动连播：正常播完后根据设置决定是否切到下一集。
        surface.onFinish = { [weak created] surface in
            guard let created else { return }
            // 播完先落一次进度：结尾 5 秒内会归零，当作「已看完」的边界。
            persistWatchProgress(
                library: library,
                privateMode: settingsStore.privateMode,
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

    // MARK: - 播放区

    /// 全屏时把「画面比例」换成**容器比例**：`.aspectRatio(_, contentMode: .fit)`
    /// 传 nil 会退回内容的固有比例（mpv 视图是方的，上一版就成了 382×382）。
    /// 换成容器自己的比例后 fit 的结果正好等于容器，全屏铺满——只改一个参数、
    /// 不改视图类型；改类型会把 mpv 拆掉重建、进度归零（3678）。
    private var boxAspectRatio: CGFloat {
        if isFullscreen, containerSize.width > 0, containerSize.height > 0 {
            return containerSize.width / containerSize.height
        }
        return aspectRatioMode.frameAspectRatio
    }

    /// 画面：16:9（或 4:3）画面本身，控制层压在它上面。
    /// 竖屏里这条就是页面最上面那一块；横屏全屏时铺满。
    @ViewBuilder
    private func playerArea(_ controller: PlayerController) -> some View {
        // 在这里读一次：视频尺寸变化要让整个播放区重算（控制层矩形也跟着变）。
        let videoSize = surface.videoSize
        ZStack {
            interactiveSurface(controller)

            if let error = surface.errorMessage {
                errorOverlay(error, controller: controller)
            }

            // 控制层只铺在画面矩形里：横屏两侧的黑边留空，顶栏 / 进度条 /
            // 两侧 15 秒钮都跟画面左右边缘对齐（DEFECT 4）。
            // 视频尺寸还没拿到时 videoRect 回落到整块画面，不会先缩一下再跳。
            GeometryReader { proxy in
                let videoRect = aspectRatioMode.fillMode.videoRect(
                    in: CGRect(origin: .zero, size: proxy.size),
                    videoSize: videoSize
                )
                // 控制层铺满整块播放区，不再框进 videoRect：横屏全屏时这块就是
                // 874x402 的窗口，顶栏底栏进度条才贴得到窗口边（Colo 2026-10-27，
                // LP「横屏播放器一圈都不沾边」）。竖屏内联时播放区本身就是那块
                // 16:9 画面，所以一条规则两边都对。videoRect 只留给弹幕层。
                controlLayer(controller, width: proxy.size.width)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }

            // 画面正中那三朵：亮度 / 音量横条、横滑的秒数、双击的播放暂停。
            // 同一时刻只会有一朵（起手就定死了这一次拖动在调什么）。
            if let gestureHUD {
                gestureOverlay(gestureHUD)
            }
            if let seekHUD {
                seekOverlay(seekHUD)
            }
            if let playPauseHUD {
                playPauseOverlay(playPauseHUD)
            }

            // 片头片尾弹窗：横屏固定位置（跟控制栏显隐无关），竖屏贴控制栏上沿。
            // 状态机自己跑，这里只负责把它摆到画面右下角。
            if skipPill.isVisible {
                SkipSegmentPillView(model: skipPill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, skipPillTrailingInset)
                    .padding(.bottom, skipPillBottomInset)
            }

            // 长按加速时顶部正中的胶囊，松手就消失。
            if isTemporarySpeed {
                VStack {
                    temporarySpeedCapsule
                        .padding(.top, 12)
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .modifier(PlayerBoxModifier(fillsWindow: isFullscreen,
                                    aspectRatio: boxAspectRatio))
        // 横屏画面铺满整个窗口（874×402）：底部那 21 的 home 安全区也忽略掉，
        // 不忽略画面就矮一截、底下露一条黑缝（LP 2026-10-27）。
        // 控制层自己另外忽略底边，留在安全区里排，不受这里影响。
        .ignoresSafeArea(.container, edges: isFullscreen ? .bottom : [])
        .background(Color.black)
        // MPVolumeView 得在视图树里，才拿得到它内部的音量滑杆。
        .background(
            SystemVolumeHost()
                .frame(width: 1, height: 1)
                .opacity(0.01)
        )
        // 控制层要知道画面有多宽：横屏才排两行底栏（宽 ≥ 600）。
        // 用 onGeometryChange 量，不套 GeometryReader —— 那玩意会把可用空间全吃掉，
        // 画面就不再是 16:9（LP 3623「竖屏播放器窗口变太大」就是这么来的）。
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            surfaceWidth = width
        }
    }

    /// 画面 + 手势（只挂在画面上，下面的选集与评论不接）：
    /// 单击显隐控制层，双击播放暂停，长按临时倍速，左右两侧竖滑分别调亮度与音量。
    /// 全屏时画面要铺满**整个窗口**（874×402），不是安全区里的 750×382——
    /// 左右那 62 的刘海区画面也要占住（Colo 2026-10-27 定的 (b)）。
    /// 控制层仍然按安全区的 750 排，所以 15 秒两颗落在 750 的 1/4 与 3/4。
    private var fullscreenVideoSize: CGSize {
        guard isFullscreen else { return .zero }
        return CGSize(
            width: containerSize.width + containerInsets.leading + containerInsets.trailing,
            height: containerSize.height + containerInsets.top + containerInsets.bottom
        )
    }

    private func interactiveSurface(_ controller: PlayerController) -> some View {
        GeometryReader { proxy in
            // 全屏用窗口尺寸，竖屏用播放区自己的尺寸（两者在竖屏下相同）。
            let surfaceSize = isFullscreen ? fullscreenVideoSize : proxy.size
            // 全屏时画面（874×402）比播放区（750×382）大，而 GeometryReader 的内容
            // 默认贴**左上角**——不居中就会整体偏右 62（LP 2026-10-27「视频偏右」）。
            // 外面再套一层居中的 frame，竖屏下两者同尺寸、没有影响。
            Group {
            // 没有画面（解析中、加载失败）时一个面手势都不挂：父层的手势会抢走
            // 失败页上「重试」「返回选源」的点击，连点都落不下去（LP 2026-10-25）。
            if controller.playbackURL == nil {
                videoSurface(controller)
                    .frame(width: surfaceSize.width, height: surfaceSize.height)
            } else {
                videoSurface(controller)
                    .frame(width: surfaceSize.width, height: surfaceSize.height)
                    .contentShape(Rectangle())
                    .gesture(
                        ExclusiveGesture(SpatialTapGesture(count: 2), SpatialTapGesture(count: 1))
                            .onEnded { value in
                                switch value {
                                case .first:
                                    handleSurfaceDoubleTap()
                                case .second:
                                    handleSurfaceTap()
                                }
                            }
                    )
                    // 滑动手势关了就不收竖向拖拽（LP 清单「滑动手势」，默认开）。
                    .simultaneousGesture(
                        surfaceDragGesture(width: surfaceSize.width),
                        including: settings.brightnessVolumeGesture ? .all : .none
                    )
                    .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 24) {
                        lastLongPressAt = Date()
                        beginTemporarySpeed()
                    } onPressingChanged: { pressing in
                        if !pressing { endTemporarySpeed() }
                    }
            }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
        }
    }

    /// 画面拖动，一次只走一路：
    /// * 横着拖是调进度，换算照 main（`180000 / width` 毫秒每点，整块画面宽 ≈ 180 秒），
    ///   比拖进度条细得多，中途只显示「+15s」，松手才真跳到那儿；
    /// * 竖着拖左半边调亮度、右半边调音量，同样自己画横条，不弹系统那条。
    private func surfaceDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                if dragAxis == nil {
                    if abs(value.translation.width) > abs(value.translation.height) {
                        // 贴左边缘往右起手是返回，交给外层的侧滑手势，不调进度。
                        if value.startLocation.x < 28, value.translation.width > 0 {
                            dragAxis = .ignored
                            return
                        }
                        dragAxis = .seek
                        seekDragStart = surface.currentTime
                        seekDragTarget = surface.currentTime
                    } else if value.startLocation.x < width / 2 {
                        dragAxis = .brightness
                        dragValueStart = Double(UIScreen.main.brightness)
                    } else {
                        dragAxis = .volume
                        dragValueStart = PlayerVolumeControl.shared.current
                    }
                }
                switch dragAxis {
                case .seek:
                    guard let start = seekDragStart else { return }
                    let seconds = Double(value.translation.width) / Double(max(1, width)) * 180
                    let limit = max(0, surface.duration - 0.5)
                    let target = min(max(0, start + seconds), limit)
                    seekDragTarget = target
                    seekHUD = Int((target - start).rounded())
                case .brightness, .volume:
                    guard let start = dragValueStart else { return }
                    // 整块画面高 ≈ 226pt，滑完一屏就到底，手感与原版一致。
                    let delta = Double(-value.translation.height) / 220
                    let target = min(1, max(0, start + delta))
                    if dragAxis == .brightness {
                        UIScreen.main.brightness = CGFloat(target)
                        gestureHUD = GestureHUDValue(kind: .brightness, value: target)
                    } else {
                        PlayerVolumeControl.shared.set(target)
                        gestureHUD = GestureHUDValue(kind: .volume, value: target)
                    }
                case .ignored, .none:
                    break
                }
            }
            .onEnded { _ in
                let wasSeeking = dragAxis == .seek
                if wasSeeking, let target = seekDragTarget {
                    surface.seek(to: target)
                }
                dragAxis = nil
                dragValueStart = nil
                seekDragStart = nil
                seekDragTarget = nil
                // 秒数胶囊停 1.2 秒；亮度 / 音量还是 0.6 秒。
                scheduleHUDHide(after: wasSeeking ? 1.2 : 0.6)
            }
    }

    private var controllerPhase: PlayerController.Phase {
        controller?.phase ?? .idle
    }

    /// 控制层是不是该露面。
    ///
    /// 暂停、播放失败：控制层和左上返回一直在，这时候用户最可能想退出去（Colo 3307）。
    /// 加载中按正常状态处理，跟正在播放一样随控制条自动隐藏、点一下唤回来。
    private var controlsShown: Bool {
        controlsVisible || pinsControls
    }

    private var pinsControls: Bool {
        if case .failed = controllerPhase { return true }
        return controllerPhase == .ready && !surface.isPlaying
    }

    /// 控制层：顶一行、底一行，都浮在画面上；几秒不碰淡出，点一下回来。
    /// 隐藏只降透明度、不动布局，画面不会跳。
    private func controlLayer(_ controller: PlayerController, width: CGFloat) -> some View {
        ZStack {
            VStack(spacing: 0) {
                topBar(controller)
                Spacer(minLength: 0)
                transportBar(controller, width: width)
            }
            // 命中只给控制栏本身：收起时它不该挡着「点画面把控制层叫回来」。
            .allowsHitTesting(controlsShown)

            // 画面左右两侧的快退 / 快进：秒数取设置里「快进快退时长」（doubleTapSkipTime，默认 15）。
            // 双击两侧的快进已经删掉（LP 3593），快进快退只从这两颗走。
            if controlsShown {
                // 位置按 LP 2026-10-27：画面的 1/4 与 3/4 处，不顶到左右边缘，
                // 也不要挤在正中——中间留给画面。
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        sideSkipButton(isForward: false)
                            .frame(width: proxy.size.width / 2, alignment: .center)
                        sideSkipButton(isForward: true)
                            .frame(width: proxy.size.width / 2, alignment: .center)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .transition(.opacity)
            }

            if !controlsShown {
                // 控制层收起时，整块画面都是「把控制层叫回来」的命中区。
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { showControls() }
            }

        }
        .opacity(controlsShown ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: controlsVisible)
        // 全屏时底栏离**窗口**下沿 12，不是离 home 那条安全区 12
        // （横屏底部还有 21 的内缩，不忽略的话底栏会悬在半空，LP 2026-10-27）。
        .ignoresSafeArea(.container, edges: isFullscreen ? .bottom : [])
    }


    /// 控制栏的压暗：不是一整块从顶到尾的渐变，而是上下各一条、各自从屏幕边
    /// 往里渐隐，过了控制栏就没了——中间那块画面完全不压暗（LP 2026-10-27）。
    ///
    /// **这两条挂在页面根层、按整屏画**（Colo 2026-10-28）：早先把它放在控制层里，
    /// 控制层本身缩在安全区里，里面再写 ignoresSafeArea 也没用——遮罩始终从安全区
    /// 下沿起画，顶上一直空着 59（LP 两次都说「没到顶」）。现在按窗口画，
    /// 高度是「顶栏 120＋顶部安全区」「底栏 160＋底部安全区」，渐变消失点仍在控制栏下面。
    /// 控制层照旧留在安全区里排，不受影响。
    private var screenMasks: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .black.opacity(0.3), location: 0.5),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // 高度＝顶部安全区＋64（Colo 2026-10-28）：顶栏 44＋下边距 12＋留 8，
            // 过了控制栏就化干净，别一路压到画面中间（LP「往下遮太多了」）。
            .frame(height: containerInsets.top + 64)

            Spacer(minLength: 0)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.3), location: 0.5),
                    .init(color: .black.opacity(0.65), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: containerInsets.bottom + 160)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// 左右两侧那颗：快退 / 快进「快进快退时长」那么多秒（LP 3643：用 15 秒那档，
    /// 不是顶栏长按那颗的 80 秒）。
    /// 规格（Colo 3599）：竖向居中、距左右边 16、44×44，箭头环里写秒数，
    /// 跟控制层一起显隐；点一下闪一次秒数。
    private func sideSkipButton(isForward: Bool) -> some View {
        let seconds = settings.doubleTapSkipTime
        return Button {
            if isForward {
                surface.skipForward(seconds: Double(seconds))
                flashSeekHUD(seconds)
            } else {
                surface.seek(to: max(0, surface.currentTime - Double(seconds)))
                flashSeekHUD(-seconds)
            }
            noteInteraction()
            showControlsBriefly()
        } label: {
            skipButton(seconds: seconds, isForward: isForward)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(isForward ? "快进 \(seconds) 秒" : "快退 \(seconds) 秒")
    }

    /// 两侧跳转钮：SF Symbols 自带数字的圆箭头（`gobackward.15` / `goforward.15`）。
    ///
    /// LP 2026-10-27 定：系统这套符号就是新 Apple 风格，不要再自己画环叠数字
    /// ——自绘的形状永远比系统旧。秒数跟设置里的「快进快退时长」走。
    private func skipButton(seconds: Int, isForward: Bool) -> some View {
        Image(systemName: isForward ? "goforward.\(seconds)" : "gobackward.\(seconds)")
            .font(.system(size: 28, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
    }

    /// 画面按压：短按切控制栏 / 播放暂停，长按临时倍速（对应原版
    /// `player_item.dart` 的 onLongPressStart / onLongPressEnd）。
    ///
    /// 用 `onLongPressGesture` 的 pressing 回调而不是两个手势叠加：
    /// 同一次按压只会走一条分支，长按松手不会再触发一次短按。
    /// 全屏开关：进横屏 + 隐藏状态栏；退出回竖屏（原版 `DisplayModeService` 也是
    /// 退出时显式回 portraitUp，而不是「系统默认」）。
    ///
    /// 方向请求走 `requestGeometryUpdate`，只影响本次会话，不改 Info.plist 里
    /// 声明的支持方向（竖屏/横屏本来都支持）。
    /// 全屏只有一种：横屏铺满（LP 2026-10-25，不做竖屏全屏）。
    /// 所以进入时先要横屏，退出时回竖屏；转回竖屏的那一下由布局兜底退出全屏，
    /// 免得留下一个「竖着也算全屏」的状态。
    private func toggleFullscreen() {
        if isFullscreen {
            exitFullscreen()
        } else {
            NSLog("[player] 进全屏")
            isFullscreen = true
            requestOrientation(.landscapeRight)
            // 系统真拒绝了横屏才退回来：等它一会儿再问，不是拿延时去赌界面状态。
            Task {
                try? await Task.sleep(for: .seconds(0.8))
                if isFullscreen, !sawLandscape {
                    NSLog("[player] 横屏请求没生效，退回竖屏")
                    exitFullscreen()
                }
            }
        }
        showControls()
        noteInteraction()
    }

    private func exitFullscreen() {
        guard isFullscreen else { return }
        NSLog("[player] 退全屏")
        isFullscreen = false
        sawLandscape = false
        requestOrientation(.portrait)
        showControls()
        syncHistoryWithWebDAV()
    }

    /// 原版 player_item.dart:374 / 458：退出全屏时把观看记录并一轮云盘。
    /// 只在「启用 WebDAV」和「观看记录」都开着时发，失败只进日志，不扰用户。
    private func syncHistoryWithWebDAV() {
        guard settings.webDavEnable, settings.webDavEnableHistory else { return }
        let settings = settings
        let library = environment.library
        Task {
            let outcome = await WebDAVSync.sync([.history], settings: settings, library: library)
            KazumiLogBuffer.network(outcome.log)
        }
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        // 让 `supportedInterfaceOrientations` 跟着变，否则请求会被忽略。
        OrientationLock.mask = mask
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    /// 双击：中间三分之二是播放 / 暂停，左右两侧分别是快退与快进（秒数走设置，
    /// 默认 15 秒）。三种都让控制层浮出来 1.2 秒再淡出，是 iOS 自己的节奏。
    /// 双击画面：任何位置都是播放 / 暂停。
    ///
    /// 以前是左三分之一快退、右三分之一快进、中间播放暂停（照原版
    /// `player_item.dart` 的 `_handleDoubleTap` 其实也只是播放暂停，
    /// 两侧快进是我们自己加的）。LP 3593：两侧的快进快退改由画面左右那两颗按钮做，
    /// 双击就只留播放暂停，点哪儿都一样。
    private func handleSurfaceDoubleTap() {
        surface.togglePlay()
        flashPlayPauseHUD()
        showControlsBriefly()
    }

    /// 控制层浮出来 1.2 秒再淡出；暂停状态保持显示，方便接着操作。
    private func showControlsBriefly() {
        showControls()
        // 先作废按设置计时的那一条，免得两套计时同时跑。
        hideGeneration &+= 1
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, surface.isPlaying else { return }
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        }
    }

    /// 点画面只切控制层显示（原版：短按显隐，不暂停）；播放/暂停在播放键上。
    private func handleSurfaceTap() {
        // 长按刚松手时系统会补一次短按，挡掉，别把控制层又切一遍。
        if let longPressAt = lastLongPressAt, Date().timeIntervalSince(longPressAt) < 0.4 {
            lastLongPressAt = nil
            return
        }
        // 弹幕输入框还开着时，点空白先收键盘，不动控制栏（Colo 2026-10-27）。
        if danmakuFieldFocused {
            danmakuFieldFocused = false
            return
        }
        if controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) {
                controlsVisible = false
            }
        } else {
            showControls()
        }
    }

    /// 长按临时加速：原版按住期间用 `defaultShortcutForwardPlaySpeed`（默认 2.0），
    /// 松手恢复按下前的速度，不写回设置。
    private func beginTemporarySpeed() {
        // 长按中再按一次也重新记起点，避免上一次手势被系统取消后卡在 2x。
        isTemporarySpeed = true
        rateBeforeTemporarySpeed = playbackRate
        surface.setPlaybackRate(Float(settings.longPressSpeed))
    }

    private func endTemporarySpeed() {
        guard isTemporarySpeed else { return }
        isTemporarySpeed = false
        surface.setPlaybackRate(rateBeforeTemporarySpeed)
    }

    // MARK: - 控制栏自动隐藏

    private var canHideControls: Bool {
        controlsVisible && surface.isPlaying && !isScrubbing && !isEditingSkipSeconds
            && activeSheet == nil && !menuOpen
    }

    /// 从菜单里开页面：菜单自己还要收一下，同一拍里改 presentation 会被吞掉，
    /// 所以等一拍再开（「更多里的选项点了没反应」里的一半）。
    /// 收起键盘：弹幕设置里有输入框，右上角那颗关闭要先把键盘收掉再关弹窗，
    /// 不然键盘会留在屏上下次进来还弹着（Colo 2026-10-27）。
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func openSheet(_ sheet: PlayerSheet) {
        showControls()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            activeSheet = sheet
        }
    }

    /// 音频会话：只有「后台播放」开着才要 .playback（熄屏、切出后台继续出声）；
    /// 关着就退回默认，免得静音键不起作用。
    private func applyAudioSessionPolicy() {
        let session = AVAudioSession.sharedInstance()
        if settings.backgroundPlayback {
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
            try? session.setActive(true)
        } else {
            try? session.setCategory(.soloAmbient, mode: .default, options: [])
        }
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

    /// 弹幕观感打包：设置页那几项 + 播放器自己的弹幕开关与当前倍速。
    /// 改成结构体是因为弹幕层要的项越来越多，一项一个参数会把调用点撑散。
    private var danmakuStyle: DanmakuOverlayView.Style {
        var style = DanmakuOverlayView.Style()
        style.enabled = danmakuEnabled
        style.opacity = settings.danmakuOpacity
        style.fontSize = settings.danmakuFontSize
        style.area = settings.danmakuArea
        style.duration = settings.danmakuDuration
        style.lineHeight = settings.danmakuLineHeight
        style.followSpeed = settings.danmakuFollowSpeed
        style.showTop = settings.danmakuTop
        style.showBottom = settings.danmakuBottom
        style.showScroll = settings.danmakuScroll
        style.massive = settings.danmakuMassive
        style.deduplication = settings.danmakuDeduplication
        style.showBiliBili = settings.danmakuBiliBiliSource
        style.showGamer = settings.danmakuGamerSource
        style.showDanDan = settings.danmakuDanDanSource
        style.border = settings.danmakuBorder
        style.borderSize = settings.danmakuBorderSize
        style.useColor = settings.danmakuColor
        style.fontWeight = settings.danmakuFontWeight
        return style
    }

    /// 黑底 + 视频画面（或解析中的状态）。拆出来是为了只在画面上挂手势，
    /// 不把顶栏按钮与错误遮罩的点击也当成「点画面暂停」。
    @ViewBuilder
    private func videoSurface(_ controller: PlayerController) -> some View {
        ZStack {
            Color.black

            if let text = controller.playbackURL, let url = URL(string: text) {
                MPVPlayerContainer(
                    url: url,
                    referer: controller.referer,
                    userAgent: controller.userAgent,
                    shaderPaths: settings.superResolutionMode.shaderPaths,
                    fillMode: aspectRatioMode.fillMode,
                    danmaku: controller.danmakuComments,
                    danmakuStyle: danmakuStyle,
                    danmakuPlaybackRate: Double(playbackRate),
                    // 横屏让开顶栏；竖屏顶栏压在画面上，保持原样。
                    danmakuTopInset: isFullscreen ? 44 : 0,
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
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlayerPressStyle())
            .accessibilityLabel("返回")

            // main 竖屏顶栏不放标题（标题在画面下面那块），这里只留出 40 高，
            // 免得后面几颗按钮被顶到左边（Colo 3599）。
            Spacer(minLength: 40)

            // 横屏底栏已经有弹幕开关，顶栏这颗藏起来，不然两个开关
            // （LP 2026-10-27）。竖屏没有底栏开关，照旧留着。
            if !isFullscreen {
                danmakuButton()
            }
            collectButton
            skipForwardButton
            moreMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// 收藏钮（LP 2026-10-28「顶栏收藏按钮改加号，收藏了才是实心」／Colo 3926、3929）：
    /// 未收藏是 `plus`、收藏了是实心 `heart.fill`，一律白色 20pt——播放器里不用主题色，
    /// 靠实心与否区分，不靠颜色。
    ///
    /// 点一下就在「在看」和「未追」之间切，带一次轻震动和 0.15 秒的 spring 缩放。
    /// 挑具体状态（想看／搁置／看过／抛弃）的门挪到「更多 → 追番状态」，
    /// 原来是点这颗弹菜单，改成切换后留个长按菜单会和「点一下」抢手势。
    private var collectButton: some View {
        Button {
            PlayerHaptics.tap()
            bounceCollect()
            noteInteraction()
            applyCollectType(currentCollectType == .none ? .watching : .none)
        } label: {
            Image(systemName: currentCollectType == .none ? "plus" : "heart.fill")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
        .scaleEffect(collectScale)
        .accessibilityLabel(currentCollectType == .none ? "收藏" : "已追番")
        .accessibilityValue(currentCollectType.title)
        .accessibilityHint("轻点切换收藏，更多里可以选追番状态")
    }

    /// 收藏钮按下去的弹一下：先缩到 0.85，再用 spring 回到 1，前后共 0.15 秒。
    private func bounceCollect() {
        withAnimation(.easeInOut(duration: 0.05)) { collectScale = 0.85 }
        withAnimation(.spring(response: 0.15, dampingFraction: 0.6).delay(0.05)) { collectScale = 1 }
    }

    /// 这部番现在的收藏状态（收藏库里没有就是未收藏）。
    private var currentCollectType: CollectType {
        CollectType(rawValue: environment.library.entry(for: bangumiID)?.type ?? 0) ?? .none
    }

    /// 改收藏状态：先写回 Bangumi，成功了才动本地收藏库；
    /// 没登录时写不进去，就在画面上说一句，不假装改过。
    private func applyCollectType(_ type: CollectType) {
        guard type != currentCollectType else { return }
        noteInteraction()
        // 口径照 collect_controller.dart 的 _syncBangumiCollectIfEnabled：
        // 只有「自动同步追番」开着才推给 Bangumi；没开就是纯本地改动。
        // 推失败时这次修改整体作废 —— 本地显示「已看过」而 Bangumi 上还是「在看」，
        // 比没改更让人糊涂（原版同样是回滚 + 一句失败提示）。
        let syncEnabled = settings.bangumiSyncEnable
        let showToast = settings.bangumiImmediateSyncToastEnable
        Task {
            if syncEnabled {
                if showToast { surface.toastMessage = "正在同步到 Bangumi..." }
                let pushed = await environment.bangumiSync.pushCollectible(
                    bangumiID: bangumiID,
                    type: type
                )
                guard pushed else {
                    surface.toastMessage = "同步到 Bangumi 失败，已取消本次状态修改"
                    return
                }
            }
            if var entry = environment.library.entry(for: bangumiID) {
                entry.type = type.rawValue
                entry.updatedAt = Date()
                environment.library.upsert(entry)
            }
            if syncEnabled, showToast {
                surface.toastMessage = "已同步到 Bangumi"
            } else {
                surface.toastMessage = type == .none ? "已取消追番" : "已标为\(type.title)"
            }
        }
    }

    /// 定时关闭的菜单标题：定上了就把分钟数写在上面。
    private var sleepTimerTitle: String {
        if let minutes = sleepTimerMinutes { return "定时关闭（\(minutes) 分钟）" }
        return "定时关闭"
    }

    /// 面板右边那行字：没开写「不开启」，开着写还剩几分钟（每分钟自己走）。
    private var sleepTimerValue: String {
        guard let minutes = sleepTimerMinutes else { return "不开启" }
        return "还剩 \(minutes) 分钟"
    }

    private var sleepTimerMinutes: Int? {
        guard let remaining = sleepTimerRemaining else { return nil }
        return max(1, Int((Double(remaining) / 60).rounded(.up)))
    }

    /// 到点暂停。定时器是一次性的 Task，改定或取消都要把上一个收掉。
    private func startSleepTimer(minutes: Int) {
        noteInteraction()
        sleepTimerTask?.cancel()
        sleepTimerRemaining = minutes * 60
        let target = minutes * 60
        sleepTimerTask = Task { @MainActor in
            var left = target
            while left > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                left -= 1
                sleepTimerRemaining = left
            }
            sleepTimerRemaining = nil
            surface.pause()
            surface.toastMessage = "定时关闭：已暂停"
            showControls()
        }
        surface.toastMessage = "定时关闭：\(minutes) 分钟后暂停"
    }

    private func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerRemaining = nil
    }

    /// 远程投屏：把系统那粒 AirPlay 按钮摆出来，点它选设备。
    private var airPlaySheet: some View {
        VStack(spacing: 16) {
            Text("远程投屏")
                .font(.headline)
            Text("选一台支持隔空播放的设备，画面会转到那台电视上。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            AirPlayRoutePicker()
                .frame(width: 44, height: 44)
            Button("完成") { activeSheet = nil }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .presentationDetents([.height(240)])
    }

    /// 外部播放：把这一集的地址交给系统分享面板，装了 VLC、Infuse 这类播放器就能在那里打开。
    @ViewBuilder
    private var externalPlaySheet: some View {
        if let urlString = controllerURLString, let url = URL(string: urlString) {
            ShareSheet(items: [url])
                .presentationDetents([.medium, .large])
        } else {
            ContentUnavailableView("还没有解析出地址", systemImage: "play.slash")
                .presentationDetents([.height(200)])
        }
    }

    /// 播放信息：这一集文件的实际编码规格 + 媒体地址，只读。
    /// 值从 mpv 现读，拿不到的项写「—」；深浅色跟着主题走。
    private var videoInfoSheet: some View {
        let info = surface.playbackInfo()
        let mediaURL = controllerURLString
        let rows: [(title: String, value: String)] = [
            ("视频编码", info?.videoCodec ?? "—"),
            ("分辨率", info?.resolution ?? "—"),
            ("帧率", info?.frameRate ?? "—"),
            ("码率", info?.videoBitrate ?? "—"),
            ("音频编码", info?.audioCodec ?? "—"),
            ("声道", info?.audioChannels ?? "—"),
            ("采样率", info?.sampleRate ?? "—"),
            ("容器", info?.container ?? "—"),
        ]
        return VStack(spacing: 0) {
            ZStack {
                Text("播放信息")
                    .font(.headline)
                HStack {
                    Spacer()
                    Button("完成") { activeSheet = nil }
                        .font(.subheadline)
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 16)
                        }
                        infoRow(rows[index])
                    }
                    Divider()
                        .padding(.leading, 16)
                    mediaURLRow(mediaURL)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .onDisappear {
            // 关掉时把「已复制」与定时器收干净，下次打开不带着上一次的状态。
            mediaURLCopiedTask?.cancel()
            mediaURLCopied = false
        }
        .presentationDetents([.medium, .large])
    }

    /// 播放信息里的一条：左标题、右值。
    private func infoRow(_ row: (title: String, value: String)) -> some View {
        HStack(spacing: 16) {
            Text(row.title)
                .font(.system(size: 13))
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
            Spacer(minLength: 12)
            Text(row.value)
                .font(.system(size: 15).monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }

    /// 媒体地址：点一下复制完整地址；复制后右侧闪一下「已复制」并震一下。
    /// 屏上只显示一行、中间截断，长地址不会把排版撑破。
    private func mediaURLRow(_ urlString: String?) -> some View {
        Button {
            guard let urlString else { return }
            UIPasteboard.general.string = urlString
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            mediaURLCopied = true
            mediaURLCopiedTask?.cancel()
            mediaURLCopiedTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled else { return }
                mediaURLCopied = false
            }
        } label: {
            HStack(spacing: 16) {
                Text("媒体地址")
                    .font(.system(size: 13))
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                Spacer(minLength: 12)
                Text(mediaURLCopied ? "已复制" : (urlString ?? "—"))
                    .font(.system(size: 15).monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(
                        mediaURLCopied
                            ? KazumiPalette.accent(for: colorScheme)
                            : Color.primary
                    )
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(urlString == nil)
        .accessibilityLabel("媒体地址")
        .accessibilityValue(mediaURLCopied ? "已复制" : (urlString ?? "不可用"))
        .accessibilityHint("点按复制完整地址")
    }

    /// 片头片尾弹窗的右边距：横屏离窗口右缘 90，竖屏 20（跟 main 一致）。
    private var skipPillTrailingInset: CGFloat { isFullscreen ? 90 : 20 }

    /// 片头片尾弹窗的底边距：横屏固定（不随控制栏显隐），竖屏跟着控制栏走。
    private var skipPillBottomInset: CGFloat {
        isFullscreen
            ? containerInsets.bottom + 63
            : containerInsets.bottom + (controlsVisible ? 48 : 28)
    }

    /// 当前这一集的媒体地址（解析出来才有）。
    private var controllerURLString: String? {
        guard let text = controller?.playbackURL, !text.isEmpty else { return nil }
        return text
    }

    /// 弹幕开关：白符号直接压画面，不套底（工具行的第一格）。
    /// 弹幕开关。顶栏里是 44 见方，横屏那条输入行里矮一点（33），尺寸由外面给。
    private func danmakuButton(width: CGFloat = 44, height: CGFloat = 44) -> some View {
        Button {
            danmakuEnabled.toggle()
            noteInteraction()
        } label: {
            // 符号统一成 captions.bubble：开启用 .fill 表示（LP 2026-10-27 定，
            // 不用强调色），颜色一律白。尺寸 20pt，跟其余图标同一档。
            Image(systemName: danmakuEnabled ? "captions.bubble.fill" : "captions.bubble")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(danmakuEnabled ? "关闭弹幕" : "打开弹幕")
    }

    /// 弹幕设置的图标：`captions.bubble` 20pt 打底，右下角叠一颗 12pt 的
    /// `gearshape.fill`，圆心压在气泡外框的右下角上（Colo 2026-10-27）。
    /// 按钮用 SwiftUI 叠，系统菜单里用这张 UIImage——两边同一套尺寸。
    private nonisolated(unsafe) static var cachedDanmakuSettingsIcon: UIImage?

    private var danmakuSettingsIcon: UIImage {
        if let cached = Self.cachedDanmakuSettingsIcon { return cached }
        let rendered = Self.renderDanmakuSettingsIcon()
        Self.cachedDanmakuSettingsIcon = rendered
        return rendered
    }

    private static func renderDanmakuSettingsIcon() -> UIImage {
        // 菜单里那条要的是 UIImage，就把同一个 View 渲成图（Colo 2026-10-28）：
        // 一处写、两处引用，横屏底栏和「更多 → 弹幕设置」不会再走样。
        let renderer = ImageRenderer(content: DanmakuSettingsGlyph())
        renderer.scale = 3
        return renderer.uiImage ?? UIImage()
    }

    /// 弹幕设置：同一颗 `captions.bubble` 打底，右下角叠一颗小齿轮——
    /// 两个符号占一个符号位，命中仍是 44×44（LP 2026-10-27）。
    private func danmakuSettingsButton() -> some View {
        Button {
            openSheet(.danmakuSettings)
        } label: {
            // 跟「更多 → 弹幕设置」那条用同一张图：一份实现画出来，两边不可能再走样
            // （LP 2026-10-28「横屏和竖屏更多菜单的要一起改，不要只改一个」）。
            DanmakuSettingsGlyph()
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel("弹幕设置")
    }

    /// 「更多」：只剩点一下就有反应、没有二级的项。
    ///
    /// 用系统 `Menu`：玻璃、行高、宽度、箭头全由系统画——LP 要的就是原来那颗
    /// 系统菜单的观感，自绘只能做到八分像。带二级的那三项（超分辨率、画面比例、
    /// 睡眠定时）拿出去，收在「播放选项」里（Colo / Ato 2026-10-25）。
    ///
    /// 菜单不把开合告诉代码，控制层的自动隐藏靠 `SystemMenuProbe` 看菜单在不在，
    /// 在就不收层。
    /// 「更多」：点一下弹系统菜单（LP 2269「点错了，还是点击」）。
    ///
    /// 用 UIKit 的按钮菜单而不是 SwiftUI 的 `Menu`：画面每秒刷新，`Menu` 会跟着重建，
    /// 弹出来的那一份和手上的视图对不上，选项点了没反应（LP 2026-10-25「还是无法点击」）。
    private var moreMenu: some View {
        SystemMenuButton(
            items: moreMenuItems,
            title: nil,
            symbol: "ellipsis",
            accessibilityLabel: "更多选项",
            onOpen: { pinControlsWhileMenuOpen() }
        )
        .frame(width: 44, height: 44)
    }

    private var moreMenuItems: [SystemMenuButton.Item] {
        // 弹幕设置：横屏底栏有直接入口，这里那条就删掉（同一件事不留两个门）；
        // 竖屏没底栏，入口留在这儿，图标跟横屏那颗同一套（Colo 2026-10-27）。
        var items: [SystemMenuButton.Item] = []
        if !isFullscreen {
            items.append(
                SystemMenuButton.Item(
                    title: "弹幕设置",
                    symbol: "captions.bubble",
                    symbolImage: danmakuSettingsIcon
                ) {
                    closeMenu()
                    openSheet(.danmakuSettings)
                }
            )
        }
        return items + [
            // 倍速从底栏收进这里（LP 3593：底栏单行）。右边小字写当前值。
            SystemMenuButton.Item(
                title: "倍速",
                symbol: "speedometer",
                subtitle: speedText(Double(playbackRate)),
                submenu: PlaybackSpeed.all.map { rate in
                    SystemMenuButton.Item(
                        title: speedText(rate),
                        symbol: abs(playbackRate - Float(rate)) < 0.01 ? "checkmark" : ""
                    ) {
                        applySpeed(Float(rate))
                        noteInteraction()
                    }
                }
            ) {},
            SystemMenuButton.Item(
                title: "追番状态",
                symbol: "heart",
                subtitle: currentCollectType.title,
                submenu: collectStatusItems
            ) {},
            SystemMenuButton.Item(title: "播放信息", symbol: "info.circle") {
                closeMenu()
                openSheet(.videoInfo)
            },
            SystemMenuButton.Item(title: "远程投屏", symbol: "airplayvideo") {
                closeMenu()
                openSheet(.airPlay)
            },
            SystemMenuButton.Item(title: "外部播放", symbol: "arrow.up.forward.app") {
                closeMenu()
                openSheet(.externalPlay)
            },
            SystemMenuButton.Item(title: "一起看", symbol: "person.2.wave.2") {
                closeMenu()
                openSheet(.syncPlay)
            },
            SystemMenuButton.Item(
                title: "视频比例",
                symbol: "rectangle.arrowtriangle.2.outward",
                subtitle: aspectRatioMode.label,
                submenu: PlayerAspectRatioMode.allCases.map { mode in
                    SystemMenuButton.Item(
                        title: mode.label,
                        symbol: aspectRatioMode == mode ? "checkmark" : ""
                    ) {
                        aspectRatioMode = mode
                    }
                }
            ) {},
            // 超分辨率从横屏底栏收进这里（横屏那行放不下十颗，Colo 3613）。
            SystemMenuButton.Item(
                title: "超分辨率",
                symbol: "wand.and.stars",
                subtitle: settings.superResolutionMode.title,
                submenu: SuperResolutionMode.allCases.map { mode in
                    SystemMenuButton.Item(
                        title: mode.title,
                        symbol: settings.superResolutionMode == mode ? "checkmark" : "",
                        subtitle: mode.detail
                    ) {
                        settings.superResolutionMode = mode
                        noteInteraction()
                    }
                }
            ) {},
            SystemMenuButton.Item(
                title: "定时关闭",
                symbol: "moon.zzz",
                subtitle: sleepTimerValue,
                submenu: [SystemMenuButton.Item(title: "不开启", symbol: sleepTimerRemaining == nil ? "checkmark" : "") {
                    cancelSleepTimer()
                }] + [15, 30, 60, 90].map { minutes in
                    SystemMenuButton.Item(
                        title: "\(minutes) 分钟",
                        symbol: sleepTimerRemaining == minutes * 60 ? "checkmark" : ""
                    ) {
                        startSleepTimer(minutes: minutes)
                    }
                }
            ) {},
        ]
    }

    /// 「更多 → 追番状态」的子菜单：五项状态 + 取消追番，勾在现在这一项上。
    private var collectStatusItems: [SystemMenuButton.Item] {
        var items = CollectType.enabledCases.map { type in
            SystemMenuButton.Item(
                title: type.buttonTitle,
                symbol: currentCollectType == type ? "checkmark" : type.statusSymbol
            ) {
                noteInteraction()
                applyCollectType(type)
            }
        }
        if currentCollectType != .none {
            items.append(
                SystemMenuButton.Item(title: "取消追番", symbol: "heart.slash", isDestructive: true) {
                    noteInteraction()
                    applyCollectType(.none)
                }
            )
        }
        return items
    }

    /// 菜单弹出来了：控制栏先别收。
    ///
    /// 系统菜单是挂在弹出它的那颗按钮上的。控制栏一收，按钮就被关掉点击，
    /// 菜单还留在屏幕上但点谁都没主（LP 2026-10-25「能打开还是无法点击」）。
    private func pinControlsWhileMenuOpen() {
        showControls()
        menuOpen = true
        probeSawMenu = false
        menuOpenedAt = Date()
        probeLastSeen = Date()
        // 已经排上的收层计时作废，等菜单关了重新起算。
        hideGeneration &+= 1
    }

    /// 菜单里点了一项：菜单这就收了，控制栏可以照常计时。
    private func closeMenu() {
        menuOpen = false
        probeSawMenu = false
    }

    /// 顶部快进按钮：单击快进，长按修改秒数（对应原版 player_item_panel 的快进按钮）。
    private var skipForwardButton: some View {
        HStack(spacing: 4) {
            Image(systemName: "goforward")
                .font(.system(size: 17, weight: .regular))
            // Camo 3523：原来写的是 `10s`，英文单位。整屏都是中文，
            // 改成「10 秒」，跟设置里那行「跳过时长…秒」一个说法。
            Text("\(settings.buttonSkipTime) 秒")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
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
            case .failed:
                // 失败提示不压在画面正中间：挪到下面「选集」那一块里
                // （平时列剧集的位置），跟页面一起推进来（LP 3286 / Colo 3287）。
                EmptyView()
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
        case .resolvingChapters: "正在加载剧集列表…"
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

    /// 播放条：一条，压在画面底部。播放键、进度、时间、倍速、全屏。
    /// 倍速从「更多」里提上来——它是这一轮要的常动作，且 3× 以前根本选不到。
    /// 底栏。竖屏单行（播放/暂停｜进度条｜当前 / 总长｜全屏）；
    /// 横屏两行（Colo 3613，照 main 非 compact）：时间在上、进度条一行，按钮一行。
    private func transportBar(_ controller: PlayerController, width: CGFloat) -> some View {
        Group {
            // 全屏就是横屏（竖屏那颗全屏键是唯一入口），直接看它，
            // 不等量出来的宽度——初值 0 会先画一帧单行再跳成两行（Colo 3627）。
            if isFullscreen || width >= 600 {
                landscapeTransport(controller)
            } else {
                portraitTransport
            }
        }
    }

    private var portraitTransport: some View {
        HStack(spacing: 8) {
            playPauseButton(size: 44)
            scrubber
            timeLabel
            fullscreenButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(height: 52)
    }

    /// 横屏：时间文字在进度条上方（左 10、下 10），进度条左右各 10，
    /// 再下面一行按钮（左右各 10）。按钮行按 Colo 3613 的精简版：手机横屏放不下十颗。
    private func landscapeTransport(_ controller: PlayerController) -> some View {
        VStack(spacing: 0) {
            timeLabel
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
                .padding(.bottom, 8)

            scrubber
                .padding(.horizontal, 16)

            HStack(spacing: 8) {
                playPauseButton(size: 44)
                nextEpisodeButton(controller, size: 44)
                danmakuButton(width: 44, height: 44)
                // 横屏两棵弹幕键并排：开关 + 设置（LP 2026-10-27）。
                danmakuSettingsButton()
                danmakuField
                    .frame(maxWidth: .infinity)
                speedButton
                episodesButton
                fullscreenButton
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
        }
        .padding(.bottom, 12)
    }

    /// `当前 / 总长`，12 号白色、等宽数字，长短不变不跳（竖屏在进度条右边）。
    private var timeLabel: some View {
        Text("\(timeText(isScrubbing ? scrubValue : surface.currentTime)) / \(timeText(surface.duration))")
            .font(.system(size: 12, weight: .regular).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
    }

    private func playPauseButton(size: CGFloat) -> some View {
        Button {
            surface.togglePlay()
            noteInteraction()
        } label: {
            Image(systemName: surface.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(surface.isPlaying ? "暂停" : "播放")
    }

    private var fullscreenButton: some View {
        Button {
            toggleFullscreen()
        } label: {
            // 符号跟着当前状态走：进全屏是放大，退出是全屏箭头收回。
            Image(systemName: isFullscreen
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(isFullscreen ? "退出全屏" : "全屏")
    }

    /// 下一集：没有下一集时灰掉。
    private func nextEpisodeButton(_ controller: PlayerController, size: CGFloat) -> some View {
        let hasNext = controller.currentEpisode < controller.episodes.count
        return Button {
            guard hasNext else { return }
            noteInteraction()
            Task { await controller.selectEpisode(controller.currentEpisode + 1) }
        } label: {
            Image(systemName: "forward.end.fill")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white.opacity(hasNext ? 1 : 0.35))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
        .disabled(!hasNext)
        .accessibilityLabel("下一集")
    }

    /// 横屏那颗倍速：标签写当前值（竖屏在「更多」菜单里）。
    private var speedButton: some View {
        SystemMenuButton(
            items: PlaybackSpeed.all.map { rate in
                SystemMenuButton.Item(
                    title: speedText(rate),
                    symbol: abs(playbackRate - Float(rate)) < 0.01 ? "checkmark" : ""
                ) {
                    applySpeed(Float(rate))
                    noteInteraction()
                }
            },
            title: speedText(Double(playbackRate)),
            symbol: "speedometer",
            accessibilityLabel: "倍速 \(speedText(Double(playbackRate)))",
            onOpen: { pinControlsWhileMenuOpen() }
        )
        .frame(minWidth: 44, minHeight: 40)
    }

    private var episodesButton: some View {
        Button {
            // 再点一次收起（Colo §7）。
            if showsEpisodesPanel {
                closeEpisodesPanel()
            } else {
                openEpisodesPanel()
            }
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel("选集")
    }

    /// 横屏选集：从右侧滑进来的玻璃窗口（LP 3637）。
    /// 复用竖屏那块 `episodesPane`，所以 100 集以上的分块跳转、线路菜单、
    /// 加载失败态都是同一套；打开时把在播那集滚到中间（LP 3640）。
    private func episodesPanel(_ controller: PlayerController) -> some View {
        // 宽度照 Colo §7：可用宽的九成封顶，常态取三分之一，手机横屏 844 落地就是 320。
        let available = max(surfaceWidth, 360)
        let panelWidth = min(available * 0.9, min(max(available / 3, 320), 420))
        return episodesPane(controller, centersCurrentEpisode: true)
            .frame(width: panelWidth)
            .frame(maxHeight: .infinity)
            // 玻璃压在视频上，内容一律按深色排：白字、深底格子，
            // 浅色下那套白底黑字在这儿糊成一团。
            .environment(\.colorScheme, .dark)
            .background { GlassBackdrop() }
            // 只有左边两个角是圆的，右边贴着屏边（Colo §7：32）。
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 32,
                    bottomLeadingRadius: 32,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
            )
            .ignoresSafeArea(edges: .vertical)
    }

    private func openEpisodesPanel() {
        showControls()
        // 面板开着的时候控制层不许自己收走，不然底栏先没了、面板还挂着。
        pinControlsWhileMenuOpen()
        withAnimation(.easeOut(duration: 0.12)) {
            showsEpisodesPanel = true
        }
    }

    private func closeEpisodesPanel() {
        withAnimation(.easeOut(duration: 0.12)) {
            showsEpisodesPanel = false
        }
        closeMenu()
    }

    /// 横屏底栏里的发弹幕：白 38% 底、圆角、13 号、hint 照原版，右边一颗「发送」。
    /// 弹幕关着时整个框灰掉并挡住输入——发了也看不见，不如先说清楚。
    private var danmakuField: some View {
        HStack(spacing: 6) {
            TextField(
                "",
                text: $danmakuDraft,
                prompt: Text("发个友善的弹幕见证当下")
                    .foregroundStyle(.white.opacity(0.7))
            )
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .tint(.white)
            .focused($danmakuFieldFocused)
            .submitLabel(.send)
            .onSubmit { sendDanmaku() }
            .disabled(!danmakuEnabled)

            Button {
                sendDanmaku()
            } label: {
                Text("发送")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(canSendDanmaku ? .white : .white.opacity(0.45))
                    .padding(.horizontal, 6)
                    .frame(height: 33)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlayerPressStyle())
            .disabled(!canSendDanmaku)
            .accessibilityLabel("发送弹幕")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 33)
        .background(.white.opacity(danmakuEnabled ? 0.38 : 0.18),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var canSendDanmaku: Bool {
        danmakuEnabled && !danmakuDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 发出去：只在本地画布上补一条（原版 `_sendDanmaku` 也不调接口），清空、收键盘。
    private func sendDanmaku() {
        let text = danmakuDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard danmakuEnabled, !text.isEmpty else { return }
        surface.danmakuOverlay?.sendLocal(text: text)
        danmakuDraft = ""
        danmakuFieldFocused = false
        noteInteraction()
        showControlsBriefly()
    }

    /// 进度条：交给系统 `Slider`（原生轨道与拇指），不再自绘。
    /// 拖动中读本地 `scrubValue` 预览，松手才真 seek——画面不跟着每一帧抖。
    /// 进度条：只有轨道，没有拇指。未播白 30%、已播纯白，靠色差看进度
    /// （LP 2026-10-27「胶囊白块除了占空毫无意义」）。交互不删：整条 44 高都能拖。
    private var scrubber: some View {
        let total = max(surface.duration, 0.001)
        let current = min(max(isScrubbing ? scrubValue : surface.currentTime, 0), total)
        let progress = total > 0 ? min(max(current / total, 0), 1) : 0
        return GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: 4)
                Capsule()
                    .fill(.white)
                    .frame(width: width * progress, height: 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing { onScrub(true) }
                        let ratio = min(max(value.location.x / width, 0), 1)
                        scrubValue = Double(ratio) * total
                    }
                    .onEnded { _ in onScrub(false) }
            )
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue(timeText(current))
    }

    private func speedText(_ value: Double) -> String { PlaybackSpeed.label(value) }

    private func applySpeed(_ rate: Float) {
        playbackRate = rate
        surface.setPlaybackRate(rate)
        surface.toastMessage = PlaybackSpeed.label(Double(rate))
    }

    private func onScrub(_ editing: Bool) {
        if editing {
            scrubValue = surface.currentTime
            isScrubbing = true
        } else {
            surface.seek(to: scrubValue)
            isScrubbing = false
        }
        PlayerHaptics.tap()
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
    /// 退出播放器时同步观看记录——只在多设备同步开着、且「观看记录」这一类打开时才发请求。
    private func syncHistoryIfNeeded() {
        guard settings.webDavEnable,
              settings.webDavEnableHistory,
              !settings.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let settings = settings
        let library = environment.library
        Task { _ = await WebDAVSync.sync([.history], settings: settings, library: library) }
    }

    private func persistProgress(_ controller: PlayerController) {
        persistWatchProgress(
            library: environment.library,
            privateMode: settings.privateMode,
            controller: controller,
            position: surface.currentTime,
            duration: surface.duration
        )
        // 「自动标记看过」的消费端：看到 90% 就在 Bangumi 上把这集标成看过。
        // 隐身模式不标 —— 用户按下隐身就是不想在服务器留下痕迹。
        guard !settings.privateMode else { return }
        environment.bangumiProgress.onPosition(
            subjectID: controller.bangumiID,
            episodeNumber: controller.currentEpisode,
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

    /// 竖滑浮层：亮度仍是小胶囊（`sun.max` + 系统玻璃）；
    /// 音量交给系统的 `MPVolumeView`，不再自绘第二条滑杆。
    @ViewBuilder
    private func gestureOverlay(_ hud: GestureHUDValue) -> some View {
        HStack(spacing: 10) {
            Image(systemName: hud.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))

            switch hud.kind {
            case .volume:
                // 系统音量滑杆：样式、拖动都是 iOS 自己的。
                SystemVolumeSlider()
                    .frame(width: 148, height: 28)
            case .brightness:
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule()
                        .fill(.white)
                        .frame(width: 148 * max(0, min(1, hud.value)))
                }
                .frame(width: 148, height: 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // HUD 胶囊吃系统玻璃底，亮画面上也读得清。
        .playerGlass(in: Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// 横滑 / 两侧跳转的秒数：玻璃胶囊，1.2 秒后自己淡出。
    private func seekOverlay(_ seconds: Int) -> some View {
        Text(seconds > 0 ? "+\(seconds)s" : "\(seconds)s")
            .font(.system(size: 20, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .playerGlass(in: Capsule(style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// 双击中间那朵播放 / 暂停。
    private func playPauseOverlay(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 1)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// 双击两侧：闪一下秒数。
    private func flashSeekHUD(_ seconds: Int) {
        withAnimation(.easeOut(duration: 0.2)) {
            gestureHUD = nil
            playPauseHUD = nil
            seekHUD = seconds
        }
        scheduleHUDHide(after: 1.2)
    }

    /// 双击中间：把刚切过去的状态画出来。暂停着就一直留着，播起来才淡出。
    /// 符号和左下角那颗读同一个状态：在播画 pause.fill（可以按它暂停），
    /// 暂停画 play.fill——两处不一致就是这里写反了（LP 2174）。
    private func flashPlayPauseHUD() {
        withAnimation(.easeOut(duration: 0.2)) {
            gestureHUD = nil
            seekHUD = nil
            playPauseHUD = surface.isPlaying ? "pause.fill" : "play.fill"
        }
        scheduleHUDHide()
    }

    /// 手指离开后淡出（默认 0.6 秒），0.2 秒 easeOut；三朵浮层共用这一个定时器。
    private func scheduleHUDHide(after seconds: Double = 0.6) {
        hudHideTask?.cancel()
        hudHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            // 暂停时那朵播放键留着，直到重新播起来。
            if playPauseHUD != nil, !surface.isPlaying { return }
            withAnimation(.easeOut(duration: 0.2)) {
                gestureHUD = nil
                seekHUD = nil
                playPauseHUD = nil
            }
        }
    }

    /// 长按加速的浮层：顶部正中一颗胶囊，写当前倍数。
    private var temporarySpeedCapsule: some View {
        Text(PlaybackSpeed.label(Double(surface.desiredRate)))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(.black.opacity(0.6)))
            .allowsHitTesting(false)
    }

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

    // MARK: - 选集与评论

    /// 画面下面这一片：上面两个页（选集 / 评论），下面是对应内容。
    /// 对应原版 video_page 的「选集 / 评论」两页。
    private func episodeArea(_ controller: PlayerController) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $detailTab) {
                ForEach(PlayerDetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .onChange(of: detailTab) { _, tab in
                if tab == .comments {
                    ensureDefaultCommentEpisode(controller)
                    loadCommentsIfNeeded()
                }
            }
            .onChange(of: isCommentsAscending) { _, _ in applyCommentsSort() }

            switch detailTab {
            case .episodes:
                episodesPane(controller)
            case .comments:
                commentsPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    /// 剧集没能加载时，这句话和「重试」就放在平时列剧集的位置（LP 3286 / Colo 3287）。
    /// 「返回选源」先留着：用户还能退回去挑别的来源。
    private func episodeFailure(_ message: String, controller: PlayerController) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button("重试") {
                    Task { await controller.retry() }
                }
                .buttonStyle(.borderedProminent)

                Button("返回选源") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func episodesPane(
        _ controller: PlayerController,
        centersCurrentEpisode: Bool = false
    ) -> some View {
        let total = controller.episodes.count
        let pageSize = 100
        let pages = max(1, (total + pageSize - 1) / pageSize)
        let currentPage = min(episodeGridPage, max(0, pages - 1))
        let lo = currentPage * pageSize
        let hi = min(total, lo + pageSize)

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // 只有一条线路也把它写出来（LP 3641）：以前整个藏起来，
                // 用户不知道现在走的是哪条。来源给了名字就照抄，没给才写「线路1」。
                if controller.roads.count > 1 {
                    roadMenu(controller)
                } else {
                    Text(Self.singleRoadTitle(controller.roads.first))
                        .font(.subheadline)
                        .frame(height: 44)
                }
                if pages > 1 {
                    SystemMenuButton(
                        items: (0 ..< pages).map { page in
                            let a = page * pageSize + 1
                            let b = min(total, (page + 1) * pageSize)
                            return SystemMenuButton.Item(title: "\(a)–\(b) 话", symbol: "") {
                                episodeGridPage = page
                            }
                        },
                        title: "\(lo + 1)–\(hi) 话",
                        symbol: "",
                        accessibilityLabel: "快速跳转，现在显示第 \(lo + 1) 到 \(hi) 话",
                        tint: KazumiPalette.accent(for: colorScheme),
                        showsChevron: true
                    )
                    .frame(height: 44)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)

            if case .failed(let message) = controller.phase {
                episodeFailure(message, controller: controller)
            } else if total == 0 {
                Text("暂无选集")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 64), spacing: 10)],
                            spacing: 10
                        ) {
                            ForEach(lo ..< hi, id: \.self) { index in
                                Button {
                                    switchEpisode(to: index + 1, controller: controller)
                                } label: {
                                    episodeGridCell(controller, index: index)
                                }
                                .buttonStyle(PlayerPressStyle())
                                .id(index)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .onAppear {
                        // 右侧面板打开时把在播那集滚到中间（LP 3640）。
                        // 等一帧再滚：LazyVGrid 那一刻还没把那一格建出来。
                        guard centersCurrentEpisode, total > 0 else { return }
                        let target = max(0, min(total - 1, controller.currentEpisode - 1))
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(80))
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }
        }
        // 铺满并靠左：VStack 默认把没铺满的子视图摆到中间，线路按钮那一行
        // 就会被摆到屏幕中间（LP 3389 / Colo 3390）。
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // 进来就把当前集那一块翻出来，不用用户再去找
            if total > 0 {
                let page = max(0, (controller.currentEpisode - 1) / pageSize)
                episodeGridPage = page
            }
        }
    }

    /// 网格里一格：当前集用主题色底与白字，其余白底。
    private func episodeGridCell(_ controller: PlayerController, index: Int) -> some View {
        let number = index + 1
        let isCurrent = number == controller.currentEpisode
        return Text("\(number)")
            .font(.subheadline.monospacedDigit().weight(isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isCurrent ? Color.accentColor : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isCurrent ? Color.clear : Color(.separator), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
    }

    /// 评论页：默认当集（无整部番），条数居中只读；左右两颗都是 44 高的按钮。
    @ViewBuilder
    private var commentsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // 左：当前集（默认当集，不再提供「整部番」）
                // 也用 UIKit 菜单：播放中视图每秒重建，SwiftUI 的 Menu 弹出来的是旧的那份、
                // 点了不执行（LP 3321「剧集和评论下边的都换了吗」）。
                SystemMenuButton(
                    items: commentEpisodeItems(),
                    title: commentEpisode.map { "第 \($0) 话" } ?? "第 — 话",
                    symbol: "",
                    accessibilityLabel: commentEpisode.map { "当前查看第 \($0) 话评论" } ?? "当前查看集数评论",
                    tint: KazumiPalette.accent(for: colorScheme),
                    showsChevron: true
                )
                .frame(height: 44)
                Spacer(minLength: 8)
                // 中：只读条数文案
                Text(commentTotal == 0 ? "还没有人评论" : "共 \(commentTotal) 条评论")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer(minLength: 8)
                // 右：排序（按钮上直接写当前排序方式） + 刷新
                SystemMenuButton(
                    items: [
                        SystemMenuButton.Item(
                            title: "最新优先",
                            symbol: isCommentsAscending ? "" : "checkmark"
                        ) {
                            if isCommentsAscending { isCommentsAscending = false }
                            applyCommentsSort()
                        },
                        SystemMenuButton.Item(
                            title: "最早优先",
                            symbol: isCommentsAscending ? "checkmark" : ""
                        ) {
                            if !isCommentsAscending { isCommentsAscending = true }
                            applyCommentsSort()
                        }
                    ],
                    title: isCommentsAscending ? "最早优先" : "最新优先",
                    symbol: "",
                    accessibilityLabel: "评论排序",
                    tint: KazumiPalette.accent(for: colorScheme),
                    showsChevron: true
                )
                .frame(height: 44)
                Button {
                    Task { await reloadComments() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(isLoadingComments)
                .accessibilityLabel("刷新评论")
            }
            .padding(.horizontal, 16)
            .frame(height: 44)

            if isLoadingComments && comments.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在加载评论…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if comments.isEmpty {
                if commentLoadFailed {
                    VStack(spacing: 10) {
                        Text("评论暂时未能加载")
                            .font(.subheadline.weight(.medium))
                        Text("请检查网络后重试，或换一集看看。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("重新加载") { Task { await reloadComments() } }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("还没有人评论")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // 用 ScrollView 不用 List：展开回复时要喊列表滚一滚（Colo 3366），
                // List 不给滚。分隔线照原来 List 的留法，从左缩 16。
                ScrollViewReader { proxy in
                    ScrollView {
                        // 必须写 alignment: .leading：LazyVStack 默认居中，整条评论（连头像）
                        // 会被摆到屏幕中间（LP 3389 / Colo 3390）。
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(comments) { comment in
                                CommentRowView(
                                    comment: comment,
                                    rateText: comment.rate > 0 ? "★ \(comment.rate)" : nil,
                                    onExpand: { proxy.scrollTo(comment.id, anchor: .center) }
                                )
                                // 行自己也要铺满：不然行宽只到内容那么宽，还是会被居中。
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                                .id(comment.id)

                                Divider().padding(.leading, 16)
                            }
                            if commentTotal > comments.count {
                                Text("已显示 \(comments.count) / \(commentTotal) 条评论")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 10)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
        // 跟选集那块一样：铺满并靠左，头部那行才不会整体被摆到中间。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 换集菜单里的集数列表。
    @ViewBuilder
    /// 评论页左上那颗菜单的条目：每一集一条，当前这集打勾。
    private func commentEpisodeItems() -> [SystemMenuButton.Item] {
        let total = controller?.episodes.count ?? 0
        guard total > 0 else { return [] }
        return (1 ... total).map { ep in
            SystemMenuButton.Item(
                title: "第 \(ep) 话",
                symbol: commentEpisode == ep ? "checkmark" : ""
            ) {
                switchCommentEpisode(ep)
            }
        }
    }

    /// 进评论页才拉，拉过就不重复拉；切集或刷新时也走 load。
    private func defaultCommentEpisode(_ controller: PlayerController) -> Int? {
        let ep = controller.currentEpisode
        guard controller.episodes.indices.contains(ep - 1) else { return nil }
        return ep
    }

    private func ensureDefaultCommentEpisode(_ controller: PlayerController) {
        // 只在「还没定过集」时默认到当集；用户切过就不再覆盖
        if commentEpisode == nil, let ep = defaultCommentEpisode(controller) {
            commentEpisode = ep
        }
    }

    private func loadCommentsIfNeeded() {
        guard comments.isEmpty, !isLoadingComments else { return }
        Task { await reloadComments() }
    }

    private func reloadComments() async {
        guard !isLoadingComments else { return }
        isLoadingComments = true
        defer { isLoadingComments = false }
        // 评论区默认只看当集：没定过就按当前集补上，失败才退回上一口径
        if commentEpisode == nil, let c = controller, let ep = defaultCommentEpisode(c) {
            commentEpisode = ep
        }
        let page: BangumiCommentPage
        if let ep = commentEpisode, let eid = await BangumiAPI.episodeID(subjectID: bangumiID, episode: ep) {
            page = await BangumiAPI.episodeComments(episodeID: eid)
        } else {
            // 兜底：当集还没解析出来或取不到 episodeID 时，退回整部番（避免空屏）
            page = await BangumiAPI.comments(subjectID: bangumiID)
        }
        var items = page.items
        // 排序：主分支在拿到就排好，这里沿用同一规则（按 updatedAt）
        items.sort { isCommentsAscending ? $0.updatedAt < $1.updatedAt : $0.updatedAt > $1.updatedAt }
        comments = items
        commentTotal = page.total
    }

    private func switchCommentEpisode(_ episode: Int?) {
        commentEpisode = episode
        comments = []
        commentTotal = 0
        Task { await reloadComments() }
    }

    private func applyCommentsSort() {
        guard !comments.isEmpty else { return }
        comments.sort { isCommentsAscending ? $0.updatedAt < $1.updatedAt : $0.updatedAt > $1.updatedAt }
    }

    /// 一行一集：集号在左，当前集打勾 + 主题色（不做「上次看到」推算）。
    private func episodeRow(_ controller: PlayerController, index: Int) -> some View {
        let number = index + 1
        let isCurrent = number == controller.currentEpisode
        return HStack(spacing: 8) {
            Text("第 \(number) 话")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }

    /// 线路：多于一条时才出现，按钮上写当前实际在用的那条线路名。
    private func roadMenu(_ controller: PlayerController) -> some View {
        // 用 UIKit 的菜单按钮，不用 SwiftUI 的 `Menu`：播放中视图每秒重建，
        // `Menu` 弹出来的是旧的那一份，点了不执行（播放器里那两颗也是这么修的）。
        SystemMenuButton(
            items: controller.roads.enumerated().map { index, road in
                SystemMenuButton.Item(
                    title: Self.roadItemTitle(road),
                    symbol: index == controller.selectedRoad ? "checkmark" : ""
                ) {
                    guard index != controller.selectedRoad else { return }
                    // 换线路 = 重新解析这一集，进度按原版先落一次。
                    persistProgress(controller)
                    surface.prepareForNewEpisode()
                    Task { await controller.selectRoad(index) }
                }
            },
            // 不预设「线路 1」：来源给什么名字就显示什么名字（cht／chs 这种照抄），
            // 也不自己编号（LP 3370 / Colo 3371）。
            title: controller.roads.indices.contains(controller.selectedRoad)
                ? Self.roadName(controller.roads[controller.selectedRoad])
                : "线路",
            symbol: "",
            accessibilityLabel: "选择线路",
            tint: KazumiPalette.accent(for: colorScheme),
            showsChevron: true
        )
        .frame(height: 44)
    }

    /// 只有一条线路时显示的那个名字。
    private static func singleRoadTitle(_ road: Road?) -> String {
        guard let road else { return "线路1" }
        let name = road.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "线路1" : name
    }

    /// 线路名照抄来源给的；来源没给名字就只写「线路」，不编号。
    private static func roadName(_ road: Road) -> String {
        let name = road.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "线路" : name
    }

    /// 菜单里那一条：线路名 · N 集（集数拿不到就不标，别写 0）。
    private static func roadItemTitle(_ road: Road) -> String {
        let name = roadName(road)
        return road.data.isEmpty ? name : "\(name) · \(road.data.count) 集"
    }

    private func switchEpisode(to number: Int, controller: PlayerController) {
        // 点当前集是空操作（原版同样早退）；但上一次加载失败时允许重点重试。
        guard number != controller.currentEpisode || surface.errorMessage != nil else { return }
        persistProgress(controller)
        if commentEpisode != nil { commentEpisode = number }
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
    privateMode: Bool,
    controller: PlayerController,
    position: Double,
    duration: Double
) {
    // 隐身模式：不写观看记录（LP 清单「隐身模式」，Ato：进历史前判一下）。
    guard !privateMode else { return }
    // 没真播过就不进历史（LP 2026-10-25）：「剧集查询失败」那种一次都没起播的，
    // 位置停在 0、时长也拿不到，写进去就是一条 0 进度的空记录。
    guard position.isFinite, duration.isFinite, duration > 0, position >= 1 else { return }
    var progress = position
    if duration > 0, progress >= duration - 5 {
        progress = 0
    }
    let source = controller.source
    let entry = library.entry(for: controller.bangumiID)
    let storedName = source?.itemName ?? ""
    let storedImage = entry?.imageURL ?? ""
    library.upsert(WatchRecord(
        bangumiID: controller.bangumiID,
        bangumiName: storedName,
        imageURL: storedImage,
        sourceRuleName: source?.pluginName ?? "",
        // 原生这边只有 URL，没有集标题，留空由历史页回退成「第 N 话」。
        episodeTitle: "",
        episodeNumber: controller.currentEpisode,
        progressSeconds: progress,
        durationSeconds: duration.isFinite && duration > 0 ? duration : 0,
        updatedAt: Date()
    ))

    // 没追过番的条目，名字和封面在上面都是空串，记录就成了空壳。
    // Colo 3554：缺的那几样用番剧 ID 向 Bangumi 取一次、写回同一条记录；
    // 这里补、不在列表里就地补，别处读同一条记录也就都有名字了。
    guard storedName.isEmpty || storedImage.isEmpty else { return }
    let bangumiID = controller.bangumiID
    Task { @MainActor in
        guard let item = await BangumiAPI.info(id: bangumiID) else { return }
        library.backfillHistoryMeta(
            bangumiID: bangumiID,
            name: item.displayName,
            imageURL: item.largeImage
        )
    }
}

/// 画面框：竖屏里按画面比例的宽度占满（16:9 就是屏宽 × 屏宽×9/16），
/// 横屏全屏时铺满窗口。`.fit` 保证不裁画面——原版竖屏同样不裁。
private struct PlayerBoxModifier: ViewModifier {
    var fillsWindow: Bool
    var aspectRatio: CGFloat

    /// 不分叉。
    ///
    /// 这里原来是 `if fillsWindow { … } else { … }`，两种分支是两种视图类型，
    /// SwiftUI 会当成两棵不同的树：切横屏时整块画面被拆掉重建，mpv 跟着
    /// `dismantleUIView` 停引擎，进度从 0 重来（LP 2026-10-27「切横屏又丢失进度」）。
    /// 改成一条修饰符链，只让参数变、结构不变。
    func body(content: Content) -> some View {
        content
            // 全屏时 `aspectRatio` 传的是**容器自己的比例**（`boxAspectRatio`），
            // 不是 nil：传 nil 会退回内容的固有比例（mpv 视图是方的），
            // 于是横屏只铺了 382 宽（LP 2026-10-27）。
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: fillsWindow ? .infinity : nil)
    }
}

/// 系统那粒隔空播放按钮，塞进投屏浮层里用。
private struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// 系统分享面板：把媒体地址交给别的 App（VLC、Infuse 之类）打开。
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 一起看表单（从 PlayerScreen 抽出，避免 @Bindable 作用域问题）
private struct SyncPlaySheet: View {
    @Bindable var settings: SettingsStore
    @Binding var showingSyncPlay: Bool
    @Bindable var surface: PlayerSurfaceModel

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("wss:// 或 ws://host:port", text: $settings.syncPlayEndPoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section("房间") {
                    TextField("房间名", text: $settings.syncPlayRoom)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("口令（可选）", text: $settings.syncPlayPassword)
                }
                Section {
                    Button("创建房间") {
                        showingSyncPlay = false
                        surface.toastMessage = "一起看：\(settings.syncPlayRoom.isEmpty ? "默认房间" : settings.syncPlayRoom)（创建）"
                    }
                    Button("加入房间") {
                        showingSyncPlay = false
                        surface.toastMessage = "一起看：\(settings.syncPlayRoom.isEmpty ? "默认房间" : settings.syncPlayRoom)（加入）"
                    }
                } header: {
                    Text("房间操作")
                } footer: {
                    Text("可填 wss:// 形式的外网房间服务器。播放同步（WS 客户端与心跳）后续接上。")
                }
            }
            .navigationTitle("一起看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showingSyncPlay = false }
                }
            }
        }
    }
}

/// 播放器里那块玻璃底（LP 3637：横屏选集窗口要用 UIKit 的玻璃）。
/// 用 iOS 26 的 `UIGlassEffect`；这块是浮在视频上的，取 `.regular` 那种，
/// 别用 `.clear`——画面一动，上面的白字就没地方站。
/// 播放页按钮的按压反馈：按下缩到 0.92、松开弹回，100ms easeOut。
/// 不加底色、不变色、不动投影，也不震——iOS 原生按钮本来就不震。
/// 弹幕设置的图标：`captions.bubble` 20pt 打底、右下角压一颗 12pt 的 `gearshape.fill`，
/// 白色、`.regular`，44×44 只是命中区，**不裁**（一裁齿轮就断、气泡就变小——
/// LP 2026-10-28「怎么还出界了」「怎么小了」两回都是裁出来的）。
/// 横屏底栏直接用这个 View，「更多 → 弹幕设置」把它渲成图，两处同一份。
struct DanmakuSettingsGlyph: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 20, weight: .regular))
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .regular))
                // 圆心压在气泡外框的右下角上；比 6 再往左上 0.6（LP 2026-10-28）。
                .offset(x: 5.4, y: 5.4)
        }
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
}

struct PlayerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// 播放器浮层的玻璃底：iOS 26 用 SwiftUI 原生 `glassEffect`；
/// 低版本退回 `GlassBackdrop`，两边都能编译、观感一致。
private struct PlayerGlassShapeModifier<S: Shape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(true), in: shape)
        } else {
            content.background {
                GlassBackdrop()
                    .clipShape(shape)
            }
        }
    }
}

private extension View {
    /// HUD 胶囊统一走这一个入口，调用点只写形状。
    func playerGlass<S: Shape>(in shape: S) -> some View {
        modifier(PlayerGlassShapeModifier(shape: shape))
    }
}

struct GlassBackdrop: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let view = UIVisualEffectView(effect: effect)
        view.backgroundColor = .clear
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}
