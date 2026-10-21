//
//  PlayerScreen.swift
//  Kazumi
//
//  对应 lib/pages/video/video_page.dart 的原生子集：
//  * 顶部播放区（KSPlayer），下方是线路与分集切换；
//  * 解析中显示进度与解析日志，失败时显示原因与重试；
//  * 没有选源信息时提示回详情页选源。
//

import SwiftUI

struct PlayerScreen: View {
    var bangumiID: Int
    var episode: Int
    var source: PlaybackSource?

    @State private var controller: PlayerController?
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let controller {
                VStack(spacing: 0) {
                    playerArea(controller)
                    controlArea(controller)
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
            controller?.stop()
        }
    }

    // MARK: - 播放区

    @ViewBuilder
    private func playerArea(_ controller: PlayerController) -> some View {
        ZStack {
            Color.black

            if let url = controller.playbackURL, let target = URL(string: url) {
                KSPlayerContainer(
                    url: target,
                    resourceName: episodeTitle(controller),
                    referer: controller.referer,
                    userAgent: controller.userAgent
                )
            } else {
                statusOverlay(controller)
            }

            // 顶部返回条，浮在播放器之上。
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
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
                Spacer()
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    private func statusOverlay(_ controller: PlayerController) -> some View {
        VStack(spacing: 12) {
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
                    .font(.system(size: 30, weight: .semibold))
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

    // MARK: - 控制区

    private func controlArea(_ controller: PlayerController) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if controller.roads.count > 1 {
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
                                                    .fill(selected ? KazumiPalette.accent : KazumiPalette.cardSurface(for: colorScheme))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
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
                                    .fill(selected ? KazumiPalette.accent : KazumiPalette.cardSurface(for: colorScheme))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func episodeTitle(_ controller: PlayerController) -> String {
        let base = source?.itemName ?? "Kazumi"
        return "\(base) 第 \(controller.currentEpisode) 话"
    }
}

