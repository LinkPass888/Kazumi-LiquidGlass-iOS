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
    var isPlaying = false
    var isReady = false
    var errorMessage: String?

    weak var playerView: PlayerView?

    func play() {
        playerView?.play()
        isPlaying = true
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
        playerView?.playerLayer?.player.playbackRate = rate
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
        if isReady {
            self.isReady = true
            self.errorMessage = nil
        }
        if isFailed {
            self.isPlaying = false
            if errorMessage == nil {
                errorMessage = "播放器加载失败，请换一条线路重试"
            }
        }
    }

    func updateTime(current: Double, total: Double) {
        currentTime = max(0, current)
        if total.isFinite, total > 0 {
            duration = total
        }
    }
}

// MARK: - 协调器

final class PlayerSurfaceCoordinator: NSObject, PlayerControllerDelegate {
    weak var surface: PlayerSurfaceModel?
    weak var overlay: DanmakuOverlayView?

    private var lastURL: URL?
    private var lastFilters: [String] = []
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
        options.videoFilters = filters

        // FFmpeg 滤镜链只在 MEPlayer 内核下生效，AVPlayer 会直接忽略。
        //
        // 这里刻意不去改 `KSOptions.firstPlayerType`：那是 KSPlayer 的全局静态
        // 可变属性，在 Swift 6 严格并发下客户端读写会被判定为不安全。
        // 改成自己建 layer（`isAutoPlay: false`）后替换 `playerLayer.player`，
        // 既绕开全局状态，也避免先按默认内核起播再换掉的双重加载。
        //
        // 换集 / 换档位时先把上一路停掉，否则旧内核会继续出声。
        view.playerLayer?.stop()

        let layer = KSPlayerLayer(url: url, isAutoPlay: false, options: options)
        view.playerLayer = layer
        if !filters.isEmpty {
            let previous = layer.player
            layer.player = KSMEPlayer(url: url, options: options)
            previous.shutdown()
        }

        // 与 `PlayerView.set(url:options:)` 保持一致：清掉上一集的进度与字幕源。
        view.srtControl.url = url
        view.toolBar.currentTime = 0
        view.totalTime = 0

        attachVideoView(to: view)
        layer.play()

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
    }

    // MARK: PlayerControllerDelegate

    func playerController(state: KSPlayerState) {
        let target = surface
        Task { @MainActor in
            target?.handleState(
                isPlaying: state.isPlaying,
                isReady: state == .readyToPlay,
                isFailed: state == .error
            )
        }
    }

    func playerController(currentTime: TimeInterval, totalTime: TimeInterval) {
        let target = surface
        Task { @MainActor in
            target?.updateTime(current: currentTime, total: totalTime)
        }
    }

    func playerController(finish error: Error?) {
        let message = error?.localizedDescription
        let target = surface
        Task { @MainActor in
            target?.handleState(isPlaying: false, isReady: false, isFailed: false)
            if let message {
                target?.errorMessage = message
            }
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
    let danmaku: [DanmakuComment]
    let danmakuEnabled: Bool
    let danmakuOpacity: Double
    let danmakuFontSize: Double
    let danmakuArea: Double
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
        context.coordinator.overlay?.apply(
            comments: danmaku,
            enabled: danmakuEnabled,
            opacity: danmakuOpacity,
            fontSize: danmakuFontSize,
            area: danmakuArea
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
