import 'package:flutter/widgets.dart';
import 'package:real_liquid_glass/real_liquid_glass.dart';

/// 路由转场期间按路由精确隐藏原生玻璃视图。
///
/// 平台视图（UiKitView/AppKitView）是叠加在 Flutter 表面之上的原生层，不参与
/// Flutter 的路由转场 / Hero 飞行动画 —— 转场期间**正在动画的那一页**的玻璃会
/// 以「截屏残留」留在原位，盖住滑动的 Flutter 内容（如详情页 Hero 飞行的封面、
/// push 滑入时详情页的顶栏玻璃按钮先就位）。
///
/// 只有番剧详情页（路由名 `/info/`，BangumiInfo）需要处理：打开详情页
/// （push 滑入）和退出详情页（pop / 侧滑返回）的转场期间，隐藏详情页自己的
/// 玻璃，动画结束后恢复 —— 与侧滑返回同等的处理。其它界面的转场一律不隐藏，
/// 玻璃保持常驻可见，避免不必要的闪烁。
///
/// 注意：PopupRoute（对话框、菜单、bottom sheet 等）不处理 —— 它们本身
/// 就是浮在玻璃之上的临时层，打开/关闭时玻璃应当保持可见，隐藏反而会造成
/// 忽隐忽现。
class GlassRouteObserver extends NavigatorObserver {
  /// 番剧详情页的路由名前缀（`/info/`）。
  static const String _detailRoutePrefix = '/info/';

  /// 是否是番剧详情页：PageRoute 且路由名以 `/info/` 开头。
  ///
  /// 详情页内部也会再 push `/info/`（关联推荐），每一层都同样处理。
  bool _isDetailRoute(Route<dynamic> route) =>
      route is PageRoute &&
      (route.settings.name?.startsWith(_detailRoutePrefix) ?? false);

  /// 正在被侧滑拖走的路由。非 null 表示侧滑手势尚未被 `didPop` 接手。
  ///
  /// 侧滑结束时有两种结局：提交 pop（`didPop` 会接管恢复）或取消回弹
  /// （不会触发 `didPop`，必须由 [didStopUserGesture] 恢复）。
  Route<dynamic>? _gestureRoute;

  /// 隐藏某条路由下的玻璃。
  void _hide(Object route) => LiquidGlassVisibility.setRouteHidden(route, true);

  /// 恢复某条路由下的玻璃。
  void _show(Object route) => LiquidGlassVisibility.setRouteHidden(route, false);

  /// 转场动画结束后恢复该路由的玻璃。
  ///
  /// 平台视图在转场期间不跟随 Flutter 动画，转场结束（MaterialPageRoute
  /// 动画约 300ms）后平台视图已经就位，可以安全恢复。这里用固定延时而不是
  /// 动画监听：`didPush` 时 `route.animation` 的 ProxyAnimation 状态不稳，
  /// 挂 listener 会误收到 completed 而提前恢复。侧滑返回的恢复不依赖这里
  /// （取消回弹由 [didStopUserGesture] 直接恢复）。
  void _scheduleShow(Route<dynamic>? route) {
    if (route == null || !_isDetailRoute(route)) return;
    Future<void>.delayed(const Duration(milliseconds: 400), () => _show(route));
  }

  /// push：打开番剧详情页。隐藏详情页自己的玻璃（顶栏按钮、玻璃面板），
  /// 动画结束后恢复 —— 与侧滑返回同等的处理。首页底部标签栏（属于首页
  /// route）保持显示，不会在动画结束时闪现。
  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    if (!_isDetailRoute(route)) return;
    _hide(route);
    _scheduleShow(route);
  }

  /// pop：番剧详情页正在滑出（按钮返回 / 侧滑返回）。隐藏被弹出的详情页
  /// 玻璃，动画结束后恢复；其它界面的返回不隐藏任何玻璃。
  ///
  /// 若这条 route 正在被侧滑拖走（[_gestureRoute]），则交还给
  /// [_scheduleShow] 在动画结束后恢复，[didStopUserGesture] 不再重复处理。
  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    if (identical(_gestureRoute, route)) {
      _gestureRoute = null;
    }
    if (!_isDetailRoute(route)) return;
    _hide(route);
    _scheduleShow(route);
  }

  /// remove：详情页被移除。
  @override
  void didRemove(Route route, Route? previousRoute) {
    super.didRemove(route, previousRoute);
    if (!_isDetailRoute(route)) return;
    _hide(route);
    _scheduleShow(route);
  }

  /// replace：详情页被替换。
  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null && _isDetailRoute(newRoute)) {
      _hide(newRoute);
      _scheduleShow(newRoute);
    }
    if (oldRoute != null && _isDetailRoute(oldRoute)) {
      _hide(oldRoute);
      _scheduleShow(oldRoute);
    }
  }

  /// iOS 侧滑返回手势开始：手指按住屏幕，详情页开始跟着手指滑动。
  ///
  /// 只有番剧详情页才需要隐藏：Flutter 的时序是 `handleStartBackGesture` →
  /// `didStartUserGesture`（动画由用户驱动，页面已经动了）→ 提交手势时才
  /// `didPop`。所以这里就要隐藏被拖走的详情页玻璃，否则拖动阶段原生层残留
  /// 在原地，盖住正在滑动的页面。其它页面的侧滑一律不处理。
  @override
  void didStartUserGesture(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didStartUserGesture(route, previousRoute);
    if (!_isDetailRoute(route)) return;
    _gestureRoute = route;
    _hide(route);
  }

  /// 侧滑返回手势结束。
  ///
  /// 提交 pop 时 [didPop] 已经接管恢复；取消回弹时没有任何后续回调，这里
  /// 必须手动恢复被隐藏的玻璃，否则它会永久隐藏。
  @override
  void didStopUserGesture() {
    super.didStopUserGesture();
    final Route<dynamic>? route = _gestureRoute;
    _gestureRoute = null;
    if (route == null) return;
    _show(route);
  }
}

/// 全局单例：番剧详情页（`/info/`）转场/侧滑返回期间按路由隐藏原生玻璃视图。
final glassRouteObserver = GlassRouteObserver();
