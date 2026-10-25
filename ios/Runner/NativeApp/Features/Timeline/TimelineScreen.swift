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

    @Environment(SettingsStore.self) private var settings
    @State private var controller = TimelineController()
    @State private var selectedWeekday = TimelineScreen.todayIndex
    @State private var isShowingSeasonPicker = false
    @State private var weekdayDragX: CGFloat?
    @State private var pageOffsetX: CGFloat = 0
    @State private var pageViewportWidth: CGFloat = 1

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

    var body: some View {
        content
            // 头部与星期条合成一块吸附在顶部：两块都是固定块，
            // 只提 header 的话内容仍会从星期条下面硬切过去。
            // LP 2026-10-24（后一条）：顶栏不要毛玻璃了，改纯色底。
            // 这块（标题＋星期条）铺页面的底色，一直铺进状态栏，上滑时内容不从缝里透出来。
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    header
                    weekdaySelector
                }
                // `ignoresSafeAreaEdges: .top` 是关键（Colo 2026-10-24）：不加只从状态栏
                // 下面那 62 点开始铺，最上面一条还是光的，内容照样从时钟后面穿过去。
                .background(
                    KazumiPalette.background(for: colorScheme),
                    ignoresSafeAreaEdges: .top
                )
            }
            .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isShowingSeasonPicker) {
            seasonSheet
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
    /// 点击区域覆盖整块标题，当前季度 + 箭头即可。
    private var seasonTitleButton: some View {
        Button {
            isShowingSeasonPicker = true
        } label: {
            HStack(spacing: 4) {
                Text(controller.seasonLabel)
                    // LP 2631：标题收一档（原 34）。
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换放送季度，当前 \(controller.seasonLabel)")
    }

    /// 右上角：排序与筛选。LP 2631/2632/2637：去掉排序名，只留符号，玻璃底留着。
    /// LP 2643 / Colo 2644：点开改成从这颗按钮弹出的菜单 —— 排序用 Picker（天然带 ✓），
    /// 筛选用 Menu 里的 Toggle（选中就带 ✓）；有筛选生效时这颗胶囊换成实心主题色、
    /// 图标换 onAccent，且不再叠玻璃（玻璃会和实心色搅在一起）。
    private var optionsButton: some View {
        let filterCount = controller.activeFilterCount
        let hasFilters = filterCount > 0
        return Menu {
            Picker("排序", selection: sortBinding) {
                ForEach(TimelineSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            Section {
                Toggle("隐藏看过的番剧", isOn: notShowWatchedBinding)
                Toggle("隐藏抛弃的番剧", isOn: notShowAbandonedBinding)
                Toggle("只看正在追的番剧", isOn: onlyShowWatchingBinding)
            }
        } label: {
            iconCapsule(hasFilters: hasFilters)
        }
        .accessibilityLabel("排序与筛选")
        .accessibilityValue(
            hasFilters
                ? "\(controller.sort.title)，已启用 \(filterCount) 项筛选"
                : "\(controller.sort.title)，未启用筛选"
        )
    }

    /// 排序一改，controller 要重排整张时间表（异步），所以 setter 里起个任务。
    private var sortBinding: Binding<TimelineSort> {
        Binding(
            get: { controller.sort },
            set: { newValue in
                guard newValue != controller.sort else { return }
                Task { await controller.changeSort(newValue) }
            }
        )
    }

    /// 那颗胶囊本体：没筛选时玻璃底 + 次要色图标，有筛选时实心主题色 + onAccent 图标。
    @ViewBuilder
    private func iconCapsule(hasFilters: Bool) -> some View {
        let shape = Capsule(style: .continuous)
        if hasFilters {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(KazumiPalette.onAccent(for: colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(shape.fill(KazumiPalette.accent(for: colorScheme)))
        } else {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .kazumiGlassCapsule(interactive: true)
        }
    }

    // MARK: - 星期选择器

    // 外框是纯色胶囊，选中格垫一块 primary 8% 的实心滑块（LP 2519：液态玻璃那套切换效果删掉，
    // 太花且不像原生，只留实心填充；滑块仍跟手/跟翻页走，只是不再液化和回凝）。
    /// 轨道可见高。
    private static let weekdayTrackHeight: CGFloat = 44
    /// 实心滑块相对轨道的内缩。
    private static let weekdayGlassInset: CGFloat = 3

    private var weekdaySelector: some View {
        GeometryReader { proxy in
            let cellWidth = max(proxy.size.width, 1) / 7
            // 跟手：翻页滚动时玻璃直接按滚动偏移算，手指到哪它到哪；
            // 只有在拖星期条时才用 weekdayDragX 覆盖。
            let pageFloat = pageViewportWidth > 1 ? pageOffsetX / max(pageViewportWidth, 1) : CGFloat(selectedWeekday)
            let trackingX = cellWidth * (pageFloat + 0.5)
            let restX = cellWidth * (CGFloat(selectedWeekday) + 0.5)
            // 正在滚就跟滚动走，静止时回到选中格中心；拖条时以手指为准。
            let isPaging = abs(pageFloat - CGFloat(selectedWeekday)) > 0.01
            let baseX: CGFloat = isPaging ? trackingX : restX
            let centerX: CGFloat = {
                guard let x = weekdayDragX else { return baseX }
                return min(max(x, cellWidth / 2), max(proxy.size.width - cellWidth / 2, cellWidth / 2))
            }()

            ZStack(alignment: .topLeading) {
                // 外框：纯色胶囊托住玻璃，黑 6%、半径 6、y 2 的浅阴影让它离开页面，
                // 再加 1 点内描边，玻璃膨胀越出上下边时会被框沿折出一道亮弧。
                Capsule(style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.06), radius: 6, y: 2)

                weekdaySlider(centerX: centerX, cellWidth: cellWidth)

                weekdayLabels
            }
            .frame(height: Self.weekdayTrackHeight)
            .contentShape(Capsule(style: .continuous))
            .gesture(weekdayDragGesture(width: proxy.size.width))
        }
        .frame(height: Self.weekdayTrackHeight)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        // LP 2535 / Colo 2537：顶栏底色下沿贴着星期条下沿，不加空白底边；
        // 原来那 12 点搬到列表顶上，滚动时跟着内容走掉。
    }

    /// 选中格的实心滑块：浅色填充、字不变色（LP 2645 / Ato 2646 作废了主题色那版——
    /// 底色太深，左右翻页时格子的字换色会闪一下）。
    private func weekdaySlider(centerX: CGFloat, cellWidth: CGFloat) -> some View {
        let inset = Self.weekdayGlassInset
        let width = max(cellWidth - inset * 2, 1)
        return Capsule(style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(width: width, height: Self.weekdayTrackHeight - inset * 2)
            .offset(x: centerX - width / 2, y: inset)
    }

    private var weekdayLabels: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { day in
                weekdayCell(day)
            }
        }
        .frame(height: Self.weekdayTrackHeight)
        .sensoryFeedback(.selection, trigger: selectedWeekday)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("放送星期")
    }

    private func weekdayCell(_ day: Int) -> some View {
        let isSelected = day == selectedWeekday
        return VStack(spacing: 1) {
            Text(dayTitle(day))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(countText(day))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.weekdayTrackHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spokenDayTitle(day))，\(countText(day)) 部")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selectWeekday(day) }
    }

    private func dayTitle(_ day: Int) -> String {
        isTodayColumn(day) ? "今天" : "周\(Self.weekdayTitles[day])"
    }

    /// 读屏念全称：「星期三」「今天」。
    private func spokenDayTitle(_ day: Int) -> String {
        isTodayColumn(day) ? "今天" : "星期\(Self.weekdayTitles[day])"
    }

    private func isTodayColumn(_ day: Int) -> Bool {
        controller.isCurrentSeason && day == Self.todayIndex
    }

    private func countText(_ day: Int) -> String {
        if controller.isLoading && controller.bangumiCalendar.allSatisfy({ $0.isEmpty }) {
            return "—"
        }
        return "\(filteredCalendar.indices.contains(day) ? filteredCalendar[day].count : 0)"
    }

    private func selectWeekday(_ day: Int) {
        guard day != selectedWeekday else { return }
        // 点选星期：让页面滑过去慢一点，玻璃跟着滚动走，不再用固定时长硬切。
        withAnimation(.spring(response: 0.48, dampingFraction: 0.86)) {
            selectedWeekday = day
        }
    }

    /// 一碰实心滑块就跟手；横移超过 4 点滑块跟着手指走，指到第几格就选第几格。
    private func weekdayDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let cellWidth = max(width, 1) / 7
                if abs(value.translation.width) > 4 || weekdayDragX != nil {
                    let x = min(max(value.location.x, cellWidth / 2),
                                max(width - cellWidth / 2, cellWidth / 2))
                    withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.82)) {
                        weekdayDragX = x
                    }
                    let day = weekdayIndex(at: value.location.x, cellWidth: cellWidth)
                    if day != selectedWeekday {
                        withAnimation(.spring(response: 0.48, dampingFraction: 0.86)) {
                            selectedWeekday = day
                        }
                    }
                }
            }
            .onEnded { value in
                let cellWidth = max(width, 1) / 7
                let day = weekdayIndex(at: value.location.x, cellWidth: cellWidth)
                withAnimation(.spring(response: 0.48, dampingFraction: 0.86)) {
                    selectedWeekday = day
                    weekdayDragX = nil
                }
            }
    }

    private func weekdayIndex(at x: CGFloat, cellWidth: CGFloat) -> Int {
        min(max(Int((x / cellWidth).rounded(.down)), 0), 6)
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
        } else {
            // 一页一天：用横向分页 ScrollView，滚动偏移直接驱动星期条玻璃，
            // 手指到哪玻璃到哪；松手弹到最近页，真换天那一刻才开始凝固计时。
            GeometryReader { pageProxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { day in
                            dayPage(day)
                                .frame(width: pageProxy.size.width)
                                .id(day)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: Binding<Int?>(get: { selectedWeekday }, set: { if let v = $0 { selectedWeekday = v } }))
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: CGFloat.self, of: { geo in
                    geo.contentOffset.x
                }, action: { _, new in
                    pageOffsetX = new
                })
                .onAppear { pageViewportWidth = max(pageProxy.size.width, 1) }
                .onChange(of: pageProxy.size.width) { _, new in
                    pageViewportWidth = max(new, 1)
                }
            }
            // 轻触感反馈：滑切与点选星期都会触发；LP 清单「触感反馈」关掉后不再震。
            .sensoryFeedback(.selection, trigger: hapticTrigger)
        }
    }

    /// 触感反馈关闭时传 nil：`.sensoryFeedback` 不比较到新值就不触发。
    private var hapticTrigger: Int? {
        settings.hapticFeedbackEnabled ? selectedWeekday : nil
    }

    @ViewBuilder
    private func dayPage(_ day: Int) -> some View {
        let items = filteredCalendar.indices.contains(day) ? filteredCalendar[day] : []
        if items.isEmpty {
            emptyState(day: day)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        BangumiTimelineCard(
                            item: item,
                            showRating: settings.showRating,
                            isWatching: watchingIDs.contains(item.id),
                            updateText: controller.updateText(for: item),
                            currentEpisode: controller.currentEpisode(for: item),
                            zoomNamespace: zoomNamespace
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            // 顶部渐进模糊边（.soft）：只作用于顶部一条，不叠材质、不加底色。
            .scrollEdgeEffectStyle(.soft, for: .top)
            .refreshable {
                await controller.loadSeason(controller.selectedDate, collectTypes: collectTypes)
                prefetchCovers()
            }
        }
    }

    private func emptyState(day: Int) -> some View {
        let filteredOut = controller.bangumiCalendar.indices.contains(day)
            && !controller.bangumiCalendar[day].isEmpty
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
            // 年份不走本地化插值，否则会被渲染成「2,026」。
            Text(year, format: .number.grouping(.never))
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

    // MARK: - 筛选绑定

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

