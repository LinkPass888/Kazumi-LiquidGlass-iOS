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
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    @State private var isShowingImporter = false
    @State private var isShowingImportSheet = false
    @State private var isShowingShop = false
    /// 新建规则：推入编辑器并带上模板。
    @State private var isShowingNewRule = false
    @State private var selectedRule: Plugin?
    @State private var pendingDeletion: Plugin?
    @State private var isEditingSelection = false
    @State private var selection: Set<String> = []
    @State private var isUpdating = false
    @State private var updateSummary: String?
    @State private var errorMessage: String?
    /// 搜索关键词：按规则名 / 站点地址 / 作者过滤。
    @State private var keyword = ""

    /// 过滤后的规则列表。
    private var visiblePlugins: [Plugin] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return plugins.pluginList }
        return plugins.pluginList.filter { plugin in
            plugin.name.localizedCaseInsensitiveContains(trimmed)
                || plugin.baseUrl.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        List {
            // 操作组：两行放同一个 Section，才有一条 0.5 分隔线、才被看成一件事的两种做法。
            // 「添加规则」弹菜单不翻页，所以不给箭头；「规则仓库」真推一页，给箭头。
            // 行高 48 用内容 44 换：List 这一层自己还给每行上下各留 2pt（实测 44→48、48→52）。
            Section {
                Menu {
                    addRuleMenuItems
                } label: {
                    Label("添加规则", systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

                Button {
                    isShowingShop = true
                } label: {
                    HStack(spacing: 0) {
                        Label("规则仓库", systemImage: "shippingbox")
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            }

            if plugins.pluginList.isEmpty {
                Section {
                    ContentUnavailableView(
                        "还没有安装规则",
                        systemImage: "puzzlepiece.extension"
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } else if visiblePlugins.isEmpty {
                Section {
                    ContentUnavailableView(
                        "没有匹配的规则",
                        systemImage: "magnifyingglass",
                        description: Text("换个关键词试试。")
                    )
                }
            } else {
                Section {
                    ForEach(visiblePlugins) { plugin in
                        row(plugin)
                    }
                    .onMove(perform: move)
                } footer: {
                    Text(footerText)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollContentBackground(.hidden)
        .background(KazumiPalette.heroBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("规则管理")
        .searchable(
            text: $keyword,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索规则名或站点"
        )
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
        .navigationDestination(isPresented: $isShowingNewRule) {
            PluginEditorView(original: Plugin.template(apiLevel: KazumiAppInfo.ruleAPILevel))
        }
        .sheet(isPresented: $isShowingImportSheet) {
            PluginImportSheet { summary in
                await applyImport(summary)
            }
        }
        .fileImporter(isPresented: $isShowingImporter, allowedContentTypes: [.json, .plainText]) { result in
            handleFileImport(result)
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
    // MARK: - 行

    /// 单行规则：点击进编辑，右侧溢出菜单（原版 KazumiMenuButton）。
    @ViewBuilder
    private func row(_ plugin: Plugin) -> some View {
        HStack(spacing: 8) {
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

            if !isEditingSelection {
                rowMenu(plugin)
            }
        }
        .swipeActions(edge: .trailing) {
            // 左滑只记录待删除规则，确认前不删行、不预播删除动画。
            Button(role: .destructive) {
                pendingDeletion = plugin
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        // 弹窗锚定到触发行；标题只读本行常量名称，pending 期间行内容与高度保持不变。
        .confirmationDialog(
            "删除规则「\(plugin.name)」？",
            isPresented: Binding(
                get: { pendingDeletion?.id == plugin.id },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                // remove() 只在确认回调里执行，行消失后底栏计数才随数据更新一次。
                pendingDeletion = nil
                Task { await remove([plugin]) }
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        }
    }

    /// 行内溢出菜单，条目与原版 plugin_view_page 的 _menu 一一对应。
    private func rowMenu(_ plugin: Plugin) -> some View {
        Menu {
            Button {
                selectedRule = plugin
            } label: {
                Label("编辑规则", systemImage: "square.and.pencil")
            }
            // 原版 _menu 的第二项就是「测试规则」，跳独立的测试页。
            Button {
                router.push(.pluginTest(ruleID: plugin.name))
            } label: {
                Label("测试规则", systemImage: "testtube.2")
            }
            Button {
                Task { await checkUpdate(plugin) }
            } label: {
                Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isUpdating)
            Button {
                UIPasteboard.general.string = PluginImportExport.ruleLink(for: plugin)
                updateSummary = "已复制「\(plugin.name)」的分享链接"
            } label: {
                Label("分享规则", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button {
                moveUp(plugin)
            } label: {
                Label("上移", systemImage: "arrow.up")
            }
            .disabled(index(of: plugin) == 0)
            Button {
                moveDown(plugin)
            } label: {
                Label("下移", systemImage: "arrow.down")
            }
            .disabled(index(of: plugin) == plugins.pluginList.count - 1)
            Divider()
            Button(role: .destructive) {
                pendingDeletion = plugin
            } label: {
                Label("删除规则", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .hitTarget44()
        }
        .accessibilityLabel("\(plugin.name) 的更多操作")
    }

    private var footerText: String {
        if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let updatable = plugins.updatablePluginCount
            return "共 \(plugins.pluginList.count) 条规则\(updatable > 0 ? "，\(updatable) 条可更新" : "")。行内菜单的「上移 / 下移」可以调整优先级。"
        }
        return "匹配 \(visiblePlugins.count) / \(plugins.pluginList.count) 条规则。"
    }

    private func index(of plugin: Plugin) -> Int {
        plugins.pluginList.firstIndex { $0.id == plugin.id } ?? 0
    }

    private func moveUp(_ plugin: Plugin) {
        let current = index(of: plugin)
        guard current > 0 else { return }
        move(from: IndexSet(integer: current), to: current - 1)
    }

    private func moveDown(_ plugin: Plugin) {
        let current = index(of: plugin)
        guard current < plugins.pluginList.count - 1 else { return }
        move(from: IndexSet(integer: current), to: current + 2)
    }

    /// 单条规则检查更新。
    private func checkUpdate(_ plugin: Plugin) async {
        isUpdating = true
        defer { isUpdating = false }
        let result = await plugins.tryUpdatePlugin(named: plugin.name)
        switch result {
        case .updated:
            updateSummary = "已更新「\(plugin.name)」"
        case .notNewer:
            updateSummary = "「\(plugin.name)」已是最新版本"
        case .requiresNewerClient:
            updateSummary = "「\(plugin.name)」需要更高版本的客户端"
        case .failed:
            errorMessage = "检查「\(plugin.name)」更新失败，请稍后重试"
        }
    }

    // MARK: - 工具栏

    /// 「添加规则」弹出的三项（唯一出处）。仓库已经在屏上那行了，同一件事不给两个入口。
    @ViewBuilder
    private var addRuleMenuItems: some View {
        Button {
            isShowingImportSheet = true
        } label: {
            Label("从剪贴板导入", systemImage: "doc.on.clipboard")
        }
        Button {
            isShowingImporter = true
        } label: {
            Label("从文件导入", systemImage: "folder.badge.plus")
        }
        Divider()
        Button {
            isShowingNewRule = true
        } label: {
            Label("新建规则", systemImage: "square.and.pencil")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isEditingSelection {
                Button("完成") {
                    isEditingSelection = false
                    selection.removeAll()
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if isEditingSelection {
                let count = selection.count
                let allSelected = count == plugins.pluginList.count
                Button(allSelected ? "取消全选" : "全选") {
                    if allSelected {
                        selection.removeAll()
                    } else {
                        selection = Set(plugins.pluginList.map(\.name))
                    }
                }
                Button(count == 0 ? "删除" : "删除 \(count)", role: .destructive) {
                    let targets = plugins.pluginList.filter { selection.contains($0.name) }
                    Task { await remove(targets) }
                }
                .disabled(selection.isEmpty)
            } else {
                Menu {
                    Button {
                        isEditingSelection = true
                    } label: {
                        Label("批量编辑", systemImage: "checkmark.circle")
                    }
                    .disabled(plugins.pluginList.isEmpty)
                    Button {
                        Task { await checkForUpdates() }
                    } label: {
                        Label(isUpdating ? "正在检查更新…" : "检查规则更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isUpdating || plugins.pluginList.isEmpty)
                } label: {
                    if isUpdating {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .accessibilityLabel("更多操作")
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
                    .foregroundStyle(isSelected ? KazumiPalette.accent(for: colorScheme) : KazumiPalette.tertiaryText(for: colorScheme))
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
                .background(KazumiPalette.accent(for: colorScheme).opacity(0.16), in: Capsule())
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
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
