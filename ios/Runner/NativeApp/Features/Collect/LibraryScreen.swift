//
//  LibraryScreen.swift
//  Kazumi
//
//  对应 lib/pages/collect/collect_page.dart + collect_library_view.dart：
//  * 顶栏是「追番」+ 右侧「同步」按钮；
//  * 控制条：分类菜单（全部 / 在看 / 想看 / 看过 / 搁置 / 抛弃，默认「在看」）
//    ＋ 排序菜单 ＋ 当前部数，右侧常驻搜索条；
//  * 主体是收藏卡片列表，点开进详情，右侧菜单可改收藏状态；
//  * 没有收藏时给出引导，而不是空白页。
//

import SwiftUI

struct LibraryScreen: View {
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    var zoomNamespace: Namespace.ID?

    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// nil 表示「全部」。
    private static let categories: [CollectType?] = [
        nil, .watching, .wish, .watched, .onHold, .dropped,
    ]

    @State private var selectedType: CollectType? = .watching
    /// 「在看」里记住的排序，存进 `SettingsStore.librarySort`。
    @State private var sort: CollectSort = .updateTime
    /// 其它分类里选的排序（只在本页会话里记），默认「最近变更」。
    @State private var otherSort: CollectSort = .recentlyChanged
    @State private var query = ""
    @State private var isSearching = false
    @State private var pendingID: Int?

    /// 「更新时间」排序用的时刻表：进页先算好，比较器只查表。
    @State private var updateTimes: [Int: Date] = [:]
    /// 季度时刻表是否已经跑完一轮。没跑完之前先按「最近变更」排，不转圈。
    @State private var updateTimesLoaded = false

    @FocusState private var searchFocused: Bool

    /// 网格列数。改列数只改这一个数，排版不重写（规格 §四）。
    private static let columnCount = 3
    /// 网格列间距。
    private static let columnSpacing: CGFloat = 10

    /// 内容区宽度（左右各 16 之后），由网格上方的探针量出来。
    /// 还没量到时按 0 处理，退回弹性列，量到之后立刻换成算好的定宽列。
    @State private var libraryContentWidth: CGFloat = 0

    /// 按内容宽算出三列的定宽列。
    private static func gridColumns(width: CGFloat) -> [GridItem] {
        guard width > 0 else {
            return Array(repeating: GridItem(.flexible(), spacing: columnSpacing), count: columnCount)
        }
        // 不取整：402 屏上每列 116.7，三列加两道间距正好铺满，右边不留缝。
        let total = width - columnSpacing * CGFloat(columnCount - 1)
        let each = max(1, total / CGFloat(columnCount))
        return Array(repeating: GridItem(.fixed(each), spacing: columnSpacing), count: columnCount)
    }

    // MARK: - 数据

    /// 去掉首尾空白后的搜索词；判空和过滤都用它。
    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 当前分类名，菜单按钮与无障碍文案共用。
    private var categoryTitle: String {
        selectedType?.title ?? "全部"
    }

    /// 实际生效的排序。
    ///
    /// 其它分类默认按 `updatedAt` 降序（也可以改成另外四档）；「在看」里如果
    /// 时刻表还没到，也先用最近变更把列表正常排出来，数据到了再切回用户选的排序。
    private var effectiveSort: CollectSort {
        guard selectedType == .watching else { return otherSort }
        if sort == .updateTime, !updateTimesLoaded { return .recentlyChanged }
        return sort
    }

    private var filteredEntries: [LibraryEntry] {
        let filtered = CollectLibraryQuery.filter(library.entries, type: selectedType, query: query)
        return CollectLibraryQuery.sort(filtered, by: effectiveSort, updateTimes: updateTimes)
    }

    var body: some View {
        content
            // 头部与控制条合成一块吸附在顶部：两块都跟着固定，
            // 只提 header 的话内容会从控制条下面硬切过去。
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    header
                    controlBar
                }
            }
            .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                sort = CollectSort(rawValue: settings.librarySort) ?? .updateTime
                KazumiImageLoader.shared.prefetch(library.entries.map(\.imageURL))
            }
            // 追番条目变化时补齐时刻表：新加入「在看」的番也要拿到时刻。
            .task(id: library.watchingEntries.map(\.id)) {
                await loadUpdateTimes()
            }
            // 详情页改了放送星期 / 时间表加载完成后，按新的星期重排一次。
            .onChange(of: BangumiTimelineStore.shared.revision) { _, _ in
                guard updateTimesLoaded else { return }
                updateTimes = makeUpdateTimes(for: library.watchingEntries)
            }
            // 搜索栏是在 `if isSearching` 里才出现的，等它进布局再拿焦点。
            .onChange(of: isSearching) { _, value in
                searchFocused = value
            }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center) {
            Text("追番")
                .font(.system(size: 34, weight: .semibold))

            Spacer(minLength: 8)

            // 叫「同步」：LP 2026-10-23 明确要求跟原版一致，字改回来了。
            // 早先它叫过「备份」，理由是按下去只会到「账号与备份」主页、不会立刻开始同步；
            // 这个歧义由那一页承担（「立即同步追番」会落在里面），不在按钮名上改。
            // MP: 未验证 —— 引擎落地后这颗按下去是否该直接开跑，等页面定了再说。
            Button {
                router.push(.syncBackup)
            } label: {
                HStack(spacing: 6) {
                    // 原版是循环箭头（lib/pages/collect/collect_page.dart:130 的
                    // Icons.sync_rounded），不是云。云是当初把字改成「备份」时
                    // 字、图标、去向一起翻的遗留物；字已退回「同步」，图标跟着退。
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 22, weight: .semibold))
                    Text("同步")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .kazumiGlassCapsule(interactive: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: - 控制条

    /// 一行控制条：分类菜单 ＋ 排序菜单 ＋ 部数，右侧搜索。
    /// 搜索展开时两个菜单和部数从布局里移除（不是盖住），整行高度不变。
    private var controlBar: some View {
        Group {
            if isSearching {
                searchRow
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            } else {
                defaultRow
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        // LP 2026-10-23：切换原来是一帧跳过去，「太快太突兀」。
        .animation(.smooth(duration: 0.32), value: isSearching)
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    private var defaultRow: some View {
        HStack(spacing: 8) {
            categoryMenu
            sortMenu
            categoryCount

            // LP 2026-10-23：默认就只是一颗放大镜按钮，点了才长成搜索条。
            searchIconButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 44)
    }

    private var categoryMenu: some View {
        Menu {
            Picker("分类", selection: categoryBinding) {
                ForEach(Array(Self.categories.enumerated()), id: \.offset) { index, type in
                    Text(type?.title ?? "全部").tag(index)
                }
            }
        } label: {
            menuCapsule(title: categoryTitle)
        }
        .accessibilityLabel(Text("筛选，\(categoryTitle)"))
        .accessibilityHint(Text("选择追番状态"))
    }

    /// 「更新时间」只对「在看」有意义：其它分类里菜单照常可点，只有这一项
    /// 灰掉；用户改选的另外四档都照常生效。灰掉的那一项用禁用的菜单项
    /// 单独排在最前，其余四项仍交给 Picker 打勾（不自己画对勾）。
    private var sortMenu: some View {
        Menu {
            if selectedType != .watching {
                Button {} label: {
                    Text(CollectSort.updateTime.label)
                }
                .disabled(true)
                .accessibilityHint(Text("只有「在看」里能按放送时间排"))
            }

            Picker("排序", selection: sortBinding) {
                ForEach(availableSorts) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            menuCapsule(title: effectiveSort.label)
        }
        .accessibilityLabel(Text("排序，\(effectiveSort.label)"))
        .accessibilityHint(Text("选择排序方式"))
    }

    /// 「在看」里五档全给；其它分类只给可选的四档（更新时间单独灰在最前）。
    private var availableSorts: [CollectSort] {
        selectedType == .watching
            ? CollectSort.allCases
            : CollectSort.allCases.filter { $0 != .updateTime }
    }

    /// 玻璃菜单底：视觉高度 36、命中区 44（外面撑出来，不加高亮）。
    /// LP 2026-10-23：原来写死 70/100 宽，「在看」两个字被挤成三个点；
    /// 现在按字撑开，多出来的宽度让给部数。
    ///
    /// 颜色用 `Color.primary` / `Color.secondary`，**不能用层级写法 `.primary`**：
    /// 菜单和按钮的标签会按 App 的全局 tint（KazumiApp 的 `.tint(accent)`）上色，
    /// 层级写法跟着 tint 走，字就变成主题色。LP 2026-10-24 报的就是这个。
    private func menuCapsule(title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .kazumiGlassCapsule(interactive: true)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 44)
        .contentShape(Rectangle())
    }

    /// 当前筛选结果的部数；搜索时跟着筛后条数走。
    private var categoryCount: some View {
        let total = filteredEntries.count
        return Text("\(total) 部")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            // 1024 部也不许被搜索条挤压。
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(Text("当前分类，\(total) 部"))
    }

    private var categoryBinding: Binding<Int> {
        Binding(
            get: { Self.categories.firstIndex(of: selectedType) ?? 0 },
            set: { index in
                let newType = Self.categories[index]
                // 切到其它分类时，**只有当前排的是「更新时间」才降级**成「最近变更」；
                // 其余四档在任何分类都能用，用户选的那档跟着走，不许切个分类就丢掉。
                // 切回「在看」时 `sort` 原样保留。
                if newType != selectedType, newType != .watching {
                    let current = effectiveSort
                    otherSort = current == .updateTime ? .recentlyChanged : current
                }
                selectedType = newType
            }
        )
    }

    private var sortBinding: Binding<CollectSort> {
        Binding(
            get: { effectiveSort },
            set: { newValue in
                // 「更新时间」只属于「在看」；灰掉的那一项即使被触发也不改状态。
                guard newValue != .updateTime || selectedType == .watching else { return }
                if selectedType == .watching {
                    sort = newValue
                    // 只记「在看」里选的排序；切分类不写这个键。
                    settings.librarySort = newValue.rawValue
                } else {
                    otherSort = newValue
                }
            }
        )
    }

    private var searchHint: String {
        "在「\(categoryTitle)」里搜索"
    }

    // MARK: - 搜索

    /// 常驻的 36 高搜索条。视觉 36，外面补到 44 的命中区。
    private var searchEntryButton: some View {
        Button {
            isSearching = true
            searchFocused = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.secondary)
                Text("搜索追番")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .kazumiGlassCapsule(interactive: true)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("搜索追番"))
        .accessibilityHint(Text(searchHint))
    }

    /// 最大字号装不下整条搜索时的 44 放大镜。
    private var searchIconButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.32)) { isSearching = true }
            searchFocused = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.secondary)
                // LP 2026-10-23：视觉 36，跟左边两个菜单胶囊一样高；命中区仍是 44。
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
                .kazumiGlassCapsule(interactive: true)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("搜索追番"))
        .accessibilityHint(Text(searchHint))
    }

    /// 展开态：搜索条占满整行，「取消」在右；整行仍是 44 高。
    private var searchRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                TextField("搜索追番", text: $query)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel(Text("搜索追番"))
                    .accessibilityHint(Text(searchHint))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("清空搜索"))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .kazumiGlassCapsule()
            .frame(height: 44)
            .contentShape(Rectangle())

            Button {
                cancelSearch()
            } label: {
                // LP 2026-10-23：字边上点不动 —— 可点范围只有字那么大。
                // 撑满 44 × 44，字居中。
                Text("取消")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("取消"))
        }
        .frame(height: 44)
    }

    private func cancelSearch() {
        query = ""
        searchFocused = false
        withAnimation(.smooth(duration: 0.32)) { isSearching = false }
    }

    // MARK: - 时刻表

    /// 进页 / 「在看」条目变化时补齐季度时刻表，然后一次性重排。
    /// 拉不到数据就保持空表 —— 调用方已经先用「最近变更」排好了，不转圈。
    private func loadUpdateTimes() async {
        let entries = library.watchingEntries
        for entry in entries {
            await BangumiAirTimeService.shared.ensureLoaded(
                subjectID: entry.id,
                airDate: entry.airDate
            )
            if Task.isCancelled { return }
        }
        let times = makeUpdateTimes(for: entries)
        updateTimes = times
        // 一部时刻都没拿到（季度 JSON 没到 / 没有匹配项）时继续按最近变更排，
        // 不要切成一堆 nil 的 id 序，那对用户没有意义。
        updateTimesLoaded = !times.isEmpty
    }

    /// 把「星期 + HH:mm」拼成本周这一集的时刻；较早于首播的由查询层丢成 nil。
    private func makeUpdateTimes(for entries: [LibraryEntry]) -> [Int: Date] {
        let service = BangumiAirTimeService.shared
        let weekdays = resolvedWeekdays(for: entries)
        let now = Date()
        var result: [Int: Date] = [:]

        for entry in entries {
            guard let weekday = weekdays[entry.id],
                  let text = service.airTime(for: entry.id),
                  let time = Self.hourMinute(text),
                  let schedule = service.schedules[entry.id],
                  let epoch = CollectLibraryQuery.updateTimeForWeekday(
                      hour: time.hour,
                      minute: time.minute,
                      weekday: weekday,
                      now: now,
                      firstAir: schedule.first
                  )
            else { continue }
            result[entry.id] = epoch
        }
        return result
    }

    /// 放送星期：用户手改 → 时间表分组 → bangumi 日历 airWeekday
    /// （iOS 收藏条目没有该字段，用同源的 `DateTimeHelper` 从开播日算）。
    ///
    /// 收藏条目都在「时间表日历」里，所以把它们的 id 全交给 `resolveWeekdays`，
    /// 用户手动点过的星期才会全部生效；没点过的落到开播日星期。
    private func resolvedWeekdays(for entries: [LibraryEntry]) -> [Int: Int] {
        let store = BangumiTimelineStore.shared
        let collectTypes = library.entries.reduce(into: [Int: CollectType]()) { result, entry in
            result[entry.id] = entry.collectType
        }
        let custom = store.resolveWeekdays(
            inCalendar: Set(entries.map(\.id)),
            collectTypes: collectTypes
        )

        var weekdays: [Int: Int] = [:]
        for entry in entries {
            let airWeekday = DateTimeHelper.dateStringToWeekday(
                entry.airDate.isEmpty ? "2000-11-11" : entry.airDate
            )
            weekdays[entry.id] = custom[entry.id] ?? airWeekday
        }
        return weekdays
    }

    private static func hourMinute(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute)
        else { return nil }
        return (hour, minute)
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if filteredEntries.isEmpty {
            if !trimmedQuery.isEmpty {
                searchEmptyState
            } else {
                libraryEmptyState
            }
        } else {
            ScrollView {
                // 三列海报网格（规格 §四）：列间距 10、行间距 14、左右 16、底部 24。
                // 列宽必须自己算出来给 `.fixed`：`.flexible()` 会被卡片内容的
                // 固有宽度撑开（实测卡宽 127、卡间 0.4、第三张越界 5），
                // 这里量出内容宽再按 `(内容宽 − 间距 × (列数 − 1)) / 列数` 定列宽。
                GeometryReader { proxy in
                    Color.clear.preference(key: LibraryContentWidthKey.self, value: proxy.size.width)
                }
                .frame(height: 0)
                // 跟网格用同一档左右内边距，量到的才是真正的可用宽（不是屏宽）。
                .padding(.horizontal, 16)

                LazyVGrid(
                    columns: Self.gridColumns(width: libraryContentWidth),
                    spacing: 14
                ) {
                    ForEach(filteredEntries) { entry in
                        LibraryPosterCard(
                            entry: entry,
                            isPending: pendingID == entry.id,
                            zoomNamespace: zoomNamespace,
                            onOpen: { router.push(.bangumiInfo(bangumiID: entry.id)) },
                            onChangeType: { type in changeType(entry, to: type) }
                        )
                        // 取消追番时这张卡淡出并缩到 0.92，其余卡片靠同一次动画补位。
                        .transition(cardRemovalTransition)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .onPreferenceChange(LibraryContentWidthKey.self) { width in
                libraryContentWidth = width
            }
            // LP 2026-10-23：点空白处也该能取消搜索，不能只有那颗「取消」能退出。
            .contentShape(Rectangle())
            .onTapGesture {
                guard isSearching else { return }
                cancelSearch()
            }
            .scrollIndicators(.hidden)
            // 顶部滚动边缘：内容从吸附的头部下方滚过，模糊盖住那一行。
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    private var libraryEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(library.entries.isEmpty ? "还没有追番" : "这个分类还没有番剧")
                .font(.headline)
            // 两种空要说两套话：整个库为空时告诉用户怎么加；
            // 只是这个分类为空时，库里明明有番，再劝他去详情页点「追番」会让人以为记错了。
            Text(library.entries.isEmpty
                 ? "在番剧详情页点「追番」即可加入这里。"
                 : "换一个分类，或者去推荐页找番剧。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if library.entries.isEmpty {
                Button("去推荐看看") {
                    router.selectedDestination = .popular
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 搜索无命中：不沿用「这个分类还没有番剧」，直接给清空搜索的出口。
    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            Text("没有匹配的番剧")
                .font(.headline)
            Button("清空搜索") {
                query = ""
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 改收藏状态，两条路分开走：
    /// * `type == .none` 是「取消追番」——这部从列表里消失，包一层动画让它淡出缩小，
    ///   剩下的卡片在同一次动画里补位（Ato 2026-10-24：不许手写定时器，也不许删完重排）；
    /// * 其余是改状态——卡片不动，只有角上那颗符号换掉，**不能包动画**，
    ///   否则整页会跟着动一下。
    private func changeType(_ entry: LibraryEntry, to type: CollectType) {
        guard pendingID == nil else { return }
        pendingID = entry.id
        if type == .none {
            withAnimation(removalAnimation) {
                library.remove(bangumiID: entry.id)
            }
        } else {
            var updated = entry
            updated.type = type.rawValue
            updated.updatedAt = Date()
            library.upsert(updated)
        }
        // 删掉的那一条已经不在列表里，别把 pendingID 留在它身上。
        pendingID = nil
    }

    /// 出门那一下的曲线：Colo 2026-10-24 定的 `.snappy(0.3)`。
    /// `easeOut` 是前快后慢，卡片 0.12 秒就几乎看不见了，后面那截缩小是空转，
    /// 而补位要到后半段才动，看着像两件事。
    /// 开了「减少动态效果」的人只淡出（0.2 秒）、不缩小、不滑动补位——
    /// 这一下要动一整排，对前庭敏感的人是负担，淡出已经说清它没了。
    private var removalAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.3)
    }

    private var cardRemovalTransition: AnyTransition {
        reduceMotion
            ? .asymmetric(insertion: .opacity, removal: .opacity)
            : .asymmetric(
                insertion: .opacity,
                removal: .opacity.combined(with: .scale(scale: 0.92))
            )
    }
}

/// 收藏卡片：沿用时间表卡片的外观，右侧菜单可改收藏状态。
private struct LibraryEntryCard: View {
    let entry: LibraryEntry
    let isPending: Bool
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    var zoomNamespace: Namespace.ID?
    var onOpen: () -> Void
    var onChangeType: (CollectType) -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// 封面宽度与时间表卡片保持一致（88pt），整页的封面尺寸就统一了。
    private static let coverWidth: CGFloat = 88

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    BangumiRemoteImage(url: entry.imageURL)
                        .frame(
                            width: Self.coverWidth,
                            height: Self.coverWidth / BangumiPosterCard.coverAspectRatio
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.displayName)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if entry.rating > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(String(format: "%.1f", entry.rating))
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                        }

                        Text(entry.collectType.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule(style: .continuous).fill(KazumiPalette.accent(for: colorScheme).opacity(0.14)))

                        // 这里原本有一行「看到第 X / Y 话」：原版列表条目没有这一项，
                        // 且 currentEpisode 今天没有一处会写（恒为 0），印出来是假进度。
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            // 只有「封面 + 文字」这块可点区域参与缩放转场，
            // 右侧的收藏状态菜单不跟着放大。
            .kazumiZoomSource(id: entry.id, namespace: zoomNamespace)

            Menu {
                ForEach(CollectType.enabledCases) { type in
                    Button(type.title) { onChangeType(type) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .hitTarget44()
                    .opacity(isPending ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("修改追番状态")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(KazumiPalette.cardSurface(for: colorScheme))
        )
        // LP 2026-10-23：整张卡片都能点开，不再只有封面那一小块。
        // 右侧那颗「修改状态」是自己的按钮，会先吃掉它范围内的点击。
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onTapGesture { onOpen() }
    }
}


/// 量网格可用内容宽用的一次性 preference（追番页网格列宽按它算）。
private struct LibraryContentWidthKey: PreferenceKey {
    // 必须是 `let`：`var` 在严格并发下是非隔离的全局可变状态，编译不过
    // （仓库里 InfoTabPanels.swift 的 IntroHeightKey 就是这个写法）。
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
