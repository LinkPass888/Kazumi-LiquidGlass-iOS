import 'package:flutter/widgets.dart';
import 'package:real_liquid_glass/real_liquid_glass.dart';

/// 路由转场期间按路由精确隐藏原生玻璃视图。
///
/// 平台视图（UiKitView/AppKitView）是叠加在 Flutter 表面之上的原生层，不参与
/// Flutter 的路由转场 / Hero 飞行动画 —— 转场期间**正在动画的那一页**的玻璃会
/// 以「截屏残留」留在原位，盖住滑动的 Flutter 内容（如详情页 Hero 飞行的封面、
/// push 滑入时详情页的顶栏玻璃按钮先就位）。所以这里**只隐藏正在转场的那一页
/// 的玻璃**：push 详情页时隐藏详情页 route 的玻璃，首页底部标签栏（属于首页
/// route）保持显示，动画结束时不会突兀闪现。
///
/// 注意：PopupRoute（对话框、菜单、bottom sheet 等）不处理 —— 它们本身
/// 就是浮在玻璃之上的临时层，打开/关闭时玻璃应当保持可见，隐藏反而会造成
/// 忽隐忽现。
class GlassRouteObserver extends NavigatorObserver {
  /// 是否只应该响应页面级路由。
  ///
  /// 对话框/菜单是 PopupRoute，不属于页面转场，忽略。
  bool _isPageRoute(Route<dynamic> route) => route is PageRoute;

  /// 隐藏某条路由下的玻璃。
  void _hide(Object route) => LiquidGlassVisibility.setRouteHidden(route, true);

  /// 恢复某条路由下的玻璃。
  void _show(Object route) => LiquidGlassVisibility.setRouteHidden(route, false);

  /// 等到转场动画结束后恢复该路由的玻璃。
  ///
  /// 平台视图在转场期间不跟随 Flutter 动画，转场结束（动画 dismissed /
  /// completed）后平台视图已经就位，可以安全恢复。用动画监听而不是固定
  /// 时长，转场被打断也能正确恢复。
  void _scheduleShow(Route<dynamic>? route, {required bool onDismiss}) {
    if (route == null || !_isPageRoute(route)) return;
    final transition = route is TransitionRoute<dynamic> ? route : null;
    var ended = false;
    void finish() {
      if (ended) return;
      ended = true;
      _show(route);
    }

    // 兜底：无论动画监听是否挂上，最迟 400ms 后一定恢复，防止玻璃永久隐藏。
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

  /// push：新页面正在滑入。隐藏新页面自己的玻璃（顶栏按钮、玻璃面板），
  /// 首页底部标签栏等旧页面玻璃保持显示。
  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    if (!_isPageRoute(route)) return;
    _hide(route);
    _scheduleShow(route, onDismiss: false);
  }

  /// pop：当前页面正在滑出。隐藏被弹出的那页的玻璃，旧页面玻璃保持显示。
  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    if (!_isPageRoute(route)) return;
    _hide(route);
    _scheduleShow(route, onDismiss: true);
  }

  /// remove：页面被移除。
  @override
  void didRemove(Route route, Route? previousRoute) {
    super.didRemove(route, previousRoute);
    if (!_isPageRoute(route)) return;
    _hide(route);
    _scheduleShow(route, onDismiss: true);
  }

  /// replace：页面被替换。
  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null && _isPageRoute(newRoute)) {
      _hide(newRoute);
      _scheduleShow(newRoute, onDismiss: false);
    }
    if (oldRoute != null && _isPageRoute(oldRoute)) {
      _hide(oldRoute);
      _scheduleShow(oldRoute, onDismiss: true);
    }
  }

  /// iOS 侧滑返回手势开始：手指按住屏幕，页面开始跟着手指滑动。
  ///
  /// Flutter 的时序是 `handleStartBackGesture` → `didStartUserGesture`（动画由
  /// 用户驱动，页面已经动了）→ 提交手势时才 `didPop`。所以这里就要隐藏被
  /// 拖走的那一页的玻璃，否则拖动阶段原生层残留在原地，盖住正在滑动的页面。
  @override
  void didStartUserGesture(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didStartUserGesture(route, previousRoute);
    if (!_isPageRoute(route)) return;
    _hide(route);
  }

  /// 侧滑返回手势结束：提交 pop（反向动画到 dismissed）或取消回弹（正向动画
  /// 到 completed）后调用。这时页面动画已结束，恢复被拖走那页的玻璃。
  @override
  void didStopUserGesture() {
    super.didStopUserGesture();
  }
}

/// 全局单例：路由转场/侧滑返回手势期间按路由隐藏原生玻璃视图。
final glassRouteObserver = GlassRouteObserver();
