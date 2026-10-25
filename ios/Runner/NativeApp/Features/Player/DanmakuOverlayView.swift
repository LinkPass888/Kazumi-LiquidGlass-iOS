//
//  DanmakuOverlayView.swift
//  Kazumi
//
//  弹幕渲染层：叠在 KSPlayer 的视频画面之上，自己用 CADisplayLink 按播放时间
//  排布弹幕，不经过 SwiftUI 的每帧刷新。
//
//  行为对齐原版 canvas_danmaku 的默认观感：
//   * 滚动弹幕 8 秒横穿屏幕，固定弹幕停留 4.5 秒；
//   * 同一轨道上一条还没完全进屏时不放下一条（不重叠）；
//   * 字色取自 DanDanPlay 的 RGB，统一加深色描边保证亮画面上可读；
//   * 透明度 / 字号 / 显示区域（屏幕高度占比）来自弹幕设置。
//

import KSPlayer
import QuartzCore
import UIKit

@MainActor
final class DanmakuOverlayView: UIView {
    private final class ItemLabel: UILabel {
        var startTime: Double = 0
        var duration: Double = 8
        var lane: Int = 0
        var mode: Int = 1
    }

    private var comments: [DanmakuComment] = []
    private var signature = 0
    private var labels: [ItemLabel] = []
    private var nextIndex = 0

    private var enabled = true
    private var opacity: CGFloat = 1
    private var fontSize: CGFloat = 20
    private var area: CGFloat = 0.5

    /// 播放内核；时间每帧直接从 KSPlayer 读，比等回调插值更跟手。
    weak var playerView: PlayerView?

    private var lastNow: Double = 0

    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 外部更新

    func apply(
        comments newComments: [DanmakuComment],
        enabled: Bool,
        opacity: Double,
        fontSize: Double,
        area: Double
    ) {
        let newSignature = newComments.count &* 31 &+ Int((newComments.last?.time ?? 0) * 10)
        if newSignature != signature {
            signature = newSignature
            comments = newComments
            clearLabels()
            nextIndex = 0
        }
        self.enabled = enabled
        self.opacity = CGFloat(max(0.1, min(1, opacity)))
        self.fontSize = CGFloat(max(10, min(40, fontSize)))
        self.area = CGFloat(max(0.2, min(1, area)))
        if !enabled {
            clearLabels()
        }
    }

    // MARK: - 时钟

    /// 直接读内核的播放时间：KSPlayer 的进度回调只有每秒几次，靠插值仍然会抖。
    private func clockNow() -> Double {
        guard let player = playerView?.playerLayer?.player else { return lastNow }
        return max(0, player.currentPlaybackTime)
    }

    private func lowerBound(_ time: Double) -> Int {
        var low = 0
        var high = comments.count
        while low < high {
            let mid = (low + high) / 2
            if comments[mid].time < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    // MARK: - 帧循环

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopDisplayLink()
        } else {
            startDisplayLink()
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private var loggedFirstStep = false

    @objc private func step() {
        guard enabled, !comments.isEmpty, bounds.width > 1, bounds.height > 1 else { return }
        if !loggedFirstStep {
            loggedFirstStep = true
            KazumiLogBuffer.player(
                "起播打点：弹幕层第一帧 \(comments.count) 条，画面 \(Int(bounds.width))x\(Int(bounds.height))"
            )
        }
        let now = clockNow()
        if now < lastNow - 1.5 || now > lastNow + 3 {
            clearLabels()
            nextIndex = lowerBound(now)
        }
        lastNow = now
        emit(upTo: now)
        layoutLabels(at: now)
    }

    private func emit(upTo now: Double) {
        while nextIndex < comments.count && comments[nextIndex].time <= now {
            let comment = comments[nextIndex]
            nextIndex += 1
            // 追上进度时不要一次性把几十条旧弹幕糊上去。
            guard now - comment.time < 1.0 else { continue }
            spawn(comment, now: now)
            if labels.count >= 90 { break }
        }
    }

    private func spawn(_ comment: DanmakuComment, now: Double) {
        let label = ItemLabel()
        label.text = comment.text
        label.font = .boldSystemFont(ofSize: fontSize)
        label.textColor = Self.color(comment.colorValue)
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.8
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero
        label.alpha = opacity
        label.mode = (comment.mode == 4 || comment.mode == 5) ? comment.mode : 1
        label.startTime = now
        label.duration = label.mode == 1 ? 8 : 4.5
        label.sizeToFit()
        label.lane = laneIndex(mode: label.mode, width: label.bounds.width, now: now)
        addSubview(label)
        labels.append(label)
        position(label, at: now)
    }

    private func layoutLabels(at now: Double) {
        var alive: [ItemLabel] = []
        alive.reserveCapacity(labels.count)
        for label in labels {
            let elapsed = now - label.startTime
            if elapsed > label.duration + 0.6 || elapsed < -1.5 {
                label.removeFromSuperview()
                continue
            }
            position(label, at: now)
            alive.append(label)
        }
        labels = alive
    }

    private func position(_ label: ItemLabel, at now: Double) {
        let width = label.bounds.width
        let height = label.bounds.height
        let laneHeight = self.laneHeight
        let topInset: CGFloat = 6

        if label.mode == 1 {
            let progress = max(0, min(1, (now - label.startTime) / label.duration))
            let x = bounds.width - CGFloat(progress) * (bounds.width + width)
            label.frame = CGRect(
                x: x,
                y: topInset + CGFloat(label.lane) * laneHeight,
                width: width,
                height: height
            )
        } else {
            let y: CGFloat
            if label.mode == 5 {
                y = topInset + CGFloat(label.lane) * laneHeight
            } else {
                y = bounds.height - CGFloat(label.lane + 1) * laneHeight
            }
            label.frame = CGRect(
                x: (bounds.width - width) / 2,
                y: y,
                width: width,
                height: height
            )
        }
    }

    // MARK: - 轨道

    private var laneHeight: CGFloat { fontSize + 6 }

    private var maxLanes: Int {
        max(1, Int((bounds.height * area - 12) / laneHeight))
    }

    private func laneIndex(mode: Int, width: CGFloat, now: Double) -> Int {
        let limit = maxLanes
        for lane in 0..<limit where isLaneFree(lane: lane, mode: mode, width: width, now: now) {
            return lane
        }
        // 全部占满时随机塞一条，宁可有重叠也不要丢弹幕。
        return Int.random(in: 0..<limit)
    }

    private func isLaneFree(lane: Int, mode: Int, width: CGFloat, now: Double) -> Bool {
        for item in labels where item.lane == lane && item.mode == mode {
            if mode == 1 {
                let progress = (now - item.startTime) / item.duration
                let x = bounds.width - CGFloat(progress) * (bounds.width + item.bounds.width)
                if x + item.bounds.width > bounds.width - 16 {
                    return false
                }
            } else if now - item.startTime < item.duration {
                return false
            }
        }
        return true
    }

    private func clearLabels() {
        for label in labels {
            label.removeFromSuperview()
        }
        labels.removeAll()
    }

    // MARK: - 颜色

    private static func color(_ value: Int) -> UIColor {
        let rgb = max(0, min(0xFFFFFF, value))
        let red = CGFloat((rgb >> 16) & 0xFF) / 255
        let green = CGFloat((rgb >> 8) & 0xFF) / 255
        let blue = CGFloat(rgb & 0xFF) / 255
        return UIColor(red: red, green: green, blue: blue, alpha: 1)
    }
}
