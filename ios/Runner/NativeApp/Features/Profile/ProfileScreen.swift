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
                // 「规则管理」只保留这一处入口：原先这里还有一张异形强调卡直达同一页，
                // 同屏两个入口反而让人怀疑是两个不同的功能。
                // LP 3522：通知设置／播放设置／弹幕设置在「全部设置」里都有，这一页不再重复；
                // 观看历史和离线下载从原来并排的两张工具卡收进这一组。
                contentSection
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
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
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

    /// Colo 3529：两张等宽白卡就是两个空盒子，合成一张统计条——
    /// 卡高跟组里一行一样 52，里面左右两块各占一半，一行里「数字 名字」。
    private var watchStats: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("观看足迹")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            HStack(spacing: 20) {
                stat(value: "\(library.entries.count)", title: "看过番剧")
                stat(value: "\(library.history.count)", title: "观看集数")
            }
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(KazumiPalette.groupedRow(for: colorScheme))
            )
        }
    }

    /// 一块：数字 24 semibold 主题色，隔 6 点接名字 13 次要色，整块左对齐、左留 14。
    private func stat(value: String, title: String) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
        // 两块各自念成一件事：「12，看过番剧」。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(value)，\(title)"))
    }

    // MARK: - 内容与偏好

    /// 规则管理 / 离线下载 / 观看历史三行，最后一行底下挂最近看过的三张海报。
    /// 组名 Camo 3523 定的「内容管理」：原来那个里的「偏好」跟着通知、播放、弹幕一起删了，
    /// 剩下这三行都是在这台设备上攒下的东西。
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("内容管理")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                rowButton(symbol: "puzzlepiece.extension", title: "规则管理") {
                    router.push(.pluginList)
                }
                Divider().padding(.leading, 54)
                rowButton(symbol: "arrow.down.circle", title: "离线下载") {
                    router.push(.download)
                }
                Divider().padding(.leading, 54)
                rowButton(symbol: "clock.arrow.circlepath", title: "观看历史") {
                    router.push(.history)
                }
                // LP 3534／Colo 3536：一个番都没有的时候，「暂无观看历史」留在这一行下面，
                // 但左边缘要跟「观看历史」四个字对齐——左起 54（14 卡片内边距 + 28 图标 + 12 间距），
                // 跟上面那条分隔线同一条竖线。上 8 下 12，13 号次要灰。
                if recentRecords.isEmpty {
                    emptyHistoryNote
                } else {
                    Divider().padding(.leading, 54)
                    recentStrip
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(KazumiPalette.groupedRow(for: colorScheme))
            )
        }
    }

    /// 空态那句，左边缘跟「观看历史」四个字对齐（Colo 3536）。
    private var emptyHistoryNote: some View {
        HStack {
            Text("暂无观看历史")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        // 54 = 卡片左右内边距 14 + 图标 28 + 图标与标题间距 12。
        .padding(.leading, 54)
        .padding(.trailing, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// 最近看过的三张：按时间倒序取前三个，同一部番只出现一次。
    private var recentRecords: [WatchRecord] {
        var seen = Set<Int>()
        var picked: [WatchRecord] = []
        for record in library.history.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard seen.insert(record.bangumiID).inserted else { continue }
            picked.append(record)
            if picked.count == 3 { break }
        }
        return picked
    }

    /// 观看历史那一行底下的三张海报。点一张直接进那部的详情，
    /// 点「观看历史」那一行才是历史页。
    private var recentStrip: some View {
        // Colo 3543：照观看历史里那张封面（84 宽）稍微缩小——72 宽、高 111
        // （72 ÷ 0.65）、圆角 14。三张顶左排、间距 10、右边留白，
        // 不再占满整行（LP 3541 撤掉了 107 宽那版）。
        HStack(spacing: 10) {
            ForEach(recentRecords) { record in
                Button {
                    router.push(.bangumiInfo(bangumiID: record.bangumiID))
                } label: {
                    Color.clear
                        .frame(
                            width: 72,
                            height: 72 / BangumiPosterCard.coverAspectRatio
                        )
                        .overlay {
                            BangumiRemoteImage(url: record.imageURL)
                        }
                        .clipShape(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(record.bangumiName))
                .accessibilityAddTraits(.isButton)
            }
            Spacer(minLength: 0)
        }
        // 卡内左右 14、上 8、下 12。
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func rowButton(
        symbol: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                    .frame(width: 28)
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            // 单行 52：正文那行实测 20.3，上下各 16 补到 52。
            .padding(.vertical, 16)
            .contentShape(Rectangle())
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
                    rowButton(symbol: row.symbol, title: row.title) {
                        router.push(row.route)
                    }
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(KazumiPalette.groupedRow(for: colorScheme))
            )
        }
    }
}
