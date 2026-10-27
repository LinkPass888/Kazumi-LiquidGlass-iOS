//
//  SourceSheet.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/info/source_sheet.dart + source_sheet_view.dart：
//  * 打开时用中文名（缺失时用原名）对所有已装规则并发检索；
//  * 每条规则一行：规则名 + 状态（检索中 / N 个结果 / 无结果 / 检索失败 / 需要验证）；
//  * 有结果时可展开全部条目，点条目回调给详情页进入播放；
//  * 失败或需要验证时提供重试；
//  * 别名在原版里不是详情页的独立区块，而是这一层的检索手段：
//    「使用别名」按钮 + 规则菜单里的「使用别名检索此来源」。
//

import SwiftUI

/// 别名选择器的载体，供 sheet(item:) 使用。
struct AliasPickerTarget: Identifiable, Hashable {
    let sourceName: String
    var id: String { sourceName }

    init(sourceName: String) {
        self.sourceName = sourceName
    }
}

@MainActor
struct SourceSheet: View {
    let controller: InfoController
    /// 点了某条结果：关面板、从详情页往右推进播放页（LP 3273 / Colo 3275）。
    /// 返回时详情页再把面板带着原来那批结果放回来。
    var onPlay: (String, SearchItem) -> Void
    /// 打不开外部浏览器时的一句话。
    @State private var browserFailure = false
    /// 正在选别名去检索的来源；为空表示没有打开别名选择器。
    @State private var aliasPickerTarget: AliasPickerTarget?
    /// 正在修改检索词的来源；为空表示没有弹出输入框。
    @State private var keywordTarget: String?
    @State private var keywordDraft = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            Group {
                if controller.sourceGroups.isEmpty && controller.isSearchingSources {
                    ProgressView("正在检索所有规则…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if controller.sourceGroups.isEmpty {
                    emptyRuleView
                } else {
                    list
                }
            }
            .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
            .navigationTitle("选择播放源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 关闭在右上，左上留空。原来右上的「重新检索」（全部刷新）已经删掉：
                // 每条来源的菜单里都有自己的「重新检索此来源」，而全量刷新在失败态
                // 下会把已经出来的结果冲掉。
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        controller.closeSourceSearch()
                        dismiss()
                    }
                }
            }
        }
        .task {
            // 第一个回来的源就地展开，不等所有规则跑完
            // （LP 2026-10-27：原来要等最后一轮检索结束才展开，慢的源拖着整屏）。
            let search = Task { await controller.searchAllSources() }
            // 轮询要一直跑到检索真的结束，不能看 `isSearchingSources` 一开始是 false
            // 就 break —— 那一帧检索还没起跑，于是永远不展开（LP 2026-10-27
            //「播放源有检索结果却不展开」）。
            let expander = Task { @MainActor in
                while !Task.isCancelled {
                    if let first = controller.sourceGroups.first(where: \.hasResults) {
                        controller.sourceExpanded.insert(first.name)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            await search.value
            expander.cancel()
            // 最后一批结果可能是和检索结束同一帧到的，补一次；
            // 用户自己收起过就不再替他展开。
            if controller.sourceExpanded.isEmpty,
               let first = controller.sourceGroups.first(where: \.hasResults) {
                controller.sourceExpanded.insert(first.name)
            }
        }
        .sheet(item: $aliasPickerTarget) { target in
            aliasPicker(for: target.sourceName)
        }
        // 修改此来源的检索词（main 的 onSourceSearch）：只重检这一个来源。
        .alert(
            "修改检索词",
            isPresented: Binding(
                get: { keywordTarget != nil },
                set: { if !$0 { keywordTarget = nil } }
            )
        ) {
            TextField("检索词", text: $keywordDraft)
            Button("取消", role: .cancel) { keywordTarget = nil }
            Button("检索") {
                guard let name = keywordTarget else { return }
                let keyword = keywordDraft
                keywordTarget = nil
                controller.sourceExpanded.insert(name)
                Task { await controller.retrySource(name, keyword: keyword) }
            }
        } message: {
            Text(keywordTarget.map { "仅检索来源：\($0)" } ?? "")
        }
        .alert("无法打开浏览器，请稍后重试", isPresented: $browserFailure) {
            Button("好", role: .cancel) {}
        }
    }

    // MARK: - 动作

    /// 「在浏览器中打开」，网址照 main 的 _openInBrowser 取：
    /// 走接口的规则开 baseUrl，走网页的规则开 searchURL 并把 @keyword 换成这一条的检索词。
    /// 用外部浏览器，不是应用内。
    private func openInBrowser(_ group: InfoController.SourceGroup) {
        guard let plugin = controller.plugin(named: group.name) else {
            browserFailure = true
            return
        }
        let usesApi = plugin.searchMode == .api || !plugin.searchApiConfig.request.url.isEmpty
        let raw = usesApi
            ? plugin.baseUrl
            : plugin.searchURL.replacingOccurrences(
                of: "@keyword",
                with: group.keyword.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? group.keyword
            )
        guard let url = URL(string: raw), !raw.isEmpty else {
            browserFailure = true
            return
        }
        UIApplication.shared.open(url, options: [:]) { success in
            if !success { browserFailure = true }
        }
    }

    // MARK: - 列表

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(controller.sourceGroups) { group in
                    groupCard(group)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }

    private func groupCard(_ group: InfoController.SourceGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    if controller.sourceExpanded.contains(group.name) {
                        controller.sourceExpanded.remove(group.name)
                    } else {
                        controller.sourceExpanded.insert(group.name)
                    }
                } label: {
                    HStack(spacing: 10) {
                        statusDot(group.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(group.statusLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if group.hasResults {
                            Image(systemName: controller.sourceExpanded.contains(group.name) ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // 原版每条规则右上角有个「更多」菜单（_buildSourceMenu）。
                sourceMenu(group)
                    .padding(.trailing, 8)
            }

            if group.hasResults, controller.sourceExpanded.contains(group.name) {
                Divider().padding(.leading, 14)
                ForEach(Array(group.results.enumerated()), id: \.offset) { index, result in
                    Button {
                        onPlay(group.name, result)
                    } label: {
                        HStack(spacing: 8) {
                            Text(result.name)
                                .font(.body)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            Image(systemName: "play.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(minHeight: 64, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < group.results.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }

            // 一格里最多一行动作：失败只留「重试」，找不到只留「使用别名」。
            // 两个一起给过，看着就是「这一块到底该点哪个」。
            if group.status == .error {
                Divider().padding(.leading, 14)
                Button {
                    Task { await controller.retrySource(group.name) }
                } label: {
                    actionRowLabel(icon: "arrow.clockwise", title: "重试")
                }
                .buttonStyle(.plain)
            }

            // 找不到时只给「使用别名」。字用「使用别名」不用「更换别名」：
            // 这一屏是挑一个别名拿去搜，不是改别名（弹层标题就叫「别名检索」）。
            if group.status == .noResult && !controller.aliases.isEmpty {
                Divider().padding(.leading, 14)
                Button {
                    aliasPickerTarget = AliasPickerTarget(sourceName: group.name)
                } label: {
                    actionRowLabel(icon: nil, title: "使用别名")
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            KazumiPalette.cardShape(cornerRadius: 18, scheme: colorScheme)
        )
    }

    /// 卡片下面那一行动作按钮的样式：整行宽、上下 10、强调色。
    private func actionRowLabel(icon: String?, title: String) -> some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .foregroundStyle(KazumiPalette.accent(for: colorScheme))
        .contentShape(Rectangle())
    }

    /// 每条规则的「更多」菜单，对应原版 source_sheet_view.dart 的 _buildSourceMenu。
    ///
    /// 四项照 main。第四项「在浏览器中打开」一度没放，理由是「拿不到一个能直接
    /// 打开的网址」——那是错的：main 并不开检索请求本身，走接口的规则开 baseUrl，
    /// 走网页的规则开 searchURL 把关键词填进去，两个我们都有（LP 3260 / Colo）。
    private func sourceMenu(_ group: InfoController.SourceGroup) -> some View {
        Menu {
            Button {
                keywordDraft = group.keyword
                keywordTarget = group.name
            } label: {
                Label("修改此来源的检索词", systemImage: "text.cursor")
            }
            if !controller.aliases.isEmpty {
                Button {
                    aliasPickerTarget = AliasPickerTarget(sourceName: group.name)
                } label: {
                    Label("使用别名检索此来源", systemImage: "textformat.alt")
                }
            }
            Button {
                Task { await controller.retrySource(group.name) }
            } label: {
                Label("重新检索此来源", systemImage: "arrow.clockwise")
            }
            Button {
                openInBrowser(group)
            } label: {
                Label("在浏览器中打开", systemImage: "safari")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .hitTarget44()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.name) 的更多操作")
    }

    /// 别名选择器，对应原版 source_alias_dialog.dart 的 _AliasPickerDialog：
    /// 标题「别名检索」，副标题「仅检索来源：xxx」，点一个别名就用它去检索这个来源。
    private func aliasPicker(for sourceName: String) -> some View {
        NavigationStack {
            List {
                Section {
                    ForEach(controller.aliases, id: \.self) { alias in
                        Button {
                            // 先展开这一条，检索结果回来后就直接铺在下面。
                            controller.sourceExpanded.insert(sourceName)
                            aliasPickerTarget = nil
                            Task {
                                await controller.searchSourceWithAlias(alias, pluginName: sourceName)
                            }
                        } label: {
                            Text(alias)
                                .foregroundStyle(.primary)
                        }
                    }
                } header: {
                    Text("仅检索来源：\(sourceName)")
                }
            }
            .navigationTitle("别名检索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { aliasPickerTarget = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func statusDot(_ status: PluginSearchStatus) -> some View {
        Group {
            switch status {
            case .pending:
                ProgressView().controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .noResult:
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            case .error:
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            case .captcha:
                Image(systemName: "lock.circle").foregroundStyle(KazumiPalette.accent(for: colorScheme))
            }
        }
        .frame(width: 18, height: 18)
    }

    private var emptyRuleView: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("还没有安装任何规则")
                .font(.headline)
            Text("请先到「我的 → 规则管理」安装番剧来源。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // 这里原本有一颗「去安装规则」按钮，只调 `dismiss()`：字指了一条路，
            // 按钮没走那条路，人还在原地——一颗在说谎的按钮比没有按钮更坏。
            // 原版是有路由的（`lib/pages/info/info_page.dart:305-307` 的
            // `context.pushNamed('/settings/plugin/')`），我们这边 `AppRouter.pluginList` 也在。
            // 接法写好了，但「先关 sheet 再推页」会跟关闭动画抢，**没在屏上验过**，
            // 所以先只留这句指路；验通了再把按钮装回来。
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}

