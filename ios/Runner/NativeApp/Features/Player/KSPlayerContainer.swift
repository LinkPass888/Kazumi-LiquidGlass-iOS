//
//  KSPlayerContainer.swift
//  Kazumi
//
//  把 KSPlayer 的视频画面接进 SwiftUI，并叠一层弹幕。
//
//  这里刻意只使用 KSPlayer 的基础 `PlayerView`（没有内置控件的那一层）：
//   * `IOSVideoPlayerView` 自带一整套 UIKit 工具条 / 手势 / 全屏转场，
//     在 iOS 26 上与 SwiftUI 的导航栈叠在一起时会互相抢 firstResponder，
//     这也是原先播放器页偶发闪退的来源；
//   * 基础 `PlayerView` 只负责 `KSPlayerLayer` 与时间回调，控件全部交给
//     下面的 SwiftUI 播放条，观感与详情页 / 时间表保持同一套语言。
//
//  视频视图由本文件手动加进 `PlayerView`：KSPlayer 的基础视图不会自己插，
//  只有 `VideoPlayerView` 才会。
//

import AVFoundation
import KSPlayer
import Observation
import SwiftUI
import UIKit

/// 播放画面对外暴露的状态与控制入口。
///
/// SwiftUI 的播放条读这里的 `currentTime` / `duration` / `isPlaying`；
/// 播放器（UIKit）通过协调器把状态写回来。
@MainActor
@Observable
final class PlayerSurfaceModel {
    var currentTime: Double = 0
    var duration: Double = 0
    /// 已缓冲到的时间点（相对视频开头），进度条据此画出缓冲段。
    var bufferedTime: Double = 0
    var isPlaying = false
    var isReady = false
    var errorMessage: String?

    weak var playerView: PlayerView?

    /// 期望的播放速率。AVPlayer 在暂停再播 / 换集后会回到 1.0，
    /// 因此就绪或重新起播时要按这个值再补一次，默认倍速才真正生效。
    var desiredRate: Float = 1.0

    /// 进入播放器时待恢复的进度：播放器就绪后只 seek 一次，
    /// 避免抢在加载完成前 seek，结果被内核回落到 0。
    var pendingResumeTime: Double?

    /// 正常播完（非出错）时的回调，交给页面处理自动连播。
    var onFinish: (@MainActor (PlayerSurfaceModel) -> Void)?

    /// 需要在播放区浮现的临时提示（首 / 末集提示等）；页面渲染并在 2 秒后清空。
    var toastMessage: String?

    func play() {
        playerView?.play()
        isPlaying = true
        applyDesiredRate()
    }

    func pause() {
        playerView?.pause()
        isPlaying = false
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
        playerView?.seek(time: time) { _ in }
        currentTime = time
    }

    func setPlaybackRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        desiredRate = rate
        applyDesiredRate()
    }

    /// 只在正在播放时下发速率：暂停时给 AVPlayer 设非零 rate 会直接把它拉起来。
    private func applyDesiredRate() {
        guard isPlaying else { return }
        playerView?.playerLayer?.player.playbackRate = desiredRate
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
        guard let player = playerView?.playerLayer?.player else { return }
        let value = player.playableTime
        guard value.isFinite, value >= 0 else { return }
        bufferedTime = value
    }

    /// 关闭播放器：先停内核再断引用，避免 KSPlayer 在析构时仍持有渲染线程。
    func stop() {
        playerView?.pause()
        playerView?.playerLayer?.stop()
        playerView?.playerLayer = nil
        isPlaying = false
    }

    func handleState(isPlaying: Bool, isReady: Bool, isFailed: Bool) {
        self.isPlaying = isPlaying
        if isPlaying {
            applyDesiredRate()
        }
        if isReady {
            self.isReady = true
            self.errorMessage = nil
            applyPendingResume()
        }
        if isFailed {
            self.isPlaying = false
            if errorMessage == nil {
                errorMessage = "播放器加载失败，请重试"
            }
        }
    }

    /// 播放结束（正常播完或出错）的收尾，由协调器调用。
    /// 出错只报错；只有确实播到结尾才触发 `onFinish`——
    /// 停止 / 换集也会走 finish 回调，那时当前时间离结尾很远，不能误触自动连播。
    func handleFinish(errorMessage: String?) {
        isPlaying = false
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
        currentTime = 0
        duration = 0
        bufferedTime = 0
        isReady = false
        pendingResumeTime = nil
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

// MARK: - 协调器

final class PlayerSurfaceCoordinator: NSObject, PlayerControllerDelegate {
    weak var surface: PlayerSurfaceModel?
    weak var overlay: DanmakuOverlayView?

    private var lastURL: URL?
    private var lastFilters: [String] = []
    /// 画面填充方式（对应原版 PlayerAspectRatio 的 BoxFit）。
    private var videoGravity: AVLayerVideoGravity = .resizeAspect
    /// 当前挂在 `PlayerView` 上的视频视图，换集时用来摘掉上一路。
    private weak var attachedVideoView: UIView?

    /// 只在地址或超分档位真的变了的时候重建资源，普通的状态刷新不打断播放。
    @MainActor
    func apply(
        url: URL,
        userAgent: String?,
        referer: String?,
        filters: [String],
        to view: PlayerView
    ) {
        let filtersChanged = filters != lastFilters
        guard lastURL != url || filtersChanged else { return }

        let resumeTime = filtersChanged && lastURL == url ? (surface?.currentTime ?? 0) : 0
        lastURL = url
        lastFilters = filters

        let options = KSOptions()
        // 规则站点普遍校验 UA 与 Referer，缺一不可。
        if let userAgent, !userAgent.isEmpty {
            options.userAgent = userAgent
            options.appendHeader(["User-Agent": userAgent])
        }
        if let referer, !referer.isEmpty {
            options.referer = referer
            options.appendHeader(["Referer": referer])
        }
        // 超分辨率不接 FFmpeg 内核，滤镜链在这里丢弃。
        //
        // 曾经的写法是按档位建 `KSMEPlayer`（FFmpeg 内核）并把滤镜链交给
        // `KSOptions.videoFilters`。它在起播时建不出滤镜图——日志里
        // `MEPlayerItem | Error parsing filterchain ...` 之后进程当场退出，
        // 也就是「起播即闪退」。在那条链路真正能用之前，画面只走 AVPlayer，
        // 宁可没有超分效果，也不能让播放器一开播就崩。
        //
        // 换集 / 换档位时先把上一路停掉，否则旧内核会继续出声。
        view.playerLayer?.stop()

        let layer = KSPlayerLayer(url: url, isAutoPlay: false, options: options)
        view.playerLayer = layer

        // 与 `PlayerView.set(url:options:)` 保持一致：清掉上一集的进度与字幕源。
        view.srtControl.url = url
        view.toolBar.currentTime = 0
        view.totalTime = 0

        KazumiLogBuffer.player("起播打点：layer 已建好，准备挂画面")
        attachVideoView(to: view)
        KazumiLogBuffer.player("起播打点：画面已挂上，调用 play()")
        layer.play()
        KazumiLogBuffer.player("起播打点：play() 已返回")

        if resumeTime > 1 {
            view.seek(time: resumeTime) { _ in }
        }
    }

    /// 把 `player.view` 铺满整个 PlayerView（弹幕层在它上面，仍然可见）。
    ///
    /// 换集 / 换内核都会产生新的 `player.view`，旧的必须显式摘掉：
    /// `PlayerView` 是 superview，会一直强持有它，内核自己析构也带不走。
    @MainActor
    private func attachVideoView(to view: PlayerView) {
        guard let layer = view.playerLayer, let videoView = layer.player.view else { return }
        if let previous = attachedVideoView, previous !== videoView {
            previous.removeFromSuperview()
        }
        attachedVideoView = videoView
        guard videoView.superview !== view else { return }
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(videoView, at: 0)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        Self.setVideoGravity(videoGravity, in: videoView)
    }

    /// 切换画面填充方式（自动 / 裁切 / 拉伸 / 4:3 共用同一套处理）。
    @MainActor
    func applyVideoGravity(_ gravity: AVLayerVideoGravity) {
        videoGravity = gravity
        guard let view = attachedVideoView else { return }
        Self.setVideoGravity(gravity, in: view)
    }

    /// KSPlayer 的视频视图由内核创建，AVPlayerLayer 可能就在它自己的 layer 上，
    /// 也可能包在一两层子视图里；两种都找一遍。
    /// FFmpeg 内核（超分开启时）没有 AVPlayerLayer，这里会自然退化为不处理。
    private static func setVideoGravity(
        _ gravity: AVLayerVideoGravity,
        in view: UIView,
        depth: Int = 0
    ) {
        if let layer = view.layer as? AVPlayerLayer {
            layer.videoGravity = gravity
            return
        }
        for sublayer in view.layer.sublayers ?? [] {
            if let layer = sublayer as? AVPlayerLayer {
                layer.videoGravity = gravity
                return
            }
        }
        guard depth < 3 else { return }
        for subview in view.subviews {
            setVideoGravity(gravity, in: subview, depth: depth + 1)
        }
    }

    // MARK: PlayerControllerDelegate

    func playerController(state: KSPlayerState) {
        // KSPlayerState 不是 Sendable，不能直接捕获进 Task。
        // 先在当前 actor 上折成三个 Bool，再交给主线程写状态。
        let isPlaying = state.isPlaying
        let isReady = state == .readyToPlay
        let isFailed = state == .error
        KazumiLogBuffer.player("起播打点：内核状态 playing=\(isPlaying) ready=\(isReady) failed=\(isFailed)")
        let target = surface
        Task { @MainActor in
            target?.handleState(isPlaying: isPlaying, isReady: isReady, isFailed: isFailed)
        }
    }

    func playerController(currentTime: TimeInterval, totalTime: TimeInterval) {
        let target = surface
        Task { @MainActor in
            target?.updateTime(current: currentTime, total: totalTime)
            target?.refreshBufferedTime()
        }
    }

    func playerController(finish error: Error?) {
        let message = error?.localizedDescription
        let target = surface
        Task { @MainActor in
            target?.handleFinish(errorMessage: message)
        }
    }

    func playerController(maskShow: Bool) {}

    func playerController(action: PlayerButtonType) {}

    func playerController(bufferedCount: Int, consumeTime: TimeInterval) {}

    func playerController(seek: TimeInterval) {}
}

// MARK: - SwiftUI 包装

struct KSPlayerContainer: UIViewRepresentable {
    let url: URL
    let referer: String?
    let userAgent: String?
    /// 超分辨率滤镜链（空数组表示关闭）。
    let videoFilters: [String]
    /// 画面填充方式（自动 = 等比适配，裁切 = 等比填满，拉伸 = 不保持比例）。
    let videoGravity: AVLayerVideoGravity
    let danmaku: [DanmakuComment]
    /// 弹幕观感（显示开关、区域、持续时间、行高、描边、字重等，见 DanmakuOverlayView.Style）。
    let danmakuStyle: DanmakuOverlayView.Style
    /// 当前播放倍速，「弹幕跟随视频倍速」开着时用它算停留时间。
    let danmakuPlaybackRate: Double
    let surface: PlayerSurfaceModel

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.delegate = context.coordinator

        let overlay = DanmakuOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.playerView = view
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        context.coordinator.surface = surface
        context.coordinator.overlay = overlay
        surface.playerView = view
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        context.coordinator.surface = surface
        context.coordinator.apply(
            url: url,
            userAgent: userAgent,
            referer: referer,
            filters: videoFilters,
            to: uiView
        )
        context.coordinator.applyVideoGravity(videoGravity)
        context.coordinator.overlay?.apply(
            comments: danmaku,
            style: danmakuStyle,
            playbackRate: danmakuPlaybackRate
        )
    }

    func makeCoordinator() -> PlayerSurfaceCoordinator {
        PlayerSurfaceCoordinator()
    }

    static func dismantleUIView(_ uiView: PlayerView, coordinator: PlayerSurfaceCoordinator) {
        coordinator.overlay?.playerView = nil
        coordinator.overlay = nil
        coordinator.surface?.playerView = nil
        uiView.delegate = nil
        uiView.playerLayer?.stop()
        uiView.playerLayer = nil
    }
}
