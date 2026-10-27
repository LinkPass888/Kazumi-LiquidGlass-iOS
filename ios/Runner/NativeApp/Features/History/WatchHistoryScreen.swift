//
//  WatchHistoryScreen.swift
//  Kazumi
//
//  对应 lib/pages/history/history_page.dart：全部观看记录，按时间倒序，
//  显示播放进度并可继续观看；支持单条删除与全部清空。
//

import SwiftUI

struct WatchHistoryScreen: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @State private var isConfirmingClear = false

    private var records: [WatchRecord] {
        library.history
            // 位置和时长都是 0 的那类不进列表：加载失败留下的空记录（LP 2026-10-25）。
            // 已经写进本机存储的老记录在这里也被挡掉，不必等它自然过期。
            .filter { $0.progressSeconds > 0 || $0.durationSeconds > 0 }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        Group {
            if records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("暂无观看历史")
                        .font(.headline)
                    Button("去推荐看看") {
                        router.selectedDestination = .popular
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(records) { record in
                            card(record)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                // 顶部滚动边缘：渐进模糊（.soft）。
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        // Colo 3532：二级页统一用分组页底。
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("观看历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { isConfirmingClear = true }
                }
            }
        }
        .confirmationDialog("确定清空全部观看历史？", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("清空全部", role: .destructive) {
                for record in records {
                    library.removeHistory(bangumiID: record.bangumiID)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .task {
            KazumiImageLoader.shared.prefetch(library.history.map(\.imageURL))
        }
    }

    private func card(_ record: WatchRecord) -> some View {
        Button {
            router.push(.player(bangumiID: record.bangumiID, episode: record.episodeNumber))
        } label: {
            HStack(spacing: 12) {
                poster(record)

                VStack(alignment: .leading, spacing: 6) {
                    Text(record.bangumiName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(episodeLine(for: record))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    KazumiGlassProgressBar(
                        progress: record.fraction,
                        tint: KazumiPalette.accent(for: colorScheme)
                    )

                    HStack(spacing: 6) {
                        Text(whenText(record.updatedAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(statusText(for: record))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 右边这一列撑满封面高度，进度条与时间落在卡片底部对齐。
                .frame(height: Self.coverWidth / BangumiPosterCard.coverAspectRatio, alignment: .top)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // Colo 3532：灰底页面的卡片只留 groupedRow 实面，不描边。
                KazumiPalette.cardShape(cornerRadius: 20, scheme: colorScheme, bordered: false)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            // 已看完的从头播，就不能再叫「继续观看」——名字要跟代码做的事一致。
            Button(record.isFinished ? "重新观看" : "继续观看") {
                router.push(.player(bangumiID: record.bangumiID, episode: record.episodeNumber))
            }
            Button("删除记录", role: .destructive) {
                library.removeHistory(bangumiID: record.bangumiID)
            }
        }
    }

    /// 封面：宽高都给死，圆形角与海报卡同一套。右下角那颗小三角是「接着看」的意思。
    private func poster(_ record: WatchRecord) -> some View {
        BangumiRemoteImage(url: record.imageURL)
            .frame(width: Self.coverWidth, height: Self.coverWidth / BangumiPosterCard.coverAspectRatio)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: record.isFinished ? "arrow.counterclockwise" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(6)
            }
    }

    private static let coverWidth: CGFloat = 84

    /// 「第 1 话」或「第 1 话 · 标题」：有集标题就用集标题，没有就退回话数。
    private func episodeLine(for record: WatchRecord) -> String {
        let number = "第 \(record.episodeNumber) 话"
        let title = record.episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || title == number ? number : "\(number) · \(title)"
    }

    /// 底部状态：看完的写「已看完」，没看完的写百分比，刚看了一点的说「刚开始」。
    private func statusText(for record: WatchRecord) -> String {
        if record.isFinished { return "已看完" }
        guard record.durationSeconds > 0 else { return "继续观看" }
        let percent = Int((record.fraction * 100).rounded())
        return percent <= 1 ? "刚开始" : "看了 \(percent)%"
    }

    /// 时间用相对说法：今天 / 昨天 / 具体日期，扫一眼就知道新旧。
    private func whenText(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "今天 \(time)" }
        if calendar.isDateInYesterday(date) { return "昨天 \(time)" }
        return date.formatted(.dateTime.month(.defaultDigits).day())
    }
}

