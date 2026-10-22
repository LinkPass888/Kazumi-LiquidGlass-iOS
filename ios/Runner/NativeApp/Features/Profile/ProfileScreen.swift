//
//  ProfileScreen.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/my/my_space_view.dart 的分组结构：
//  * 顶栏「我的」+ 右侧「全部设置」按钮；
//  * 观看足迹（看过番剧 / 观看集数）；
//  * 历史记录、离线下载（并排两块工具卡）；
//  * 规则设置（原版的异形强调卡）；
//  * 内容与偏好：规则设置 / 通知设置 / 播放设置 / 弹幕设置；
//  * 数据与应用：同步备份 / 存储管理 / 关于 Kazumi。
//

import SwiftUI

struct ProfileScreen: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                watchStats
                quickTools
                rulesTile
                section("内容与偏好", rows: [
                    Row(symbol: "puzzlepiece.extension", title: "规则设置", subtitle: "管理番剧来源", route: .pluginList),
                    Row(symbol: "bell", title: "通知设置", subtitle: "追番更新提醒", route: .notificationSettings),
                    Row(symbol: "play.rectangle", title: "播放设置", subtitle: "播放器与画质", route: .playerSettings),
                    Row(symbol: "captions.bubble", title: "弹幕设置", subtitle: "弹幕与屏蔽规则", route: .danmakuSettings),
                ])
                section("数据与应用", rows: [
                    Row(symbol: "icloud", title: "同步备份", subtitle: "跨设备同步数据", route: .webDAV),
                    Row(symbol: "externaldrive", title: "存储管理", subtitle: "缓存与日志", route: .storage),
                    Row(symbol: "info.circle", title: "关于 Kazumi", subtitle: "版本与开源许可", route: .about),
                ])
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center) {
            Text("我的")
                .font(.system(size: 24, weight: .bold))
            Spacer(minLength: 8)
            Button {
                router.push(.settings)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .kazumiGlassCapsule(interactive: true)
            .accessibilityLabel("全部设置")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(KazumiPalette.background(for: colorScheme))
    }

    // MARK: - 观看足迹

    private var watchStats: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("观看足迹")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            HStack(spacing: 12) {
                stat(value: "\(library.entries.count)", title: "看过番剧")
                stat(value: "\(library.history.count)", title: "观看集数")
            }
        }
    }

    private func stat(value: String, title: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(KazumiPalette.accent)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(KazumiPalette.cardSurface(for: colorScheme))
        )
    }

    // MARK: - 历史 / 下载

    private var quickTools: some View {
        HStack(spacing: 12) {
            toolCard(
                symbol: "clock.arrow.circlepath",
                title: "历史记录",
                caption: library.history.isEmpty ? "暂无观看记录" : "查看观看记录",
                route: .history
            )
            toolCard(
                symbol: "arrow.down.circle",
                title: "离线下载",
                caption: "管理离线内容",
                route: .download
            )
        }
    }

    private func toolCard(symbol: String, title: String, caption: String, route: AppRoute) -> some View {
        Button {
            router.push(route)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(KazumiPalette.accent)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(KazumiPalette.cardSurface(for: colorScheme))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 规则设置（原版的异形强调卡）

    private var rulesTile: some View {
        Button {
            router.push(.pluginList)
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("规则设置")
                        .font(.headline.weight(.bold))
                    Text("管理番剧来源")
                        .font(.caption)
                        .opacity(0.85)
                }
                Spacer(minLength: 0)
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 26, weight: .semibold))
            }
            .foregroundStyle(KazumiPalette.onAccent(for: colorScheme))
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: KazumiPalette.cardCornerRadius,
                    bottomLeadingRadius: KazumiPalette.cardCornerRadius,
                    bottomTrailingRadius: KazumiPalette.cardCornerRadius,
                    topTrailingRadius: 64,
                    style: .continuous
                )
                .fill(KazumiPalette.accent)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分组列表

    private struct Row: Identifiable {
        let id = UUID()
        var symbol: String
        var title: String
        var subtitle: String
        var route: AppRoute
    }

    private func section(_ title: String, rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Button {
                        router.push(row.route)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: row.symbol)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(KazumiPalette.accent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(row.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < rows.count - 1 {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(KazumiPalette.cardSurface(for: colorScheme))
            )
        }
    }
}
