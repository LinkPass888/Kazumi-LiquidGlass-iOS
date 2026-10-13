import 'package:flutter/widgets.dart';
import 'package:real_liquid_glass/real_liquid_glass.dart';

/// 路由转场期间按路由精确隐藏原生玻璃视图。
///
/// 平台视图（UiKitView/AppKitView）是叠加在 Flutter 表面之上的原生层，不参与
/// Flutter 的路由转场 / Hero 飞行动画 —— 转场期间**正在动画的那一页**的玻璃会
/// 以「截屏残留」留在原位，盖住滑动的 Flutter 内容（如详情页 Hero 飞行的封面、
/// push 滑入时详情页的顶栏玻璃按钮先就位）。
///
/// 只有顶栏有大标题、顶栏又带玻璃按钮的页面需要处理：番剧详情页
/// （路由名 `/info/`，BangumiInfo）、搜索页（`/search`）和历史记录页
/// （`/settings/history`）。打开这些页面（push 滑入）、退出（pop / 侧滑返回）
/// 和侧滑拖动的转场期间隐藏它们自己的玻璃，动画结束后恢复。其它界面的转场一律
/// 不隐藏，玻璃保持常驻可见，避免不必要的闪烁。
///
/// 注意：PopupRoute（对话框、菜单、bottom sheet 等）不处理 —— 它们本身
/// 就是浮在玻璃之上的临时层，打开/关闭时玻璃应当保持可见，隐藏反而会造成
/// 忽隐忽现。
class GlassRouteObserver extends NavigatorObserver {
  /// 转场期间要隐藏自己玻璃的路由名前缀。
  ///
  /// - `/info/`：番剧详情页。Hero 飞行的封面、顶栏玻璃按钮会被原生层残留盖住；
  ///   详情页内部还会再 push `/info/`（关联推荐），每一层都同样处理，所以用前缀。
  /// - `/search`（搜索页）、`/settings/history`（历史记录页）：这两页的顶栏上
  ///   有一行大标题，转场结束、原生玻璃重新定位的那一帧会盖在标题上，看起来
  ///   就是「动画结束时标题突然消失又出现」。处理和详情页一样：转场期间隐藏，
  ///   转场结束后恢复。
  ///
  /// 只处理顶栏有大标题、且顶栏带玻璃按钮的页面 —— 其余页面转场期间玻璃保持
  /// 可见（隐藏再恢复反而会让玻璃突兀地闪现一下）。
  static const List<String> _transitionRoutePrefixes = <String>[
    '/info/',
    '/search',
    '/settings/history',
  ];

  /// 是否是转场期间需要隐藏玻璃的页面：PageRoute 且路由名命中
  /// [_transitionRoutePrefixes]。
  bool _needsTransitionHiding(Route<dynamic> route) {
    if (route is! PageRoute) return false;
    final String? name = route.settings.name;
    if (name == null) return false;
    return _transitionRoutePrefixes.any(name.startsWith);
  }

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
    if (route == null || !_needsTransitionHiding(route)) return;
    Future<void>.delayed(const Duration(milliseconds: 400), () => _show(route));
  }

  /// push：打开详情页 / 搜索页 / 历史记录页。隐藏这一页自己的玻璃
  /// （顶栏按钮、玻璃面板），动画结束后恢复 —— 与侧滑返回同等的处理。
  /// 首页底部标签栏（属于首页 route）保持显示，不会在动画结束时闪现。
  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    if (!_needsTransitionHiding(route)) return;
    _hide(route);
    _scheduleShow(route);
  }

  /// pop：详情页 / 搜索页 / 历史记录页正在滑出（按钮返回 / 侧滑返回）。
  /// 隐藏被弹出的这一页的玻璃，动画结束后恢复；其它界面的返回不隐藏任何玻璃。
  ///
  /// 若这条 route 正在被侧滑拖走（[_gestureRoute]），则交还给
  /// [_scheduleShow] 在动画结束后恢复，[didStopUserGesture] 不再重复处理。
  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    if (identical(_gestureRoute, route)) {
      _gestureRoute = null;
    }
    if (!_needsTransitionHiding(route)) return;
    _hide(route);
    _scheduleShow(route);
  }

  /// remove：被移除的是上述页面。
  @override
  void didRemove(Route route, Route? previousRoute) {
    super.didRemove(route, previousRoute);
    if (!_needsTransitionHiding(route)) return;
    _hide(route);
    _scheduleShow(route);
  }

  /// replace：被替换的是上述页面。
  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null && _needsTransitionHiding(newRoute)) {
      _hide(newRoute);
      _scheduleShow(newRoute);
    }
    if (oldRoute != null && _needsTransitionHiding(oldRoute)) {
      _hide(oldRoute);
      _scheduleShow(oldRoute);
    }
  }

  /// iOS 侧滑返回手势开始：手指按住屏幕，这一页开始跟着手指滑动。
  ///
  /// Flutter 的时序是 `handleStartBackGesture` → `didStartUserGesture`
  /// （动画由用户驱动，页面已经动了）→ 提交手势时才 `didPop`。所以这里就要
  /// 隐藏被拖走的那一页的玻璃，否则拖动阶段原生层残留在原地，盖住正在滑动的
  /// 页面。其它页面的侧滑一律不处理。
  @override
  void didStartUserGesture(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didStartUserGesture(route, previousRoute);
    if (!_needsTransitionHiding(route)) return;
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

/// 全局单例：详情页 / 搜索页 / 历史记录页在转场、侧滑返回期间按路由隐藏
/// 原生玻璃视图。
final glassRouteObserver = GlassRouteObserver();
