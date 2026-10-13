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
/// 于是 `route.settings.name` 恒为 null。任何「按路由名办事」的机制都会静默失效：
/// 典型的就是 [GlassRouteObserver]（见 bean/liquid_glass/glass_route_observer.dart），
/// 它靠 `settings.name` 认出「顶栏有大标题」的页面，在 push / 侧滑返回期间隐藏
/// 这一页自己的原生玻璃。
///
/// 所以需要被 observer 认出来的路由，都要把转场换成这个类，并把 [name] 传成
/// 和 `pushNamed()` 一致的路径（observer 按前缀匹配）。
class NamedPageTransition extends PageTransition {
  const NamedPageTransition(this.name);

  /// 这条路由的名字，即 `route.settings.name`。
  final String name;

  @override
  Page<void> buildPage(LocalKey key, Widget child) =>
      MaterialPage<void>(key: key, name: name, child: child);
}
