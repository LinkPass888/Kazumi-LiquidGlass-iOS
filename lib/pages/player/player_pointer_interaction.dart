import 'package:flutter/gestures.dart';

bool isTouchLikePointer(PointerDeviceKind? pointerKind) {
  return pointerKind == PointerDeviceKind.touch ||
      pointerKind == PointerDeviceKind.stylus ||
      pointerKind == PointerDeviceKind.invertedStylus;
}

/// Kazumi 本地版仅 iOS：主点击即切换控制层；双击全屏由移动端手势层处理。
bool shouldToggleControllerOnPrimaryTap({
  required bool isDesktop,
  required PointerDeviceKind? pointerKind,
}) {
  return isTouchLikePointer(pointerKind);
}

bool shouldToggleFullscreenOnDoubleTap({
  required bool isDesktop,
  required bool isPip,
  required PointerDeviceKind? pointerKind,
}) {
  return false;
}
