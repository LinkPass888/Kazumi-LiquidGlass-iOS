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
}
