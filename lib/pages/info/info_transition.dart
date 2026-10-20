import 'package:kazumi/navigation.dart';

/// 番剧详情页专用路由转场。
///
/// 只做一件事：把详情页路由的名字显式设成 `'/info/'`。为什么需要见
/// [NamedPageTransition]——Modular 默认的 material 转场不给 Page 带 name，
/// `route.settings.name` 恒为 null。行为（动画、返回手势）与默认完全一致。
class NamedInfoPageTransition extends NamedPageTransition {
  const NamedInfoPageTransition() : super(routeName);

  /// 详情页路由名（与 `pushNamed('/info/')` 一致，observer 用此前缀匹配）。
  static const String routeName = '/info/';
}
