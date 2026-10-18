import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:kazumi/services/bangumi_update_times.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// 权限入口的处理结果。
enum PermissionAction {
  /// 已授权。
  granted,

  /// 弹了系统弹窗但用户未允许。
  asked,

  /// 之前拒绝过，已跳到系统设置。
  openSettings,
}

/// 一条已排定的更新提醒（设置页「通知排程」展示用）。
class ScheduledUpdateNotification {
  const ScheduledUpdateNotification({
    required this.title,
    required this.body,
    required this.fireAt,
  });

  final String title;
  final String body;
  final DateTime fireAt;
}

/// 番剧更新本地通知
///
/// 在更新时间数据就绪后，为「正在追」的番剧在更新时刻排定本地通知。
/// 每次重排先清掉旧提醒再排新的，弃追/停更不会有残留。走
/// flutter_local_notifications 的 iOS 定时通知（UNUserNotificationCenter，
/// 侧载证书也能用）；非 iOS 平台不支持，静默跳过。
class BangumiUpdateNotificationService {
  BangumiUpdateNotificationService._();

  static final BangumiUpdateNotificationService instance =
      BangumiUpdateNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// 取「正在追」番剧（id -> 名称）的回调，由 main 注入，避免服务反向依赖存储。
  Future<Map<int, String>> Function()? watchingProvider;

  static const _maxLead = Duration(days: 7);
  static const _idBase = 400000;
  static const _idRange = 100000;

  bool get isSupported => Platform.isIOS;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation(DateTime.now().timeZoneName));
    const settings = InitializationSettings(
      iOS: DarwinInitializationSettings(),
    );
    await _plugin.initialize(settings);
    _initialized = true;
  }

  /// 查询当前系统通知权限状态（不触发系统弹窗）。
  Future<bool> isPermissionGranted() async {
    if (!isSupported) return true;
    try {
      await _ensureInitialized();
      final settings = await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.checkPermissions();
      return settings?.isEnabled ?? false;
    } catch (e) {
      KazumiLogger().w('UpdateNotify: permission check failed', error: e);
      return false;
    }
  }

  /// 权限入口（设置页「通知权限」行）。
  ///
  /// 返回处理方式，供页面提示：
  /// - [PermissionAction.granted]：已授权（本次申请通过，或本来就允许）。
  /// - [PermissionAction.asked]：弹了系统授权弹窗，用户未允许。
  /// - [PermissionAction.openSettings]：之前申请过且被永久拒绝，已跳到
  ///   系统设置——iOS 上 requestPermissions 对已拒绝的 App 不再弹窗，
  ///   必须引导用户去设置页手动开。
  Future<PermissionAction> ensurePermission() async {
    if (!isSupported) return PermissionAction.granted;
    try {
      await _ensureInitialized();
      if (await isPermissionGranted()) return PermissionAction.granted;
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      final before = await ios?.checkPermissions();
      // 从没申请过（权限值全为 false 且未触发过系统询问）时才会真正弹窗。
      final granted = await ios?.requestPermissions(
            alert: true,
            badge: false,
            sound: true,
          ) ??
          false;
      final after = await ios?.checkPermissions();
      // 申请前后权限状态没变 = 用户在弹窗里拒绝了，或系统直接没弹
      // （此前拒绝过）——跳系统设置让用户手动开。
      final stillDenied = !(after?.isEnabled ?? false);
      if (!granted || (stillDenied && _samePermissionState(before, after))) {
        AppSettings.openAppSettings(type: AppSettingsType.notification);
        return PermissionAction.openSettings;
      }
      return stillDenied ? PermissionAction.asked : PermissionAction.granted;
    } catch (e) {
      KazumiLogger().w('UpdateNotify: permission request failed', error: e);
      return PermissionAction.openSettings;
    }
  }

  static bool _samePermissionState(
    NotificationsEnabledOptions? before,
    NotificationsEnabledOptions? after,
  ) {
    final b = before?.isEnabled ?? false;
    final a = after?.isEnabled ?? false;
    return b == a;
  }

  /// 数据刷新（或设置里改动后）调用：重排「正在追」番剧的更新提醒。
  Future<void> rescheduleNow() async {
    if (!isSupported) return;
    if (!GStorage.getSetting(SettingsKeys.bangumiUpdateNotifyEnable)) return;
    final provider = watchingProvider;
    if (provider == null) return;
    try {
      await scheduleForWatching(await provider());
    } catch (e) {
      KazumiLogger().w('UpdateNotify: reschedule failed', error: e);
    }
  }

  /// 按 [watching]（bangumi id -> 名称）在各自更新时刻排定提醒。
  Future<void> scheduleForWatching(
    Map<int, String> watching, {
    DateTime? now,
  }) async {
    if (!isSupported) return;
    final current = now ?? DateTime.now();
    try {
      await _ensureInitialized();
      // 先清掉旧提醒再排新的，弃追/停更后不会有残留。
      await _cancelAll();
      for (final entry in watching.entries) {
        final nextMs = BangumiUpdateTimesService.instance
            .nextUpdateEpoch(entry.key, now: current);
        if (nextMs == null) continue;
        // 推送时刻 = 更新时间本身；已过点的和过远的（数据异常）不排。
        final fireAt = DateTime.fromMillisecondsSinceEpoch(nextMs);
        final lead = fireAt.difference(current);
        if (lead <= Duration.zero || lead > _maxLead) continue;
        await _plugin.zonedSchedule(
          _idBase + (entry.key % _idRange),
          '番剧更新',
          '「${entry.value}」已更新',
          tz.TZDateTime.from(fireAt, tz.local),
          const NotificationDetails(iOS: DarwinNotificationDetails()),
          // API 必填，iOS 端不生效。
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          // pendingNotificationRequests 不返回排定时刻，用 payload 带上。
          payload: '${entry.key}:${fireAt.millisecondsSinceEpoch}',
        );
      }
    } catch (e) {
      KazumiLogger().w('UpdateNotify: scheduling failed', error: e);
    }
  }

  /// 已排定的提醒，按时间先后排序（设置页「通知排程」）。
  Future<List<ScheduledUpdateNotification>> scheduledNotifications() async {
    if (!isSupported) return const [];
    try {
      await _ensureInitialized();
      final names = <int, String>{};
      if (watchingProvider != null) {
        try {
          names.addAll(await watchingProvider!());
        } catch (_) {}
      }
      final result = <ScheduledUpdateNotification>[];
      for (final request in await _plugin.pendingNotificationRequests()) {
        final id = int.tryParse(request.id.toString());
        if (id == null || id < _idBase || id >= _idBase + _idRange) continue;
        final payload = _decodePayload(request.payload);
        if (payload == null) continue;
        final (bangumiId, fireMs) = payload;
        result.add(ScheduledUpdateNotification(
          title: names[bangumiId] ?? '番剧 $bangumiId',
          body: request.body ?? '',
          fireAt: DateTime.fromMillisecondsSinceEpoch(fireMs),
        ));
      }
      result.sort((a, b) => a.fireAt.compareTo(b.fireAt));
      return result;
    } catch (e) {
      KazumiLogger().w('UpdateNotify: pending list failed', error: e);
      return const [];
    }
  }

  /// 关闭提醒时清掉全部已排定通知。
  Future<void> cancelAllScheduled() async {
    if (!isSupported) return;
    try {
      await _ensureInitialized();
      await _cancelAll();
    } catch (e) {
      KazumiLogger().w('UpdateNotify: cancel failed', error: e);
    }
  }

  Future<void> _cancelAll() async {
    for (final request in await _plugin.pendingNotificationRequests()) {
      final id = int.tryParse(request.id.toString());
      if (id != null && id >= _idBase && id < _idBase + _idRange) {
        await _plugin.cancel(id);
      }
    }
  }

  /// payload 形如 `bangumiId:epochMs`。
  (int, int)? _decodePayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    final parts = payload.split(':');
    if (parts.length != 2) return null;
    final id = int.tryParse(parts[0]);
    final ms = int.tryParse(parts[1]);
    if (id == null || ms == null) return null;
    return (id, ms);
  }
}
