import 'package:flutter/material.dart';

import 'dart:ui' as ui;

import 'package:kazumi/bean/liquid_glass/glass_material.dart';
import 'package:kazumi/bean/liquid_glass/glass_shader.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_motion.dart';

/// 玻璃的形状。
///
/// 形状由着色器的距离场决定，Flutter 侧用同一条圆角矩形裁剪 —— 两者必须
/// 完全一致，边缘才只被抗锯齿一次。
class LiquidGlassShape {
  const LiquidGlassShape.capsule()
      : capsule = true,
        cornerRadius = 0,
        bottomCornerRadius = 0;

  const LiquidGlassShape.roundedRectangle(
    this.cornerRadius, {
    double? bottom,
  })  : capsule = false,
        bottomCornerRadius = bottom ?? cornerRadius;

  /// 贴着屏幕底边的面板（底部弹层）：上边圆角、下边齐平。
  const LiquidGlassShape.sheet(this.cornerRadius)
      : capsule = false,
        bottomCornerRadius = 0;

  final bool capsule;

  /// 上边圆角；[capsule] 为 true 时忽略。
  final double cornerRadius;

  /// 下边圆角；默认和上边相同。
  final double bottomCornerRadius;

  /// 在当前尺寸下的上边圆角（胶囊取短边一半）。
  double radiusFor(Size size) => capsule ? size.shortestSide / 2 : cornerRadius;

  /// 在当前尺寸下的下边圆角。
  double bottomRadiusFor(Size size) =>
      capsule ? size.shortestSide / 2 : bottomCornerRadius;

  BorderRadius borderRadiusFor(Size size) => BorderRadius.vertical(
        top: Radius.circular(radiusFor(size)),
        bottom: Radius.circular(bottomRadiusFor(size)),
      );

  @override
  bool operator ==(Object other) =>
      other is LiquidGlassShape &&
      other.capsule == capsule &&
      other.cornerRadius == cornerRadius &&
      other.bottomCornerRadius == bottomCornerRadius;

  @override
  int get hashCode => Object.hash(capsule, cornerRadius, bottomCornerRadius);
}

/// 一块真正的液态玻璃：折光、磨砂、边缘高光，全部在 Flutter 图层内完成。
///
/// 与旧的 `UiKitView` 实现最根本的区别：它**属于 Flutter 图层树**，可以参与
/// 裁剪、Hero 飞行、路由转场、弹层与弹窗。因此既不会在转场时留下「截屏残留」，
/// 也不会在弹窗里渲染成一大块遮挡 —— 那两条限制是平台视图独有的。
///
/// ```dart
/// KazumiLiquidGlass(
///   kind: GlassSurfaceKind.appBar,
///   shape: const LiquidGlassShape.capsule(),
///   padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
///   child: const Text('正在播放'),
/// )
/// ```
///
/// 材质不写 regular / clear 字面量，而写场景 [kind]：场景到材质的映射集中在
/// [GlassMaterial.of]，调整某个场景只改那一处。
class KazumiLiquidGlass extends StatefulWidget {
  const KazumiLiquidGlass({
    super.key,
    this.child,
    this.kind = GlassSurfaceKind.groupedSurface,
    this.material,
    this.shape = const LiquidGlassShape.roundedRectangle(24),
    this.tint,
    this.interactive = false,
    this.onTap,
    this.padding,
    this.margin,
    this.alignment,
    this.width,
    this.height,
    this.fade = 1,
  });

  /// 画在玻璃之上的内容。
  final Widget? child;

  /// 场景种类；决定 regular / clear 材质。
  final GlassSurfaceKind kind;

  /// 显式指定材质。为 null 时由 [kind] 决定，一般不要传。
  final GlassMaterial? material;

  final LiquidGlassShape shape;

  /// 可选染色。苹果建议玻璃尽量不着色，只在强调态用。
  final Color? tint;

  /// 按下时是否播放可交互反馈（缩放 + 涟漪）。
  final bool interactive;

  /// 点击回调；提供时自动开启可交互。
  final VoidCallback? onTap;

  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final AlignmentGeometry? alignment;
  final double? width;
  final double? height;

  /// 整块玻璃的淡入淡出（0 = 完全透明，露出原本的内容）。
  ///
  /// 不能改用 `Opacity` 包玻璃：那会插一层 `saveLayer`，`BackdropFilter`
  /// 采到的不再是页面，而是一张空图层 —— 玻璃会变灰。这里把系数交给着色器，
  /// 让它连同颜色一起衰减，效果等同交叉淡入。
  final double fade;

  @override
  State<KazumiLiquidGlass> createState() => _KazumiLiquidGlassState();
}

class _KazumiLiquidGlassState extends State<KazumiLiquidGlass> {
  /// 涟漪起点；非 null 表示正在播放按下涟漪。
  Offset? _rippleOrigin;

  void _handleTapDown(TapDownDetails details) {
    setState(() => _rippleOrigin = details.localPosition);
  }

  void _handleTapUp() {
    // 涟漪播完再清掉，避免提前归零导致跳变。
    Future<void>.delayed(const Duration(milliseconds: 420), () {
      if (mounted) setState(() => _rippleOrigin = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final material = widget.material ??
        GlassMaterial.debugOverride ??
        GlassMaterial.of(widget.kind);
    final resolvedMaterial = material.forBrightness(brightness);
    final interactive = widget.interactive || widget.onTap != null;

    Widget? content = widget.child;
    if (widget.alignment != null && content != null) {
      content = Align(alignment: widget.alignment!, child: content);
    }
    if (widget.padding != null && content != null) {
      content = Padding(padding: widget.padding!, child: content);
    }

    // 玻璃和内容必须画在**同一棵** Stack 里：玻璃是背景，内容叠在上面。
    // 反过来（内容当 Stack 的 child、玻璃当 background）时，BackdropFilter
    // 会把自己绘制到「已经画好的内容」上，高光边缘那层半透明白会把文字压灰。
    Widget result = Stack(
      fit: StackFit.passthrough,
      children: [
        // 玻璃层：只改写背景，不接收触摸。
        Positioned.fill(
          child: RepaintBoundary(
            child: GlassBackdrop(
              shape: widget.shape,
              material: resolvedMaterial,
              tint: widget.tint,
              ripple: _rippleOrigin == null ? 0 : 1,
              rippleCenter: _rippleOrigin ?? Offset.zero,
              fade: widget.fade,
            ),
          ),
        ),
        ?content,
      ],
    );

    if (widget.width != null || widget.height != null) {
      result = SizedBox(
        width: widget.width,
        height: widget.height,
        child: result,
      );
    }

    if (interactive) {
      result = KazumiMotion.pressable(
        onTap: widget.onTap,
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        child: result,
      );
    }

    if (widget.margin != null) {
      result = Padding(padding: widget.margin!, child: result);
    }
    return result;
  }
}

/// 只负责「改写背后内容」的那一层玻璃。
///
/// 渲染栈（自下而上）：
///
/// ```
/// ClipRRect                                  // 让滤镜只在玻璃形状内生效
///  └ BackdropFilter.grouped(filterConfig)    // 磨砂 + 折光，作用于背景
///     └ SizedBox.expand()                    // 给滤镜一块画布
/// ```
///
/// 关键点：滤镜是 `BackdropFilter` 的，作用对象是**背后的内容**；子树只需要
/// 有尺寸，不需要真的画东西。
///
/// 着色器与磨砂被合成到同一个 `ImageFilterConfig.compose` 里，这样引擎只做
/// 一次背景采样 —— 分两层的话每层各采样一次，面积大的玻璃会明显掉帧。
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({
    super.key,
    required this.shape,
    required this.material,
    this.tint,
    this.ripple = 0,
    this.rippleCenter = Offset.zero,
    this.fade = 1,
  });

  final LiquidGlassShape shape;
  final GlassMaterial material;
  final Color? tint;
  final double ripple;
  final Offset rippleCenter;
  final double fade;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(
          constraints.hasBoundedWidth ? constraints.maxWidth : 0,
          constraints.hasBoundedHeight ? constraints.maxHeight : 0,
        );
        final radius = shape.radiusFor(size);

        return ClipRRect(
          // 着色器用的是同一条圆角矩形（见 liquid_glass.frag 的 rrect_sdf），
          // 裁剪在这里做抗锯齿；磨砂层也需要一个正确的边界（bounded blur
          // 依赖它），否则模糊会在形状外溢出一圈。
          borderRadius: shape.borderRadiusFor(size),
          child: _GlassFilters(
            size: size,
            radius: radius,
            bottomRadius: shape.bottomRadiusFor(size),
            material: material,
            tint: tint,
            ripple: ripple,
            rippleCenter: rippleCenter,
            fade: fade,
          ),
        );
      },
    );
  }
}

/// 磨砂 + 折光，合成成一次背景采样。
class _GlassFilters extends StatefulWidget {
  const _GlassFilters({
    required this.size,
    required this.radius,
    required this.bottomRadius,
    required this.material,
    this.tint,
    this.ripple = 0,
    this.rippleCenter = Offset.zero,
    this.fade = 1,
  });

  final Size size;
  final double radius;
  final double bottomRadius;
  final GlassMaterial material;
  final Color? tint;
  final double ripple;
  final Offset rippleCenter;
  final double fade;

  @override
  State<_GlassFilters> createState() => _GlassFiltersState();
}

class _GlassFiltersState extends State<_GlassFilters> {
  ui.FragmentShader? _shader;
  bool _loadRequested = false;

  @override
  void initState() {
    super.initState();
    _ensureShader();
  }

  void _ensureShader() {
    if (_shader != null || _loadRequested) return;
    _loadRequested = true;
    if (GlassShader.program != null) {
      _shader = GlassShader.createShader();
      return;
    }
    GlassShader.loadProgram().then((program) {
      if (!mounted || program == null) return;
      setState(() => _shader = GlassShader.createShader());
    });
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  ImageFilterConfig _filterConfig(double pixelRatio) {
    final ImageFilterConfig frost = ImageFilterConfig.blur(
      sigmaX: widget.material.blurSigma,
      sigmaY: widget.material.blurSigma,
      // bounded：只在自身边界内采样 —— 引擎里复刻 iOS 磨砂玻璃的模式。
      bounded: true,
    );

    final shader = _shader;
    if (shader == null) return frost;

    GlassShader.writeUniforms(
      shader,
      width: widget.size.width,
      height: widget.size.height,
      pixelRatio: pixelRatio,
      corner: widget.radius,
      cornerBottom: widget.bottomRadius,
      refraction: widget.material.refraction,
      highlight: widget.material.highlight,
      thickness: widget.material.thickness,
      opacity: widget.material.opacity,
      tintStrength: widget.tint == null ? 0 : 1,
      tint: widget.tint == null ? null : ui.Color(widget.tint!.toARGB32()),
      ripple: widget.ripple,
      rippleCenter: widget.rippleCenter,
      fade: widget.fade,
    );

    // 先磨砂、再折光：顺序反过来的话，模糊会把刚算出来的高光边缘涂平。
    return ImageFilterConfig.compose(
      outer: ImageFilterConfig(ui.ImageFilter.shader(shader)),
      inner: frost,
    );
  }

  @override
  Widget build(BuildContext context) {
    _ensureShader();
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return BackdropFilter.grouped(
      filterConfig: _filterConfig(pixelRatio),
      child: const SizedBox.expand(),
    );
  }
}
