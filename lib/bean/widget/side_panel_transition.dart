import 'package:flutter/material.dart';

import 'package:kazumi/bean/liquid_glass/kazumi_motion.dart';

class SidePanelTransition extends StatelessWidget {
  const SidePanelTransition({
    super.key,
    required this.animation,
    required this.child,
  });

  /// 侧边面板滑入：短、快、收尾缓，和玻璃面板的浮起一致。
  static const duration = Duration(milliseconds: 180);

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(animation.drive(CurveTween(curve: KazumiMotion.springDecel))),
        child: child,
      );
}
