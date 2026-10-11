import 'package:flutter/widgets.dart';
import 'package:real_liquid_glass/real_liquid_glass.dart';

/// 路由转场期间隐藏所有原生玻璃视图。
///
/// 平台视图（UiKitView）是叠加在 Flutter 表面之上的原生层，不参与 Flutter 的
/// 路由转场 / Hero 飞行动画 —— 转场期间它会以「截屏残留」盖住下层内容
/// （典型：番剧详情页 Hero 飞行的封面被玻璃残留遮挡）。这个 Observer 在
/// 路由 push / pop 开始时把玻璃隐藏，转场动画结束后再恢复。
class GlassRouteObserver extends NavigatorObserver {
  int _pendingTransitions = 0;

  /// 当前是否有未结束的路由转场。
  bool get isTransitioning => _pendingTransitions > 0;

  void _beginTransition() {
    _pendingTransitions++;
    LiquidGlassVisibility.setHidden(true);
  }

  void _endTransition() {
    if (_pendingTransitions == 0) return;
    _pendingTransitions--;
    if (_pendingTransitions == 0) {
      LiquidGlassVisibility.setHidden(false);
    }
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    _beginTransition();
    // 等待新路由的转场动画完成（约 300ms 后），再恢复玻璃。
    _scheduleEnd();
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    _beginTransition();
    _scheduleEnd();
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    super.didRemove(route, previousRoute);
    _beginTransition();
    _scheduleEnd();
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _beginTransition();
    _scheduleEnd();
  }

  void _scheduleEnd() {
    // 路由转场动画的典型时长。用 Timer 而不是监听动画完成，避免平台视图
    // 在动画中残留；结束后恢复玻璃。
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      if (isTransitioning) _endTransition();
    });
  }
}

/// 全局单例：路由转场期间隐藏原生玻璃视图。
final glassRouteObserver = GlassRouteObserver();
