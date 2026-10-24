//
//  PluginShopView.swift
//  Kazumi
//
//  规则仓库（对应 lib/pages/plugin_editor/plugin_shop_page.dart）：
//  安装 / 更新 / 已安装三种状态，支持搜索、下拉刷新与批量更新。
//

import SwiftUI

struct PluginShopView: View {
    @Environment(PluginsController.self) private var plugins
    @Environment(\.colorScheme) private var colorScheme

    @State private var keyword = ""
    @State private var isLoading = false
    @State private var busyItems: Set<String> = []
    @State private var errorMessage: String?
    @State private var toast: String?

    private var filteredItems: [PluginHTTPItem] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return plugins.pluginHTTPList }
        return plugins.pluginHTTPList.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) ||
                $0.author.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        List {
            if isLoading && plugins.pluginHTTPList.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("正在获取规则目录…")
                        Spacer()
                    }
                    .padding(.vertical, 24)
                }
            } else if filteredItems.isEmpty {
                Section {
                    ContentUnavailableView(
                        plugins.pluginHTTPList.isEmpty ? "规则目录为空" : "没有匹配的规则",
                        systemImage: "shippingbox",
                        description: Text(plugins.pluginHTTPList.isEmpty ? "下拉刷新重试。" : "换个关键词试试。")
                    )
                }
            } else {
                Section {
                    ForEach(filteredItems) { item in
                        PluginCatalogRow(
                            item: item,
                            status: plugins.pluginStatus(item),
                            isBusy: busyItems.contains(item.id)
                        ) {
                            Task { await install(item) }
                        }
                    }
                } footer: {
                    Text("共 \(filteredItems.count) 条规则，数据来自 KazumiRules 仓库。")
                }
            }
        }
        // 顶部滚动边缘：列表顶部用渐进模糊（.soft）。
        .scrollEdgeEffectStyle(.automatic, for: .top)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(KazumiPalette.heroBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("规则仓库")
        .searchable(text: $keyword, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索规则或作者")
        .refreshable { await refresh(force: true) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await updateAll() }
                } label: {
                    Label("全部更新", systemImage: "arrow.down.circle")
                }
                .disabled(isLoading || plugins.updatablePluginCount == 0)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .kazumiGlassCapsule()
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await refresh(force: false) }
    }

    private func refresh(force: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            if force {
                _ = try await plugins.refreshPluginCatalog()
            } else {
                _ = try await plugins.ensurePluginCatalog()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func install(_ item: PluginHTTPItem) async {
        busyItems.insert(item.id)
        defer { busyItems.remove(item.id) }
        let result = await plugins.tryUpdatePlugin(named: item.name)
        switch result {
        case .updated:
            showToast("已安装 \(item.name)")
        case .notNewer:
            showToast("\(item.name) 已是最新版本")
        case .requiresNewerClient:
            errorMessage = "规则「\(item.name)」需要更高版本的客户端"
        case .failed:
            errorMessage = "安装「\(item.name)」失败，请稍后重试"
        }
    }

    private func updateAll() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await plugins.tryUpdateAllPlugins()
            showToast(result.updated > 0 ? "已更新 \(result.updated) 条规则" : "没有需要更新的规则")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.snappy) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) { toast = nil }
        }
    }
}

private struct PluginCatalogRow: View {
    let item: PluginHTTPItem
    let status: PluginCatalogItemStatus
    let isBusy: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                    if item.antiCrawlerEnabled {
                        Label("验证", systemImage: "checkmark.shield")
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                    }
                }
                HStack(spacing: 10) {
                    Label(item.author, systemImage: "person")
                    Label(item.version, systemImage: "tag")
                    if item.lastUpdate > 0 {
                        Label(Self.dateText(item.lastUpdate), systemImage: "clock")
                    }
                }
                .font(.caption)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
            }
            Spacer(minLength: 0)
            if isBusy {
                ProgressView()
            } else {
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(buttonTint.opacity(0.16), in: Capsule())
                        .foregroundStyle(buttonTint)
                }
                .buttonStyle(.plain)
                .disabled(status == .installed)
            }
        }
        .padding(.vertical, 2)
    }

    private var buttonTitle: String {
        switch status {
        case .install: "安装"
        case .installed: "已安装"
        case .update: "更新"
        }
    }

    private var buttonTint: Color {
        switch status {
        case .install, .update: KazumiPalette.accent(for: colorScheme)
        case .installed: KazumiPalette.secondaryText(for: colorScheme)
        }
    }

    private static func dateText(_ epochSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
