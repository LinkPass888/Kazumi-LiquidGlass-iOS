//
//  LibraryScreen.swift
//  Kazumi
//
//  对应 lib/pages/collect/collect_page.dart + collect_library_view.dart：
//  * 顶栏是「追番」+ 右侧「同步」按钮；
//  * 分类标签：全部 / 在看 / 想看 / 看过 / 搁置 / 抛弃，默认停在「在看」；
//  * 主体是收藏卡片列表，点开进详情，右侧菜单可改收藏状态；
//  * 没有收藏时给出引导，而不是空白页。
//

import SwiftUI

struct LibraryScreen: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    /// nil 表示「全部」。
    private static let categories: [CollectType?] = [
        nil, .watching, .wish, .watched, .onHold, .dropped,
    ]

    @State private var selectedType: CollectType? = .watching
    @State private var pendingID: Int?

    private var filteredEntries: [LibraryEntry] {
        let entries = library.entries
        guard let selectedType else {
            return entries.sorted { $0.updatedAt > $1.updatedAt }
        }
        return entries
            .filter { $0.collectType == selectedType }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            categoryBar
            content
        }
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center) {
            Text("追番")
                .font(.system(size: 24, weight: .bold))

            Spacer(minLength: 8)

            Button {
                router.push(.webDAV)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 15, weight: .semibold))
                    Text("同步")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .kazumiGlassCapsule(interactive: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: - 分类

    private var categoryBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(Self.categories.enumerated()), id: \.offset) { _, type in
                    let isSelected = selectedType == type
                    let count = count(for: type)
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { selectedType = type }
                    } label: {
                        HStack(spacing: 5) {
                            Text(type?.title ?? "全部")
                                .font(.subheadline.weight(.semibold))
                            Text("\(count)")
                                .font(.caption.weight(.medium))
                                .opacity(0.7)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? KazumiPalette.accent : KazumiPalette.cardSurface(for: colorScheme))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 12)
    }

    private func count(for type: CollectType?) -> Int {
        guard let type else { return library.entries.count }
        return library.entries.filter { $0.collectType == type }.count
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if filteredEntries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(library.entries.isEmpty ? "还没有追番" : "这个分类还没有番剧")
                    .font(.headline)
                Text("在番剧详情页点「追番」即可加入这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("去推荐看看") {
                    router.selectedDestination = .popular
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filteredEntries) { entry in
                        LibraryEntryCard(
                            entry: entry,
                            isPending: pendingID == entry.id,
                            onOpen: { router.push(.bangumiInfo(bangumiID: entry.id)) },
                            onChangeType: { type in changeType(entry, to: type) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func changeType(_ entry: LibraryEntry, to type: CollectType) {
        guard pendingID == nil else { return }
        pendingID = entry.id
        var updated = entry
        updated.type = type.rawValue
        updated.updatedAt = Date()
        library.upsert(updated)
        pendingID = nil
    }
}

/// 收藏卡片：沿用时间表卡片的外观，右侧菜单可改收藏状态。
private struct LibraryEntryCard: View {
    let entry: LibraryEntry
    let isPending: Bool
    var onOpen: () -> Void
    var onChangeType: (CollectType) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    BangumiRemoteImage(url: entry.imageURL)
                        .frame(width: 88)
                        .aspectRatio(BangumiPosterCard.coverAspectRatio, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.displayName)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if entry.rating > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(String(format: "%.1f", entry.rating))
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundStyle(KazumiPalette.accent)
                        }

                        Text(entry.collectType.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(KazumiPalette.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule(style: .continuous).fill(KazumiPalette.accent.opacity(0.14)))

                        if entry.totalEpisodes > 0 {
                            Text("看到第 \(entry.currentEpisode) / \(entry.totalEpisodes) 话")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(CollectType.enabledCases) { type in
                    Button(type.title) { onChangeType(type) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .opacity(isPending ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("修改收藏状态")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(KazumiPalette.cardSurface(for: colorScheme))
        )
    }
}

