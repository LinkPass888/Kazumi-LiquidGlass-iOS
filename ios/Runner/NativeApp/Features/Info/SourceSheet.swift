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
    var onPlay: (String, SearchItem) -> Void


    @State private var expanded: Set<String> = []
    /// 正在选别名去检索的来源；为空表示没有打开别名选择器。
    @State private var aliasPickerTarget: AliasPickerTarget?
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
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        controller.cancelSourceSearch()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await controller.searchAllSources() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(controller.isSearchingSources)
                    .accessibilityLabel("重新检索")
                }
            }
        }
        .task {
            await controller.searchAllSources()
            if let first = controller.sourceGroups.first(where: \.hasResults) {
                expanded.insert(first.name)
            }
        }
        .sheet(item: $aliasPickerTarget) { target in
            aliasPicker(for: target.sourceName)
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
                    if expanded.contains(group.name) {
                        expanded.remove(group.name)
                    } else {
                        expanded.insert(group.name)
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
                            Image(systemName: expanded.contains(group.name) ? "chevron.up" : "chevron.down")
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

            if group.hasResults, expanded.contains(group.name) {
                Divider().padding(.leading, 14)
                ForEach(Array(group.results.enumerated()), id: \.offset) { index, result in
                    Button {
                        onPlay(group.name, result)
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .trailing)
                            Text(result.name)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            Image(systemName: "play.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < group.results.count - 1 {
                        Divider().padding(.leading, 42)
                    }
                }
            }

            if group.status == .error || group.status == .captcha {
                Divider().padding(.leading, 14)
                Button {
                    Task { await controller.retrySource(group.name) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: group.status == .captcha ? "lock.shield" : "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                        Text(group.status == .captcha ? "完成验证后重试" : "重试")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                }
                .buttonStyle(.plain)
            }

            // 原版：没有结果时给「使用别名」，规则菜单里也有「使用别名检索此来源」。
            if !group.hasResults && group.status != .pending && !controller.aliases.isEmpty {
                Divider().padding(.leading, 14)
                Button {
                    aliasPickerTarget = AliasPickerTarget(sourceName: group.name)
                } label: {
                    Text("使用别名")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(KazumiPalette.cardSurface(for: colorScheme))
        )
    }

    /// 每条规则的「更多」菜单，对应原版 source_sheet_view.dart 的 _buildSourceMenu：
    /// 修改此来源的检索词 / 使用别名检索此来源 / 重新检索此来源。
    private func sourceMenu(_ group: InfoController.SourceGroup) -> some View {
        Menu {
            Button {
                Task { await controller.retrySource(group.name) }
            } label: {
                Label("重新检索此来源", systemImage: "arrow.clockwise")
            }
            if !controller.aliases.isEmpty {
                Button {
                    aliasPickerTarget = AliasPickerTarget(sourceName: group.name)
                } label: {
                    Label("使用别名检索此来源", systemImage: "textformat.alt")
                }
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
                            expanded.insert(sourceName)
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
