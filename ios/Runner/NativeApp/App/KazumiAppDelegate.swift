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

import SwiftUI
import UIKit

/// 应用入口挂在 AppDelegate 上，而不是 SwiftUI 的 `App`。
///
/// 原因只有一个：锁屏 / 灵动岛 / 控制中心那张卡被点之后，SpringBoard 要按
/// `Info.plist` 里的 `UISceneConfigurations` 找一个**真的场景代理**来激活场景。
/// 用 `@main struct … : App` 时那个代理是 SwiftUI 私有的 `AppSceneDelegate`，
/// 系统那边拿不到能用的入口，点卡片就只展开、不回 App（LP 5008/5534）。
///
/// 之前两次尝试都失败在这条路上，教训写在这里，别再重走：
///   * `configurationForConnecting` 里返回空白配置 → 路由落到没有对应条目的名字上；
///   * 原样透传 SwiftUI 的配置 → 真机递归崩（`SwiftUI.AppSceneDelegate` 互调）。
/// 现在的写法（LP 5584/5585）：`configurationForConnecting` 显式返回一份指名
/// `KazumiSceneDelegate` 的配置（纯 UIKit 入口，没有 SwiftUI 场景代理可互调），
/// 场景代理自己建窗口，窗口挂好之后才成为 FirstResponder 并声明收远程控制事件。
@main
final class KazumiAppDelegate: UIResponder, UIApplicationDelegate {
    /// 响应者链的最末端。LP 5584/5585 要求照那份意见把这一处补齐：
    /// App 代理进响应者链、窗口建好之后成为 FirstResponder，再声明收远程控制事件。
    override var canBecomeFirstResponder: Bool { true }

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
        // 「我要收远程控制事件」（LP 4738）。**这句现在挪到场景窗口建好之后**
        // （见 KazumiSceneDelegate.scene(_:willConnectTo:)）：启动这一刻整个 App
        // 还没有 UIWindow、也没有活跃的响应者，早叫一次没有意义（LP 5584 那份意见）。
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 定位「点卡片不回 App」用的判据（Fuck 5597）：这条来自 UIApplication，
        // 不管播放页在不在都会打。点完卡片它要是没出现，就是系统压根没把激活
        // 送进 App；出现了而下面场景那条也有，才是 App 被叫起来了。
        KazumiLogBuffer.player("App 代理：applicationDidBecomeActive")
        NotificationCenter.default.post(name: .kazumiAppDidBecomeActive, object: nil)
    }

    // ⚠️ 这一段是历史，留给孩子看：`configurationForConnecting` 曾经两次翻车，
    // 现在的实现见下面那个方法（LP 5584：翻车是别的地方没改对）。
    //
    // 两次都踩在同一处：
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
    // 当时的结论是「什么都不写」。现在的结论：入口换成纯 UIKit 之后，
    //    返回一份指名 `KazumiSceneDelegate` 的配置是标准写法，也不会再有 SwiftUI
    //    那层代理跟它互调（LP 5584）。

    /// 显式给出场景配置（LP 5584/5585：照那份意见补齐）。
    ///
    /// 之前两次翻车都记在上面：一次返回**空白**配置导致点卡片不进 App；一次**原样
    /// 透传** `connectingSceneSession.configuration`，那份里带着 SwiftUI 的
    /// `AppSceneDelegate`，UIKit 装一遍、SwiftUI 再装一遍，真机栈溢出递归崩。
    ///
    /// 现在入口已经是纯 UIKit 的 `@main KazumiAppDelegate`，进程里没有 SwiftUI 的
    /// 场景代理可绕，这里返回一份**指名 KazumiSceneDelegate** 的配置就是 Apple 的
    /// 标准写法（LP 5584：之前翻车是别的地方没改对）。
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        config.sceneClass = UIWindowScene.self
        config.delegateClass = KazumiSceneDelegate.self
        return config
    }

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


// MARK: - 场景

/// 场景代理：真正拿 `UIWindow` 把 SwiftUI 视图挂上去的那一层。
///
/// 之前 `86fecd3` 那一版里这个类是空壳，于是 `Info.plist` 一旦指向它，
/// UIKit 就不再走 SwiftUI 的 `WindowGroup`，而空壳又不建窗口——黑屏。
/// 现在窗口由它自己建、自己 `makeKeyAndVisible()`，两条路都通。
///
/// `@objc(KazumiSceneDelegate)` 是给 `Info.plist` 里的类名用的：
/// 那张表是按 Objective-C 运行时按名字找类的，不加这个注解就找不到。
@objc(KazumiSceneDelegate)
final class KazumiSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let host = RemoteControlHostingController(rootView: KazumiRootView())
        // 画面自己铺满；背景交给 SwiftUI 的主题色，别让窗口底色在转场时闪一下白。
        host.view.backgroundColor = .clear
        window.rootViewController = host
        self.window = window
        window.makeKeyAndVisible()

        // 窗口挂上去之后才成为 FirstResponder、才声明收远程控制事件：
        // 启动那一刻还没有窗口，那时调用等于空转（LP 5584 那份意见）。
        Self.declareRemoteControlEvents(on: host)
        KazumiLogBuffer.player("场景窗口已就绪：已声明 beginReceivingRemoteControlEvents")
        // 走到 willConnectTo 就是「新建了一个场景」，也就是进程刚起来（冷启动）。
        // 点卡片之后日志里出现这句，说明 App 之前已经被系统回收掉了（Fuck 5597）。
        KazumiLogBuffer.player("场景：willConnectTo（新建场景，说明进程是刚起来的）")
    }

    /// 把宿主控制器顶成 FirstResponder，再向系统声明「这个 App 要收远程控制事件」。
    ///
    /// `UIHostingController` 的 `canBecomeFirstResponder` 默认是 false、而且是只读的，
    /// 所以用下面那个子类把它打开。拿不到第一响应者也照样要调
    /// `beginReceivingRemoteControlEvents()`——后者是 App 级声明，不依赖响应者链。
    @MainActor
    private static func declareRemoteControlEvents(on host: UIViewController) {
        _ = host.becomeFirstResponder()
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // 场景层的判据（Fuck 5597）：这条有、播放页那条「回前台」没有，
        // 说明 App 起来了但播放页不在——那就是被整个杀掉过后的冷启动。
        KazumiLogBuffer.player("场景：sceneDidBecomeActive")
        // 与 AppDelegate 那条一样：进前台时刷新设置、续上被系统掐掉的东西。
        NotificationCenter.default.post(name: .kazumiAppDidBecomeActive, object: nil)
    }
}

/// 能成为第一响应者的宿主控制器。
///
/// `canBecomeFirstResponder` 在 `UIViewController` 上是只读属性，只能靠子类重写打开；
/// 打开之后 `becomeFirstResponder()` 才会成功，远程控制事件才有响应者可投递。
private final class RemoteControlHostingController<Content: View>: UIHostingController<Content> {
    override var canBecomeFirstResponder: Bool { true }
}
