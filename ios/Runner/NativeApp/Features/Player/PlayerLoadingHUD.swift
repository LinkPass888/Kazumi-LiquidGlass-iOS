//
//  PlayerLoadingHUD.swift
//  Kazumi
//
//  播放器里那颗加载符号（LP 4810）。
//
//  圈就用系统的 `ProgressView()`：它自己会转、跟着深浅色走、开了「减弱动态效果」
//  也不会乱动，不用我们再维护一套动画（Ato 4812）。这里只多做一件事——在它下面
//  配一行网速，让「卡住了」和「在下、只是慢」能分得清。
//

import SwiftUI

/// 圈 + 网速。用在三处：解析地址、起播等第一帧、播放中途缓冲 / 拖进度。
struct PlayerLoadingHUD: View {
    /// 当前下载速度（字节/秒）。0 表示拿不到或者没在下载，这一行就不显示。
    var bytesPerSecond: Double = 0

    private var speedText: String? { Self.speedText(bytesPerSecond) }

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.2)
            // 这一行**永远占着位置**，只是拿不到速度时透明（LP 4870：一开始有字时位置对，
            // 字一没圈就往下掉到 1/4 线上）。圈是按整块的圆心摆在 1/4 的，少一行字整块
            // 就矮一截、圆心跟着往下走，看起来就是「跳了一下」。
            // 等宽数字：不然「9.8 MB/s」跳成「10.0 MB/s」时整行会左右抖一下。
            Text(speedText ?? "0 KB/s")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .opacity(speedText == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: speedText)
        }
    }

    /// 「1.2 MB/s」「860 KB/s」。拿不到（0、非数、小到没有意义）时返回 nil，
    /// 界面上不挂一行「0 KB/s」。
    static func speedText(_ bytesPerSecond: Double) -> String? {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1024 else { return nil }
        let megabytes = bytesPerSecond / 1024 / 1024
        if megabytes >= 1 {
            return String(format: "%.1f MB/s", megabytes)
        }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }
}
