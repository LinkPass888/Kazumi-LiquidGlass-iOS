import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import 'glass_style.dart';
import 'native_glass_view.dart';

/// One destination in a [LiquidGlassBottomBar].
class LiquidGlassBarItem {
  /// Creates a bar destination.
  const LiquidGlassBarItem({
    required this.icon,
    this.selectedIcon,
    required this.sfSymbol,
    this.selectedSfSymbol,
    required this.label,
  });

  /// Icon shown when the destination is not selected.
  final IconData icon;

  /// Icon shown when selected; falls back to [icon].
  final IconData? selectedIcon;

  /// SF Symbol rendered by the native iOS tab bar.
  final String sfSymbol;

  /// Optional selected-state SF Symbol; defaults to [sfSymbol].
  final String? selectedSfSymbol;

  /// Short destination name, shown under the icon and used for
  /// accessibility.
  final String label;
}

/// A floating capsule tab bar in the iOS 26/27 Liquid Glass idiom.
///
/// Sits above your content (typically in a [Stack], aligned to the
/// bottom) so the glass has something to refract.
///
/// The selected destination is marked by a capsule that behaves like the
/// native iOS 26 tab bar selection: the capsule is **real glass** — its
/// own lensing layer on the bar.
///
/// ```dart
/// LiquidGlassBottomBar(
///   items: const [
///     LiquidGlassBarItem(icon: CupertinoIcons.house, label: 'Home'),
///     LiquidGlassBarItem(icon: CupertinoIcons.search, label: 'Search'),
///   ],
///   currentIndex: _index,
///   onTap: (i) => setState(() => _index = i),
/// )
/// ```
class LiquidGlassBottomBar extends StatefulWidget {
  /// Creates the bar. [items] needs at least two destinations.
  const LiquidGlassBottomBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.tint,
    this.style = LiquidGlassStyle.regular,
    this.height = 85,
    this.margin = EdgeInsets.zero,
    this.showLabels = true,
  }) : assert(items.length >= 2, 'Provide at least two destinations');

  /// The destinations to display, in order.
  final List<LiquidGlassBarItem> items;

  /// Index of the selected destination.
  final int currentIndex;

  /// Called with the tapped destination's index.
  final ValueChanged<int> onTap;

  /// Color of the selected icon and label. Defaults to the ambient
  /// Cupertino primary color.
  final Color? tint;

  /// Glass variant for the bar surface.
  final LiquidGlassStyle style;

  /// Bar height, excluding [margin].
  final double height;

  /// Spacing around the floating bar. The default keeps it clear of the
  /// home indicator; wrap in [SafeArea] if you need more.
  final EdgeInsetsGeometry margin;

  /// Whether to show labels under the icons.
  final bool showLabels;

  @override
  State<LiquidGlassBottomBar> createState() => _LiquidGlassBottomBarState();
}

class _LiquidGlassBottomBarState extends State<LiquidGlassBottomBar> {
  void _select(int index) {
    if (index != widget.currentIndex) {
      HapticFeedback.selectionClick();
    }
    widget.onTap(index);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.margin,
      child: SizedBox(
        height: widget.height,
        child: _NativeLiquidGlassTabBar(
          items: widget.items,
          currentIndex: widget.currentIndex,
          onTap: _select,
          tint: widget.tint ?? CupertinoTheme.of(context).primaryColor,
        ),
      ),
    );
  }
}

class _NativeLiquidGlassTabBar extends StatefulWidget {
  const _NativeLiquidGlassTabBar({
    required this.items,
    required this.currentIndex,
    required this.onTap,
    required this.tint,
  });

  final List<LiquidGlassBarItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final Color tint;

  @override
  State<_NativeLiquidGlassTabBar> createState() =>
      _NativeLiquidGlassTabBarState();
}

class _NativeLiquidGlassTabBarState extends State<_NativeLiquidGlassTabBar> {
  MethodChannel? _channel;
  bool _hidden = false;

  /// 这条标签栏所属的路由：首页（shell）route。push 详情页时它不属于被
  /// 转场的那一页，所以保持显示，不会在动画结束时突兀闪现。
  Object? _route;

  Map<String, Object> get _params => {
    'labels': widget.items.map((item) => item.label).toList(),
    'symbols': widget.items.map((item) => item.sfSymbol).toList(),
    'selectedSymbols': widget.items
        .map((item) => item.selectedSfSymbol ?? item.sfSymbol)
        .toList(),
    'currentIndex': widget.currentIndex,
    'tint': widget.tint.toARGB32(),
    'dark': CupertinoTheme.of(context).brightness == Brightness.dark,
  };

  @override
  void initState() {
    super.initState();
    LiquidGlassVisibility.hiddenRoutesListenable.addListener(_onVisibilityChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Object? route = ModalRoute.of(context);
    if (route != _route) {
      _route = route;
      _hidden = LiquidGlassVisibility.isHiddenFor(_route);
    }
  }

  void _onVisibilityChanged() {
    final bool hidden = LiquidGlassVisibility.isHiddenFor(_route);
    if (_hidden == hidden) return;
    // 必须 setState：Offstage 依赖 _hidden 重建，否则原生 UITabBar 会一直
    // 被隐藏，要等滚动等操作触发 rebuild 才恢复显示。
    setState(() {
      _hidden = hidden;
    });
    _channel?.invokeMethod<void>('setHidden', {'hidden': hidden});
  }

  @override
  void didUpdateWidget(_NativeLiquidGlassTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _channel?.invokeMethod<void>('update', _params);
  }

  @override
  void dispose() {
    LiquidGlassVisibility.hiddenRoutesListenable.removeListener(_onVisibilityChanged);
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Offstage(
    offstage: _hidden,
    child: UiKitView(
      viewType: 'real_liquid_glass/tab_bar',
      creationParams: _params,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (id) {
        final channel = MethodChannel('real_liquid_glass/tab_bar_$id');
        _channel = channel;
        channel.setMethodCallHandler((call) async {
          if (call.method == 'selected') {
            final args = call.arguments as Map<Object?, Object?>;
            widget.onTap(args['index']! as int);
          }
        });
      },
    ),
  );
}
