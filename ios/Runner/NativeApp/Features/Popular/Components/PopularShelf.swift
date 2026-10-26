//
//  PopularShelf.swift
//  Kazumi
//
//  推荐页的一行货架（Colo 规格 §3）：
//  * 行标题 20 semibold，左边距 16，距海报 10，距上一行 24；
//  * 「更多」15 medium 强调色，**同一行里贴右 16**（LP 2743/2746 定的：
//    不贴着分组名，是同行居右），与标题同一条基线；
//  * 它在横向货架外面：页面竖着滚它跟着走，海报横滑它不动；
//  * 横向 ScrollView + LazyHStack，内容左右各 16，一张 96 宽海报 + 12 间距，
//    一屏看得见三张多一点、第四张露 53——这就是「还能往右滑」的唯一提示。
//

import SwiftUI

struct PopularShelf: View {
    let row: PopularRow
    var zoomNamespace: Namespace.ID?
    var onMore: (PopularListSource) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(row.items) { poster in
                        PopularPosterTile(poster: poster, zoomNamespace: zoomNamespace)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            // 没有对应列表页的行不放这颗字——点了没地方去比没有更糟。
            if let list = row.list {
                Button {
                    onMore(list)
                } label: {
                    Text("更多")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                }
                .buttonStyle(.plain)
                .hitTarget44()
                .accessibilityLabel("更多\(row.title)")
            }
        }
        .padding(.horizontal, 16)
    }
}
