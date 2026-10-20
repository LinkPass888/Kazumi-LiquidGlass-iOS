import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/bean/widget/collect_button.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/date_time.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/timeline/timeline_controller.dart';
import 'package:kazumi/services/bangumi_update_times.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/bangumi_timeline_store.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:skeletonizer/skeletonizer.dart';

// 视频卡片 - 水平布局
class BangumiInfoCardV extends StatefulWidget {
  const BangumiInfoCardV({
    super.key,
    required this.bangumiItem,
    required this.isLoading,
    required this.showRating,
  });

  final BangumiItem bangumiItem;
  final bool isLoading;
  final bool showRating;

  /// 详情页顶栏给卡片留的最大宽度，与页面里的 Padding 和卡片的
  /// [BoxConstraints.maxWidth] 一致。
  static const double _maxWidth = 950;

  /// 页面给卡片的左右内边距（info_page.dart 的 EdgeInsets.fromLTRB）。
  static const double horizontalInset = 16;

  /// 封面那一列的宽高比：宽度定下来，高度就定了。
  static const double _coverAspectRatio = 0.65;

  /// 封面和右侧信息之间的间距。
  static const double _coverGap = 16;

  static String _titleOf(BangumiItem item) =>
      item.nameCn.trim().isEmpty ? item.name.trim() : item.nameCn.trim();

  /// 标题在给定宽度、指定行数下的高度。
  static double _measureTitle(
    BuildContext context,
    BangumiItem item,
    int maxLines,
  ) {
    final width = math.min(
      MediaQuery.sizeOf(context).width - horizontalInset * 2,
      _maxWidth,
    );
    final text = _titleOf(item);
    return (TextPainter(
      text: TextSpan(
        text: text.isEmpty ? ' ' : text,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      maxLines: maxLines,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: width))
        .height;
  }

  /// 卡片总高度。标题换行时整体加高，封面、条目信息、概览吐槽按钮跟着一起
  /// 下移，与标题始终隔着 [_verticalGap]。详情页的 SliverAppBar 用同一函数
  /// 算 expandedHeight，两边始终一致。
  ///
  /// 高度由内容驱动：标题（按实际换行）+ [_verticalGap] + 封面行高。封面行高
  /// 由宽度推出（见 [_coverRowHeight]），不再写死，卡片下缘到「概览/吐槽」
  /// 标签的距离于是恒为 [info_page] 里那段固定留白，不会因为封面比卡片矮而
  /// 多出一段空。[showRating] / [isLoading] 决定是否计入「评分透视」那一列，
  /// 必须与 build 时一致，封面行高才和卡片总高对得上。
  static double heightFor(
    BuildContext context,
    BangumiItem item, {
    required bool showRating,
    required bool isLoading,
  }) {
    return _measureTitle(context, item, 2) +
        _verticalGap +
        _coverRowHeight(context, showRating: showRating, isLoading: isLoading);
  }

  /// 封面那一行的高度：和 build 里 LayoutBuilder 的算法一致，按宽度推。
  ///
  /// 封面是「宽高比 0.65」定尺寸的：行里除了 16 的间距，其余都是弹性子项
  /// （封面、文字列、可选的评分透视），所以封面那一份宽度 =（行宽 − 间距）/
  /// 弹性子项个数，高度 = 宽度 / 0.65。这里不算「最多不超过行高」那一支：
  /// 卡片总高本来就由封面行高决定，行高不会再反过来压它。
  static double _coverRowHeight(
    BuildContext context, {
    required bool showRating,
    required bool isLoading,
  }) {
    final width = math.min(
      MediaQuery.sizeOf(context).width - horizontalInset * 2,
      _maxWidth,
    );
    final share = (width - _coverGap) /
        (_showVoteChart(context, showRating: showRating, isLoading: isLoading)
            ? 3
            : 2);
    return share / _coverAspectRatio;
  }

  /// 右侧的「评分透视」要不要显示：宽屏 + 有评分 + 不是骨架屏。
  /// 静态副本供 [heightFor] 在还没有 State 时预判同一结论。
  static bool _showVoteChart(
    BuildContext context, {
    required bool showRating,
    required bool isLoading,
  }) =>
      showRating &&
      MediaQuery.sizeOf(context).width >= LayoutBreakpoint.compact['width']! &&
      !isLoading;

  /// 标题、内容块之间的竖向间距。
  static const double _verticalGap = 10;

  @override
  State<BangumiInfoCardV> createState() => _BangumiInfoCardVState();
}

class _BangumiInfoCardVState extends State<BangumiInfoCardV> {
  int touchedIndex = -1;

  /// 放送星期 1 = 星期一 ... 7 = 星期日（用户手动设置的，没设过就用开播日）
  late int weekday;

  /// 是否在时间表对应放送星期展示
  late bool showInTimeline;

  @override
  void initState() {
    super.initState();
    _loadTimelineEntry();
    _loadUpdateInfo();
  }

  @override
  void didUpdateWidget(covariant BangumiInfoCardV oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bangumiItem.id != widget.bangumiItem.id) {
      _loadTimelineEntry();
      _loadUpdateInfo();
    }
  }

  void _loadTimelineEntry() {
    final entry = BangumiTimelineStore.entryOf(widget.bangumiItem.id);
    // 显示值和合并时同源，都是 [resolveTimelineWeekdays] 认的那种「用户
    // 选过的星期」：
    // 1. 用户在本页点选过星期 —— 记在条目的 weekdayCustom 上；
    // 2. 没点选过就用时间表里这部番实际所在的那一列（bangumi 日历的
    //    原分组），这样两处写的永远是同一个星期；
    // 3. 时间表还没加载过（日历是空的）才退回条目里的默认值。
    //
    // 不能直接用条目的 weekday：只点亮过「在时间表展示」时它会连开播日
    // 这种默认值一起写进去，拿它显示会和番实际所在的列对不上。
    int? timelineWeekday;
    try {
      timelineWeekday =
          inject<TimelineController>().timelineWeekdayOf(widget.bangumiItem.id);
    } catch (error) {
      KazumiLogger().w('Timeline controller not found', error: error);
    }
    weekday = (entry != null && entry.weekdayCustom ? entry.weekday : null) ??
        timelineWeekday ??
        (entry?.weekday ?? normalizeBangumiWeekday(widget.bangumiItem.airWeekday));
    showInTimeline = entry?.showInTimeline ?? false;
  }

  CollectController? get _collectController {
    try {
      return inject<CollectController>();
    } catch (error) {
      KazumiLogger().w('Collect controller not found', error: error);
      return null;
    }
  }

  /// 详情页改动后让时间表立即生效
  void _refreshTimeline() {
    try {
      inject<TimelineController>().refreshCustomTimelineEntries();
    } catch (error) {
      KazumiLogger().w('Refresh timeline entries failed', error: error);
    }
  }

  Future<void> _showWeekdayPicker() async {
    final selected = await KazumiDialog.show<int>(
      builder: (context) {
        return KazumiAlert(
          // 收窄成正方形：宽高都给死，按钮 2 个一行
          constraints: const BoxConstraints.tightFor(width: 260, height: 260),
          title: const Center(
            child: Text('选择放送星期'),
          ),
          content: Wrap(
            // 居中分布：左右余量相等，两侧离边框的距离就一样
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (int index = 1; index <= 7; index++)
                // 尺寸写死：Wrap 里不指定大小会按内容分散，
                // 靠 padding 撑不出统一尺寸，必须给死宽高（和详情页收藏按钮一致）
                SizedBox(
                  width: 96,
                  height: 40,
                  child: KazumiGlass.glassButton(
                    context: context,
                    padding: EdgeInsets.zero,
                    selected: index == weekday,
                    onTap: () {
                      KazumiDialog.dismiss<int>(popWith: index);
                    },
                    child: Text(weekdayCnLabel(index)),
                  ),
                ),
            ],
          ),
          // 不留「取消」按钮：点外面即取消，弹窗也更紧凑。
        );
      },
    );
    if (!mounted || selected == null || selected == weekday) {
      return;
    }
    await BangumiTimelineStore.setWeekday(widget.bangumiItem.id, selected);
    if (!mounted) {
      return;
    }
    setState(() {
      weekday = normalizeBangumiWeekday(selected);
    });
    _refreshTimeline();
    // 日历里已经在播的番，改星期就直接换列了；只有它本来不在时间表里时
    // 才需要用户再点亮图标加进来。
    var inTimeline = false;
    try {
      inTimeline = inject<TimelineController>()
          .isInTimeline(widget.bangumiItem.id);
    } catch (error) {
      KazumiLogger().w('Timeline controller not found', error: error);
    }
    if (!inTimeline) {
      KazumiDialog.showToast(
        message: '已设置放送星期，点亮右侧图标后即可在时间表展示',
      );
    }
  }

  Future<void> _setShowInTimeline(bool value) async {
    if (value) {
      final collectType =
          _collectController?.getCollectType(widget.bangumiItem) ?? 0;
      if (!bangumiKeepsTimelineEntry(collectType)) {
        final confirmed = await _confirmMarkWatching();
        if (!mounted || !confirmed) {
          return;
        }
        final controller = _collectController;
        if (controller == null) {
          return;
        }
        await controller.addCollect(
          widget.bangumiItem,
          type: CollectType.watching.value,
        );
        if (!mounted) {
          return;
        }
      }
    }
    await BangumiTimelineStore.setShowInTimeline(
      widget.bangumiItem.id,
      value,
      weekday: weekday,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      showInTimeline = value;
    });
    _refreshTimeline();
  }

  /// 开启前确认把番剧标记为「在看」
  Future<bool> _confirmMarkWatching() async {
    final confirmed = await KazumiDialog.show<bool>(
      builder: (context) {
        return KazumiAlert(
          title: const Text('在时间表展示'),
          content: const Text('该功能需要番剧处于「在看」状态，是否标记为在看并开启？'),
          actions: [
            TextButton(
              onPressed: () {
                KazumiDialog.dismiss<bool>(popWith: false);
              },
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                KazumiDialog.dismiss<bool>(popWith: true);
              },
              child: const Text('标记并开启'),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  /// 更新时间数据异步到达后重建一次，让放送时间/进度显示出来。
  /// ensureLoaded 是共享的，已加载过时立即返回，不会重复下载。
  void _loadUpdateInfo() {
    final service = BangumiUpdateTimesService.instance;
    final id = widget.bangumiItem.id;
    service.ensureLoaded().then((_) async {
      if (mounted) setState(() {});
      // 两季数据就绪后只为这一部补 AniList 实测值（总集数/准确进度）。
      await service.ensureAniListLoaded([id]);
      if (mounted) setState(() {});
    });
  }

  /// 「20:00」，推不出更新时刻时返回 null。
  ///
  /// 星期和时刻分开取，和时间表的规则一致：
  /// - **星期**来自手动设置的放送星期，也就是时间表分组用的那一天
  ///   （见 [weekday] 和 [TimelineController.timelineWeekdayOf]）；
  /// - **时刻**来自 [BangumiUpdateTimesService.timelineUpdateEpoch]，
  ///   AniList 实测优先、bangumi-mal 兜底。
  ///
  /// 不能拿时刻反推星期：AniList 跟的是先行配信，bangumi 跟的是电视
  /// 放送，同一条目可以差好几天，反推会出现「详情页写周六、时间表排在
  /// 周一」。
  String? get _broadcastTime {
    final epoch = BangumiUpdateTimesService.instance
        .timelineUpdateEpoch(widget.bangumiItem.id);
    if (epoch == null) return null;
    final time = DateTime.fromMillisecondsSinceEpoch(epoch);
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
  }

  /// 「03/12」，总集数未知时为「03/??」；没有进度返回 null。
  String? get _updateProgress {
    final service = BangumiUpdateTimesService.instance;
    if (!service.isRecentSeason(widget.bangumiItem.id)) return null;
    final current = service.currentEpisode(widget.bangumiItem.id);
    if (current == null) return null;
    final total = service.totalEpisodes(widget.bangumiItem.id);
    final currentText = current.toString().padLeft(2, '0');
    final totalText =
        total == null ? '??' : total.toString().padLeft(2, '0');
    return '$currentText/$totalText';
  }

  Widget get voteBarChart {
    return Flexible(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '  评分透视:',
          ),
          SizedBox(height: 16),
          AspectRatio(
            aspectRatio: 2,
            child: BarChart(
              duration: Duration(milliseconds: 80),
              BarChartData(
                // alignment: BarChartAlignment.spaceEvenly,
                borderData: FlBorderData(show: false),
                gridData: FlGridData(show: false),
                barTouchData: BarTouchData(
                  touchCallback: (FlTouchEvent event, barTouchResponse) {
                    setState(() {
                      if (!event.isInterestedForInteractions ||
                          barTouchResponse == null ||
                          barTouchResponse.spot == null) {
                        touchedIndex = -1;
                        return;
                      }
                      touchedIndex =
                          barTouchResponse.spot!.touchedBarGroupIndex;
                    });
                  },
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) =>
                        Theme.of(context).colorScheme.inverseSurface,
                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                      var percentage =
                          widget.bangumiItem.votesCount[groupIndex] /
                              widget.bangumiItem.votes *
                              100;
                      return BarTooltipItem(
                        '${percentage.toStringAsFixed(2)}% (${widget.bangumiItem.votesCount[groupIndex]}人)',
                        TextStyle(
                            color:
                                Theme.of(context).colorScheme.onInverseSurface),
                      );
                    },
                  ),
                ),
                barGroups: List<BarChartGroupData>.generate(
                  10,
                  (i) => BarChartGroupData(
                    x: i + 1,
                    barRods: [
                      BarChartRodData(
                        toY: widget.bangumiItem.votesCount[i].toDouble(),
                        color: touchedIndex == i
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).disabledColor,
                        width: 20,
                        borderRadius:
                            BorderRadius.vertical(top: Radius.circular(5)),
                      )
                    ],
                    // showingTooltipIndicators: [0],
                  ),
                ),
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      getTitlesWidget: (value, meta) => SideTitleWidget(
                        meta: meta,
                        space: 10,
                        child: Text(value.toInt().toString()),
                      ),
                    ),
                  ),
                  topTitles: const AxisTitles(),
                  leftTitles: const AxisTitles(),
                  rightTitles: const AxisTitles(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 右侧的「评分透视」要不要显示：宽屏 + 有评分 + 不是骨架屏。
  bool _showVoteChart(BuildContext context) =>
      BangumiInfoCardV._showVoteChart(
        context,
        showRating: widget.showRating,
        isLoading: widget.isLoading,
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      height: BangumiInfoCardV.heightFor(
        context,
        widget.bangumiItem,
        showRating: widget.showRating,
        isLoading: widget.isLoading,
      ),
      constraints: const BoxConstraints(
        maxWidth: BangumiInfoCardV._maxWidth,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.bangumiItem.nameCn == ''
                ? widget.bangumiItem.name
                : (widget.bangumiItem.nameCn),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: BangumiInfoCardV._verticalGap),
          Expanded(
            child: LayoutBuilder(builder: (context, rowConstraints) {
              // 封面是「宽高比 0.65」定尺寸的：行里除了 16 的间距，其余都是弹性
              // 子项（封面、文字列、可选的评分透视），所以封面那一份宽度 =
              // （行宽 - 间距）/ 弹性子项个数，高度 = 宽度 / 0.65、最多不超过
              // 这一行的高。右下角那个收藏按钮要跟封面底边平齐 —— 右侧文字列
              // 的高度就得是这一份高度（原来撑满整行，按钮比封面底边低了小半格）。
              final double share =
                  (rowConstraints.maxWidth - BangumiInfoCardV._coverGap) /
                      (_showVoteChart(context) ? 3 : 2);
              final double coverHeight = math.min(
                share / BangumiInfoCardV._coverAspectRatio,
                rowConstraints.maxHeight,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: AspectRatio(
                      aspectRatio: BangumiInfoCardV._coverAspectRatio,
                      child: LayoutBuilder(builder: (context, boxConstraints) {
                        final double maxWidth = boxConstraints.maxWidth;
                        final double maxHeight = boxConstraints.maxHeight;
                        return Hero(
                          transitionOnUserGestures: true,
                          flightShuttleBuilder:
                              NetworkImgLayer.heroFlightShuttleBuilder,
                          createRectTween: NetworkImgLayer.heroRectTween,
                          tag: widget.bangumiItem.id,
                          child: NetworkImgLayer(
                            src: widget.bangumiItem.images['large'] ?? '',
                            width: maxWidth,
                            height: maxHeight,
                            fadeInDuration: const Duration(milliseconds: 0),
                            fadeOutDuration: const Duration(milliseconds: 0),
                          ),
                        );
                      }),
                    ),
                  ),
                  SizedBox(width: BangumiInfoCardV._coverGap),
                  Flexible(
                    child: SizedBox(
                      // 和封面一样高：收藏按钮的底部于是和封面底部齐平
                      height: coverHeight,
                      child: Skeletonizer(
                        enabled: widget.isLoading,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Shrink under large system font so the collect button
                            // stays inside the fixed-height card.
                            Flexible(
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.only(bottom: 8),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.topLeft,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '放送开始:',
                                      ),
                                      Text(
                                        widget.bangumiItem.airDate == ''
                                            ? '2000-11-11' // Skeleton Loader 占位符
                                            : widget.bangumiItem.airDate,
                                        style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                        ),
                                      ),
                                      // 放送时间：星期可点（换列），右边是时间表
                                      // 开关。「更新进度」作为另一行留着。
                                      if (!widget.isLoading) ...[
                                        const SizedBox(height: 4),
                                        // 星期、时刻、时间表开关在同一行：
                                        // 它们都是「几点播」这件事的一部分。
                                        const Text('放送时间:'),
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            // 星期就在时刻前面，点它换放送星期。
                                            InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              onTap: () =>
                                                  _showWeekdayPicker(),
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 2,
                                                  vertical: 2,
                                                ),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      weekdayCnLabel(weekday),
                                                      style: TextStyle(
                                                        fontSize: 20,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .primary,
                                                      ),
                                                    ),
                                                    Icon(
                                                      Icons.expand_more_rounded,
                                                      size: 20,
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .primary,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            if (_broadcastTime != null)
                                              Text(
                                                _broadcastTime!,
                                                style: TextStyle(
                                                  fontSize: 20,
                                                  fontWeight: FontWeight.bold,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary,
                                                ),
                                              ),
                                            const SizedBox(width: 6),
                                            // 时间表 Tab 的图标：点亮即在时间表展示。
                                            Tooltip(
                                              message: '在时间表展示',
                                              child: InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(
                                                        KazumiGlass.radiusOf(
                                                            context)),
                                                onTap: () =>
                                                    _setShowInTimeline(
                                                        !showInTimeline),
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.all(6),
                                                  // 底部时间表 Tab 的符号（SF
                                                  // `calendar`）；选中态只换
                                                  // 颜色，和 Tab 栏一致。
                                                  child: Icon(
                                                    CupertinoIcons.calendar,
                                                    size: 24,
                                                    color: showInTimeline
                                                        ? Theme.of(context)
                                                            .colorScheme
                                                            .primary
                                                        : Theme.of(context)
                                                            .colorScheme
                                                            .outline,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                      if (!widget.isLoading && _updateProgress != null) ...[
                                        const SizedBox(height: 4),
                                        Text('更新进度:'),
                                        Text(
                                          _updateProgress!,
                                          style: TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 8),
                                      Text(
                                        widget.showRating
                                            ? '${widget.bangumiItem.votes} 人评分:'
                                            : '*** 人评分:',
                                      ),
                                      if (widget.isLoading)
                                        // Skeleton Loader 占位符
                                        Text(
                                          '10.0 ********',
                                          style: TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                          ),
                                        ),
                                      if (!widget.isLoading)
                                        Row(
                                          children: [
                                            Text(
                                              widget.showRating
                                                  ? '${widget.bangumiItem.ratingScore}'
                                                  : '***',
                                              style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .primary,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            RatingBarIndicator(
                                              itemCount: 5,
                                              rating: widget.showRating
                                                  ? widget.bangumiItem
                                                          .ratingScore
                                                          .toDouble() /
                                                      2
                                                  : 0,
                                              itemBuilder: (context, index) =>
                                                  Icon(
                                                Icons.star_rounded,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .primary,
                                              ),
                                              itemSize: 20.0,
                                            ),
                                          ],
                                        ),
                                      SizedBox(height: 8),
                                      Text(
                                        'Bangumi Ranked:',
                                      ),
                                      Text(
                                        widget.showRating
                                            ? '#${widget.bangumiItem.rank}'
                                            : '***',
                                        style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 120,
                              height: 40,
                              child: CollectButton.extend(
                                bangumiItem: widget.bangumiItem,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_showVoteChart(context)) voteBarChart,
                ],
              );
            }),
          ),
        ],
      ),
    );
  }
}
