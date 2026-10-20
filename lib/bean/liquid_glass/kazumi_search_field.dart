import 'package:flutter/material.dart';

import 'package:kazumi/bean/liquid_glass/glass_material.dart';
import 'package:kazumi/bean/liquid_glass/liquid_glass.dart';

/// 玻璃搜索框，替代 `SearchBar`。
///
/// 参数按 [SearchBar] 的常用集合对齐（控制器、焦点、提示语、前后图标、
/// 提交与变更回调），这样调用点换过来只需要改类名。表面用玻璃：搜索框下面
/// 往往是封面墙或列表，隔着它被折射比一块实色面板更像系统控件。
///
/// 形状默认是胶囊 —— iOS 的搜索框（UISearchBar）就是胶囊，而且它和
/// 顶栏里的圆形玻璃按钮是同一套弧线语言。
class KazumiSearchField extends StatelessWidget {
  const KazumiSearchField({
    super.key,
    this.controller,
    this.focusNode,
    this.hintText,
    this.textInputAction = TextInputAction.search,
    this.leading,
    this.trailing = const <Widget>[],
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
    this.constraints = const BoxConstraints(minHeight: 56),
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hintText;
  final TextInputAction textInputAction;

  /// 前置图标（一般是搜索镜）。给的是一个按钮时，点按区就是它自己。
  final Widget? leading;

  /// 后置图标（清空、以图搜番这类），按顺序排在右边。
  final List<Widget> trailing;

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;

  /// 玻璃内部的留白。和 [SearchBar] 默认值一致。
  final EdgeInsetsGeometry padding;

  /// 搜索框的最小尺寸。和 [SearchBar] 一样默认高 56。
  final BoxConstraints constraints;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return ConstrainedBox(
      constraints: constraints,
      child: KazumiLiquidGlass(
        kind: GlassSurfaceKind.groupedSurface,
        shape: LiquidGlassShape.capsule(),
        padding: padding,
        child: Row(
          children: [
            ?leading,
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                textInputAction: textInputAction,
                onChanged: onChanged,
                onSubmitted: onSubmitted,
                onTap: onTap,
                // 输入框自己不能有底色：表面由玻璃给。
                style: theme.textTheme.titleMedium,
                cursorColor: colors.primary,
                decoration: InputDecoration(
                  hintText: hintText,
                  hintStyle: theme.textTheme.titleMedium?.copyWith(
                    // 提示语和系统搜索框一样是次要色，不抢已输入的内容。
                    color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
                ),
              ),
            ),
            ...trailing,
          ],
        ),
      ),
    );
  }
}

/// 玻璃搜索框里的一颗图标按钮。
///
/// 不单独铺玻璃（玻璃叠玻璃既不好看也点不动），只保留 [IconButton] 的
/// 点按反馈与语义；颜色跟随次要色，和控制条里的图标一致。
class KazumiSearchIcon extends StatelessWidget {
  const KazumiSearchIcon({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: icon,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      // 48 的点按区在 56 高的胶囊里正好居中，不会把玻璃撑高。
      visualDensity: VisualDensity.standard,
    );
  }
}
