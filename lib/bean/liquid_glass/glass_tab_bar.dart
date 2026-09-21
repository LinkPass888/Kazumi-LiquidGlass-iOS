import 'package:flutter/material.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';

/// 详情页顶部那一排标签（概览 / 吐槽 / 角色 / 关联 / 制作人员）。
///
/// 和首页底部标签栏同一套语言：整条玻璃浮在内容之上 —— 左右各让开一段，
/// 圆角和屏幕圆角同心；选中项、按住时都是一块深色填充，底下没有 Material
/// 标签栏那条会跟着滑动的下划线。标签多了一行放不下，可以左右滑动。
///
/// 「设置 → 界面设置 → 液态玻璃」关掉玻璃时，退回 Material 的 [TabBar]，
/// 外观和以前完全一样。
class KazumiGlassTabBar extends StatelessWidget implements PreferredSizeWidget {
  const KazumiGlassTabBar({
    super.key,
    required this.controller,
    required this.tabs,
  });

  final TabController controller;
  final List<String> tabs;

  /// 玻璃条本身的高度。
  static const double barHeight = 44;

  /// 玻璃条上下的留白：上面留一点，下面留多一点，和正文分开。
  static const double topGap = 6;
  static const double bottomGap = 12;

  /// 这条玻璃在 [SliverAppBar.bottom] 槽里占掉的整段高度。
  static const double bandHeight = topGap + barHeight + bottomGap;

  /// 当前实际占掉的高度：关掉液态玻璃时退回 Material 标签栏的高度。
  static double heightOf(BuildContext context) =>
      KazumiGlass.enabled ? bandHeight : kTextTabBarHeight;

  @override
  Size get preferredSize =>
      Size.fromHeight(KazumiGlass.enabled ? bandHeight : kTextTabBarHeight);

  @override
  Widget build(BuildContext context) {
    if (!KazumiGlass.enabled) {
      return TabBar(
        controller: controller,
        isScrollable: true,
        tabAlignment: TabAlignment.center,
        dividerHeight: 0,
        tabs: tabs.map((String name) => Tab(text: name)).toList(),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KazumiGlass.floatingBarInset,
        topGap,
        KazumiGlass.floatingBarInset,
        bottomGap,
      ),
      child: KazumiGlass.floatingBar(
        context: context,
        // 条目自己还有 2 的间距，玻璃再补 4：左右留白和上下一样宽
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: SizedBox(
          height: barHeight,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const ClampingScrollPhysics(),
                child: ConstrainedBox(
                  // 一行放得下就居中，放不下才能左右滑
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: _GlassTabItems(controller: controller, tabs: tabs),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 玻璃条里的那一行标签。
///
/// 单独一个 widget：选中态要跟着滑动进度重画，这样每帧只重建这一行，外面的
/// 玻璃和滚动视图都不动。
class _GlassTabItems extends StatelessWidget {
  const _GlassTabItems({required this.controller, required this.tabs});

  final TabController controller;
  final List<String> tabs;

  @override
  Widget build(BuildContext context) {
    // 动画在的时候（TabBarView 已经在用这个 controller）跟着滑动进度重画；
    // 还没有动画时退化成监听 controller 自己，点了也要马上换选中项。
    final Listenable listenable = controller.animation ?? controller;
    return AnimatedBuilder(
      animation: listenable,
      builder: (BuildContext context, Widget? child) => _row(context),
    );
  }

  int get _selectedIndex {
    final Animation<double>? animation = controller.animation;
    final double value =
        animation == null ? controller.index.toDouble() : animation.value;
    return value.round().clamp(0, tabs.length - 1);
  }

  Widget _row(BuildContext context) {
    final int selected = _selectedIndex;
    final TextScaler textScaler =
        MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2);
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        for (int index = 0; index < tabs.length; index++)
          _item(
            context,
            index: index,
            selected: index == selected,
            textScaler: textScaler,
          ),
      ],
    );
  }

  Widget _item(
    BuildContext context, {
    required int index,
    required bool selected,
    required TextScaler textScaler,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle baseStyle =
        theme.textTheme.labelLarge ?? const TextStyle();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: KazumiGlass.barSegment(
        context: context,
        onTap: () => controller.animateTo(index),
        selected: selected,
        child: Text(
          tabs[index],
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textScaler: textScaler,
          style: baseStyle.copyWith(
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
