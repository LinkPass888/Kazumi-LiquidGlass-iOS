import 'package:flutter/material.dart';

import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_motion.dart';
import 'package:kazumi/bean/widget/tonal_card.dart';

// 圆角: 这两个常量保留给拿不到 context 的调用方做估算；
// 实际绘制一律走 KazumiGlass.radiusOf（全局统一圆角）。
const double splitListOuterRadius = tonalCardRadius;
const double splitListInnerRadius = 4;
const double splitListRowGap = 4;

const Duration splitListMotionDuration = Duration(milliseconds: 250);
const Curve splitListMotionCurve = KazumiMotion.springDecel;

class SplitListRow extends StatefulWidget {
  const SplitListRow({
    super.key,
    required this.child,
    this.topRadius = splitListInnerRadius,
    this.bottomRadius = splitListInnerRadius,
    this.pressedRadius = splitListOuterRadius,
    this.onTap,
    this.transparent = false,
  });

  final Widget child;

  final double topRadius;
  final double bottomRadius;
  final double pressedRadius;
  final VoidCallback? onTap;

  /// 不画自己的底色（整组已经铺了一张面，行只在高亮时提亮）。
  final bool transparent;

  /// Forward a child InkWell's onHighlightChanged here.
  static ValueChanged<bool>? pressReporterOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_SplitRowScope>()
        ?.onPressChanged;
  }

  @override
  State<SplitListRow> createState() => _SplitListRowState();
}

class _SplitListRowState extends State<SplitListRow> {
  bool _pressed = false;

  void _reportPress(bool pressed) => setState(() => _pressed = pressed);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final child = widget.onTap == null
        ? widget.child
        : InkWell(
            onTap: widget.onTap,
            onHighlightChanged: _reportPress,
            child: widget.child,
          );
    // Animate color as well as shape; Material alone snaps color changes.
    // 统一圆角：按下/选中时用全局圆角，否则用行自身（联合组决定）的圆角
    final double groupRadius = KazumiGlass.radiusOf(context);
    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : splitListMotionDuration,
      curve: splitListMotionCurve,
      clipBehavior: Clip.antiAlias,
      // 整组已经是一张连续的面（[SplitListGroup]），行只在按下时提亮 ——
      // 垫自己的底色会把整面割成一条一条。
      decoration: BoxDecoration(
        color: _pressed
            ? colors.onSurface.withValues(alpha: 0.06)
            : Colors.transparent,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(
              _pressed ? groupRadius : widget.topRadius),
          bottom: Radius.circular(
              _pressed ? groupRadius : widget.bottomRadius),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTileTheme(
          data: theme.listTileTheme.copyWith(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            titleTextStyle:
                theme.textTheme.bodyLarge?.copyWith(color: colors.onSurface),
            subtitleTextStyle: theme.textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          child: _SplitRowScope(onPressChanged: _reportPress, child: child),
        ),
      ),
    );
  }
}

class _SplitRowScope extends InheritedWidget {
  const _SplitRowScope({required this.onPressChanged, required super.child});

  final ValueChanged<bool> onPressChanged;

  // The callback always targets the same state.
  @override
  bool updateShouldNotify(_SplitRowScope oldWidget) => false;
}

class SplitListGroup extends StatelessWidget {
  const SplitListGroup({
    super.key,
    required this.children,
    this.outerRadius = splitListOuterRadius,
  });

  final List<Widget> children;

  final double outerRadius;

  @override
  Widget build(BuildContext context) {
    // 全局统一圆角：组首/组尾的外圆角跟整机走。每行之间不留缝 —— 分组是
    // 一张连续的面，行与行之间靠按下的高亮和分隔线区分，而不是一块块小板
    // 拼起来（iOS 的 inset grouped 列表就是一张整面）。
    final double outer = KazumiGlass.radiusOf(context);
    final Color hairline =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.12);
    return ClipRSuperellipse(
      borderRadius: BorderRadius.circular(outer),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (int i = 0; i < children.length; i++) ...[
              if (i > 0)
                // iOS 分组列表的行间分隔：0.5 的发丝线，左右缩进让出内容边。
                // 不用 Divider：它自带的高度会把行距撑开。
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: SizedBox(
                    height: 0.5,
                    child: ColoredBox(color: hairline),
                  ),
                ),
              SplitListRow(
                topRadius: outer,
                bottomRadius: outer,
                pressedRadius: outer,
                // 组内不再画自己的底色（整组已经是一张面），只负责按下高亮。
                transparent: true,
                child: children[i],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
