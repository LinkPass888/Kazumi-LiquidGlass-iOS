//
//  SystemMenuButton.swift
//  Kazumi
//
//  播放器控制栏上的「更多」：点击弹出系统菜单（UIMenu），不是半屏面板。
//
//  为什么不用 SwiftUI 的 `Menu`：
//  播放中画面每秒都在刷新，`Menu` 会跟着整个视图重建；菜单弹出来以后留在屏幕上的
//  还是旧的那一份，选项点下去不执行（LP 2026-10-25「更多菜单能打开还是无法点击」）。
//  换成 UIKit 的按钮菜单，菜单和动作由 UIKit 自己持有，视图怎么重建都不受影响。
//

import SwiftUI
import UIKit

/// 一颗「点了弹系统菜单」的按钮。样式由外面给，菜单内容由 `items` 给。
struct SystemMenuButton: UIViewRepresentable {
    struct Item {
        /// 菜单项的标题，也是重建菜单时比对用的凭据。
        var title: String
        var symbol: String
        /// 图标是两颗符号叠出来的时候给这张合成图（比如弹幕设置：
        /// `captions.bubble` 打底 + 右下角小齿轮）。给了就用它，`symbol` 只当凭据。
        var symbolImage: UIImage? = nil
        var isDestructive: Bool = false
        /// 二级菜单那一行右边的小字，写当前值。
        var subtitle: String? = nil
        /// 有二级菜单就展开成子菜单，`action` 不生效。
        var submenu: [Item]? = nil
        var action: () -> Void
    }

    var items: [Item]
    /// 按钮上画什么：给了 `title` 就写字，否则画 `symbol` 那个符号。
    var title: String?
    var symbol: String
    var accessibilityLabel: String
    /// 按钮和字用什么颜色：播放器里是白的，选集那块要跟页面一样是正文色。
    var tint: Color = .white
    /// 标题右边要不要带一个小三角，表示「点开有菜单」。
    var showsChevron: Bool = false
    /// 菜单被点开时回调：控制栏要靠它知道「先别收」。
    var onOpen: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        // 尺寸由外面的 `.frame` 给：在 updateUIView 里写死 frame 会和 SwiftUI 的布局打架，
        // 结果是屏幕上一个位置、真正的按钮在另一个位置（点了没反应、居中变歪都从这里来）。
        //
        // 水平方向必须「抱紧内容」：hugging 低了，HStack 里富余的空间会被按钮吃掉
        // （Spacer 反而挤没），按钮铺满整行、标题在正中被居中 —— 选集里那颗线路按钮
        // 就是这样从左边跑到屏幕中间的（LP 3389/3397）。纵向不管：外面都给了高。
        button.setContentHuggingPriority(.required, for: .horizontal)
        // 压缩抵抗留低：实在放不下时允许被挤，不至于把旁边的按钮顶出屏。
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 图标钮（收藏 / 更多）不能再被挤：横竖屏切换时 Spacer 一旦把它压到 0 宽，
        // SwiftUI 给的 frame 和 UIKit 自己算的位置就会对不上，按钮被留在屏幕左上角。
        if title == nil {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        button.tintColor = Self.uiColor(tint)
        button.addAction(
            UIAction { [coordinator = context.coordinator] _ in
                coordinator.onOpen()
            },
            for: .menuActionTriggered
        )
        apply(to: button, context: context)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        apply(to: button, context: context)
        // 旋转后 UIKit 可能还拿着旧 bounds：内容（符号）停在旧位置。
        // frame 仍由 SwiftUI 给，这里只催它按新 frame 重排。
        button.setNeedsLayout()
    }

    /// 尺寸交给 SwiftUI 定。不返回 nil（默认会去问 UIKit 的 intrinsicContentSize，
    /// 旋转后那份缓存可能还是旧的，按钮就被留在屏幕左上角）。
    /// 图标钮至少 44×44（点击区），带标题的按内容宽，且都不超过外面给的提案。
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UIButton,
        context: Context
    ) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        // 图标钮给到 44×44（点击区）；带标题的保持原来的内容尺寸，不改大小。
        let minimum: CGFloat = title == nil ? 44 : 0
        let hasWidth = intrinsic.width.isFinite && intrinsic.width > 0
        let hasHeight = intrinsic.height.isFinite && intrinsic.height > 0
        // 带标题的按钮如果量不出内容尺寸，交给 SwiftUI 默认测量，别把它压成 0。
        guard hasWidth || minimum > 0, hasHeight || minimum > 0 else { return nil }
        var width = hasWidth ? max(minimum, intrinsic.width) : minimum
        var height = hasHeight ? max(minimum, intrinsic.height) : minimum
        if let proposed = proposal.width, proposed.isFinite, proposed > 0 {
            width = min(width, proposed)
        }
        if let proposed = proposal.height, proposed.isFinite, proposed > 0 {
            height = min(height, proposed)
        }
        return CGSize(width: width, height: height)
    }

    private func apply(to button: UIButton, context: Context) {
        let coordinator = context.coordinator
        // 动作从协调器里现取，闭包里不抓 SwiftUI 那一层，视图重建也不会变成旧闭包。
        coordinator.items = items
        coordinator.onOpen = onOpen

        #if DEBUG
        Self.auditSymbols(buttonSymbol: title == nil ? symbol : nil, items: items)
        #endif

        // 内容没变就别再重置 configuration / image：播放中视图每 250ms 重建一次，
        // 反复重置会让 UIKit 不停作废 intrinsicContentSize，旋转时更容易和 SwiftUI 的
        // 布局对不上（按钮被留在左上角就是这么来的）。
        let tintColor = Self.uiColor(tint)
        // 图标钮（收藏 / 更多）只在内容真的变了才重置；带标题的照旧每次重设，
        // 免得深浅色切换时 configuration 里的标题颜色不跟着换。
        let isIcon = title == nil
        let appearanceChanged = isIcon
            ? (!coordinator.hasAppliedAppearance
                || coordinator.appliedSymbol != symbol
                || button.tintColor != tintColor)
            : true
        if appearanceChanged {
            if let title {
                // 用 configuration 才能「字 + 右边小三角」，setTitle/setImage 只能二选一。
                var config = UIButton.Configuration.plain()
                config.title = title
                config.baseForegroundColor = tintColor
                config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
                if showsChevron {
                    config.image = UIImage(
                        systemName: "chevron.up.chevron.down",
                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
                    )
                    config.imagePlacement = .trailing
                    config.imagePadding = 4
                }
                config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                    var out = incoming
                    out.font = .systemFont(ofSize: 15, weight: .regular)
                    return out
                }
                button.configuration = config
                button.setTitleColor(tintColor, for: .normal)
            } else {
                button.configuration = nil
                button.setTitle(nil, for: .normal)
                button.setImage(
                    UIImage(
                        systemName: symbol,
                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
                    ),
                    for: .normal
                )
            }
            coordinator.appliedSymbol = symbol
            coordinator.hasAppliedAppearance = true
        }
        button.tintColor = tintColor
        button.accessibilityLabel = accessibilityLabel
        // 旋转后 UIKit 重排内容时始终以按钮中心为锚，别让符号贴着左上角画。
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center

        // 只在内容真的变了才重建菜单：菜单开着的时候重建，会把手上那一份换成没人认领的空壳。
        // 二级菜单里的勾（symbol）和右侧小字也算进凭据：只比标题的话，
        // 换个档位标题没变、勾该挪位置，菜单却不重建，勾就一直停在原来那项
        // （LP 2026-10-27「点了不会切换，还一直在默认那里✓」）。
        let signature = items.map { item in
            let children = item.submenu?.map { "\($0.title)~\($0.symbol)~\($0.subtitle ?? "")" }
                .joined(separator: ",") ?? ""
            let composite = item.symbolImage == nil ? "" : "合成图"
            return "\(item.title)|\(item.symbol)|\(composite)|\(item.isDestructive)|\(item.subtitle ?? "")|\(children)"
        }.joined(separator: "#")
        guard signature != coordinator.signature else { return }
        coordinator.signature = signature

        button.menu = UIMenu(children: coordinator.makeActions(count: items.count))
    }

    #if DEBUG
    /// 图标名写错时系统不报错，只在屏上留一片空白——这里替它喊一声。
    /// 每个名字只喊一次，避免每次视图重建都刷日志。
    private nonisolated(unsafe) static var reportedSymbols: Set<String> = []

    private static func auditSymbols(buttonSymbol: String?, items: [Item]) {
        var names: [String] = []
        if let buttonSymbol, !buttonSymbol.isEmpty { names.append(buttonSymbol) }
        for item in items {
            if !item.symbol.isEmpty { names.append(item.symbol) }
            if let submenu = item.submenu { names.append(contentsOf: submenu.map(\.symbol)) }
        }
        for name in names where !name.isEmpty && !reportedSymbols.contains(name) {
            guard UIImage(systemName: name) == nil else { continue }
            reportedSymbols.insert(name)
            KazumiLogBuffer.network("图标名不存在：\(name)")
        }
    }
    #endif

    /// 浅底深字、深底浅字：必须用系统的动态色。
    /// `UIColor(Color.primary)` 会把动态色按当前深浅算成一个死颜色，
    /// 换主题就还是原来那个（菜单「变黑」就是这里来的，Colo 3344）。
    private static func uiColor(_ color: Color) -> UIColor {
        switch color {
        case .primary: return .label
        case .secondary: return .secondaryLabel
        case .white: return .white
        case .black: return .black
        default: return UIColor(color)
        }
    }

    /// 只在主线程上用；`UIAction` 的闭包签名要求 Sendable，这里显式标注。
    final class Coordinator: @unchecked Sendable {
        var items: [Item] = []
        var flat: [Item] = []
        var onOpen: () -> Void = {}
        var signature: String = ""
        /// 按钮外观（标题 / 符号 / 小三角）上次应用的值：没变就不重置 UIKit 内容。
        var hasAppliedAppearance = false
        var appliedSymbol: String?

        func makeActions(count: Int) -> [UIMenuElement] {
            // 一级和二级的点法做成一件事：所有能点的项按顺序进 `flat`，
            // 回调里只用下标取，闭包形状跟原来一样（不把动作闭包塞进菜单里）。
            var flat: [Item] = []
            func leaf(_ item: Item) -> UIAction {
                flat.append(item)
                let index = flat.count - 1
                return UIAction(
                    title: item.title,
                    image: item.symbolImage ?? (item.symbol.isEmpty ? nil : UIImage(systemName: item.symbol)),
                    attributes: item.isDestructive ? .destructive : []
                ) { [weak self] _ in
                    self?.flat[safe: index]?.action()
                }
            }
            let elements: [UIMenuElement] = (0..<count).map { index in
                let item = items[index]
                guard let submenu = item.submenu else { return leaf(item) }
                return UIMenu(
                    title: item.title,
                    subtitle: item.subtitle ?? "",
                    image: item.symbolImage ?? (item.symbol.isEmpty ? nil : UIImage(systemName: item.symbol)),
                    children: submenu.map(leaf)
                )
            }
            self.flat = flat
            return elements
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
