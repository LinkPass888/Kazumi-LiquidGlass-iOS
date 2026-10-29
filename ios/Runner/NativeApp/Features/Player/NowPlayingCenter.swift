//
//  NowPlayingCenter.swift
//  Kazumi
//
//  控制中心 / 通知中心 / 锁屏的「正在播放」信息（LP 4433、Colo 4434）。
//
//  实时活动（灵动岛）是另一套，互不冲突：
//   * 这里交给系统的是「我在放什么」——剧名、第几话、封面、进度、播放速率；
//   * 系统拿这些自己画控制中心那张卡，也自己画灵动岛上 Apple Music 那种样子
//     （左封面、右声谱）——所以 LP 4431 想要的那个效果，主要靠这一层。
//
//  几个必须知道的点：
//   * 只在「状态/元数据变了」或「系统自己推算的进度跟真实进度差到 1.5 秒以上」时
//     写一次（LP 4925 Step 1）：原来每 2 秒无条件赋一次值，那是实打实的一次
//     跨进程全量覆盖写；系统自己会按我们给的速率往前推，不用我们一直喂。
//   * 封面图片是异步取的，取不到就先不带封面，取到了立刻补一次更新。
//   * 退出播放器、播完、出错都要 `clear()`，否则上一集留在控制中心卡片上。
//

import MediaPlayer
import QuartzCore
import UIKit

@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    /// 控制中心那几颗按钮按下去要做什么，由播放页面接上。
    /// 没接就是空实现——显示出来点不动比不显示更难看，所以一进来就接好。
    /// 真正的存放处在 commands 盒子里：注册给系统的闭包只读盒子，不碰主线程状态。
    var onPlay: (() -> Void)? {
        get { commands.onPlay }
        set { commands.onPlay = newValue }
    }
    var onPause: (() -> Void)? {
        get { commands.onPause }
        set { commands.onPause = newValue }
    }
    var onNext: (() -> Void)? {
        get { commands.onNext }
        set { commands.onNext = newValue }
    }
    var onPrevious: (() -> Void)? {
        get { commands.onPrevious }
        set { commands.onPrevious = newValue }
    }
    var onSeek: ((Double) -> Void)? {
        get { commands.onSeek }
        set { commands.onSeek = newValue }
    }

    /// 遥控键的转接盒：回调与「是否在播」都在这里，不带主线程隔离。
    /// 系统在哪个队列回调都不会撞断言；真正动作回主线程做。
    private final class CommandBox: @unchecked Sendable {
        var onPlay: (() -> Void)?
        var onPause: (() -> Void)?
        var onNext: (() -> Void)?
        var onPrevious: (() -> Void)?
        var onSeek: ((Double) -> Void)?
        /// toggle 那颗键据此决定叫停还是叫播。
        var isPlaying = false
    }

    private let commands = CommandBox()

    /// 当前这一集的信息，用来判断要不要真的写一次 nowPlayingInfo。
    private struct Info: Equatable {
        var title: String
        var artist: String
        var albumTitle: String
        var artworkURL: String
        var duration: Double
        var episode: Int
    }

    private var info: Info?
    /// 算好的封面按地址存着——避免每次换集都重新解码。
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var commandsConfigured = false
    private var lastRate: Double = 0
    private var lastElapsed: Double = 0
    private var lastState: MPNowPlayingPlaybackState = .stopped

    /// 上一次**真的写进系统**时的样子（LP 4925 Step 1）。
    /// 拿它跟这一次比：状态没变就看系统自己推算到哪儿了，偏得不多就什么都不做。
    private struct SyncSnapshot {
        var title: String
        var artist: String
        var duration: Double
        var elapsedTime: Double
        /// 播放中为实际倍速，暂停 / 缓冲中为 0——系统就是按这个速率往前推的。
        var effectiveRate: Double
        var isPlaying: Bool
        /// 封面地址；封面是异步到的，到了要算一次变化（那时它才有得写）。
        var artworkKey: String
        /// 写入时的单调时钟，用来算系统侧自己走到了哪儿。
        var timestamp: CFTimeInterval
    }

    private var lastSyncSnapshot: SyncSnapshot?

    /// 写了几次 / 跳过了几次轮询。mpv 的 `wakeup` 日志一秒几十条、日志缓冲只留 200 条，
    /// 逐次写会被冲掉，所以每 8 次跳过记一条、停止时再记一条总的——
    /// 在「运行日志 → 播放」里能直接看到「每 2 秒一次全量写」是不是真没了（LP 4925）。
    private var writeCount = 0
    private var skipCount = 0

    private init() {}

    // MARK: - 遥控指令

    /// 接一次就够了。幂等：重复调用不会重复注册。
    func configureRemoteCommands() {
        guard !commandsConfigured else { return }
        commandsConfigured = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        Self.registerCommandHandlers(commands)
    }

    /// 故意 nonisolated：闭包在这个上下文里形成，才不继承主线程隔离。
    /// 系统在自己的队列上回调它们，哪怕闭包体自己再跳回主线程也没用——
    /// 隔离检查就压在闭包入口那一帧（真机报告里就是这么死的）。
    private nonisolated static func registerCommandHandlers(_ box: CommandBox) {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { _ in
            guard box.onPlay != nil else { return .commandFailed }
            Task { @MainActor in box.onPlay?() }
            return .success
        }

        center.pauseCommand.addTarget { _ in
            guard box.onPause != nil else { return .commandFailed }
            Task { @MainActor in box.onPause?() }
            return .success
        }

        center.togglePlayPauseCommand.addTarget { _ in
            guard box.onPlay != nil || box.onPause != nil else { return .commandFailed }
            Task { @MainActor in
                if box.isPlaying { box.onPause?() } else { box.onPlay?() }
            }
            return .success
        }

        // 上一集 / 下一集：控制中心那两颗箭头。
        center.nextTrackCommand.addTarget { _ in
            guard box.onNext != nil else { return .commandFailed }
            Task { @MainActor in box.onNext?() }
            return .success
        }

        center.previousTrackCommand.addTarget { _ in
            guard box.onPrevious != nil else { return .commandFailed }
            Task { @MainActor in box.onPrevious?() }
            return .success
        }

        // 锁屏那条进度条可以拖。
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                  box.onSeek != nil
            else { return .commandFailed }
            let target = event.positionTime
            Task { @MainActor in box.onSeek?(target) }
            return .success
        }
    }

    // MARK: - 更新

    /// 播放入口：剧名、第几话、封面地址、总长。
    /// - Parameters:
    ///   - isPlaying: 当前是否在播；直接决定速率，也决定控制中心那颗按钮画成什么。
    ///   - elapsed: 当前进度（秒）。
    ///   - rate: 实际倍速（播放中）。写进系统的就是它——系统按这个速率自己往前推进度，
    ///     暂停 / 缓冲时给 0。必须给真实值：给 1 的话，2 倍速时系统推得比真实慢一倍，
    ///     偏差每秒涨 1 秒，纠偏写入会从每 2 秒变成每 1.5 秒。
    func update(
        title: String,
        episode: Int,
        episodeTitle: String?,
        artworkURL: String?,
        duration: Double,
        elapsed: Double,
        isPlaying: Bool,
        rate: Double = 1
    ) {
        configureRemoteCommands()

        let artist = episodeTitle.map { "第 \(episode) 集 · \($0)" } ?? "第 \(episode) 集"
        let next = Info(
            title: title,
            artist: artist,
            albumTitle: "",
            artworkURL: artworkURL ?? "",
            duration: max(duration, 0),
            episode: episode
        )

        let isNewItem = info != next
        info = next
        let effectiveRate = isPlaying ? max(rate, 0) : 0
        lastRate = effectiveRate
        lastElapsed = elapsed
        commands.isPlaying = isPlaying

        // 换集（或换剧）才重建整套信息；只是进度变了走轻量的那条——
        // 每两秒把整个字典重建再赋回去没必要，系统也多收一份重复更新。
        if isNewItem {
            publish(next, elapsed: elapsed, isPlaying: isPlaying, rate: effectiveRate, full: true)
            loadArtwork(for: next)
        } else {
            publish(next, elapsed: elapsed, isPlaying: isPlaying, rate: effectiveRate, full: false)
        }
    }

    /// 退出播放器、播完、出错时调用。
    func clear() {
        info = nil
        lastRate = 0
        lastElapsed = 0
        lastState = .stopped
        // 一次都没轮询过就不记（开了播放页立刻退出的情况，没必要留一行 0/0）。
        if writeCount > 0 || skipCount > 0 { logSyncSummary() }
        writeCount = 0
        skipCount = 0
        // 快照一起清掉（LP 4925 Step 1）：不清的话，下一集第一次写入会跟上一集的
        // 快照比，可能被判成「没变化」而跳过——那一次跳过就是真的没写出去。
        lastSyncSnapshot = nil
        // 遥控键的盒子一起放掉（Fuck 4881）：那几个闭包强持有 surface，而这里是
        // 单例——不放掉，上一轮的 surface 一直被攥着（engine 早停了，但对象还在），
        // 退出播放器后系统再送遥控事件还会打到已经停掉的 surface 上。
        commands.onPlay = nil
        commands.onPause = nil
        commands.onNext = nil
        commands.onPrevious = nil
        commands.onSeek = nil
        commands.isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: - 内部

    private func publish(_ info: Info, elapsed: Double, isPlaying: Bool, rate: Double, full: Bool) {
        let now = CACurrentMediaTime()
        let snapshot = SyncSnapshot(
            title: info.title,
            artist: info.artist,
            duration: info.duration,
            elapsedTime: elapsed,
            effectiveRate: rate,
            isPlaying: isPlaying,
            artworkKey: artworkCache[info.artworkURL] != nil ? info.artworkURL : "",
            timestamp: now
        )

        guard let last = lastSyncSnapshot else {
            lastSyncSnapshot = snapshot
            recordWrite()
            write(info, elapsed: elapsed, isPlaying: isPlaying, rate: rate, full: full)
            return
        }

        // 状态 / 元数据变了：立刻写。
        if last.title != snapshot.title
            || last.artist != snapshot.artist
            || last.artworkKey != snapshot.artworkKey
            || last.isPlaying != snapshot.isPlaying
            || last.effectiveRate != snapshot.effectiveRate
            || abs(last.duration - snapshot.duration) > 0.5
        {
            lastSyncSnapshot = snapshot
            recordWrite()
            write(info, elapsed: elapsed, isPlaying: isPlaying, rate: rate, full: full)
            return
        }

        // 都没变：系统自己按上次的速率往前推。推算值跟真实进度差不到 1.5 秒就
        // 不打扰它——差到了才写（拖了进度、+80 跳过、缓冲卡完恢复都算）。
        let expectedElapsed = last.elapsedTime + (now - last.timestamp) * last.effectiveRate
        guard abs(elapsed - expectedElapsed) >= 1.5 else {
            skipCount += 1
            if skipCount.isMultiple(of: 8) { logSyncSummary() }
            return
        }

        lastSyncSnapshot = snapshot
        recordWrite()
        write(info, elapsed: elapsed, isPlaying: isPlaying, rate: rate, full: full)
    }

    private func recordWrite() {
        writeCount += 1
    }

    private func logSyncSummary() {
        KazumiLogBuffer.shared.append(
            "正在播放：已写入 \(writeCount) 次，跳过 \(skipCount) 次轮询",
            category: .player
        )
    }

    /// 真正写一次：重建字典 + 赋值。`publish` 判定要写的时候才走到这里。
    private func write(_ info: Info, elapsed: Double, isPlaying: Bool, rate: Double, full: Bool) {
        var dictionary = full ? [String: Any]() : (MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:])

        dictionary[MPMediaItemPropertyTitle] = info.title
        dictionary[MPMediaItemPropertyArtist] = info.artist
        // 专辑那行不写：卡片上其实只有两行，写了反而跟副标题并成一串（Colo 4444）。
        if !info.albumTitle.isEmpty {
            dictionary[MPMediaItemPropertyAlbumTitle] = info.albumTitle
        } else {
            dictionary.removeValue(forKey: MPMediaItemPropertyAlbumTitle)
        }
        dictionary[MPMediaItemPropertyPlaybackDuration] = info.duration
        dictionary[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        dictionary[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0.0
        if full {
            // 报「音频」不报「视频」（LP 4720）：报成视频，系统就按视频内容处理那颗
            // 「正在播放」指示——点一下是展开、不跳 App；音乐 App 报音频，点一下进 App。
            dictionary[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
            // 集数：系统自带的「第 N 集」字段就是专辑里的音轨号，控制中心会拿出来显示。
            dictionary[MPMediaItemPropertyAlbumTrackNumber] = info.episode
        }

        if let artwork = artworkCache[info.artworkURL] {
            dictionary[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = dictionary
        // 播放状态只在真的变了才写：每两秒重写一次没有意义。
        let state: MPNowPlayingPlaybackState = isPlaying ? .playing : .paused
        if state != lastState {
            MPNowPlayingInfoCenter.default().playbackState = state
            lastState = state
        }
    }

    /// 封面：先查缓存，没有就下载，拿到后再补一次更新。
    private func loadArtwork(for info: Info) {
        let url = info.artworkURL
        guard !url.isEmpty else { return }
        if artworkCache[url] != nil { return }

        Task { [weak self] in
            let loader = KazumiImageLoader.shared
            // 控制中心那张封面的显示尺寸比列表大，按 900 解一次足够。
            _ = await loader.load(url, pixelSize: 900)
            guard let image = loader.cachedImage(for: url, pixelSize: 900) else { return }
            await MainActor.run {
                guard let self else { return }
                // 这颗闭包是系统在**后台队列**上调用的（它拿去编 JPEG）。
                // 在 MainActor 上下文里直接写闭包，闭包会继承主线程隔离，
                // 一被后台调用就撞隔离断言 → SIGTRAP（真机、模拟器都会）。
                // 所以交非隔离的静态方法去造，闭包才不带主线程隔离。
                let artwork = Self.makeArtwork(image: image)
                self.artworkCache[url] = artwork
                // 图回来了，如果还是这一集，就把封面补进去（这一下才整套重建）。
                guard let current = self.info, current.artworkURL == url else { return }
                self.publish(
                    current,
                    elapsed: self.lastElapsed,
                    isPlaying: self.lastRate > 0,
                    rate: self.lastRate,
                    full: true
                )
            }
        }
    }

    /// 包一层：UIImage 没标记可跨线程传递，交给系统闭包持有得由我们担保。
    private final class ArtworkImageBox: @unchecked Sendable {
        let image: UIImage
        init(_ image: UIImage) { self.image = image }
    }

    /// 故意 nonisolated：在这个上下文里形成的闭包不继承主线程隔离，
    /// 系统在哪个队列调它都不会撞断言。
    private nonisolated static func makeArtwork(image: UIImage) -> MPMediaItemArtwork {
        let box = ArtworkImageBox(image)
        return MPMediaItemArtwork(boundsSize: box.image.size) { _ in box.image }
    }
}
