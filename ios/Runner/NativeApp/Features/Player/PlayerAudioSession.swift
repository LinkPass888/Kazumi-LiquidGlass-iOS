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
import MediaPlayer

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
    ///
    /// `.allowAirPlay` / `.allowBluetoothA2DP` 必须跟着写：`setCategory` 的 options
    /// 是整体替换，不写就等于把启动时那份投屏能力抹掉——播放中点投屏就选不到设备了。
    func applyPlaybackCategory() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .moviePlayback,
                policy: .longFormVideo,
                options: [.allowAirPlay, .allowBluetoothA2DP]
            )
            try session.setActive(true)
        } catch {
            // 以前这里用 `try?` 把错误吞掉了。会话正在出声的时候改类别是会失败的，
            // 吞掉就等于「以为改回来了，其实还是 mpv 设的混音」——而混音的会话
            // 不会被 iOS 当成正在播放，控制中心/锁屏那张卡就永远不出来。
            KazumiLogBuffer.player("音频会话配置失败：\(error.localizedDescription)")
        }
    }

    /// 把当前会话的真实状态写进「播放」日志，真机上能直接看出系统看到的是什么。
    ///
    /// 只读，不改任何东西：这是 `mixWithOthers` 那条推断的证据来源——
    /// 推断靠读回，不靠猜。
    func logSnapshot(_ tag: String) {
        let session = AVAudioSession.sharedInstance()
        let options = session.categoryOptions
        var flags: [String] = []
        if options.contains(.mixWithOthers) { flags.append("mixWithOthers") }
        if options.contains(.duckOthers) { flags.append("duckOthers") }
        if options.contains(.interruptSpokenAudioAndMixWithOthers) { flags.append("mixSpoken") }
        if options.contains(.allowBluetooth) { flags.append("hfp") }
        if options.contains(.allowBluetoothA2DP) { flags.append("a2dp") }
        if options.contains(.allowAirPlay) { flags.append("airplay") }
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        KazumiLogBuffer.player(
            "[会话] \(tag) 类别=\(session.category.rawValue) 模式=\(session.mode.rawValue)"
            + " 选项=[\(flags.joined(separator: ","))]"
            + " 卡片字段=\(info?.count ?? 0)"
            + " 状态=\(MPNowPlayingInfoCenter.default().playbackState.rawValue)"
        )
    }

    /// 起播后再配一次：mpv 的 audiounit 输出初始化时可能已经把类别重设过。
    ///
    /// 只查不写是错的：会话在出声时改类别可能被系统拒绝，那就得退一次再上。
    /// 所以这里先就地改，读回还是混音就把会话退掉重配一次，并把结果写进日志——
    /// 成没成都要留证据。
    func reapplyIfNeeded() {
        let session = AVAudioSession.sharedInstance()
        guard session.categoryOptions.contains(.mixWithOthers) || session.category != .playback else {
            return
        }
        let before = describe(session)
        applyPlaybackCategory()
        if session.categoryOptions.contains(.mixWithOthers) || session.category != .playback {
            // 就地改被拒了：退一次再上。只在真的被盖成混音时才走，不是每 2 秒一次。
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            applyPlaybackCategory()
        }
        let after = describe(session)
        logSessionChange("音频会话被重设：\(before) → \(after)", state: after)
    }

    private func describe(_ session: AVAudioSession) -> String {
        let mixing = session.categoryOptions.contains(.mixWithOthers) ? "混音" : "独占"
        return "\(session.category.rawValue)/\(mixing)"
    }

    /// 上一次写进日志的会话描述：同样的状态不重复写，
    /// 不然每 2 秒一条，200 条的缓冲两下就被自己刷满。
    private var lastLoggedSessionState: String?

    private func logSessionChange(_ message: String, state: String) {
        guard lastLoggedSessionState != state else { return }
        lastLoggedSessionState = state
        KazumiLogBuffer.player(message)
    }

    /// 离开播放器时调用：退回启动那套类别并放开会话，别让整个 App 一直占着播放位。
    ///
    /// 这里不能用 `.soloAmbient`：它会连投屏一起关掉（启动时 AppDelegate 配了
    /// `.allowAirPlay`），退出播放器后再进就选不到投屏设备了。
    ///
    /// `setActive(false)` 是注释本来就说要做的事，之前没写：离开播放器后会话一直挂着
    /// `.playback`，等于对系统宣称「这个 App 还在占播放位」。通知开着
    /// `.notifyOthersOnDeactivation`，让被打断的别的 app 自己能接回去。
    func restore() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // 会话本来就没激活时会报错，这里不是问题，不写日志免得误导。
        }
        do {
            try session.setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.allowAirPlay, .allowBluetoothA2DP]
            )
        } catch {
            KazumiLogBuffer.player("退出播放器后回落会话类别失败：\(error.localizedDescription)")
        }
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
