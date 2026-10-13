import 'package:flutter/material.dart';

import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';

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
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(KazumiGlass.radiusOf(context)),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: padding, child: child),
      );
}
