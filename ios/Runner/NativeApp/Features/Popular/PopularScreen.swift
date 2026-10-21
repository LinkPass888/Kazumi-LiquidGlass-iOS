//
//  PopularScreen.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/popular/popular_page.dart：
//  * 顶部是可点击的大标题「热门番组 ▾ / 标签名 ▾」，点开选标签；
//  * 主体是 3 列（宽度 > 600 时 5 列、> 840 时 6 列）的竖版卡片网格；
//  * 滚到底自动继续加载，右下角有回到顶部按钮；
//  * 列表为空视为请求超时，展示可重试的错误态。
//

import SwiftUI

struct PopularScreen: View {
    @State private var controller = PopularController()
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    /// 与 constants.dart 的 defaultAnimeTags 逐条一致。
    private static let tags: [String] = [
        "日常", "原创", "校园", "搞笑", "奇幻", "百合", "恋爱", "悬疑",
        "热血", "后宫", "机战", "轻改", "偶像", "治愈", "异世界",
    ]

    /// 与 StyleString.cardSpace 一致。
    private static let cardSpace: CGFloat = 8

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                        .id("top")

                    if controller.isLoadingMore {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }

                    content
                }
            }
            .scrollIndicators(.hidden)
            // 回顶按钮用 overlay 而不是 background：background 会被滚动内容盖住，
            // 卡片滑过去时按钮就消失在海报下面（overlay 在内容之上）。
            .overlay(alignment: .bottomTrailing) {
                ScrollToTopButton {
                    withAnimation(.easeOut(duration: 0.35)) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
                .padding(.trailing, 18)
                .padding(.bottom, 18)
            }
            .refreshable {
                await reload()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .task {
            if controller.trendList.isEmpty {
                await controller.queryBangumiByTrend()
            }
        }
    }

    // MARK: - 顶部标题

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            Menu {
                Button {
                    selectTag("")
                } label: {
                    Text("热门番组")
                }
                Divider()
                ForEach(Self.tags, id: \.self) { tag in
                    Button {
                        selectTag(tag)
                    } label: {
                        Text(controller.currentTag == tag ? "✓ \(tag)" : tag)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(controller.currentTag.isEmpty ? "热门番组" : controller.currentTag)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            // 原版顶栏右侧：搜索 + 历史记录。
            // 两个按钮都用圆形玻璃，直径与间距取 KazumiGlassMetrics（与原版一致）。
            barButton(symbol: "magnifyingglass", label: "搜索") {
                router.push(.search(keyword: ""))
            }

            barButton(symbol: "clock.arrow.circlepath", label: "历史记录") {
                router.push(.history)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// 顶栏圆形玻璃按钮。尺寸、间距、边距全部取自 KazumiGlassMetrics，
    /// 与详情页的返回 / 更多按钮共用同一套数值。
    private func barButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: KazumiGlassMetrics.barButtonSize, height: KazumiGlassMetrics.barButtonSize)
        }
        .buttonStyle(.plain)
        .kazumiGlassCapsule(interactive: true)
        .padding(.leading, KazumiGlassMetrics.barButtonGap / 2)
        .accessibilityLabel(label)
    }

    // MARK: - 网格

    @ViewBuilder
    private var content: some View {
        if controller.items.isEmpty && controller.isTimeOut {
            mirrorErrorView
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Self.cardSpace - 2) {
                ForEach(controller.items) { item in
                    BangumiPosterCard(item: item, width: posterWidth)
                        .task {
                            await loadMoreIfNeeded(current: item)
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            // 底部多留一截，最后一行才能完全滚到回顶按钮上方。
            .padding(.bottom, 72)
        }
    }

    /// 对应 contentGrid 的 crossCount：3 / 5 / 6 列。
    private var columnCount: Int {
        let width = containerWidth
        if width > KazumiLayout.mediumWidth { return 6 }
        if width > KazumiLayout.compactWidth { return 5 }
        return 3
    }

    /// 海报列宽：与原版 SliverGrid 一样由容器宽度平分而来。
    /// 固定列宽之后每一行的封面底边都在同一条线上，标题长短不会再把行高顶开。
    private var posterWidth: CGFloat {
        KazumiLayout.posterColumnWidth(
            containerWidth: containerWidth,
            columns: columnCount,
            spacing: Self.cardSpace,
            padding: 8
        )
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(posterWidth), spacing: Self.cardSpace, alignment: .top),
            count: columnCount
        )
    }

    private var containerWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 390
    }

    private var mirrorErrorView: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("无法获取番剧列表")
                .font(.headline)
            Text("请检查网络连接，或到「我的 → 设置」确认 Bangumi 加速方式。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await reload() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 120)
    }

    // MARK: - 行为

    private func selectTag(_ tag: String) {
        guard tag != controller.currentTag else { return }
        if tag.isEmpty {
            controller.setCurrentTag("")
            controller.clearBangumiList()
            Task { await controller.queryBangumiByTrend(type: "init") }
        } else {
            controller.setCurrentTag(tag)
            Task { await controller.queryBangumiByTag(type: "init") }
        }
    }

    private func reload() async {
        if controller.currentTag.isEmpty {
            await controller.queryBangumiByTrend(type: "init")
        } else {
            await controller.queryBangumiByTag(type: "init")
        }
    }

    /// 与原版一致：接近列表尾部时继续加载下一批。
    private func loadMoreIfNeeded(current item: BangumiItem) async {
        guard !controller.isLoadingMore else { return }
        let items = controller.items
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              index >= items.count - 8 else { return }
        if controller.currentTag.isEmpty {
            await controller.queryBangumiByTrend()
        } else {
            await controller.queryBangumiByTag()
        }
    }
}

/// 右下角回到顶部按钮（对应原版 floatingActionButton）。
private struct ScrollToTopButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .kazumiGlassCapsule(interactive: true)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .accessibilityLabel("回到顶部")
    }
}

