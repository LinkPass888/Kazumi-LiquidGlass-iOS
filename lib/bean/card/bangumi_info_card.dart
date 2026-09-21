import 'package:flutter/material.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/collect_button.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/date_time.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/timeline/timeline_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/bangumi_timeline_store.dart';
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

  @override
  State<BangumiInfoCardV> createState() => _BangumiInfoCardVState();
}

class _BangumiInfoCardVState extends State<BangumiInfoCardV> {
  int touchedIndex = -1;

  /// 放送星期 1 = 星期一 ... 7 = 星期日
  late int weekday;

  /// 是否在时间表对应放送星期展示
  late bool showInTimeline;

  @override
  void initState() {
    super.initState();
    _loadTimelineEntry();
  }

  @override
  void didUpdateWidget(covariant BangumiInfoCardV oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bangumiItem.id != widget.bangumiItem.id) {
      _loadTimelineEntry();
    }
  }

  void _loadTimelineEntry() {
    final entry = BangumiTimelineStore.entryOf(widget.bangumiItem.id);
    weekday = entry?.weekday ??
        normalizeBangumiWeekday(widget.bangumiItem.airWeekday);
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
        return AlertDialog(
          // 收窄成正方形：宽高都给死，按钮 2 个一行
          constraints: const BoxConstraints.tightFor(width: 260, height: 260),
          title: const Text('选择放送星期'),
          content: Wrap(
            // 居中分布：左右余量相等，两侧离边框的距离就一样
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (int index = 1; index <= 7; index++)
                // 尺寸写死：原生玻璃视图在 Wrap 里会被撑到可用宽度，
                // 靠 padding 撑不出大小，必须给死宽高（和详情页收藏按钮一致）
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
          // 按用户要求不留「取消」按钮：点外面即取消，弹窗也更紧凑。
          // 弹窗本体保持原来的不透明背景，标题不会再被挤出。
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
    if (!showInTimeline) {
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
        return AlertDialog(
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

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 356,
      constraints: BoxConstraints(maxWidth: 950),
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
          SizedBox(height: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: AspectRatio(
                    aspectRatio: 0.65,
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
                SizedBox(width: 16),
                Flexible(
                  child: Skeletonizer(
                    enabled: widget.isLoading,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
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
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text('放送星期:'),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: widget.isLoading
                                      ? null
                                      : () => _showWeekdayPicker(),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
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
                                            fontWeight: FontWeight.bold,
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
                                const SizedBox(width: 6),
                                Tooltip(
                                  message: '在时间表展示',
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(20),
                                    onTap: widget.isLoading
                                        ? null
                                        : () => _setShowInTimeline(
                                            !showInTimeline),
                                    child: Padding(
                                      padding: const EdgeInsets.all(6),
                                      child: Icon(
                                        showInTimeline
                                            ? Icons.timeline
                                            : Icons.timeline_outlined,
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
                            SizedBox(height: 8),
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
                                  color: Theme.of(context).colorScheme.primary,
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
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  RatingBarIndicator(
                                    itemCount: 5,
                                    rating: widget.showRating
                                        ? widget.bangumiItem.ratingScore
                                                .toDouble() /
                                            2
                                        : 0,
                                    itemBuilder: (context, index) => Icon(
                                      Icons.star_rounded,
                                      color:
                                          Theme.of(context).colorScheme.primary,
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
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ],
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
                if (widget.showRating &&
                    MediaQuery.sizeOf(context).width >=
                        LayoutBreakpoint.compact['width']! &&
                    !widget.isLoading)
                  voteBarChart,
              ],
            ),
          ),
        ],
      ),
    );
  }
}
