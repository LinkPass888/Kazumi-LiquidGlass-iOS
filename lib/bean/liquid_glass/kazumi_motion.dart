import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

/// 全 App 统一的弹簧动效。
///
/// 苹果的界面里没有「线性过渡」：按下、抬起、展开、收起、切换，全部由弹簧
/// 物理驱动 —— 惯性、阻尼、回弹都是连续的。这里把用到的几组弹簧收敛成预设，
/// 别再各处写 `Curves.easeOutCubic` 或随手编一个 250ms。
///
/// 规则：
/// * **交互类**（按下、选中、展开、折叠、转场）一律用这里的弹簧；
/// * **循环类**（加载指示器、进度条）保留曲线 —— 弹簧没有「匀速循环」的语义。
///
/// 所有入口都会检查 [MediaQuery.disableAnimationsOf]：系统开启「减弱动态效果」
/// 时直接落到终值，不做动画。
abstract final class KazumiMotion {
  /// 按下 / 抬起：刚度高、几乎不振荡，手感是「清脆」而不是「弹跳」。
  static final SpringDescription press = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 700,
    ratio: 1.0,
  );

  /// 选中态迁移（标签栏胶囊、分段控件）。
  static final SpringDescription select = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 380,
    ratio: 0.8,
  );

  /// 展开 / 收起（面板、折叠头、列表项）。
  static final SpringDescription expand = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 260,
    ratio: 0.86,
  );

  /// Sheet / 对话框入场。
  static final SpringDescription sheet = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 380,
    ratio: 0.8,
  );

  /// 由弹簧换算出来的「先快后慢」曲线。
  ///
  /// 隐式动画（`TweenAnimationBuilder` / `AnimatedOpacity` 这类）只接受
  /// [Curve]，没法直接跑 `SpringSimulation`。这条曲线是欠阻尼弹簧（[select]）
  /// 的响应形状，数值上不会越过 1 —— 缩放、透明度这类**越界就出问题**的
  /// 属性必须用它，而不是 `Curves.easeOutBack`。
  static const Curve springDecel = Cubic(0.16, 0.84, 0.24, 1.0);

  /// 淡入淡出 / 位置迁移的默认曲线，等价于 [springDecel]。
  static const Curve appear = springDecel;

  /// 交互类隐式动画的统一时长。和 [springDecel] 一起用，手感接近弹簧。
  static const Duration short = Duration(milliseconds: 220);

  /// 按下时的缩放比例。苹果的按钮按下会轻微内收。
  static const double pressedScale = 0.97;

  /// 普通点击的触感反馈。
  static void hapticTap() => HapticFeedback.lightImpact();

  /// 选中 / 切换的触感反馈。
  static void hapticSelect() => HapticFeedback.selectionClick();

  /// 把 [controller] 用弹簧推到 [target]（起始值是它当前的值）。
  ///
  /// 返回一个可以直接驱动 `AnimatedBuilder` 的动画；多次调用会打断上一次
  /// 弹簧，从当前位置继续 —— 这正是苹果那种「可打断」的手感。
  static void springTo(
    AnimationController controller,
    double target, {
    SpringDescription? description,
    double velocity = 0,
  }) {
    description ??= press;
    controller.animateWith(
      SpringSimulation(
        description,
        controller.value,
        target,
        velocity,
        snapToEnd: false,
      ),
    );
  }

  /// 一个由弹簧驱动的按下反馈包装。
  ///
  /// 按下时缩到 [KazumiMotion.pressedScale]，抬起/取消时弹回 1，全程走弹簧。
  /// 用 `Listener` 而不是 `GestureDetector` 的 `onTapDown`，是为了不吞掉子控件
  /// 自己的手势识别（玻璃按钮里往往还嵌着真正的按钮）。
  static Widget pressable({
    Key? key,
    required Widget child,
    VoidCallback? onTap,
    ValueChanged<TapDownDetails>? onTapDown,
    VoidCallback? onTapUp,
    double scale = pressedScale,
    bool haptic = true,
  }) {
    return _PressableSpring(
      key: key,
      onTap: onTap,
      onTapDown: onTapDown,
      onTapUp: onTapUp,
      pressedScale: scale,
      haptic: haptic,
      child: child,
    );
  }

  /// 一个由弹簧驱动、值在 [0, 1] 之间推进的控制器。
  ///
  /// 适合「展开 / 收起」这类只需要一个 0→1 进度的场景。调用方持有
  /// [AnimationController]，这里只负责用弹簧推进它。
  static void springOpen(AnimationController controller,
      {bool open = true, SpringDescription? description}) {
    springTo(controller, open ? 1 : 0, description: description ?? expand);
  }
}

class _PressableSpring extends StatefulWidget {
  const _PressableSpring({
    super.key,
    required this.child,
    required this.pressedScale,
    required this.haptic,
    this.onTap,
    this.onTapDown,
    this.onTapUp,
  });

  final Widget child;
  final double pressedScale;
  final bool haptic;
  final VoidCallback? onTap;
  final ValueChanged<TapDownDetails>? onTapDown;
  final VoidCallback? onTapUp;

  @override
  State<_PressableSpring> createState() => _PressableSpringState();
}

class _PressableSpringState extends State<_PressableSpring>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _to(double target) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _controller.value = target;
      return;
    }
    KazumiMotion.springTo(_controller, target);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        _to(widget.pressedScale);
        widget.onTapDown?.call(
          TapDownDetails(globalPosition: event.position, localPosition: event.localPosition),
        );
      },
      onPointerUp: (event) {
        _to(1);
        widget.onTapUp?.call();
      },
      onPointerCancel: (event) {
        _to(1);
        widget.onTapUp?.call();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap == null
            ? null
            : () {
                if (widget.haptic) KazumiMotion.hapticTap();
                widget.onTap!();
              },
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) => Transform.scale(
            scale: _controller.value.isFinite && _controller.value > 0
                ? _controller.value
                : 1,
            child: child,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 把 [0,1] 的线性进度映射成 iOS 那种「先快后慢」的收敛曲线。
///
/// 只用于**循环类**动画（例如加载骨架的呼吸）；交互类请用弹簧。
double easeOutQuart(double t) => 1 - math.pow(1 - t, 4).toDouble();
