//
//  MPVPlayerContainer.swift
//  Kazumi
//
//  把 mpv 的画面接进 SwiftUI，并叠一层弹幕（换掉原来的 KSPlayer 容器）。
//
//  只换画面这一层：上面的控制栏、手势、选集、截图全是自己写的 SwiftUI，
//  接口（`PlayerSurfaceModel`）保持原样，页面那边一行不用改。
//

import AVFoundation
import GLKit
import OpenGLES
import SwiftUI
import UIKit

// MARK: - 画面状态

/// 播放画面对外暴露的状态与控制入口。
///
/// SwiftUI 的播放条读这里的 `currentTime` / `duration` / `isPlaying`；
/// 内核通过快照把状态写回来。
@MainActor
@Observable
final class PlayerSurfaceModel {
    var currentTime: Double = 0
    var duration: Double = 0
    /// 已缓冲到的时间点（相对视频开头），进度条据此画出缓冲段。
    var bufferedTime: Double = 0
    var isPlaying = false
    /// 用户想让它在播（而不是自己按了暂停）。
    ///
    /// 只看内核状态会把「缓冲中」当成「暂停」：mpv 一卡 `core-idle` 就是 true，
    /// 界面立刻换成暂停图标、还把控制栏弹回来（LP 2026-10-29 第 1、2 条：
    /// 「解决不了就不要显示暂停，加个加载中符号」）。
    /// 所以内核没走的时候要再分一步：是用户按停的（`pause`），还是没跟上（idle 但没暂停）。
    private(set) var wantsPlaying = false
    /// 内核最后一次报的 pause。系统中断、退后台这些外部暂停走它，不是用户按的。
    private(set) var corePaused = false
    /// 正在缓冲 / 卡住：想播、没在播、内核也没被暂停。界面用它显示加载符号，
    /// 而不是暂停图标和控制栏。
    var isStalled: Bool { wantsPlaying && !isPlaying && !corePaused }
    var isReady = false
    /// 这一集的第一帧是不是已经画上屏了。
    var hasFirstFrame = false
    /// 时间轴真的走起来了（第一帧之后又过了 0.15 秒）。
    ///
    /// 加载符号收到这里为止，不是收到 `hasFirstFrame`（LP 4810）：第一帧画上屏之后
    /// 还要等音画对齐、时钟起跳，中间那一小段画面是黑的——圈先收了，人就在那儿干等。
    private(set) var hasStartedPlayback = false
    /// 当前下载速度（字节/秒），加载符号下面那行网速。平滑过，不然一秒跳四个数字。
    private(set) var downloadSpeed: Double = 0
    /// 内核正在 seek（拖进度、换集）。
    private(set) var isSeeking = false
    /// 这次加载走到哪一步（由 mpv 事件推，见 `MPVLoadPhase`）。
    private(set) var loadPhase: MPVLoadPhase = .idle

    /// 首帧还没出来 / 刚换集：加载圈该转。
    ///
    /// 判据只看引擎一路推过来的相位，不看「首帧到了」那个标记：那个通知是一次性的
    /// （渲染回调里发一次就不发了），而换集时界面这边会把标记清掉，两件事谁先谁后不定
    /// ——清理落在通知之后就再也回不来，画面在放也照样转圈（Ato 4867，模拟器上切集
    /// 复现过）。相位由 `MPV_EVENT_START_FILE / FILE_LOADED / PLAYBACK_RESTART` 和
    /// 时间轴推进一起推，不依赖一次性回调。
    ///
    /// 「有画面、用户自己暂停着」还是放行：那时画面已经在了，不该拿圈盖住它。
    var isLoadingFirstFrame: Bool {
        switch loadPhase {
        case .opening, .awaitingFirstFrame:
            if hasFirstFrame, corePaused { return false }
            return true
        case .idle, .playing:
            return false
        }
    }
    var errorMessage: String?
    /// 视频的像素尺寸；还没拿到时是 .zero，布局回落到整块画面。
    var videoSize: CGSize = .zero

    weak var engine: MPVEngine?
    /// 弹幕画布：横屏底栏「发弹幕」往这里补一条自己发的。
    weak var danmakuOverlay: DanmakuOverlayView?

    /// 期望的播放速率。换集 / 起播后会回到 1.0，因此就绪时要按这个值再补一次。
    var desiredRate: Float = 1.0

    /// 进入播放器时待恢复的进度：就绪后只 seek 一次，
    /// 避免抢在加载完成前 seek，结果被内核回落到 0。
    var pendingResumeTime: Double?

    /// 正常播完（非出错）时的回调，交给页面处理自动连播。
    var onFinish: (@MainActor (PlayerSurfaceModel) -> Void)?

    /// 这一集加载完就该自己开播（LP 2026-10-28 第 3 条）。
    ///
    /// `MPVEngine.load()` 里已经在 `loadfile` 之前放开了 pause，但 mpv 换文件时
    /// 会把 pause 重新按选项值设一次，所以那条时序靠不住：实测加载完就停着，手点一下才走。
    /// 于是在「第一帧到手」那一刻再补一次 `play()`——只补一次，用户随手暂停就作废。
    private var autoPlayPending = false

    /// 需要在播放区浮现的临时提示（首 / 末集提示等）；页面渲染并在 2 秒后清空。
    var toastMessage: String?

    /// 摆在画面 1/4 那条线上的提示（LP 4668）：倍速、收藏状态、定时关闭这些
    /// 「动作结果」都跟长按倍速指示器同一条线，不再挤在屏幕最顶上。
    /// 顶部那条留给说明性的话（弹幕、错误、同步进度）。
    var hudToastMessage: String?

    func play() {
        autoPlayPending = false
        wantsPlaying = true
        engine?.play()
        isPlaying = true
        applyDesiredRate()
    }

    func pause() {
        // 用户自己按的暂停：起播后那次补播不能再把它拉起来。
        autoPlayPending = false
        wantsPlaying = false
        engine?.pause()
        isPlaying = false
    }

    /// 后台播放时把画面通道关掉，回前台再打开（原因见 `MPVEngine.setVideoTrackEnabled`）。
    ///
    /// 回前台那条每次都会调 `true`，如果无脑转给 mpv，等于每次回来都让 mpv
    /// 重新选一遍视频轨——回来那一下会顿（LP：返回 app 时会暂停一会）。
    /// 所以同一个内核、同一个值就不重复转发。
    ///
    /// 上一次真的转发给 mpv 的那一对：发给哪个内核、开还是关。
    ///
    /// 只记「我想要的状态」不够——记忆里说开着、mpv 其实关着的时候，
    /// 那一句「开」会被吞掉，画面就再也回不来了（有声音、画面一直转圈）。
    /// 所以拿当前内核比：内核换了就一定要转发一次。
    private weak var lastTrackEngine: MPVEngine?
    private var lastTrackEnabled = true

    func setVideoTrackEnabled(_ enabled: Bool) {
        if engine === lastTrackEngine, enabled == lastTrackEnabled { return }
        lastTrackEngine = engine
        lastTrackEnabled = enabled
        engine?.setVideoTrackEnabled(enabled)
    }

    /// 屏幕这块视图。mpv 自己出图失败时，从它兜底。
    weak var hostView: MPVHostView?

    /// 抓当前这一帧（截图）。mpv 自己出 PNG 写临时文件。
    ///
    /// mpv 那条会失败（真机上 1080p 要从关键帧重解，也可能直接被拒），
    /// 那时不能让用户拿到空的：屏幕上已经有画了，直接读它。读到的整块视口
    /// 带黑边、是屏幕的比例，所以按同一套 `videoRect` 裁成画面本身（LP 要的是
    /// 画面比例，不是屏幕比例）。分辨率是屏幕的，比 mpv 原生出图低，但
    /// 「有一张、比例对」比「没有」重要得多。
    ///
    /// 返回 `(文件, 给用户看的那句话)`：文件在就交给相册那条路存。
    func captureFrame() async -> (url: URL?, note: String) {
        if let url = await engine?.captureFrameToFile().url { return (url, "") }
        guard let image = hostView?.snapshotOfVideo(),
              let data = image.pngData()
        else {
            return (nil, "截图失败：没抓到画面")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kazumi-shot-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
        } catch {
            return (nil, "截图失败：临时文件写不出去")
        }
        let note = "截图：mpv 没出图，改用屏幕那一帧 \(Int(image.size.width))×\(Int(image.size.height))"
        KazumiLogBuffer.player(note)
        return (url, note)
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to time: Double) {
        guard time.isFinite, time >= 0 else { return }
        engine?.seek(to: time)
        currentTime = time
    }

    func setPlaybackRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        desiredRate = rate
        engine?.setSpeed(rate)
    }

    /// 只在正在播放时补速率，避免暂停时被拉起来。
    private func applyDesiredRate() {
        guard isPlaying else { return }
        engine?.setSpeed(desiredRate)
    }

    /// 快进指定秒数：已知总时长时夹在时长内，未知时就按当前时间往后加。
    func skipForward(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        let target = duration > 0
            ? min(duration, currentTime + seconds)
            : currentTime + seconds
        seek(to: target)
    }

    /// 从内核读一次已缓冲位置（进度条的缓冲段用）；读不到就保持原值。
    func refreshBufferedTime() {
        guard let engine else { return }
        let value = engine.playableTime
        guard value.isFinite, value > 0 else { return }
        bufferedTime = value
    }

    /// 当前文件的编码规格（「播放信息」半屏页用）。引擎还没建好时返回 nil。
    func playbackInfo() -> PlaybackInfo? {
        engine?.playbackInfo()
    }

    /// mpv 现在真正挂着的着色器个数（0 就是没挂上）。
    func appliedShaderCount() -> Int {
        engine?.appliedShaderCount() ?? 0
    }

    /// 关闭播放器：先停内核再断引用。
    func stop() {
        engine?.stop()
        engine = nil
        isPlaying = false
        wantsPlaying = false
    }

    /// 内核推来的一帧状态。
    func handle(snapshot: MPVSnapshot) {
        currentTime = max(0, snapshot.time)
        if snapshot.duration.isFinite, snapshot.duration > 0 {
            duration = snapshot.duration
        }
        // 内核没在走有三种：正在缓冲/卡住（idle 但没暂停）、被暂停（用户或系统）、
        // 还没起播。只有第二种才算暂停，第一种要留给界面转加载圈。
        corePaused = snapshot.isPaused
        isSeeking = snapshot.isSeeking
        if snapshot.loadPhase != loadPhase {
            // 新的一次加载开始（换集 / 重新加载 / 换源）：首帧那套状态清掉，
            // 圈重新转。seek 不经过这里（相位还是 playing），所以不会误触发
            // 首帧逻辑（LP 4818 第 7 条）。
            if snapshot.loadPhase == .opening {
                hasFirstFrame = false
                hasStartedPlayback = false
            }
            loadPhase = snapshot.loadPhase
        }
        // 网速平滑一下：mpv 报的是瞬时值，直接显示就是每 250ms 乱跳的数字。
        // 掉到 0 时直接归零，别让「已经不下载了」还挂着上一个速度。
        if snapshot.downloadSpeed > 0 {
            downloadSpeed = downloadSpeed > 0
                ? downloadSpeed * 0.6 + snapshot.downloadSpeed * 0.4
                : snapshot.downloadSpeed
        } else {
            downloadSpeed = 0
        }
        if hasFirstFrame, snapshot.time > 0.15 {
            hasStartedPlayback = true
        }
        let coreRunning = !snapshot.isPaused && !snapshot.isIdle
        if coreRunning {
            isPlaying = true
        } else if snapshot.isPaused {
            isPlaying = false
        } else {
            // 没暂停却没走：意图还在就仍然算「在播」，界面看 isStalled 转圈。
            isPlaying = wantsPlaying
        }
        if snapshot.videoWidth > 0, snapshot.videoHeight > 0 {
            let size = CGSize(width: snapshot.videoWidth, height: snapshot.videoHeight)
            if videoSize != size { videoSize = size }
        }
        if snapshot.hasVideo {
            if !isReady {
                // 第一帧到手：把起播那次没生效的「别停」补回来，然后按正常播放补速率。
                if autoPlayPending {
                    autoPlayPending = false
                    wantsPlaying = true
                    engine?.play()
                    isPlaying = true
                }
            }
            isReady = true
            errorMessage = nil
        } else if let loadError = snapshot.loadError {
            // 源挂了 / 404 / 403：不留一块黑屏装死，把原因说给用户。
            errorMessage = loadError
        }
        if isReady {
            applyPendingResume()
        }
        if snapshot.ended {
            handleFinish(errorMessage: nil)
        }
    }

    /// 播放结束（正常播完或出错）的收尾。
    /// 出错只报错；只有确实播到结尾才触发 `onFinish`——停止 / 换集也会走到结尾附近。
    func handleFinish(errorMessage: String?) {
        isPlaying = false
        wantsPlaying = false
        isReady = false
        if let errorMessage {
            self.errorMessage = errorMessage
            return
        }
        guard duration > 0, currentTime >= duration - 3 else { return }
        onFinish?(self)
    }

    /// 切换分集前清掉上一集的展示状态，避免旧的时长 / 进度闪一下。
    func prepareForNewEpisode() {
        // 这一集就绪后应该自己开播（见 `autoPlayPending`）。
        autoPlayPending = true
        wantsPlaying = true
        currentTime = 0
        duration = 0
        bufferedTime = 0
        isReady = false
        hasFirstFrame = false
        hasStartedPlayback = false
        isSeeking = false
        downloadSpeed = 0
        pendingResumeTime = nil
        errorMessage = nil
        // 换集先清尺寸：新的一集分辨率可能不同，拿到之前回落到整块画面。
        videoSize = .zero
    }

    func updateTime(current: Double, total: Double) {
        currentTime = max(0, current)
        if total.isFinite, total > 0 {
            duration = total
        }
    }

    /// 就绪后恢复一次待续播位置；太短或落在结尾 5 秒内（视为已看完）就丢掉。
    private func applyPendingResume() {
        guard let resume = pendingResumeTime else { return }
        pendingResumeTime = nil
        guard resume > 1 else { return }
        if duration > 0, resume >= duration - 5 { return }
        seek(to: resume)
    }
}

extension PlayerSurfaceModel: PlayerClockProvider {
    var currentPlaybackTime: Double { currentTime }
    var isPlayingNow: Bool { isPlaying }
}

// MARK: - 画面

/// mpv 的 OpenGL 画面。mpv 每次有新帧会叫 `setNeedsDisplay`，这里画进自己的 FBO。
final class MPVGLView: GLKView {
    weak var engine: MPVEngine?

    override func draw(_ rect: CGRect) {
        guard let engine else { return }
        glClearColor(0, 0, 0, 1)
        glClear(UInt32(GL_COLOR_BUFFER_BIT))
        engine.render(in: self)
    }
}

/// 画面 + 弹幕叠在一起的那块 UIView。
final class MPVHostView: UIView {
    let glView = MPVGLView()
    let overlay = DanmakuOverlayView()

    /// 视频尺寸、填充方式与弹幕顶部留白，由容器在 updateUIView 里推进来。
    private var videoSize: CGSize = .zero
    /// 上一次 layout 时的尺寸：用来认出「画面被撑大了」这件事。
    private var lastLayoutSize: CGSize = .zero
    private var fillMode: MPVPlayerContainer.MPVFillMode = .fit
    private var danmakuTopInset: CGFloat = 0

    private var overlayLeading: NSLayoutConstraint!
    private var overlayTop: NSLayoutConstraint!
    private var overlayWidth: NSLayoutConstraint!
    private var overlayHeight: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        glView.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glView)
        addSubview(overlay)
        overlayLeading = overlay.leadingAnchor.constraint(equalTo: leadingAnchor)
        overlayTop = overlay.topAnchor.constraint(equalTo: topAnchor)
        overlayWidth = overlay.widthAnchor.constraint(equalToConstant: 0)
        overlayHeight = overlay.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            // GL 画面仍然铺满整块：mpv 自己在里面按 fit/crop/stretch 出画面。
            glView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glView.topAnchor.constraint(equalTo: topAnchor),
            glView.bottomAnchor.constraint(equalTo: bottomAnchor),
            // 弹幕只贴在「视频矩形」里，不再铺到黑边上（DEFECT 1）。
            overlayLeading,
            overlayTop,
            overlayWidth,
            overlayHeight,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 屏幕上真正的画面那一块（不含黑边），points。layoutSubviews 里算好。
    private var currentVideoRect: CGRect = .zero

    /// 兜底截图：读屏幕上那块画面，按画面比例把黑边裁掉再返回。
    ///
    /// 只有 mpv 自己出图失败时才走到这里，所以宁可是屏幕分辨率的一张，
    /// 也不要给用户一张带黑边的整屏图。
    func snapshotOfVideo() -> UIImage? {
        let snapshot = glView.snapshot
        let boundsSize = glView.bounds.size
        guard boundsSize.width >= 1, boundsSize.height >= 1,
              snapshot.size.width >= 1, snapshot.size.height >= 1
        else { return nil }

        // 视频还没报尺寸（或布局还没跑过）时按整块来，至少不是空的。
        let rect = currentVideoRect.width >= 1 && currentVideoRect.height >= 1
            ? currentVideoRect
            : fillMode.videoRect(in: glView.bounds, videoSize: videoSize)

        // snapshot 是像素，rect 是 points，换算过去再裁。
        let sx = snapshot.size.width / boundsSize.width
        let sy = snapshot.size.height / boundsSize.height
        let crop = CGRect(
            x: rect.minX * sx,
            y: rect.minY * sy,
            width: rect.width * sx,
            height: rect.height * sy
        ).integral.intersection(CGRect(origin: .zero, size: snapshot.size))

        guard crop.width >= 1, crop.height >= 1,
              let cgImage = snapshot.cgImage?.cropping(to: crop)
        else { return snapshot }
        return UIImage(cgImage: cgImage, scale: snapshot.scale, orientation: .up)
    }

    /// 更新视频矩形所需的三样东西；真正的尺寸在 layoutSubviews 里按当前 bounds 算。
    func updateVideoLayout(
        videoSize: CGSize,
        fillMode: MPVPlayerContainer.MPVFillMode,
        danmakuTopInset: CGFloat
    ) {
        // 画面尺寸 / 填充方式变了也要主动讨一帧：暂停时 mpv 不报新帧，
        // 屏幕上会留着旧尺寸画的那张图（同下面的 layoutSubviews）。
        let geometryChanged = videoSize != self.videoSize || fillMode != self.fillMode
        self.videoSize = videoSize
        self.fillMode = fillMode
        self.danmakuTopInset = danmakuTopInset
        setNeedsLayout()
        if geometryChanged {
            glView.setNeedsDisplay()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 尺寸一变就主动要一帧（LP 2026-10-28 第 5 条）。
        //
        // GL 视图开了 `enableSetNeedsDisplay`，只在 mpv 报新帧时才重画。暂停时
        // 一帧都不来，进全屏只是把这块视图撑大，屏幕上还是**旧尺寸画的那张图**
        // 被系统拉大——看着就是「画面被拉伸」（@developer3 2026-10-28 4349 的读法；
        // Colo 那条 `videoSize` 为零的解释对不上：暂停并不清 `videoSize`，
        // 清它的是 `prepareForNewEpisode`，所以补 16:9 兜底治不了这一条）。
        // 尺寸对不上就自己讨一帧：mpv 按新的 FBO 尺寸重画，它自己按 keepaspect 留边。
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            glView.setNeedsDisplay()
        }
        let rect = fillMode.videoRect(in: bounds, videoSize: videoSize)
        currentVideoRect = rect
        // 顶部让出控制栏（横屏 44pt），底部仍留 20% 给字幕：
        // 弹幕区 = 视频上方 80% 再往上收掉顶部留白。
        let inset = max(0, danmakuTopInset)
        let top = rect.minY + inset
        let height = max(0, rect.height * 0.8 - inset)
        // 只在数值变了才改约束，避免 layoutSubviews 里反复触发布局。
        if overlayLeading.constant != rect.minX { overlayLeading.constant = rect.minX }
        if overlayTop.constant != top { overlayTop.constant = top }
        if overlayWidth.constant != rect.width { overlayWidth.constant = rect.width }
        if overlayHeight.constant != height { overlayHeight.constant = height }
    }
}

// MARK: - SwiftUI 容器

struct MPVPlayerContainer: UIViewRepresentable {
    let url: URL
    let referer: String?
    let userAgent: String?
    /// 超分着色器的绝对路径，空数组表示关闭（顺序就是挂载顺序）。
    let shaderPaths: [String]
    /// 画面填充方式。
    let fillMode: MPVFillMode
    let danmaku: [DanmakuComment]
    let danmakuStyle: DanmakuOverlayView.Style
    let danmakuPlaybackRate: Double
    /// 弹幕顶部留白：横屏时让开顶栏，竖屏为 0。
    let danmakuTopInset: CGFloat
    let surface: PlayerSurfaceModel

    /// 画面填充方式（对应原版 PlayerAspectRatio 的 BoxFit）。
    enum MPVFillMode {
        /// 等比适配，留黑边。
        case fit
        /// 等比填满，超出裁掉。
        case crop
        /// 不保持比例，拉满。
        case stretch
    }

    func makeUIView(context: Context) -> MPVHostView {
        let host = MPVHostView()
        let engine = MPVEngine()
        surface.hostView = host
        engine.glView = host.glView
        host.glView.engine = engine
        host.glView.enableSetNeedsDisplay = true
        host.glView.isOpaque = true
        // blit 到 CVPixelBuffer 纹理要求两边格式兼容；显式固定成 RGBA8，
        // 不依赖 GLKView 的默认值。
        host.glView.drawableColorFormat = .RGBA8888
        host.glView.context = engine.glContext

        engine.onSnapshot = { [weak surface] snapshot in
            surface?.handle(snapshot: snapshot)
            surface?.refreshBufferedTime()
        }
        engine.onLog = { message in
            KazumiLogBuffer.player("mpv: \(message)")
        }
        engine.onFirstFrame = { [weak surface] in
            surface?.hasFirstFrame = true
        }
        engine.start()

        context.coordinator.engine = engine
        context.coordinator.surface = surface
        context.coordinator.overlay = host.overlay
        surface.engine = engine
        surface.danmakuOverlay = host.overlay
        host.overlay.clock = surface
        host.updateVideoLayout(
            videoSize: surface.videoSize,
            fillMode: fillMode,
            danmakuTopInset: danmakuTopInset
        )
        context.coordinator.apply(
            url: url,
            referer: referer,
            userAgent: userAgent,
            shaders: shaderPaths,
            fill: fillMode
        )
        return host
    }

    func updateUIView(_ uiView: MPVHostView, context: Context) {
        context.coordinator.surface = surface
        surface.engine = context.coordinator.engine
        // 视频尺寸 / 填充方式 / 顶部留白变了，弹幕矩形跟着重算。
        uiView.updateVideoLayout(
            videoSize: surface.videoSize,
            fillMode: fillMode,
            danmakuTopInset: danmakuTopInset
        )
        context.coordinator.apply(
            url: url,
            referer: referer,
            userAgent: userAgent,
            shaders: shaderPaths,
            fill: fillMode
        )
        context.coordinator.overlay?.apply(
            comments: danmaku,
            style: danmakuStyle,
            playbackRate: danmakuPlaybackRate
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ uiView: MPVHostView, coordinator: Coordinator) {
        coordinator.overlay?.clock = nil
        coordinator.overlay = nil
        uiView.overlay.clock = nil
        coordinator.surface?.engine = nil
        uiView.glView.engine = nil
        coordinator.engine?.stop()
        coordinator.engine = nil
    }

    @MainActor
    final class Coordinator {
        weak var surface: PlayerSurfaceModel?
        weak var overlay: DanmakuOverlayView?
        var engine: MPVEngine?

        private var lastURL: URL?
        private var lastShaders: [String] = []
        private var lastFill: MPVFillMode?

        func apply(
            url: URL,
            referer: String?,
            userAgent: String?,
            shaders: [String],
            fill: MPVFillMode
        ) {
            guard let engine else { return }
            // 换档位时画面要重新出，但不用重新起播：mpv 换着色器当场生效。
            if shaders != lastShaders {
                lastShaders = shaders
                // 换着色器要现编 GLSL，质量档那几颗 VL 模型在手机上能卡几百毫秒。
                // 这一步原来跟着 SwiftUI 的更新走、在主线程上做，点完菜单整段卡住，
                // 点击就被吃掉、要点很多下（LP 2026-10-28）。
                // 2026-10-29 排查闪退得出的结论：与线程无关，瓶颈在编译本身；
                // 主线程上这 6 颗挂上去实测 82ms，LP 验收不闪退。
                engine.setShaders(shaders)
            }
            if fill != lastFill {
                lastFill = fill
                switch fill {
                case .fit:
                    engine.setOptionForPlayback("panscan", "0")
                    engine.setOptionForPlayback("keepaspect", "yes")
                case .crop:
                    engine.setOptionForPlayback("panscan", "1.0")
                    engine.setOptionForPlayback("keepaspect", "yes")
                case .stretch:
                    engine.setOptionForPlayback("panscan", "0")
                    engine.setOptionForPlayback("keepaspect", "no")
                }
            }
            guard lastURL != url else { return }
            lastURL = url
            engine.load(url: url, referer: referer, userAgent: userAgent)
        }
    }
}

extension MPVPlayerContainer.MPVFillMode {
    /// 画面在容器里的可见矩形（和 mpv 的 fit / crop / stretch 一致）。
    ///
    /// 弹幕层和控制层都从这里取同一份几何：横屏时屏幕比 16:9 宽，
    /// 两边是黑边，弹幕和控件都不该画进去（DEFECT 1 / 4）。
    func videoRect(in bounds: CGRect, videoSize: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0
        else { return bounds }

        let scaleX = bounds.width / videoSize.width
        let scaleY = bounds.height / videoSize.height
        let scale: CGFloat
        switch self {
        case .stretch:
            return bounds
        case .fit:
            scale = min(scaleX, scaleY)
        case .crop:
            scale = max(scaleX, scaleY)
        }
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        let rect = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        // crop 时矩形比容器大：只取可见部分，别把控件画到屏外。
        let visible = rect.intersection(bounds)
        return visible.isNull || visible.isEmpty ? bounds : visible
    }
}
