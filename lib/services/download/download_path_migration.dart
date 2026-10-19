import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/file_system.dart';
import 'package:path/path.dart' as path;

/// iOS can move an app's data container on update. Download files move with it,
/// but the absolute paths stored in Hive still point to the old container.
/// Restore sandbox downloads under the current default directory before any
/// playback, resume or deletion.
///
/// [customDownloadRoot] is the user-picked download folder (iOS only). Its
/// paths live outside the app container and survive updates, so they must not
/// be rebased.
Future<void> rebaseIosDownloadPaths(
  Box<DownloadRecord> downloads, {
  Future<String> Function() downloadDirectory = getDefaultDownloadDirectory,
  String customDownloadRoot = '',
}) async {
  try {
    await _rebaseDownloadPaths(
      downloads,
      await downloadDirectory(),
      customDownloadRoot,
    );
  } catch (error, stackTrace) {
    // Existing boxes remain usable even if migration cannot be persisted (for
    // example on a full disk). Retry from the saved records on the next launch.
    KazumiLogger().e(
      'DownloadStorage: iOS download path migration failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

Future<void> _rebaseDownloadPaths(
  Box<DownloadRecord> downloads,
  String downloadBase,
  String customDownloadRoot,
) async {
  bool isCustom(String value) =>
      customDownloadRoot.isNotEmpty &&
      value.isNotEmpty &&
      (value == customDownloadRoot ||
          path.isWithin(customDownloadRoot, value));

  var changed = false;
  for (final key in downloads.keys.toList()) {
    final record = downloads.get(key);
    if (record == null) continue;

    var recordChanged = false;
    for (final entry in record.episodes.entries) {
      final episode = entry.value;
      if (episode.downloadDirectory.isEmpty && episode.localM3u8Path.isEmpty) {
        continue;
      }
      if (isCustom(episode.downloadDirectory) ||
          isCustom(episode.localM3u8Path)) {
        continue;
      }

      final directory = path.join(
        downloadBase,
        '${record.bangumiId}_${record.pluginName}',
        '${entry.key}',
      );
      final videoPath = episode.localM3u8Path.isEmpty
          ? ''
          : path.join(directory, path.basename(episode.localM3u8Path));
      if (episode.downloadDirectory == directory &&
          episode.localM3u8Path == videoPath) {
        continue;
      }

      episode.downloadDirectory = directory;
      episode.localM3u8Path = videoPath;
      recordChanged = true;
    }

    if (recordChanged) {
      await downloads.put(key, record);
      changed = true;
    }
  }
  if (changed) await downloads.flush();
}
