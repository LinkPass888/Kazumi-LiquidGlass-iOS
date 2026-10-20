import 'package:flutter/material.dart';

import 'package:kazumi/bean/liquid_glass/glass_material.dart';
import 'package:kazumi/bean/liquid_glass/liquid_glass.dart';

/// 一块玻璃对话框，替代 `AlertDialog`。
///
/// 参数和 [AlertDialog] 一一对应（排布、按钮、滚动行为全部沿用 Material 的
/// 实现，用户不需要重新适应），只是把表面从「不透明的 Material 面」换成了
/// 玻璃：背后是页面内容，隔着弹窗能看见它被折射，而不是一张和页面无关的灰板。
///
/// 做法是在 [AlertDialog] 底下垫一层 [KazumiLiquidGlass]：这样布局、无障碍、
/// 键盘避让、溢出按钮这些细节都不用重写，只有表面变了。
///
/// 玻璃在 Flutter 图层树里，所以对话框里再放玻璃按钮、玻璃菜单也不会出现
/// 「整块遮挡」—— 那是平台视图独有的问题。
///
/// ```dart
/// KazumiDialog.show(
///   builder: (_) => KazumiAlert(
///     title: const Text('删除这一项？'),
///     content: const Text('删除后无法恢复。'),
///     actions: [
///       TextButton(onPressed: KazumiDialog.dismiss, child: const Text('取消')),
///       TextButton(onPressed: ..., child: const Text('删除')),
///     ],
///   ),
/// );
/// ```
class KazumiAlert extends StatelessWidget {
  const KazumiAlert({
    super.key,
    this.icon,
    this.iconPadding,
    this.iconColor,
    this.title,
    this.titlePadding,
    this.titleTextStyle,
    this.content,
    this.contentPadding,
    this.contentTextStyle,
    this.actions,
    this.actionsPadding,
    this.actionsOverflowDirection,
    this.actionsOverflowButtonSpacing,
    this.actionsAlignment,
    this.backgroundColor,
    this.elevation,
    this.semanticLabel,
    this.insetPadding =
        const EdgeInsets.symmetric(horizontal: 40.0, vertical: 24.0),
    this.clipBehavior = Clip.none,
    this.shape,
    this.alignment,
    this.scrollable = false,
    this.constraints,
  });

  final Widget? icon;
  final EdgeInsetsGeometry? iconPadding;
  final Color? iconColor;
  final Widget? title;
  final EdgeInsetsGeometry? titlePadding;
  final TextStyle? titleTextStyle;
  final Widget? content;
  final EdgeInsetsGeometry? contentPadding;
  final TextStyle? contentTextStyle;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? actionsPadding;
  final VerticalDirection? actionsOverflowDirection;
  final double? actionsOverflowButtonSpacing;
  final MainAxisAlignment? actionsAlignment;

  /// 玻璃的染色。传进来的应该是一个 surface 色；玻璃只取它的色相，
  /// 并压到很低的透明度 —— 苹果的玻璃不做大面积着色。
  final Color? backgroundColor;

  /// 保留但不再生效：玻璃的立体感来自折射与高光，不来自投影。
  final double? elevation;
  final String? semanticLabel;
  final EdgeInsetsGeometry insetPadding;
  final Clip clipBehavior;
  final ShapeBorder? shape;
  final AlignmentGeometry? alignment;
  final bool scrollable;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    final double radius = _radiusOf(context, shape);
    final Color? tint = backgroundColor?.withValues(alpha: 0.22);

    return Padding(
      // AlertDialog 自己会让出 insetPadding；玻璃要正好贴住对话框本身，
      // 所以把同一份边距在外面让一次，内层归零。遮罩挂在外面，跟随同一份
      // 边距缩放（和框架的 inset 动画一致）。
      padding: insetPadding,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: KazumiLiquidGlass(
                kind: GlassSurfaceKind.dialog,
                tint: tint,
                shape: LiquidGlassShape.roundedRectangle(radius),
              ),
            ),
          ),
          KazumiAlert(
            icon: icon,
            iconPadding: iconPadding,
            iconColor: iconColor,
            title: title,
            titlePadding: titlePadding,
            titleTextStyle: titleTextStyle,
            content: content,
            contentPadding: contentPadding,
            contentTextStyle: contentTextStyle,
            actions: actions,
            actionsPadding: actionsPadding,
            actionsOverflowDirection: actionsOverflowDirection,
            actionsOverflowButtonSpacing: actionsOverflowButtonSpacing,
            actionsAlignment: actionsAlignment,
            // 表面完全交给底下的玻璃。
            backgroundColor: Colors.transparent,
            elevation: 0,
            semanticLabel: semanticLabel,
            insetPadding: EdgeInsets.zero,
            clipBehavior: clipBehavior,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
            ),
            alignment: alignment,
            scrollable: scrollable,
            constraints: constraints,
          ),
        ],
      ),
    );
  }

  static double _radiusOf(BuildContext context, ShapeBorder? shape) {
    if (shape is RoundedRectangleBorder) {
      final BorderRadius radius = shape.borderRadius.resolve(
        Directionality.of(context),
      );
      final double value = radius.topLeft.x;
      if (value.isFinite && value > 0) return value;
    }
    return _globalRadius(context);
  }
}

/// 对话框圆角（和卡片、菜单同一套全局半径）。
double _globalRadius(BuildContext context) {
  // 这里不直接依赖 KazumiGlass，避免 dialog 层与 glass 层互相 import 成环。
  final double shortest = MediaQuery.sizeOf(context).shortestSide;
  if (!shortest.isFinite || shortest <= 0) return 28;
  return (shortest * 55.0 / 393.0).clamp(24.0, 32.0);
}
