//
//  PluginListView.swift
//  Kazumi
//
//  规则管理主界面（对应 lib/pages/plugin_editor/plugin_view_page.dart）。
//  列表、排序、批量删除、导入导出、检查更新与规则商店入口。
//

import SwiftUI
import UniformTypeIdentifiers

struct PluginListView: View {
    @Environment(PluginsController.self) private var plugins
    @Environment(\.colorScheme) private var colorScheme

    @State private var isShowingImporter = false
    @State private var isShowingImportSheet = false
    @State private var isShowingShop = false
    @State private var selectedRule: Plugin?
    @State private var pendingDeletion: Plugin?
    @State private var isEditingSelection = false
    @State private var selection: Set<String> = []
    @State private var isUpdating = false
    @State private var updateSummary: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(plugins.pluginList) { plugin in
                    Button {
                        if isEditingSelection {
                            toggle(plugin)
                        } else {
                            selectedRule = plugin
                        }
                    } label: {
                        PluginRowView(
                            plugin: plugin,
                            status: plugins.pluginUpdateStatus(plugin),
                            isSearchValid: plugins.validityTracker.isSearchValid(plugin.name),
                            isSelecting: isEditingSelection,
                            isSelected: selection.contains(plugin.name)
                        )
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDeletion = plugin
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            selectedRule = plugin
                        } label: {
                            Label("编辑", systemImage: "square.and.pencil")
                        }
                        .tint(KazumiPalette.accent)
                    }
                }
                .onMove(perform: move)
            } footer: {
                if plugins.pluginList.isEmpty {
                    Text("还没有规则。可以从规则仓库安装，或导入 JSON / kazumi:// 链接。")
                } else {
                    Text("共 \(plugins.pluginList.count) 条规则\(plugins.updatablePluginCount > 0 ? "，\(plugins.updatablePluginCount) 条可更新" : "")。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(KazumiPalette.heroBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("规则管理")
        .toolbar { toolbarContent }
        .navigationDestination(isPresented: Binding(
            get: { selectedRule != nil },
            set: { if !$0 { selectedRule = nil } }
        )) {
            if let selectedRule {
                PluginEditorView(original: selectedRule)
            }
        }
        .navigationDestination(isPresented: $isShowingShop) {
            PluginShopView()
        }
        .sheet(isPresented: $isShowingImportSheet) {
            PluginImportSheet { summary in
                await applyImport(summary)
            }
        }
        .fileImporter(isPresented: $isShowingImporter, allowedContentTypes: [.json, .plainText]) { result in
            handleFileImport(result)
        }
        .confirmationDialog(
            "删除规则「\(pendingDeletion?.name ?? "")」？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let plugin = pendingDeletion {
                    pendingDeletion = nil
                    Task { await remove([plugin]) }
                }
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        }
        .alert("提示", isPresented: Binding(
            get: { updateSummary != nil },
            set: { if !$0 { updateSummary = nil } }
        )) {
            Button("好", role: .cancel) { updateSummary = nil }
        } message: {
            Text(updateSummary ?? "")
        }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            if plugins.pluginList.isEmpty { plugins.load() }
        }
    }
    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isEditingSelection {
                Button("完成") {
                    isEditingSelection = false
                    selection.removeAll()
                }
            } else {
                EditButton()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    isShowingShop = true
                } label: {
                    Label("规则仓库", systemImage: "shippingbox")
                }
                Button {
                    isShowingImportSheet = true
                } label: {
                    Label("粘贴导入", systemImage: "doc.on.clipboard")
                }
                Button {
                    isShowingImporter = true
                } label: {
                    Label("从文件导入", systemImage: "folder.badge.plus")
                }
                Divider()
                Button {
                    copyAllRules()
                } label: {
                    Label("复制全部规则", systemImage: "doc.on.doc")
                }
                .disabled(plugins.pluginList.isEmpty)
                Button {
                    Task { await checkForUpdates() }
                } label: {
                    Label(isUpdating ? "正在检查更新…" : "检查规则更新", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isUpdating || plugins.pluginList.isEmpty)
                if !plugins.pluginList.isEmpty {
                    Button {
                        isEditingSelection = true
                    } label: {
                        Label("批量选择", systemImage: "checkmark.circle")
                    }
                }
            } label: {
                Image(systemName: isUpdating ? "hourglass" : "ellipsis.circle")
            }
        }
    }

    // MARK: - 操作

    private func toggle(_ plugin: Plugin) {
        if selection.contains(plugin.name) {
            selection.remove(plugin.name)
        } else {
            selection.insert(plugin.name)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        Task {
            do {
                try await plugins.move(fromOffsets: source, toOffset: destination)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func remove(_ targets: [Plugin]) async {
        do {
            try await plugins.removePlugins(named: Set(targets.map(\.name)))
            selection.subtract(targets.map(\.name))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyAllRules() {
        UIPasteboard.general.string = PluginImportExport.json(for: plugins.pluginList)
        updateSummary = "已复制 \(plugins.pluginList.count) 条规则的 JSON 到剪贴板。"
    }

    private func checkForUpdates() async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            let result = try await plugins.tryUpdateAllPlugins()
            if result.hasNoCandidates {
                updateSummary = "所有规则都是最新版本。"
            } else {
                var parts = ["可更新 \(result.candidates) 条"]
                if result.updated > 0 { parts.append("已更新 \(result.updated) 条") }
                if result.notNewer > 0 { parts.append("已是最新 \(result.notNewer) 条") }
                if result.requiresNewerClient > 0 { parts.append("\(result.requiresNewerClient) 条需要更高版本客户端") }
                if result.failed > 0 { parts.append("失败 \(result.failed) 条") }
                updateSummary = parts.joined(separator: "，") + "。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyImport(_ summary: PluginImportSummary) async {
        guard !summary.isEmpty else {
            if !summary.failures.isEmpty { errorMessage = summary.failures.prefix(3).joined(separator: "\n") }
            return
        }
        do {
            try await plugins.updatePlugins(summary.plugins)
            isShowingImportSheet = false
            var message = "已导入 \(summary.plugins.count) 条规则"
            if summary.duplicateCount > 0 { message += "（合并重复 \(summary.duplicateCount) 条）" }
            if !summary.replacedNames.isEmpty { message += "，覆盖了 \(summary.replacedNames.count) 条同名规则" }
            if !summary.failures.isEmpty { message += "；\(summary.failures.count) 条失败" }
            updateSummary = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleFileImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            let data = try Foundation.Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                errorMessage = "文件不是 UTF-8 文本"
                return
            }
            let summary = PluginImportExport.importResult(for: text, existing: plugins.pluginList)
            Task { await applyImport(summary) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 行视图

private struct PluginRowView: View {
    let plugin: Plugin
    let status: PluginUpdateAvailability
    let isSearchValid: Bool
    let isSelecting: Bool
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? KazumiPalette.accent : KazumiPalette.tertiaryText(for: colorScheme))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(plugin.name.isEmpty ? "未命名规则" : plugin.name)
                        .font(.headline)
                        .lineLimit(1)
                    badge
                }
                HStack(spacing: 10) {
                    Label(plugin.version.isEmpty ? "-" : plugin.version, systemImage: "tag")
                    Label(plugin.searchMode == .api ? "API" : "XPath", systemImage: plugin.searchMode == .api ? "curlybraces" : "chevron.left.forwardslash.chevron.right")
                    if plugin.antiCrawlerConfig.enabled {
                        Label("验证", systemImage: "checkmark.shield")
                    }
                }
                .font(.caption)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                Text(plugin.baseUrl)
                    .font(.caption2)
                    .foregroundStyle(KazumiPalette.tertiaryText(for: colorScheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var badge: some View {
        switch status {
        case .updatable:
            Text("可更新")
                .font(.caption2.bold())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(KazumiPalette.accent.opacity(0.16), in: Capsule())
                .foregroundStyle(KazumiPalette.accent)
        case .latest:
            if isSearchValid {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        case .notInCatalog, .unknown:
            EmptyView()
        }
    }
}
