import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/drag_to_move_bar.dart' as dtb;
import 'package:kazumi/bean/liquid_glass/glass_tab_bar.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/bean/card/bangumi_info_card.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/embedded_native_control_area.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/info/info_actions_menu.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/pages/info/info_tabview.dart';
import 'package:kazumi/pages/info/rating_review_dialog.dart';
import 'package:kazumi/pages/info/source_sheet.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

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

class _InfoPageState extends State<InfoPage>
    with SingleTickerProviderStateMixin {
  static const List<String> _infoTabs = <String>[
    '概览',
    '吐槽',
    '角色',
    '关联',
    '制作人员',
  ];
  static const Duration _minimumBangumiInfoLoadingDuration =
      Duration(milliseconds: 600);

  InfoController get infoController => widget.infoController;
  late final TabController infoTabController;
  late final bool showRating;

  bool commentsIsLoading = false;
  bool charactersIsLoading = false;
  bool commentsQueryTimeout = false;
  bool commentsHasLoaded = false;
  bool charactersQueryTimeout = false;
  bool charactersIsEmpty = false;
  bool staffIsLoading = false;
  bool staffQueryTimeout = false;
  bool staffIsEmpty = false;
  bool _showBangumiInfoSkeleton = false;

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
    });
    try {
      await infoController.queryBangumiCommentsByID(
          infoController.bangumiItem.id,
          refresh: !loadMore);
      if (mounted) {
        setState(() {
          commentsIsLoading = false;
          commentsHasLoaded = true;
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

  Future<void> _openReviewEditor() async {
    final token =
        GStorage.getSetting(SettingsKeys.bangumiAccessToken).toString().trim();
    if (token.isEmpty) {
      KazumiDialog.showToast(message: '请先在同步设置中绑定 Bangumi');
      return;
    }
    final localType = infoController.collectController
        .getCollectType(infoController.bangumiItem);
    if (localType == 0) {
      KazumiDialog.showToast(message: '请先追番');
      return;
    }
    final editing =
        infoController.bangumiItem.interest?.hasReviewContent ?? false;
    final submitted = await KazumiDialog.show<bool>(
      context: context,
      builder: (context) => RatingReviewDialog(
        bangumiItem: infoController.bangumiItem,
        onSubmit: (review) =>
            infoController.rateBangumi(review, localType: localType),
      ),
    );
    if (submitted == true && mounted) {
      setState(() {});
      KazumiDialog.showToast(
        context: context,
        message: editing ? '吐槽已更新' : '吐槽已发表',
      );
    }
  }

  @override
  void initState() {
    super.initState();
    infoController.bangumiItem = widget.inputBangumiItem;
    infoController.characterList.clear();
    infoController.clearComments();
    infoController.staffList.clear();
    infoController.clearRelations();
    infoController.pluginSearchResponseList.clear();
    if (_needsBangumiInfoRefresh(infoController.bangumiItem)) {
      _showBangumiInfoSkeleton = true;
      _loadBangumiInfo();
    }
    infoTabController = TabController(length: _infoTabs.length, vsync: this);
    showRating = GStorage.getSetting(SettingsKeys.showRating);
    infoTabController.addListener(onInfoTabChanged);
  }

  void onInfoTabChanged() {
    final index = infoTabController.index;
    if (index == 1) {
      onCommentsTabSelected();
    }
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

  Future<void> onCommentsTabSelected() async {
    final interest = infoController.bangumiItem.interest;
    final token =
        GStorage.getSetting(SettingsKeys.bangumiAccessToken).toString().trim();
    if (interest != null && token.isNotEmpty) {
      final updated = await infoController.fillInterestUserProfileIfNeeded();
      if (!mounted) return;
      if (updated) {
        setState(() {});
      }
    }
    if (infoController.commentsList.isEmpty &&
        !commentsIsLoading &&
        !commentsHasLoaded &&
        !commentsQueryTimeout) {
      loadMoreComments();
    }
  }

  @override
  void dispose() {
    infoTabController.removeListener(onInfoTabChanged);
    infoController.characterList.clear();
    infoController.clearComments();
    infoController.staffList.clear();
    infoController.clearRelations();
    infoController.pluginSearchResponseList.clear();
    infoTabController.dispose();
    super.dispose();
  }

  Future<void> _loadBangumiInfo() async {
    final loadingStartedAt = DateTime.now();
    try {
      // Attach metadata without replacing rendered image URLs.
      await infoController.queryBangumiInfoByID(
        infoController.bangumiItem.id,
        type: 'attach',
      );
    } catch (e) {
      KazumiLogger()
          .e('InfoPage: failed to query bangumi info by ID', error: e);
    } finally {
      if (mounted) {
        await _waitForMinimumBangumiInfoLoadingDuration(loadingStartedAt);
      }
      if (mounted) {
        setState(() {
          _showBangumiInfoSkeleton = false;
        });
      }
    }
  }

  void _startWatching() {
    if (widget.pluginsController.pluginList.isEmpty) {
      KazumiDialog.showToast(
        message: '还没有规则，无法开始观看',
        showActionButton: true,
        actionLabel: '添加规则',
        onActionPressed: () {
          if (mounted) context.pushNamed('/settings/plugin/');
        },
        duration: const Duration(seconds: 4),
      );
      return;
    }
    showAdaptiveBottomSheet<void>(
      context: context,
      maxHeightFactor: 0.88,
      builder: (_) => SourceSheet(infoController: infoController),
    );
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
    return Scaffold(
      body: NestedScrollView(
        headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) {
          // 顶部这条玻璃标签栏占掉的高度
          final double tabBand = KazumiGlassTabBar.heightOf(context);
          return <Widget>[
            SliverOverlapAbsorber(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
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
                  // 收藏状态由卡片里那个按钮负责（贴封面底边），顶栏不再重复
                  // 放一个；其余操作（复制标题、保存封面、浏览器打开）都在菜单里。
                  _barButton(
                    InfoActionsMenu(
                      bangumiItem: infoController.bangumiItem,
                    ),
                  ),
                  // 每个按钮左右各留 barButtonGap / 2，这里减掉自己那一半，
                  // 最后一个按钮离屏幕边才是 barEdgeInset（与推荐页右上角一致）
                  const SizedBox(
                    width: KazumiGlass.barEdgeInset -
                        KazumiGlass.barButtonGap / 2,
                  ),
                ],
                toolbarHeight: kToolbarHeight,
                stretch: true,
                centerTitle: false,
                // 364 = 卡片的 356 + 8 余量。状态栏内边距不要自己加：
                // Flutter 的 _SliverAppBarDelegate.maxExtent 已经把它算在
                // 上面了（maxExtent = topPadding + expandedHeight），
                // 这里再加一次顶栏就会白高出一截。
                expandedHeight: 364 + tabBand + kToolbarHeight,
                // collapsedHeight 只写「工具栏」那一截。Flutter 自己还会
                // 加上底部标签栏和状态栏内边距 —— app_bar.dart:
                //   collapsedHeight = (widget.collapsedHeight
                //       ?? widget.toolbarHeight) + bottomHeight + topPadding
                // 这里之前把状态栏和标签栏也写了进去，于是收起后顶栏白白多出
                // 107（= 59 状态栏 + 48 标签栏）的空档，标签条停在半路上不去。
                collapsedHeight: kToolbarHeight,
                flexibleSpace: FlexibleSpaceBar(
                  collapseMode: CollapseMode.pin,
                  background: Observer(builder: (context) {
                    final showBangumiInfoSkeleton =
                        _isShowingBangumiInfoSkeleton;
                    // 背景那一层**始终留在 children 里**，只切「画不画」：
                    // 之前是 `if (!skeleton)` 直接增删这一个 child，骨架结束时
                    // 它插到 index 0，下面那棵 SafeArea 就从 0 挪到 1 —— 两个
                    // 都没 key，Flutter 认为对不上，整棵重建：Hero 重新 startFlight，
                    // 封面被 placeholder 顶掉再显示，就是详情页封面「闪一下」。
                    // 推荐页的条目没有 summary / 评分分布，进来必然走这段刷新，
                    // 所以只有从推荐页进详情才看得见（时间表、收藏的数据是全的）。
                    //
                    // 用 Offstage 而不是一直画：这块背景是全屏 ImageFilter.blur，
                    // 骨架期间不画它，既省掉转场中的模糊开销（#2058 原本的用意），
                    // 又保住元素位置不变。
                    return Stack(
                      children: [
                        Positioned.fill(
                          bottom: tabBand,
                          child: Offstage(
                            offstage: showBangumiInfoSkeleton,
                            child: IgnorePointer(
                              child: _InfoHeaderBackground(
                                imageUrl: infoController
                                        .bangumiItem.images['large'] ??
                                    '',
                              ),
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
            commentsHasLoaded: commentsHasLoaded,
            charactersQueryTimeout: charactersQueryTimeout,
            charactersIsEmpty: charactersIsEmpty,
            staffQueryTimeout: staffQueryTimeout,
            staffIsEmpty: staffIsEmpty,
            loadMoreComments: loadMoreComments,
            loadCharacters: loadCharacters,
            loadStaff: loadStaff,
            commentsList: infoController.commentsList.toList(growable: false),
            commentsIsLoading: commentsIsLoading,
            onWriteReview: _openReviewEditor,
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
      floatingActionButton: KazumiGlass.floatingButton(
        context: context,
        aboveTabBar: false,
        child: FloatingActionButton.extended(
          tooltip: '开始观看',
          onPressed: _startWatching,
          label: const Text('开始观看'),
          icon: const Icon(Icons.play_arrow_rounded),
        ),
      ),
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

/// 折叠时才出现的顶栏内容（标题）。
///
/// 为什么不用 [SliverAppBar.medium] 那套：medium / large 的工具栏标题只是
/// 一个「内容滚到顶栏下面时」才淡入的副本，真正的展开态标题由它自己的弹性空间
/// 渲染 —— 而详情页要用自定义 background，把它整个覆盖掉了。于是就成了：
/// 外层折叠完、内层列表还停在顶部时它淡出，往上滑才又出现，松手就没了。
///
/// 这里跟着**折叠进度**走：展开时透明，折叠过半淡入，折叠完成一直显示。
/// 不用 innerBoxIsScrolled 判断：那是「内层列表有没有滚」，外层折叠完、内层
/// 列表回到顶部时标题就会跟着消失。
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
