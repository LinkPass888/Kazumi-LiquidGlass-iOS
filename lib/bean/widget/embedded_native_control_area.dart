import 'package:flutter/material.dart';

/// Reserves space above content for native macOS window controls.
///
/// Kazumi 本地版仅 iOS，无需为窗口按钮留白：保持原 API（各页面调用处
/// 不变），直接原样返回 child。
class EmbeddedNativeControlArea extends StatelessWidget {
  const EmbeddedNativeControlArea({
    super.key,
    required this.child,
    this.requireOffset = true,
  });

  final Widget child;
  final bool requireOffset;

  @override
  Widget build(BuildContext context) => child;
}
