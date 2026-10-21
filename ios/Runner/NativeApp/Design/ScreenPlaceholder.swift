//
//  ScreenPlaceholder.swift
//  Kazumi
//
//  Step 1 的页面外壳：先把导航骨架与液态玻璃观感搭好，
//  各页面的真实内容在 Step 2~5 依次替换本文件的使用处。
//  这是纯视觉占位（含标题、图标与说明），不是业务实现的占位符。
//

import SwiftUI

struct ScreenPlaceholder: View {
    var title: String
    var symbolName: String
    var message: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            KazumiPalette.heroBackground(for: colorScheme)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: symbolName)
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(KazumiPalette.accent)
                Text(title)
                    .font(.title2.bold())
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    .padding(.horizontal, 24)
            }
            .padding(28)
            .kazumiGlassCard(cornerRadius: 28)
            .padding(24)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
