//
//  ImageSearchResultViews.swift
//  Kazumi
//
//  对应 lib/pages/search/image_search_widgets.dart 的 _BestMatch / _OtherMatch / _TraceFrame。
//

import SwiftUI

/// 16:9 的匹配画面；加载失败或没有地址时显示占位图标。
struct RemoteFrameImage: View {
    let url: URL
    var height: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(KazumiPalette.cardSurface(for: colorScheme))
            .overlay {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        placeholder
                    case .empty:
                        ProgressView()
                    @unknown default:
                        placeholder
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: "film")
            .font(.system(size: 32, weight: .light))
            .foregroundStyle(.tertiary)
    }
}

/// 对应 _TraceFrame：结果卡片内的 16:9 画面。
struct TraceFrame: View {
    let result: TraceResultItem
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(KazumiPalette.cardSurface(for: colorScheme))
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let url = result.frameURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                        case .failure:
                            placeholder
                        case .empty:
                            ProgressView()
                                .controlSize(.small)
                        @unknown default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityLabel("\(result.displayTitle)的匹配画面")
    }

    private var placeholder: some View {
        Image(systemName: "film")
            .font(.system(size: 30, weight: .light))
            .foregroundStyle(.tertiary)
    }
}

/// 对应 _BestMatch：相似度最高的一条，带两个操作按钮。
struct BestMatchCard: View {
    let result: TraceResultItem
    let onSelect: () -> Void
    let onPreview: (URL) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("相似度最高")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(result.similarityText) 相似")
                        .font(.subheadline.weight(.bold))
                    Spacer(minLength: 0)
                }
                Text(result.displayTitle)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    TraceFrame(result: result)
                        .padding(.leading, 12)
                    details
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 0) {
                    TraceFrame(result: result)
                        .padding(.horizontal, 12)
                    details
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(KazumiPalette.background(for: colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 0.5)
                }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                metadata(icon: "movieclapper", label: result.episodeText)
                metadata(icon: "clock", label: result.timeRangeText)
            }
            .padding(.top, 16)

            if result.isLowSimilarity {
                Text("相似度偏低，建议对照画面，或换一张截图。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }

            HStack(spacing: 10) {
                Button(action: onSelect) {
                    Label("搜索这部番", systemImage: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(KazumiPalette.accent(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if let video = result.previewURL {
                    Button {
                        onPreview(video)
                    } label: {
                        Label("预览片段", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.top, 16)
        }
        .padding(20)
    }

    private func metadata(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            Text(label)
                .font(.footnote)
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }
}

/// 对应 _OtherMatch：其余相似片段，点击即用该番名搜索。
struct OtherMatchRow: View {
    let result: TraceResultItem
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                TraceFrame(result: result)
                    .frame(width: 104)

                VStack(alignment: .leading, spacing: 6) {
                    Text(result.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    Text("\(result.episodeText) · \(result.similarityText) 相似")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(result.timeRangeText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(KazumiPalette.cardSurface(for: colorScheme))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜索 \(result.displayTitle)")
    }
}
