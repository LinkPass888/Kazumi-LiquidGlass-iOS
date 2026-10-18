import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the current device can do, as reported by the native side.
@immutable
class LiquidGlassCapabilities {
  /// Creates a capabilities snapshot; normally obtained from
  /// [LiquidGlass.capabilities].
  const LiquidGlassCapabilities({
    required this.nativeGlass,
    required this.reduceTransparency,
    required this.osMajorVersion,
  });

  /// Whether real UIGlassEffect Liquid Glass is available (iOS 26+).
  final bool nativeGlass;

  /// Whether the user has enabled Reduce Transparency in system settings.
  ///
  /// Native glass adapts automatically; consult this if you render custom
  /// translucent surfaces of your own.
  final bool reduceTransparency;

  /// Major OS version (e.g. 26, 27), or 0 when unknown.
  final int osMajorVersion;

  /// Capabilities assumed where the plugin has no native side: no native
  /// glass, no known accessibility override.
  static const LiquidGlassCapabilities none = LiquidGlassCapabilities(
    nativeGlass: false,
    reduceTransparency: false,
    osMajorVersion: 0,
  );
}

/// Entry point for querying Liquid Glass support at runtime.
abstract final class LiquidGlass {
  static const MethodChannel _channel = MethodChannel('real_liquid_glass');
  static Future<LiquidGlassCapabilities>? _capabilities;

  /// Whether this platform hosts the native glass platform view.
  ///
  /// Kazumi 本地版：仅 iOS。iOS 26+ 是真玻璃，旧系统不再提供模糊兜底
  /// （项目最低目标系统为 iOS 26）。
  static bool get isNativePlatform => !kIsWeb;

  /// Device capabilities, fetched once and cached.
  ///
  /// Safe to call on every platform; resolves to
  /// [LiquidGlassCapabilities.none] where the plugin has no native side.
  static Future<LiquidGlassCapabilities> capabilities() {
    return _capabilities ??= _fetch();
  }

  static Future<LiquidGlassCapabilities> _fetch() async {
    if (!isNativePlatform) return LiquidGlassCapabilities.none;
    try {
      final raw =
          await _channel.invokeMapMethod<String, dynamic>('getCapabilities');
      if (raw == null) return LiquidGlassCapabilities.none;
      return LiquidGlassCapabilities(
        nativeGlass: raw['nativeGlass'] as bool? ?? false,
        reduceTransparency: raw['reduceTransparency'] as bool? ?? false,
        osMajorVersion: raw['osMajorVersion'] as int? ?? 0,
      );
    } on MissingPluginException {
      return LiquidGlassCapabilities.none;
    }
  }

  /// Test hook: replaces the cached capabilities.
  @visibleForTesting
  static void debugOverrideCapabilities(LiquidGlassCapabilities? value) {
    _capabilities = value == null ? null : Future.value(value);
  }
}
