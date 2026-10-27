//
//  ProfileScreen.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/my/my_space_view.dart 的分组结构：
//  * 顶栏「我的」+ 右侧「全部设置」按钮；
//  * 观看足迹（看过番剧 / 观看集数）；
//  * 历史记录、离线下载（并排两块工具卡）；
//  * 规则管理（原版的异形强调卡）；
//  * 内容与偏好：规则管理 / 通知设置 / 播放设置 / 弹幕设置；
//  * 数据与应用：账号与备份 / 存储管理 / 关于 Kazumi。
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
                // 「规则管理」只保留「内容与偏好」里的那一行：原先这里还有一张
                // 异形强调卡直达同一页，同屏两个入口反而让人怀疑是两个不同的功能。
                section("内容与偏好", rows: [
                    Row(symbol: "puzzlepiece.extension", title: "规则管理", route: .pluginList),
                    Row(symbol: "bell", title: "通知设置", route: .notificationSettings),
                    Row(symbol: "play.rectangle", title: "播放设置", route: .playerSettings),
                    Row(symbol: "captions.bubble", title: "弹幕设置", route: .danmakuSettings),
                ])
                section("数据与应用", rows: [
                    Row(symbol: "icloud", title: "同步设置", route: .syncBackup),
                    Row(symbol: "externaldrive", title: "存储与日志", route: .storage),
                    Row(symbol: "info.circle", title: "关于 Kazumi", route: .about),
                ])
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        // 顶部滚动边缘：渐进模糊（.soft），不额外叠材质或底色。
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        // 顶栏换原生（LP 2026-10-24）：标题和设置按钮都归系统。
        // 原来那块自钉顶栏带不透明底色，会把滚动边缘的模糊整块挡住（Colo 1794 提的坑），
        // 所以这次连底色一起删掉，不再自己画任何一条栏。
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.push(.settings)
                } label: {
                    // LP 2026-10-25：右上角是设置入口，用齿轮符号。
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("全部设置")
            }
        }
    }

    // MARK: - 头部

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
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
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
                title: "观看历史",
                caption: library.history.isEmpty ? "暂无观看历史" : "查看观看历史",
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
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))
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

    // MARK: - 分组列表

    private struct Row: Identifiable {
        let id = UUID()
        var symbol: String
        var title: String
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
                                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                                .frame(width: 28)
                            Text(row.title)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        // Colo 3474：单行了，上下各 11 → 行高 44（系统单行）。
                        // 原来「标题＋小字」两行、上下各 12，一行 64。
                        .padding(.vertical, 11)
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
