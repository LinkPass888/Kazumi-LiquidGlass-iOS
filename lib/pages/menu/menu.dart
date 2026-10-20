import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/liquid_glass/glass_material.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_motion.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_native_tab_bar.dart';
import 'package:kazumi/bean/liquid_glass/liquid_glass.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/menu/route_visibility.dart';
import 'package:kazumi/pages/router.dart';

class ScaffoldMenu extends StatefulWidget {
  const ScaffoldMenu({super.key, required this.location});

  final String location;

  @override
  State<ScaffoldMenu> createState() => _ScaffoldMenu();
}

class _ScaffoldMenu extends State<ScaffoldMenu> with RouteAware {
  final _outletKey = GlobalKey<RouterOutletState>();
  late int _selectedIndex = menu.indexForPath(widget.location);
  DateTime? _lastExitPromptAt;

  /// The shell sits at the bottom of the root stack and stays mounted while
  /// other pages cover it, so it publishes that state for its subtree.
  bool _isCovered = false;

  @override
  void didUpdateWidget(covariant ScaffoldMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) {
      _selectedIndex = menu.indexForPath(widget.location);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) {
      rootRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    rootRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPushNext() => _setCovered(true);

  @override
  void didPopNext() => _setCovered(false);

  void _setCovered(bool value) {
    if (!mounted || _isCovered == value) {
      return;
    }
    setState(() => _isCovered = value);
  }

  void _selectDestination(int index) {
    _lastExitPromptAt = null;
    if (index == _selectedIndex) {
      return;
    }
    final outlet = _outletKey.currentState;
    if (outlet == null) return;
    outlet.navigate('/tab${menu.getPath(index)}/');
    setState(() => _selectedIndex = index);
  }

  void _handleSystemBack(BuildContext context) {
    if (_outletKey.currentState?.maybePop() ?? false) {
      _lastExitPromptAt = null;
      return;
    }

    if (_selectedIndex != 0) {
      _selectDestination(0);
      return;
    }

    final now = DateTime.now();
    final lastPromptAt = _lastExitPromptAt;
    if (lastPromptAt == null ||
        now.difference(lastPromptAt) > const Duration(seconds: 2)) {
      _lastExitPromptAt = now;
      KazumiDialog.showToast(message: '再按一次退出应用', context: context);
      return;
    }

    _lastExitPromptAt = null;
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return RouteVisibility(
      isCovered: _isCovered,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            _handleSystemBack(context);
          }
        },
        child: OrientationBuilder(
          builder: (context, orientation) {
            return orientation == Orientation.portrait
                ? _bottomMenu(context, _selectedIndex)
                : _sideMenu(context, _selectedIndex);
          },
        ),
      ),
    );
  }

  Widget _outlet(BuildContext context, {BorderRadius? borderRadius}) {
    Widget child = NotificationListener<NavigationNotification>(
      // A non-poppable outlet must not override the shell's PopScope state.
      onNotification: (notification) => !notification.canHandlePop,
      child: RouterOutlet(key: _outletKey),
    );
    if (borderRadius != null) {
      child = ClipRRect(borderRadius: borderRadius, child: child);
    }
    // 页面底色用中性的浅表面：苹果的内容面不泛主题色，主题色留给控件本身。
    // 圆角在宽屏下给的是「设置」这类分栏面板的轮廓，颜色换了之后仍然保留。
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: borderRadius,
      ),
      child: child,
    );
  }

  Widget _bottomMenu(BuildContext context, int selectedIndex) {
    final useGlass = KazumiGlass.enabled;
    return Scaffold(
      // 玻璃栏浮在内容之上，滚动时才有东西可以折光
      extendBody: useGlass,
      body: _outlet(context),
      bottomNavigationBar: useGlass
          ? _glassBottomBar(context, selectedIndex)
          : _materialBottomBar(context, selectedIndex),
    );
  }

  /// iOS 26 的液态玻璃标签栏。
  ///
  /// iOS 上是原生 UITabBar：真正的 UIGlassEffect、选中胶囊、滑动手势与
  /// 无障碍都由系统接管，图标走 SF Symbols。
  ///
  /// 直接用 [KazumiNativeTabBar] 创建平台视图，而不是插件自带的
  /// `NativeGlassNavBar`：后者首帧要先做一次「是否支持液态玻璃」的
  /// method channel 往返，期间渲染空盒子，底栏会从 0 跳到 83。本应用最低
  /// 就是 iOS 26，那次检查必然通过，跳过它就不会有这阵抖动。
  Widget _glassBottomBar(BuildContext context, int selectedIndex) {
    // 高度和位置都交给原生 UITabBar：栏体一直铺到屏幕底部，底部安全区由它
    // 自己处理，这样浮动胶囊的位置就是 iOS 原生的位置。
    return KazumiNativeTabBar(
      items: const <KazumiNativeTabItem>[
        KazumiNativeTabItem(
          label: '推荐',
          symbol: 'house',
          selectedSymbol: 'house.fill',
        ),
        KazumiNativeTabItem(
          label: '时间表',
          symbol: 'calendar',
        ),
        KazumiNativeTabItem(
          label: '追番',
          symbol: 'heart',
          selectedSymbol: 'heart.fill',
        ),
        KazumiNativeTabItem(
          label: '我的',
          symbol: 'gearshape',
          selectedSymbol: 'gearshape.fill',
        ),
      ],
      currentIndex: selectedIndex,
      onTap: _selectDestination,
      tintColor: Theme.of(context).colorScheme.primary,
    );
  }

  Widget _materialBottomBar(BuildContext context, int selectedIndex) {
    return NavigationBar(
        destinations: const <Widget>[
          NavigationDestination(
            selectedIcon: Icon(Icons.home),
            icon: Icon(Icons.home_outlined),
            label: '推荐',
          ),
          NavigationDestination(
            selectedIcon: Icon(Icons.timeline),
            icon: Icon(Icons.timeline_outlined),
            label: '时间表',
          ),
          NavigationDestination(
            selectedIcon: Icon(Icons.favorite),
            icon: Icon(Icons.favorite_outlined),
            label: '追番',
          ),
          NavigationDestination(
            selectedIcon: Icon(Icons.settings),
            icon: Icon(Icons.settings),
            label: '我的',
          ),
        ],
        selectedIndex: selectedIndex,
        onDestinationSelected: _selectDestination,
      );
  }

  /// 横屏（iPad / 横向 iPhone）的侧边栏。
  ///
  /// 换成了浮起的玻璃导航条：和一屏内容之间隔开一段留白，圆角与屏幕圆角
  /// 同心，选中项是压在玻璃上的一颗胶囊。原生 `NavigationRail` 只能给一块
  /// 平铺的实色面板，和这套玻璃语言对不上。
  Widget _sideMenu(BuildContext context, int selectedIndex) {
    final double inset = KazumiGlass.floatingBarInset;
    final double radius = KazumiGlass.floatingBarRadiusOf(context);
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        child: Row(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(inset, inset, 0, inset),
              child: KazumiLiquidGlass(
                kind: GlassSurfaceKind.mediaTabBar,
                shape: LiquidGlassShape.roundedRectangle(radius),
                padding: const EdgeInsets.symmetric(
                  horizontal: KazumiGlass.floatingBarGap,
                  vertical: KazumiGlass.floatingBarGap,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SideDestination(
                      icon: Icons.search_rounded,
                      label: '搜索',
                      selected: false,
                      onTap: () => context.pushNamed('/search/'),
                    ),
                    const SizedBox(height: 8),
                    ..._sideDestinations.map(
                      (destination) => _SideDestination(
                        icon: destination.$2,
                        selectedIcon: destination.$3,
                        label: destination.$1,
                        selected: destination.$4 == selectedIndex,
                        onTap: () => _selectDestination(destination.$4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _outlet(
                context,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(radius),
                  bottomLeft: Radius.circular(radius),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 侧边栏的目的地：标题、图标、选中图标、索引（与底部标签栏同一顺序）。
const List<(String, IconData, IconData, int)> _sideDestinations = [
  ('推荐', Icons.home_outlined, Icons.home_rounded, 0),
  ('时间表', Icons.timeline_outlined, Icons.timeline_rounded, 1),
  ('追番', Icons.favorite_outline_rounded, Icons.favorite_rounded, 2),
  ('我的', Icons.settings_outlined, Icons.settings_rounded, 3),
];

/// 玻璃导航条里的一项：图标 + 文字，选中时垫一颗同心圆角的胶囊。
class _SideDestination extends StatelessWidget {
  const _SideDestination({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.selectedIcon,
  });

  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color foreground =
        selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: KazumiMotion.short,
          curve: KazumiMotion.springDecel,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: ShapeDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.16)
                : Colors.transparent,
            // 和玻璃外框同心：外框圆角减掉四周留白。
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(
                (KazumiGlass.floatingBarRadiusOf(context) -
                        KazumiGlass.floatingBarGap)
                    .clamp(8.0, 40.0),
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(selected ? (selectedIcon ?? icon) : icon,
                  size: 22, color: foreground),
              const SizedBox(width: 10),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
