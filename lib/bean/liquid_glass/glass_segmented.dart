import 'package:flutter/material.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';

/// [KazumiGlassSegmented] 里的一段。
class KazumiGlassSegment<T> {
  const KazumiGlassSegment({
    required this.value,
    required this.label,
    this.icon,
  });

  final T value;
  final String label;
  final IconData? icon;

  ButtonSegment<T> toButtonSegment() => ButtonSegment<T>(
        value: value,
        label: Text(label),
        icon: icon == null ? null : Icon(icon),
      );
}

/// 一排「N 选一」的分段按钮（排序方式这类）。
///
/// 和详情页标签栏、首页底部标签栏同一套语言：整条是浮起的玻璃，选中项是一块
/// 与玻璃同心的深色填充，四周留白等宽，底下没有 Material 那条会滑动的下划线。
///
/// 总开关（[KazumiGlass.enabled]）关掉时退回 Material 的 [SegmentedButton]，
/// 外观和以前完全一样。
class KazumiGlassSegmented<T> extends StatelessWidget {
  const KazumiGlassSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelected,
    this.height = 44,
  });

  final List<KazumiGlassSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onSelected;

  /// 玻璃条的高度。默认和顶栏按钮的 40 + 上下留白一样高。
  final double height;

  @override
  Widget build(BuildContext context) {
    if (!KazumiGlass.enabled) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<T>(
          selected: <T>{selected},
          onSelectionChanged: (Set<T> values) => onSelected(values.first),
          segments: <ButtonSegment<T>>[
            for (final KazumiGlassSegment<T> segment in segments)
              segment.toButtonSegment(),
          ],
        ),
      );
    }
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle baseStyle = theme.textTheme.labelLarge ?? const TextStyle();
    final TextScaler textScaler =
        MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2);
    return SizedBox(
      height: height,
      child: KazumiGlass.floatingBar(
        context: context,
        // 和详情页标签栏一样：玻璃四周先给 6，横向上条目再补一半，正好也是 6
        padding: KazumiGlass.floatingBarPadding,
        child: Row(
          children: <Widget>[
            for (final KazumiGlassSegment<T> segment in segments)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: KazumiGlass.floatingBarGap / 2,
                  ),
                  child: KazumiGlass.barSegment(
                    context: context,
                    onTap: () => onSelected(segment.value),
                    selected: segment.value == selected,
                    // 竖向留白交给玻璃统一给（条目撑满玻璃内高），这里只留
                    // 文字左右的呼吸
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (segment.icon != null) ...[
                          Icon(
                            segment.icon,
                            size: 18,
                            color: segment.value == selected
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            segment.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textScaler: textScaler,
                            style: baseStyle.copyWith(
                              fontWeight: segment.value == selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: segment.value == selected
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
