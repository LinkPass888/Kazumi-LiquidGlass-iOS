import 'dart:async';

import 'package:flutter/material.dart';

import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/services/bangumi_update_notification_service.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 提醒范围：关闭 / 我在追的动画
enum UpdateNotifyScope {
  off('关闭'),
  watching('我在追的动画');

  const UpdateNotifyScope(this.label);
  final String label;
}

class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage>
    with WidgetsBindingObserver {
  late UpdateNotifyScope _scope = GStorage.getSetting(
    SettingsKeys.bangumiUpdateNotifyEnable,
  )
      ? UpdateNotifyScope.watching
      : UpdateNotifyScope.off;

  /// null = 尚未查询；true/false = 系统权限状态
  bool? _permissionGranted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshPermission());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 跳到系统设置授权后回来，重新检查并刷新「已允许/未允许」。
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshPermission());
    }
  }

  Future<void> _refreshPermission() async {
    final granted =
        await BangumiUpdateNotificationService.instance.isPermissionGranted();
    if (mounted) setState(() => _permissionGranted = granted);
  }

  /// 「通知权限」行点击：重新检查 → 未允许且没问过就弹系统弹窗申请，
  /// 问过仍拒绝就跳系统设置。
  Future<void> _handlePermissionTap() async {
    final action =
        await BangumiUpdateNotificationService.instance.ensurePermission();
    await _refreshPermission();
    if (mounted && action == PermissionAction.asked) {
      KazumiDialog.showToast(message: '未获得通知权限，可在系统设置中开启');
    }
  }

  Future<void> _selectScope(UpdateNotifyScope scope) async {
    if (scope == UpdateNotifyScope.off) {
      await BangumiUpdateNotificationService.instance.cancelAllScheduled();
      await GStorage.putSetting(
          SettingsKeys.bangumiUpdateNotifyEnable, false);
      if (mounted) setState(() => _scope = scope);
      return;
    }

    final action =
        await BangumiUpdateNotificationService.instance.ensurePermission();
    await _refreshPermission();
    if (action != PermissionAction.granted) {
      // 权限被拒：不写入开关，保持关闭并提示（跳系统设置的情况由
      // 生命周期回调在返回时刷新状态）。
      if (mounted && action == PermissionAction.asked) {
        KazumiDialog.showToast(message: '未获得通知权限，请在系统设置中允许通知');
      }
      return;
    }
    await GStorage.putSetting(SettingsKeys.bangumiUpdateNotifyEnable, true);
    if (mounted) setState(() => _scope = scope);
    // 立即按当前追番排一次，不用等下次数据刷新。
    await BangumiUpdateNotificationService.instance.rescheduleNow();
  }

  Future<void> _showScheduled() async {
    final scheduled =
        await BangumiUpdateNotificationService.instance.scheduledNotifications();
    if (!mounted) return;
    await KazumiDialog.show(builder: (context) {
      return AlertDialog(
        title: const Text('通知排程'),
        content: scheduled.isEmpty
            ? const Text('当前没有已排定的提醒。\n正在追的番剧有更新时会自动排定。')
            : SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final entry in scheduled)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.notifications_none_rounded),
                        title: Text(entry.title, maxLines: 2),
                        subtitle: Text(_formatDateTime(entry.fireAt)),
                      ),
                  ],
                ),
              ),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(context: context),
            child: const Text('关闭'),
          ),
        ],
      );
    });
  }

  static String _formatDateTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.month}月${time.day}日 ${two(time.hour)}:${two(time.minute)}';
  }

  String get _permissionLabel => switch (_permissionGranted) {
        null => '检查中…',
        true => '已允许',
        false => '未允许',
      };

  String get _permissionDescription {
    if (_permissionGranted == false) {
      return '系统未允许通知，提醒无法送达；请到系统设置中开启';
    }
    return '查看系统是否允许 Kazumi 发送通知';
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('通知设置'),
      body: SettingsList(
        sections: [
          SettingsSection(
            title: const Text('通知权限'),
            tiles: [
              SettingsTile(
                leading: Icons.notifications_rounded,
                title: const Text('通知权限'),
                description: Text(_permissionDescription),
                trailing: Text(_permissionLabel),
                onPressed: (_) => _handlePermissionTap(),
              ),
            ],
          ),
          SettingsRadioSection<UpdateNotifyScope>(
            title: const Text('提醒范围'),
            groupValue: _scope,
            onChanged: (value) {
              if (value != null) unawaited(_selectScope(value));
            },
            tiles: [
              for (final scope in UpdateNotifyScope.values)
                SettingsTile<UpdateNotifyScope>.radioTile(
                  title: Text(scope.label),
                  radioValue: scope,
                ),
            ],
          ),
          SettingsSection(
            bottomInfo: const Text(
              '「我在追的动画」包含所有最近两季标记「在看」的番剧。',
            ),
            tiles: const [],
          ),
          SettingsSection(
            title: const Text('通知排程'),
            tiles: [
              SettingsTile(
                leading: Icons.schedule_rounded,
                title: const Text('查看排程'),
                description: const Text('查看已排定的更新提醒'),
                onPressed: (_) => _showScheduled(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
