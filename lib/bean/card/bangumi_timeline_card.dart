import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/bangumi_update_times.dart';

class BangumiTimelineCard extends StatelessWidget {
  const BangumiTimelineCard({
    super.key,
    required this.bangumiItem,
    required this.showRating,
    required this.onTap,
    this.isWatching = false,
    this.compact = false,
    this.updateEpoch,
    this.currentEpisode,
  });

  final BangumiItem bangumiItem;
  final bool showRating;
  final VoidCallback onTap;
  final bool isWatching;
  final bool compact;

  /// 下一次更新时刻（epoch ms）。为空时不显示更新时间胶囊。
  final int? updateEpoch;

  /// 已更新到第几集，为空时不显示集数胶囊。
  final int? currentEpisode;

  static const _contentPadding = 12.0;
  // 时间表卡片的圆角保持原样（28 的外框 + 同心 16 的内封面），不跟全局屏幕圆角走。
  static const _cornerRadius = 28.0;
  static const _titleFontSize = 16.0;
  static const _titleLineHeight = 1.5;
  static const _labelFontSize = 12.0;
  static const _labelLineHeight = 4 / 3;
  static const _metadataGap = 8.0;
  static const _footerGap = 12.0;
  static const _pillIconSize = 16.0;
  static const _pillPadding =
      EdgeInsets.symmetric(horizontal: 10, vertical: 6);
  static const _pillGap = 8.0;

  // Shared by the grid and card to keep their text-scaled heights in sync.
  static double heightFor(TextScaler scaler, {bool compact = false}) {
    final titleHeight = scaler.scale(_titleFontSize) * _titleLineHeight * 2;
    final labelHeight = scaler.scale(_labelFontSize) * _labelLineHeight;
    final footerHeight =
        math.max(_pillIconSize, labelHeight) + _pillPadding.vertical;
    final contentHeight = math.max(
      compact ? 120.0 : 136.0,
      titleHeight + _metadataGap + labelHeight + _footerGap + footerHeight,
    );
    return _contentPadding * 2 + contentHeight;
  }

  String _supportingText(String title) {
    final tags = bangumiItem.metaTags.isNotEmpty
        ? bangumiItem.metaTags
        : bangumiItem.tags.map((tag) => tag.name);
    final metadata = tags
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();
    if (metadata.isNotEmpty) return metadata.take(3).join(' · ');
    final originalName = bangumiItem.name.trim();
    return originalName != title ? originalName : '';
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_cornerRadius),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height:
                heightFor(MediaQuery.textScalerOf(context), compact: compact),
            child: Padding(
              padding: const EdgeInsets.all(_contentPadding),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildCover(context),
                  SizedBox(width: compact ? 12 : 16),
                  Expanded(child: _buildDetails(context)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetails(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final translatedName = bangumiItem.nameCn.trim();
    final title =
        translatedName.isNotEmpty ? translatedName : bangumiItem.name.trim();
    final supportingText = _supportingText(title);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            color: colors.onSurface,
            fontSize: _titleFontSize,
            fontWeight: FontWeight.w700,
            height: _titleLineHeight,
          ),
        ),
        // 标签行：评分在最左，后面是标签。
        SizedBox(height: _metadataGap),
        Row(
          children: [
            if (showRating) ...[
              _buildRatingInline(context),
              if (supportingText.isNotEmpty) const SizedBox(width: 8),
            ],
            if (supportingText.isNotEmpty)
              Expanded(
                child: Text(
                  supportingText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontSize: _labelFontSize,
                    height: _labelLineHeight,
                  ),
                ),
              ),
          ],
        ),
        const Spacer(),
        const SizedBox(height: _footerGap),
        Row(
          children: [
            if (updateEpoch != null)
              Flexible(
                child: _buildPill(
                  context,
                  icon: Icons.schedule_rounded,
                  label: '${formatUpdateTime(updateEpoch)} 更新',
                ),
              ),
            if (updateEpoch != null && currentEpisode != null)
              const SizedBox(width: _pillGap),
            if (currentEpisode != null)
              Flexible(
                child: _buildPill(
                  context,
                  icon: Icons.playlist_play_rounded,
                  label: '第 $currentEpisode 话',
                ),
              ),
            if (isWatching) ...[
              const SizedBox(width: _pillGap),
              Tooltip(
                message: '正在追',
                child: Icon(Icons.bookmark_rounded,
                    size: 20, color: colors.primary),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// 评分在标签行左侧，不带胶囊背景：星标 + 分数。
  Widget _buildRatingInline(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final labelStyle = theme.textTheme.labelMedium?.copyWith(
      fontSize: _labelFontSize,
      height: _labelLineHeight,
    );
    if (bangumiItem.ratingScore <= 0) {
      return Text('暂无评分',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: labelStyle?.copyWith(color: colors.onSurfaceVariant));
    }
    final score = bangumiItem.ratingScore.toStringAsFixed(1);
    return Semantics(
      label: '评分 $score',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded,
              size: _pillIconSize, color: colors.primary),
          const SizedBox(width: 2),
          Text(
            score,
            maxLines: 1,
            style: labelStyle?.copyWith(
              color: colors.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  /// 底部信息胶囊：和原评分胶囊同款 StadiumBorder。
  Widget _buildPill(
    BuildContext context, {
    required IconData icon,
    required String label,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final labelStyle = theme.textTheme.labelMedium?.copyWith(
      fontSize: _labelFontSize,
      height: _labelLineHeight,
    );
    return Container(
      padding: _pillPadding,
      decoration: ShapeDecoration(
        color: colors.secondaryContainer,
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: _pillIconSize, color: colors.onSecondaryContainer),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: labelStyle?.copyWith(
                color: colors.onSecondaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCover(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final imageUrl = bangumiItem.images['large'] ?? '';
    return ExcludeSemantics(
      child: SizedBox(
        width: compact ? 80 : 88,
        child: LayoutBuilder(
          builder: (context, constraints) => Hero(
            tag: bangumiItem.id,
            transitionOnUserGestures: true,
            createRectTween: NetworkImgLayer.heroRectTween,
            child: ClipRRect(
              // 同心圆角：封面和外层卡片同圆心
              borderRadius: BorderRadius.circular(
                  _cornerRadius - _contentPadding),
              child: imageUrl.isEmpty
                  ? ColoredBox(
                      color: colors.surfaceContainerHighest,
                      child: Center(
                        child: Icon(Icons.movie_outlined,
                            color: colors.onSurfaceVariant),
                      ),
                    )
                  : NetworkImgLayer(
                      src: imageUrl,
                      width: constraints.maxWidth,
                      height: constraints.maxHeight,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
