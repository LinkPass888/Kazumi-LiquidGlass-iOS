/// Kazumi 本地插件：iOS 原生 UIGlassEffect 液态玻璃。
///
/// 从 real_liquid_glass fork 并瘦身：剔除了旧系统 UIBlurEffect 兜底、
/// Android/Desktop/macOS 的 Flutter 磨砂 fallback。现仅支持 iOS；
/// 非 iOS 不渲染任何玻璃（空占位），调用方自行处理。
library;

export 'src/bottom_bar.dart';
export 'src/capabilities.dart';
export 'src/glass_container.dart';
export 'src/glass_style.dart';
export 'src/native_glass_view.dart' show LiquidGlassVisibility;

