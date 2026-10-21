//
//  SearchScreen.swift
//  Kazumi
//
//  关键字搜索（对应 lib/pages/search/）。
//

import SwiftUI

struct SearchScreen: View {
    var initialKeyword: String

    var body: some View {
        ScreenPlaceholder(
            title: "搜索",
            symbolName: "magnifyingglass",
            message: "按关键字聚合各规则源搜索结果。"
        )
    }
}
