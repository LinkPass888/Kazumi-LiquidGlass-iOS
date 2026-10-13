import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/history/history_page.dart';
import 'package:kazumi/pages/history/history_controller.dart';

final historyModule = createModule(
  path: '/history',
  register: (c) {
    c.route(
      '/',
      // 路由带名字，GlassRouteObserver 才认得出历史记录页（模块挂在 /settings
      // 下，完整路径是 /settings/history/）。详见 [NamedPageTransition]。
      transition: const NamedPageTransition('/settings/history/'),
      child: (context, state) => HistoryPage(
        controller: inject<HistoryController>(),
      ),
    );
  },
);
