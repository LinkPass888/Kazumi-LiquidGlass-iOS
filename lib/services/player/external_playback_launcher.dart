import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/player/external_player.dart';

class ExternalPlaybackLauncher {
  final String Function() videoUrl;
  final String Function() referer;

  ExternalPlaybackLauncher({
    required this.videoUrl,
    required this.referer,
  });

  Future<void> launch() async {
    final currentVideoUrl = videoUrl();
    final currentReferer = referer();
    if (await ExternalPlayer.launchUrlWithReferer(
        currentVideoUrl, currentReferer)) {
      KazumiDialog.showToast(
        message: '尝试唤起外部播放器',
      );
    } else {
      KazumiDialog.showToast(
        message: '唤起外部播放器失败',
      );
    }
  }
}
