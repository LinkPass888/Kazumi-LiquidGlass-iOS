import 'package:flutter/material.dart';

/// A widget for drag to move window.
///
/// Kazumi 本地版仅 iOS：窗口拖动是桌面概念，这里保留 API（各页面调用处
/// 不变），直接原样返回 child。
class DragToMoveArea extends StatelessWidget {
  const DragToMoveArea({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
