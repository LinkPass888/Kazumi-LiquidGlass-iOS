//
//  BangumiInfoScreen.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/info/info_page.dart + bangumi_info_card.dart：
//  * 顶部封面 + 右侧标题、原名、评分、放送信息、简介；
//  * 操作区：「想看 / 在看 / 看过」收藏按钮与「选源播放」按钮；
//  * 选源面板：对每条已装规则并发检索，逐条展示结果并可点进播放；
//  * 剧集列表：@v0/episodes 的首 20 条，配合搜索词作为播放兜底入口。
//

import SwiftUI

struct BangumiInfoScreen: View {
    var bangumiID: Int

    @State private var controller: InfoController?
    @State private var isShowingSources = false
    @State private var isShowingEpisodeList = false
    @Environment(AppEnvironment.self) private var environment
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let controller {
                content(controller)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if controller == nil {
                await load()
            }
        }
    }

    // MARK: - 内容

    private func content(_ controller: InfoController) -> some View {
        VStack(spacing: 0) {
            topBar(controller)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    infoCard(controller)
                    actionRow(controller)
                    episodesSection(controller)
                    if !controller.item.alias.isEmpty {
                        aliasSection(controller)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $isShowingSources) {
            let current = controller
            SourceSheet(controller: current) { pluginName, result in
                isShowingSources = false
                router.push(
                    .player(
                        bangumiID: current.item.id,
                        episode: 1,
                        source: PlaybackSource(
                            pluginName: pluginName,
                            itemName: result.name,
                            detailURL: EpisodeURL.normalize(
                                baseUrl: environment.plugins.plugin(named: pluginName)?.baseUrl ?? "",
                                raw: result.src
                            ),
                            directMediaURL: MediaUtility.isMediaURL(result.src) ? result.src : nil
                        )
                    )
                )
            }
        }
    }

    private func topBar(_ controller: InfoController) -> some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            Text(controller.item.displayName)
                .font(.headline)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                router.push(.search(keyword: controller.item.displayName))
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索同名番剧")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 基本信息卡片

    private func infoCard(_ controller: InfoController) -> some View {
        let item = controller.item
        return HStack(alignment: .top, spacing: 16) {
            BangumiRemoteImage(url: item.largeImage)
                .frame(width: 132)
                .aspectRatio(BangumiPosterCard.coverAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(item.displayName)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !item.name.isEmpty, item.name != item.displayName {
                    Text(item.name)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if item.ratingScore > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text(String(format: "%.1f", item.ratingScore))
                            .font(.system(size: 14, weight: .bold))
                        if item.votes > 0 {
                            Text("(\(item.votes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(KazumiPalette.accent)
                }

                if !item.airDate.isEmpty {
                    Text("放送：\(item.airDate)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if item.rank > 0 {
                    Text("Bangumi 排名 #\(item.rank)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 操作区

    private func actionRow(_ controller: InfoController) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                isShowingSources = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("选源播放")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(KazumiPalette.accent)
                )
            }
            .buttonStyle(.plain)

            // 收藏状态：与原版 collect_button 一致，可选 在看 / 想看 / 看过。
            HStack(spacing: 8) {
                ForEach([CollectType.watching, .wish, .watched]) { type in
                    let isSelected = library.entry(for: controller.item.id)?.collectType == type
                    Button {
                        toggleCollect(controller.item, type: type)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: type.symbolName)
                                .font(.system(size: 13, weight: .semibold))
                            Text(type.title)
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(isSelected ? KazumiPalette.accent : KazumiPalette.cardSurface(for: colorScheme))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if !controller.item.summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("简介")
                        .font(.headline)
                    Text(controller.item.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 剧集

    private func episodesSection(_ controller: InfoController) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("剧集")
                    .font(.headline)
                Spacer()
                if !controller.episodes.isEmpty {
                    Text("\(controller.episodes.count) 话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if controller.isLoadingEpisodes {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else if controller.episodes.isEmpty {
                Text(controller.episodesFailed ? "剧集信息获取失败" : "暂无剧集信息")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 64), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(controller.episodes) { episode in
                        Button {
                            router.push(.player(bangumiID: controller.item.id, episode: Int(episode.sort)))
                        } label: {
                            Text("\(Int(episode.sort))")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(KazumiPalette.cardSurface(for: colorScheme))
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(episode.displayName)
                    }
                }
            }

            if !controller.item.alias.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("别名")
                        .font(.headline)
                        .padding(.top, 8)
                    ForEach(controller.item.alias, id: \.self) { alias in
                        Text(alias)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 别名

    private func aliasSection(_ controller: InfoController) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("别名")
                .font(.headline)
            ForEach(controller.item.alias, id: \.self) { alias in
                Text(alias)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 行为

    private func load() async {
        let environment = self.environment
        let base = await BangumiAPI.info(id: bangumiID)
            ?? BangumiItem(id: bangumiID, name: "未知番剧", nameCn: "")
        let created = InfoController(item: base, plugins: environment.plugins)
        controller = created
        await created.loadDetailIfNeeded()
        await created.loadEpisodes()
    }

    private func toggleCollect(_ item: BangumiItem, type: CollectType) {
        if let existing = library.entry(for: item.id), existing.collectType == type {
            library.remove(bangumiID: item.id)
            return
        }
        library.upsert(
            LibraryEntry(
                id: item.id,
                type: type.rawValue,
                name: item.name,
                nameCn: item.nameCn,
                summary: item.summary,
                airDate: item.airDate,
                imageURL: item.largeImage,
                rating: item.ratingScore,
                rank: item.rank,
                tags: item.tags.map(\.name),
                totalEpisodes: controller?.episodes.count ?? 0,
                currentEpisode: 0,
                addedAt: library.entry(for: item.id)?.addedAt ?? Date(),
                updatedAt: Date()
            )
        )
    }
}

