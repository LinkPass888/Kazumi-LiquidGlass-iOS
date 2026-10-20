import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 液态玻璃着色器的加载与 uniform 写入。
///
/// 单独成文件是为了让「着色器」这一层的生命周期清楚：
///
/// * [FragmentProgram] 全进程只加载一次（编译很贵，且与尺寸无关）；
/// * 每个玻璃实例持有自己的 [ui.FragmentShader]（uniform 是实例状态）；
/// * 尺寸变化时只重写 float，不重建对象 —— 滚动折叠、转场时每帧都会变。
///
/// uniform 的排列顺序必须和 `assets/shaders/liquid_glass.frag` 完全一致。
/// 特别注意第一个 `vec2 u_size`：引擎会用输入快照的像素尺寸**覆盖**它，
/// 我们绝不能依赖自己写进去的值（见 impeller 的
/// `runtime_effect_filter_contents.cc`）。
abstract final class GlassShader {
  static ui.FragmentProgram? _program;
  static bool _failed = false;

  /// 着色器是否可用。
  ///
  /// 非 Impeller 后端（或在测试环境里）不可用，此时调用方退化为纯磨砂玻璃。
  static bool get isSupported => ui.ImageFilter.isShaderFilterSupported;

  /// 加载（或复用）着色器程序。返回 null 表示不可用。
  static Future<ui.FragmentProgram?> loadProgram() async {
    if (_program != null) return _program;
    if (_failed || !isSupported) return null;
    try {
      _program = await ui.FragmentProgram.fromAsset(_shaderAsset);
      return _program;
    } catch (error, stack) {
      _failed = true;
      debugPrint('Liquid glass shader failed to load: $error\n$stack');
      return null;
    }
  }

  /// 已经同步加载好时直接取用（用于 build 中的快速路径）。
  static ui.FragmentProgram? get program => _program;

  /// 同步预加载入口，供 `main()` 调用。
  static Future<void> preload() => loadProgram();

  /// 为一个玻璃实例创建 shader，并写入与尺寸相关的 uniform。
  static ui.FragmentShader? createShader() {
    final program = _program;
    if (program == null) return null;
    return program.fragmentShader();
  }

  /// 写入所有 uniform。
  ///
  /// [size] 是玻璃的逻辑尺寸；[pixelRatio] 用来在 shader 内把快照像素
  /// 换算回逻辑坐标。
  static void writeUniforms(
    ui.FragmentShader shader, {
    required double width,
    required double height,
    required double pixelRatio,
    required double corner,
    required double cornerBottom,
    required double refraction,
    required double highlight,
    required double thickness,
    required double opacity,
    required double tintStrength,
    required ui.Color? tint,
    required double ripple,
    required ui.Offset rippleCenter,
    double fade = 1,
  }) {
    var index = 0;
    // u_size（vec2）—— 由引擎覆盖为快照像素尺寸，这里写一个占位值即可。
    shader.setFloat(index++, 1);
    shader.setFloat(index++, 1);
    // u_logical_size（vec2）
    shader.setFloat(index++, width);
    shader.setFloat(index++, height);
    // u_scale
    shader.setFloat(index++, pixelRatio);
    // u_corner
    shader.setFloat(index++, corner);
    // u_corner_bottom
    shader.setFloat(index++, cornerBottom);
    // u_refraction
    shader.setFloat(index++, refraction);
    // u_highlight
    shader.setFloat(index++, highlight);
    // u_thickness
    shader.setFloat(index++, thickness);
    // u_opacity
    shader.setFloat(index++, opacity);
    // u_tint_strength
    shader.setFloat(index++, tintStrength);
    // u_ripple
    shader.setFloat(index++, ripple);
    // u_ripple_center（vec2）
    shader.setFloat(index++, rippleCenter.dx);
    shader.setFloat(index++, rippleCenter.dy);
    // u_tint（vec4）
    shader.setFloat(index++, tint?.r ?? 0);
    shader.setFloat(index++, tint?.g ?? 0);
    shader.setFloat(index++, tint?.b ?? 0);
    shader.setFloat(index++, tint?.a ?? 0);
    // u_fade
    shader.setFloat(index++, fade);
  }

  static const String _shaderAsset = 'assets/shaders/liquid_glass.frag';
}
