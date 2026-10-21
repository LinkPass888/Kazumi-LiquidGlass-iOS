//
//  PopularScreen.swift
//  Kazumi
//
//  推荐首页（对应 lib/pages/popular/）。
//  顶部为焦点巨幅海报 Hero Showcase，下方为横向片单流（Shelves）。
//

import SwiftUI

struct PopularScreen: View {
    var body: some View {
        ScreenPlaceholder(
            title: "推荐",
            symbolName: "house.fill",
            message: "焦点巨幅海报与横向片单流将在这里呈现 Bangumi 热门番剧。"
        )
    }
}
