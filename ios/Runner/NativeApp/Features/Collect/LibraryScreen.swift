//
//  LibraryScreen.swift
//  Kazumi
//
//  对应 lib/pages/collect/collect_page.dart + collect_library_view.dart：
//  * 顶栏是「追番」+ 右侧「同步」按钮；
//  * 分类标签：全部 / 在看 / 想看 / 看过 / 搁置 / 抛弃，默认停在「在看」；
//  * 主体是收藏卡片列表，点开进详情，右侧菜单可改收藏状态；
//  * 没有收藏时给出引导，而不是空白页。
//

import SwiftUI

struct LibraryScreen: View {
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    var zoomNamespace: Namespace.ID?

    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    /// nil 表示「全部」。
    private static let categories: [CollectType?] = [
        nil, .watching, .wish, .watched, .onHold, .dropped,
    ]

    @State private var selectedType: CollectType? = .watching
    @State private var pendingID: Int?

    private var filteredEntries: [LibraryEntry] {
        let entries = library.entries
        guard let selectedType else {
            return entries.sorted { $0.updatedAt > $1.updatedAt }
        }
        return entries
            .filter { $0.collectType == selectedType }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        content
            // 头部与分类条合成一块吸附在顶部：两块都跟着固定，
            // 只提 header 的话内容会从分类条下面硬切过去。
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    header
                    categoryBar
                }
            }
            .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                KazumiImageLoader.shared.prefetch(library.entries.map(\.imageURL))
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

    // MARK: - 分类

    /// 六颗分类胶囊一律交给 `KazumiFlowLayout` 排，上限三颗一行（Colo 1185）。
    /// 为什么不横滑：六颗胶囊在 390 点宽的屏上放不进一行（六颗约 396 点 ＋
    /// 空隙 64 ＋ 右边的部数，可用只有 358），而一颗要横滑才看得见的分类等于
    /// 没有这颗——LP 就以为「抛弃」被删了。
    /// 为什么不用 ViewThatFits 两态：第二态要等流式布局那个件落地，件没到就会
    /// 溢出；一态到底，任何字号都不溢出、不横滑、不截断、不缩字号。
    private var categoryBar: some View {
        KazumiFlowLayout(maxColumns: 3, spacing: 8, rowSpacing: 10) {
            ForEach(Array(Self.categories.enumerated()), id: \.offset) { _, type in
                categoryChip(type)
            }
        }
        // 右边留出部数自己的宽 ＋ 间距，六颗的可用宽就少这么多。
        // 84 不是 74：最大字号下「1 部」两个字符就有 71 宽，加 12 的间距要 83；
        // 74 没撞上只是因为库里现在只有三位数，四位数一到就压上胶囊了（Colo 1247）。
        .padding(.trailing, 84)
        // 部数贴整条右上，不跟某一行走：流式布局里点不出「某一行」的右端，
        // 而整条右上在任何字号下位置都不变，也就不会跟任何一颗重叠、
        // 不会长成第七颗分类。
        .overlay(alignment: .topTrailing) { categoryCount }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func categoryChip(_ type: CollectType?) -> some View {
        let isSelected = selectedType == type
        let title = type?.title ?? "全部"
        // 与时间表星期胶囊同一套取色：按 colorScheme 显式取
        // （`KazumiPalette.accent(for:)`）。切分类时颜色要在动画事务里
        // 插值，别在这里引入会回到 trait collection 解析的动态色 ——
        // 那正是之前点分类闪退的位置。
        let foreground: Color = isSelected
            ? KazumiPalette.onAccent(for: colorScheme)
            : .primary
        let background: Color = isSelected
            ? KazumiPalette.accent(for: colorScheme)
            : KazumiPalette.cardSurface(for: colorScheme)
        return Button {
            selectedType = type
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(foreground)
                .background(
                    Capsule(style: .continuous).fill(background)
                )
        }
        .buttonStyle(.plain)
        // 胶囊视觉 34，命中区撑到 44（`Design/HitTarget.swift` 那条全库规矩）。
        // 不用 `hitTarget44()`：那个把框本身撑到 44，两行就成 44+10+44＝98，
        // 而定的整条高度是 78（胶囊 34＋行间 10＋胶囊 34）。所以这里把命中区
        // 向外胀 5 点再收回去：命中区 44、框仍是 34、整条 78。
        // 代价说清楚：这样量无障碍树，胶囊的框依旧是 34——**高度 44 只能用手按出来验**，
        // 不能靠量框。验法：按两行之间的缝，看落中的是哪一颗。
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .padding(.vertical, -5)
        // 屏上把数字收掉了，读屏还得念出来：收起来的是数字，不是数据。
        .accessibilityLabel(Text("\(title)，\(count(for: type)) 部"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 当前选中分类的部数。只这一处，不是六个数字、也不是合计（原版
    /// `collect_library_view.dart:280` 就是 `'\(count(_selectedType)) 部'`）。
    private var categoryCount: some View {
        let total = count(for: selectedType)
        return Text("\(total) 部")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("当前分类，\(total) 部"))
            // 跟第一行胶囊对齐：overlay 的 `.topTrailing` 对的是顶边，胶囊高 34、
            // 这行行高 16，顶边一平中心就差 9 点，看着像浮在那一排上面的 header。
            // 补成和胶囊一样的内边距，字中心就落在第一行胶囊的中线上；大字模式下
            // 两者一起长，对齐关系不会跑（Colo 1192）。
            .padding(.vertical, 8)
            .padding(.top, 1)
    }

    private func count(for type: CollectType?) -> Int {
        guard let type else { return library.entries.count }
        return library.entries.filter { $0.collectType == type }.count
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if filteredEntries.isEmpty {
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
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filteredEntries) { entry in
                        LibraryEntryCard(
                            entry: entry,
                            isPending: pendingID == entry.id,
                            zoomNamespace: zoomNamespace,
                            onOpen: { router.push(.bangumiInfo(bangumiID: entry.id)) },
                            onChangeType: { type in changeType(entry, to: type) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            // 顶部滚动边缘：内容从吸附的头部下方滚过，模糊盖住那一行。
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    private func changeType(_ entry: LibraryEntry, to type: CollectType) {
        guard pendingID == nil else { return }
        pendingID = entry.id
        var updated = entry
        updated.type = type.rawValue
        updated.updatedAt = Date()
        library.upsert(updated)
        pendingID = nil
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

                        if entry.totalEpisodes > 0 {
                            Text("看到第 \(entry.currentEpisode) / \(entry.totalEpisodes) 话")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
    }
}

