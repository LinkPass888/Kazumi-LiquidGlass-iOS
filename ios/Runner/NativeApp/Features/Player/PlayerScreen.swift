//
//  PlayerScreen.swift
//  Kazumi
//
//  对应 lib/pages/video/video_page.dart 的原生实现：
//  * 顶部 16:9 播放区（KSPlayer 基础画面 + 弹幕层），浮着返回与标题；
//  * 播放条：播放 / 暂停、进度、弹幕开关、超分辨率、倍速；
//  * 下方是线路与分集切换，解析中显示进度与解析日志，失败时给出原因与重试。
//

import SwiftUI

struct PlayerScreen: View {
    var bangumiID: Int
    var episode: Int
    var source: PlaybackSource?

    @State private var controller: PlayerController?
    @State private var surface = PlayerSurfaceModel()
    @State private var danmakuEnabled = true
    @State private var playbackRate: Float = 1.0
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let controller {
                VStack(spacing: 0) {
                    playerArea(controller)
                    playerControls
                    detailArea(controller)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard controller == nil else { return }
            danmakuEnabled = settings.danmakuEnabled
            playbackRate = Float(settings.playSpeed)
            let created = PlayerController(
                bangumiID: bangumiID,
                episode: episode,
                source: source,
                plugins: environment.plugins
            )
            controller = created
            await created.start()
        }
        .onDisappear {
            surface.stop()
            controller?.stop()
        }
    }

    // MARK: - 播放区

    @ViewBuilder
    private func playerArea(_ controller: PlayerController) -> some View {
        ZStack {
            Color.black

            if let text = controller.playbackURL, let url = URL(string: text) {
                KSPlayerContainer(
                    url: url,
                    referer: controller.referer,
                    userAgent: controller.userAgent,
                    videoFilters: settings.superResolutionMode.videoFilters,
                    danmaku: controller.danmakuComments,
                    danmakuEnabled: danmakuEnabled,
                    danmakuOpacity: settings.danmakuOpacity,
                    danmakuFontSize: settings.danmakuFontSize,
                    danmakuArea: settings.danmakuArea,
                    surface: surface
                )
            } else {
                statusOverlay(controller)
            }

            VStack(spacing: 6) {
                topBar
                if let notice = danmakuNotice(controller) {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.black.opacity(0.45)))
                }
                Spacer()
            }

            if let error = surface.errorMessage {
                errorOverlay(error, controller: controller)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.black.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            Text(source?.itemName ?? "播放")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func errorOverlay(_ message: String, controller: PlayerController) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("重新加载") {
                surface.errorMessage = nil
                Task { await controller.retry() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.55))
    }

    private func danmakuNotice(_ controller: PlayerController) -> String? {
        switch controller.danmakuStatus {
        case .loading:
            return danmakuEnabled ? "正在加载弹幕…" : nil
        case .unavailable, .failed:
            return danmakuEnabled ? controller.danmakuMessage : nil
        case .idle, .ready:
            return nil
        }
    }

    private func statusOverlay(_ controller: PlayerController) -> some View {
        VStack(spacing: 10) {
            switch controller.phase {
            case .idle, .resolvingChapters, .parsingMedia:
                ProgressView()
                    .tint(.white)
                Text(phaseTitle(controller.phase))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                if let last = controller.logLines.last {
                    Text(last)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .padding(.horizontal, 24)
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                HStack(spacing: 10) {
                    Button("重试") {
                        Task { await controller.retry() }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("返回选源") { dismiss() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            case .ready:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func phaseTitle(_ phase: PlayerController.Phase) -> String {
        switch phase {
        case .idle: "准备中…"
        case .resolvingChapters: "正在抓取剧集列表…"
        case .parsingMedia: "正在解析播放地址…"
        case .ready: ""
        case .failed: ""
        }
    }

    // MARK: - 播放条

    private var playerControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(timeText(surface.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                Slider(
                    value: scrubBinding,
                    in: 0...max(1, surface.duration),
                    onEditingChanged: onScrub
                )
                .tint(KazumiPalette.accent(for: colorScheme))
                Text(timeText(surface.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }

            HStack(spacing: 8) {
                controlButton(symbol: surface.isPlaying ? "pause.fill" : "play.fill") {
                    surface.togglePlay()
                }
                controlButton(symbol: danmakuEnabled ? "text.bubble.fill" : "text.bubble") {
                    danmakuEnabled.toggle()
                }
                superResolutionMenu
                speedMenu
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black)
    }

    private func controlButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 32)
                .background(Capsule().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func controlLabel(_ symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(.white.opacity(0.12)))
    }

    private var superResolutionMenu: some View {
        Menu {
            ForEach(SuperResolutionMode.allCases) { mode in
                Button {
                    settings.superResolutionMode = mode
                } label: {
                    if settings.superResolutionMode == mode {
                        Label("\(mode.title) · \(mode.detail)", systemImage: "checkmark")
                    } else {
                        Text("\(mode.title) · \(mode.detail)")
                    }
                }
            }
        } label: {
            controlLabel("sparkles", text: settings.superResolutionMode.title)
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                Button {
                    playbackRate = Float(rate)
                    surface.setPlaybackRate(Float(rate))
                } label: {
                    if abs(playbackRate - Float(rate)) < 0.01 {
                        Label(speedText(rate), systemImage: "checkmark")
                    } else {
                        Text(speedText(rate))
                    }
                }
            }
        } label: {
            controlLabel("speedometer", text: speedText(Double(playbackRate)))
        }
    }

    private func speedText(_ value: Double) -> String {
        String(format: "%.2gx", value)
    }

    private var scrubBinding: Binding<Double> {
        Binding(
            get: { isScrubbing ? scrubValue : surface.currentTime },
            set: { scrubValue = $0 }
        )
    }

    private func onScrub(_ editing: Bool) {
        if editing {
            scrubValue = surface.currentTime
            isScrubbing = true
        } else {
            isScrubbing = false
            surface.seek(to: scrubValue)
        }
    }

    private func timeText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "00:00" }
        let total = Int(value)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - 线路与选集

    private func detailArea(_ controller: PlayerController) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if controller.roads.count > 1 {
                    roadPicker(controller)
                }
                if !controller.episodes.isEmpty {
                    episodeGrid(controller)
                }
                if controller.source == nil {
                    Text("当前没有选择播放源。请返回详情页点「选源播放」后重试。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(KazumiPalette.background(for: colorScheme))
    }

    private func roadPicker(_ controller: PlayerController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("线路")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(controller.roads.enumerated()), id: \.offset) { index, road in
                        let selected = controller.selectedRoad == index
                        Button {
                            controller.selectRoad(index)
                        } label: {
                            Text(road.name.isEmpty ? "线路 \(index + 1)" : road.name)
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(
                                            selected
                                                ? KazumiPalette.accent(for: colorScheme)
                                                : KazumiPalette.cardSurface(for: colorScheme)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func episodeGrid(_ controller: PlayerController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选集")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 56), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(Array(controller.episodes.enumerated()), id: \.offset) { index, _ in
                    let number = index + 1
                    let selected = controller.currentEpisode == number
                    Button {
                        Task { await controller.selectEpisode(number) }
                    } label: {
                        Text("\(number)")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(
                                        selected
                                            ? KazumiPalette.accent(for: colorScheme)
                                            : KazumiPalette.cardSurface(for: colorScheme)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
