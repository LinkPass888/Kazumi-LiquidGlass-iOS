import 'package:flutter/widgets.dart';

import 'capabilities.dart';
import 'glass_style.dart';
import 'native_glass_view.dart';

/// A container whose background is Liquid Glass.
///
/// On iOS 26+ this hosts Apple's real glass material (UIGlassEffect), so it
/// refracts the content behind it and automatically follows system
/// appearance — the iOS 27 transparency slider, Reduce Transparency, and
/// Increase Contrast all just work. Where native glass is unavailable this
/// renders an empty placeholder (no Flutter-drawn fallback).
///
/// Use it like a [Container]:
///
/// ```dart
/// LiquidGlassContainer(
///   shape: const LiquidGlassShape.capsule(),
///   padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
///   child: const Text('Now playing'),
/// )
/// ```
class LiquidGlassContainer extends StatelessWidget {
  /// Creates a glass container. Provide a [child], explicit [width] and
  /// [height], or both.
  const LiquidGlassContainer({
    super.key,
    this.child,
    this.style = LiquidGlassStyle.regular,
    this.shape = const LiquidGlassShape.roundedRectangle(24),
    this.tint,
    this.interactive = false,
    this.onTap,
    this.padding,
    this.margin,
    this.alignment,
    this.width,
    this.height,
  });

  /// Content rendered on top of the glass.
  final Widget? child;

  /// Material variant; see [LiquidGlassStyle].
  final LiquidGlassStyle style;

  /// Outline of the surface. Defaults to a 24px continuous-corner
  /// rounded rectangle; use [LiquidGlassShape.capsule] for bars.
  final LiquidGlassShape shape;

  /// Optional tint mixed into the material (use sparingly — Apple's
  /// guidance is that glass reads best untinted).
  final Color? tint;

  /// When true, the native glass reacts to touch with Apple's shimmer /
  /// bounce (iOS 26+ only). Leave false for purely decorative surfaces so
  /// touches pass through to Flutter widgets behind the container.
  final bool interactive;

  /// Called when the surface is tapped. On iOS this is delivered by the
  /// native glass view, so Apple's interactive shimmer and the callback share
  /// the same touch. Supplying a callback automatically enables interaction.
  final VoidCallback? onTap;

  /// Inner padding around [child].
  final EdgeInsetsGeometry? padding;

  /// Outer margin around the glass surface.
  final EdgeInsetsGeometry? margin;

  /// How to align [child] within an oversized container.
  final AlignmentGeometry? alignment;

  /// Optional fixed dimensions.
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final Widget surface;
    if (!LiquidGlass.isNativePlatform) {
      // Kazumi 本地版：非 iOS 平台不再画 Flutter 磨砂 fallback，给一个空占位。
      surface = const SizedBox.expand();
    } else {
      surface = NativeGlassView(
        style: style,
        shape: shape,
        tint: tint,
        interactive: interactive || onTap != null,
        onTap: onTap,
      );
    }

    Widget? content = child;
    if (alignment != null && content != null) {
      content = Align(alignment: alignment!, child: content);
    }
    if (padding != null && content != null) {
      content = Padding(padding: padding!, child: content);
    }

    Widget result = Stack(
      children: [
        Positioned.fill(child: surface),
        ?content,
      ],
    );

    if (width != null || height != null) {
      result = SizedBox(width: width, height: height, child: result);
    }
    if (margin != null) {
      result = Padding(padding: margin!, child: result);
    }
    if (onTap != null && !LiquidGlass.isNativePlatform) {
      result = GestureDetector(onTap: onTap, child: result);
    }
    return result;
  }
}
