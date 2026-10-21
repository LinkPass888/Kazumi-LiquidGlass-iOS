//
//  InfoController.swift
//  Kazumi
//
//  对应 lib/pages/info/info_controller.dart 的原生子集：
//  * 详情懒刷新：summary 为空或缺票数分布时重新拉一次 next 域详情；
//  * 剧集列表走 /v0/episodes；
//  * 选源复用 PluginSearchService，对全部已装规则并发检索。
//

import Observation

@MainActor
@Observable
final class InfoController {
    private(set) var item: BangumiItem
    private(set) var episodes: [BangumiEpisode] = []
    private(set) var isLoadingDetail = false
    private(set) var isLoadingEpisodes = false
    private(set) var episodesFailed = false

    /// 选源面板的聚合结果，按规则名索引。
    private(set) var sourceGroups: [SourceGroup] = []
    private(set) var isSearchingSources = false

    let searchService: PluginSearchService
    private let plugins: PluginsController
    private var sourceKeyword = ""

    struct SourceGroup: Identifiable, Sendable {
        var id: String { name }
        var name: String
        var status: PluginSearchStatus
        var results: [SearchItem]
        var keyword: String

        var statusLabel: String {
            switch status {
            case .pending: "检索中…"
            case .success: results.isEmpty ? "无结果" : "\(results.count) 个结果"
            case .noResult: "无结果"
            case .error: "检索失败"
            case .captcha: "需要验证"
            }
        }

        var hasResults: Bool { status == .success && !results.isEmpty }
    }

    init(item: BangumiItem, plugins: PluginsController) {
        self.item = item
        self.plugins = plugins
        self.searchService = PluginSearchService(plugins: plugins)
    }

    /// 与原版一致：标题/简介缺失或票数分布不全时刷新详情。
    var needsDetailRefresh: Bool {
        item.summary.isEmpty || item.votes <= 0 || item.votesCount.count < 10
    }

    func loadDetailIfNeeded() async {
        guard needsDetailRefresh, !isLoadingDetail else { return }
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        if let refreshed = await BangumiAPI.info(id: item.id) {
            item = refreshed
        }
    }

    func loadEpisodes() async {
        guard !isLoadingEpisodes, episodes.isEmpty else { return }
        isLoadingEpisodes = true
        episodesFailed = false
        defer { isLoadingEpisodes = false }
        let result = await BangumiAPI.episodes(subjectID: item.id)
        episodes = result
        episodesFailed = result.isEmpty
    }

    // MARK: - 选源

    /// 对应 SourceSheet 的 init：用中文名优先作为检索词。
    func searchAllSources() async {
        guard !plugins.pluginList.isEmpty else { return }
        let keyword = item.nameCn.isEmpty ? item.name : item.nameCn
        sourceKeyword = keyword
        isSearchingSources = true
        await searchService.queryAllSource(keyword)
        isSearchingSources = false
        refreshSourceGroups()
    }

    func retrySource(_ name: String, keyword: String? = nil) async {
        let resolved = (keyword ?? sourceKeyword).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { return }
        await searchService.querySource(resolved, pluginName: name)
        refreshSourceGroups()
    }

    func cancelSourceSearch() {
        searchService.cancel()
        isSearchingSources = false
    }

    private func refreshSourceGroups() {
        sourceKeyword = item.nameCn.isEmpty ? item.name : item.nameCn
        sourceGroups = plugins.pluginList.map { plugin in
            SourceGroup(
                name: plugin.name,
                status: searchService.status(for: plugin.name) ?? .pending,
                results: searchService.responses(for: plugin.name),
                keyword: sourceKeyword
            )
        }
    }
}

/// 剧集条目（对应 getBangumiEpisodesByID 返回的 EpisodeInfo 子集）。
struct BangumiEpisode: Identifiable, Hashable, Sendable {
    var id: Int
    var sort: Double
    var name: String
    var nameCn: String
    var airdate: String

    /// 与 Dart 版 EpisodeItem.displayName 一致：中文名优先。
    var displayName: String {
        let translated = nameCn.trimmingCharacters(in: .whitespacesAndNewlines)
        if !translated.isEmpty { return translated }
        let original = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return original.isEmpty ? "第 \(Int(sort)) 话" : original
    }

    static func fromJSON(_ json: JSONValue) -> BangumiEpisode {
        BangumiEpisode(
            id: json["id"].intValue ?? 0,
            sort: json["sort"].doubleValue ?? json["ep"].doubleValue ?? 0,
            name: json["name"].stringValue ?? "",
            nameCn: json["name_cn"].stringValue ?? "",
            airdate: json["airdate"].stringValue ?? ""
        )
    }
}
