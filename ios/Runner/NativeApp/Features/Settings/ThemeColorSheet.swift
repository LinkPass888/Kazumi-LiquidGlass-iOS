//
//  ThemeColorSheet.swift
//  Kazumi
//
//  设置页「配色方案」（对照 lib/pages/settings/theme_settings_page.dart 的
//  配色对话框与 lib/bean/card/palette_card.dart）。
//  原版卡片用 primary / tertiary / primaryContainer 三色调拼成双色块；
//  这里只取该方案的主题色画单色圆，选中时叠一枚勾选圆点，
//  用系统 Sheet + 自适应网格承载 9 个方案与即时生效的交互。
//

import SwiftUI

struct ThemeColorSheet: View {
    @Binding var selection: KazumiThemeColor
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 74), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(KazumiThemeColor.all) { color in
                        Button {
                            selection = color
                        } label: {
                            VStack(spacing: 8) {
                                KazumiPaletteCard(color: color, selected: color == selection)
                                Text(color.title)
                                    .font(.footnote)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(color == selection ? [.isSelected] : [])
                    }
                }
                .padding(20)
            }
            .navigationTitle("配色方案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// 配色卡片：只用该方案的主题色（浅色 T40 / 深色 T80）画一个实心圆，
/// 选中时叠一枚勾选圆点。
private struct KazumiPaletteCard: View {
    let color: KazumiThemeColor
    let selected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(uiColor: color.accentUIColor))
            if selected {
                Circle()
                    .fill(checkmarkBackground)
                    .frame(width: 25, height: 25)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(checkmarkForeground)
                    }
            }
        }
        .frame(width: 70, height: 70)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(Color.primary.opacity(selected ? 0.45 : 0.08), lineWidth: selected ? 2 : 1)
        }
    }

    private var checkmarkBackground: Color {
        colorScheme == .dark ? .white.opacity(0.9) : KazumiThemeColor.color(color.lightPrimary)
    }

    private var checkmarkForeground: Color {
        colorScheme == .dark ? .black : .white
    }
}

/// 设置行里的小色块。
struct KazumiThemeColorSwatch: View {
    let color: KazumiThemeColor
    var size: CGFloat = 16

    var body: some View {
        Circle()
            .fill(Color(uiColor: color.accentUIColor))
            .frame(width: size, height: size)
            .overlay {
                Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}
