//
//  BangumiInfoScreen.swift
//  Kazumi
//
//  番剧详情（对应 lib/pages/info/）。
//

import SwiftUI

struct BangumiInfoScreen: View {
    var bangumiID: Int

    var body: some View {
        ScreenPlaceholder(
            title: "番剧详情",
            symbolName: "info.circle",
            message: "剧照、评分、角色与剧集信息。"
        )
    }
}
