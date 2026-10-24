//
//  SearchFilterSheet.swift
//  Kazumi
//
//  对应 lib/pages/search/search_filter_sheet.dart 的「按条件查找」面板：
//  题材标签、季度、评分区间、名次区间、放送星期与排序。
//  确认时把条件拼成搜索语法回填搜索框，与 SearchParser.fromFilterState 一致。
//

import SwiftUI

struct SearchFilterSheet: View {
    var onApply: (SearchFilterState) -> Void

    @State private var state: SearchFilterState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// 与 constants.dart 的 defaultAnimeTags 一致。
    private static let tags: [String] = [
        "日常", "原创", "校园", "搞笑", "奇幻", "百合", "恋爱", "悬疑",
        "热血", "后宫", "机战", "轻改", "偶像", "治愈", "异世界",
    ]

    private static let sorts: [(value: String, title: String)] = [
        ("heat", "热度"),
        ("rank", "排名"),
        ("score", "评分"),
        ("match", "匹配度"),
    ]

    private static let weekdayTitles = ["一", "二", "三", "四", "五", "六", "日"]

    init(initial: SearchFilterState, onApply: @escaping (SearchFilterState) -> Void) {
        self.onApply = onApply
        _state = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("关键词") {
                    TextField("番剧名称", text: $state.keyword)
                        .autocorrectionDisabled()
                }

                Section("题材") {
                    tagGrid
                }

                Section("排序") {
                    Picker("排序方式", selection: $state.sort) {
                        ForEach(Self.sorts, id: \.value) { sort in
                            Text(sort.title).tag(sort.value)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("放送季度") {
                    Picker("季度", selection: seasonBinding) {
                        Text("不限").tag("")
                        ForEach(seasonOptions, id: \.self) { season in
                            Text(season).tag(season)
                        }
                    }
                }

                Section("评分") {
                    OptionRangeRow(options: [0, 5, 6, 7, 7.5, 8, 8.5, 9], selection: scoreBinding)
                }

                Section("名次") {
                    HStack(spacing: 12) {
                        TextField("最小", value: rankMinBinding, format: .number)
                            .keyboardType(.numberPad)
                        Text("—")
                            .foregroundStyle(.secondary)
                        TextField("最大", value: rankMaxBinding, format: .number)
                            .keyboardType(.numberPad)
                    }
                }

                Section("放送星期") {
                    weekdayGrid
                }
            }
            .navigationTitle("按条件查找")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("重置") { state = SearchFilterState(keyword: state.keyword) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        onApply(state)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - 组件

    private var tagGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 76), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(Self.tags, id: \.self) { tag in
                let selected = state.tags.contains(tag)
                Button {
                    if selected {
                        state.tags.removeAll { $0 == tag }
                    } else {
                        state.tags.append(tag)
                    }
                } label: {
                    Text(tag)
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected ? KazumiPalette.accent(for: colorScheme) : Color.secondary.opacity(0.14))
                        )
                        .foregroundStyle(selected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private var weekdayGrid: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { day in
                let selected = state.weekdays.contains(day)
                Button {
                    if selected {
                        state.weekdays.removeAll { $0 == day }
                    } else {
                        state.weekdays.append(day)
                        state.weekdays.sort()
                    }
                } label: {
                    Text(Self.weekdayTitles[day - 1])
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected ? KazumiPalette.accent(for: colorScheme) : Color.secondary.opacity(0.14))
                        )
                        .foregroundStyle(selected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 绑定与选项

    private var seasonBinding: Binding<String> {
        Binding(
            get: { state.season },
            set: { newValue in
                state.season = newValue
                // 选了季度就不再叠加自定义日期区间，避免两个条件同时生效。
                if !newValue.isEmpty { state.dateRange = nil }
            }
        )
    }

    private var scoreBinding: Binding<Double> {
        Binding(
            get: { state.scoreRange?.min ?? 0 },
            set: { value in
                state.scoreRange = value <= 0 ? nil : SearchDoubleRange(min: value, max: nil)
            }
        )
    }

    private var rankMinBinding: Binding<Int?> {
        Binding(
            get: { state.rankRange?.min },
            set: { value in
                let max = state.rankRange?.max
                state.rankRange = (value == nil && max == nil)
                    ? nil
                    : SearchIntRange(min: value, max: max)
            }
        )
    }

    private var rankMaxBinding: Binding<Int?> {
        Binding(
            get: { state.rankRange?.max },
            set: { value in
                let min = state.rankRange?.min
                state.rankRange = (value == nil && min == nil)
                    ? nil
                    : SearchIntRange(min: min, max: value)
            }
        )
    }

    /// 近 8 年的四个季度，倒序排列。
    private var seasonOptions: [String] {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        return (0..<8).flatMap { offset -> [String] in
            let value = year - offset
            return [4, 3, 2, 1].map { "\(value)Q\($0)" }
        }
    }
}

/// 离散选项的一行选择器（评分区间用）。
private struct OptionRangeRow: View {
    let options: [Double]
    @Binding var selection: Double

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    let selected = abs(selection - option) < 0.001
                    Button {
                        selection = option
                    } label: {
                        Text(option <= 0 ? "不限" : String(format: "%.1f+", option))
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selected ? KazumiPalette.accent(for: colorScheme) : Color.secondary.opacity(0.14))
                            )
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }
}
