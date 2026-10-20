#version 320 es
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Liquid Glass —— iOS 26 液态玻璃的片元着色器实现。
//
// 用法：ui.ImageFilter.shader(shader)，配合 BackdropFilter 作用在背景上。
//
// ## 坐标系（重要）
//
// 引擎（impeller/entity/contents/filters/runtime_effect_filter_contents.cc）
// 会把**第一个** vec2 uniform 自动改写成「输入快照纹理的像素尺寸」，并且
// FlutterFragCoord() 与采样坐标都落在这张纹理上。也就是说：
//
//   * 这里拿到的不是「逻辑像素」，而是「快照像素」；
//   * 所以我们自己算的几何（圆角、边缘带宽度）必须跟着换算。
//
// 解决办法：约定第一个 uniform 就是尺寸（引擎会覆盖它），第二个 uniform
// 传「逻辑尺寸」，第三个传 device pixel ratio。shader 内部一律用逻辑坐标
// 计算几何，只在最后采样时乘回比例。
//
//   逻辑坐标 = FlutterFragCoord() / u_scale
//
// 当玻璃尺寸变化时（滚动折叠、转场），只需要重设 u_size 与 u_scale 两个
// float，不必重建 shader。

#include <flutter/runtime_effect.glsl>

// 引擎会自动把输入快照的像素尺寸写进第一个 vec2 uniform。
uniform vec2 u_size;            // 快照像素尺寸（引擎写入，勿手工设置）
uniform vec2 u_logical_size;    // 玻璃的逻辑尺寸（像素 / u_scale）
uniform float u_scale;          // 快照像素 / 逻辑像素
uniform float u_corner;         // 上边圆角半径（逻辑像素）
uniform float u_corner_bottom;  // 下边圆角半径（贴屏幕底边的面板填 0）
uniform float u_refraction;     // 折光强度：regular ≈ 0.35，clear ≈ 0.7
uniform float u_highlight;      // 边缘高光强度
uniform float u_thickness;      // 内部厚度渐变强度
uniform float u_opacity;        // 整体不透明度系数
uniform float u_tint_strength;  // tint 混合强度（0 = 不着色）
uniform float u_ripple;         // 交互涟漪强度（0..1）
uniform vec2 u_ripple_center;   // 涟漪中心（逻辑坐标）
uniform vec4 u_tint;            // r,g,b,a
uniform float u_fade;           // 整块玻璃的淡入淡出（0 = 完全透明，露出原内容）

uniform sampler2D u_texture;

out vec4 frag_color;

// 圆角矩形的有符号距离场，上下圆角可以不同。
//
// 上下一分为二地各取一个半径：平直的边不受半径影响（r 在公式里恰好抵消），
// 只有四个角上的点才会用到所属半边的半径。贴屏幕底边的面板（底部弹层）就把
// 下边半径填 0，下缘才是齐的。
//
// 形状和 Flutter 侧的 ClipRRect 用同一条圆角矩形，边缘只被裁剪一次 ——
// 两边各抗锯齿一次反而会把边缘糊成一条灰边。
float corner_radius(vec2 p, float top, float bottom) {
  return p.y < 0.0 ? top : bottom;
}

float rrect_sdf(vec2 p, vec2 half_size, float radius) {
  vec2 q = abs(p) - half_size + vec2(radius);
  float outside = length(max(q, vec2(0.0)));
  float inside = min(max(q.x, q.y), 0.0);
  return outside + inside - radius;
}

// 边缘法线：折光位移与高光方向都要用。
vec2 rrect_normal(vec2 p, vec2 half_size, float radius) {
  vec2 q = abs(p) - half_size + vec2(radius);
  vec2 n = sign(p) * normalize(max(q, vec2(0.0001)));
  return normalize(n + vec2(0.0001));
}

void main() {
  // 快照像素 / 逻辑像素。优先用引擎写进来的真实快照尺寸反推 —— 转场里玻璃
  // 被缩放时快照分辨率会变，只有这个比值才是当下的真实比例；u_scale 只是
  // 拿不到快照尺寸时的兜底。
  vec2 derived = u_size / max(u_logical_size, vec2(1.0));
  float scale = (derived.x + derived.y) * 0.5;
  if (!(scale > 0.0001)) {
    scale = max(u_scale, 0.0001);
  }

  // 快照像素 → 逻辑坐标。
  vec2 frag = FlutterFragCoord().xy / scale;
  vec2 half_size = u_logical_size * 0.5;
  vec2 p = frag - half_size;

  float radius = min(
    corner_radius(p, u_corner, u_corner_bottom),
    min(half_size.x, half_size.y));
  float sdf = rrect_sdf(p, half_size, radius);

  // 形状外的像素完全透明。这里不做抗锯齿：Flutter 侧的 ClipRRect 用的是同一条
  // 圆角矩形，边缘由它抗锯齿，shader 再抗一次只会把边缘糊成一条灰边。
  if (sdf > 0.0) {
    discard;
  }

  // 到边缘的归一化距离：0 = 边缘，1 = 内部。
  float edge_band = max(radius * 0.55, 12.0);
  float edge = clamp(-sdf / edge_band, 0.0, 1.0);

  vec2 normal = rrect_normal(p, half_size, radius);

  // 折光：越靠边，采样越向内收（凸透镜）。再叠一点法线方向位移，
  // 边缘才像「包住」背后的画面。
  vec2 inward = -normal * (1.0 - edge) * u_refraction * edge_band;
  vec2 sample_logical = frag + inward;

  // 交互涟漪：从触点向外扩散的轻微缩放。Apple 的可交互玻璃按下时
  // 会有这层扰动。
  if (u_ripple > 0.001) {
    vec2 rp = (frag - u_ripple_center) / max(u_logical_size.x, u_logical_size.y);
    float d = length(rp);
    float wave = sin(d * 18.0 - 1.2) * exp(-d * 5.0) * u_ripple;
    sample_logical += normalize(rp + vec2(0.0001)) * wave * 12.0;
  }

  // 回到快照像素空间再采样。
  vec2 uv = (sample_logical * scale) / max(u_size, vec2(1.0));
  vec4 bg = texture(u_texture, clamp(uv, vec2(0.0), vec2(1.0)));

  // 厚度色：苹果的玻璃不是纯白也不是纯灰，是极淡的双向渐变。
  float vertical = frag.y / max(u_logical_size.y, 1.0);
  float thickness = (1.0 - vertical) * u_thickness;

  // 边缘高光：左上受光最亮；越靠边越亮。
  vec2 light_dir = normalize(vec2(-0.55, -0.83));
  float facing = max(dot(normal, light_dir), 0.0);
  float rim = pow(1.0 - edge, 2.2) * u_highlight * (0.35 + 0.65 * facing);

  // 贴着边缘的极细内描边 —— 苹果玻璃最标志性的那根高光线。
  float hairline = smoothstep(0.94, 1.0, edge) * u_highlight * 0.55;

  vec3 color = bg.rgb;
  color = mix(color, u_tint.rgb, u_tint.a * u_tint_strength);
  color += vec3(thickness * 0.045);
  color += vec3(rim + hairline);

  // 边缘轻微压暗，玻璃才有体积，不像一张贴纸。
  color *= 1.0 - pow(1.0 - edge, 3.0) * 0.06;

  float alpha = clamp(bg.a * u_opacity + rim + hairline, 0.0, 1.0);
  // 淡入淡出：整块输出（颜色 + alpha）一起缩。着色器滤镜的输出会**替换**
  // 背后的内容，所以 alpha 一低就自然露出原内容，等同于一次交叉淡入 ——
  // 不需要外面再套 Opacity（BackdropFilter 套在 Opacity 里取不到背景）。
  frag_color = vec4(clamp(color, 0.0, 1.0), alpha) * u_fade;
}
