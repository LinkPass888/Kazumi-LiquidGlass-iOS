import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/search/image_search_page.dart';
import 'package:kazumi/pages/search/search_controller.dart';
import 'package:kazumi/pages/search/search_page.dart';

void _provideSearchController(Scoped scoped) {
  scoped.add<SearchPageController>(SearchPageController.new);
}

/// 搜索页的路由都要带名字：GlassRouteObserver 靠路由名认出「顶栏有大标题」的
/// 搜索页，在 push / 侧滑返回期间隐藏这一页自己的玻璃（否则顶栏那行大标题
/// 会在转场结束的那一帧被原生玻璃盖一下，看起来就是标题闪了一下）。
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
        // 动态 tag 路由：路径是 /search/<tag>，这里给个固定名字即可，
        // observer 只按 '/search' 前缀匹配。
        transition: const NamedPageTransition('/search/tag'),
        child: (context, state) => SearchPage(
          controller: context.read<SearchPageController>(),
          inputTag: state['tag'] ?? '',
        ),
      );
  },
);
