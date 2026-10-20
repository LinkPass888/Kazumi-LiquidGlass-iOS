import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/search/image_search_page.dart';
import 'package:kazumi/pages/search/search_controller.dart';
import 'package:kazumi/pages/search/search_page.dart';

void _provideSearchController(Scoped scoped) {
  scoped.add<SearchPageController>(SearchPageController.new);
}

/// 搜索页的路由都带名字，日志与埋点里能看到完整路径。
/// 详见 [NamedPageTransition]。
final searchModule = createModule(
  path: '/search',
  register: (c) {
    c
      ..route(
        '/',
        provide: _provideSearchController,
        transition: const NamedPageTransition('/search/'),
        child: (context, state) => SearchPage(
          controller: context.read<SearchPageController>(),
        ),
      )
      ..route(
        '/image',
        provide: _provideSearchController,
        transition: const NamedPageTransition('/search/image'),
        child: (context, state) => ImageSearchPage(
          controller: context.read<SearchPageController>(),
        ),
      )
      ..route(
        '/:tag',
        provide: _provideSearchController,
        // 动态 tag 路由：路径是 /search/<tag>，这里给个固定名字即可。
        transition: const NamedPageTransition('/search/tag'),
        child: (context, state) => SearchPage(
          controller: context.read<SearchPageController>(),
          inputTag: state['tag'] ?? '',
        ),
      );
  },
);
