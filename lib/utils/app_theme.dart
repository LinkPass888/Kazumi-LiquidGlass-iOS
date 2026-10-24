import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/bean/settings/theme_provider.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/theme.dart';

/// 按已保存的设置应用主题：深色模式、主题色与 OLED 纯黑。
///
/// [AppWidget] 在启动时调用（此时页面还在构建，[notify] 保持 false）；
/// 导入设置备份后以 `notify: true` 再调用一次，界面立即换上新主题。
void applyStoredThemeSettings(
  ThemeProvider themeProvider, {
  bool notify = false,
}) {
  themeProvider.setThemeMode(_storedThemeMode(), notify: notify);

  final color = _storedThemeColor();
  final oledEnhance = GStorage.getSetting(SettingsKeys.oledEnhance);
  final defaultDarkTheme = appTheme(
    brightness: Brightness.dark,
    color: color,
  );
  themeProvider.setTheme(
    appTheme(
      brightness: Brightness.light,
      color: color,
    ),
    oledEnhance ? oledDarkTheme(defaultDarkTheme) : defaultDarkTheme,
    notify: notify,
  );
}

ThemeMode _storedThemeMode() {
  return switch (GStorage.getSetting(SettingsKeys.themeMode)) {
    'dark' => ThemeMode.dark,
    'light' => ThemeMode.light,
    _ => ThemeMode.system,
  };
}

Color _storedThemeColor() {
  final defaultThemeColor = GStorage.getSetting(SettingsKeys.themeColor);
  if (defaultThemeColor == 'default') {
    return Colors.green;
  }
  return Color(int.parse(defaultThemeColor, radix: 16));
}

ThemeData appTheme({
  required Brightness brightness,
  Color? color,
}) {
  // 全局圆角：整个 App 的「一块面」都用同一个半径（见 KazumiGlass.radiusOf）。
  // 这里按窗口短边算一次 —— 主题是脱离 BuildContext 构建的，拿不到 MediaQuery。
  final double radius = KazumiGlass.radiusFor(_windowShortestSide());
  final BorderRadius globalRadius = BorderRadius.circular(radius);
  final RoundedRectangleBorder globalShape =
      RoundedRectangleBorder(borderRadius: globalRadius);
  // 下面两处是往 Apple 观感靠的最小改动（细节见各自注释）：
  // 1) 压低 Material 3 的「表面着色」（surfaceTint）：M3 会给卡片 / 弹窗 /
  //    菜单叠一层主题色的半透明覆盖，苹果的界面是中性灰面，不这么做白面上
  //    会泛出一层莫名的绿/紫。
  // 2) 点按反馈从 M3 的 InkSparkle（Android 上会溅出小星星）换成克制的
  //    InkRipple，并且只留一点极淡的高亮 —— 苹果的按钮按下就是轻微压暗。
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: color ?? Colors.green,
    brightness: brightness,
  );
  final Color splash = scheme.primary.withValues(alpha: 0.08);
  final Color highlight = scheme.primary.withValues(alpha: 0.06);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    progressIndicatorTheme: progressIndicatorTheme2024,
    sliderTheme: sliderTheme2024,
    // Apple 观感：克制的按下反馈，不要 Material 3 的星星水波。
    splashFactory: InkRipple.splashFactory,
    splashColor: splash,
    highlightColor: highlight,
    pageTransitionsTheme: pageTransitionsTheme2024,
    // 下面这些是 Material 自带的「面板类」控件。以前各自用框架默认圆角
    // （卡片 12、对话框 28、输入框 4/12……），彼此对不上；统一到全局半径后，
    // 卡片、弹窗、底部弹层、输入框、标签、菜单、提示条看起来才是同一套。
    //
    // 表面着色归零：M3 默认把主题色以低透明度叠在所有 surface 上（primary /
    // secondary / surfaceContainer……），卡片和面板因此都泛着主题色的偏色。
    // 苹果的中性面不这么做。主题里需要用的容器色仍是 ColorScheme 给的，只是
    // 不再额外「染」一层。
    cardTheme: CardThemeData(
      shape: globalShape,
      clipBehavior: Clip.antiAlias,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(
      shape: globalShape,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: const BottomSheetThemeData().copyWith(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
      ),
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: globalShape,
      surfaceTintColor: Colors.transparent,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        // 苹果连续圆角：裸 SubmenuButton 这类没有显式 menuStyle 的菜单面板会
        // 落到这里，圆角得和原生玻璃面板同族，填充才和面板平行。
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedSuperellipseBorder(borderRadius: globalRadius),
        ),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: globalShape,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: globalRadius),
      enabledBorder: OutlineInputBorder(borderRadius: globalRadius),
      focusedBorder: OutlineInputBorder(borderRadius: globalRadius),
      errorBorder: OutlineInputBorder(borderRadius: globalRadius),
      focusedErrorBorder: OutlineInputBorder(borderRadius: globalRadius),
    ),
  );
}

/// 当前窗口的短边（逻辑像素）。主题构建在 BuildContext 之外，用它估屏幕圆角。
double _windowShortestSide() {
  final ui.FlutterView? view = ui.PlatformDispatcher.instance.implicitView;
  if (view == null) return 393;
  final Size size = view.physicalSize / view.devicePixelRatio;
  return size.shortestSide;
}
