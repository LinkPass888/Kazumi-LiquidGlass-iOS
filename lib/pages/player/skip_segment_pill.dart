import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/services/skip/skip_segments.dart';

/// 播放进入片头/片尾区间时浮出的「跳过」按钮。
///
/// 时间轴来自 AniSkip 在线查询，只提示不自动跳（在线时间由他人提供，
/// 不同压制版本会有偏差）。
class SkipSegmentPill extends StatefulWidget {
  const SkipSegmentPill({
    super.key,
    required this.playerController,
    required this.onNextEpisode,
  });

  final PlayerController playerController;
  final VoidCallback onNextEpisode;

  @override
  State<SkipSegmentPill> createState() => _SkipSegmentPillState();
}

enum _PillMode { skip, undo }

class _SkipSegmentPillState extends State<SkipSegmentPill> {
  static const _tick = Duration(milliseconds: 250);
  static const _showFor = Duration(seconds: 8);
  static const _undoFor = Duration(seconds: 5);

  Timer? _timer;

  SkipSegments? _segments;
  SkipKind? _dismissed;

  SkipKind? _kind;
  SkipRange? _range;
  _PillMode _mode = _PillMode.skip;
  DateTime _shownAt = DateTime.now();
  double _progress = 0;

  PlayerController get _player => widget.playerController;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_tick, (_) => _update());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  double get _position =>
      _player.playback.currentPosition.inMilliseconds / 1000;

  void _update() {
    if (!mounted) return;
    final segments = _player.skipSegments;
    if (!identical(segments, _segments)) {
      _segments = segments;
      _dismissed = null;
      _setPill(null, null);
    }
    if (segments.isEmpty) return;

    if (_mode == _PillMode.undo) {
      if (DateTime.now().difference(_shownAt) > _undoFor) _setPill(null, null);
      return;
    }

    final position = _position;
    final active = segments.activeAt(position);
    // 距区间结束不到 1 秒就没有必要再提示了。
    if (active == null || active.$2.end - position < 1) {
      _dismissed = null;
      _setPill(null, null);
      return;
    }
    final (kind, range) = active;

    if (_kind != kind) {
      // 手动忽略过的提示，等控制栏再次出现才回来。
      if (_dismissed == kind && !_player.panel.showVideoController) return;
      _setPill(kind, range);
    } else if (DateTime.now().difference(_shownAt) > _showFor &&
        !_player.panel.showVideoController) {
      _dismissed = kind;
      _setPill(null, null);
      return;
    }
    setState(() {
      _progress = ((position - range.start) / range.length).clamp(0.0, 1.0);
    });
  }

  void _setPill(
    SkipKind? kind,
    SkipRange? range, {
    _PillMode mode = _PillMode.skip,
  }) {
    if (_kind == kind && identical(_range, range) && _mode == mode) return;
    setState(() {
      _kind = kind;
      _range = range;
      _mode = mode;
      _shownAt = DateTime.now();
      _progress = 0;
    });
  }

  Future<void> _seekTo(double seconds) =>
      _player.seek(Duration(milliseconds: (seconds * 1000).round()));

  bool _endsEpisode(SkipRange range) {
    final duration = _player.playback.duration.inMilliseconds / 1000;
    return duration > 0 && duration - range.end < 3;
  }

  void _onTap() {
    final kind = _kind;
    final range = _range;
    if (kind == null || range == null) return;
    if (_mode == _PillMode.undo) {
      unawaited(_seekTo(range.start));
      _dismissed = kind;
    } else if (kind == SkipKind.ending && _endsEpisode(range)) {
      widget.onNextEpisode();
    } else {
      unawaited(_seekTo(range.end));
    }
    _setPill(null, null);
  }

  String get _label {
    final kind = _kind;
    final range = _range;
    if (kind == null || range == null) return '';
    final name = kind == SkipKind.opening ? '片头' : '片尾';
    if (_mode == _PillMode.undo) return '已跳过$name · 撤销';
    if (kind == SkipKind.ending && _endsEpisode(range)) return '下一集';
    return '跳过$name';
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return Observer(
      builder: (context) {
        final locked = _player.panel.lockPanel;
        final controlsUp = _player.panel.showVideoController && !locked;
        final visible = _kind != null && !locked;
        return Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              right: 20,
              bottom: safeBottom + (controlsUp ? 108 : 28),
              child: AnimatedSwitcher(
                duration: Duration(milliseconds: reduceMotion ? 0 : 240),
                reverseDuration: Duration(milliseconds: reduceMotion ? 0 : 140),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: animation.drive(
                      Tween(begin: const Offset(0.25, 0), end: Offset.zero),
                    ),
                    child: child,
                  ),
                ),
                child: visible
                    ? _SkipButton(
                        key: ValueKey(_label),
                        label: _label,
                        progress: _mode == _PillMode.skip ? _progress : null,
                        undo: _mode == _PillMode.undo,
                        onTap: _onTap,
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({
    super.key,
    required this.label,
    required this.progress,
    required this.undo,
    required this.onTap,
  });

  final String label;

  /// 已播放的比例，null 时不显示进度条。
  final double? progress;
  final bool undo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const foreground = Color(0xF2FFFFFF);
    const accent = Color(0xFFA8D8FF);
    final textStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: foreground,
      fontSize: 14,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
    );
    final progress = this.progress;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 9, 16, 9),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                undo ? Icons.replay_rounded : Icons.fast_forward_rounded,
                size: 18,
                color: foreground,
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: textStyle),
                  if (progress != null) ...[
                    const SizedBox(height: 4),
                    SizedBox(
                      width: 68,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 2,
                          backgroundColor: Colors.white24,
                          valueColor: const AlwaysStoppedAnimation(accent),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
