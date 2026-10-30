//
//  NowPlayingSceneRouteBridge.swift
//  Kazumi
//
//  给系统一个「进程里有一条正在播放的 AVFoundation 渲染管线」的凭证（LP 4966）。
//
//  背景：真机上锁屏 / 灵动岛那张卡点不动 —— 单击灵动岛只原地展开，
//  点锁屏封面 / 标题不唤醒 App。会话类别、卡片字段、`mediaType=audio`
//  都已经排除过（LP 4961）。剩下的假设是：系统只给「进程内存在播放态
//  AVFoundation 管线」的 App 绑定场景唤醒路由，而我们出声的管道是
//  mpv 的 AudioUnit，不是 AVFoundation。
//
//  这个文件就是那个假设的最小验证：
//  * 一个采样都不 enqueue，零音频输出；
//  * `isMuted = true`，不跟 mpv 抢声道，也不写 NowPlayingInfo；
//  * 只在真机上点得动卡片才算数 —— 不动就删掉这个文件，别留着当摆设。
//
//  代价说清楚：它是一条没有文档依据的 hack。真机上如果连声音都出问题，
//  第一个删的就是这里。
//

import AVFoundation

@MainActor
final class NowPlayingSceneRouteBridge {
    static let shared = NowPlayingSceneRouteBridge()

    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var isConfigured = false

    private init() {}

    /// 跟着播放状态走：播放中给真实倍速（至少 1.0），暂停 / 退出给 0.0。
    ///
    /// 只在倍速真的变了的时候写一次 —— 播放页每 250ms 都会走到这里，
    /// 每次都写会把缓冲刷满。
    func setPlaying(_ playing: Bool, rate: Float = 1.0) {
        if !isConfigured {
            audioRenderer.isMuted = true
            synchronizer.addRenderer(audioRenderer)
            isConfigured = true
        }
        let targetRate: Float = playing ? max(rate, 1.0) : 0.0
        guard synchronizer.rate != targetRate else { return }
        synchronizer.setRate(targetRate, time: .zero)
        KazumiLogBuffer.player("场景路由凭证：渲染同步器 rate=\(targetRate)")
    }
}
