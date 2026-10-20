// Adapted from m3e_core 1.1.2's M3EBottomSheet (MIT).
// Copyright (c) 2026 Mudit Purohit. See licenses/m3e_core.txt.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kazumi/bean/liquid_glass/glass_material.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_motion.dart';
import 'package:kazumi/bean/liquid_glass/liquid_glass.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';

BoxConstraints _adaptiveBottomSheetConstraints(
  BuildContext context, {
  required double maxHeightFactor,
  required double compactLandscapeMaxHeightFactor,
}) {
  final size = MediaQuery.sizeOf(context);
  final isLandscape = size.width > size.height;
  final useFullWidth = !isLandscape && size.width < 600;
  final maxWidth =
      useFullWidth ? size.width : math.min(size.width * 0.72, 640.0);
  final useExpandedLandscapeHeight = isLandscape && size.height < 600;
  final maxHeight = size.height *
      (useExpandedLandscapeHeight
          ? compactLandscapeMaxHeightFactor
          : maxHeightFactor);

  return BoxConstraints(
    maxWidth: maxWidth,
    maxHeight: maxHeight,
  );
}

// 路由自身的位移交给框架（它负责遮罩与手势）；这里只给一个不带曲线的时长，
// 面板的「弹起」由下面的弹簧负责。
const AnimationStyle _sheetRouteAnimationStyle = AnimationStyle(
  duration: Duration(milliseconds: 320),
  reverseDuration: Duration(milliseconds: 240),
);

Future<T?> showAdaptiveBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxHeightFactor = 0.75,
  double compactLandscapeMaxHeightFactor = 0.9,
  bool useRootNavigator = false,
  RouteSettings? routeSettings,
}) {
  return showModalBottomSheet<T>(
    context: context,
    // 玻璃自己就是面板，框架那层不透明的 Material 必须让开。
    backgroundColor: Colors.transparent,
    elevation: 0,
    shape: const RoundedRectangleBorder(),
    clipBehavior: Clip.none,
    // 玻璃面板浮在页面之上，遮罩太重会把背后的内容压成死黑，折射也就没有
    // 东西可折了。苹果的弹层遮罩本来就比 Material 淡。
    barrierColor: Colors.black.withValues(alpha: 0.28),
    constraints: _adaptiveBottomSheetConstraints(
      context,
      maxHeightFactor: maxHeightFactor,
      compactLandscapeMaxHeightFactor: compactLandscapeMaxHeightFactor,
    ),
    isScrollControlled: true,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    showDragHandle: false,
    useSafeArea: true,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : _sheetRouteAnimationStyle,
    builder: (context) => _GlassSheetSurface(
      child: Builder(builder: builder),
    ),
  );
}

/// 底部弹层的外壳：一块贴着屏幕底边的玻璃。
///
/// 关键变化：以前这里是一层不透明的 `Material(color: surface)`，弹层和页面
/// 是两张互不相干的白板。现在面板就是玻璃本身 —— 页面内容透过它折射，弹层
/// 和页面在视觉上是连续的（和系统「音乐」「地图」的底部卡片一致）。
///
/// 因为玻璃在 Flutter 图层树里，它可以被裁剪、可以参与转场，也不会像平台视图
/// 那样在弹层里整块遮挡。
class _GlassSheetSurface extends StatefulWidget {
  const _GlassSheetSurface({required this.child});

  final Widget child;

  @override
  State<_GlassSheetSurface> createState() => _GlassSheetSurfaceState();
}

class _GlassSheetSurfaceState extends State<_GlassSheetSurface>
    with SingleTickerProviderStateMixin {
  late final _entrance = AnimationController.unbounded(vsync: this);
  bool _started = false;

  /// 玻璃比内容多伸出的高度。
  ///
  /// 入场弹簧会略微过冲（面板上浮几像素），面板底边一旦离开屏幕底边就会露出
  /// 一条缝。让玻璃多伸出一段到屏幕外，过冲时补上的仍是玻璃，而不是一条底色。
  /// 40 足够覆盖 0.8 阻尼弹簧约 1.5% 的过冲（位移幅度 200 时约 3 像素）。
  static const double _bottomExtension = 40;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _started = true;
      _entrance.value = 1;
    } else if (!_started) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
        KazumiMotion.springTo(_entrance, 1, description: KazumiMotion.sheet);
      });
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // 全局统一圆角：弹层顶边圆角跟整机走，底边贴屏幕，不需要圆角。
    final sheetShape =
        LiquidGlassShape.sheet(KazumiGlass.radiusOf(context));

    final content = Theme(
      data: theme.copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: Colors.transparent,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              label:
                  MaterialLocalizations.of(context).modalBarrierDismissLabel,
              onDismiss: () => Navigator.of(context).maybePop(),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: Container(
                    width: 36,
                    height: 5,
                    decoration: BoxDecoration(
                      color: colors.onSurfaceVariant.withValues(alpha: 0.38),
                      borderRadius: BorderRadius.circular(2.5),
                    ),
                  ),
                ),
              ),
            ),
            Flexible(child: widget.child),
          ],
        ),
      ),
    );

    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.topCenter,
      children: [
        // 玻璃层：从面板顶部一直铺到屏幕外，内容画在它上面。
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          bottom: -_bottomExtension,
          child: KazumiLiquidGlass(
            kind: GlassSurfaceKind.sheet,
            material: GlassMaterial.regular,
            shape: sheetShape,
          ),
        ),
        AnimatedBuilder(
          animation: _entrance,
          child: content,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, (1 - _entrance.value) * 200),
            child: Opacity(
              opacity: _entrance.value.clamp(0.0, 1.0),
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}
