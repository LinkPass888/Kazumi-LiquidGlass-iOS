//
//  TimelineScreen.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/timeline/timeline_page.dart：
//  * 顶栏左边是**放送季度**（点开切换季度），右边是「排序与筛选」玻璃药丸
//    （图标 + 当前排序名，有筛选时带角标）——与原版窄屏顶栏一致；
//  * 下面是一排 7 天的选择器：今天显示「今天」，其余显示「周X」，各带当日数量；
//  * 主体是所选那天的卡片列表（BangumiTimelineCard），
//    带「HH:mm 更新」「第 N 话」两个胶囊和正在追的书签。
//

import SwiftUI

struct TimelineScreen: View {
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    var zoomNamespace: Namespace.ID?

    @State private var controller = TimelineController()
    @State private var selectedWeekday = TimelineScreen.todayIndex
    @State private var isShowingSeasonPicker = false
    @State private var isShowingOptions = false

    @Environment(LibraryStore.self) private var library
    @Environment(\.colorScheme) private var colorScheme

    private static let weekdayTitles = ["一", "二", "三", "四", "五", "六", "日"]

    /// ISO 星期是 1...7（周一...周日），这里换成 0 基下标。
    private static var todayIndex: Int {
        max(0, min(6, DateTimeHelper.isoWeekday(Date()) - 1))
    }

    private static let seasonColumns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 4
    )

    /// 派生数据：追番状态表，供合并手动条目与筛选共用。
    private var collectTypes: [Int: CollectType] {
        library.entries.reduce(into: [Int: CollectType]()) { result, entry in
            result[entry.id] = entry.collectType
        }
    }

    // MARK: - 派生数据

    private var watchingIDs: Set<Int> {
        Set(library.entries.filter { $0.collectType == .watching }.map(\.id))
    }

    private var watchedIDs: Set<Int> {
        Set(library.entries.filter { $0.collectType == .watched }.map(\.id))
    }

    private var droppedIDs: Set<Int> {
        Set(library.entries.filter { $0.collectType == .dropped }.map(\.id))
    }

    private var filteredCalendar: [[BangumiItem]] {
        controller.filterCalendar(
            watchingIDs: watchingIDs,
            watchedIDs: watchedIDs,
            droppedIDs: droppedIDs
        )
    }

    private var dayItems: [BangumiItem] {
        filteredCalendar.indices.contains(selectedWeekday) ? filteredCalendar[selectedWeekday] : []
    }

    private var rawDayIsNotEmpty: Bool {
        controller.bangumiCalendar.indices.contains(selectedWeekday)
            && !controller.bangumiCalendar[selectedWeekday].isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            weekdaySelector
            content
        }
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isShowingSeasonPicker) {
            seasonSheet
        }
        .sheet(isPresented: $isShowingOptions) {
            optionsSheet
        }
        .task {
            await loadInitialSeason()
        }
        // 详情页改完放送星期 / 点亮「在时间表展示」后，回到这里立刻重排。
        .onChange(of: BangumiTimelineStore.shared.revision) { _, _ in
            Task { await controller.refreshCustomEntries(collectTypes: collectTypes) }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            seasonTitleButton
            Spacer(minLength: 8)
            optionsButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// 顶栏标题就是当前季度，和原版 `_buildSeasonPicker(inAppBar: true)` 一致。
    /// 标题下面补一行当日条目数，顶栏因此同时给出「哪一季、这天有几部」。
    private var seasonTitleButton: some View {
        Button {
            isShowingSeasonPicker = true
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(controller.seasonLabel)
                        .font(.system(size: 24, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Text(dayCountText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换放送季度，当前 \(controller.seasonLabel)，\(dayCountText)")
    }

    /// 「今天 12 部」/「周二 8 部」。
    private var dayCountText: String {
        let title = selectedWeekday == Self.todayIndex && controller.isCurrentSeason
            ? "今天"
            : "周\(Self.weekdayTitles[max(0, min(6, selectedWeekday))])"
        if controller.isLoading { return "\(title) · 加载中" }
        return "\(title) · \(dayItems.count) 部"
    }

    /// 右上角：排序与筛选（图标 + 当前排序名 + 筛选角标）。
    private var optionsButton: some View {
        let filterCount = controller.activeFilterCount
        return Button {
            isShowingOptions = true
        } label: {
            HStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                    if filterCount > 0 {
                        Text("\(filterCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(KazumiPalette.onAccent(for: colorScheme))
                            .frame(width: 13, height: 13)
                            .background(
                                Circle().fill(KazumiPalette.accent(for: colorScheme))
                            )
                            .offset(x: 7, y: -7)
                    }
                }
                .frame(width: 18, height: 18)

                Text(controller.sort.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .kazumiGlassCapsule(interactive: true)
        .accessibilityLabel("排序与筛选")
        .accessibilityValue(
            filterCount > 0
                ? "\(controller.sort.title)，已启用 \(filterCount) 项筛选"
                : "\(controller.sort.title)，未启用筛选"
        )
    }

    // MARK: - 星期选择器

    private var weekdaySelector: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { day in
                dayButton(day)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func dayButton(_ day: Int) -> some View {
        let isSelected = day == selectedWeekday
        let isToday = controller.isCurrentSeason && day == Self.todayIndex
        let count = filteredCalendar.indices.contains(day) ? filteredCalendar[day].count : 0
        let title = isToday ? "今天" : "周\(Self.weekdayTitles[day])"
        // 提前算好颜色与字号，避免较长的三目表达式触发类型推断超时。
        let foreground: Color = isSelected ? KazumiPalette.onAccent(for: colorScheme) : .primary
        let background: Color = isSelected
            ? KazumiPalette.accent(for: colorScheme)
            : KazumiPalette.cardSurface(for: colorScheme)
        let countText = controller.isLoading ? "—" : "\(count)"

        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                selectedWeekday = day
            }
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(countText)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(foreground)
            .background(
                Capsule(style: .continuous).fill(background)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "星期\(Self.weekdayTitles[day])\(isToday ? "，今天" : "")，\(countText) 部"
        )
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if controller.isLoading && controller.bangumiCalendar.allSatisfy({ $0.isEmpty }) {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if controller.isTimeOut {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("本季时间表加载失败")
                    .font(.headline)
                Button("重试") {
                    Task {
                        await controller.loadSeason(controller.selectedDate, collectTypes: collectTypes)
                        prefetchCovers()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if dayItems.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(dayItems) { item in
                        BangumiTimelineCard(
                            item: item,
                            isWatching: watchingIDs.contains(item.id),
                            updateText: controller.updateText(for: item),
                            currentEpisode: controller.currentEpisode(for: item),
                            zoomNamespace: zoomNamespace
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await controller.loadSeason(controller.selectedDate, collectTypes: collectTypes)
                prefetchCovers()
            }
        }
    }

    private var emptyState: some View {
        let filteredOut = rawDayIsNotEmpty
        return VStack(spacing: 10) {
            Image(
                systemName: filteredOut
                    ? "line.3.horizontal.decrease.circle"
                    : "calendar.badge.exclamationmark"
            )
            .font(.system(size: 38, weight: .semibold))
            .foregroundStyle(.secondary)
            Text(filteredOut ? "没有符合筛选的番剧" : "这一天没有播出番剧")
                .font(.headline)
            if filteredOut {
                Button("清除筛选") {
                    controller.clearFilters()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 季度

    private var seasonSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("正在查看 \(controller.seasonLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)

                    // 与原版一致：最近 20 年，每年四个季度**横向**排列。
                    ForEach(Self.seasonYears, id: \.self) { year in
                        yearSection(year)
                    }
                }
                .padding(.vertical, 16)
            }
            .navigationTitle("放送季度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { isShowingSeasonPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func yearSection(_ year: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(year)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Self.seasonColumns, spacing: 8) {
                ForEach([1, 4, 7, 10], id: \.self) { month in
                    seasonChip(year: year, month: month)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func seasonChip(year: Int, month: Int) -> some View {
        let date = Self.seasonStart(year: year, month: month)
        let selected = AnimeSeason.isSameSeason(controller.selectedDate, date)
        let disabled = date > Date()
        let foreground: Color = selected ? KazumiPalette.onAccent(for: colorScheme) : .primary
        let background: Color = selected
            ? KazumiPalette.accent(for: colorScheme)
            : KazumiPalette.cardSurface(for: colorScheme)

        return Button {
            selectSeason(date)
        } label: {
            Text("\(AnimeSeason.seasonString(month: month))季")
                .font(.subheadline.weight(selected ? .bold : .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(foreground)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(background)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    // MARK: - 排序与筛选

    private var optionsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("排序")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(TimelineSort.allCases) { option in
                                sortChip(option)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("显示范围")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            filterRow("隐藏看过的番剧", isOn: notShowWatchedBinding)
                            Divider().padding(.leading, 14)
                            filterRow("隐藏抛弃的番剧", isOn: notShowAbandonedBinding)
                            Divider().padding(.leading, 14)
                            filterRow("只看正在追的番剧", isOn: onlyShowWatchingBinding)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(KazumiPalette.cardSurface(for: colorScheme))
                        )
                    }
                }
                .padding(16)
            }
            .navigationTitle("排序与筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { isShowingOptions = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func sortChip(_ option: TimelineSort) -> some View {
        let selected = controller.sort == option
        let foreground: Color = selected ? KazumiPalette.onAccent(for: colorScheme) : .primary
        let background: Color = selected
            ? KazumiPalette.accent(for: colorScheme)
            : KazumiPalette.cardSurface(for: colorScheme)

        return Button {
            Task { await controller.changeSort(option) }
        } label: {
            Text(option.title)
                .font(.footnote.weight(selected ? .bold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(foreground)
                .background(Capsule(style: .continuous).fill(background))
        }
        .buttonStyle(.plain)
    }

    private func filterRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .font(.subheadline)
            .tint(KazumiPalette.accent(for: colorScheme))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
    }

    private var notShowWatchedBinding: Binding<Bool> {
        Binding(
            get: { controller.notShowWatchedBangumis },
            set: { controller.setNotShowWatchedBangumis($0) }
        )
    }

    private var notShowAbandonedBinding: Binding<Bool> {
        Binding(
            get: { controller.notShowAbandonedBangumis },
            set: { controller.setNotShowAbandonedBangumis($0) }
        )
    }

    private var onlyShowWatchingBinding: Binding<Bool> {
        Binding(
            get: { controller.onlyShowWatchingBangumis },
            set: { controller.setOnlyShowWatchingBangumis($0) }
        )
    }

    // MARK: - 动作

    private func loadInitialSeason() async {
        guard controller.bangumiCalendar.isEmpty else { return }
        selectedWeekday = Self.todayIndex
        await controller.loadSeason(Date(), collectTypes: collectTypes)
        prefetchCovers()
    }

    private func selectSeason(_ date: Date) {
        isShowingSeasonPicker = false
        Task {
            await controller.loadSeason(date, collectTypes: collectTypes)
            prefetchCovers()
        }
    }

    /// 季初那一个月的 1 号（与原版 `DateTime(year, month)` 一致）。
    private static func seasonStart(year: Int, month: Int) -> Date {
        Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
    }

    private static var seasonYears: [Int] {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        return (0..<20).map { year - $0 }
    }

    /// 列表出现前先预热封面，滚动时不再一张张从网络取。
    private func prefetchCovers() {
        let urls = controller.bangumiCalendar.flatMap { $0.map(\.largeImage) }
        KazumiImageLoader.shared.prefetch(urls)
    }
}
