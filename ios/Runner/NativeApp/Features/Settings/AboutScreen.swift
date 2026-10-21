//
//  AboutScreen.swift
//  Kazumi
//
//  对应 lib/pages/about/about_page.dart：应用信息、开源声明与相关链接。
//

import SwiftUI

struct AboutScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    private var appIcon: UIImage? {
        UIImage(named: "AppIcon") ?? Bundle.main.iconImage
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Group {
                        if let appIcon {
                            Image(uiImage: appIcon)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Image(systemName: "play.rectangle.fill")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(KazumiPalette.accent)
                        }
                    }
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Text(KazumiAppInfo.displayName)
                        .font(.title2.bold())
                    Text("版本 \(KazumiAppInfo.fullVersion)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("规则 API 级别 \(KazumiAppInfo.ruleAPILevel)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 12)

                VStack(spacing: 8) {
                    linkRow("项目主页", url: KazumiAppInfo.projectURL)
                    linkRow("源码仓库", url: KazumiAppInfo.sourceURL)
                    linkRow("Telegram 群组", url: KazumiAppInfo.telegramURL)
                    linkRow("图标作者", url: KazumiAppInfo.iconAuthorURL)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("数据来源")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    linkRow("Bangumi 番组计划", url: KazumiAppInfo.bangumiIndexURL)
                    linkRow("bangumi-data（CC BY 4.0）", url: KazumiAppInfo.bangumiDataIndexURL)
                    linkRow("bangumi-mal 映射表", url: KazumiAppInfo.bangumiMALIndexURL)
                    linkRow("BangumiExtLinker（CC BY 4.0）", url: KazumiAppInfo.bangumiExtLinkerURL)
                    linkRow("AniSkip 片头片尾数据", url: KazumiAppInfo.aniSkipIndexURL)
                    linkRow("AniList 放送时刻", url: KazumiAppInfo.aniListIndexURL)
                    linkRow("弹弹play", url: KazumiAppInfo.dandanIndexURL)
                }

                Text("本应用与上述数据提供方无隶属关系，番剧信息与评论版权归原作者所有。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func linkRow(_ title: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(KazumiPalette.cardSurface(for: colorScheme))
            )
        }
        .buttonStyle(.plain)
    }
}

private extension Bundle {
    /// 从资产目录取应用图标（AppIcon 不是普通图片资源，退回主图标名）。
    var iconImage: UIImage? {
        guard let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

