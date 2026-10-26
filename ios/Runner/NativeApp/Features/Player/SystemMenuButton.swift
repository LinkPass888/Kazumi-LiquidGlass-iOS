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
    }

    private func apply(to button: UIButton, context: Context) {
        let coordinator = context.coordinator
        // 动作从协调器里现取，闭包里不抓 SwiftUI 那一层，视图重建也不会变成旧闭包。
        coordinator.items = items
        coordinator.onOpen = onOpen

        #if DEBUG
        Self.auditSymbols(buttonSymbol: title == nil ? symbol : nil, items: items)
        #endif

        if let title {
            // 用 configuration 才能「字 + 右边小三角」，setTitle/setImage 只能二选一。
            var config = UIButton.Configuration.plain()
            config.title = title
            config.baseForegroundColor = Self.uiColor(tint)
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
            button.setTitleColor(Self.uiColor(tint), for: .normal)
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
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityLabel = accessibilityLabel

        // 只在内容真的变了才重建菜单：菜单开着的时候重建，会把手上那一份换成没人认领的空壳。
        let signature = items.map { item in
            "\(item.title)|\(item.symbol)|\(item.isDestructive)|\(item.submenu?.map(\.title).joined(separator: ",") ?? "")"
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

        func makeActions(count: Int) -> [UIMenuElement] {
            // 一级和二级的点法做成一件事：所有能点的项按顺序进 `flat`，
            // 回调里只用下标取，闭包形状跟原来一样（不把动作闭包塞进菜单里）。
            var flat: [Item] = []
            func leaf(_ item: Item) -> UIAction {
                flat.append(item)
                let index = flat.count - 1
                return UIAction(
                    title: item.title,
                    image: item.symbol.isEmpty ? nil : UIImage(systemName: item.symbol),
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
                    image: item.symbol.isEmpty ? nil : UIImage(systemName: item.symbol),
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
