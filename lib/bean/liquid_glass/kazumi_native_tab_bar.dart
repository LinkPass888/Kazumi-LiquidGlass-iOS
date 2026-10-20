import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 原生 `UITabBar` 的一个标签项。
class KazumiNativeTabItem {
  const KazumiNativeTabItem({
    required this.label,
    required this.symbol,
    String? selectedSymbol,
    this.badgeValue,
  }) : selectedSymbol = selectedSymbol ?? symbol;

  /// 标签文字。
  final String label;

  /// 未选中时的 SF Symbol 名。
  final String symbol;

  /// 选中时的 SF Symbol 名；不填时与 [symbol] 相同。
  final String selectedSymbol;

  /// 徽标文字；null 表示不显示。
  final String? badgeValue;
}

/// 直接创建 `native_glass_navbar` 注册的原生标签栏视图。
///
/// 为什么不用插件自带的 `NativeGlassNavBar`：它在 `initState` 里发起一次
/// `isLiquidGlassSupported` 的 method channel 往返，结果回来之前渲染
/// `SizedBox.shrink()` —— 启动时底栏会从 0 跳到 83，肉眼能看见一次布局抖动。
/// 本应用的最低系统就是 iOS 26，那个检查必然通过，所以这里跳过这次往返，
/// 按同一套参数协议直接创建平台视图：首帧就是正确高度。
///
/// 平台视图的类型名（`NativeTabBar`）、通道名（`NativeTabBar_<id>`）和参数
/// 结构都由插件的 Swift 侧定义，改动这里必须同步核对
/// `native_glass_navbar` 的 `createNativeTabBarParams`。
class KazumiNativeTabBar extends StatefulWidget {
  const KazumiNativeTabBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.tintColor,
  });

  final List<KazumiNativeTabItem> items;

  /// 当前选中的标签下标。
  final int currentIndex;

  /// 点按回调；原生侧选中后再通知，索引以原生为准。
  final ValueChanged<int> onTap;

  /// 选中项的颜色；null 时用主题主色。
  final Color? tintColor;

  /// 栏体本身的高度，不含底部安全区（原生 UITabBar 的固定值）。
  static const double barHeight = 49;

  @override
  State<KazumiNativeTabBar> createState() => _KazumiNativeTabBarState();
}

class _KazumiNativeTabBarState extends State<KazumiNativeTabBar> {
  MethodChannel? _channel;

  /// 与 `native_glass_navbar` 的 `createNativeTabBarParams` 保持同构。
  Map<String, Object?> _params(BuildContext context) {
    return <String, Object?>{
      'tabs': widget.items
          .map((item) => <String, String?>{
                'label': item.label,
                'symbol': item.symbol,
                'selectedSymbol': item.selectedSymbol,
                'badgeValue': item.badgeValue,
              })
          .toList(growable: false),
      // 没有动作按钮：Swift 侧以空串判定「无」。
      'actionButtonSymbol': '',
      'selectedIndex': widget.currentIndex,
      'isDark': Theme.of(context).brightness == Brightness.dark,
      'tintColor':
          (widget.tintColor ?? Theme.of(context).colorScheme.primary)
              .toARGB32(),
    };
  }

  void _push() {
    _channel?.invokeMethod<void>('update', _params(context));
  }

  @override
  void didUpdateWidget(KazumiNativeTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _push();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 主题明暗或主色变了也要同步过去（原生侧自己不会跟随）。
    _push();
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double bottomInset = MediaQuery.paddingOf(context).bottom;
    return SizedBox(
      height: KazumiNativeTabBar.barHeight + bottomInset,
      child: UiKitView(
        viewType: 'NativeTabBar',
        creationParams: _params(context),
        creationParamsCodec: const StandardMessageCodec(),
        // 标签栏要独占触摸：不这样声明，点按会先被 Flutter 的手势竞技场
        // 判给背后的滚动视图。
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
        },
        onPlatformViewCreated: (int id) {
          final channel = MethodChannel('NativeTabBar_$id');
          _channel = channel;
          channel.setMethodCallHandler((MethodCall call) async {
            if (call.method == 'valueChanged') {
              final args = call.arguments as Map<Object?, Object?>;
              widget.onTap(args['index']! as int);
            }
          });
        },
      ),
    );
  }
}
