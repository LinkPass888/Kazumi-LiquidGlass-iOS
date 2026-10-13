import 'package:flutter/material.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';

typedef KazumiMenuBuilder =
    Widget Function(BuildContext context, VoidCallback? toggle);

const _menuItemStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(144, 48)),
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
  alignment: AlignmentDirectional.centerStart,
  visualDensity: VisualDensity.standard,
);

/// 菜单面板的样式。
///
/// 面板由 MenuAnchor 自己画在 Overlay 里，铺不了玻璃，所以退一步用
/// [KazumiGlass.submenuStyle]：圆角和别的玻璃面板完全一致、去掉阴影和
/// surfaceTint，底色用半透明的 surface，远看和玻璃面板是一套。内边距取
/// [KazumiGlass.menuPanelPadding]，条目的高亮圆角才是同心圆（见
/// [KazumiGlass.menuItemButtonStyle]）。
MenuStyle _panelStyle(BuildContext context) => KazumiGlass.submenuStyle(context)
    .copyWith(
  padding: const WidgetStatePropertyAll(KazumiGlass.menuPanelPadding),
  surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
  shadowColor: const WidgetStatePropertyAll(Colors.transparent),
);

class KazumiMenuButton extends StatelessWidget {
  const KazumiMenuButton({
    super.key,
    required this.builder,
    required this.menuChildren,
    this.controller,
    this.enabled = true,
    this.animated = false,
    this.crossAxisUnconstrained = true,
    this.onOpen,
    this.onClose,
    this.style,
    this.alignmentOffset,
    this.glass = false,
  });

  final KazumiMenuBuilder builder;
  final List<Widget> menuChildren;
  final MenuController? controller;
  final bool enabled;

  /// Opt in only for menus that previously animated.
  final bool animated;
  final bool crossAxisUnconstrained;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;
  final MenuStyle? style;

  /// 菜单相对锚点的偏移。
  ///
  /// 负的 dy 把面板顶到按钮上方：播放器横屏时按钮贴着屏幕底部，菜单往下开
  /// 会顶出屏幕，靠这个把它顶回来（竖屏不传，保持框架默认位置）。
  final Offset? alignmentOffset;

  /// 面板用真玻璃，而不是 [KazumiGlass.submenuStyle] 那层半透明底色。
  ///
  /// 框架的菜单面板画在 Overlay 里，铺不了玻璃，所以这里把 [menuChildren] 整个
  /// 包进一块 [KazumiGlass.glassSurface]，再把框架那层底色/阴影/内边距去掉 ——
  /// 和播放器菜单（player_panel_hold.dart）是同一个做法。
  ///
  /// 默认关，而且**弹窗/底部弹层里的菜单不要开**：原生玻璃视图在弹窗里会渲染成
  /// 一大块遮挡（见 material_bottom_sheet.dart 里的说明）。只有画在普通页面上的
  /// 菜单才开它 —— 底下有内容可折射时才有意义（热门番组、追番分类这类）。
  final bool glass;

  @override
  Widget build(BuildContext context) {
    // 调用方传进来的 style 优先（例如推荐页只改 maximumSize）。注意
    // [MenuStyle.merge] 是「自己优先」：panelStyle.merge(style) 会让默认面板
    // 样式反过来盖住调用方的设置，所以必须把默认样式合到调用方后面。
    // 顺序写反过，后果就是「面板整块变透明」这类调用方的设置全部失效 ——
    // 玻璃菜单背后那层半透明 surface 就是这么冒出来的。
    final MenuStyle panelStyle = _panelStyle(context);
    MenuStyle resolvedStyle =
        style == null ? panelStyle : style!.merge(panelStyle);
    List<Widget> children = menuChildren;
    if (glass && KazumiGlass.enabled) {
      // 面板整块透明，玻璃由 children 自己带上。这里用 copyWith：不管调用方
      // 传了什么，玻璃都得是唯一的那层表面，也不能再压一层底色/阴影/内边距。
      resolvedStyle = resolvedStyle.copyWith(
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shadowColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      );
      children = [
        KazumiGlass.glassSurface(
          shape: KazumiGlass.panelShapeOf(context),
          // 上下留空 = 面板圆角 − 条目圆角，两个圆角同心
          padding: KazumiGlass.menuPanelPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: menuChildren,
          ),
        ),
      ];
    }
    return MenuButtonTheme(
      data: MenuButtonThemeData(
        // Submenu entries must use the same inset as ordinary menu items.
        // 最后一层是我们的玻璃样式，覆盖主题里的形状/底色，菜单条目统一是同心圆。
        style: _menuItemStyle
            .merge(MenuButtonTheme.of(context).style)
            .merge(KazumiGlass.menuItemButtonStyle(context)),
      ),
      child: MenuAnchor(
        controller: controller,
        consumeOutsideTap: true,
        crossAxisUnconstrained: crossAxisUnconstrained,
        animated: animated && !MediaQuery.disableAnimationsOf(context),
        alignmentOffset: alignmentOffset,
        onOpen: onOpen,
        onClose: onClose,
        // 调用方传进来的 style 优先（例如推荐页只改 maximumSize）。
        style: resolvedStyle,
        menuChildren: children,
        builder: (context, controller, _) => builder(
          context,
          enabled && menuChildren.isNotEmpty
              ? () => controller.isOpen ? controller.close() : controller.open()
              : null,
        ),
      ),
    );
  }
}

class KazumiMenuItem extends StatelessWidget {
  const KazumiMenuItem({
    super.key,
    required this.label,
    required this.onPressed,
    this.leadingIcon,
    this.selected,
    this.destructive = false,
    this.requestFocusOnHover = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget? leadingIcon;

  /// Null for actions; a bool exposes single-choice selection semantics.
  final bool? selected;
  final bool destructive;
  final bool requestFocusOnHover;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = destructive
        ? colors.error
        : selected == true
        ? colors.primary
        : null;
    final foregroundColor = color == null
        ? null
        : WidgetStateProperty.resolveWith<Color?>(
            (states) => states.contains(WidgetState.disabled) ? null : color,
          );
    return KazumiGlass.menuItemSlot(
      // 面板/玻璃给 3，条目再自己留 3，合计 6：高亮块离面板边框的距离和
      // 相邻条目高亮之间的距离一样宽，高亮圆角（面板圆角 − 6）才是同心的。
      child: MenuItemButton(
        onPressed: onPressed,
        requestFocusOnHover: requestFocusOnHover,
        style: ButtonStyle(
          foregroundColor: foregroundColor,
          iconColor: foregroundColor,
        ),
        leadingIcon: leadingIcon,
        child: Semantics(
          selected: selected,
          inMutuallyExclusiveGroup: selected == null ? null : true,
          child: Text(label, textAlign: TextAlign.start),
        ),
      ),
    );
  }
}
