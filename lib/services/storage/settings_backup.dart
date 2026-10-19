import 'dart:convert';

/// 设置备份的编解码。备份是一段 JSON 文本，可以放进剪贴板或存成文本文件，
/// 卸载重装后粘回来即可恢复。
///
/// 只处理设置箱里的标量 / 列表值（bool、num、String、String 列表），
/// 与 [GStorage.rawSettingsSnapshot] 的产出对应。
class SettingsBackup {
  const SettingsBackup._();

  /// 备份格式版本。字段不兼容时递增，导入端据此拒绝。
  static const int version = 1;

  /// 不参与备份的键：
  /// - 设备标识与同步游标：每台设备必须自己生成，拷过来会和另一台设备撞车。
  /// - 同步用的内部状态 / 待办队列：来自远端数据，不是用户设置。
  /// - 代理「已测试通过」标记：换设备 / 重装后网络环境不同，必须重新测试。
  /// - 引导与提示条「已显示」标记：那份体验跟着这台设备走。
  /// - 播放器快捷键：存的是按键组合，换设备 / 换输入法后可能失效，也不该
  ///   跟着备份走（键名前缀见 [isExcludedKey]）。
  static const Set<String> excludedKeys = {
    'historySyncDeviceId',
    'historySyncSequence',
    'historySyncSnapshotInitialized',
    'danmakuShieldSyncDeviceId',
    'danmakuShieldSyncState',
    'danmakuShieldSyncCorruptState',
    'bangumiProgressQueue',
    'proxyConfigured',
    'onboardingCompleted',
    'shortcutDialogShown',
  };

  /// 动态键名（按番剧 id 存的搜索历史等）不参与备份。
  static const List<String> _excludedPrefixes = [
    'shortcut_',
    'danmakuSearchHistory_',
  ];

  static bool isExcludedKey(String key) =>
      excludedKeys.contains(key) ||
      _excludedPrefixes.any(key.startsWith);

  /// 把设置箱快照整理成可备份的「键 -> 值」：跳过内部键与无法编码的值。
  /// [omit] 里的键也不写入（「不含账号与密码」的导出用）。
  static Map<String, Object> settingsFrom(
    Map<Object?, Object?> snapshot, {
    Set<String> omit = const {},
  }) {
    final settings = <String, Object>{};
    snapshot.forEach((key, value) {
      if (key is! String || isExcludedKey(key) || omit.contains(key)) return;
      final encoded = _encodeValue(value);
      if (encoded != null) settings[key] = encoded;
    });
    return settings;
  }

  /// 把设置箱快照编码成备份文本。
  static String encode(
    Map<Object?, Object?> snapshot, {
    DateTime? now,
    Set<String> omit = const {},
  }) {
    return encodeValues(settingsFrom(snapshot, omit: omit), now: now);
  }

  /// 把已经整理好的设置编码成备份文本。
  static String encodeValues(
    Map<String, Object> settings, {
    DateTime? now,
  }) {
    return jsonEncode({
      'app': 'Kazumi',
      'version': version,
      'exportedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
      'settings': settings,
    });
  }

  /// 解析备份文本。格式不对时抛出 [FormatException]，消息可直接展示给用户。
  static SettingsBackupData decode(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text.trim());
    } on FormatException {
      throw const FormatException('内容不是有效的 JSON，请确认复制完整');
    }
    if (decoded is! Map) {
      throw const FormatException('备份格式不正确');
    }
    if (decoded['app'] != 'Kazumi') {
      throw const FormatException('这不是 Kazumi 的设置备份');
    }
    final fileVersion = decoded['version'];
    if (fileVersion is! int || fileVersion < 1) {
      throw const FormatException('备份版本无法识别');
    }
    if (fileVersion > version) {
      throw const FormatException('备份来自更新版本的 Kazumi，请先升级应用');
    }
    final rawSettings = decoded['settings'];
    if (rawSettings is! Map) {
      throw const FormatException('备份里没有设置内容');
    }

    final settings = <String, Object>{};
    rawSettings.forEach((key, value) {
      if (key is! String || isExcludedKey(key)) return;
      final decodedValue = _decodeValue(value);
      if (decodedValue != null) settings[key] = decodedValue;
    });
    final exportedAt = DateTime.tryParse('${decoded['exportedAt']}');
    return SettingsBackupData(settings, exportedAt?.toLocal());
  }

  static Object? _encodeValue(Object? value) {
    if (value is bool || value is num || value is String) return value;
    if (value is List) {
      if (value.every((item) => item is String)) return List<String>.from(value);
      return null;
    }
    return null;
  }

  static Object? _decodeValue(Object? value) {
    if (value is bool || value is num || value is String) return value;
    if (value is List && value.every((item) => item is String)) {
      return List<String>.from(value);
    }
    return null;
  }
}

/// 解析后的备份内容。
class SettingsBackupData {
  const SettingsBackupData(this.settings, this.exportedAt);

  /// 键名 -> 设置值（已去掉不参与备份的键）。
  final Map<String, Object> settings;

  /// 备份创建时间；备份里没写或格式不对时为 null。
  final DateTime? exportedAt;

  int get count => settings.length;
}
