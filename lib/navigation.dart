import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Lets [RouteAware] pages learn they were covered or revealed again.
///
/// Restricted to [PageRoute] on purpose: dialogs and bottom sheets are
/// PopupRoutes, and sitting under one does not make a page hidden.
final rootRouteObserver = RouteObserver<PageRoute<void>>();

/// 给路由显式带上名字的转场，其余和 `TransitionType.material` 完全一样。
///
/// 背景：Modular 7.x（Navigator 2.0 / Router API）默认的 material 转场生成的是
/// `MaterialPage<void>(key: key, child: child)` —— 只有 key、**没有 name**，
/// 于是 `route.settings.name` 恒为 null。
///
/// 现在玻璃已经改为 Flutter 图层内的着色器，不再需要「转场期间隐藏玻璃」，
/// 但带 name 的路由对调试、埋点和后续按路由名做动画仍然有用，保留这个转场。
class NamedPageTransition extends PageTransition {
  const NamedPageTransition(this.name);

  /// 这条路由的名字，即 `route.settings.name`。
  final String name;

  @override
  Page<void> buildPage(LocalKey key, Widget child) =>
      MaterialPage<void>(key: key, name: name, child: child);
}
