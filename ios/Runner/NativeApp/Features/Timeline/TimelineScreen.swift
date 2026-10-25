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
    @State private var isShowingOptions = false
    @State private var isLiquidWeekday = false
    @State private var weekdayDragX: CGFloat?
    @State private var weekdaySolidifyTask: Task<Void, Never>?
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
    /// 点击区域覆盖整块标题，当前季度 + 箭头即可。
    private var seasonTitleButton: some View {
        Button {
            isShowingSeasonPicker = true
        } label: {
            HStack(spacing: 4) {
                Text(controller.seasonLabel)
                    .font(.system(size: 34, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换放送季度，当前 \(controller.seasonLabel)")
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
                        .font(.system(size: 22, weight: .semibold))
                    if filterCount > 0 {
                        Text("\(filterCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(KazumiPalette.onAccent(for: colorScheme))
                            .frame(width: 15, height: 15)
                            .background(
                                Circle().fill(KazumiPalette.accent(for: colorScheme))
                            )
                            .offset(x: 8, y: -8)
                    }
                }
                .frame(width: 22, height: 22)

                Text(controller.sort.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
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

    // 定稿（2026-10-24，照 LP 给的液态 tab 版）：外框是纯色胶囊；静止时滑块 primary 8%。
    // 手指一碰整条立刻「液化」——实心滑块淡出，手指底下浮起一块 .clear 的液态玻璃
    // （比格子宽 14、高 10，只折它底下的刻度线，文字压在它上面永远清楚）；松手后玻璃先飞到目标格，停 0.28–0.42 秒
    // 再缓缓凝回实心。整条同一时刻只有这一块玻璃。
    /// 轨道可见高。
    private static let weekdayTrackHeight: CGFloat = 44
    /// 实心滑块相对轨道的内缩。
    private static let weekdayGlassInset: CGFloat = 3
    /// 液态玻璃比格子多出来的宽高。
    private static let weekdayLiquidGrowth = CGSize(width: 14, height: 10)

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

                // 刻度线在最底下，专门留给玻璃折。
                ForEach(1..<7, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1.5, height: 24)
                        .offset(x: cellWidth * CGFloat(index) - 0.75,
                                y: (Self.weekdayTrackHeight - 24) / 2)
                }

                weekdaySlider(centerX: centerX, cellWidth: cellWidth)

                // 玻璃在文字下面：字永远横平竖直、不被折变形，玻璃只折它底下的刻度线。
                weekdayLiquidGlass(centerX: centerX, cellWidth: cellWidth)

                weekdayLabels
            }
            .frame(height: Self.weekdayTrackHeight)
            .contentShape(Capsule(style: .continuous))
            // 切天那一刻才液化，松手不直接凝——等 selectedWeekday 真变了再计时凝固。
            .onChange(of: selectedWeekday) { _, _ in
                weekdaySolidifyTask?.cancel()
                if !isLiquidWeekday {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.65)) {
                        isLiquidWeekday = true
                    }
                }
                scheduleWeekdaySolidify(delayMilliseconds: 420)
            }
            .gesture(weekdayDragGesture(width: proxy.size.width))
        }
        .frame(height: Self.weekdayTrackHeight)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .onDisappear { weekdaySolidifyTask?.cancel() }
    }

    /// 静止时的实心滑块：primary 8%，字颜色不变；液化时淡出交给玻璃。
    private func weekdaySlider(centerX: CGFloat, cellWidth: CGFloat) -> some View {
        let inset = Self.weekdayGlassInset
        let width = max(cellWidth - inset * 2, 1)
        return Capsule(style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(width: width, height: Self.weekdayTrackHeight - inset * 2)
            .offset(x: centerX - width / 2, y: inset)
            .opacity(isLiquidWeekday ? 0 : 1)
    }

    /// 手指底下的那块液态玻璃：盖在文字上方才折得出光，比格子只放一圈。
    private func weekdayLiquidGlass(centerX: CGFloat, cellWidth: CGFloat) -> some View {
        let width = cellWidth + Self.weekdayLiquidGrowth.width
        let height = Self.weekdayTrackHeight + Self.weekdayLiquidGrowth.height
        return WeekdayLiquidGlass()
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(isLiquidWeekday ? 0.12 : 0),
                    radius: isLiquidWeekday ? 8 : 0,
                    y: isLiquidWeekday ? 3 : 0)
            // 用 position 而不是 offset：position 吃掉父级提议的尺寸，玻璃比格子大也不会把整条顶歪。
            .position(x: centerX, y: Self.weekdayTrackHeight / 2)
            .opacity(isLiquidWeekday ? 1 : 0)
            .allowsHitTesting(false)
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
        .scaleEffect(isSelected && isLiquidWeekday ? 1.06 : 1)
        .animation(.spring(response: 0.26, dampingFraction: 0.7), value: isSelected && isLiquidWeekday)
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

    /// 一碰就液化；横移超过 4 点玻璃跟着手指走，指到第几格就选第几格。
    /// 松手不直接定凝固——等 Tab 真换天（selectedWeekday 变）那一刻才计时凝固。
    private func weekdayDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                weekdaySolidifyTask?.cancel()
                if !isLiquidWeekday {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.65)) {
                        isLiquidWeekday = true
                    }
                }
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
                // 不在这里定凝固，交给 onChange(selectedWeekday) 去定。
            }
    }

    /// 松手后让玻璃先停在目标格，过一会儿再缓缓凝回实心。
    private func scheduleWeekdaySolidify(delayMilliseconds: Int) {
        weekdaySolidifyTask?.cancel()
        weekdaySolidifyTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled else { return }
            // 凝固比展开快：0.24 秒收住，几乎不弹。
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                isLiquidWeekday = false
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

// MARK: - 星期条的玻璃

/// 手指底下的液态玻璃：.clear 全透明、零染色，只靠边缘亮弧和阴影定形。
private struct WeekdayLiquidGlass: View {
    var body: some View {
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(.clear.interactive(), in: .capsule)
        } else {
            Capsule(style: .continuous).fill(Color.white.opacity(0.5))
        }
    }
}
