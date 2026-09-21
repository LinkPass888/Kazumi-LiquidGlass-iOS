import 'dart:io';
import 'dart:ui';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/liquid_glass/glass_tab_bar.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/pages/info/rating_review_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/widget/collect_button.dart';
import 'package:kazumi/bean/widget/embedded_native_control_area.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/bean/card/bangumi_info_card.dart';
import 'package:kazumi/pages/info/source_sheet.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/pages/info/info_tabview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/bean/appbar/drag_to_move_bar.dart' as dtb;
import 'package:kazumi/utils/device.dart';

class InfoPage extends StatefulWidget {
  const InfoPage({
    super.key,
    required this.inputBangumiItem,
    required this.infoController,
    required this.pluginsController,
  });

  final BangumiItem inputBangumiItem;
  final InfoController infoController;
  final PluginsController pluginsController;

  @override
  State<InfoPage> createState() => _InfoPageState();
}

class _InfoPageState extends State<InfoPage> with TickerProviderStateMixin {
  static const List<String> _infoTabs = <String>[
    '概览',
    '吐槽',
    '角色',
    '关联',
    '制作人员',
  ];
  static const int _commentsTabIndex = 1;
  static const Duration _minimumBangumiInfoLoadingDuration =
      Duration(milliseconds: 600);

  InfoController get infoController => widget.infoController;
  PluginsController get pluginsController => widget.pluginsController;
  late TabController infoTabController;
  late bool showRating;

  bool commentsIsLoading = false;
  bool charactersIsLoading = false;
  bool commentsQueryTimeout = false;
  bool commentsIsEmpty = false;
  bool charactersQueryTimeout = false;
  bool charactersIsEmpty = false;
  bool staffIsLoading = false;
  bool staffQueryTimeout = false;
  bool staffIsEmpty = false;
  bool _showBangumiInfoSkeleton = false;
  int _fabTabIndex = 0;

  BangumiItem get inputBangumiIten => widget.inputBangumiItem;

  bool get _isShowingBangumiInfoSkeleton =>
      infoController.isLoading || _showBangumiInfoSkeleton;

  bool _needsBangumiInfoRefresh(BangumiItem bangumiItem) {
    final votesCount = bangumiItem.votesCount;
    final missingVoteDistribution =
        votesCount.isEmpty || bangumiItem.votes <= 0 || votesCount.length < 10;
    return bangumiItem.summary == '' || missingVoteDistribution;
  }

  Future<void> loadCharacters() async {
    if (charactersIsLoading) return;
    setState(() {
      charactersIsLoading = true;
      charactersQueryTimeout = false;
      charactersIsEmpty = false;
    });
    try {
      await infoController
          .queryBangumiCharactersByID(infoController.bangumiItem.id);
      if (mounted) {
        setState(() {
          charactersIsLoading = false;
          if (infoController.characterList.isEmpty) {
            charactersIsEmpty = true;
          }
        });
      }
    } catch (e) {
      KazumiLogger().e('InfoPage: failed to load characters', error: e);
      if (mounted) {
        setState(() {
          charactersIsLoading = false;
          charactersQueryTimeout = true;
        });
      }
    }
  }

  Future<void> loadStaff() async {
    if (staffIsLoading) return;
    setState(() {
      staffIsLoading = true;
      staffQueryTimeout = false;
      staffIsEmpty = false;
    });
    try {
      await infoController
          .queryBangumiStaffsByID(infoController.bangumiItem.id);
      if (mounted) {
        setState(() {
          staffIsLoading = false;
          if (infoController.staffList.isEmpty) {
            staffIsEmpty = true;
          }
        });
      }
    } catch (e) {
      KazumiLogger().e('InfoPage: failed to load staff', error: e);
      if (mounted) {
        setState(() {
          staffIsLoading = false;
          staffQueryTimeout = true;
        });
      }
    }
  }

  Future<void> loadRelations() async {
    try {
      await infoController
          .queryBangumiRelationsByID(infoController.bangumiItem.id);
    } catch (e) {
      KazumiLogger().e('InfoPage: failed to load relations', error: e);
    }
  }

  Future<void> loadMoreComments({bool loadMore = false}) async {
    if (commentsIsLoading) return;
    setState(() {
      commentsIsLoading = true;
      commentsQueryTimeout = false;
      commentsIsEmpty = false;
    });
    try {
      await infoController.queryBangumiCommentsByID(
          infoController.bangumiItem.id,
          refresh: !loadMore);
      if (mounted) {
        setState(() {
          commentsIsLoading = false;
          if (infoController.commentsList.isEmpty &&
              !(infoController.bangumiItem.interest?.hasReviewContent ??
                  false)) {
            commentsIsEmpty = true;
          }
        });
      }
    } catch (e) {
      KazumiLogger().e('InfoPage: failed to load comments', error: e);
      if (mounted) {
        setState(() {
          commentsIsLoading = false;
          commentsQueryTimeout = true;
        });
      }
    }
  }

  void onBangumiRatingTap() {
    final token =
        GStorage.getSetting(SettingsKeys.bangumiAccessToken).toString().trim();
    if (token.isEmpty) {
      KazumiDialog.showToast(message: '请先在同步设置中绑定你的 Bangumi 配置以发表吐槽');
      return;
    }
    final localType = infoController.collectController
        .getCollectType(infoController.bangumiItem);
    if (localType == 0) {
      KazumiDialog.showToast(message: '请先追番后再发表评价');
      return;
    }
    KazumiDialog.show(
      builder: (context) => RatingReviewDialog(
        bangumiItem: infoController.bangumiItem,
        onSubmit: (data) async {
          final updated =
              await infoController.rateBangumi(data, localType: localType);
          if (updated && mounted) {
            setState(() {});
          }
          return updated;
        },
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    infoController.bangumiItem = inputBangumiIten;
    infoController.characterList.clear();
    infoController.clearComments();
    infoController.staffList.clear();
    infoController.clearRelations();
    infoController.pluginSearchResponseList.clear();
    // Search results can miss rating distribution or summaries, so fill those
    // fields without replacing image URLs that are already rendered.
    if (_needsBangumiInfoRefresh(infoController.bangumiItem)) {
      _showBangumiInfoSkeleton = true;
      queryBangumiInfoByID(
        infoController.bangumiItem.id,
        type: 'attach',
        enforceMinimumLoadingDuration: true,
      );
    }
    infoTabController = TabController(length: _infoTabs.length, vsync: this);
    _fabTabIndex = infoTabController.index;
    showRating = GStorage.getSetting(SettingsKeys.showRating);
    infoTabController.addListener(onInfoTabChanged);
    infoTabController.addListener(_syncFabTabIndex);
    infoTabController.animation?.addListener(_syncFabTabIndex);
  }

  void onInfoTabChanged() {
    final index = infoTabController.index;
    if (index == 2 &&
        infoController.characterList.isEmpty &&
        !charactersIsLoading &&
        !charactersIsEmpty &&
        !charactersQueryTimeout) {
      loadCharacters();
    }
    if (index == 3 && infoController.canLoadRelations) {
      loadRelations();
    }
    if (index == 4 &&
        infoController.staffList.isEmpty &&
        !staffIsLoading &&
        !staffIsEmpty &&
        !staffQueryTimeout) {
      loadStaff();
    }
  }

  void _syncFabTabIndex() {
    final animation = infoTabController.animation;
    final targetIndex = infoTabController.indexIsChanging
        ? infoTabController.index
        : (animation?.value.round() ?? infoTabController.index);
    final nextIndex =
        targetIndex.clamp(0, infoTabController.length - 1).toInt();

    if (_fabTabIndex == nextIndex) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _fabTabIndex = nextIndex;
    });
  }

  Future<void> onCommentsTabSelected() async {
    final interest = infoController.bangumiItem.interest;
    final token =
        GStorage.getSetting(SettingsKeys.bangumiAccessToken).toString().trim();
    if (interest != null && token.isNotEmpty) {
      final updated = await infoController.fillInterestUserProfileIfNeeded();
      if (updated && mounted) {
        setState(() {});
      }
    }
    if (infoController.commentsList.isEmpty &&
        !commentsIsLoading &&
        !commentsIsEmpty &&
        !commentsQueryTimeout) {
      loadMoreComments();
    }
  }

  @override
  void dispose() {
    infoTabController.removeListener(onInfoTabChanged);
    infoTabController.removeListener(_syncFabTabIndex);
    infoTabController.animation?.removeListener(_syncFabTabIndex);
    infoController.characterList.clear();
    infoController.clearComments();
    infoController.staffList.clear();
    infoController.clearRelations();
    infoController.pluginSearchResponseList.clear();
    infoTabController.dispose();
    super.dispose();
  }

  Future<void> queryBangumiInfoByID(
    int id, {
    String type = "init",
    bool enforceMinimumLoadingDuration = false,
  }) async {
    final loadingStartedAt = DateTime.now();
    try {
      await infoController.queryBangumiInfoByID(id, type: type);
    } catch (e) {
      KazumiLogger()
          .e('InfoPage: failed to query bangumi info by ID', error: e);
    } finally {
      if (enforceMinimumLoadingDuration && mounted) {
        await _waitForMinimumBangumiInfoLoadingDuration(loadingStartedAt);
      }
      if (mounted) {
        setState(() {
          _showBangumiInfoSkeleton = false;
        });
      }
    }
  }

  Future<void> _waitForMinimumBangumiInfoLoadingDuration(
      DateTime loadingStartedAt) async {
    final elapsed = DateTime.now().difference(loadingStartedAt);
    final remaining = _minimumBangumiInfoLoadingDuration - elapsed;
    if (remaining > Duration.zero) {
      await Future.delayed(remaining);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool showWindowButton =
        GStorage.getSetting(SettingsKeys.showWindowButton);
    final bool showRatingFab = _fabTabIndex == _commentsTabIndex;
    return PopScope(
      canPop: true,
      child: DefaultTabController(
        length: _infoTabs.length,
        child: Scaffold(
          body: NestedScrollView(
            headerSliverBuilder:
                (BuildContext context, bool innerBoxIsScrolled) {
              // 顶部这条玻璃标签栏占掉的高度
              final double tabBand = KazumiGlassTabBar.heightOf(context);
              return <Widget>[
                SliverOverlapAbsorber(
                  handle:
                      NestedScrollView.sliverOverlapAbsorberHandleFor(context),
                  sliver: SliverAppBar(
                    // 不用 .medium：那套标题的显隐跟着「内容有没有滚到顶栏下面」
                    // 走（Flutter 的 _SliverAppBarDelegate.build：
                    // opacity: isScrolledUnder ? 1 : 0），而详情页是
                    // NestedScrollView —— 外层折叠完、内层列表还停在顶部时它就
                    // 淡掉，往上滑才又出现，松手就没了。这里改成自己按折叠进度
                    // 控制显隐，折叠完成就一直显示。
                    pinned: true,
                    title: _CollapseFade(
                      child: EmbeddedNativeControlArea(
                        child: dtb.DragToMoveArea(
                          child: Container(
                            width: double.infinity,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              infoController.bangumiItem.nameCn == ''
                                  ? infoController.bangumiItem.name
                                  : infoController.bangumiItem.nameCn,
                            ),
                          ),
                        ),
                      ),
                    ),
                    automaticallyImplyLeading: false,
                    scrolledUnderElevation: 0.0,
                    leadingWidth: KazumiGlass.barLeadingWidth,
                    leading: Center(
                      child: KazumiGlass.iconButton(
                        context: context,
                        icon: const Icon(Icons.arrow_back, size: 22),
                        onPressed: () => context.maybePop(),
                        tooltip:
                            MaterialLocalizations.of(context).backButtonTooltip,
                      ),
                    ),
                    actions: [
                      // 收藏按钮和标题同一套显隐：跟着折叠进度淡入，折叠完一直
                      // 显示。之前用 innerBoxIsScrolled 判断 —— 那是「内层列表
                      // 有没有滚」，外层折叠完、内层列表回到顶部时它就跟着消失，
                      // 也就是「松手就没了」。
                      _barButton(
                        _CollapseFade(
                          child: CollectButton(
                            bangumiItem: infoController.bangumiItem,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            // 按钮贴着屏幕右上角：菜单右对齐按钮、往下 10、往里
                            // 12，既不粘在按钮上，也不顶着屏幕边。
                            menuAlignment: AlignmentDirectional.bottomEnd,
                            menuAlignmentOffset: const Offset(-12, 10),
                          ),
                        ),
                      ),
                      _barButton(
                        IconButton(
                          onPressed: () {
                            launchUrl(
                              Uri.parse(
                                  'https://bangumi.tv/subject/${infoController.bangumiItem.id}'),
                              mode: LaunchMode.externalApplication,
                            );
                          },
                          icon: const Icon(Icons.open_in_browser_rounded,
                              size: 22),
                        ),
                      ),
                      if (!showWindowButton && isDesktop())
                        CloseButton(onPressed: () => windowManager.close()),
                      // 每个按钮左右各留 barButtonGap / 2，这里减掉自己那一半，
                      // 最后一个按钮离屏幕边才是 barEdgeInset（与推荐页右上角一致）
                      const SizedBox(
                        width: KazumiGlass.barEdgeInset -
                            KazumiGlass.barButtonGap / 2,
                      ),
                    ],
                    toolbarHeight: (Platform.isMacOS && showWindowButton)
                        ? kToolbarHeight + 22
                        : kToolbarHeight,
                    stretch: true,
                    centerTitle: false,
                    // 364 = 卡片的 356 + 8 余量。状态栏内边距不要自己加：
                    // Flutter 的 _SliverAppBarDelegate.maxExtent 已经把它算在
                    // 上面了（maxExtent = topPadding + expandedHeight），
                    // 这里再加一次顶栏就会白高出一截。
                    expandedHeight: (Platform.isMacOS && showWindowButton)
                        ? 364 + tabBand + kToolbarHeight + 22
                        : 364 + tabBand + kToolbarHeight,
                    // collapsedHeight 只写「工具栏」那一截。Flutter 自己还会
                    // 加上底部标签栏和状态栏内边距 —— app_bar.dart:
                    //   collapsedHeight = (widget.collapsedHeight
                    //       ?? widget.toolbarHeight) + bottomHeight + topPadding
                    // 这里之前把状态栏和标签栏也写了进去，于是收起后顶栏白白多出
                    // 107（= 59 状态栏 + 48 标签栏）的空档，标签条停在半路上不去。
                    collapsedHeight: (Platform.isMacOS && showWindowButton)
                        ? kToolbarHeight + 22
                        : kToolbarHeight,
                    flexibleSpace: FlexibleSpaceBar(
                      collapseMode: CollapseMode.pin,
                      background: Observer(builder: (context) {
                        final showBangumiInfoSkeleton =
                            _isShowingBangumiInfoSkeleton;
                        // 折叠交给框架自己的 pin 行为：弹性空间整体往上抽，
                        // 卡片的顶边先被裁掉、底边一路贴着标签栏上沿 —— 也就是
                        // 「从顶部缩减」。之前在这里自己裁底边，方向正好反了。
                        return Stack(
                          children: [
                            // No background image when loading to make loading looks better
                            if (!showBangumiInfoSkeleton)
                              Positioned.fill(
                                bottom: tabBand,
                                child: IgnorePointer(
                                  child: _InfoHeaderBackground(
                                    imageUrl: infoController
                                            .bangumiItem.images['large'] ??
                                        '',
                                  ),
                                ),
                              ),
                            SafeArea(
                              bottom: false,
                              child: EmbeddedNativeControlArea(
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        16, kToolbarHeight, 16, 0),
                                    child: BangumiInfoCardV(
                                      bangumiItem: infoController.bangumiItem,
                                      isLoading: showBangumiInfoSkeleton,
                                      showRating: showRating,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      }),
                    ),
                    forceElevated: innerBoxIsScrolled,
                    bottom: KazumiGlassTabBar(
                      controller: infoTabController,
                      tabs: _infoTabs,
                    ),
                  ),
                ),
              ];
            },
            body: Observer(builder: (context) {
              final showBangumiInfoSkeleton = _isShowingBangumiInfoSkeleton;
              return InfoTabView(
                tabController: infoTabController,
                bangumiItem: infoController.bangumiItem,
                commentsQueryTimeout: commentsQueryTimeout,
                commentsIsEmpty: commentsIsEmpty,
                charactersQueryTimeout: charactersQueryTimeout,
                charactersIsEmpty: charactersIsEmpty,
                staffQueryTimeout: staffQueryTimeout,
                staffIsEmpty: staffIsEmpty,
                loadMoreComments: loadMoreComments,
                loadCharacters: loadCharacters,
                loadStaff: loadStaff,
                commentsList: infoController.commentsList,
                commentsIsLoading: commentsIsLoading,
                onCommentsTabSelected: onCommentsTabSelected,
                characterList: infoController.characterList,
                staffList: infoController.staffList,
                relationList: infoController.relationList,
                relationsIsLoading: infoController.relationsIsLoading,
                relationsQueryTimeout: infoController.relationsQueryTimeout,
                relationsHasLoaded: infoController.relationsHasLoaded,
                loadRelations: loadRelations,
                isLoading: showBangumiInfoSkeleton,
              );
            }),
          ),
          floatingActionButton: showRatingFab
              ? KazumiGlass.floatingButton(
                  context: context,
                  aboveTabBar: false,
                  child: FloatingActionButton.extended(
                    tooltip: '吐槽',
                    onPressed: onBangumiRatingTap,
                    label: const Text('发表吐槽'),
                    icon: const Icon(Icons.rate_review_rounded),
                  ),
                )
              : KazumiGlass.floatingButton(
                  context: context,
                  aboveTabBar: false,
                  child: FloatingActionButton.extended(
                    tooltip: '开始观看',
                    onPressed: () {
                      showAdaptiveBottomSheet<void>(
                        backgroundColor:
                            Theme.of(context).scaffoldBackgroundColor,
                        context: context,
                        builder: (context) {
                          return SourceSheet(infoController: infoController);
                        },
                      );
                    },
                    label: const Text('开始观看'),
                    icon: const Icon(Icons.play_arrow_rounded),
                  ),
                )
        ),
      ),
    );
  }
}

/// 详情页顶栏按钮：尺寸统一的圆形玻璃，图标居中。
///
/// 左右各留 [KazumiGlass.barButtonGap] / 2：两个按钮之间就是 barButtonGap，
/// 和推荐页右上角那两个按钮一模一样，不会粘在一起。
Widget _barButton(Widget child) {
  return Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: KazumiGlass.barButtonGap / 2,
    ),
    child: KazumiGlass.buttonGlass(
      child: SizedBox(
        width: KazumiGlass.barButtonSize,
        height: KazumiGlass.barButtonSize,
        child: child,
      ),
    ),
  );
}

/// 折叠时才出现的顶栏内容（标题、收藏按钮）。
///
/// 为什么不用 [SliverAppBar.medium] 那套：medium / large 的工具栏标题只是
/// 一个「内容滚到顶栏下面时」才淡入的副本，真正的展开态标题由它自己的弹性空间
/// 渲染 —— 而详情页要用自定义 background，把它整个覆盖掉了。于是就成了：
/// 外层折叠完、内层列表还停在顶部时它淡出，往上滑才又出现，松手就没了。
///
/// 这里跟着**折叠进度**走：展开时透明，折叠过半淡入，折叠完成一直显示。
/// 收藏按钮也是同一套 —— 用 innerBoxIsScrolled 判断的话，外层折叠完、内层
/// 列表回到顶部，它会跟着一起消失。
class _CollapseFade extends StatelessWidget {
  const _CollapseFade({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final FlexibleSpaceBarSettings? settings =
        context.dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
    double progress = 1;
    if (settings != null) {
      final double span = settings.maxExtent - settings.minExtent;
      if (span > 0) {
        progress = ((settings.maxExtent - settings.currentExtent) / span)
            .clamp(0.0, 1.0);
      }
    }
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      opacity: progress > 0.6 ? 1 : 0,
      child: child,
    );
  }
}

class _InfoHeaderBackground extends StatelessWidget {
  const _InfoHeaderBackground({
    required this.imageUrl,
  });

  static const double _blurSigma = 15.0;
  static const double _opacity = 0.4;
  static const double _bottomFeatherHeight = 48.0;

  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    if (imageUrl.isEmpty) {
      return const SizedBox.shrink();
    }

    final Color backgroundColor = Theme.of(context).scaffoldBackgroundColor;

    return LayoutBuilder(
      builder: (context, constraints) {
        final double width = constraints.maxWidth;
        final double height = constraints.maxHeight;
        if (width <= 0 || height <= 0) {
          return const SizedBox.shrink();
        }
        // 按整块区域直接画：不再降采样后 Transform 放大 —— 那条路径会在
        // 屏幕上留下一条竖着的接缝（放送开始那一行的高度上看得最清楚）。
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ShaderMask(
                shaderCallback: (bounds) {
                  return const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white,
                      Colors.transparent,
                    ],
                    stops: [0.8, 1],
                  ).createShader(bounds);
                },
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(
                    sigmaX: _blurSigma,
                    sigmaY: _blurSigma,
                  ),
                  child: NetworkImgLayer(
                    src: imageUrl,
                    width: width,
                    height: height,
                    fadeInDuration: Duration.zero,
                    fadeOutDuration: Duration.zero,
                    filterQuality: FilterQuality.medium,
                    color: Colors.white.withValues(alpha: _opacity),
                    colorBlendMode: BlendMode.modulate,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: _bottomFeatherHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        backgroundColor.withValues(alpha: 0),
                        backgroundColor.withValues(alpha: 0.55),
                        backgroundColor,
                      ],
                      stops: const [0, 0.72, 1],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
