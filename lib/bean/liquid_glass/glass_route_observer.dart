import 'package:flutter/widgets.dart';
import 'package:real_liquid_glass/real_liquid_glass.dart';

/// iOS 侧滑返回手势期间隐藏所有原生玻璃视图。
///
/// 平台视图（UiKitView）是叠加在 Flutter 表面之上的原生层，不参与 Flutter 的
/// 路由转场 / Hero 飞行动画。侧滑返回手势的拖动阶段动画由手指驱动，`didPop`
/// 要等用户松手提交手势才触发 —— 如果只靠 `didPop` 隐藏，拖动时玻璃（原生层）
/// 会留在原地不动，盖住正在被拖走的页面以及露出的下层页面。所以手势一开始
/// （[didStartUserGesture]）就隐藏玻璃，手势结束（[didStopUserGesture]）再恢复。
///
/// 注意：PopupRoute（对话框、菜单、bottom sheet 等）不处理 —— 它们本身
/// 就是浮在玻璃之上的临时层，打开/关闭时玻璃应当保持可见，隐藏反而会造成
/// 忽隐忽现。
class GlassRouteObserver extends NavigatorObserver {
  /// 是否只应该响应页面级路由。
  ///
  /// 对话框/菜单是 PopupRoute，不属于页面转场，忽略。
  bool _isPageRoute(Route<dynamic> route) => route is PageRoute;

  /// 本次侧滑手势是否真的隐藏了玻璃。
  ///
  /// `didStartUserGesture` 时栈顶不是 PageRoute（例如对话框盖在上面）就不会
  /// 隐藏，`didStopUserGesture` 必须与它配对，不能盲目地恢复玻璃。
  bool _gestureHidden = false;

  /// iOS 侧滑返回手势开始：手指按住屏幕，页面开始跟着手指滑动。
  ///
  /// Flutter 的时序是 `handleStartBackGesture` → `didStartUserGesture`（动画由
  /// 用户驱动，页面已经动了）→ 提交手势时才 `didPop`。所以这里就要隐藏玻璃，
  /// 否则拖动阶段原生层残留在原地，盖住正在滑动的页面。
  @override
  void didStartUserGesture(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didStartUserGesture(route, previousRoute);
    if (!_isPageRoute(route)) return;
    _gestureHidden = true;
    LiquidGlassVisibility.setHidden(true);
  }

  /// 侧滑返回手势结束：提交 pop（反向动画到 dismissed）或取消回弹（正向动画
  /// 到 completed）后调用。这时页面动画已结束，可以恢复玻璃。
  @override
  void didStopUserGesture() {
    super.didStopUserGesture();
    if (!_gestureHidden) return;
    _gestureHidden = false;
    LiquidGlassVisibility.setHidden(false);
  }

}

/// 全局单例：侧滑返回手势期间隐藏原生玻璃视图。
final glassRouteObserver = GlassRouteObserver();
