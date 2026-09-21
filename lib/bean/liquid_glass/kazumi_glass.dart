import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:real_liquid_glass/real_liquid_glass.dart';

/// 菜单条目点完要关到哪一层。
///
/// 播放器菜单是两层的：一级是「更多」那块面板，二级是比例 / 倍速 / 超分 / 定时。
enum KazumiMenuCloseLevel {
  /// 二级项：关自己 + 上层，整条菜单链都收起来。
  all,

  /// 只关自己所在的那层（定时关闭：选完时间，一级面板继续留着）。
  current,
}

class KazumiMenuCloseScope extends InheritedWidget {
  const KazumiMenuCloseScope({
    super.key,
    required this.closeSelf,
    required this.closeAll,
    required super.child,
  });

  /// 只关自己这一层。
  final VoidCallback closeSelf;

  /// 关自己 + 上层。
  final VoidCallback closeAll;

  /// 用 `getInheritedWidgetOfExactType`：找一个已有祖先就行，不建立依赖，
  /// 这样在 build 里、在点击回调里都能安全调用。
  static KazumiMenuCloseScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<KazumiMenuCloseScope>();

  @override
  bool updateShouldNotify(KazumiMenuCloseScope oldWidget) => false;
}

/// 液态玻璃（iOS 26 Liquid Glass）适配的统一入口。
///
/// iOS 26+ 上交给苹果原生的 `UIGlassEffect`：真正的折光液态玻璃，并且自动
/// 跟随系统的透明度滑块、降低透明度与增强对比度；iOS 26 以下是系统模糊；
/// 其它平台由 real_liquid_glass 自己画一层磨砂。所有玻璃表面都从这里出，
/// 是为了只有一处开关、形状统一，也方便随时整体退回原来的 Material 外观。
abstract final class KazumiGlass {
  /// 底部玻璃标签栏的高度。
  ///
  /// iOS 上这是原生 `UITabBar` 的高度，栏体一直铺到屏幕底部并自己处理底部
  /// 安全区，所以这里包含安全区高度。
  static const double bottomBarHeight = 85;

  /// 圆形按钮 / 浮动按钮的形状。
  static const LiquidGlassShape circleShape = LiquidGlassShape.capsule();

  /// 分组控件（放送星期、追番分类这类标签）的胶囊形状。
  static const LiquidGlassShape pillShape =
      LiquidGlassShape.roundedRectangle(22);

  /// 菜单、面板的圆角半径。
  ///
  /// 不写死：跟着设备走。这个 Flutter 版本的 MediaQueryData 没有
  /// displayCornerRadius（analyze 会报 undefined_getter），所以按屏幕短边
  /// 换算——短边越大、机身圆角越大，菜单也跟着更圆，设备间是自适应的。
  static double panelRadiusOf(BuildContext context) {
    final double shortest = MediaQuery.of(context).size.shortestSide;
    if (!shortest.isFinite || shortest <= 0) {
      return 16;
    }
    // iPhone 短边 393 时正好 16，小屏略小、大屏略大
    return (shortest * 16.0 / 393.0).clamp(13.0, 22.0);
  }

  /// 菜单内容离面板内边的距离。
  ///
  /// 这是「同心圆」的关键：条目高亮圆角恒等于 面板圆角 − 这个值，两个圆角的
  /// 圆心就落在同一点，看起来才是 iOS 那种同心圆。所有菜单都从这里取，
  /// 不要各处自己写数字。
  static const double menuPanelInset = 6;

  /// 条目自身还带了 3 的外边距（见 [menuItem]），面板再补 3 就正好 6。
  ///
  /// 面板 3 + 条目 3 = 6，相邻两个条目之间是 3 + 3 = 6：高亮块离玻璃边框的
  /// 距离、和离上下选项的距离完全一样宽。
  static const EdgeInsets menuPanelPadding = EdgeInsets.all(3);

  /// 菜单条目的高亮/选中圆角：= 面板圆角 − [menuPanelInset]。
  static double menuItemRadiusOf(BuildContext context) =>
      (panelRadiusOf(context) - menuPanelInset).clamp(6.0, 18.0);

  /// 菜单条目的样式：按下/选中的高亮形状用同心圆半径。
  ///
  /// 播放器那几个菜单是 MenuItemButton/SubmenuButton，MenuTheme 在这条链路
  /// 上照不到，所以逐个显式给。
  static ButtonStyle menuItemButtonStyle(
    BuildContext context, {
    bool selected = false,
  }) {
    final Color primary = Theme.of(context).colorScheme.primary;
    return ButtonStyle(
      // 当前值那一项也要深色填充（这些条目不是 MenuItemButton 的选中态，
      // 得由调用方告诉它自己是当前值）
      backgroundColor: WidgetStatePropertyAll(
        selected ? primary.withValues(alpha: 0.30) : Colors.transparent,
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.all(
            Radius.circular(menuItemRadiusOf(context)),
          ),
        ),
      ),
      // 按下/悬停的深色
      overlayColor: WidgetStatePropertyAll(primary.withValues(alpha: 0.18)),
    );
  }

  /// 子菜单（SubmenuButton）的面板样式。
  ///
  /// 子菜单面板由框架自己画，铺不了玻璃，所以退一步：圆角和别的菜单完全一致，
  /// 底色用半透明的 surface，远看和玻璃面板是一套。
  static MenuStyle submenuStyle(BuildContext context) => MenuStyle(
        backgroundColor: WidgetStatePropertyAll(
          Theme.of(context).colorScheme.surface.withValues(alpha: 0.86),
        ),
        elevation: const WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(
              Radius.circular(panelRadiusOf(context)),
            ),
          ),
        ),
      );

  /// 菜单、面板用的圆角形状。
  static LiquidGlassShape panelShapeOf(BuildContext context) =>
      LiquidGlassShape.roundedRectangle(panelRadiusOf(context));

  /// 兜底用的默认形状（拿不到设备信息时）。
  static const LiquidGlassShape panelShape =
      LiquidGlassShape.roundedRectangle(16);

  /// 顶栏按钮的统一尺寸。
  static const double barButtonSize = 40;
  static const double barButtonGap = 6;
  static const double barEdgeInset = 10;

  /// 顶栏按钮占位宽度：按钮 + 两侧留白。
  static const double barLeadingWidth = barButtonSize + barEdgeInset * 2;

  /// 浮起的玻璃条（详情页标签栏这类）两侧的留白。
  ///
  /// 和首页底部标签栏同一套语言：玻璃是「浮」在内容上的，左右都让开一段，
  /// 不贴屏幕边。
  static const double floatingBarInset = 16;

  /// 屏幕（机身）圆角半径的估算值。
  ///
  /// 和 [panelRadiusOf] 同理：这个 Flutter 版本的 MediaQueryData 没有
  /// displayCornerRadius，只能按屏幕短边换算 —— 短边 393 的那一代机器
  /// （iPhone 15/16/17）机身圆角约 55，小屏略小、大屏略大。
  static double screenRadiusOf(BuildContext context) {
    final double shortest = MediaQuery.of(context).size.shortestSide;
    if (!shortest.isFinite || shortest <= 0) {
      return 55;
    }
    return (shortest * 55.0 / 393.0).clamp(24.0, 68.0);
  }

  /// 浮起的玻璃条的圆角：和屏幕圆角同心。
  ///
  /// iOS 26 的浮层就是这么取的：控件左右各离屏幕边 [floatingBarInset]，圆角取
  /// 「屏幕圆角 − 这段距离」，两个圆角共用同一个圆心，边线才是连着的一条曲线，
  /// 而不是各圆各的。手机上算出来比半高还大，渲染出来是胶囊，和首页底部标签栏
  /// 一致。
  static double floatingBarRadiusOf(BuildContext context) =>
      (screenRadiusOf(context) - floatingBarInset).clamp(18.0, 40.0);

  /// 一条浮起来的玻璃：左右留白 + 同心圆角，内容画在玻璃之上。
  static Widget floatingBar({
    required BuildContext context,
    required Widget child,
    EdgeInsetsGeometry padding = EdgeInsets.zero,
  }) {
    if (!enabled) {
      return child;
    }
    return LiquidGlassContainer(
      shape: LiquidGlassShape.roundedRectangle(floatingBarRadiusOf(context)),
      style: LiquidGlassStyle.regular,
      padding: padding,
      child: child,
    );
  }

  /// 玻璃条里的一个选项（详情页标签这类）。
  ///
  /// 选中和按下是同一个盒子上的深色填充，形状必然一致；整条已经是一块玻璃，
  /// 所以这里不再叠玻璃（苹果不建议玻璃叠玻璃，实测也会点不动）。
  static Widget barSegment({
    required BuildContext context,
    required Widget child,
    required VoidCallback? onTap,
    bool selected = false,
    EdgeInsetsGeometry padding =
        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    double? radius,
  }) {
    return _GlassTapTarget(
      onTap: onTap,
      shape: panelShapeOf(context),
      padding: padding,
      selected: selected,
      // 高亮块和玻璃同心：玻璃圆角 − 内边距
      radius: radius ?? (floatingBarRadiusOf(context) - 8).clamp(10.0, 22.0),
      wrapInGlass: false,
      child: child,
    );
  }

  /// 是否启用液态玻璃，可在「设置 - 界面设置」里关闭。
  static bool get enabled =>
      GStorage.getSetting(SettingsKeys.enableLiquidGlass);

  /// 页面为了让开浮动的玻璃标签栏，需要额外留出的底部内边距。
  static double bottomInset(BuildContext context) {
    if (!enabled) {
      return 0;
    }
    // 栏体本身已经盖住底部安全区，这里再留一点余量，免得最后一行贴着玻璃。
    return bottomBarHeight + 8;
  }

  /// 顶栏用的系统状态栏样式：透明背景 + 跟随主题明暗的图标。
  ///
  /// 顶栏背景一旦设成透明，AppBar 自己推断出来的样式会把状态栏图标定成白色
  /// 并一直留着，所以这里显式给一份。iOS 看的是
  /// [SystemUiOverlayStyle.statusBarBrightness]（状态栏背景的明暗），
  /// 安卓看的是 `statusBarIconBrightness`，两个都要给。
  static SystemUiOverlayStyle overlayStyle(BuildContext context) {
    final bool light = Theme.of(context).brightness == Brightness.light;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: light ? Brightness.dark : Brightness.light,
      statusBarBrightness: light ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
    );
  }

  /// 一块玻璃表面，[child] 画在玻璃之上。
  ///
  /// 关闭液态玻璃时原样返回 [child]，由调用方自己决定原来的外观。
  static Widget glassSurface({
    required Widget child,
    LiquidGlassShape shape = circleShape,
    EdgeInsetsGeometry? padding,
  }) {
    if (!enabled) {
      return child;
    }
    return LiquidGlassContainer(
      shape: shape,
      style: LiquidGlassStyle.regular,
      padding: padding,
      child: child,
    );
  }

  /// 顶栏按钮的玻璃底。
  ///
  /// 只做装饰：触摸照旧落到里面的按钮上。
  static Widget buttonGlass({required Widget child}) {
    if (!enabled) {
      return child;
    }
    return LiquidGlassContainer(
      shape: circleShape,
      style: LiquidGlassStyle.regular,
      child: child,
    );
  }

  /// 圆形玻璃按钮：图标固定居中在玻璃正中，点按区就是整块玻璃。
  static Widget iconButton({
    required BuildContext context,
    required Widget icon,
    required VoidCallback? onPressed,
    String? tooltip,
    double size = barButtonSize,
  }) {
    final Widget button = _GlassTapTarget(
      onTap: onPressed,
      shape: circleShape,
      padding: EdgeInsets.zero,
      width: size,
      height: size,
      child: icon,
    );
    if (tooltip == null) {
      return button;
    }
    return Tooltip(message: tooltip, child: button);
  }

  /// 一颗可点的小玻璃按钮（放送星期、追番分类这类标签）。
  static Widget glassButton({
    required BuildContext context,
    required Widget child,
    required VoidCallback? onTap,
    bool selected = false,
    EdgeInsetsGeometry padding =
        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
  }) {
    return _GlassTapTarget(
      onTap: onTap,
      shape: circleShape,
      padding: padding,
      selected: selected,
      child: child,
    );
  }

  /// 玻璃面板里的一个可点条目。
  ///
  /// 不额外铺玻璃（苹果不建议玻璃叠玻璃，实测也会点不动），整块菜单还是一块
  /// 条目点完到菜单真正关闭之间的停顿：让选中态 / 文案先改出来，
  /// 用户能看清自己点中的是哪一项。
  static const Duration menuCloseDelay = Duration(milliseconds: 200);

  /// 玻璃面板里的一个可点条目。
  ///
  /// 不额外铺玻璃（苹果不建议玻璃叠玻璃，实测也会点不动），整块菜单还是一块
  /// 大玻璃；条目只负责按下时的圆角高亮。
  static Widget menuItem({
    required BuildContext context,
    required Widget child,
    required VoidCallback? onTap,
    bool selected = false,
    bool closeMenu = true,
    KazumiMenuCloseLevel closeLevel = KazumiMenuCloseLevel.all,
    EdgeInsetsGeometry padding =
        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    double? radius,
  }) {
    return Padding(
      // 3 + 面板的 3 = 6：四边留白等宽（相邻条目之间也是 3 + 3 = 6）
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      // 必须用「条目自己的 context」找菜单，不能用传进来的 context：
      // 传进来的 context 属于构建菜单的那棵树（播放器面板 / Observer），
      // 它在菜单浮层外面 —— 在那里查 MenuController 和 KazumiMenuCloseScope
      // 永远是 null，关菜单就静默失败（这就是「改了没变化」的真正原因）。
      // Builder 给的是条目在浮层里的 context，往上查才查得到。
      child: Builder(
        builder: (BuildContext itemContext) {
          return _GlassTapTarget(
            // 和 MenuItemButton 一样：点完就把所在的菜单关掉，
            // 否则选完倍速 / 定时关闭，菜单还留在屏幕上。
            // 菜单里的条目走 KazumiMenuCloseScope（能一层层往上关）；不在菜单
            // 体系里的条目退回框架的 MenuController，行为和以前一致。
            onTap: onTap == null
                ? null
                : () {
                    final KazumiMenuCloseScope? scope = closeMenu
                        ? KazumiMenuCloseScope.maybeOf(itemContext)
                        : null;
                    final MenuController? menu = closeMenu && scope == null
                        ? MenuController.maybeOf(itemContext)
                        : null;
                    // 先跑条目自己的动作，再留一小会儿才关菜单：
                    // 1) 同步关菜单会立刻重建菜单树，投屏 / 弹窗 / 跳详情这类
                    //    「先做事」的条目动作可能像没发生一样；
                    // 2) 选中态（深色填充）也要有时间被看见，不然点完根本
                    //    不知道自己选中了哪一项。
                    onTap();
                    if (scope != null) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        Future<void>.delayed(KazumiGlass.menuCloseDelay, () {
                          if (closeLevel == KazumiMenuCloseLevel.all) {
                            scope.closeAll();
                          } else {
                            scope.closeSelf();
                          }
                        });
                      });
                    } else if (menu != null) {
                      // 不在播放器这套分层菜单里的（收藏状态菜单、下拉菜单），
                      // 退回框架的 MenuController，行为和以前一致。
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        Future<void>.delayed(KazumiGlass.menuCloseDelay, () {
                          menu.close();
                        });
                      });
                    }
                  },
            shape: panelShape,
            padding: padding,
            selected: selected,
            radius: radius ?? menuItemRadiusOf(itemContext),
            wrapInGlass: false,
            // 同一块面板里的条目必须同一套字：菜单条目统一 labelLarge，
            // 免得「一起看」这类和「定时关闭」那类条目的字号字重不一样。
            child: DefaultTextStyle(
              style: Theme.of(itemContext).textTheme.labelLarge ??
                  const TextStyle(),
              child: child,
            ),
          );
        },
      ),
    );
  }

  /// 子菜单触发条目（视频比例、超分辨率、倍速、定时关闭）的按下底色。
  ///
  /// SubmenuButton 自带的是 M3 菜单按钮那层很淡的按下色，和玻璃条目的按下
  /// 深色对不上，所以显式给一份：按下 0.22，圆角用同心的条目圆角。
  static ButtonStyle submenuTriggerStyle(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ButtonStyle(
      overlayColor: WidgetStatePropertyAll(
        scheme.primary.withValues(alpha: 0.22),
      ),
      // 框架给「有子菜单」的条目在文字后面留了一段和按钮内边距同宽的空白
      // （_MenuItemLabel 里的 submenuIcon 占位），文字就被顶偏了。
      // 内边距归零后，这类条目和普通条目一样是整块宽度里居中。
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.all(
            Radius.circular(menuItemRadiusOf(context)),
          ),
        ),
      ),
    );
  }


  /// 浮在玻璃标签栏之上的浮动按钮。
  ///
  /// 顺手把 Material FAB 的表面变透明、去掉阴影并改成胶囊（圆形按钮就是圆，
  /// 扩展按钮就是药丸），让玻璃透出来；点按与涟漪还是 FAB 自己的。
  static Widget floatingButton({
    required BuildContext context,
    required Widget child,
    bool aboveTabBar = true,
  }) {
    if (!enabled) {
      return child;
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget themed = Theme(
      data: Theme.of(context).copyWith(
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: Colors.transparent,
          foregroundColor: scheme.primary,
          elevation: 0,
          focusElevation: 0,
          hoverElevation: 0,
          highlightElevation: 0,
          shape: const StadiumBorder(),
        ),
      ),
      child: child,
    );
    return Padding(
      padding: EdgeInsets.only(
        bottom: aboveTabBar ? bottomInset(context) : 0,
      ),
      child: glassSurface(child: themed),
    );
  }
}

/// 玻璃底 + 按下反馈画在同一个盒子里的小按钮。
///
/// 关键点：按下时的高亮和选中填充都由**同一个容器的装饰**画出来，和玻璃共用
/// 同一个矩形，所以形状、大小必然一致。之前用 Material 的 InkWell，它的水波纹
/// 和高亮是按 Material 自己的盒子算的，和玻璃是两套几何，怎么调都会有出入。
class _GlassTapTarget extends StatefulWidget {
  const _GlassTapTarget({
    required this.child,
    required this.onTap,
    required this.shape,
    required this.padding,
    this.selected = false,
    this.width,
    this.height,
    this.radius,
    this.wrapInGlass = true,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// 玻璃的形状（[wrapInGlass] 为 false 时不用）。
  final LiquidGlassShape shape;
  final EdgeInsetsGeometry padding;
  final bool selected;
  final double? width;
  final double? height;

  /// 高亮形状的圆角；为 null 时用胶囊（StadiumBorder）。
  final double? radius;

  /// 是否在盒子后面铺一层玻璃。菜单条目不需要，因为整块菜单已经是一块玻璃。
  final bool wrapInGlass;

  @override
  State<_GlassTapTarget> createState() => _GlassTapTargetState();
}

class _GlassTapTargetState extends State<_GlassTapTarget> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (mounted && _pressed != value) {
      setState(() => _pressed = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color base = widget.selected
        ? scheme.primary.withValues(alpha: 0.30)
        : Colors.transparent;
    // 按压高亮和选中填充画在同一个盒子上：形状、圆角、大小必然一致
    final Color color = _pressed
        ? scheme.primary
            .withValues(alpha: widget.selected ? 0.46 : 0.22)
        : base;
    final ShapeBorder border = widget.radius == null
        ? const StadiumBorder()
        : RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(widget.radius!)),
          );
    final Widget box = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        width: widget.width,
        height: widget.height,
        alignment: Alignment.center,
        decoration: ShapeDecoration(shape: border, color: color),
        child: Padding(padding: widget.padding, child: widget.child),
      ),
    );
    if (!KazumiGlass.enabled || !widget.wrapInGlass) {
      return box;
    }
    return LiquidGlassContainer(
      shape: widget.shape,
      style: LiquidGlassStyle.regular,
      // 装饰用：触摸交给上面的 GestureDetector，玻璃自己不接管触摸
      interactive: false,
      child: box,
    );
  }
}
