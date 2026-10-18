import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';

class ExternalPlayer {
  ExternalPlayer._();

  static const _platform = MethodChannel('com.predidit.kazumi/intent');

  static Future<bool> launchUrlWithReferer(String url, String referer) async {
    try {
      await _platform.invokeMethod(
          'openWithReferer', <String, String>{'url': url, 'referer': referer});
      return true;
    } on PlatformException catch (e) {
      KazumiLogger().e("ExternalPlayer: failed to open with referer", error: e);
      return false;
    }
  }
}
