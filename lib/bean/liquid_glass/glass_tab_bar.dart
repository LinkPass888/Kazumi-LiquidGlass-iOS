import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';

/// 详情页顶部那一排标签（概览 / 吐槽 / 角色 / 关联 / 制作人员）。
///
/// 和首页底部标签栏同一套语言：整条玻璃浮在内容之上 —— 左右各让开一段，
/// 圆角和屏幕圆角同心；选中项、按住时都是一块深色填充，四周留白等宽，
/// 底下没有 Material 标签栏那条会跟着滑动的下划线。一行放不下可以左右滑。
///
/// 这一条的总高度和原来的 Material 标签栏一样（[kTextTabBarHeight]），
/// 所以换成玻璃之后，它和上面顶栏的间距一点没变。
///
/// 总开关（[KazumiGlass.enabled]）关掉时退回 Material 的 [TabBar]，
/// 外观和以前完全一样。
class KazumiGlassTabBar extends StatelessWidget implements PreferredSizeWidget {
  const KazumiGlassTabBar({
    super.key,
    required this.controller,
    required this.tabs,
  });

  final TabController controller;
  final List<String> tabs;

  /// 这一条占掉的高度：和原来的 Material 标签栏一致，间距不会变。
  static const double barHeight = kTextTabBarHeight;

  /// 当前实际占掉的高度。
  static double heightOf(BuildContext context) => barHeight;

  @override
  Size get preferredSize => const Size.fromHeight(barHeight);

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
      // 左右让开一段（和首页底部标签栏同一套语言）；上下不留，高度不额外增加
      padding: const EdgeInsets.symmetric(
        horizontal: KazumiGlass.floatingBarInset,
      ),
      child: KazumiGlass.floatingBar(
        context: context,
        // 玻璃内部留白：横向条目自己再补一半，加起来正好也是 6
        padding: KazumiGlass.floatingBarPadding,
        // 高度必须自己钉死：AppBar 把 bottom 放进一个 Column，而 Column 给子项的
        // 是「竖直方向无上限」的约束，不钉的话里面那一行（stretch）会去要无限
        // 高度，真机上直接崩。
        child: SizedBox(
          height: barHeight - KazumiGlass.floatingBarPadding.vertical,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const ClampingScrollPhysics(),
                child: ConstrainedBox(
                  // 一行放得下就居中，放不下才能左右滑
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: _GlassTabItems(
                    controller: controller,
                    tabs: tabs,
                    // 这一行能用的宽度（已经扣掉玻璃自己的左右留白）
                    availableWidth: constraints.maxWidth,
                  ),
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
  const _GlassTabItems({
    required this.controller,
    required this.tabs,
    required this.availableWidth,
  });

  final TabController controller;
  final List<String> tabs;

  /// 玻璃条里给这一行的宽度（不含玻璃自己的留白）。
  final double availableWidth;

  /// 文字左右的呼吸（不含两边各 [KazumiGlass.floatingBarGap] / 2 的外边距）。
  static const double _labelPadding = 14;

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
    // 一行放得下时，把富余平均分给每个按钮：这样深色填充的四边才是等宽的
    // —— 离玻璃左右边、离玻璃上下边、相邻两块之间，全是
    // [KazumiGlass.floatingBarGap]。不分的话整行是居中的，最左最右那两块
    // 离玻璃边会比上下宽出一截。
    double contentWidth = 0;
    for (int index = 0; index < tabs.length; index++) {
      contentWidth += _itemWidth(
        context,
        index: index,
        selected: index == selected,
        textScaler: textScaler,
      );
    }
    final double extra = availableWidth.isFinite
        ? math.max(0, availableWidth - contentWidth) / tabs.length
        : 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      // 撑满玻璃内高，深色填充才是整条的高度（而不是只包住文字）
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int index = 0; index < tabs.length; index++)
          _item(
            context,
            index: index,
            selected: index == selected,
            textScaler: textScaler,
            extra: extra,
          ),
      ],
    );
  }

  /// 文字用的样式：和 [_item] 里渲染的完全一样，量宽度才不会差。
  TextStyle _labelStyle(BuildContext context, {required bool selected}) {
    final ThemeData theme = Theme.of(context);
    final TextStyle baseStyle = theme.textTheme.labelLarge ?? const TextStyle();
    return baseStyle.copyWith(
      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
    );
  }

  /// 条目（含自己的外边距和内边距）在 [extra] 为 0 时的宽度。
  double _itemWidth(
    BuildContext context, {
    required int index,
    required bool selected,
    required TextScaler textScaler,
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: tabs[index],
        style: _labelStyle(context, selected: selected),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textScaler: textScaler,
    )..layout();
    final double width = painter.width;
    painter.dispose();
    return width + KazumiGlass.floatingBarGap + _labelPadding * 2;
  }

  Widget _item(
    BuildContext context, {
    required int index,
    required bool selected,
    required TextScaler textScaler,
    required double extra,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      // 玻璃那边给了 3，这里再补 3：离玻璃边框 6，相邻两块之间也是 3 + 3 = 6
      padding: const EdgeInsets.symmetric(
        horizontal: KazumiGlass.floatingBarGap / 2,
      ),
      child: KazumiGlass.barSegment(
        context: context,
        onTap: () => controller.animateTo(index),
        selected: selected,
        // 竖向留白交给玻璃统一给，这里只留文字左右的呼吸
        // 富余的一半补在这里，填充变宽、文字仍然居中
        padding: EdgeInsets.symmetric(horizontal: _labelPadding + extra / 2),
        child: Text(
          tabs[index],
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textScaler: textScaler,
          style: _labelStyle(context, selected: selected).copyWith(
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
