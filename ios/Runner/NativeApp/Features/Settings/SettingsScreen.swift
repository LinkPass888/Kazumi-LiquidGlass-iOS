//
//  SettingsScreen.swift
//  Kazumi
//
//  设置首页。分组与主分支完全一致（lib/pages/settings/settings_page.dart 的 _settingsGroups）：
//    * 播放 —— 播放设置 / 弹幕设置
//    * 资源 —— 规则管理 / 下载设置
//    * 应用 —— 通知设置 / 外观设置 / 界面设置 / 账号与备份 / 网络设置
//    * 其他 —— 更新设置 / 存储与日志 / 关于
//
//  「账号与备份」现在是一张主页：账号与 WebDAV 各一行，设置备份直接摊开在主页里。
//  原来的「同步设置」整页已撤掉（账号、WebDAV 各回各的二级页），
//  「设置备份」也不再单独成页，因此这里不再有这两个入口。
//
//  每个分类点进去是一张二级设置页（二级页面见 SettingsDetailScreens.swift），
//  已经存在独立页面的分类（规则管理 / 存储与日志 / 关于）直接推入对应页面。
//

import SwiftUI

/// 设置分类（对应原版 _SettingsCategory）。
struct SettingsCategory: Identifiable, Hashable {
    /// 二级页面的去向。
    enum Destination: Hashable {
        case player
        case danmaku
        case pluginList
        case pluginShop
        case download
        case notification
        case theme
        case interface
        case syncBackup
        case network
        case update
        case logs
        case storage
        case about
    }

    let id: String
    let label: String
    let description: String
    let symbol: String
    let destination: Destination
}

/// 设置分组（对应原版 _SettingsGroup）。
struct SettingsGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let categories: [SettingsCategory]
}

extension SettingsGroup {
    /// 与主分支的分类、顺序、图标一致。
    static let all: [SettingsGroup] = [
        SettingsGroup(
            id: "playback",
            title: "播放",
            categories: [
                SettingsCategory(
                    id: "player",
                    label: "播放设置",
                    description: "解码、渲染与播放行为",
                    symbol: "play.rectangle.on.rectangle",
                    destination: .player
                ),
                SettingsCategory(
                    id: "danmaku",
                    label: "弹幕设置",
                    description: "弹幕来源与显示效果",
                    symbol: "captions.bubble",
                    destination: .danmaku
                ),
            ]
        ),
        SettingsGroup(
            id: "resource",
            title: "资源",
            categories: [
                SettingsCategory(
                    id: "plugin",
                    label: "规则管理",
                    description: "番剧资源规则",
                    symbol: "puzzlepiece.extension",
                    destination: .pluginList
                ),
                SettingsCategory(
                    id: "download",
                    label: "下载设置",
                    description: "并发数与弹幕缓存",
                    symbol: "arrow.down.circle",
                    destination: .download
                ),
            ]
        ),
        SettingsGroup(
            id: "application",
            title: "应用",
            categories: [
                SettingsCategory(
                    id: "notification",
                    label: "通知设置",
                    description: "追番更新提醒",
                    symbol: "bell",
                    destination: .notification
                ),
                SettingsCategory(
                    id: "theme",
                    label: "外观设置",
                    description: "主题与配色",
                    symbol: "paintpalette",
                    destination: .theme
                ),
                SettingsCategory(
                    id: "interface",
                    label: "界面设置",
                    description: "启动、窗口行为与展示信息",
                    symbol: "square.grid.2x2",
                    destination: .interface
                ),
                SettingsCategory(
                    id: "syncBackup",
                    label: "账号与备份",
                    description: "Bangumi 令牌、WebDAV 与设置备份",
                    symbol: "icloud",
                    destination: .syncBackup
                ),
                SettingsCategory(
                    id: "network",
                    label: "网络设置",
                    description: "访问加速与代理",
                    symbol: "globe",
                    destination: .network
                ),
            ]
        ),
        SettingsGroup(
            id: "other",
            title: "其他",
            categories: [
                SettingsCategory(
                    id: "update",
                    label: "更新设置",
                    description: "应用与规则更新",
                    symbol: "arrow.down.app",
                    destination: .update
                ),
                SettingsCategory(
                    id: "storage",
                    label: "存储与日志",
                    description: "图片缓存与错误日志",
                    symbol: "externaldrive",
                    destination: .storage
                ),
                SettingsCategory(
                    id: "about",
                    label: "关于",
                    description: "版本与开源信息",
                    symbol: "info.circle",
                    destination: .about
                ),
            ]
        ),
    ]
}

struct SettingsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppRouter.self) private var router

    var body: some View {
        List {
            ForEach(SettingsGroup.all) { group in
                Section {
                    ForEach(group.categories) { category in
                        categoryRow(category)
                    }
                } header: {
                    Text(group.title)
                }
            }
        }
        // 顶部滚动边缘：列表顶部用渐进模糊（.soft）。
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
    }

    // MARK: - 分类行

    @ViewBuilder
    private func categoryRow(_ category: SettingsCategory) -> some View {
        switch category.destination {
        case .player:
            NavigationLink { PlayerSettingsScreen() } label: { tile(category) }
        case .danmaku:
            NavigationLink { DanmakuSettingsScreen() } label: { tile(category) }
        case .notification:
            NavigationLink { NotificationSettingsScreen() } label: { tile(category) }
        case .theme:
            NavigationLink { ThemeSettingsScreen() } label: { tile(category) }
        case .interface:
            NavigationLink { InterfaceSettingsScreen() } label: { tile(category) }
        case .syncBackup:
            // 主页面这一层走统一路由：以后从「我的」等别处进来也走同一条。
            Button { router.push(.syncBackup) } label: { tile(category) }
                .buttonStyle(.plain)
        case .network:
            NavigationLink { NetworkSettingsScreen() } label: { tile(category) }
        case .update:
            NavigationLink { UpdateSettingsScreen() } label: { tile(category) }
        case .download:
            NavigationLink { DownloadSettingsScreen() } label: { tile(category) }
        // 已经有独立页面的分类，直接推入既有路由。
        case .pluginList:
            Button { router.push(.pluginList) } label: { tile(category) }
                .buttonStyle(.plain)
        case .pluginShop:
            Button { router.push(.pluginShop) } label: { tile(category) }
                .buttonStyle(.plain)
        case .logs:
            Button { router.push(.logs) } label: { tile(category) }
                .buttonStyle(.plain)
        case .storage:
            Button { router.push(.storage) } label: { tile(category) }
                .buttonStyle(.plain)
        case .about:
            Button { router.push(.about) } label: { tile(category) }
                .buttonStyle(.plain)
        }
    }

    private func tile(_ category: SettingsCategory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: category.symbol)
                .font(.system(size: 18, weight: .semibold)) // 图标尺寸：与列表其他分类图标的视觉大小对齐
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.label)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(category.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        // 整行都是点击目标；视觉高度可以随文字走，可点区域不低于 44pt。
        .hitTarget44(alignment: .leading)
    }
}
