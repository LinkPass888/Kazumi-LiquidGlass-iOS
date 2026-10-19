part of 'collect_library_view.dart';

class _CollectCategories extends StatelessWidget {
  const _CollectCategories({
    super.key,
    required this.controller,
    required this.count,
  });

  final TabController controller;
  final int Function(CollectType?) count;

  @override
  Widget build(BuildContext context) {
    // 自己排一行玻璃按钮：TabBar 的选中填充和点击水波纹都按「标签区域」画，
    // 和玻璃不是一个尺寸，会大一圈也对不上形。选中态仍然由 [controller] 驱动，
    // 所以竖屏那张 TabBarView 还能照常跟手切换。
    return SizedBox(
      height: 40,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return ListView.separated(
            key: const PageStorageKey('collect-filter-strip'),
            scrollDirection: Axis.horizontal,
            itemCount: _collectCategories.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final type = _collectCategories[index];
              final selected = controller.index == index;
              return Semantics(
                selected: selected,
                inMutuallyExclusiveGroup: true,
                label: '${type?.label ?? '全部'}，${count(type)} 部',
                excludeSemantics: true,
                child: KazumiGlass.glassButton(
                  context: context,
                  selected: selected,
                  onTap: () => controller.animateTo(index),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    type?.label ?? '全部',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _CollectLayoutSwitch extends StatelessWidget {
  const _CollectLayoutSwitch({required this.value, required this.onChanged});

  final CollectLayout value;
  final ValueChanged<CollectLayout> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final surfaceRadius = KazumiGlass.radiusOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        for (final layout in [CollectLayout.cards, CollectLayout.list])
          Semantics(
            selected: value == layout,
            inMutuallyExclusiveGroup: true,
            child: IconButton.filledTonal(
              tooltip: '${layout.label}布局',
              isSelected: value == layout,
              onPressed: () => onChanged(layout),
              style: ButtonStyle(
                minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
                visualDensity: VisualDensity.standard,
                backgroundColor: WidgetStateProperty.resolveWith((states) =>
                    states.contains(WidgetState.selected)
                        ? colors.secondaryContainer
                        : colors.surfaceContainerLow),
                foregroundColor: WidgetStateProperty.resolveWith((states) =>
                    states.contains(WidgetState.selected)
                        ? colors.onSecondaryContainer
                        : colors.onSurfaceVariant),
                shape: WidgetStateProperty.resolveWith((states) =>
                    RoundedRectangleBorder(
                      borderRadius: states.contains(WidgetState.pressed)
                          ? BorderRadius.circular(12)
                          : states.contains(WidgetState.selected)
                              ? BorderRadius.circular(surfaceRadius)
                              : BorderRadiusDirectional.horizontal(
                                  start: Radius.circular(
                                      layout == CollectLayout.cards
                                          ? surfaceRadius
                                          : 8),
                                  end: Radius.circular(
                                      layout == CollectLayout.list
                                          ? surfaceRadius
                                          : 8),
                                ),
                    )),
                animationDuration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 200),
              ),
              icon: Icon(layout == CollectLayout.list
                  ? Icons.view_list_rounded
                  : Icons.grid_view_rounded),
            ),
          ),
      ],
    );
  }
}

class _CollectSortMenu extends StatelessWidget {
  const _CollectSortMenu({
    required this.value,
    required this.showLabel,
    required this.onChanged,
    required this.options,
  });

  final CollectSort value;
  final bool showLabel;
  final ValueChanged<CollectSort> onChanged;
  final List<CollectSort> options;

  @override
  Widget build(BuildContext context) {
    return KazumiMenuButton(
      // 面板铺真玻璃：菜单是开在收藏海报上的，半透明底色在海报上一眼就是「一块
      // 灰板」，和我们其它菜单不是一套。
      glass: true,
      menuChildren: [
        for (final sort in options)
          KazumiMenuItem(
            selected: value == sort,
            onPressed: () => onChanged(sort),
            label: sort.label,
          ),
      ],
      builder: (context, toggle) {
        return Tooltip(
          message: '排序：${value.label}',
          child: showLabel
              ? TextButton.icon(
                  onPressed: toggle,
                  style: TextButton.styleFrom(
                    foregroundColor:
                        Theme.of(context).colorScheme.onSurfaceVariant,
                    minimumSize: const Size(48, 48),
                  ),
                  icon: const Icon(Icons.sort_rounded, size: 20),
                  label: Text(value.label),
                )
              : IconButton(
                  onPressed: toggle,
                  icon: const Icon(Icons.sort_rounded),
                ),
        );
      },
    );
  }
}
