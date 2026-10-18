import 'package:flutter/material.dart';

Future<Map<String, double>> getScreenInfo() async {
  final mediaQuery = MediaQueryData.fromView(
    WidgetsBinding.instance.platformDispatcher.views.first,
  );
  final screenSize =
      WidgetsBinding.instance.platformDispatcher.displays.first.size;
  return {
    'width': screenSize.width,
    'height': screenSize.height,
    'ratio': mediaQuery.devicePixelRatio,
  };
}

// Kazumi 本地版仅 iOS；桌面分支已随平台收窄删除。
// 保留此函数让历史调用点语义不变。
bool isDesktop() => false;
