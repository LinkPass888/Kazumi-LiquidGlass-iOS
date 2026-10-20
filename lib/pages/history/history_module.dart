import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/history/history_page.dart';
import 'package:kazumi/pages/history/history_controller.dart';

final historyModule = createModule(
  path: '/history',
  register: (c) {
    c.route(
      '/',
      // 路由带名字，日志与埋点里能看到完整路径（模块挂在 /settings 下，
      // 完整路径是 /settings/history/）。详见 [NamedPageTransition]。
      transition: const NamedPageTransition('/settings/history/'),
      child: (context, state) => HistoryPage(
        controller: inject<HistoryController>(),
      ),
    );
  },
);
