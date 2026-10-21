//
//  TimelineScreen.swift
//  Kazumi
//
//  新番时间表（对应 lib/pages/timeline/）。
//

import SwiftUI

struct TimelineScreen: View {
    var body: some View {
        ScreenPlaceholder(
            title: "新番时间表",
            symbolName: "calendar",
            message: "按星期分列展示当季新番的放送时刻。"
        )
    }
}
