import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:kazumi/bean/liquid_glass/glass_material.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_motion.dart';
import 'package:kazumi/bean/liquid_glass/liquid_glass.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/utils/constants.dart';

export 'kazumi_alert.dart';

/// Single-use ownership of a route, including before its first frame.
class KazumiDialogHandle<T> {
  Route<T>? _route;
  bool _used = false;
  bool _dismissed = false;

  bool get isActive => !_dismissed && (_route?.isActive ?? false);

  void dismiss({T? popWith}) {
    if (_dismissed) return;
    _dismissed = true;
    final route = _route;
    if (route != null) KazumiDialog._dismissRoute(route, popWith);
  }

  void _attach(Route<T> route) {
    _used = true;
    _route = route;
  }

  void _finish() {
    _dismissed = true;
    _route = null;
  }
}

class KazumiDialog {
  static final KazumiDialogObserver observer = KazumiDialogObserver();
  // Allows modal sheets to use the same dismissal and route tracking.
  static const routeSettings = RouteSettings(name: 'KazumiDialog');

  /// 对话框入场：先淡入，同时从 0.92 轻微放大到 1。
  ///
  /// Material 默认是 150ms 的线性缩放，弹窗像「贴」上去的；这里时长略长、
  /// 前段快后段缓，落下来更接近系统弹窗的手感。
  static const AnimationStyle dialogAnimationStyle = AnimationStyle(
    duration: Duration(milliseconds: 260),
    reverseDuration: Duration(milliseconds: 180),
  );
  static int _toastRevision = 0;

  KazumiDialog._internal();

  static Future<T?> show<T>({
    BuildContext? context,
    KazumiDialogHandle<T>? handle,
    bool clickMaskDismiss = true,
    FutureOr<void> Function()? onDismiss,
    Duration? transitionDuration,
    RouteTransitionsBuilder? transitionBuilder,
    required WidgetBuilder builder,
  }) async {
    final dialog = handle ?? KazumiDialogHandle<T>();
    if (dialog._used) {
      throw StateError('A dialog handle can only be used once.');
    }
    try {
      final ctx = context ??
          rootNavigatorKey.currentContext ??
          observer.navigator?.context;
      if (ctx == null || !ctx.mounted || dialog._dismissed) return null;
      final navigator = Navigator.of(ctx, rootNavigator: true);
      final route = _KazumiDialogRoute<T>(
        context: ctx,
        builder: builder,
        themes: InheritedTheme.capture(from: ctx, to: navigator.context),
        // 弹窗是玻璃，遮罩太重会把背后的内容压死、折射也就没东西可折。
        barrierColor: DialogTheme.of(ctx).barrierColor ??
            Theme.of(ctx).dialogTheme.barrierColor ??
            Colors.black.withValues(alpha: 0.32),
        barrierDismissible: clickMaskDismiss,
        traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
        settings: routeSettings,
        animationStyle: transitionDuration == null
            ? dialogAnimationStyle
            : AnimationStyle(duration: transitionDuration),
        transitionBuilder: transitionBuilder ?? _springScaleFade,
      );
      dialog._attach(route);
      return await navigator.push<T>(route);
    } catch (e) {
      debugPrint('Kazumi Dialog Error: Failed to show dialog: $e');
      return null;
    } finally {
      dialog._finish();
      await onDismiss?.call();
    }
  }

  /// 对话框动画的曲线：从欠阻尼弹簧换算出来的减速曲线。
  ///
  /// 路由动画拿到的是 [Animation]，`Transition` 又只吃 [Curve]，没法直接跑
  /// `SpringSimulation`。这条曲线就是弹簧的响应形状，而且不会越过 [1] ——
  /// 透明度越界会被框架断言拦下。
  static const Curve springCurve = KazumiMotion.springDecel;

  static Widget _springScaleFade(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        // 只在开头快、结尾缓，值不会越过 1，配合下面的缩放正好。
        curve: const Interval(0, 0.7, curve: springCurve),
      ),
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.92, end: 1).animate(
          CurvedAnimation(parent: animation, curve: springCurve),
        ),
        child: child,
      ),
    );
  }

  static void showToast({
    required String message,
    BuildContext? context,
    bool showActionButton = false,
    String? actionLabel,
    VoidCallback? onActionPressed,
    Duration duration = const Duration(seconds: 2),
  }) {
    final messenger = _resolveScaffoldMessenger(context);
    if (messenger != null && messenger.mounted) {
      final toastContext =
          context != null && context.mounted ? context : messenger.context;
      try {
        _toastRevision++;
        final double maxWidth =
            MediaQuery.sizeOf(toastContext).width > LayoutBreakpoint.medium['width']!
                ? 600
                : double.infinity;
        messenger
          ..removeCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              // 吐司就是一块玻璃：背景、内边距、圆角都由玻璃自己给，
              // 框架那层实色面板必须让开，否则玻璃底下会再垫一块不透明底。
              backgroundColor: Colors.transparent,
              elevation: 0,
              padding: EdgeInsets.zero,
              // width 和 margin 不能同时给：宽屏限宽时用 width（框架会自己
              // 居中），窄屏用 margin —— 否则会撞上 SnackBar 的断言。
              behavior: SnackBarBehavior.floating,
              width: maxWidth.isFinite ? maxWidth : null,
              margin: maxWidth.isFinite
                  ? null
                  : const EdgeInsets.fromLTRB(16, 0, 16, 16),
              duration: duration,
              persist: false,
              content: KazumiLiquidGlass(
                kind: GlassSurfaceKind.dialog,
                shape: LiquidGlassShape.capsule(),
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: showActionButton ? 0 : 12,
                        ),
                        child: Text(message),
                      ),
                    ),
                    if (showActionButton)
                      TextButton(
                        onPressed: () {
                          // 先关掉当前这条吐司，再执行动作 —— 动作里往往会再
                          // 弹一条新的（「已复制」→「已打开」），不关就会排队。
                          messenger.hideCurrentSnackBar();
                          if (onActionPressed != null) {
                            scheduleMicrotask(onActionPressed);
                          }
                        },
                        child: Text(actionLabel ?? '关闭'),
                      ),
                  ],
                ),
              ),
            ),
          );
      } catch (e) {
        debugPrint('Kazumi Dialog Error: Failed to show toast: $e');
      }
    } else {
      debugPrint(
          'Kazumi Dialog Error: No ScaffoldMessenger available to show Toast');
    }
  }

  static void dismiss<T>({BuildContext? context, T? popWith}) {
    if (context != null && !context.mounted) return;
    final route =
        context == null ? observer._lastDialogRoute : ModalRoute.of(context);
    if (route != null && route.settings.name == routeSettings.name) {
      _dismissRoute(route, popWith);
    }
  }

  static void _dismissRoute<T>(Route<T> route, T? result) {
    if (!route.isActive) return;
    // Owners may be disposed while Navigator is reconciling its routes.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _dismissRoute(route, result);
      });
      return;
    }
    final navigator = route.navigator;
    if (navigator == null || !navigator.mounted) return;
    if (route.isCurrent) {
      navigator.pop<T>(result);
    } else {
      navigator.removeRoute<T>(route, result);
    }
  }

  static ScaffoldMessengerState? _resolveScaffoldMessenger(
    BuildContext? context,
  ) {
    if (context != null && context.mounted) {
      final scopedMessenger = ScaffoldMessenger.maybeOf(context);
      if (scopedMessenger != null) {
        return scopedMessenger;
      }
    }
    return rootScaffoldMessengerKey.currentState;
  }
}

class _KazumiDialogRoute<T> extends DialogRoute<T> {
  _KazumiDialogRoute({
    required super.context,
    required super.builder,
    super.themes,
    super.barrierColor,
    super.barrierDismissible,
    super.traversalEdgeBehavior,
    super.settings,
    super.animationStyle,
    this.transitionBuilder,
  });

  final RouteTransitionsBuilder? transitionBuilder;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      transitionBuilder?.call(context, animation, secondaryAnimation, child) ??
      super.buildTransitions(context, animation, secondaryAnimation, child);
}

class KazumiDialogObserver extends NavigatorObserver {
  final List<Route<dynamic>> _kazumiDialogRoutes = [];
  bool _snackBarClearScheduled = false;

  bool get hasKazumiDialog => _kazumiDialogRoutes.isNotEmpty;

  Route<dynamic>? get _lastDialogRoute =>
      _kazumiDialogRoutes.isEmpty ? null : _kazumiDialogRoutes.last;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (_isKazumiDialogRoute(route)) {
      _kazumiDialogRoutes.add(route);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (route is PageRoute) _scheduleSnackBarClear();
    if (_isKazumiDialogRoute(route)) {
      _kazumiDialogRoutes.remove(route);
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (oldRoute is PageRoute) _scheduleSnackBarClear();
    if (_isKazumiDialogRoute(oldRoute)) {
      _kazumiDialogRoutes.remove(oldRoute);
    }
    if (newRoute != null && _isKazumiDialogRoute(newRoute)) {
      _kazumiDialogRoutes.add(newRoute);
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    if (route is PageRoute) _scheduleSnackBarClear();

    if (_isKazumiDialogRoute(route)) {
      _kazumiDialogRoutes.remove(route);
    }
  }

  bool _isKazumiDialogRoute(Route<dynamic>? route) =>
      route?.settings.name == KazumiDialog.routeSettings.name;

  void _scheduleSnackBarClear() {
    if (_snackBarClearScheduled) return;
    _snackBarClearScheduled = true;
    final revision = KazumiDialog._toastRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _snackBarClearScheduled = false;
      // Only clear the old page's toast, never one posted after navigation.
      if (revision == KazumiDialog._toastRevision) {
        rootScaffoldMessengerKey.currentState?.removeCurrentSnackBar();
      }
    });
  }
}
