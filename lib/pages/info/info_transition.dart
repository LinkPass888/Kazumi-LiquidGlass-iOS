import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

/// 番剧详情页专用路由转场。
///
/// 背景：Modular 7.x（Navigator 2.0 / Router API）的默认 `TransitionType.material`
/// 生成的是 `MaterialPage<void>(key: key, child: child)` —— 只有 key，**没有
/// name**，所以 `route.settings.name` 恒为 null。而 `GlassRouteObserver` 靠
/// `settings.name == '/info/'` 识别详情页路由，来在 push / 侧滑返回期间按路由
/// 隐藏详情页自己的玻璃。name 为 null 时 observer 永远匹配不上，push 打开详情页
/// 时玻璃就不会隐藏。
///
/// 这里用与 [TransitionType.material] 完全相同的 `MaterialPage`，只是显式带上
/// `name: '/info/'`，让详情页路由在 observer 里可识别。行为（动画、返回手势）
/// 与默认完全一致。
class NamedInfoPageTransition extends PageTransition {
  const NamedInfoPageTransition();

  /// 详情页路由名（与 `pushNamed('/info/')` 一致，observer 用此前缀匹配）。
  static const String routeName = '/info/';

  @override
  Page<void> buildPage(LocalKey key, Widget child) =>
      MaterialPage<void>(key: key, name: routeName, child: child);
}
