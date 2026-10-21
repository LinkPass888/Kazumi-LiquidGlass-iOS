//
//  DownloadScreen.swift
//  Kazumi
//
//  对应 lib/pages/download/download_page.dart：离线缓存列表。
//  原生版下载由 KSPlayer 资源缓存负责，这里展示已缓存的条目与占用空间。
//

import SwiftUI

struct DownloadScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var cachedURLs: [URL] = []

    var body: some View {
        Group {
            if cachedURLs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("暂无离线缓存")
                        .font(.headline)
                    Text("播放页的「缓存」按钮会把当前剧集存到本地。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(cachedURLs, id: \.self) { url in
                            HStack(spacing: 12) {
                                Image(systemName: "film.stack")
                                    .foregroundStyle(KazumiPalette.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text(fileSize(of: url))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(KazumiPalette.cardSurface(for: colorScheme))
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .navigationTitle("离线下载")
        .navigationBarTitleDisplayMode(.inline)
        .task { cachedURLs = Self.loadCachedFiles() }
    }

    private func fileSize(of url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// 缓存目录由 AppEnvironment 统一维护（Application Support/Kazumi/cache）。
    private static func loadCachedFiles() -> [URL] {
        let directory = AppEnvironment.storageRoot
            .appending(path: "cache", directoryHint: .isDirectory)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

