//
//  AppRoot.swift
//  Kazumi
//
//  根视图：存储失败时展示错误页；否则进入自适应液态玻璃 TabView。
//

import SwiftUI

struct AppRoot: View {
    var failure: AppEnvironment.StartupFailure?

    var body: some View {
        if let failure {
            StorageErrorView(failure: failure)
        } else {
            KazumiTabShell()
        }
    }
}
