import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/bean/widget/bangumi_mirror_error_widget.dart';
import 'package:kazumi/bean/widget/custom_dropdown_menu.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/popular/popular_controller.dart';
import 'package:kazumi/bean/card/bangumi_card.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/services/logging/logger.dart';

class PopularPage extends StatefulWidget {
  const PopularPage({
    super.key,
    required this.controller,
  });

  final PopularController controller;

  @override
  State<PopularPage> createState() => _PopularPageState();
}

class _PopularPageState extends State<PopularPage> {
  late final ScrollController scrollController;
  PopularController get popularController => widget.controller;

  // 给分类选择器定位用：菜单是浮层，得先拿到标题按钮在屏幕上的位置。
  final GlobalKey selectorKey = GlobalKey();

  /// 顶栏玻璃的出现进度：只让顶栏那一小块随滚动重建，列表不参与。
  final KazumiScrollProgress scrollProgress = KazumiScrollProgress();

  @override
  void initState() {
    super.initState();
    scrollController = ScrollController(
      initialScrollOffset: popularController.scrollOffset,
    );
    scrollController.addListener(scrollListener);
    if (popularController.trendList.isEmpty) {
      popularController.queryBangumiByTrend();
    }
  }

  @override
  void dispose() {
    scrollController.removeListener(scrollListener);
    scrollController.dispose();
    scrollProgress.dispose();
    super.dispose();
  }

  void scrollListener() {
    scrollProgress.updateFrom(scrollController.position);
    popularController.scrollOffset = scrollController.offset;
    if (scrollController.position.pixels >=
            scrollController.position.maxScrollExtent - 200 &&
        !popularController.isLoadingMore) {
      KazumiLogger()
          .i('PopularPageController: Fetching next recommendation batch');
      if (popularController.currentTag != '') {
        popularController.queryBangumiByTag();
      } else {
        popularController.queryBangumiByTrend();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final SysAppBar appBar = SysAppBar(
      // 小标题在滚动后淡入；大标题由 buildLargeTitle 画在列表里。
      title: const SizedBox.shrink(),
      collapsedTitle: Observer(
        builder: (_) => Text(
          popularController.currentTag.isEmpty
              ? '热门番组'
              : popularController.currentTag,
        ),
      ),
      actions: buildActions(),
      scrollProgress: scrollProgress,
    );
    return Scaffold(
      appBar: appBar,
      // 内容从顶栏底下滑过去，玻璃才采得到封面。AppBar 的背景画在 body
      // 之前（采不到东西），所以玻璃由 glassOverlay 叠在 body 的最上层。
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          CustomScrollView(
            controller: scrollController,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.only(top: appBar.bodyTopInset(context)),
              ),
              SliverToBoxAdapter(child: buildLargeTitle()),
              SliverToBoxAdapter(
                child: Observer(
                  builder: (_) => AnimatedOpacity(
                    opacity: popularController.isLoadingMore ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 300),
                    child: popularController.isLoadingMore
                        ? const LinearProgressIndicator(minHeight: 4)
                        : const SizedBox(height: 4),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                    StyleString.cardSpace, 0, StyleString.cardSpace, 0),
                sliver: Observer(builder: (_) {
                  if (popularController.isTimeOut) {
                    return SliverToBoxAdapter(
                      child: SizedBox(
                        height: 400,
                        child: BangumiMirrorErrorWidget(
                          onRetry: () {
                            if (popularController.trendList.isEmpty) {
                              popularController.queryBangumiByTrend();
                            } else {
                              popularController.queryBangumiByTag();
                            }
                          },
                          onSettingsReturned: () {
                            if (mounted) {
                              setState(() {});
                            }
                          },
                        ),
                      ),
                    );
                  }
                  return contentGrid(
                    (popularController.currentTag == '')
                        ? popularController.trendList
                        : popularController.bangumiList,
                  );
                }),
              ),
            ],
          ),
          appBar.glassOverlay(context),
        ],
      ),
      floatingActionButton: KazumiGlass.floatingButton(
        context: context,
        child: FloatingActionButton(
          // 回到顶部走滚动自己的惯性通道（用户一碰就交还控制权），
          // 曲线只负责前快后慢，和 iOS 的滚动一致。
          onPressed: () => scrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
          ),
          child: const Icon(Icons.arrow_upward),
        ),
      ),
    );
  }

  Widget contentGrid(List<BangumiItem> bangumiList) {
    int crossCount = 3;
    if (MediaQuery.sizeOf(context).width > LayoutBreakpoint.compact['width']!) {
      crossCount = 5;
    }
    if (MediaQuery.sizeOf(context).width > LayoutBreakpoint.medium['width']!) {
      crossCount = 6;
    }
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
          8, 8, 8, 8 + KazumiGlass.bottomInset(context)),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          // 行间距
          mainAxisSpacing: StyleString.cardSpace - 2,
          // 列间距
          crossAxisSpacing: StyleString.cardSpace,
          // 列数
          crossAxisCount: crossCount,
          mainAxisExtent:
              MediaQuery.of(context).size.width / crossCount / 0.65 +
                  MediaQuery.textScalerOf(context).scale(32.0),
        ),
        delegate: SliverChildBuilderDelegate(
          (BuildContext context, int index) {
            return bangumiList.isNotEmpty
                ? BangumiCardV(bangumiItem: bangumiList[index])
                : null;
          },
          childCount: bangumiList.isNotEmpty ? bangumiList.length : 10,
        ),
      ),
    );
  }

  /// 大标题：随列表滚走，并在滚动时收缩、淡出。
  ///
  /// 不需要额外的顶部留白：scaffold 的 body 本来就排在 AppBar 下面。
  Widget buildLargeTitle() {
    final theme = Theme.of(context);
    return KazumiLargeTitle(
        progress: scrollProgress,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Observer(
          builder: (_) {
            final bool isTrend = popularController.currentTag == '';
            // 用我们自己的浮层菜单（CustomDropdownMenu），不用 MenuAnchor：
            // 框架的菜单面板开合动画比我们这版慢（200ms 淡入 + 高度展开）。
            return Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                key: selectorKey,
                behavior: HitTestBehavior.opaque,
                onTap: showTagMenu,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isTrend ? '热门番组' : popularController.currentTag,
                      style: theme.textTheme.headlineMedium!.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 28,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.keyboard_arrow_down,
                      size: 26,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
    );
  }

  /// 顶栏的圆形玻璃按钮，尺寸与间距和统一顶栏一致。
  Widget _glassBarButton({
    required String tooltip,
    required VoidCallback onPressed,
    required Widget icon,
  }) {
    if (!KazumiGlass.enabled) {
      return IconButton(tooltip: tooltip, onPressed: onPressed, icon: icon);
    }
    return Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: KazumiGlass.barButtonGap / 2),
      child: KazumiGlass.iconButton(
        context: context,
        icon: icon,
        onPressed: onPressed,
        tooltip: tooltip,
      ),
    );
  }

  List<Widget> buildActions() {
    final actions = <Widget>[
      if (MediaQuery.of(context).orientation == Orientation.portrait)
        _glassBarButton(
          tooltip: '搜索',
          onPressed: () => context.pushNamed('/search/'),
          icon: const Icon(Icons.search, size: 22),
        ),
    ];
    actions.add(
      _glassBarButton(
        tooltip: '历史记录',
        onPressed: () => context.pushNamed('/settings/history/'),
        icon: const Icon(Icons.history, size: 22),
      ),
    );
    if (KazumiGlass.enabled) {
      actions.add(
        const SizedBox(
            width: KazumiGlass.barEdgeInset - KazumiGlass.barButtonGap / 2),
      );
    }
    return actions;
  }

  Future<void> showTagMenu() async {
    // 手动算按钮的位置来摆放浮层菜单。
    // 用 CustomDropdownMenu 而不是 PopupMenuButton / MenuAnchor：没有闪烁，
    // 而且标题（28/w700）和菜单条目可以用各自的字号。
    final RenderBox renderBox =
        selectorKey.currentContext!.findRenderObject() as RenderBox;
    final Offset offset = renderBox.localToGlobal(Offset.zero);
    final Size size = renderBox.size;

    final selected = await Navigator.push<String>(
      context,
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.transparent,
        pageBuilder: (context, animation, secondaryAnimation) {
          return CustomDropdownMenu(
            offset: offset,
            buttonSize: size,
            animation: animation,
            maxWidth: 80,
            items: [
              '',
              ...defaultAnimeTags,
            ],
            itemBuilder: (item) => item.isEmpty ? '热门番组' : item,
          );
        },
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 150),
      ),
    );

    if (selected == null) return;
    if (selected == '' && popularController.currentTag != '') {
      scrollController.animateTo(0,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      popularController.setCurrentTag('');
      popularController.clearBangumiList();
      if (popularController.trendList.isEmpty) {
        await popularController.queryBangumiByTrend();
      }
    } else if (selected != '' && selected != popularController.currentTag) {
      scrollController.animateTo(0,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      popularController.setCurrentTag(selected);
      await popularController.queryBangumiByTag(type: 'init');
    }
  }
}
