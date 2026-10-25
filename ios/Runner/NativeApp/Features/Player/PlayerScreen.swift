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
    /// 临时：探测器读数，用来确认 SystemMenuProbe 认不认这个菜单（验完删）。
    /// 「更多」/ 倍速面板：自己握开关，好让控制层知道菜单还开着。
    /// 每次交互 +1，body 上的 `.task(id:)` 据此取消上一轮自动隐藏并重新计时。
    @State private var hideGeneration = 0
    /// 「更多」菜单开着：开着的时候不自动收控制栏，否则菜单会变成一张点不动的死图。
    @State private var menuOpen = false
    @State private var menuOpenedAt = Date()
    @State private var probeSawMenu = false
    @State private var probeLastSeen = Date()
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
    /// 定时关闭：还剩多少秒，nil 就是没定。
    /// 侧滑返回时页面跟着手走多少点。
    @State private var backDragOffset: CGFloat = 0
    /// 这一次拖动是不是从左边边缘起手、按侧滑返回处理。
    @State private var backDragArmed = false
    @State private var sleepTimerRemaining: Int?
    @State private var sleepTimerTask: Task<Void, Never>?

    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                if let controller {
                if isFullscreen {
                    // 横屏全屏：画面铺满，选集收起（本轮不改横屏行为）。
                    playerArea(controller)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 竖屏：16:9 画面在最上、占满屏宽，控制层浮在画面上；
                    // 画面下面是选集与线路（对应原版 video_page 的落点）。
                    VStack(spacing: 0) {
                        playerArea(controller)
                        episodeArea(controller)
                    }
                }
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
            .offset(x: backDragOffset)
        }
        .background(Color.black.ignoresSafeArea())
        // 竖屏全屏不做：先真的横过屏，之后用户又转回竖屏，才退出全屏。
        // 只看「现在是不是竖的」会误判——刚点全屏、屏幕还没来得及转的那一帧
        // 本来就是竖的，那样一进就被自己的判据弹出来（LP 2026-10-25 现场）。
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size) { _, size in
                        if size.width > size.height {
                            sawLandscape = true
                        } else if isFullscreen, sawLandscape {
                            sawLandscape = false
                            exitFullscreen()
                        }
                    }
            }
        }
        // 竖屏侧滑返回（全屏不认，免得跟横屏的手势打架）。
        .simultaneousGesture(backSwipeGesture)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .overlay(alignment: .top) { toastView }
        .overlay { skipSecondsDialog }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .danmakuSettings:
                NavigationStack {
                    DanmakuSettingsScreen()
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
            }
        }
        // 竖屏侧滑返回：导航栏藏了之后系统的手势会失效，这里把它接回来（全屏时不认）。

        .animation(.easeOut(duration: 0.2), value: surface.toastMessage)
        // 弹幕拉不到的时候说一句原因（Ato：对不上号 / 接口失败要说，
        // 「这集本来就没弹幕」是正常情况，安静地不显示）。
        .onChange(of: controller?.danmakuMessage) { _, message in
            if let message, !message.isEmpty {
                surface.toastMessage = message
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
            // 临时探针读数（验完删）。
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
            // 默认倍速：以前只读了一次没交给播放器，现在存进画面模型，
            // 就绪 / 重新起播时由它补一次（AVPlayer 会回到 1.0）。
            surface.setPlaybackRate(Float(settingsStore.playSpeed))
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
        }
    }

    // MARK: - 播放区

    /// 画面：16:9（或 4:3）画面本身，控制层压在它上面。
    /// 竖屏里这条就是页面最上面那一块；横屏全屏时铺满。
    @ViewBuilder
    private func playerArea(_ controller: PlayerController) -> some View {
        ZStack {
            interactiveSurface(controller)

            if let error = surface.errorMessage {
                errorOverlay(error, controller: controller)
            }

            controlLayer(controller)

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
                                    aspectRatio: aspectRatioMode.frameAspectRatio))
        .background(Color.black)
        // MPVolumeView 得在视图树里，才拿得到它内部的音量滑杆。
        .background(
            SystemVolumeHost()
                .frame(width: 1, height: 1)
                .opacity(0.01)
        )
    }

    /// 画面 + 手势（只挂在画面上，下面的选集与评论不接）：
    /// 单击显隐控制层，双击播放暂停，长按临时倍速，左右两侧竖滑分别调亮度与音量。
    private func interactiveSurface(_ controller: PlayerController) -> some View {
        GeometryReader { proxy in
            // 没有画面（解析中、加载失败）时一个面手势都不挂：父层的手势会抢走
            // 失败页上「重试」「返回选源」的点击，连点都落不下去（LP 2026-10-25）。
            if controller.playbackURL == nil {
                videoSurface(controller)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                videoSurface(controller)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        ExclusiveGesture(SpatialTapGesture(count: 2), SpatialTapGesture(count: 1))
                            .onEnded { value in
                                switch value {
                                case .first(let tap):
                                    handleSurfaceDoubleTap(at: tap.location, width: proxy.size.width)
                                case .second:
                                    handleSurfaceTap()
                                }
                            }
                    )
                    // 滑动手势关了就不收竖向拖拽（LP 清单「滑动手势」，默认开）。
                    .simultaneousGesture(
                        surfaceDragGesture(width: proxy.size.width),
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
                if dragAxis == .seek, let target = seekDragTarget {
                    surface.seek(to: target)
                }
                dragAxis = nil
                dragValueStart = nil
                seekDragStart = nil
                seekDragTarget = nil
                scheduleHUDHide()
            }
    }

    /// 控制层：顶一行、底一行，都浮在画面上；几秒不碰淡出，点一下回来。
    /// 隐藏只降透明度、不动布局，画面不会跳。
    private func controlLayer(_ controller: PlayerController) -> some View {
        ZStack {
            VStack(spacing: 0) {
                topBar(controller)
                Spacer(minLength: 0)
                transportBar(controller)
            }
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .animation(.easeOut(duration: 0.2), value: controlsVisible)
            .background {
                // 上下两条压暗，让白字压在亮画面上也读得清（原版是两条等高的渐变）。
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.55), location: 0),
                        .init(color: .clear, location: 0.34),
                        .init(color: .clear, location: 0.6),
                        .init(color: .black.opacity(0.65), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }

            if !controlsVisible {
                // 控制层收起时，整块画面都是「把控制层叫回来」的命中区。
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { showControls() }
            }

        }
    }

    /// 竖屏侧滑返回：从屏幕左边缘往右拖，松手就退出播放页。
    ///
    /// 导航栏藏了以后系统那条边缘手势会被停掉，而把 `interactivePopGestureRecognizer`
    /// 的 delegate 换掉这条路，SwiftUI 每次更新导航栈都会把它换回去，试过没生效
    /// （LP 2026-10-25 报「侧滑返回还是无效」）。所以自己认这次拖动：
    /// 起手点在左边缘 28 点内、往右拖过 70 点、横向为主，就退。
    /// 挂在整页上而不是画面上，控制层收着、失败页显示着也一样能退。
    private var backSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                guard !isFullscreen else { return }
                if !backDragArmed {
                    // 只有从左边边缘起手、而且是在横着走，才认成返回：
                    // 画面中间横向划是进度，边缘竖着划是别的手势。
                    guard value.startLocation.x < 32,
                          value.translation.width > 0,
                          abs(value.translation.width) > abs(value.translation.height)
                    else { return }
                    backDragArmed = true
                }
                // 手指拖多少，页面就挪多少——这一条是「跟手」的关键。
                backDragOffset = max(0, value.translation.width)
            }
            .onEnded { value in
                guard backDragArmed else { return }
                backDragArmed = false
                let width = max(screenWidth, 1)
                // 松手时按「拖过半屏」或「甩得够快」决定退回还是弹回。
                let dragged = value.translation.width
                let projected = value.predictedEndTranslation.width
                if dragged > width * 0.32 || projected > width * 0.5 {
                    withAnimation(.easeOut(duration: 0.22)) {
                        backDragOffset = width
                    }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        backDragOffset = 0
                        dismiss()
                    }
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        backDragOffset = 0
                    }
                }
            }
    }

    private var screenWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.width }
            .first ?? 402
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
    private func handleSurfaceDoubleTap(at location: CGPoint, width: CGFloat) {
        let edge = width / 3
        let seconds = Double(settings.doubleTapSkipTime)
        if location.x < edge {
            surface.seek(to: max(0, surface.currentTime - seconds))
            flashSeekHUD(-settings.doubleTapSkipTime)
        } else if location.x > width - edge {
            surface.skipForward(seconds: seconds)
            flashSeekHUD(settings.doubleTapSkipTime)
        } else {
            surface.togglePlay()
            flashPlayPauseHUD()
        }
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
    private func openSheet(_ sheet: PlayerSheet) {
        showControls()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            NSLog("[menu] 真的设 activeSheet=\(String(describing: sheet))")
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
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            // 从历史进入时 `source` 是空值，标题得用控制器里重建出来的那个。
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.source?.itemName ?? "播放")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(episodeCaption(controller))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            danmakuButton
            collectButton
            skipForwardButton
            moreMenu
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }

    /// 顶栏第二行：这一集 + 一共几集（线路多于一条时补线路名）。
    private func episodeCaption(_ controller: PlayerController) -> String {
        let total = controller.episodes.count
        guard total > 0 else { return "第 \(controller.currentEpisode) 话" }
        var text = "第 \(controller.currentEpisode) 话 · 共 \(total) 话"
        if controller.roads.count > 1,
           controller.roads.indices.contains(controller.selectedRoad),
           !controller.roads[controller.selectedRoad].name.isEmpty {
            text += " · \(controller.roads[controller.selectedRoad].name)"
        }
        return text
    }

    /// 收藏状态：符号就是当前收藏状态（heart.fill / star.fill / hourglass / checkmark /
    /// heart.slash.fill，未收藏是空心 heart），点开换成别的状态。
    private var collectButton: some View {
        SystemMenuButton(
            items: collectMenuItems,
            title: nil,
            symbol: currentCollectType.statusSymbol,
            accessibilityLabel: "追番状态：\(currentCollectType.title)",
            onOpen: { pinControlsWhileMenuOpen() }
        )
        .frame(width: 44, height: 44)
    }

    private var collectMenuItems: [SystemMenuButton.Item] {
        var items = CollectType.enabledCases.map { type in
            SystemMenuButton.Item(
                title: type.title,
                symbol: currentCollectType == type ? "checkmark" : type.statusSymbol
            ) {
                closeMenu()
                applyCollectType(type)
            }
        }
        if currentCollectType != .none {
            items.append(
                SystemMenuButton.Item(title: "取消追番", symbol: "heart.slash", isDestructive: true) {
                    closeMenu()
                    applyCollectType(.none)
                }
            )
        }
        return items
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
        Task {
            let updated = await BangumiAPI.updateCollection(subjectID: bangumiID, type: type)
            guard updated else {
                surface.toastMessage = "先在「我的」里登录 Bangumi，才能改收藏状态"
                return
            }
            if var entry = environment.library.entry(for: bangumiID) {
                entry.type = type.rawValue
                entry.updatedAt = Date()
                environment.library.upsert(entry)
            }
            surface.toastMessage = type == .none ? "已取消追番" : "已标为\(type.title)"
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

    /// 当前这一集的媒体地址（解析出来才有）。
    private var controllerURLString: String? {
        guard let text = controller?.playbackURL, !text.isEmpty else { return nil }
        return text
    }

    /// 弹幕开关：白符号直接压画面，不套底（工具行的第一格）。
    private var danmakuButton: some View {
        Button {
            danmakuEnabled.toggle()
            noteInteraction()
        } label: {
            Image(systemName: danmakuEnabled ? "text.bubble.fill" : "text.bubble")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(danmakuEnabled ? "关闭弹幕" : "打开弹幕")
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
        .accessibilityLabel("更多选项")
    }

    private var moreMenuItems: [SystemMenuButton.Item] {
        [
            SystemMenuButton.Item(
                title: danmakuEnabled ? "关闭弹幕" : "打开弹幕",
                symbol: danmakuEnabled ? "text.bubble.fill" : "text.bubble"
            ) {
                closeMenu()
                danmakuEnabled.toggle()
            },
            SystemMenuButton.Item(title: "弹幕设置", symbol: "text.bubble.badge.gearshape") {
                closeMenu()
                openSheet(.danmakuSettings)
            },
            SystemMenuButton.Item(title: "视频详情", symbol: "info.circle") {
                closeMenu()
                environment.router.push(.bangumiInfo(bangumiID: bangumiID))
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
            Text("\(settings.buttonSkipTime)s")
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

    /// 播放条：一条，压在画面底部。播放键、进度、时间、倍速、全屏。
    /// 倍速从「更多」里提上来——它是这一轮要的常动作，且 3× 以前根本选不到。
    private func transportBar(_ controller: PlayerController) -> some View {
        HStack(spacing: 10) {
            Button {
                surface.togglePlay()
                noteInteraction()
            } label: {
                Image(systemName: surface.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(surface.isPlaying ? "暂停" : "播放")

            Text(timeText(isScrubbing ? scrubValue : surface.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 38, alignment: .leading)

            scrubber

            Text(timeText(surface.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 38, alignment: .trailing)

            speedMenu

            Button {
                toggleFullscreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFullscreen ? "退出全屏" : "全屏")
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
    }

    /// 细线进度：不要拇指白块（LP：取消进度条上的大白块）。2pt 高、圆角 1。
    private var scrubber: some View {
        let total = max(surface.duration, 0.001)
        let progress = min(max(isScrubbing ? scrubValue : surface.currentTime, 0), total) / total
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: 2)
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, proxy.size.width * progress), height: 2)
            }
            // GeometryReader 把内容放在左上角，不给满宽高的话 2pt 的线会贴在 24 高框的顶上，
            // 看上去就比旁边的时间数字高出半个字（LP 2174）。
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let ratio = min(max(value.location.x / max(1, proxy.size.width), 0), 1)
                        isScrubbing = true
                        scrubValue = ratio * total
                    }
                    .onEnded { value in
                        let ratio = min(max(value.location.x / max(1, proxy.size.width), 0), 1)
                        scrubValue = ratio * total
                        onScrub(false)
                    }
            )
        }
        .frame(height: 24)
        .accessibilityLabel("播放进度")
    }

    /// 倍速：菜单标签写当前值（原版把倍速藏在「更多」里，而且上限只到 2×）。
    private var speedMenu: some View {
        SystemMenuButton(
            items: speedMenuItems,
            title: speedText(Double(playbackRate)),
            symbol: "speedometer",
            accessibilityLabel: "倍速 \(speedText(Double(playbackRate)))",
            onOpen: { pinControlsWhileMenuOpen() }
        )
        .frame(minWidth: 46, minHeight: 44)
    }

    private var speedMenuItems: [SystemMenuButton.Item] {
        PlaybackSpeed.all.map { rate in
            SystemMenuButton.Item(
                title: speedText(rate),
                symbol: abs(playbackRate - Float(rate)) < 0.01 ? "checkmark" : ""
            ) {
                closeMenu()
                applySpeed(Float(rate))
                noteInteraction()
            }
        }
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
            privateMode: settings.privateMode,
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

    /// 竖滑浮层：120×120、圆角 16、黑 55%，里面是图标、竖条和百分比。
    /// 形状照 main，图标与配色用 iOS 自己那套（SF Symbols、白色）。
    private func gestureOverlay(_ hud: GestureHUDValue) -> some View {
        HStack(spacing: 10) {
            Image(systemName: hud.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule()
                    .fill(.white)
                    .frame(width: 148 * max(0, min(1, hud.value)))
            }
            .frame(width: 148, height: 6)
        }
        // 亮画面里白条会糊掉，压一层系统阴影；不铺底色方块。
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// 横滑调进度时正中那朵「+15s」：20pt semibold 等宽数字，不铺底。
    private func seekOverlay(_ seconds: Int) -> some View {
        Text(seconds > 0 ? "+\(seconds)s" : "\(seconds)s")
            .font(.system(size: 20, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
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
        scheduleHUDHide()
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

    /// 手指离开 0.6 秒后淡出，0.2 秒 easeOut；三朵浮层共用这一个定时器。
    private func scheduleHUDHide() {
        hudHideTask?.cancel()
        hudHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.6))
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

    @ViewBuilder
    private func episodesPane(_ controller: PlayerController) -> some View {
        let total = controller.episodes.count
        let pageSize = 100
        let pages = max(1, (total + pageSize - 1) / pageSize)
        let currentPage = min(episodeGridPage, max(0, pages - 1))
        let lo = currentPage * pageSize
        let hi = min(total, lo + pageSize)

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if controller.roads.count > 1 { roadMenu(controller) }
                if pages > 1 {
                    Menu {
                        ForEach(0 ..< pages, id: \.self) { page in
                            let a = page * pageSize + 1
                            let b = min(total, (page + 1) * pageSize)
                            Button("\(a)–\(b) 话") { episodeGridPage = page }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(lo + 1)–\(hi) 话")
                                .font(.subheadline)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("快速跳转，现在显示第 \(lo + 1) 到 \(hi) 话")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)

            if total == 0 {
                Text("暂无选集")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
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
                Menu {
                    if let controller, let ep = commentEpisode {
                        episodeCommentPicker(controller, selectedEpisode: ep)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(commentEpisode.map { "第 \($0) 话" } ?? "第 — 话")
                            .font(.subheadline)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(commentEpisode.map { "当前查看第 \($0) 话评论" } ?? "当前查看集数评论")
                Spacer(minLength: 8)
                // 中：只读条数文案
                Text(commentTotal == 0 ? "还没有人评论" : "共 \(commentTotal) 条评论")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer(minLength: 8)
                // 右：排序（按钮上直接写当前排序方式） + 刷新
                Menu {
                    Button {
                        if isCommentsAscending { isCommentsAscending = false }
                        applyCommentsSort()
                    } label: {
                        if !isCommentsAscending { Label("最新优先", systemImage: "checkmark") } else { Text("最新优先") }
                    }
                    Button {
                        if !isCommentsAscending { isCommentsAscending = true }
                        applyCommentsSort()
                    } label: {
                        if isCommentsAscending { Label("最早优先", systemImage: "checkmark") } else { Text("最早优先") }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isCommentsAscending ? "最早优先" : "最新优先")
                            .font(.subheadline)
                        Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
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
                List {
                    ForEach(comments) { comment in
                        commentRow(comment)
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    }
                    if commentTotal > comments.count {
                        Text("已显示 \(comments.count) / \(commentTotal) 条评论")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// 换集菜单里的集数列表。
    @ViewBuilder
    private func episodeCommentPicker(_ controller: PlayerController, selectedEpisode: Int?) -> some View {
        let total = controller.episodes.count
        ForEach(0 ..< total, id: \.self) { index in
            let ep = index + 1
            Button {
                switchCommentEpisode(ep)
            } label: {
                Label("第 \(ep) 话", systemImage: selectedEpisode == ep ? "checkmark" : "number")
            }
        }
    }

    private func commentRow(_ comment: BangumiCommentItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            BangumiRemoteImage(url: comment.userAvatar, contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.userName)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    if comment.rate > 0 {
                        Text("★ \(comment.rate)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(comment.comment)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// 线路：多于一条时才出现，右侧显示当前线路。
    private func roadMenu(_ controller: PlayerController) -> some View {
        Menu {
            ForEach(Array(controller.roads.enumerated()), id: \.offset) { index, road in
                Button {
                    if index != controller.selectedRoad {
                        // 换线路 = 重新解析这一集，进度按原版先落一次。
                        persistProgress(controller)
                        surface.prepareForNewEpisode()
                        Task { await controller.selectRoad(index) }
                    }
                } label: {
                    if index == controller.selectedRoad {
                        Label(road.name.isEmpty ? "线路 \(index + 1)" : road.name, systemImage: "checkmark")
                    } else {
                        Text(road.name.isEmpty ? "线路 \(index + 1)" : road.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(controller.roads.indices.contains(controller.selectedRoad)
                     ? "线路 \(controller.selectedRoad + 1)"
                     : "线路")
                    .font(.subheadline)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.primary)
            .frame(minHeight: 44)
        }
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

/// 画面框：竖屏里按画面比例的宽度占满（16:9 就是屏宽 × 屏宽×9/16），
/// 横屏全屏时铺满窗口。`.fit` 保证不裁画面——原版竖屏同样不裁。
private struct PlayerBoxModifier: ViewModifier {
    var fillsWindow: Bool
    var aspectRatio: CGFloat

    func body(content: Content) -> some View {
        if fillsWindow {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
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
