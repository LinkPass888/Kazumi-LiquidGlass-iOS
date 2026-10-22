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
        library.history.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        Group {
            if records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("暂无观看记录")
                        .font(.headline)
                    Button("去推荐看看") {
                        router.selectedDestination = .popular
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(records) { record in
                            card(record)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .navigationTitle("历史记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { isConfirmingClear = true }
                }
            }
        }
        .confirmationDialog("确定清空全部观看记录？", isPresented: $isConfirmingClear, titleVisibility: .visible) {
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
            HStack(alignment: .top, spacing: 12) {
                BangumiRemoteImage(url: record.imageURL)
                    .frame(width: 100)
                    .aspectRatio(BangumiPosterCard.coverAspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(record.bangumiName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(record.episodeTitle.isEmpty
                        ? "第 \(record.episodeNumber) 话"
                        : record.episodeTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    KazumiGlassProgressBar(progress: record.fraction, tint: KazumiPalette.accent)

                    HStack(spacing: 6) {
                        Text(record.updatedAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                        if record.isFinished {
                            Text("已看完")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(KazumiPalette.cardSurface(for: colorScheme))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("继续观看") {
                router.push(.player(bangumiID: record.bangumiID, episode: record.episodeNumber))
            }
            Button("删除记录", role: .destructive) {
                library.removeHistory(bangumiID: record.bangumiID)
            }
        }
    }
}

