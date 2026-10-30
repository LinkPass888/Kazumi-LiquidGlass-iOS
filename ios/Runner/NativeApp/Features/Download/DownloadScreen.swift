//
//  DownloadScreen.swift
//  Kazumi
//
//  「下载管理」：按番列出下载记录，每集的状态、进度、文件大小都在这里。
//
//  以前这页是去文件夹里数文件（老实现），下载记录根本没读，所以下完也看不见。
//  现在直接读 DownloadCenter.records——记录是唯一的事实来源，文件由它指向。
//

import SwiftUI

struct DownloadScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppEnvironment.self) private var environment

    private var downloads: DownloadCenter { environment.downloads }

    /// 展开着的番（默认都展开；收起为了长列表好翻）。
    @State private var collapsed: Set<String> = []
    @State private var pendingDelete: DownloadRecord?

    var body: some View {
        Group {
            if downloads.records.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(downloads.records) { record in
                            recordCard(record)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        // 只删记录也要问一句：连同文件一起删，捡不回来。
        .confirmationDialog(
            "删除「\(pendingDelete?.title ?? "")」的全部下载？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let record = pendingDelete { downloads.removeRecord(record) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("这一部已经下好的文件会一起删掉。")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("暂无下载")
                .font(.headline)
            Text("在剧集列表点下载按钮缓存整部番，下好的会出现在这里。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 一部番

    @ViewBuilder
    private func recordCard(_ record: DownloadRecord) -> some View {
        VStack(spacing: 0) {
            header(record)
            if !collapsed.contains(record.id) {
                Divider().padding(.leading, 12)
                ForEach(record.episodes) { episode in
                    episodeRow(record: record, episode: episode)
                    if episode.id != record.episodes.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .background(
            // Colo 3532：分组页里的卡片只留实面，不描边。
            KazumiPalette.cardShape(cornerRadius: 16, scheme: colorScheme, bordered: false)
        )
    }

    private func header(_ record: DownloadRecord) -> some View {
        let done = record.episodes.filter(\.isPlayableOffline).count
        let total = record.episodes.count
        let running = record.episodes.contains { $0.status.isActive }

        return HStack(spacing: 10) {
            Button {
                if collapsed.contains(record.id) { collapsed.remove(record.id) }
                else { collapsed.insert(record.id) }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title.isEmpty ? "未命名番剧" : record.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text(subtitle(done: done, total: total, running: running))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed.contains(record.id) ? -90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button {
                pendingDelete = record
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }

    private func subtitle(done: Int, total: Int, running: Bool) -> String {
        let count = "\(done)/\(total) 集"
        if running {
            return "下载中 · \(count)"
        }
        if done == total, total > 0 {
            return "已下载完 · \(count)"
        }
        return count
    }

    // MARK: - 一集

    @ViewBuilder
    private func episodeRow(record: DownloadRecord, episode: DownloadEpisode) -> some View {
        HStack(spacing: 10) {
            statusIcon(episode)

            VStack(alignment: .leading, spacing: 3) {
                Text(episode.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(statusText(episode))
                    .font(.caption)
                    .foregroundStyle(episode.status == .failed ? Color.red : .secondary)
                    .lineLimit(2)
                if episode.status == .downloading || episode.status == .resolving {
                    ProgressView(value: max(0, min(1, episode.progress)))
                        .tint(KazumiPalette.accent(for: colorScheme))
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 0)

            trailingAction(record: record, episode: episode)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func statusIcon(_ episode: DownloadEpisode) -> some View {
        switch episode.status {
        case .downloading, .resolving:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .paused:
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
        }
    }

    private func statusText(_ episode: DownloadEpisode) -> String {
        switch episode.status {
        case .pending:
            return "排队中"
        case .resolving:
            return "正在解析播放地址"
        case .downloading:
            let percent = Int((episode.progress * 100).rounded())
            let size = ByteCountFormatter.string(fromByteCount: episode.totalBytes, countStyle: .file)
            return episode.totalBytes > 0 ? "下载中 \(percent)% · \(size)" : "下载中 \(percent)%"
        case .paused:
            return "已暂停"
        case .completed:
            return ByteCountFormatter.string(fromByteCount: episode.totalBytes, countStyle: .file)
        case .failed:
            // 失败原因直接说，不再只画个红点。
            return episode.errorMessage ?? "下载失败"
        }
    }

    /// 一集能做的事：失败了重试、跑着暂停、暂停继续、下好删掉。
    @ViewBuilder
    private func trailingAction(record: DownloadRecord, episode: DownloadEpisode) -> some View {
        switch episode.status {
        case .failed:
            Button("重试") {
                downloads.enqueue(
                    bangumiID: record.bangumiID,
                    title: record.title,
                    coverURL: record.coverURL,
                    pluginName: record.pluginName,
                    road: record.road,
                    episodes: [(number: episode.number, title: episode.title, pageURL: episode.pageURL)]
                )
            }
            .font(.footnote.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(KazumiPalette.accent(for: colorScheme))
        case .downloading, .resolving, .pending:
            Button {
                downloads.cancel(recordKey: record.id, numbers: [episode.number])
            } label: {
                Image(systemName: "stop.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        case .paused:
            Button {
                downloads.enqueue(
                    bangumiID: record.bangumiID,
                    title: record.title,
                    coverURL: record.coverURL,
                    pluginName: record.pluginName,
                    road: record.road,
                    episodes: [(number: episode.number, title: episode.title, pageURL: episode.pageURL)]
                )
            } label: {
                Image(systemName: "play.circle")
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))
            }
            .buttonStyle(.plain)
        case .completed:
            Button {
                downloads.removeEpisode(recordKey: record.id, number: episode.number)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }
}
