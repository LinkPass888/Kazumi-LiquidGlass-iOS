//
//  PlayerAudioSession.swift
//  Kazumi
//
//  播放时的音频会话，以及系统对它的干扰（来电、别的 app 抢音频、拔耳机）。
//
//  三件事，缺一件在真机上都能看见：
//
//  1. 播放器开着就配成 `.playback` 并激活。系统只把「播放类别」的 app 当成
//     正在播放的播放器——不是这个类别，控制中心、锁屏、灵动岛都不会有卡片。
//     main（Flutter 版）的 `AudioSessionConfiguration.music()` 也是无条件的，
//     我们曾经把它挂在一颗默认关的开关上，那是偏离。
//  2. 来电、Siri、别的 app 抢音频 → 暂停；中断结束且系统说可以恢复 → 接着播。
//  3. 拔耳机、蓝牙断连（`oldDeviceUnavailable`）→ 暂停，别对着外放继续响。
//

import AVFoundation

@MainActor
final class PlayerAudioSession {
    static let shared = PlayerAudioSession()

    /// 中断、断连时要停的那块画面。
    weak var surface: PlayerSurfaceModel?

    /// 出问题时的日志钩子，接到播放页面的日志行上。
    var onLog: ((String) -> Void)?

    /// 中断之前是不是在播——只接回「因为中断才停的」那一次，
    /// 用户自己按的暂停不会被这里叫起来。
    private var wasPlayingBeforeInterruption = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - 类别与激活

    /// 播放器打开时调用。
    func activate() {
        applyPlaybackCategory()
        installObservers()
    }

    /// 把会话配成「长视频播放」并激活，不加 mixWithOthers。
    ///
    /// 两处细节都是为了控制中心那张卡：
    /// * 不加 `mixWithOthers`——混音的会话不会被 iOS 当成「正在播放」；
    /// * 用 `.longFormVideo` 路由策略，锁屏和控制中心按视频来画，而不是当成音乐。
    /// mpv 的音频输出会在开始出声时自己重设一次类别（会盖掉这里的设置），
    /// 所以起播后要再调一次 `reapplyIfNeeded()`。
    func applyPlaybackCategory() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
        try? session.setActive(true)
    }

    /// 起播后再配一次：mpv 的 audiounit 输出初始化时可能已经把类别重设过。
    func reapplyIfNeeded() {
        let session = AVAudioSession.sharedInstance()
        let mixing = session.categoryOptions.contains(.mixWithOthers)
        if mixing || session.category != .playback {
            onLog?("音频会话被重置（mixing=\(mixing)），重新配置")
            applyPlaybackCategory()
        }
    }

    /// 离开播放器时调用：退回默认类别，别让整个 App 一直占着播放位。
    func restore() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.soloAmbient, mode: .default, options: [])
        removeObservers()
        wasPlayingBeforeInterruption = false
    }

    // MARK: - 系统事件

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        // 队列固定给主队列，下面就能确定自己在主线程上。
        // 注意别把 Notification 本身递进主线程：它不是 Sendable，Swift 6 会直接拒。
        // 先把要用的两个值取成普通整数，再进隔离域。
        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] note in
                let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                MainActor.assumeIsolated {
                    self?.handleInterruption(rawType: rawType, rawOptions: rawOptions)
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] note in
                let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                MainActor.assumeIsolated {
                    self?.handleRouteChange(rawReason: rawReason)
                }
            }
        )
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    private func handleInterruption(rawType: UInt?, rawOptions: UInt) {
        guard let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            // 只有本来在播的才记：暂停着被打断，中断结束不该自己响起来。
            wasPlayingBeforeInterruption = surface?.isPlaying == true
            if wasPlayingBeforeInterruption {
                surface?.pause()
            }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            let shouldResume = wasPlayingBeforeInterruption && options.contains(.shouldResume)
            wasPlayingBeforeInterruption = false
            if shouldResume {
                surface?.play()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(rawReason: UInt?) {
        guard let rawReason,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }
        // 耳机拔了、蓝牙断了：系统不会替我们停，不停就变成外放。
        if reason == .oldDeviceUnavailable, surface?.isPlaying == true {
            surface?.pause()
        }
    }
}
