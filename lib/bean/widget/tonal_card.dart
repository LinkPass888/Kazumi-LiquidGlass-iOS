import 'package:flutter/material.dart';

import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';

/// 一块「面」：分组容器、设置区块这类不需要折光的容器。
///
/// 不是玻璃 —— 列表卡片、设置分组这类成片出现、面积又大的表面如果每块都去
/// 采样背景，代价是叠加的（见推荐页卡片的说明）。它们用中性表面 + 苹果连续
/// 圆角，和玻璃面板并列时属于同一套几何语言；真正浮在内容之上、面积小的
/// 控件（顶栏、按钮、菜单、弹窗）才用玻璃。
///
/// 旧的固定圆角值，保留给拿不到 [BuildContext] 的调用方做早期布局估算用；
/// 实际绘制一律走 [KazumiGlass.radiusOf]（全局统一圆角）。
const double tonalCardRadius = 24;

class TonalCard extends StatelessWidget {
  const TonalCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final double radius = KazumiGlass.radiusOf(context);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      // 苹果连续圆角：和玻璃面板、卡片、对话框同一族曲线。
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}
