import 'package:flutter/widgets.dart';
import 'package:real_liquid_glass/real_liquid_glass.dart';

/// 路由转场期间隐藏所有原生玻璃视图。
///
/// 平台视图（UiKitView）是叠加在 Flutter 表面之上的原生层，不参与 Flutter 的
/// 路由转场 / Hero 飞行动画 —— 转场期间它会以「截屏残留」盖住下层内容
/// （典型：番剧详情页 Hero 飞行的封面被玻璃残留遮挡）。这个 Observer 在
/// **页面级路由（PageRoute）** push / pop 开始时把玻璃隐藏，转场动画结束后
/// 再恢复。
///
/// 注意：PopupRoute（对话框、菜单、bottom sheet 等）不处理 —— 它们本身
/// 就是浮在玻璃之上的临时层，打开/关闭时玻璃应当保持可见，隐藏反而会造成
/// 忽隐忽现。
class GlassRouteObserver extends NavigatorObserver {
  int _pendingTransitions = 0;

  /// 当前是否有未结束的路由转场。
  bool get isTransitioning => _pendingTransitions > 0;

  /// 是否只应该响应页面级路由。
  ///
  /// 对话框/菜单是 PopupRoute，不属于页面转场，忽略。
  bool _isPageRoute(Route<dynamic> route) => route is PageRoute;

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
    if (!_isPageRoute(route)) return;
    _beginTransition();
    _scheduleEnd(route, onDismiss: false);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    if (!_isPageRoute(route)) return;
    _beginTransition();
    _scheduleEnd(route, onDismiss: true);
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    super.didRemove(route, previousRoute);
    if (!_isPageRoute(route)) return;
    _beginTransition();
    _scheduleEnd(route, onDismiss: true);
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    final target = newRoute ?? oldRoute;
    if (target == null || !_isPageRoute(target)) return;
    _beginTransition();
    _scheduleEnd(target, onDismiss: false);
  }

  /// 监听转场动画完成，而不是用固定时长。
  ///
  /// 这样即使转场被手势打断、或者动画时长不是默认值，恢复时机也准确，
  /// 不会出现「计数失衡导致玻璃永久隐藏」。
  ///
  /// [onDismiss] 为 true 表示这是 pop/remove（动画反向到 dismissed），
  /// 为 false 表示 push/replace（动画正向到 completed）。
  void _scheduleEnd(Route<dynamic>? route, {required bool onDismiss}) {
    final transition = route is TransitionRoute<dynamic> ? route : null;
    var ended = false;
    void finish() {
      if (ended) return;
      ended = true;
      if (isTransitioning) _endTransition();
    }

    // 兜底：无论动画监听是否挂上，最迟 400ms 后一定恢复。
    // 防止 didPush 回调时 animation 尚未创建导致监听丢失、玻璃永久隐藏。
    Future<void>.delayed(const Duration(milliseconds: 400), finish);

    if (transition != null) {
      final Animation<double>? animation = transition.animation;
      if (animation == null) return;
      void listener(AnimationStatus status) {
        final bool done = onDismiss
            ? status == AnimationStatus.dismissed
            : status == AnimationStatus.completed;
        if (done) {
          animation.removeStatusListener(listener);
          finish();
        }
      }

      animation.addStatusListener(listener);
    }
  }
}

/// 全局单例：路由转场期间隐藏原生玻璃视图。
final glassRouteObserver = GlassRouteObserver();
