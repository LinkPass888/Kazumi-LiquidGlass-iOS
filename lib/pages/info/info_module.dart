import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/pages/info/info_page.dart';
import 'package:kazumi/pages/info/info_transition.dart';
import 'package:kazumi/pages/route_error_page.dart';
import 'package:kazumi/plugins/plugins_controller.dart';

final infoModule = createModule(
  path: '/info',
  register: (c) {
    c.route(
      '/',
      provide: (s) => s.add<InfoController>(InfoController.new),
      // 详情页路由必须带 name '/info/'：GlassRouteObserver 靠它识别详情页，
      // 在 push / 侧滑返回期间隐藏详情页自己的玻璃（见 NamedInfoPageTransition）。
      transition: const NamedInfoPageTransition(),
      child: (context, state) {
        final bangumiItem = state.arguments;
        if (bangumiItem is! BangumiItem) {
          return const RouteErrorPage(message: '番组详情参数无效，请返回后重新打开。');
        }
        return InfoPage(
          inputBangumiItem: bangumiItem,
          infoController: context.read<InfoController>(),
          pluginsController: inject<PluginsController>(),
        );
      },
    );
  },
);
