import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:kazumi/bean/widget/collect_button.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
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
