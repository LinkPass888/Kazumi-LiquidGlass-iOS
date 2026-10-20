import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_dropdown_tile.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/bean/settings/theme_provider.dart';
import 'package:kazumi/services/bangumi_update_notification_service.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/proxy_manager.dart';
import 'package:kazumi/services/storage/settings_backup.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/app_theme.dart';

/// 设置备份范围：全部设置，或不含账号与代理凭据的那部分。
enum _BackupScope {
  all('全部设置', '包含同步账号、WebDAV 与代理密码，请只存放在自己可信的地方'),
  safe('不含账号与密码', '跳过追番同步、WebDAV、代理等凭据，其余设置照常恢复');

  const _BackupScope(this.label, this.description);

  final String label;
  final String description;
}

/// 备份里有、但恢复时需要一起处理的凭据类键，用来提示用户重新确认。
const _credentialKeys = {
  'bangumiAccessToken',
  'webDavUsername',
  'webDavPassword',
  'webDavURL',
  'proxyUrl',
  'proxyTestUrl',
};

class SettingsBackupPage extends StatefulWidget {
  const SettingsBackupPage({super.key});

  @override
  State<SettingsBackupPage> createState() => _SettingsBackupPageState();
}

class _SettingsBackupPageState extends State<SettingsBackupPage> {
  _BackupScope _scope = _BackupScope.safe;
  bool _busy = false;

  void _message(String message) {
    KazumiDialog.showToast(context: context, message: message);
  }

  /// 按选定范围取出设置（键 -> 值）。
  Map<String, Object> _selectedSettings(_BackupScope scope) {
    return SettingsBackup.settingsFrom(
      GStorage.rawSettingsSnapshot(),
      omit: scope == _BackupScope.all ? const {} : _credentialKeys,
    );
  }

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final settings = _selectedSettings(_scope);
      if (settings.isEmpty) {
        _message('没有可导出的设置');
        return;
      }
      final text = SettingsBackup.encodeValues(settings);
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      _message('已复制 ${settings.length} 项设置到剪贴板，建议粘贴到备忘录保存');
    } catch (error, stackTrace) {
      KazumiLogger()
          .e('Settings backup: export failed', error: error, stackTrace: stackTrace);
      if (mounted) _message('导出失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    final ClipboardData? clipboard;
    try {
      clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (error) {
      KazumiLogger().w('Settings backup: clipboard read failed', error: error);
      _message('无法读取剪贴板');
      return;
    }
    final text = clipboard?.text?.trim() ?? '';
    if (text.isEmpty) {
      _message('剪贴板是空的，请先复制设置备份内容');
      return;
    }

    final SettingsBackupData backup;
    try {
      backup = SettingsBackup.decode(text);
    } on FormatException catch (error) {
      _message(error.message);
      return;
    }
    if (backup.settings.isEmpty) {
      _message('备份里没有可恢复的设置');
      return;
    }
    if (!mounted) return;

    final when = backup.exportedAt;
    final whenText = when == null
        ? '时间未知'
        : '${when.year}-${when.month.toString().padLeft(2, '0')}-'
            '${when.day.toString().padLeft(2, '0')} '
            '${when.hour.toString().padLeft(2, '0')}:'
            '${when.minute.toString().padLeft(2, '0')}';
    final hasCredentials =
        backup.settings.keys.any(_credentialKeys.contains);

    final confirmed = await KazumiDialog.show<bool>(
      context: context,
      builder: (context) => KazumiAlert(
        icon: const Icon(Icons.settings_backup_restore_rounded),
        title: const Text('恢复这些设置？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('备份时间：$whenText\n共 ${backup.count} 项设置，将覆盖当前设置。'),
            if (hasCredentials) ...[
              const SizedBox(height: 12),
              const Text('备份包含账号或代理密码。恢复后请到同步设置里确认凭据仍然有效。'),
            ],
            const SizedBox(height: 12),
            const Text('引导步骤、通知权限、设备同步状态不会被改动。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(popWith: false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => KazumiDialog.dismiss(popWith: true),
            child: const Text('恢复设置'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await GStorage.putRawSettings(backup.settings);
      _applyAfterImport(backup.settings);
      if (!mounted) return;
      _message('已恢复 ${backup.count} 项设置');
    } catch (error, stackTrace) {
      KazumiLogger()
          .e('Settings backup: import failed', error: error, stackTrace: stackTrace);
      if (mounted) _message('恢复失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 让只读取一次、或需要重新下发的设置在恢复后立即生效。
  void _applyAfterImport(Map<String, Object> settings) {
    applyStoredThemeSettings(context.read<ThemeProvider>(), notify: true);
    if (settings.containsKey('proxyEnable') ||
        settings.containsKey('proxyUrl')) {
      ProxyManager.applyProxy();
    }
    if (settings.containsKey('bangumiUpdateNotifyEnable')) {
      unawaited(
        BangumiUpdateNotificationService.instance.rescheduleNow(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('设置备份'),
      body: SettingsList(
        sections: [
          SettingsSection(
            title: const Text('导出'),
            tiles: [
              SettingsDropdownTile<_BackupScope>(
                leading: Icons.tune_rounded,
                title: const Text('备份内容'),
                description: Text(_scope.description),
                value: _scope,
                options: {
                  for (final scope in _BackupScope.values) scope: scope.label,
                },
                enabled: !_busy,
                onChanged: (scope) => setState(() => _scope = scope),
              ),
              SettingsTile(
                leading: Icons.content_copy_rounded,
                title: const Text('导出到剪贴板'),
                description: Text(
                  _busy ? '正在导出…' : '复制一段备份文本，粘贴到备忘录或文件里保存',
                ),
                enabled: !_busy,
                onPressed: (_) => _export(),
                trailing: const Icon(Icons.ios_share_rounded),
              ),
            ],
          ),
          SettingsSection(
            title: const Text('导入'),
            tiles: [
              SettingsTile(
                leading: Icons.settings_backup_restore_rounded,
                title: const Text('从剪贴板恢复'),
                description: Text(
                  _busy ? '正在恢复…' : '先复制之前导出的备份文本，再点这里',
                ),
                enabled: !_busy,
                onPressed: (_) => _import(),
                trailing: const Icon(Icons.download_rounded),
              ),
            ],
            bottomInfo: const Text(
              '备份只包含应用设置。追番列表、观看记录、下载与播放器日志不会导出，'
              '请用 WebDAV 同步另行备份。',
            ),
          ),
        ],
      ),
    );
  }
}
