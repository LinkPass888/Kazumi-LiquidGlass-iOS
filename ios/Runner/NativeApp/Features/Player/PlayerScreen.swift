//
//  PlayerScreen.swift
//  Kazumi
//
//  播放器（对应 lib/pages/player/）。
//  Step 4 接入 KSPlayer + Anime4K + 弹幕层 + SyncPlay + 投屏。
//

import SwiftUI

struct PlayerScreen: View {
    var bangumiID: Int
    var episode: Int

    var body: some View {
        ScreenPlaceholder(
            title: "播放器",
            symbolName: "play.rectangle",
            message: "KSPlayer 播放内核与液态玻璃 OSD。"
        )
    }
}
