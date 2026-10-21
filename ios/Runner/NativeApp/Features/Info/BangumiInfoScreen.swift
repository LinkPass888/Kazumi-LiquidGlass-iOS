//
//  BangumiInfoScreen.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/info/info_page.dart + bangumi_info_card.dart：
//  * 顶栏：返回 + 折叠后淡入的番剧名 + 右上角「更多」菜单（保存封面 / 复制标题 / 外部打开）；
//  * 信息卡：标题就是番剧名称，封面右侧是条目信息（放送开始 / 放送时间 / 更新进度 / 评分 / 排名），
//    条目信息下面是「追番状态」菜单（未追 / 在看 / 想看 / 搁置 / 看过 / 抛弃）；
//  * 横向排列的「概览 / 吐槽 / 角色 / 关联 / 制作人员」标签；
//  * 别名不是详情页的区块，它在片源弹窗里当检索词用（见 SourceSheet）；
//  * 右下角是「开始播放」的液态玻璃按钮。
//

import SwiftUI
import Photos
import UIKit

struct BangumiInfoScreen: View {
    var bangumiID: Int

    @State private var controller: InfoController?
    @State private var isShowingSources = false
    @State private var selectedTab: InfoTab = .overview
    @State private var scrollOffset: CGFloat = 0
    @State private var isShowingWeekdayPicker = false
    @State private var toastMessage: String?

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
                        coverBackdrop(controller)
                        infoCard(controller)
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
        .sheet(isPresented: $isShowingWeekdayPicker) {
            weekdayPicker(controller)
        }
    }

    // MARK: - 顶栏

    private func topBar(_ controller: InfoController) -> some View {
        HStack(spacing: 0) {
            barButton(symbol: "chevron.left", label: "返回") {
                dismiss()
            }

            Spacer(minLength: 8)

            // 原版：顶栏标题跟着折叠进度淡入（展开时卡片里已经写着番剧名称）。
            Text(controller.item.displayName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .opacity(scrollOffset > 30 ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: scrollOffset)

            Spacer(minLength: 8)

            // 右上角是「更多」菜单，与原版 info_actions_menu.dart 一致。
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
                    .frame(width: KazumiGlassMetrics.barButtonSize, height: KazumiGlassMetrics.barButtonSize)
            }
            .buttonStyle(.plain)
            .kazumiGlassCapsule(interactive: true)
            .accessibilityLabel("更多")
        }
        .padding(.leading, KazumiGlassMetrics.barEdgeInset)
        .padding(.trailing, KazumiGlassMetrics.barEdgeInset - KazumiGlassMetrics.barButtonGap / 2)
        .padding(.vertical, 6)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(scrollOffset > 24 ? 1 : 0)
        }
    }

    /// 顶栏圆形玻璃按钮，尺寸与间距取自 KazumiGlassMetrics。
    private func barButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: KazumiGlassMetrics.barButtonSize, height: KazumiGlassMetrics.barButtonSize)
        }
        .buttonStyle(.plain)
        .kazumiGlassCapsule(interactive: true)
        .accessibilityLabel(label)
    }

    // MARK: - 封面背景

    /// 原版 _InfoHeaderBackground：封面大图打模糊，底部渐隐进背景色。
    private func coverBackdrop(_ controller: InfoController) -> some View {
        BangumiRemoteImage(url: controller.item.largeImage)
            .frame(height: 220)
            .blur(radius: 15)
            .opacity(0.4)
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        KazumiPalette.background(for: colorScheme).opacity(0),
                        KazumiPalette.background(for: colorScheme),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 80)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, -16)
            .padding(.top, -8)
    }

    // MARK: - 信息卡

    /// 信息卡：标题 + 封面 + 右侧条目信息 + 追番状态菜单。
    private func infoCard(_ controller: InfoController) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题就是番剧名称。
            Text(controller.item.displayName)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 16) {
                cover(controller.item)
                itemInfoColumn(controller)
            }

            collectMenu(controller)
        }
    }

    /// 封面。宽度按原版的两栏算法：行宽减去 16 的间距再平分两栏。
    private func cover(_ item: BangumiItem) -> some View {
        BangumiRemoteImage(url: item.largeImage)
            .frame(
                width: coverWidth,
                height: coverWidth / BangumiPosterCard.coverAspectRatio
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 封面宽度：原版把封面与右侧文字列当成两个弹性子项平分行宽（宽屏时是三栏，
    /// 第三栏是「评分透视」）。这里没有评分透视图表，保持两栏。
    private var coverWidth: CGFloat {
        let screenWidth = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 390
        // 详情页的卡片最大宽度与原版一致（950）。
        let rowWidth = min(screenWidth - 32, 950)
        return max(80, (rowWidth - 16) / 2)
    }

    /// 条目信息列。排版与原版一致：标签一行，值一行（值用强调色加粗）。
    private func itemInfoColumn(_ controller: InfoController) -> some View {
        let item = controller.item
        return VStack(alignment: .leading, spacing: 8) {
            infoLine(label: "放送开始:", value: item.airDate.isEmpty ? "未知" : item.airDate)

            // 放送时间：星期可点（换列），右边是时间表开关（原版用日历符号）。
            VStack(alignment: .leading, spacing: 2) {
                Text("放送时间:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        isShowingWeekdayPicker = true
                    } label: {
                        HStack(spacing: 2) {
                            Text(weekdayTitle(currentWeekday(controller)))
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(KazumiPalette.accent)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(KazumiPalette.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("选择放送星期")

                    Button {
                        toggleTimeline(controller)
                    } label: {
                        Image(systemName: "calendar")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isInTimeline(controller) ? KazumiPalette.accent : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("在时间表展示")
                }
            }

            // 更新进度：原版 bangumi_info_card.dart 里紧跟在「放送时间」之后的一行，
            // 格式同样是「已更新到第几集/总集数」。原版读 AniList 的时刻服务，
            // 原生端没有那套服务，改用 Bangumi 自己的剧集列表算：播过的集数 / 总集数。
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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(KazumiPalette.accent)
                        Text(String(format: "%.1f", item.ratingScore))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(KazumiPalette.accent)
                        if item.votes > 0 {
                            Text("(\(item.votes) 人)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if item.rank > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bangumi Ranked:")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("#\(item.rank)")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(KazumiPalette.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「标签: 值」一行。值用强调色加粗，与原版一致。
    private func infoLine(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(KazumiPalette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: - 追番状态

    /// 追番状态：条目信息下面的一个菜单，不是三个分开的按钮。
    ///
    /// 文案沿用原版 lib/bean/widget/collect_button.dart 的 getTypeStringByInt：
    /// 未追 / 在看 / 想看 / 搁置 / 看过 / 抛弃。
    private func collectMenu(_ controller: InfoController) -> some View {
        let current = library.entry(for: controller.item.id)?.collectType ?? .none
        return Menu {
            Button {
                setCollect(controller, .none)
            } label: {
                Label(CollectType.none.buttonTitle, systemImage: current == .none ? "checkmark" : "plus")
            }
            ForEach(CollectType.enabledCases) { type in
                Button {
                    setCollect(controller, type)
                } label: {
                    Label(type.buttonTitle, systemImage: current == type ? "checkmark" : type.symbolName)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: current.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                Text(current.buttonTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(current == .none ? Color.primary : KazumiPalette.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(KazumiPalette.cardSurface(for: colorScheme))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("追番状态")
    }

    // MARK: - 标签

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
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected ? KazumiPalette.accent : KazumiPalette.cardSurface(for: colorScheme))
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
                isLoading: controller.isLoadingComments
            )
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

    // MARK: - 别名 / 剧集

    /// 「已更新/总集数」，对应原版 bangumi_info_card.dart 的 _updateProgress。
    ///
    /// 原版用 AniList 的时刻服务推「更新到第几集」，原生端没有那套服务，
    /// 这里改用 Bangumi 自己的剧集列表：播期已过的算已更新，
    /// 总集数取列表里的最大集号（列表可能缺集，用个数会算少）。
    /// 还没有任何一集播出时返回 nil，这一行就不显示。
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

    // MARK: - 开始播放

    /// 右下角的「开始播放」按钮（原版是 FloatingActionButton.extended）。
    private var startPlayingButton: some View {
        Button {
            isShowingSources = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("开始播放")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule(style: .continuous).fill(KazumiPalette.accent))
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(.trailing, 18)
        .padding(.bottom, 22)
        .accessibilityLabel("开始播放")
    }

    // MARK: - 提示

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

    // MARK: - 放送星期选择

    /// 放送星期选择器：与原版 bangumi_info_card.dart 的 _showWeekdayPicker 一致。
    private func weekdayPicker(_ controller: InfoController) -> some View {
        let current = currentWeekday(controller)
        return NavigationStack {
            VStack(spacing: 12) {
                ForEach(1...7, id: \.self) { weekday in
                    Button {
                        BangumiTimelineStore.shared.setWeekday(weekday, for: controller.item.id)
                        isShowingWeekdayPicker = false
                    } label: {
                        HStack {
                            Text(weekdayTitle(weekday))
                                .font(.body.weight(.semibold))
                            Spacer()
                            if weekday == current {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(KazumiPalette.accent)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(KazumiPalette.cardSurface(for: colorScheme))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .navigationTitle("选择放送星期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { isShowingWeekdayPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 行为

    private func load() async {
        let environment = self.environment
        let base = await BangumiAPI.info(id: bangumiID)
            ?? BangumiItem(id: bangumiID, name: "未知番剧", nameCn: "")
        let created = InfoController(item: base, plugins: environment.plugins)
        controller = created
        await created.loadDetailIfNeeded()
        await created.loadEpisodes()
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

    private func setCollect(_ controller: InfoController, _ type: CollectType) {
        let item = controller.item
        if type == .none {
            library.remove(bangumiID: item.id)
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
    private func toggleTimeline(_ controller: InfoController) {
        let store = BangumiTimelineStore.shared
        let next = !isInTimeline(controller)
        store.setShowInTimeline(next, for: controller.item.id, weekday: currentWeekday(controller))
        toastMessage = next ? "已在时间表展示" : "已从时间表移除"
    }

    /// 星期序号（1 = 周一 ... 7 = 周日）的中文标题。
    private func weekdayTitle(_ weekday: Int) -> String {
        let titles = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return titles[max(1, min(7, weekday)) - 1]
    }

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
        if raw.hasPrefix("//") { return URL(string: "https:" + raw) }
        if raw.hasPrefix("http://") { return URL(string: "https://" + raw.dropFirst("http://".count)) }
        return URL(string: raw)
    }
}