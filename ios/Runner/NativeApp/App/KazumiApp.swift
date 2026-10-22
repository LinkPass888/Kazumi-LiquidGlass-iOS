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
                .environment(environment.updates)
                .preferredColorScheme(environment.settings.themeMode.preferredColorScheme)
                // UIKit 动态色（`Color(uiColor:)`、material）按窗口的 trait 解析，
                // 必须把同一套亮度写到窗口上，否则系统亮度与应用主题不一致时
                // 强调色会取到相反那一档（浅色用深色配色，反之亦然）。
                .kazumiWindowStyle(environment.settings.themeMode)
                // 窗口 trait 已同步，动态色 `KazumiPalette.accent` 此时解析到的是
                // 与界面一致的亮度档位，这里可以直接用。
                .tint(KazumiPalette.accent)
                // 配色方案与 OLED 纯黑是全局状态（`KazumiPalette` 为静态取值），
                // 用 id 让视图树在切换后整体重建，背景与强调色立即生效。
                .id("\(environment.settings.themeColor.id)-\(environment.settings.oledEnhance)")
        }
    }
}

