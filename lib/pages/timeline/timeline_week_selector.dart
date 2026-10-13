part of 'timeline_page.dart';

/// 时间表顶部那一排「星期」选择器。
///
/// 原来是 Material 的 [TabBar]：一条深色底板 + 会跟着滑动的下划线。这里换成
/// 一排各自成块的液态玻璃胶囊 —— 选中项是压在玻璃上的一块深色填充，四周留白
/// 和玻璃等宽，和首页底部标签栏、详情页标签栏是同一套语言。选中块跟着
/// [TabBarView] 的滑动进度走：滑过一半就换到相邻那颗（tween 出来的中间位置用
/// 四舍五入取整，不做两半平分——玻璃上的深色填充只有一个整块的观感才对）。
///
/// 每颗玻璃里的内容和原来一样：星期（今天标「今天」）与当天放送数量。
class _TimelineWeekSelector extends StatelessWidget {
  const _TimelineWeekSelector({
    required this.counts,
    this.todayIndex,
    this.isLoading = false,
  });

  final List<int> counts;
  final int? todayIndex;
  final bool isLoading;

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  /// 这一排按钮的总高。[_verticalTrim] 是从原来那版的 40 里收掉的量，
  /// 同时会把下面那张表整体上移同样的距离（见 timeline_page.dart 的 weekHeight）。
  static const double _verticalTrim = 8;

  static double heightFor(TextScaler scaler) =>
      40 - _verticalTrim + scaler.scale(20) + scaler.scale(16);

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    // TabBarView 用的就是外面这层 DefaultTabController。
    final controller = DefaultTabController.of(context);
    final Listenable listenable = controller.animation ?? controller;
    return SizedBox(
      height: heightFor(scaler),
      child: AnimatedBuilder(
        animation: listenable,
        builder: (context, _) {
          final double position =
              controller.animation?.value ?? controller.index.toDouble();
          final int selected =
              position.round().clamp(0, _weekdays.length - 1);
          return LayoutBuilder(builder: (context, constraints) {
            final minTabWidth = (scaler.scale(14) * 2 + 16).clamp(48.0, 112.0);
            final scrollable = constraints.maxWidth - 8 < minTabWidth * 7;
            final row = Row(
              // 撑满整条高度，玻璃胶囊才是整条的高度（而不是只包住文字）
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var day = 0; day < _weekdays.length; day++)
                  scrollable
                      ? SizedBox(
                          width: minTabWidth,
                          child: _dayButton(
                            context,
                            controller: controller,
                            day: day,
                            selected: selected,
                          ),
                        )
                      : Expanded(
                          child: _dayButton(
                            context,
                            controller: controller,
                            day: day,
                            selected: selected,
                          ),
                        ),
              ],
            );
            if (!scrollable) {
              return row;
            }
            // 一行放不下才左右滑，和原来的 TabBar 行为一致。
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: row,
            );
          });
        },
      ),
    );
  }

  Widget _dayButton(
    BuildContext context, {
    required TabController controller,
    required int day,
    required int selected,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final bool isSelected = day == selected;
    final Color labelColor =
        isSelected ? colors.primary : colors.onSurfaceVariant;
    return Padding(
      // 两颗玻璃之间留一点缝，免得胶囊挨在一起。
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
      child: KazumiGlass.glassButton(
        context: context,
        selected: isSelected,
        onTap: () => controller.animateTo(day),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Semantics(
          label: '星期${_weekdays[day]}'
              '${day == todayIndex ? '，今天' : ''}'
              '${isLoading ? '，加载中' : '，${counts[day]}部'}',
          excludeSemantics: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                day == todayIndex ? '今天' : '周${_weekdays[day]}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w700, color: labelColor),
              ),
              const SizedBox(height: 2),
              Text(
                isLoading ? '—' : '${counts[day]}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: theme.textTheme.labelSmall?.fontSize,
                  fontWeight: FontWeight.w500,
                  color: labelColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
