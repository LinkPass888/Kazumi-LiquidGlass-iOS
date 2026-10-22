//
//  BangumiInfoScreen.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/info/info_page.dart + bangumi_info_card.dart：
//  * 顶栏：返回键 + 左对齐的大标题（字重字号与推荐页「热门番组」一致）+ 右上角「更多」；
//  * 封面与条目信息直接压在模糊的封面背景上，不再是背景下面另起一块；
//  * 条目信息：放送开始 / 放送时间（星期菜单 + 具体时刻 + 时间表开关）/ 更新进度 / 评分 / 排名，
//    最下面一行是收窄的追番状态菜单；
//  * 横向排列的「概览 / 吐槽 / 角色 / 关联 / 制作人员」标签；
//  * 别名不是详情页的区块，它在片源弹窗里当检索词用（见 SourceSheet）。
//

import Photos
import SwiftUI
import UIKit

struct BangumiInfoScreen: View {
    var bangumiID: Int

    @State private var controller: InfoController?
    @State private var isShowingSources = false
    @State private var selectedTab: InfoTab = .overview
    @State private var scrollOffset: CGFloat = 0
    @State private var toastMessage: String?
    /// 点亮「在时间表展示」但番剧还没标成在看时，先弹确认。
    @State private var pendingTimelineItem: BangumiItem?

    @Environment(AppEnvironment.self) private var environment
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let controller {
                content(controller)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        // 自绘顶栏会连带关掉系统返回手势，这里把它接回来。
        .background {
            KazumiSwipeBackEnabler()
                .frame(width: 0, height: 0)
        }
        .task {
            if controller == nil {
                await load()
            }
        }
    }

    // MARK: - 内容

    private func content(_ controller: InfoController) -> some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                topBar(controller)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        hero(controller)
                        tabStrip(controller)
                        tabContent(controller)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 96)
                }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, geometry.contentOffset.y)
                } action: { _, newValue in
                    scrollOffset = newValue
                }
            }

            startPlayingButton
        }
        .overlay(alignment: .top) { toastView }
        .sheet(isPresented: $isShowingSources) {
            let current = controller
            SourceSheet(controller: current) { pluginName, result in
                isShowingSources = false
                router.push(
                    .player(
                        bangumiID: current.item.id,
                        episode: 1,
                        source: PlaybackSource(
                            pluginName: pluginName,
                            itemName: result.name,
                            detailURL: EpisodeURL.normalize(
                                baseUrl: environment.plugins.plugin(named: pluginName)?.baseUrl ?? "",
                                raw: result.src
                            ),
                            directMediaURL: MediaUtility.isMediaURL(result.src) ? result.src : nil
                        )
                    )
                )
            }
        }
        .confirmationDialog(
            "在时间表展示",
            isPresented: Binding(
                get: { pendingTimelineItem != nil },
                set: { if !$0 { pendingTimelineItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("标记为在看并开启") {
                guard let item = pendingTimelineItem else { return }
                pendingTimelineItem = nil
                markWatchingAndEnableTimeline(item)
            }
            Button("取消", role: .cancel) { pendingTimelineItem = nil }
        } message: {
            Text("该功能需要番剧处于「在看」状态，是否标记为在看并开启？")
        }
    }

    // MARK: - 顶栏

    /// 返回键 + 左对齐标题 + 更多菜单。
    ///
    /// 这里不再给顶栏加 `.ultraThinMaterial` 背景条：滚动时那一条灰底会横在
    /// 内容上方，与页面背景断开。标题始终显示（原来靠折叠淡入的那份已经删掉）。
    private func topBar(_ controller: InfoController) -> some View {
        HStack(spacing: 10) {
            barButton(symbol: "chevron.left", label: "返回") {
                dismiss()
            }

            Text(controller.item.displayName)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    copyTitle(controller)
                } label: {
                    Label("复制标题", systemImage: "doc.on.doc")
                }
                Button {
                    saveCover(controller)
                } label: {
                    Label("保存封面", systemImage: "square.and.arrow.down")
                }
                Button {
                    openExternally(controller)
                } label: {
                    Label("外部打开", systemImage: "safari")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(
                        width: KazumiGlassMetrics.barButtonSize,
                        height: KazumiGlassMetrics.barButtonSize
                    )
            }
            .buttonStyle(.plain)
            .kazumiGlassCapsule(interactive: true)
            .accessibilityLabel("更多")
        }
        .padding(.leading, KazumiGlassMetrics.barEdgeInset)
        .padding(.trailing, KazumiGlassMetrics.barEdgeInset)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// 顶栏圆形玻璃按钮，尺寸与间距取自 KazumiGlassMetrics。
    private func barButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(
                    width: KazumiGlassMetrics.barButtonSize,
                    height: KazumiGlassMetrics.barButtonSize
                )
        }
        .buttonStyle(.plain)
        .kazumiGlassCapsule(interactive: true)
        .accessibilityLabel(label)
    }
}

// MARK: - 封面 + 条目信息

extension BangumiInfoScreen {
    /// 封面与条目信息一起压在模糊封面上（原版 _InfoHeaderBackground 的做法）。
    private func hero(_ controller: InfoController) -> some View {
        HStack(alignment: .top, spacing: 14) {
            cover(controller.item)
            infoColumn(controller)
        }
        .padding(12)
        .background { backdrop(controller) }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// 背景：同一张封面放大打模糊，再叠一层页面底色把它压成「磨砂」，
    /// 保证浅色 / 深色下上面的文字都读得清。
    private func backdrop(_ controller: InfoController) -> some View {
        BangumiRemoteImage(url: controller.item.largeImage)
            .blur(radius: 26)
            .overlay {
                KazumiPalette.background(for: colorScheme)
                    .opacity(colorScheme == .dark ? 0.62 : 0.74)
            }
    }

    private func cover(_ item: BangumiItem) -> some View {
        BangumiRemoteImage(url: item.largeImage)
            .frame(width: coverWidth, height: coverWidth / BangumiPosterCard.coverAspectRatio)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 封面宽度：整块 hero 的宽度分给封面约三分之一，右侧留给条目信息。
    private var coverWidth: CGFloat {
        let screenWidth = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 390
        let rowWidth = min(screenWidth - 32, 950) - 24
        return max(84, min(150, (rowWidth - 14) * 0.34))
    }

    /// 条目信息列：标签一行、值一行，最后一行是收窄的追番菜单。
    private func infoColumn(_ controller: InfoController) -> some View {
        let item = controller.item
        return VStack(alignment: .leading, spacing: 8) {
            infoLine(label: "放送开始:", value: item.airDate.isEmpty ? "未知" : item.airDate)

            broadcastRow(controller)

            // 更新进度：紧跟在「放送时间」之后。
            if let progress = updateProgress(controller) {
                infoLine(label: "更新进度:", value: progress)
            }

            if item.ratingScore > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("评分:")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(KazumiPalette.accent)
                        Text(String(format: "%.1f", item.ratingScore))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(KazumiPalette.accent)
                        if item.votes > 0 {
                            Text("(\(item.votes) 人)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            if item.rank > 0 {
                infoLine(label: "Bangumi Ranked:", value: "#\(item.rank)")
            }

            collectMenu(controller)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「放送时间」：星期菜单 + 具体时刻 + 时间表开关。
    private func broadcastRow(_ controller: InfoController) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("放送时间:")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                weekdayMenu(controller)

                // 具体时刻来自 bangumi-mal 的季度表，取不到就不显示。
                if let time = controller.airTime {
                    Text(time)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(KazumiPalette.accent)
                }

                Button {
                    toggleTimeline(controller)
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(
                            isInTimeline(controller) ? KazumiPalette.accent : Color.secondary
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("在时间表展示")
            }
        }
    }

    /// 放送星期菜单：七项，收窄成一颗小胶囊（与推荐页的标签菜单同一处理）。
    private func weekdayMenu(_ controller: InfoController) -> some View {
        let current = currentWeekday(controller)
        return Menu {
            ForEach(1...7, id: \.self) { weekday in
                Button {
                    BangumiTimelineStore.shared.setWeekday(weekday, for: controller.item.id)
                } label: {
                    Text(weekday == current ? "✓ \(weekdayTitle(weekday))" : weekdayTitle(weekday))
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(weekdayTitle(current))
                    .font(.system(size: 18, weight: .bold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(KazumiPalette.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择放送星期")
    }
}


// MARK: - 追番菜单 / 信息行

extension BangumiInfoScreen {
    /// 追番状态菜单：收窄放在条目信息最下方。
    private func collectMenu(_ controller: InfoController) -> some View {
        let current = currentType(controller)
        return Menu {
            ForEach(CollectType.enabledCases) { type in
                Button {
                    collect(controller, type)
                } label: {
                    Label(type.buttonTitle, systemImage: type.symbolName)
                }
            }
            if current != .none {
                Divider()
                Button(role: .destructive) {
                    collect(controller, .none)
                } label: {
                    Label("取消追番", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: current.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                Text(current.buttonTitle)
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(current == .none ? Color.primary : KazumiPalette.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("追番状态：\(current.buttonTitle)")
    }

    /// 「标签: 值」一行。值用强调色加粗，与原版一致。
    private func infoLine(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(KazumiPalette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// 「已更新/总集数」，对应原版 bangumi_info_card.dart 的 _updateProgress。
    /// 播期已过的算已更新；总集数取列表里的最大集号（列表可能缺集）。
    private func updateProgress(_ controller: InfoController) -> String? {
        let episodes = controller.episodes
        guard !episodes.isEmpty else { return nil }
        let today = AnimeSeason.format(Date())
        let aired = episodes.filter { episode in
            let airdate = episode.airdate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !airdate.isEmpty else { return false }
            return airdate <= today
        }.count
        guard aired > 0 else { return nil }
        let total = episodes.map { Int($0.sort) }.max() ?? episodes.count
        return String(format: "%02d/%02d", aired, total)
    }
}


// MARK: - 标签条

extension BangumiInfoScreen {
    /// 横向排列的标签行：概览 / 吐槽 / 角色 / 关联 / 制作人员。
    private func tabStrip(_ controller: InfoController) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(InfoTab.allCases) { tab in
                    let isSelected = selectedTab == tab
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { selectedTab = tab }
                        Task { await loadTab(tab, controller: controller) }
                    } label: {
                        Text(tab.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .foregroundStyle(
                                isSelected ? KazumiPalette.onAccent(for: colorScheme) : Color.primary
                            )
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        isSelected
                                            ? KazumiPalette.accent
                                            : KazumiPalette.cardSurface(for: colorScheme)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }

    /// 标签对应的内容面板。
    @ViewBuilder
    private func tabContent(_ controller: InfoController) -> some View {
        switch selectedTab {
        case .overview:
            InfoOverviewPanel(item: controller.item)
        case .comments:
            InfoCommentsPanel(
                comments: controller.comments,
                total: controller.commentsTotal,
                isLoading: controller.isLoadingComments,
                isPosting: controller.isPostingComment
            ) { text in
                await controller.postComment(text, type: currentType(controller))
            }
        case .characters:
            InfoCharactersPanel(
                characters: controller.characters,
                isLoading: controller.isLoadingCharacters
            )
        case .relations:
            InfoRelationsPanel(
                relations: controller.relations,
                isLoading: controller.isLoadingRelations
            )
        case .staff:
            InfoStaffPanel(
                staff: controller.staff,
                isLoading: controller.isLoadingStaff
            )
        }
    }
}

// MARK: - 开始播放

extension BangumiInfoScreen {
    /// 右下角的「开始播放」按钮（原版是 FloatingActionButton.extended）。
    ///
    /// 按压反馈用自定义 ButtonStyle：`.plain` 会在按住时把整个按钮变半透明，
    /// 深色下看起来像消失了；这里改成轻微缩放 + 压暗。
    private var startPlayingButton: some View {
        Button {
            isShowingSources = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text("开始播放")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(KazumiPalette.onAccent(for: colorScheme))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule(style: .continuous).fill(KazumiPalette.accent))
        }
        .buttonStyle(KazumiPressButtonStyle())
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(.trailing, 18)
        .padding(.bottom, 22)
        .accessibilityLabel("开始播放")
    }
}

/// 按压时轻微缩放 + 压暗，而不是把按钮变透明。
struct KazumiPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}


// MARK: - 提示

extension BangumiInfoScreen {
    @ViewBuilder
    private var toastView: some View {
        if let toastMessage {
            Text(toastMessage)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.toastMessage = nil
                    }
                }
        }
    }
}

// MARK: - 加载

extension BangumiInfoScreen {
    private func load() async {
        let environment = self.environment
        let base = await BangumiAPI.info(id: bangumiID)
            ?? BangumiItem(id: bangumiID, name: "未知番剧", nameCn: "")
        let created = InfoController(item: base, plugins: environment.plugins)
        controller = created
        await created.loadDetailIfNeeded()
        await created.loadEpisodes()
        // 播出时刻要单独拉季度表，失败只是不显示时刻。
        await created.loadAirTime()
    }

    /// 标签点开时才去拉对应数据。
    private func loadTab(_ tab: InfoTab, controller: InfoController) async {
        switch tab {
        case .overview:
            break
        case .comments:
            await controller.loadComments()
        case .characters:
            await controller.loadCharacters()
        case .relations:
            await controller.loadRelations()
        case .staff:
            await controller.loadStaff()
        }
    }
}

// MARK: - 追番 / 时间表

extension BangumiInfoScreen {
    /// 当前追番状态（本地收藏库里的）。
    private func currentType(_ controller: InfoController) -> CollectType {
        library.entry(for: controller.item.id)?.collectType ?? .none
    }

    private func collect(_ controller: InfoController, _ type: CollectType) {
        let item = controller.item
        if type == .none {
            library.remove(bangumiID: item.id)
            // 与原版一致：不再处于「在看」时，时间表条目一并删除。
            BangumiTimelineStore.shared.dropIfNotWatching(item.id, collectType: CollectType.none)
            return
        }
        library.upsert(
            LibraryEntry(
                id: item.id,
                type: type.rawValue,
                name: item.name,
                nameCn: item.nameCn,
                summary: item.summary,
                airDate: item.airDate,
                imageURL: item.largeImage,
                rating: item.ratingScore,
                rank: item.rank,
                tags: item.tags.map(\.name),
                totalEpisodes: controller.episodes.count,
                currentEpisode: 0,
                addedAt: library.entry(for: item.id)?.addedAt ?? Date(),
                updatedAt: Date()
            )
        )
        // 改成「在看」以外的状态时，时间表条目随之失效（原版 dropIfNotWatching）。
        BangumiTimelineStore.shared.dropIfNotWatching(item.id, collectType: type)
    }

    /// 当前放送星期：用户手动改过就用手动的，否则用条目的开播日。
    private func currentWeekday(_ controller: InfoController) -> Int {
        let store = BangumiTimelineStore.shared
        if let entry = store.entry(for: controller.item.id), entry.weekdayCustom {
            return max(1, min(7, entry.weekday))
        }
        return max(1, min(7, controller.item.airWeekday))
    }

    private func isInTimeline(_ controller: InfoController) -> Bool {
        BangumiTimelineStore.shared.entry(for: controller.item.id)?.showInTimeline ?? false
    }

    /// 时间表开关：点亮即在时间表展示（与原版 _setShowInTimeline 一致）。
    ///
    /// 原版点亮前要求番剧处于「在看」状态：不在看就先弹确认，确认后顺手
    /// 标成在看。之前这里直接写存储，既缺这一步，写入路径本身还会崩
    /// （存储层用非字符串键做 JSONSerialization，见 BangumiTimelineStore）。
    private func toggleTimeline(_ controller: InfoController) {
        let next = !isInTimeline(controller)
        guard next else {
            BangumiTimelineStore.shared.setShowInTimeline(
                false,
                for: controller.item.id,
                weekday: currentWeekday(controller)
            )
            toastMessage = "已从时间表移除"
            return
        }
        if currentType(controller) != .watching {
            pendingTimelineItem = controller.item
            return
        }
        enableTimeline(controller)
    }

    /// 真正写入「在时间表展示」。
    private func enableTimeline(_ controller: InfoController) {
        BangumiTimelineStore.shared.setShowInTimeline(
            true,
            for: controller.item.id,
            weekday: currentWeekday(controller)
        )
        toastMessage = "已在时间表展示"
    }

    /// 确认「标记为在看并开启」后：先写收藏，再点亮时间表。
    private func markWatchingAndEnableTimeline(_ item: BangumiItem) {
        library.upsert(
            LibraryEntry(
                id: item.id,
                type: CollectType.watching.rawValue,
                name: item.name,
                nameCn: item.nameCn,
                summary: item.summary,
                airDate: item.airDate,
                imageURL: item.largeImage,
                rating: item.ratingScore,
                rank: item.rank,
                tags: item.tags.map(\.name),
                totalEpisodes: 0,
                currentEpisode: 0,
                addedAt: library.entry(for: item.id)?.addedAt ?? Date(),
                updatedAt: Date()
            )
        )
        BangumiTimelineStore.shared.setShowInTimeline(
            true,
            for: item.id,
            weekday: max(1, min(7, item.airWeekday))
        )
        toastMessage = "已标记为在看，并在时间表展示"
    }

    /// 星期序号（1 = 周一 ... 7 = 周日）的中文标题。
    private func weekdayTitle(_ weekday: Int) -> String {
        let titles = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return titles[max(1, min(7, weekday)) - 1]
    }
}

// MARK: - 更多菜单

extension BangumiInfoScreen {
    private func copyTitle(_ controller: InfoController) {
        UIPasteboard.general.string = controller.item.displayName
        toastMessage = "标题已复制"
    }

    private func saveCover(_ controller: InfoController) {
        let urlString = controller.item.largeImage
        guard !urlString.isEmpty, let url = Self.imageURL(from: urlString) else {
            toastMessage = "暂无封面"
            return
        }
        Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try await PHPhotoLibrary.shared().performChanges {
                    // iOS 26 SDK 起 addResource 必须显式传 options（无默认值的重载已被移除）。
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
                toastMessage = "已保存到相册"
            } catch {
                toastMessage = "封面保存失败，请重试"
            }
        }
    }

    private func openExternally(_ controller: InfoController) {
        guard let url = URL(string: "https://bangumi.tv/subject/\(controller.item.id)") else { return }
        UIApplication.shared.open(url)
    }

    /// Bangumi 的图片地址可能是协议相对地址，统一补成 https。
    private static func imageURL(from raw: String) -> URL? {
        let normalized = KazumiImageLoader.normalizedURLString(raw)
        return normalized.isEmpty ? nil : URL(string: normalized)
    }
}

