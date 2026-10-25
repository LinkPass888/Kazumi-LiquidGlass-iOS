//
//  BangumiProgress.swift
//  Kazumi
//
//  「自动标记看过」的消费端：一集看到 90% 就在 Bangumi 上把它标成看过。
//  对应 lib/services/bangumi_progress/bangumi_progress_service.dart。
//
//  为什么要有这一层：设置里那个开关没有别的读者，播放器不该自己拼接口，
//  也不该自己记住「这集标过了」——进度回调每秒都会来，不记住就会刷出一串重复请求。
//
//  与「自动同步追番」的关系：那是搬收藏状态，这是搬单集进度，两者互不依赖，
//  各自的开关管各自的活。
//

import Foundation
import Observation

@MainActor
@Observable
final class BangumiProgressService {
    private let settings: SettingsStore

    /// 这次运行里已经处理过的「番剧:集数」。只记内存：重开 App 再标一次也不会错，
    /// 服务端同状态重复写是幂等的。
    private var handled = Set<String>()
    /// 番剧 → (集数 → Bangumi 单集 id)。同一次播放里会反复问进度，缓存一次省一批请求。
    private var episodeIndex: [Int: [Int: Int]] = [:]
    /// 串行化：上一集还在标，下一集不要抢在同一条队列前面。
    private var chain: Task<Void, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// 开关是否生效：既要拨开，也要有令牌 —— 对应原版 enabled()。
    private var enabled: Bool {
        settings.bangumiAutoMarkWatched
            && !settings.bangumiAccessToken
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
    }

    /// 播放器每次进度回调都调用它；不到 90% 或没开开关时立刻返回。
    ///
    /// 两条下限照原版：时长不到 2 分钟的不算（预览、短片），位置不到 90% 的不算。
    func onPosition(
        subjectID: Int,
        episodeNumber: Int,
        position: Double,
        duration: Double
    ) {
        guard subjectID > 0, episodeNumber > 0 else { return }
        guard duration.isFinite, duration >= 120 else { return }
        guard position.isFinite, position >= duration * 0.9 else { return }
        guard enabled else { return }
        let key = "\(subjectID):\(episodeNumber)"
        guard handled.insert(key).inserted else { return }
        let previous = chain
        chain = Task { [weak self] in
            _ = await previous?.value
            await self?.mark(subjectID: subjectID, episodeNumber: episodeNumber)
        }
    }

    private func mark(subjectID: Int, episodeNumber: Int) async {
        guard let episodeID = await resolveEpisodeID(subjectID: subjectID, episodeNumber: episodeNumber) else {
            return
        }
        switch await BangumiAPI.markEpisodeWatched(episodeID: episodeID) {
        case .ok:
            KazumiLog.network.notice(
                "Bangumi: 已标记看过 \(subjectID, privacy: .public) 第 \(episodeNumber, privacy: .public) 集"
            )
        case .notCollected:
            // 400 = 番剧还没收藏。先收成「在看」再试一次，这正是原版的规矩。
            let collected = await BangumiAPI.updateCollection(subjectID: subjectID, type: .watching)
            guard collected else { return }
            if case .ok = await BangumiAPI.markEpisodeWatched(episodeID: episodeID) {
                KazumiLog.network.notice("Bangumi: 收藏后已标记看过 \(subjectID, privacy: .public)")
            }
        case .unauthorized:
            // 令牌没了或过期：这次就算了，不要拿一个失效凭据反复重试。
            KazumiLog.network.error("Bangumi: 自动标记看过失败，令牌无效")
        case .rejected, .failed:
            KazumiLog.network.error(
                "Bangumi: 自动标记看过失败 \(subjectID, privacy: .public) 第 \(episodeNumber, privacy: .public) 集"
            )
        }
    }

    /// 集数 → Bangumi 单集 id。列表里的 `sort` 就是集号，比 offset 猜测可靠。
    private func resolveEpisodeID(subjectID: Int, episodeNumber: Int) async -> Int? {
        if let cached = episodeIndex[subjectID]?[episodeNumber] { return cached }
        let list = await BangumiAPI.episodes(subjectID: subjectID)
        guard !list.isEmpty else { return nil }
        var index: [Int: Int] = [:]
        for (position, episode) in list.enumerated() {
            let number = episode.sort > 0 ? Int(episode.sort) : position + 1
            index[number] = episode.id
        }
        episodeIndex[subjectID] = index
        return index[episodeNumber]
    }
}
