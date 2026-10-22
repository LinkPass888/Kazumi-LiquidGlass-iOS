//
//  AppRoot.swift
//  Kazumi
//
//  根视图：存储失败时展示错误页；否则进入自适应液态玻璃 TabView。
//  启动后先检查应用更新（有新版就弹更新日志），再检查规则更新。
//

import SwiftUI

struct AppRoot: View {
    var failure: AppEnvironment.StartupFailure?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL

    @State private var isShowingAppUpdate = false

    var body: some View {
        Group {
            if let failure {
                StorageErrorView(failure: failure)
            } else {
                KazumiTabShell()
            }
        }
        .task {
            guard failure == nil else { return }
            await environment.updates.checkOnLaunch(
                settings: environment.settings,
                plugins: environment.plugins
            )
            if environment.updates.appUpdate != nil {
                isShowingAppUpdate = true
            }
        }
        .alert(
            "发现新版本 \(environment.updates.appUpdate?.version ?? "")",
            isPresented: $isShowingAppUpdate
        ) {
            Button("查看更新日志") {
                openURL(KazumiAppInfo.releasesURL)
                environment.updates.appUpdate = nil
            }
            Button("稍后", role: .cancel) {
                environment.updates.appUpdate = nil
            }
        } message: {
            Text(updateMessage)
        }
    }

    /// 更新日志：release body 可能很长，这里截断成几行提示。
    private var updateMessage: String {
        let notes = environment.updates.appUpdate?.notes ?? ""
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "当前版本 \(KazumiAppInfo.fullVersion)，可以到项目主页下载新版本。"
        }
        return String(trimmed.prefix(400))
    }
}
