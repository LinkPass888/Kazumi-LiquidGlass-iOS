import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import 'glass_style.dart';

/// 全局玻璃可见性控制。
///
/// 平台视图（UiKitView/AppKitView）是叠加在 Flutter 表面之上的原生层，不参与
/// Flutter 的路由转场 / Hero 飞行动画 —— 转场期间它会以「截屏残留」盖住下层
/// 内容（如详情页 Hero 飞行的封面）。转场开始时把玻璃隐藏、结束再恢复，
/// 即可消除这类遮挡。
class LiquidGlassVisibility {
  LiquidGlassVisibility._();

  static final ValueNotifier<bool> _hidden = ValueNotifier<bool>(false);

  /// 当前是否处于「隐藏玻璃」状态。
  static bool get isHidden => _hidden.value;

  /// 隐藏/恢复所有原生玻璃视图。true = 隐藏（转场/Hero 飞行期间），
  /// false = 恢复显示。
  static void setHidden(bool hidden) {
    if (_hidden.value == hidden) return;
    _hidden.value = hidden;
  }

  /// 供 [NativeGlassView] 内部订阅。
  static ValueListenable<bool> get hiddenListenable => _hidden;
}

/// Embeds the native effect view that carries the glass material.
///
/// On iOS 26+ / macOS 26+ this is real UIGlassEffect / NSGlassEffectView
/// Liquid Glass. The effect samples the content rendered beneath it —
/// Flutter widgets included.
class NativeGlassView extends StatefulWidget {
  const NativeGlassView({
    super.key,
    required this.style,
    required this.shape,
    required this.interactive,
    this.tint,
    this.onTap,
  });

  final LiquidGlassStyle style;
  final LiquidGlassShape shape;
  final bool interactive;
  final Color? tint;
  final VoidCallback? onTap;

  @override
  State<NativeGlassView> createState() => _NativeGlassViewState();
}

class _NativeGlassViewState extends State<NativeGlassView> {
  MethodChannel? _viewChannel;
  bool _hidden = false;

  Map<String, Object?> get _params => {
        'style': widget.style.name,
        'tint': widget.tint?.toARGB32(),
        'interactive': widget.interactive,
        'capsule': widget.shape.capsule,
        'cornerRadius': widget.shape.cornerRadius,
        'dark': CupertinoTheme.of(context).brightness == Brightness.dark,
      };

  @override
  void initState() {
    super.initState();
    _hidden = LiquidGlassVisibility.isHidden;
    LiquidGlassVisibility.hiddenListenable.addListener(_onVisibilityChanged);
  }

  void _onVisibilityChanged() {
    final bool hidden = LiquidGlassVisibility.isHidden;
    if (_hidden == hidden) return;
    // 必须 setState：Offstage 依赖 _hidden 重建，否则 UI 停在旧状态，
    // 要等滚动等操作触发 rebuild 才「回来」。
    setState(() {
      _hidden = hidden;
    });
    _viewChannel?.invokeMethod<void>('setHidden', {'hidden': hidden});
  }

  @override
  void didUpdateWidget(NativeGlassView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.style != oldWidget.style ||
        widget.shape != oldWidget.shape ||
        widget.interactive != oldWidget.interactive ||
        widget.tint != oldWidget.tint) {
      _viewChannel?.invokeMethod<void>('update', _params);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewChannel?.invokeMethod<void>('update', _params);
  }

  @override
  Widget build(BuildContext context) {
    final hitTestBehavior = widget.interactive
        ? PlatformViewHitTestBehavior.opaque
        : PlatformViewHitTestBehavior.transparent;
    // Kazumi 本地版：只保留 iOS/macOS（Apple 全平台）。
    final Widget view = defaultTargetPlatform == TargetPlatform.macOS
        ? AppKitView(
            viewType: 'real_liquid_glass/glass_view',
            creationParams: _params,
            creationParamsCodec: const StandardMessageCodec(),
            hitTestBehavior: hitTestBehavior,
            onPlatformViewCreated: _onViewCreated,
          )
        : UiKitView(
            viewType: 'real_liquid_glass/glass_view',
            creationParams: _params,
            creationParamsCodec: const StandardMessageCodec(),
            hitTestBehavior: hitTestBehavior,
            onPlatformViewCreated: _onViewCreated,
          );
    // 转场期间平台视图不跟随 Flutter 动画，直接隐藏（Offstage）避免截屏残留盖住内容。
    return IgnorePointer(
      ignoring: !widget.interactive,
      child: Offstage(offstage: _hidden, child: view),
    );
  }

  void _onViewCreated(int id) {
    final channel = MethodChannel('real_liquid_glass/glass_view_$id');
    _viewChannel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'tap') widget.onTap?.call();
    });
  }

  @override
  void dispose() {
    LiquidGlassVisibility.hiddenListenable.removeListener(_onVisibilityChanged);
    _viewChannel?.setMethodCallHandler(null);
    super.dispose();
  }
}
