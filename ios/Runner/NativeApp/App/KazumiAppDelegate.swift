//
//  KazumiAppDelegate.swift
//  Kazumi
//
//  仅保留 UIKit 侧必须的能力：
//   1. 忽略 SIGPIPE，免得对端关连接时把整个进程带走；
//   2. 静音网络下的启动检查入口（对应 MeteredNetworkService.refresh）；
//   3. 应用进入前台时刷新设置（对应 app_widget.dart 的 didChangeAppLifecycleState）。
//  其余窗口生命周期交给 SwiftUI。
//
//  **启动时一概不碰 AVAudioSession**（LP 4938）：这里以前会 `setCategory(.playback)`
//  再 `setActive(true)`，App 一冷启动就向系统申请独占的播放会话，首页还没点播放，
//  后台正在放歌的其它 App 就被掐断了。音频会话只由 `PlayerAudioSession` 管：
//  进播放器才配 `.playback` 并激活，退出时 `restore()` 退回去。
//  Info.plist 里的 `UIBackgroundModes: audio` 不受影响——它声明的是「允许」，
//  要不要出声由会话决定。
//

import UIKit

final class KazumiAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 忽略 SIGPIPE：往已经关掉的 socket 写数据时，默认行为是直接干掉整个进程
        // （日志里的 `terminated (exit 141)` 就是 128 + 13）。流媒体解析、换集、
        // 取消加载时连接被对端关掉是常事，不该因此把 App 杀掉。
        signal(SIGPIPE, SIG_IGN)
        UITabBar.appearance().isHidden = false
        UITableView.appearance().backgroundColor = .clear
        // 锁屏 / 灵动岛那张卡要认到「是这个 App 在放」，得显式声明一句
        // 「我要收远程控制事件」（LP 4738）。没有这一句，系统只当我们放了一段
        // 普通音频流：卡能出来，但点它不回这个 App，退到后台时也不按我们的
        // 进程收（LP 4715：别的 App 点一下进 App、长按才展开，我们反过来）。
        // 现代 iOS 真正的按钮回调走 MPRemoteCommandCenter（NowPlayingCenter），
        // 这行是老接口，但它就是那个「显式声明」，两样都要有。
        //
        // 这行跟音频会话无关，不抢播放位，所以留在启动路径上；`AVAudioSession`
        // 那一整套配置按 LP 4938 已经挪走（见文件头）。
        UIApplication.shared.beginReceivingRemoteControlEvents()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        NotificationCenter.default.post(name: .kazumiAppDidBecomeActive, object: nil)
    }

    // ⚠️ 这里**故意不实现** `application(_:configurationForConnecting:options:)`。
    //
    // 这件事的完整教训（两次都踩在同一处）：
    //
    // 1）LP 4978 那版在这里 return 了一份**新建的空白配置**
    //    `UISceneConfiguration(name: "Default Configuration", …)`。系统拿到非 nil 就
    //    不再用它自己准备好那份，而 "Default Configuration" 在 plist 的 scene manifest
    //    里根本没有对应条目（manifest 只有 UIApplicationSupportsMultipleScenes）。
    //    界面照常起、卡片画得出来、控制中心键也能用，但「把 App 带到前台」这条
    //    场景激活路由落到空配置上——表现就是点灵动岛/锁屏卡片只展开、不进 App（LP 5008）。
    //
    // 2）于是下一版改成「**原样透传** `connectingSceneSession.configuration`」，
    //    看着最干净，`8cc5956e` 在我这台 iOS 27.2 模拟器上也真能起。
    //    但 iOS 27.0.1 真机上**启动必崩**（LP 5019 的崩溃报告）：
    //    `Thread stack size exceeded due to excessive recursion`，thread 0 栈溢出，
    //    递归是 `SwiftUI.AppSceneDelegate.responds(to:)` ⇄
    //    `AppSceneDelegate.scene(_:willConnectTo:options:)` 互为调用，
    //    入口是 `-[UIScene setDelegate:]` → `_UISceneInspectDelegateSuport`。
    //    也就是说：从我们这层递出去一份**已经带着 SwiftUI 的 delegateClass** 的配置，
    //    UIKit 会装一遍 SwiftUI 的场景代理，SwiftUI 自己再装一遍，两边绕死。
    //
    // 正解就是**什么都不写**：不实现这个方法，SwiftUI 自己的主代理会给出它要的那份
    //    配置，场景代理只被装一次。之前「删了会拿不到 delegate class」是没验过的猜测。

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // WebDAV / 下载任务使用的后台 URLSession：尽快回调，避免系统终止任务。
        completionHandler()
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

/// 场景代理的占位实现，只为了让 Info.plist 那张场景路由表有条目可指（LP 5025）。
///
/// 这个类**不建窗口、不挂 storyboard**：窗口是 SwiftUI 的 `AppSceneDelegate` +
/// `WindowGroup` 建的，真实 delegateClass 由 SwiftUI 自己填。
/// 它存在的意义只有一条：SpringBoard 点灵动岛/锁屏卡唤起 App 时要查
/// `UISceneConfigurations` 里 `UIWindowSceneSessionRoleApplication` 这一条的类名，
/// 缺了它系统手里就没有可用的场景配置，点了只会展开卡片。
@objc(KazumiSceneDelegate)
final class KazumiSceneDelegate: UIResponder, UIWindowSceneDelegate {}
