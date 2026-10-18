import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/history/history_list_view.dart';
import 'package:kazumi/pages/history/history_record_tile.dart';
import 'package:kazumi/services/player/history_playback_service.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart'
    show RuleCancelToken;

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.controller});

  final HistoryController controller;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  bool _editing = false;
  bool _clearing = false;
  final Set<String> _deleting = {};

  @override
  void initState() {
    super.initState();
    widget.controller.init();
  }

  Future<void> _deleteHistory(History history) async {
    if (_clearing || _deleting.contains(history.key)) return;
    setState(() => _deleting.add(history.key));
    try {
      await widget.controller.deleteHistory(history);
      if (mounted && widget.controller.histories.isEmpty) {
        setState(() => _editing = false);
      }
    } catch (_) {
      if (mounted) {
        KazumiDialog.showToast(context: context, message: '删除失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _deleting.remove(history.key));
    }
  }

  Future<void> _clearHistory() async {
    if (_clearing || _deleting.isNotEmpty) return;
    final confirmed = await KazumiDialog.show<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_outlined),
        title: const Text('清空历史记录？'),
        content: Text(
            '将删除全部 ${widget.controller.histories.length} 条观看记录，包括在线和缓存记录。此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空全部'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      await widget.controller.clearAll();
      if (mounted) setState(() => _editing = false);
    } catch (_) {
      if (mounted) {
        KazumiDialog.showToast(context: context, message: '清空失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Observer(builder: (context) {
      final entries = widget.controller.histories.toList();
      return PopScope(
        canPop: !_editing,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && _editing) {
            setState(() => _editing = false);
          }
        },
        child: Scaffold(
          appBar: SysAppBar(
            title: Text('历史记录', style: appBarTitleStyle(context)),
            actions: [
              if (entries.isNotEmpty) ...[
                // 编辑中：「清空全部」在左，「完成」在最右（贴屏幕边，和返回键
                // 左右对称）。
                if (_editing)
                  IconButton(
                    tooltip: '清空全部历史记录',
                    onPressed: _clearing || _deleting.isNotEmpty
                        ? null
                        : _clearHistory,
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                if (_editing)
                  // 「完成」是顶栏上的文字按钮。这里不用 TextButton：Material
                  // 按钮自己的最小尺寸/内边距会在 40×40 的动作槽里把文字挤偏。
                  // 用和玻璃图标按钮同一套点按目标（整块玻璃居中、回弹一致），
                  // 只把图标换成文字，位置就和旁边的图标按钮完全对齐。
                  KazumiGlass.barSegment(
                    context: context,
                    onTap: _clearing
                        ? null
                        : () => setState(() => _editing = false),
                    padding: EdgeInsets.zero,
                    radius: KazumiGlass.barButtonSize / 2,
                    child: Text(
                      '完成',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            // 跟顶栏的图标同一个颜色（AppBar 的动作图标用的是
                            // colorScheme.onSurface），不要主题色 —— 深色下是白、
                            // 浅色下是黑，才和旁边的图标融为一体。
                            color: _clearing
                                ? Theme.of(context).disabledColor
                                : Theme.of(context).colorScheme.onSurface,
                          ),
                    ),
                  )
                else
                  IconButton(
                    tooltip: '管理历史记录',
                    onPressed: () => setState(() => _editing = true),
                    icon: const Icon(Icons.edit_outlined, size: 22),
                  ),
              ],
            ],
          ),
          body: SafeArea(
            top: false,
            bottom: false,
            child: HistoryListView(
              entries: entries,
              editing: _editing,
              itemBuilder: (history, borderRadius) => _HistoryCard(
                history: history,
                borderRadius: borderRadius,
                editing: _editing,
                busy: _clearing || _deleting.contains(history.key),
                onDelete: () => _deleteHistory(history),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _HistoryCard extends StatefulWidget {
  const _HistoryCard({
    required this.history,
    required this.onDelete,
    required this.editing,
    required this.busy,
    required this.borderRadius,
  });

  final History history;
  final bool editing;
  final bool busy;
  final Future<void> Function() onDelete;
  final BorderRadius borderRadius;

  @override
  State<_HistoryCard> createState() => _HistoryCardState();
}

class _HistoryCardState extends State<_HistoryCard> with KazumiDialogOwner {
  final CollectController _collectController = inject<CollectController>();
  final HistoryPlaybackService _playbackService =
      inject<HistoryPlaybackService>();
  bool _updatingCollect = false;

  Future<void> _play() async {
    if (widget.editing || widget.busy || dialogs.isRunning) return;
    await dialogs.run((task) async {
      final cancelToken = RuleCancelToken();
      final result = await task.loading(
        message: '获取中',
        barrierDismissible: false,
        onCancel: cancelToken.cancel,
        action: () =>
            _playbackService.open(widget.history, cancelToken: cancelToken),
      );
      switch (result) {
        case HistoryPlaybackReady(:final args):
          task.withContext(
              (context) => context.pushNamed('/video/', arguments: args));
        case HistoryPlaybackUnavailable(:final reason):
          KazumiDialog.showToast(message: reason);
      }
    }, errorMessage: '暂时无法继续播放，请稍后重试');
  }

  Future<void> _changeCollect(CollectType type) async {
    if (_updatingCollect) return;
    setState(() => _updatingCollect = true);
    try {
      await _collectController.addCollect(widget.history.bangumiItem,
          type: type.value);
    } catch (_) {
      KazumiDialog.showToast(message: '修改收藏状态失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _updatingCollect = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Observer(builder: (context) {
      // getCollectType reads storage, so track the observable list explicitly.
      _collectController.collectibles.length;
      return HistoryRecordTile(
        history: widget.history,
        borderRadius: widget.borderRadius,
        editing: widget.editing,
        busy: widget.busy,
        onPlay: _play,
        onDelete: widget.onDelete,
        onDetails: () =>
            context.pushNamed('/info/', arguments: widget.history.bangumiItem),
        collectType: CollectType.fromValue(
            _collectController.getCollectType(widget.history.bangumiItem)),
        onChangeCollect: _updatingCollect ? null : _changeCollect,
      );
    });
  }
}
