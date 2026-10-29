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
//   * `elapsed + rate` 只在状态变化时写一次，系统自己按速率往前推时间；
//     每 0.25 秒回写一次反而会让进度条一抖一抖。
//   * 封面图片是异步取的，取不到就先不带封面，取到了立刻补一次更新。
//   * 退出播放器、播完、出错都要 `clear()`，否则上一集留在控制中心卡片上。
//

import MediaPlayer
import UIKit

@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    /// 控制中心那三颗按钮按下去要做什么，由播放页面接上。
    /// 没接就是空实现——显示出来点不动比不显示更难看，所以一进来就接好。
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((Double) -> Void)?

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

    private init() {}

    // MARK: - 遥控指令

    /// 接一次就够了。幂等：重复调用不会重复注册。
    func configureRemoteCommands() {
        guard !commandsConfigured else { return }
        commandsConfigured = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.onPlay != nil else { return .commandFailed }
            Task { @MainActor in self.onPlay?() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.onPause != nil else { return .commandFailed }
            Task { @MainActor in self.onPause?() }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if self.lastRate > 0 { self.onPause?() } else { self.onPlay?() }
            }
            return .success
        }

        // 上一集 / 下一集：控制中心那两颗箭头。
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.onNext != nil else { return .commandFailed }
            Task { @MainActor in self.onNext?() }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.onPrevious != nil else { return .commandFailed }
            Task { @MainActor in self.onPrevious?() }
            return .success
        }

        // 锁屏那条进度条可以拖。
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let event = event as? MPChangePlaybackPositionCommandEvent,
                  self.onSeek != nil
            else { return .commandFailed }
            let target = event.positionTime
            Task { @MainActor in self.onSeek?(target) }
            return .success
        }
    }

    // MARK: - 更新

    /// 播放入口：剧名、第几话、封面地址、总长。
    /// - Parameters:
    ///   - isPlaying: 当前是否在播；直接决定速率，也决定控制中心那颗按钮画成什么。
    ///   - elapsed: 当前进度（秒）。
    func update(
        title: String,
        episode: Int,
        episodeTitle: String?,
        artworkURL: String?,
        duration: Double,
        elapsed: Double,
        isPlaying: Bool
    ) {
        configureRemoteCommands()

        let artist = episodeTitle.map { "第 \(episode) 话 · \($0)" } ?? "第 \(episode) 话"
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
        lastRate = isPlaying ? 1 : 0
        lastElapsed = elapsed

        // 换集（或换剧）才重建整套信息；只是进度变了走轻量的那条——
        // 每两秒把整个字典重建再赋回去没必要，系统也多收一份重复更新。
        if isNewItem {
            publish(next, elapsed: elapsed, isPlaying: isPlaying, full: true)
            loadArtwork(for: next)
        } else {
            publish(next, elapsed: elapsed, isPlaying: isPlaying, full: false)
        }
    }

    /// 退出播放器、播完、出错时调用。
    func clear() {
        info = nil
        lastRate = 0
        lastElapsed = 0
        lastState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: - 内部

    private func publish(_ info: Info, elapsed: Double, isPlaying: Bool, full: Bool) {
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
        dictionary[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if full {
            dictionary[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
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
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.artworkCache[url] = artwork
                // 图回来了，如果还是这一集，就把封面补进去（这一下才整套重建）。
                guard let current = self.info, current.artworkURL == url else { return }
                self.publish(current, elapsed: self.lastElapsed, isPlaying: self.lastRate > 0, full: true)
            }
        }
    }
}
