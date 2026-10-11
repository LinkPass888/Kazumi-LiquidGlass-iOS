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

  @override
  Widget build(BuildContext context) {
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
        style: _panelStyle(context).merge(style),
        menuChildren: menuChildren,
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
    return MenuItemButton(
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
    );
  }
}
