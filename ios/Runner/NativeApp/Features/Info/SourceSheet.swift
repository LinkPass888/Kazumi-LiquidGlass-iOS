//
//  SourceSheet.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/info/source_sheet.dart + source_sheet_view.dart：
//  * 打开时用中文名（缺失时用原名）对所有已装规则并发检索；
//  * 每条规则一行：规则名 + 状态（检索中 / N 个结果 / 无结果 / 检索失败 / 需要验证）；
//  * 有结果时可展开全部条目，点条目回调给详情页进入播放；
//  * 失败或需要验证时提供重试。
//

import SwiftUI

@MainActor
struct SourceSheet: View {
    let controller: InfoController
    var onPlay: (String, SearchItem) -> Void

    @State private var expanded: Set<String> = []
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
                                .foregroundStyle(KazumiPalette.accent)
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
                    .foregroundStyle(KazumiPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(KazumiPalette.cardSurface(for: colorScheme))
        )
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
                Image(systemName: "lock.circle").foregroundStyle(KazumiPalette.accent)
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
            Text("请先到「我的 → 规则设置」安装番剧来源。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("去安装规则") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}
