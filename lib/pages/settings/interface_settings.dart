import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_dropdown_tile.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/modules/collect/collect_layout.dart';
import 'package:kazumi/services/storage/storage.dart';

class InterfaceSettingsPage extends StatefulWidget {
  const InterfaceSettingsPage({super.key});

  @override
  State<InterfaceSettingsPage> createState() => _InterfaceSettingsPageState();
}

class _InterfaceSettingsPageState extends State<InterfaceSettingsPage> {
  late bool showRating;
  late String defaultPage;
  late String _timelinePreferredSource;
  late CollectLayout _defaultCollectLayout;
  bool _savingCollectLayout = false;
  static const Map<String, String> defaultPageMap = {
    '/tab/popular/': '推荐',
    '/tab/timeline/': '时间表',
    '/tab/collect/': '追番',
    '/tab/my/': '我的',
  };

  /// 时间表的星期分组来源。
  /// - bangumi：条目自身的播出星期（放送星期），同一时段的排在一起。
  /// - anilist：实测的下一次播出时刻。首播日和正片播出日不一致（先行配信、
  ///   流媒体提前上线）时按它分组。
  static const Map<String, String> timelineSourceMap = {
    'bangumi': 'Bangumi 放送星期',
    'anilist': 'AniList 播出时间',
  };

  @override
  void initState() {
    super.initState();
    showRating = GStorage.getSetting(SettingsKeys.showRating);
    defaultPage = GStorage.getSetting(SettingsKeys.defaultStartupPage);
    _timelinePreferredSource =
        GStorage.getSetting(SettingsKeys.timelinePreferredSource);
    _defaultCollectLayout = CollectLayout.fromValue(
      GStorage.getSetting(SettingsKeys.defaultCollectLayout),
    );
  }

  void _updateTimelineSource(String source) {
    GStorage.putSetting(SettingsKeys.timelinePreferredSource, source);
    setState(() => _timelinePreferredSource = source);
  }

  void updateDefaultPage(String page) {
    GStorage.putSetting(SettingsKeys.defaultStartupPage, page);
    setState(() {
      defaultPage = page;
    });
  }

  Future<void> _updateDefaultCollectLayout(CollectLayout layout) async {
    if (_savingCollectLayout || layout == _defaultCollectLayout) return;
    setState(() => _savingCollectLayout = true);
    try {
      await GStorage.putSetting(SettingsKeys.defaultCollectLayout, layout.name);
      if (mounted) setState(() => _defaultCollectLayout = layout);
    } catch (_) {
      if (mounted) KazumiDialog.showToast(message: '追番默认布局保存失败，请重试');
    } finally {
      if (mounted) setState(() => _savingCollectLayout = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: Text('界面设置'),
      body: SettingsList(
        sections: [
          SettingsSection(title: Text('启动'), tiles: [
            SettingsDropdownTile<String>(
              leading: Icons.home_rounded,
              title: const Text('启动界面设置'),
              description: const Text('设置应用开启时的默认页面'),
              value: defaultPage,
              options: defaultPageMap,
              fallbackLabel: '推荐',
              onChanged: updateDefaultPage,
            ),
          ]),
          SettingsSection(title: Text('展示信息'), tiles: [
            SettingsDropdownTile<String>(
              leading: Icons.calendar_view_week_rounded,
              title: const Text('时间表星期来源'),
              description: const Text(
                '按放送星期分组时，同一时段的番剧会排在一起；'
                '按 AniList 播出时间分组时跟随最新一次的播出时刻',
              ),
              value: _timelinePreferredSource,
              options: timelineSourceMap,
              fallbackLabel: 'Bangumi 放送星期',
              onChanged: _updateTimelineSource,
            ),
            SettingsDropdownTile<CollectLayout>(
              leading: Icons.view_agenda_rounded,
              title: const Text('追番默认布局'),
              description: const Text('下次打开追番页时使用，页面内切换不会改变此设置'),
              enabled: !_savingCollectLayout,
              value: _defaultCollectLayout,
              options: {
                for (final layout in CollectLayout.values) layout: layout.label,
              },
              onChanged: _updateDefaultCollectLayout,
            ),
            SettingsTile.switchTile(
              leading: Icons.star_rounded,
              onToggle: (value) async {
                showRating = value ?? !showRating;
                await GStorage.putSetting(SettingsKeys.showRating, showRating);
                setState(() {});
              },
              title: Text('显示评分'),
              description: Text('关闭后隐藏概览和番剧列表中的评分信息'),
              initialValue: showRating,
            ),
          ]),
        ],
      ),
    );
  }
}
