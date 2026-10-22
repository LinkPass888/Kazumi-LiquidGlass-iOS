//
//  SearchScreen.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/search/search_page.dart：
//  * 顶部是大号搜索框（左侧搜索图标，右侧清空与筛选）；
//  * 未搜索时展示「按条件查找」入口与搜索语法提示；
//  * 搜索结果复用推荐页的竖版卡片网格，滚到底自动续页。
//

import SwiftUI

struct SearchScreen: View {
    var initialKeyword: String = ""
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    var zoomNamespace: Namespace.ID?

    @State private var controller = SearchController()
    @State private var input = ""
    @State private var submittedQuery: String?
    @State private var isShowingFilters = false
    @State private var isShowingImageSearch = false
    @FocusState private var isInputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppRouter.self) private var router

    private var hasSearched: Bool { submittedQuery != nil }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                searchField
                    .padding(.top, hasSearched ? 8 : 20)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                if hasSearched {
                    results
                } else {
                    discovery
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingFilters) {
            SearchFilterSheet(initial: SearchParser(input).toFilterState()) { state in
                let query = SearchParser.fromFilterState(state)
                input = query
                submit(query)
            }
        }
        .navigationDestination(isPresented: $isShowingImageSearch) {
            ImageSearchScreen { keyword in
                // 对应 _imageSearch：拿到番名后直接提交搜索。
                input = keyword
                submit(keyword)
            }
        }
        .task {
            if !initialKeyword.isEmpty, input.isEmpty {
                input = initialKeyword
                submit(initialKeyword)
            }
        }
    }

    // MARK: - 搜索框

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("搜索番剧名称", text: $input)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isInputFocused)
                .onSubmit { submit(input) }

            if !input.isEmpty || hasSearched {
                Button {
                    input = ""
                    submittedQuery = nil
                    controller.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }

            // 与原版一致：搜索框右侧第二个按钮是「以图搜番」，筛选在发现态的「按条件查找」里。
            // 图标沿用项目里已验证可用的 photo.on.rectangle。
            Button {
                openImageSearch()
            } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("以图搜番")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(KazumiPalette.cardSurface(for: colorScheme))
        )
    }

    // MARK: - 发现态

    private var discovery: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isShowingFilters = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("按条件查找")
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text("题材、放送时间与评分")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(KazumiPalette.cardSurface(for: colorScheme))
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 6) {
                Text("搜索语法")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("tag:标签  season:2026Q1  score:8..10  rank:1..100  weekday:1,3  id:400602")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)

            recentSearches
        }
    }

    /// 最近搜索：与原版一致，最多 10 条，点击即搜。
    @ViewBuilder
    private var recentSearches: some View {
        let recents = SearchHistoryStore.load()
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最近搜索")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("查看全部") { router.push(.webSearchHistory) }
                        .font(.caption)
                }
                .padding(.horizontal, 20)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(recents.prefix(8), id: \.self) { keyword in
                        Button {
                            input = keyword
                            submit(keyword)
                        } label: {
                            Text(keyword)
                                .font(.footnote)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.secondary.opacity(0.12))
                                )
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 28)
        }
    }

    // MARK: - 结果

    @ViewBuilder
    private var results: some View {
        if controller.isLoading && controller.bangumiList.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else if controller.bangumiList.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(controller.isTimeOut ? "没有找到匹配结果" : "换个关键词试试")
                    .font(.headline)
                Button("修改条件") { isShowingFilters = true }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(controller.bangumiList) { item in
                    BangumiPosterCard(item: item, zoomNamespace: zoomNamespace)
                        .task { await loadMoreIfNeeded(current: item) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 24)
        }
    }

    private var columns: [GridItem] {
        let width = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 390
        let count = width > KazumiLayout.mediumWidth ? 6 : (width > KazumiLayout.compactWidth ? 5 : 3)
        return Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: count)
    }

    // MARK: - 行为

    /// 对应 _imageSearch：打开以图搜番。
    private func openImageSearch() {
        isInputFocused = false
        isShowingImageSearch = true
    }

    private func submit(_ value: String) {
        let state = SearchParser(value).toFilterState()
        let query = SearchParser.fromFilterState(state)
        isInputFocused = false
        input = query
        submittedQuery = query
        if !query.isEmpty { SearchHistoryStore.record(query) }
        Task { await controller.searchBangumi(query, type: "init") }
    }

    private func loadMoreIfNeeded(current item: BangumiItem) async {
        guard !controller.isLoading, controller.hasMoreSearchResults else { return }
        let items = controller.bangumiList
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              index >= items.count - 6,
              let query = submittedQuery else { return }
        await controller.searchBangumi(query)
    }
}

