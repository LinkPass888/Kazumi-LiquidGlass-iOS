//
//  KazumiAppDelegate.swift
//  Kazumi
//
//  仅保留 UIKit 侧必须的能力：
//   1. 后台音频会话（画中画 / 锁屏播放，对应原 Info.plist 的 UIBackgroundModes: audio）；
//   2. 静音网络下的启动检查入口（对应 MeteredNetworkService.refresh）；
//   3. 应用进入前台时刷新设置（对应 app_widget.dart 的 didChangeAppLifecycleState）。
//  其余窗口生命周期交给 SwiftUI。
//

import AVFAudio
import UIKit

final class KazumiAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureAudioSession()
        UITabBar.appearance().isHidden = false
        UITableView.appearance().backgroundColor = .clear
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        NotificationCenter.default.post(name: .kazumiAppDidBecomeActive, object: nil)
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // WebDAV / 下载任务使用的后台 URLSession：尽快回调，避免系统终止任务。
        completionHandler()
    }

    /// 播放器需要在锁屏与 PiP 下继续出声，因此使用 playback 类别。
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            KazumiLog.app.error("音频会话初始化失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Notification.Name {
    static let kazumiAppDidBecomeActive = Notification.Name("com.example.kazumi.appDidBecomeActive")

    /// 弹幕屏蔽词被改过。同步那边靠它做 500ms 防抖后上传（原版
    /// danmaku_shield_sync_service.dart 也是改完就同步，不是只等下次启动）。
    static let kazumiDanmakuRulesChanged = Notification.Name("com.example.kazumi.danmakuRulesChanged")
}

/// 全屏播放的临时方向锁。
///
/// `requestGeometryUpdate` 只有在 `supportedInterfaceOrientations` 也允许那个方向时才会生效，
/// 而 SwiftUI App 生命周期下这个值由 delegate 报。所以播放器进全屏时把 `mask` 改成横屏，
/// 退出时改回竖屏；其它页面一律 `portrait`，与 Info.plist 声明一致（竖横都支持，只改运行时锁）。
@MainActor
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .portrait
}

extension KazumiAppDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}
