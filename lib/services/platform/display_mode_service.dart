import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';

class DisplayModeService {
  DisplayModeService._();

  static Future<void> _pendingFullscreen = Future.value();
  static Future<void>? _pendingSystemBars;
  static Object? _systemBarsOwner;
  static bool _systemBarsHidden = false;

  static Future<void> applyVideoFullscreen(bool fullscreen) {
    return _pendingFullscreen = _pendingFullscreen.then((_) async {
      // 退出全屏时**显式锁竖屏**：传空数组是「恢复系统默认方向」，系统屏幕
      // 方向锁定关闭时设备物理横着就保持横屏，点小屏按钮看起来像失效。
      // 改为显式 portraitUp，播放器才能真的切回竖屏。
      await _attempt(() => SystemChrome.setPreferredOrientations(
            fullscreen
                ? [
                    DeviceOrientation.landscapeLeft,
                    DeviceOrientation.landscapeRight
                  ]
                : [DeviceOrientation.portraitUp],
          ));
    });
  }

  /// Outgoing pages cannot release chrome owned by the next visible page.
  static Future<void> setSystemBarsHidden({
    required Object owner,
    required bool hidden,
  }) {
    _systemBarsOwner = owner;
    return _setSystemBarsHidden(hidden);
  }

  static Future<void> releaseSystemBars(Object owner) {
    if (!identical(_systemBarsOwner, owner)) {
      return _pendingSystemBars ?? Future.value();
    }
    _systemBarsOwner = null;
    return _setSystemBarsHidden(false);
  }

  static Future<void> _setSystemBarsHidden(bool hidden) {
    if (_systemBarsHidden == hidden) {
      return _pendingSystemBars ?? Future.value();
    }
    _systemBarsHidden = hidden;
    // Rotation acknowledgements must not delay immersion or route cleanup.
    late final Future<void> request;
    request = (_pendingSystemBars ?? Future<void>.value())
        .then((_) => _attempt(() => SystemChrome.setEnabledSystemUIMode(
              hidden ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
            )))
        .whenComplete(() {
      if (identical(_pendingSystemBars, request)) _pendingSystemBars = null;
    });
    return _pendingSystemBars = request;
  }

  static Future<void> _attempt(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error, stackTrace) {
      KazumiLogger().e('Display: failed to apply video display mode',
          error: error, stackTrace: stackTrace);
    }
  }
}
