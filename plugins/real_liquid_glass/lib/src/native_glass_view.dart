import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import 'glass_style.dart';

/// 全局玻璃可见性控制（按路由作用域）。
///
/// 平台视图（UiKitView/AppKitView）是叠加在 Flutter 表面之上的原生层，不参与
/// Flutter 的路由转场 / Hero 飞行动画 —— 转场期间**正在动画的那一页**的玻璃会
/// 以「截屏残留」留在原位，盖住滑动的 Flutter 内容（如详情页 Hero 飞行的封面、
/// push 滑入时详情页的顶栏按钮先就位）。所以这里按**路由**精确隐藏：只隐藏
/// 正在转场的那一页的玻璃，其它页面（如首页底部标签栏）保持可见，不会在
/// 动画结束时突兀闪现。
class LiquidGlassVisibility {
  LiquidGlassVisibility._();

  static final ValueNotifier<Set<Object>> _hiddenRoutes =
      ValueNotifier<Set<Object>>(<Object>{});

  /// 指定路由下的玻璃当前是否处于隐藏状态。
  static bool isHiddenFor(Object? route) =>
      route != null && _hiddenRoutes.value.contains(route);

  /// 隐藏/恢复指定路由下的所有原生玻璃视图。
  ///
  /// 只有正在做路由转场的那一页（push 进入 / pop 退出 / 侧滑拖走）的玻璃
  /// 才需要隐藏；其它页面的玻璃保持显示，避免动画结束时突兀闪现。
  static void setRouteHidden(Object route, bool hidden) {
    final Set<Object> next = Set<Object>.of(_hiddenRoutes.value);
    if (hidden) {
      next.add(route);
    } else {
      next.remove(route);
    }
    if (setEquals(next, _hiddenRoutes.value)) return;
    _hiddenRoutes.value = next;
  }

  /// 供 [NativeGlassView] 内部订阅。
  static ValueListenable<Set<Object>> get hiddenRoutesListenable =>
      _hiddenRoutes;
}

/// Embeds the native effect view that carries the glass material.
///
/// On iOS 26+ / macOS 26+ this is real UIGlassEffect / NSGlassEffectView
/// Liquid Glass. The effect samples the content rendered beneath it —
/// Flutter widgets included.
class NativeGlassView extends StatefulWidget {
  const NativeGlassView({
    super.key,
    required this.style,
    required this.shape,
    required this.interactive,
    this.tint,
    this.onTap,
  });

  final LiquidGlassStyle style;
  final LiquidGlassShape shape;
  final bool interactive;
  final Color? tint;
  final VoidCallback? onTap;

  @override
  State<NativeGlassView> createState() => _NativeGlassViewState();
}

class _NativeGlassViewState extends State<NativeGlassView> {
  MethodChannel? _viewChannel;

  /// 这块玻璃所属的路由（由 [ModalRoute.of] 在依赖变化时解析）。
  Object? _route;

  bool _hidden = false;

  Map<String, Object?> get _params => {
        'style': widget.style.name,
        'tint': widget.tint?.toARGB32(),
        'interactive': widget.interactive,
        'capsule': widget.shape.capsule,
        'cornerRadius': widget.shape.cornerRadius,
        'dark': CupertinoTheme.of(context).brightness == Brightness.dark,
      };

  @override
  void initState() {
    super.initState();
    LiquidGlassVisibility.hiddenRoutesListenable.addListener(_onVisibilityChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 玻璃所属的路由：push 详情页时详情页玻璃解析到详情页 route，首页底部
    // 标签栏解析到首页 route —— 转场只隐藏正在转场的那一页。
    final Object? route = ModalRoute.of(context);
    if (route != _route) {
      _route = route;
      _hidden = LiquidGlassVisibility.isHiddenFor(_route);
    }
    _viewChannel?.invokeMethod<void>('update', _params);
  }

  void _onVisibilityChanged() {
    final bool hidden = LiquidGlassVisibility.isHiddenFor(_route);
    if (_hidden == hidden) return;
    // 必须 setState：Offstage 依赖 _hidden 重建，否则 UI 停在旧状态，
    // 要等滚动等操作触发 rebuild 才「回来」。
    setState(() {
      _hidden = hidden;
    });
    _viewChannel?.invokeMethod<void>('setHidden', {'hidden': hidden});
  }

  @override
  void didUpdateWidget(NativeGlassView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.style != oldWidget.style ||
        widget.shape != oldWidget.shape ||
        widget.interactive != oldWidget.interactive ||
        widget.tint != oldWidget.tint) {
      _viewChannel?.invokeMethod<void>('update', _params);
    }
  }



  @override
  Widget build(BuildContext context) {
    final hitTestBehavior = widget.interactive
        ? PlatformViewHitTestBehavior.opaque
        : PlatformViewHitTestBehavior.transparent;
    // Kazumi 本地版：只保留 iOS/macOS（Apple 全平台）。
    final Widget view = defaultTargetPlatform == TargetPlatform.macOS
        ? AppKitView(
            viewType: 'real_liquid_glass/glass_view',
            creationParams: _params,
            creationParamsCodec: const StandardMessageCodec(),
            hitTestBehavior: hitTestBehavior,
            onPlatformViewCreated: _onViewCreated,
          )
        : UiKitView(
            viewType: 'real_liquid_glass/glass_view',
            creationParams: _params,
            creationParamsCodec: const StandardMessageCodec(),
            hitTestBehavior: hitTestBehavior,
            onPlatformViewCreated: _onViewCreated,
          );
    // 转场期间平台视图不跟随 Flutter 动画，直接隐藏（Offstage）避免截屏残留盖住内容。
    return IgnorePointer(
      ignoring: !widget.interactive,
      child: Offstage(offstage: _hidden, child: view),
    );
  }

  void _onViewCreated(int id) {
    final channel = MethodChannel('real_liquid_glass/glass_view_$id');
    _viewChannel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'tap') widget.onTap?.call();
    });
  }

  @override
  void dispose() {
    LiquidGlassVisibility.hiddenRoutesListenable.removeListener(_onVisibilityChanged);
    _viewChannel?.setMethodCallHandler(null);
    super.dispose();
  }
}
