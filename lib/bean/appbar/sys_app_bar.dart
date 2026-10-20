import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/liquid_glass/glass_material.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/bean/liquid_glass/liquid_glass.dart';
import 'package:kazumi/bean/widget/embedded_native_control_area.dart';

/// 顶栏大标题的样式：字号与字重和推荐页的「热门番组」保持一致。
TextStyle appBarTitleStyle(BuildContext context) =>
    Theme.of(context).textTheme.headlineMedium!.copyWith(
          fontSize: 28,
          fontWeight: FontWeight.w700,
        );

/// 顶栏里的「宽动作」：图标 + 文字的自带玻璃药丸。
///
/// [SysAppBar] 会把每个 action 统一套进一层 40×40 的圆玻璃（图标居中）。
/// 带文字的按钮塞不进那个圆，所以用这个包一层放进 `actions`：SysAppBar 见到它会
/// 原样透传（不再套圆玻璃、也不再量成 40×40），玻璃由调用方自己用
/// [KazumiGlass.barPill] 出。
class SysAppBarWideAction extends StatelessWidget {
  const SysAppBarWideAction({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// 玻璃顶栏随内容滚动的进度（0 = 停在顶部，1 = 玻璃完全出现）。
///
/// 页面只要把这个 notifier 接到滚动上（见 [SysAppBar.scrollProgress]），
/// 顶栏就会按 iOS 的规矩「浮」出来：停在顶部时是透明的一行按钮，内容一滑到
/// 它底下，一层玻璃加一条发丝线就淡入，标题同时缩进栏里。
class KazumiScrollProgress extends ValueNotifier<double> {
  KazumiScrollProgress() : super(0);

  /// 滚动多少逻辑像素后玻璃完全出现。
  ///
  /// 取 56 而不是整段大标题的高度：手指刚一动，玻璃就该出现 —— 等标题整段
  /// 滚没了再出现，观感上顶栏是「迟到的」。
  static const double distance = 56;

  /// 用滚动位置更新进度。
  ///
  /// 内容不足一屏时 `maxScrollExtent` 为 0，此时滚动量为 0 或负（回弹），
  /// `clamp` 后仍是 0 —— 顶栏不会因为回弹闪一下玻璃。
  void updateFrom(ScrollMetrics metrics) {
    final double next = (metrics.pixels / distance).clamp(0.0, 1.0);
    if (next != value) value = next;
  }

  /// 直接按偏移量更新（给不产生常规 [ScrollMetrics] 的页面用）。
  void updateOffset(double offset) {
    final double next = (offset / distance).clamp(0.0, 1.0);
    if (next != value) value = next;
  }
}

/// 把页面里「最外层纵向滚动」的进度接到 [KazumiScrollProgress]。
///
/// 包在滚动视图**外面**即可，不用改控制器：
///
/// ```dart
/// KazumiScrollProgressObserver(
///   progress: progress,
///   child: CustomScrollView(...),
/// )
/// ```
///
/// 只认 `depth == 0` 的通知：`NestedScrollView` 里内层列表的滚动会带着
/// 更大的 depth 冒上来，那条不该驱动顶栏（外层还没滚完时，内层谈不上「滚到
/// 顶栏底下」）。横向列表同理，只取纵向轴。
class KazumiScrollProgressObserver extends StatelessWidget {
  const KazumiScrollProgressObserver({
    super.key,
    required this.progress,
    required this.child,
  });

  final KazumiScrollProgress progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical) {
          progress.updateFrom(notification.metrics);
        }
        return false;
      },
      child: child,
    );
  }
}

class SysAppBar extends StatelessWidget implements PreferredSizeWidget {
  final double? toolbarHeight;

  final Widget? title;

  final Color? backgroundColor;

  final double? elevation;

  final ShapeBorder? shape;

  final List<Widget>? actions;

  final Widget? leading;

  final double? leadingWidth;

  final PreferredSizeWidget? bottom;

  final bool needTopOffset;

  /// 滚动进度。提供时顶栏在内容滑到它下面之后才铺玻璃（iOS 的 scrolledUnder
  /// 行为）；为 null 时保持原来的样子 —— 一条透明栏，只让按钮各自带玻璃。
  ///
  /// 玻璃必须画在**页面内容之上**才采得到东西，而 AppBar 画在 body 之前。
  /// 所以这里不用 AppBar 自带的背景，而是在 body 上方叠一层（见
  /// [KazumiAppBarGlass]），页面把它们放进 `Scaffold.body` 的 Stack 里。
  final ValueListenable<double>? scrollProgress;

  /// 折叠后的小标题。为大标题提供时，滚动到玻璃出现后淡入。
  final Widget? collapsedTitle;

  const SysAppBar({
    super.key,
    this.toolbarHeight,
    this.title,
    this.backgroundColor,
    this.elevation,
    this.shape,
    this.actions,
    this.leading,
    this.leadingWidth,
    this.bottom,
    this.needTopOffset = true,
    this.scrollProgress,
    this.collapsedTitle,
  });

  /// 顶栏实际高度（不含状态栏）。
  double get _height => toolbarHeight ?? kToolbarHeight;

  @override
  Widget build(BuildContext context) {
    final List<Widget> acs = <Widget>[...?actions];
    // 顶栏不再整条铺玻璃，改成 iOS 26 的软渐进模糊，按钮各自带一层玻璃。
    // 返回键与右侧按钮统一成同样大小的圆形玻璃，图标居中，离边缘留白
    Widget? leadingWidget;
    if (leading != null) {
      leadingWidget = Center(
        child: KazumiGlass.buttonGlass(
          child: SizedBox(
            width: KazumiGlass.barButtonSize,
            height: KazumiGlass.barButtonSize,
            child: EmbeddedNativeControlArea(
              requireOffset: needTopOffset,
              child: leading!,
            ),
          ),
        ),
      );
    } else if (ModalRoute.of(context)?.impliesAppBarDismissal ?? false) {
      leadingWidget = Center(
        child: KazumiGlass.iconButton(
          context: context,
          icon: const Icon(Icons.arrow_back, size: 22),
          onPressed: () => context.maybePop(),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        ),
      );
    }
    final List<Widget> actionWidgets = <Widget>[];
    for (final Widget action in acs) {
      // 宽动作（图标 + 文字的自带玻璃药丸）原样透传：它的高度已经和圆玻璃一致
      // （KazumiGlass.barButtonSize），再套一层 40×40 会把文字压扁。
      if (action is SysAppBarWideAction || action is SizedBox) {
        actionWidgets.add(action);
        continue;
      }
      if (actionWidgets.isNotEmpty) {
        actionWidgets.add(const SizedBox(width: KazumiGlass.barButtonGap));
      }
      actionWidgets.add(
        KazumiGlass.buttonGlass(
          child: SizedBox(
            width: KazumiGlass.barButtonSize,
            height: KazumiGlass.barButtonSize,
            child: EmbeddedNativeControlArea(
              requireOffset: needTopOffset,
              child: action,
            ),
          ),
        ),
      );
    }
    if (actionWidgets.isNotEmpty) {
      actionWidgets.add(const SizedBox(width: KazumiGlass.barEdgeInset));
    }
    return AppBar(
      toolbarHeight: _height,
      scrolledUnderElevation: 0.0,
      // 会随滚动铺玻璃的顶栏必须自己完全透明：AppBar 的背景画在 body 之前，
      // 一旦是不透明的底色，body 里的内容就永远滑不到它下面，玻璃永远采不到
      // 东西（也永远只看到一块死板的面板）。
      backgroundColor:
          scrollProgress != null ? Colors.transparent : backgroundColor,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      title: title != null
          ? EmbeddedNativeControlArea(
              requireOffset: needTopOffset,
              child: title!,
            )
          : null,
      centerTitle: false,
      actions: actionWidgets,
      leading: leadingWidget,
      leadingWidth: leadingWidth ?? KazumiGlass.barLeadingWidth,
      elevation: elevation,
      shape: shape,
      bottom: bottom,
      automaticallyImplyLeading: false,
      systemOverlayStyle: KazumiGlass.overlayStyle(context),
    );
  }

  /// 叠在页面内容之上的那层玻璃 + 折叠标题（`Stack` 的直接子项）。
  ///
  /// 页面需要开启 `Scaffold.extendBodyBehindAppBar: true`，并给滚动视图留出
  /// [bodyTopInset] 的顶部内边距 —— 这样内容才会从顶栏**底下**滑过去，玻璃
  /// 采样的正是它。玻璃画在 Stack 的最后，所以它压在列表之上。
  ///
  /// ```dart
  /// final appBar = SysAppBar(scrollProgress: progress);
  /// Scaffold(
  ///   extendBodyBehindAppBar: true,
  ///   appBar: appBar,
  ///   body: Stack(
  ///     children: [
  ///       NotificationListener<ScrollNotification>(
  ///         onNotification: (n) {
  ///           progress.updateFrom(n.metrics);
  ///           return false;
  ///         },
  ///         child: CustomScrollView(slivers: [
  ///           SliverPadding(padding: EdgeInsets.only(top: appBar.bodyTopInset(context))),
  ///           ...
  ///         ]),
  ///       ),
  ///       appBar.glassOverlay(context),
  ///     ],
  ///   ),
  /// )
  /// ```
  Widget glassOverlay(BuildContext context) {
    final progress = scrollProgress;
    if (progress == null) return const SizedBox.shrink();
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SizedBox(
        height: bodyTopInset(context),
        child: KazumiAppBarGlass(
          progress: progress,
          height: _height,
          title: collapsedTitle,
        ),
      ),
    );
  }

  /// 滚动视图需要留出的顶部内边距：状态栏 + 顶栏。
  ///
  /// 只在 `extendBodyBehindAppBar: true` 时需要 —— 否则 body 本来就从顶栏
  /// 下面开始。
  double bodyTopInset(BuildContext context) =>
      MediaQuery.paddingOf(context).top + _height;

  @override
  Size get preferredSize {
    return Size.fromHeight(_height);
  }
}

/// 压在内容之上的顶栏玻璃。
class KazumiAppBarGlass extends StatefulWidget {
  const KazumiAppBarGlass({
    super.key,
    required this.progress,
    required this.height,
    this.title,
  });

  final ValueListenable<double> progress;
  final double height;
  final Widget? title;

  @override
  State<KazumiAppBarGlass> createState() => _KazumiAppBarGlassState();
}

class _KazumiAppBarGlassState extends State<KazumiAppBarGlass> {
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double topInset = MediaQuery.paddingOf(context).top;
    final Color hairline = theme.colorScheme.onSurface.withValues(alpha: 0.14);

    return Align(
      alignment: Alignment.topCenter,
      child: ValueListenableBuilder<double>(
        valueListenable: widget.progress,
        builder: (context, t, _) {
          // 完全透明时不铺玻璃：此时背后是页面顶部（大标题或封面），铺一层
          // 只会把它糊掉，还白白多一次背景采样。
          final bool showGlass = t > 0.01;
          return Stack(
            children: [
              if (showGlass)
                Positioned.fill(
                  child: IgnorePointer(
                    child: KazumiLiquidGlass(
                      kind: GlassSurfaceKind.appBar,
                      // 贴着屏幕边和状态栏，四角都是直角。
                      shape: const LiquidGlassShape.roundedRectangle(0),
                      // 淡入交给着色器：外面套 Opacity 会插一层 saveLayer，
                      // 玻璃就采不到背后的内容了（见 KazumiLiquidGlass.fade）。
                      fade: t,
                    ),
                  ),
                ),
              if (widget.title != null)
                Positioned(
                  left: KazumiGlass.barLeadingWidth,
                  right: KazumiGlass.barLeadingWidth,
                  top: topInset,
                  height: widget.height,
                  child: IgnorePointer(
                    child: Opacity(
                      // 玻璃出现之后小标题才淡入，和大标题的淡出错开 ——
                      // 两者不会在同一时刻都半透明。
                      opacity: ((t - 0.35) / 0.65).clamp(0.0, 1.0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: DefaultTextStyle(
                          style: theme.textTheme.titleMedium!.copyWith(
                            fontWeight: FontWeight.w600,
                            fontSize: 17,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          child: widget.title!,
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Opacity(
                  opacity: t,
                  child: Container(height: 0.5, color: hairline),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 顶栏里「原地收缩」的大标题。
///
/// 有些页面的标题本身就在顶栏（例如追番页：分类条固定在标题下面，没有一段
/// 可以滚走的大标题）。这种页面不把标题挪进列表，而是让它随滚动从 28 收到
/// 17 —— 和 iOS 的 inline title 一致：字变小、位置不变，顶栏同时浮出玻璃。
///
/// [progress] 为 null 时永远是完整的大标题（不滚动的页面用）。
class KazumiCollapsingTitle extends StatelessWidget {
  const KazumiCollapsingTitle({
    super.key,
    required this.text,
    this.progress,
  });

  final String text;
  final ValueListenable<double>? progress;

  @override
  Widget build(BuildContext context) {
    final ValueListenable<double>? progress = this.progress;
    if (progress == null) {
      return Text(text, style: appBarTitleStyle(context));
    }
    return ValueListenableBuilder<double>(
      valueListenable: progress,
      builder: (context, t, _) {
        final TextStyle base = appBarTitleStyle(context);
        return Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: base.copyWith(
            // 起点 28（大标题），终点 20（比 17 的 inline title 略大：
            // 这一栏有 72 高，缩到 17 会显得空）。
            fontSize: lerpDouble(28, 20, t),
            // 字重不插值：过半程时直接切到 semibold，视觉上跟着字号走。
            fontWeight: t > 0.6 ? FontWeight.w600 : FontWeight.w700,
          ),
        );
      },
    );
  }
}

/// 顶栏下方的大标题。
///
/// 它跟着列表一起往上滚；这里只叠一层随滚动收敛的缩放与淡出，让它「缩进」
/// 顶栏，而不是硬生生被裁掉。
class KazumiLargeTitle extends StatelessWidget {
  const KazumiLargeTitle({
    super.key,
    required this.progress,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 12),
    this.alignment = Alignment.centerLeft,
  });

  final ValueListenable<double> progress;
  final Widget child;
  final EdgeInsets padding;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: progress,
      builder: (context, t, _) => Padding(
        padding: padding,
        child: Opacity(
          // 比玻璃收得再快一点：标题在玻璃完全出现前就已经淡没了。
          opacity: (1 - t * 1.5).clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 1 - 0.08 * t,
            alignment: alignment,
            child: child,
          ),
        ),
      ),
    );
  }
}
