import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/file_system.dart';

/// Owns where downloads are stored.
///
/// Defaults to the app sandbox (Application Support/downloads). The user can
/// pick a folder in Files/Finder instead; iOS hands out a security-scoped
/// bookmark for it, which [restoreAccess] re-resolves on every launch so the
/// folder stays writable across restarts.
///
/// Only iOS has a native side (see `AppDelegate.swift`, channel
/// `com.predidit.kazumi/storage`). Other platforms report no custom support
/// and keep using the default directory.
class DownloadDirectoryService {
  static final DownloadDirectoryService _instance =
      DownloadDirectoryService._internal();
  factory DownloadDirectoryService() => _instance;
  DownloadDirectoryService._internal();

  static const _channel = MethodChannel('com.predidit.kazumi/storage');

  /// Whether a custom directory was restored successfully this launch.
  /// Settings saved by an older build may name a folder without a bookmark;
  /// without access it must not be reported as active.
  bool _accessGranted = false;

  String _customDirectory = '';

  bool get supportsCustomDirectory => _platformSupportsCustomDirectory;

  /// The active custom directory. Empty while the default directory is in
  /// use — a stored path without granted access is not shown.
  String get customDirectory => _accessGranted ? _customDirectory : '';

  /// Saved path, even when this launch has not restored access to it yet.
  /// The settings page uses it so the row does not flash "default" while
  /// [restoreAccess] is still resolving the bookmark. Only meaningful on
  /// iOS; elsewhere it stays empty.
  String get savedDirectory => supportsCustomDirectory
      ? GStorage.getSetting(SettingsKeys.downloadDirectory)
      : '';

  /// Re-resolves the stored security-scoped bookmark. Call once at startup;
  /// if the bookmark no longer resolves (folder deleted, volume unmounted),
  /// fall back to the default directory and forget the stale path.
  Future<void> restoreAccess() async {
    if (!_platformSupportsCustomDirectory) return;
    final bookmark = GStorage.getSetting(SettingsKeys.downloadDirectoryBookmark);
    if (bookmark.isEmpty) {
      // Older builds saved a path (or macOS bookmark) with no iOS access.
      if (GStorage.getSetting(SettingsKeys.downloadDirectory).isNotEmpty) {
        await _clearStoredDirectory();
      }
      return;
    }
    try {
      final resolved = await _channel.invokeMethod<String>(
        'resolveBookmark',
        {'bookmark': bookmark},
      );
      if (resolved == null || resolved.isEmpty) {
        KazumiLogger().w('DownloadDirectory: bookmark no longer resolves');
        await _clearStoredDirectory();
        return;
      }
      _customDirectory = resolved;
      _accessGranted = true;
      if (resolved != GStorage.getSetting(SettingsKeys.downloadDirectory)) {
        await GStorage.putSetting(SettingsKeys.downloadDirectory, resolved);
      }
    } on PlatformException catch (e) {
      KazumiLogger().w('DownloadDirectory: restore failed', error: e);
      await _clearStoredDirectory();
    }
  }

  /// Root for new downloads. Falls back to the default directory when the
  /// custom folder is unavailable, so a revoked permission never blocks
  /// downloads.
  Future<String> getDownloadDirectory() async {
    if (!_accessGranted || _customDirectory.isEmpty) {
      return getDefaultDownloadDirectory();
    }
    return _customDirectory;
  }

  /// Opens the system folder picker. Returns null when the user cancels.
  /// Throws [DownloadDirectoryException] when the chosen folder is not
  /// writable or the platform has no picker.
  Future<String?> selectDirectory() async {
    if (!_platformSupportsCustomDirectory) {
      throw const DownloadDirectoryException('当前平台不支持手动选择目录');
    }
    final result =
        await _channel.invokeMapMethod<String, dynamic>('pickDirectory');
    if (result == null) return null;
    final path = result['path'];
    final bookmark = result['bookmark'];
    if (path is! String || path.isEmpty) return null;

    await ensureDirectoryWritable(path);
    _customDirectory = path;
    _accessGranted = true;
    await GStorage.putSetting(SettingsKeys.downloadDirectory, path);
    if (bookmark is String && bookmark.isNotEmpty) {
      await GStorage.putSetting(
          SettingsKeys.downloadDirectoryBookmark, bookmark);
    }
    return path;
  }

  /// Drops the custom folder and returns to the sandbox directory.
  Future<void> resetDirectory() async {
    _accessGranted = false;
    if (_platformSupportsCustomDirectory) {
      try {
        await _channel.invokeMethod<void>('releaseDirectory');
      } on PlatformException catch (e) {
        KazumiLogger().w('DownloadDirectory: release failed', error: e);
      }
    }
    await _clearStoredDirectory();
  }

  bool get _platformSupportsCustomDirectory {
    try {
      return defaultTargetPlatform == TargetPlatform.iOS;
    } on Object {
      return false;
    }
  }

  Future<void> _clearStoredDirectory() async {
    _customDirectory = '';
    _accessGranted = false;
    await GStorage.putSetting(SettingsKeys.downloadDirectory, '');
    await GStorage.putSetting(SettingsKeys.downloadDirectoryBookmark, '');
  }
}

class DownloadDirectoryException implements Exception {
  const DownloadDirectoryException(this.message);

  final String message;

  @override
  String toString() => message;
}
