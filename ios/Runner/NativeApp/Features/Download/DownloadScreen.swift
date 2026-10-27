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
    @Environment(DownloadDirectoryStore.self) private var downloadDirectory
    @State private var cachedURLs: [URL] = []

    var body: some View {
        Group {
            if cachedURLs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("暂无下载")
                        .font(.headline)
                    Text("本机还没有下载的剧集。")
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
                                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))
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
                                // Colo 3532：灰底页面的卡片只留 groupedRow 实面，不描边。
                                KazumiPalette.cardShape(cornerRadius: 16, scheme: colorScheme, bordered: false)
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .scrollIndicators(.hidden)
                // 顶部滚动边缘：渐进模糊（.soft）。
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        // Colo 3532：二级页统一用分组页底。
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        // 位置可能在设置里改过：每次进这一页都按当前的下载目录重读一遍。
        .task { cachedURLs = Self.loadCachedFiles(in: downloadDirectory.directoryURL) }
        .onChange(of: downloadDirectory.directoryURL) { _, newValue in
            cachedURLs = Self.loadCachedFiles(in: newValue)
        }
    }

    private func fileSize(of url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// 下载目录由 DownloadDirectoryStore 统一维护：默认 Application Support/Kazumi/downloads，
    /// 设置里选过外部文件夹时就是那个文件夹。
    private static func loadCachedFiles(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

