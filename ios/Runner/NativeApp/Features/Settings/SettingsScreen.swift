//
//  SettingsScreen.swift
//  Kazumi
//
//  对应 lib/pages/settings/settings_page.dart 的原生子集：
//  外观（主题 / 液态玻璃）、播放（全屏进入 / 自动连播）、弹幕（开关 / 字号 / 不透明度）、
//  规则与数据（规则设置 / 同步备份 / 弹幕屏蔽 / 关于 / 日志）。
//

import SwiftUI

struct SettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppRouter.self) private var router

    @State private var isShowingThemeColorSheet = false

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: themeBinding) {
                    ForEach(KazumiThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Button {
                    isShowingThemeColorSheet = true
                } label: {
                    HStack {
                        Label("配色方案", systemImage: "paintpalette")
                        Spacer()
                        Text(settings.themeColor.title)
                            .foregroundStyle(.secondary)
                        KazumiThemeColorSwatch(color: settings.themeColor, size: 18)
                    }
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $isShowingThemeColorSheet) {
                    ThemeColorSheet(selection: themeColorBinding)
                }
                Toggle("液态玻璃效果", isOn: glassBinding)
                Toggle("OLED 优化", isOn: oledEnhanceBinding)
            }

            Section("播放") {
                Toggle("进入播放器即全屏", isOn: fullscreenBinding)
                Toggle("自动连播下一集", isOn: autoPlayNextBinding)
                Toggle("自动跳过片头片尾", isOn: autoSkipBinding)
            }

            Section("弹幕") {
                Toggle("显示弹幕", isOn: danmakuEnabledBinding)
                VStack(alignment: .leading) {
                    HStack {
                        Text("字号")
                        Spacer()
                        Text("\(Int(settings.danmakuFontSize))")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: danmakuFontBinding, in: 12...32, step: 1)
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("不透明度")
                        Spacer()
                        Text(String(format: "%.0f%%", settings.danmakuOpacity * 100))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: danmakuOpacityBinding, in: 0.2...1.0, step: 0.05)
                }
                Button {
                    router.push(.danmakuShield)
                } label: {
                    Label("弹幕屏蔽规则", systemImage: "eye.slash")
                }
            }

            Section("内容与数据") {
                Button {
                    router.push(.pluginShop)
                } label: {
                    Label("番剧规则管理", systemImage: "puzzlepiece.extension")
                }
                Button {
                    router.push(.webDAV)
                } label: {
                    Label("同步备份", systemImage: "icloud")
                }
                Button {
                    router.push(.logs)
                } label: {
                    Label("运行日志", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    router.push(.about)
                } label: {
                    Label("关于 Kazumi", systemImage: "info.circle")
                }
            }

            Section {
                Text("版本 \(KazumiAppInfo.fullVersion)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
    }

    // MARK: - 双向绑定

    private var themeBinding: Binding<KazumiThemeMode> {
        Binding(get: { settings.themeMode }, set: { settings.themeMode = $0 })
    }

    private var glassBinding: Binding<Bool> {
        Binding(get: { settings.glassEnabled }, set: { settings.glassEnabled = $0 })
    }

    private var themeColorBinding: Binding<KazumiThemeColor> {
        Binding(get: { settings.themeColor }, set: { settings.themeColor = $0 })
    }

    private var oledEnhanceBinding: Binding<Bool> {
        Binding(get: { settings.oledEnhance }, set: { settings.oledEnhance = $0 })
    }

    private var fullscreenBinding: Binding<Bool> {
        Binding(
            get: { settings.playerEntryFullscreen },
            set: { settings.playerEntryFullscreen = $0 }
        )
    }

    private var autoPlayNextBinding: Binding<Bool> {
        Binding(get: { settings.autoPlayNext }, set: { settings.autoPlayNext = $0 })
    }

    private var autoSkipBinding: Binding<Bool> {
        Binding(get: { settings.autoSkipOpEd }, set: { settings.autoSkipOpEd = $0 })
    }

    private var danmakuEnabledBinding: Binding<Bool> {
        Binding(get: { settings.danmakuEnabled }, set: { settings.danmakuEnabled = $0 })
    }

    private var danmakuFontBinding: Binding<Double> {
        Binding(get: { settings.danmakuFontSize }, set: { settings.danmakuFontSize = $0 })
    }

    private var danmakuOpacityBinding: Binding<Double> {
        Binding(get: { settings.danmakuOpacity }, set: { settings.danmakuOpacity = $0 })
    }
}

