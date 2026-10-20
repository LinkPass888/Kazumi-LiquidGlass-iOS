import 'package:flutter/material.dart';

import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_motion.dart';
import 'package:kazumi/bean/liquid_glass/liquid_glass.dart';

/// 让 [child] 在「有内容从底下穿过」时自动铺一层玻璃。
///
/// 用在 [SliverPersistentHeaderDelegate] 里：`overlapsContent` 正是滚动位置
/// 告诉我们的那件事，不必自己再算一遍阈值。停在顶部时它就是页面的一部分，
/// 一旦有卡片从底下滑过，玻璃立刻浮出来 —— 和 iOS 的 pinned section header
/// 一样，边界由玻璃的高光交代，而不是画一条硬分割线。
class KazumiOverlapGlass extends StatelessWidget {
  const KazumiOverlapGlass({
    super.key,
    required this.overlapsContent,
    required this.child,
    this.backgroundColor,
    this.shape = const LiquidGlassShape.roundedRectangle(0),
  });

  final bool overlapsContent;
  final Widget child;

  /// 玻璃出现之前垫在底下的底色；为 null 时不垫（由页面自己负责）。
  final Color? backgroundColor;

  final LiquidGlassShape shape;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (backgroundColor != null)
          Positioned.fill(child: ColoredBox(color: backgroundColor!)),
        Positioned.fill(
          child: IgnorePointer(
            // 淡入交给玻璃自己（[KazumiLiquidGlass.fade]）：外面套 Opacity 会
            // 插一层 saveLayer，BackdropFilter 就只能采到那一层里的空背景，
            // 玻璃会变成一块灰。
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: overlapsContent ? 1 : 0),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              curve: KazumiMotion.appear,
              builder: (context, value, _) => KazumiGlass.glassSurface(
                shape: shape,
                fade: value,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
