import 'package:kazumi/utils/file_system.dart';

/// Owns where downloads are stored.
///
/// Kazumi 本地版仅 iOS：应用沙箱内固定使用默认目录（Application Support
/// /downloads），不支持自定义位置。保留原 API 与异常类型，调用处不变。
class DownloadDirectoryService {
  static final DownloadDirectoryService _instance =
      DownloadDirectoryService._internal();
  factory DownloadDirectoryService() => _instance;
  DownloadDirectoryService._internal();

  bool get supportsCustomDirectory => false;

  /// Empty while the default directory is in use.
  String get customDirectory => '';

  /// Sandboxed storage needs no per-launch access restore; kept as a no-op
  /// so startup sequencing stays unchanged.
  Future<void> restoreAccess() async {}

  /// Root for new downloads.
  Future<String> getDownloadDirectory() async {
    return getDefaultDownloadDirectory();
  }

  /// Returns null when the user cancels. Custom directories are not
  /// supported on iOS, so this always reports the platform limit.
  Future<String?> selectDirectory() async {
    throw const DownloadDirectoryException('当前平台不支持手动选择目录');
  }

  Future<void> resetDirectory() async {}
}

class DownloadDirectoryException implements Exception {
  const DownloadDirectoryException(this.message);

  final String message;

  @override
  String toString() => message;
}
