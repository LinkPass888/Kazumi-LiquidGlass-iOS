//
//  PlayerController.swift
//  Kazumi
//
//  对应 lib/pages/video/video_controller.dart + player_playback_controller.dart 的原生子集：
//   * 选源进入时先按规则抓取章节（规则引擎已有实现），得到分集页面地址；
//   * 分集页面交给隐藏的 VideoSourceWebView 嗅探真实媒体地址；
//   * 最终媒体地址附带规则要求的 UA / Referer，交给 KSPlayer 播放。
//

import Foundation
import Observation

@MainActor
@Observable
final class PlayerController {
    /// 播放阶段，UI 据此展示加载 / 错误 / 就绪。
    enum Phase: Equatable {
        case idle
        /// 从观看历史进入、没有带播放源时，先按记录里的规则名检索条目。
        case searchingSource
        case resolvingChapters
        case parsingMedia
        case ready
        case failed(String)
    }

    /// 弹幕加载状态。
    enum DanmakuStatus: Equatable {
        case idle
        case loading
        case ready
        case unavailable
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var roads: [Road] = []
    private(set) var selectedRoad = 0
    private(set) var episodes: [String] = []
    private(set) var currentEpisode = 1
    private(set) var playbackURL: String?
    private(set) var referer: String?
    private(set) var userAgent: String?
    private(set) var logLines: [String] = []

    /// 当前这一集的弹幕与加载状态（对应 PlayerDanmakuController）。
    private(set) var danmakuComments: [DanmakuComment] = []
    private(set) var danmakuStatus: DanmakuStatus = .idle
    private(set) var danmakuMessage: String?

    let bangumiID: Int
    private(set) var source: PlaybackSource?
    private let plugins: PluginsController
    /// 观看历史存储：仅用于「从历史进入、路由没带播放源」时重建播放源。
    private let library: LibraryStore?
    private let engine = RuleEngine()
    private let webView = VideoSourceWebView()
    private var cancelToken = RuleCancelToken()

    init(
        bangumiID: Int,
        episode: Int,
        source: PlaybackSource?,
        plugins: PluginsController,
        library: LibraryStore? = nil
    ) {
        self.bangumiID = bangumiID
        self.source = source
        self.currentEpisode = max(1, episode)
        self.plugins = plugins
        self.library = library
        webView.onLog = { [weak self] line in
            self?.appendLog(line)
        }
        webView.onVideoURLParser = { [weak self] event in
            self?.handleParsedMedia(event)
        }
    }

    /// 播放该集：先抓章节（只做一次），再解析媒体地址。
    func start() async {
        // 从观看历史进入时路由只带 bangumiID / 集数，没有播放源；
        // 先按历史里的规则名把播放源重建出来，再走正常的起播流程。
        if source == nil {
            await resolveSourceFromHistory()
        }
        guard let source else {
            phase = .failed("没找到这部剧的播放源")
            return
        }
        guard let plugin = plugins.plugin(named: source.pluginName) else {
            phase = .failed("规则「\(source.pluginName)」已不存在，请重新选择")
            return
        }

        if let direct = source.directMediaURL, !direct.isEmpty {
            applyHeaders(plugin: plugin)
            playbackURL = direct
            phase = .ready
            await loadDanmaku()
            return
        }

        if episodes.isEmpty {
            phase = .resolvingChapters
            cancelToken = RuleCancelToken()
            do {
                let trace = try await engine.queryChapters(
                    RuleExecutionConfig(plugin: plugin),
                    source: source.detailURL,
                    cancelToken: cancelToken
                )
                roads = trace.roads
                // 历史里没记是哪条线路，统一从第一条起播（与切源页行为一致）。
                selectedRoad = 0
                episodes = trace.roads.first?.data ?? []
                if episodes.isEmpty {
                    phase = .failed("该播放源没有解析到剧集")
                    return
                }
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
        }

        guard episodes.indices.contains(currentEpisode - 1) else {
            phase = .failed("第 \(currentEpisode) 话不存在")
            return
        }
        let target = episodes[currentEpisode - 1]
        guard !target.isEmpty else {
            phase = .failed("该集没有播放地址")
            return
        }

        applyHeaders(plugin: plugin)
        phase = .parsingMedia
        await webView.load(url: target, useLegacyParser: plugin.useLegacyParser)
    }

    /// 切线路后直接起播：原版只切列表、等用户再点集数，这里按本批要求自动接上。
    func selectRoad(_ index: Int) async {
        guard roads.indices.contains(index) else { return }
        selectedRoad = index
        episodes = roads[index].data
        currentEpisode = min(currentEpisode, max(1, episodes.count))
        phase = .idle
        playbackURL = nil
        resetDanmaku()
        await start()
    }

    func selectEpisode(_ number: Int) async {
        currentEpisode = max(1, number)
        phase = .idle
        playbackURL = nil
        resetDanmaku()
        await start()
    }

    func retry() async {
        phase = .idle
        playbackURL = nil
        resetDanmaku()
        await start()
    }

    func stop() {
        cancelToken.cancel()
        webView.dispose()
    }

    // MARK: - 内部

    /// 从观看历史重建播放源。
    ///
    /// 历史里只存了规则名（`WatchRecord.sourceRuleName`），没有详情页地址，
    /// 因此先用规则搜一次番剧名，拿第一条（优先同名）结果的 `src` 当详情页。
    /// 失败就保持 `source` 为空，由 `start()` 报「没找到这部剧的播放源」。
    private func resolveSourceFromHistory() async {
        guard let library, let record = library.record(for: bangumiID) else { return }
        let keyword = record.bangumiName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        // 记录的规则被删了就退回第一条已装规则，总比直接判死强。
        guard let plugin = plugins.plugin(named: record.sourceRuleName) ?? plugins.pluginList.first else {
            return
        }

        phase = .searchingSource
        appendLog("正在查找播放源：\(plugin.name)")
        do {
            let trace = try await engine.search(
                RuleExecutionConfig(plugin: plugin),
                keyword: keyword,
                cancelToken: cancelToken
            )
            let items = trace.response.data
            // 只认同名条目，且必须唯一：宁可播不了，也不能播错番。
            // 同名多条说明无法判定是哪一部，同样放弃。
            let matches = items.filter { $0.name == record.bangumiName }
            guard matches.count == 1, let item = matches.first else {
                appendLog(
                    matches.isEmpty
                        ? "没有找到与「\(keyword)」同名的条目"
                        : "「\(keyword)」有 \(matches.count) 个同名条目，无法确定播放哪一部"
                )
                return
            }
            source = PlaybackSource(
                pluginName: plugin.name,
                itemName: item.name,
                detailURL: EpisodeURL.normalize(baseUrl: plugin.baseUrl, raw: item.src),
                directMediaURL: MediaUtility.isMediaURL(item.src) ? item.src : nil
            )
        } catch {
            appendLog("查找播放源失败：\(error.localizedDescription)")
        }
    }

    private func applyHeaders(plugin: Plugin) {
        userAgent = plugin.userAgent.isEmpty ? HTTPHeaders.randomUserAgent() : plugin.userAgent
        let refererValue = plugin.referer.isEmpty ? plugin.baseUrl : plugin.referer
        referer = refererValue.isEmpty ? nil : refererValue
    }

    private func handleParsedMedia(_ event: VideoParserEvent) {
        guard !event.url.isEmpty else { return }
        playbackURL = event.url
        phase = .ready
        KazumiLogBuffer.player("解析到媒体地址（\(event.format)）")
        Task { await loadDanmaku() }
    }

    // MARK: - 弹幕

    /// 对应 PlayerDanmakuController.fetchDanmaku：按 Bangumi id + 集数取弹幕。
    func loadDanmaku() async {
        guard danmakuStatus != .loading else { return }
        danmakuStatus = .loading
        danmakuMessage = nil

        let result = await DanmakuAPI.fetch(bangumiID: bangumiID, episode: currentEpisode)
        switch result {
        case .success(let comments):
            danmakuComments = comments
            danmakuStatus = .ready
            KazumiLogBuffer.player("弹幕已加载：\(comments.count) 条")
        case .empty:
            // 这集本来就没弹幕：不当成错误，也不跳提示。
            danmakuComments = []
            danmakuStatus = .ready
            danmakuMessage = nil
        case .unavailable(let message):
            danmakuComments = []
            danmakuStatus = .unavailable
            danmakuMessage = message
        case .failed(let message):
            danmakuComments = []
            danmakuStatus = .failed
            danmakuMessage = message
        }
    }

    private func resetDanmaku() {
        danmakuComments = []
        danmakuStatus = .idle
        danmakuMessage = nil
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }
}
