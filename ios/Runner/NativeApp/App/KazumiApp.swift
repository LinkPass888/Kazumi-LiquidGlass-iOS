//
//  KazumiApp.swift
//  Kazumi
//
//  纯 SwiftUI 应用入口（取代 Flutter 的 main.dart / AppWidget）。
//  Flutter 引擎、GeneratedPluginRegistrant、Modular 路由树全部移除，
//  启动流程与原 lib/main.dart 对齐：先初始化本地存储，失败时进入存储错误页。
//

import SwiftUI

@main
struct KazumiApp: App {
    @UIApplicationDelegateAdaptor(KazumiAppDelegate.self) private var appDelegate

    @State private var environment: AppEnvironment
    @State private var storageFailure: AppEnvironment.StartupFailure?

    init() {
        let result = AppEnvironment.makeAtLaunch()
        _environment = State(initialValue: result.environment)
        _storageFailure = State(initialValue: result.failure)
    }

    var body: some Scene {
        WindowGroup {
            AppRoot(failure: storageFailure)
                .environment(environment)
                .environment(environment.settings)
                .environment(environment.library)
                .environment(environment.router)
                .environment(environment.plugins)
                .preferredColorScheme(environment.settings.themeMode.preferredColorScheme)
                .tint(KazumiPalette.accent)
                // 配色方案与 OLED 纯黑是全局状态（`KazumiPalette` 为静态取值），
                // 用 id 让视图树在切换后整体重建，背景与强调色立即生效。
                .id("\(environment.settings.themeColor.id)-\(environment.settings.oledEnhance)")
        }
    }
}

