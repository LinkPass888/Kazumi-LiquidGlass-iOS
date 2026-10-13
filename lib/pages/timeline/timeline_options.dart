part of 'timeline_page.dart';

const _timelineOptionsTitle = '排序与筛选';

extension _TimelineSortLabel on TimelineSort {
  String get label => switch (this) {
        TimelineSort.popularity => '热度优先',
        TimelineSort.rating => '评分优先',
        TimelineSort.defaultOrder => '默认顺序',
      };
}

class _TimelineOptionsButton extends StatelessWidget {
  const _TimelineOptionsButton({
    required this.sort,
    required this.filterCount,
    required this.onPressed,
  });

  final TimelineSort sort;
  final int filterCount;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final summary = '${sort.label}，'
        '${filterCount > 0 ? '已启用 $filterCount 项筛选' : '未启用筛选'}';
    // Badge 默认用 error（很扎眼的大红点），这里换成应用自己的配色：
    // 只是个「有筛选生效」的提示，用主色就够了。
    final icon = Badge(
      isLabelVisible: filterCount > 0,
      label: Text('$filterCount'),
      backgroundColor: colors.primary,
      textColor: colors.onPrimary,
      child: const Icon(Icons.tune_rounded, size: 20),
    );
    // 和原版一样：排序方式直接写在按钮上（图标 + 当前排序名），不再只出一个
    // 图标让人点进去才知道现在按什么排。顶栏的默认动作是 40×40 的圆玻璃，装不下
    // 文字，所以这里用 [SysAppBarWideAction] + [KazumiGlass.barPill] 出一颗更宽
    // 的玻璃药丸，圆角跟着全局走（panelRadiusOf）。
    final label = Text(
      sort.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelLarge,
    );
    return SysAppBarWideAction(
      // 注意：SysAppBarWideAction 必须在最外层 —— SysAppBar 是按「动作的类型」
      // 判断要不要套 40×40 圆玻璃的，外面再包一层 Semantics，它就只看到 Semantics，
      // 照旧套圆玻璃，文字就被压出界了。
      child: Semantics(
        label: _timelineOptionsTitle,
        value: summary,
        button: true,
        onTap: onPressed,
        excludeSemantics: true,
        child: Tooltip(
          message: '$_timelineOptionsTitle：$summary',
          child: KazumiGlass.barPill(
            context: context,
            onPressed: onPressed,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                const SizedBox(width: 6),
                label,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TimelineOptionsSheet extends StatelessWidget {
  const _TimelineOptionsSheet({required this.controller});

  final TimelineController controller;

  @override
  Widget build(BuildContext context) {
    return Observer(builder: (context) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MaterialBottomSheetHeader(
            title: _timelineOptionsTitle,
            onClose: () => Navigator.of(context).pop(),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              // 底部让开浮起的玻璃标签栏。
              padding: materialBottomSheetContentPadding.add(
                  EdgeInsets.only(bottom: KazumiGlass.bottomInset(context))),
              children: [
                ContentSection(
                  title: '排序',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final option in TimelineSort.values)
                        ChoiceChip(
                          label: Text(option.label),
                          selected: controller.sort == option,
                          onSelected: (_) => controller.changeSort(option),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                ContentSection.group(
                  title: '显示范围',
                  children: [
                    SwitchListTile(
                      title: const Text('隐藏看过的番剧'),
                      value: controller.notShowWatchedBangumis,
                      onChanged: controller.setNotShowWatchedBangumis,
                    ),
                    SwitchListTile(
                      title: const Text('隐藏抛弃的番剧'),
                      value: controller.notShowAbandonedBangumis,
                      onChanged: controller.setNotShowAbandonedBangumis,
                    ),
                    SwitchListTile(
                      title: const Text('只看正在追的番剧'),
                      value: controller.onlyShowWatchingBangumis,
                      onChanged: controller.setOnlyShowWatchingBangumis,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    });
  }
}
