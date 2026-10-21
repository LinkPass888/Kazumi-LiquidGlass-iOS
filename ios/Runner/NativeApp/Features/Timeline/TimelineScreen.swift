//
//  TimelineScreen.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/timeline/timeline_page.dart：
//  * 顶部是「新番时间表」+ 季度按钮（点开可切换季度与排序）；
//  * 下面是一排 7 天的选择器：今天显示「今天」，其余显示「周X」，各带当日数量；
//  * 主体是所选那天的卡片列表（BangumiTimelineCard）。
//

import SwiftUI

struct TimelineScreen: View {
    @State private var controller = TimelineController()
    @State private var selectedWeekday = TimelineScreen.todayIndex
    @State private var isShowingSeasonPicker = false
    @Environment(\.colorScheme) private var colorScheme

    private static let weekdayTitles = ["一", "二", "三", "四", "五", "六", "日"]

    /// ISO 星期是 1...7（周一...周日），这里换成 0 基下标。
    private static var todayIndex: Int {
        max(0, min(6, DateTimeHelper.isoWeekday(Date()) - 1))
    }

    private var currentItems: [BangumiItem] {
        guard controller.bangumiCalendar.indices.contains(selectedWeekday) else { return [] }
        return controller.bangumiCalendar[selectedWeekday]
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
            seasonPicker
        }
        .task {
            if controller.bangumiCalendar.isEmpty {
                selectedWeekday = Self.todayIndex
                await controller.loadSeason(Date())
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center) {
            Text("新番时间表")
                .font(.system(size: 24, weight: .bold))
            Spacer(minLength: 8)
            Button {
                isShowingSeasonPicker = true
            } label: {
                HStack(spacing: 4) {
                    Text(controller.seasonLabel)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .kazumiGlassCapsule(interactive: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
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
        let count = controller.counts.indices.contains(day) ? controller.counts[day] : 0
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { selectedWeekday = day }
        } label: {
            VStack(spacing: 2) {
                Text(isToday ? "今天" : "周\(Self.weekdayTitles[day])")
                    .font(.system(size: 13, weight: .bold))
                Text(controller.isLoading ? "—" : "\(count)")
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background {
                Capsule(style: .continuous)
                    .fill(isSelected ? KazumiPalette.accent : KazumiPalette.cardSurface(for: colorScheme))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isToday ? "今天" : "周\(Self.weekdayTitles[day])")，\(count) 部")
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if controller.isLoading && currentItems.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text("正在加载本季时间表…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if currentItems.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(controller.isTimeOut ? "本季时间表加载失败" : "这一天没有播出番剧")
                    .font(.headline)
                if controller.isTimeOut {
                    Button("重试") {
                        Task { await controller.loadSeason(controller.selectedDate) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(currentItems) { item in
                        BangumiTimelineCard(item: item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await controller.loadSeason(controller.selectedDate)
            }
        }
    }

    // MARK: - 季度与排序

    private var seasonPicker: some View {
        NavigationStack {
            List {
                Section("排序") {
                    ForEach(TimelineSort.allCases) { sort in
                        Button {
                            Task { await controller.changeSort(sort) }
                        } label: {
                            HStack {
                                Text(sort.title)
                                Spacer()
                                if controller.sort == sort {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(KazumiPalette.accent)
                                }
                            }
                        }
                    }
                }

                // 与原版一致：最近 20 年，每年四个季度。
                ForEach(Self.seasonYears, id: \.self) { year in
                    Section(String(year)) {
                        ForEach([1, 4, 7, 10], id: \.self) { month in
                            Button {
                                isShowingSeasonPicker = false
                                let date = Calendar(identifier: .gregorian)
                                    .date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
                                selectedWeekday = 0
                                Task { await controller.loadSeason(date) }
                            } label: {
                                Text("\(AnimeSeason.seasonString(month: month))季")
                            }
                        }
                    }
                }
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
    }

    private static var seasonYears: [Int] {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        return (0..<20).map { year - $0 }
    }
}

