import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/services/skip/skip_segments.dart';
import 'package:real_liquid_glass/real_liquid_glass.dart';

/// 即将进入片头/片尾区间时浮出的倒计时弹窗。
///
/// 时间轴来自 AniSkip 在线查询（不同压制版本会有偏差），所以默认走「即将
/// 跳过」+ 倒数 5 秒、倒数到 0 自动 seek 到区间结束，过程里点「取消」则
/// 本段不再自动跳。ED 结束到全集结尾很近时改成「下一集 / 取消」按钮弹窗，
/// 倒数到 0 用户无操作就**取消**（不自动切下一集），把决定权留给用户。
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

/// 弹窗模式：
///  * [countdown] 默认：即将跳过 X · 圆环倒数 5..1，到 0 自动 seek 到区间结束；
///  * [nextEpisode] ED 后紧接集尾：下一集 / 取消，倒数到 0 不动作；
///  * [undo] 跳完后的 5s 撤销窗口。
enum _PillMode { countdown, nextEpisode, undo }

class _SkipSegmentPillState extends State<SkipSegmentPill> {
  static const _tick = Duration(milliseconds: 250);

  /// 提前多少秒弹出倒计时（Apple TV 片头弹窗的提前量）。
  static const _countdownSeconds = 5;
  static const _undoFor = Duration(seconds: 5);

  /// ED 结束到全集结尾的「短」阈值：<= 该值时认为 ED 就是本集结尾，弹
  /// 下一集/取消（不自动切），> 该值按「还有彩蛋」处理，默认 seek 到
  /// ED 结束位置。3 秒沿用 AniSkip 的经验值。
  static const _postCreditsThreshold = 3.0;

  Timer? _timer;

  SkipSegments? _segments;

  /// 用户点过「取消 / 撤销」的片段：本段不再自动跳。
  SkipRange? _cancelledRange;

  /// 本段是否已经执行过自动跳过（防止 seek 失败时反复触发）。
  SkipRange? _skippedRange;

  SkipKind? _kind;
  SkipRange? _range;
  _PillMode _mode = _PillMode.countdown;
  DateTime _shownAt = DateTime.now();
  double _countdownRemaining = _countdownSeconds.toDouble();

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

  /// 还没进入区间时的剩余倒计时（range.start − position，夹到 0..5）。
  /// 已经进入区间后不再倒数：倒计时分支在 position >= range.start 时直接跳过。
  double _remaining(SkipRange range, double position) {
    return (range.start - position).clamp(0.0, _countdownSeconds.toDouble());
  }

  bool _isEdEndsEpisode(SkipKind kind, SkipRange range) {
    final duration = _player.playback.duration.inMilliseconds / 1000;
    return kind == SkipKind.ending &&
        duration > 0 &&
        duration - range.end <= _postCreditsThreshold;
  }

  /// 用 range 的真实种类（开头/结尾）选择 mode。
  _PillMode _modeFor(SkipKind kind, SkipRange range) =>
      kind == SkipKind.ending && _isEdEndsEpisode(kind, range)
          ? _PillMode.nextEpisode
          : _PillMode.countdown;

  void _update() {
    if (!mounted) return;
    final segments = _player.skipSegments;
    if (!identical(segments, _segments)) {
      _segments = segments;
      _cancelledRange = null;
      _skippedRange = null;
      _setPill(null, null);
    }
    if (segments.isEmpty) return;

    final position = _position;

    if (_mode == _PillMode.undo) {
      if (DateTime.now().difference(_shownAt) > _undoFor ||
          position < _range!.start) {
        _setPill(null, null);
      }
      return;
    }

    final pending = _range;

    // 倒计时进行中：只在仍盯着同一片段时倒数。
    if (_kind != null && pending != null) {
      final active = segments.activeAt(position);
      // 「正在区间内」或「5 秒内即将进入」都算盯着同一段。
      final bool same = active != null && active.$2 == pending;
      if (!same) {
        final upcoming =
            segments.upcomingAt(position, _countdownSeconds.toDouble());
        if (upcoming == null || upcoming.$2 != pending) {
          _setPill(null, null);
          return;
        }
      }
      // 已经进入区间（含开播即 OP/ED）：直接跳过，不再等剩余倒数。
      if (position >= pending.start) {
        if (_mode == _PillMode.nextEpisode) {
          _onCancel();
        } else if (!identical(_skippedRange, pending) &&
            _cancelledRange != pending) {
          _performSkip(_kind!, pending, auto: true);
        }
        return;
      }
      final remaining = _remaining(pending, position);
      setState(() {
        _countdownRemaining = remaining;
      });
      if (remaining <= 0) {
        if (_mode == _PillMode.nextEpisode) {
          // 倒数到 0 用户无操作 = 取消（不自动切下一集）。
          _onCancel();
        } else if (!identical(_skippedRange, pending) &&
            _cancelledRange != pending) {
          _performSkip(_kind!, pending, auto: true);
        }
      }
      return;
    }

    // 还没到提示时机。已经进入区间的（开播即 OP/ED、倍速/拖进度条直接进入）
    // 只在「一开始就是 OP」时给倒计时；其它区间中段进来的不再弹窗。
    final upcoming =
        segments.upcomingAt(position, _countdownSeconds.toDouble());
    if (upcoming == null) {
      final activeNow = segments.activeAt(position);
      if (activeNow == null) {
        // 真正无区间：清掉取消/跳过状态，让下一次的提示能回来。
        _cancelledRange = null;
        _skippedRange = null;
        return;
      }
      // 开播即落在 OP/ED 起点附近（≤ 5s 内）：给倒计时，由上面的分支触发跳过。
      // 区间中段进来的：不弹窗、也不自动跳（用户手动拖进来就是来看这段的）。
      final (kind, range) = activeNow;
      if (position - range.start <= _countdownSeconds &&
          _cancelledRange != range &&
          !identical(_skippedRange, range)) {
        _setPill(kind, range, mode: _modeFor(kind, range));
      }
      return;
    }
    final (kind, range) = upcoming;
    if (_cancelledRange == range || identical(_skippedRange, range)) return;
    _setPill(kind, range, mode: _modeFor(kind, range));
  }

  void _setPill(
    SkipKind? kind,
    SkipRange? range, {
    _PillMode mode = _PillMode.countdown,
  }) {
    if (_kind == kind && identical(_range, range) && _mode == mode) return;
    setState(() {
      _kind = kind;
      _range = range;
      _mode = mode;
      _shownAt = DateTime.now();
      _countdownRemaining = _countdownSeconds.toDouble();
    });
  }

  Future<void> _seekTo(double seconds) =>
      _player.seek(Duration(milliseconds: (seconds * 1000).round()));

  void _performSkip(SkipKind kind, SkipRange range, {bool auto = false}) {
    _skippedRange = range;
    unawaited(_seekTo(range.end));
    // 撤销弹窗只在「自动跳完」时出：用户手动点「跳过」是已经主动决定，
    // 再给撤销反而多余。手动走法直接关弹窗。
    if (auto) {
      _setPill(kind, range, mode: _PillMode.undo);
    } else {
      _setPill(null, null);
    }
  }

  void _onCancel() {
    _cancelledRange = _range;
    _setPill(null, null);
  }

  void _onNextEpisode() {
    _cancelledRange = _range;
    widget.onNextEpisode();
    _setPill(null, null);
  }

  void _onUndo() {
    final range = _range;
    if (range == null) return;
    _cancelledRange = range;
    unawaited(_seekTo(range.start));
    _setPill(null, null);
  }

  int get _countdownDisplay =>
      _countdownRemaining.clamp(0.0, _countdownSeconds.toDouble()).ceil();

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return Observer(
      builder: (context) {
        // 锁定面板时仍显示（看 OP/ED 经常顺手把面板锁了）。
        final visible = _kind != null;
        final controlsUp = _player.panel.showVideoController &&
            !_player.panel.lockPanel;
        // 横屏时弹窗往屏幕中间挪，让右边界和视频进度条的右内边距对齐
        // （进度条自己离屏边 ~28，弹窗本来还有 20 的 inset，所以总 48）。
        final size = MediaQuery.sizeOf(context);
        final landscape = size.width > size.height;
        final rightInset = landscape ? 48.0 : 20.0;
        final Widget pill;
        if (!visible) {
          pill = const SizedBox.shrink();
        } else if (_mode == _PillMode.undo) {
          pill = _UndoPill(
            key: const ValueKey('undo'),
            label: '已跳过${_kind == SkipKind.opening ? '片头' : '片尾'}',
            onTap: _onUndo,
          );
        } else if (_mode == _PillMode.nextEpisode) {
          pill = _NextEpisodePill(
            key: const ValueKey('next'),
            secondsLeft: _countdownDisplay,
            totalSeconds: _countdownSeconds,
            onNextEpisode: _onNextEpisode,
            onCancel: _onCancel,
          );
        } else {
          pill = _CountdownPill(
            key: const ValueKey('countdown'),
            kind: _kind!,
            secondsLeft: _countdownDisplay,
            totalSeconds: _countdownSeconds,
            onSkipNow: () => _performSkip(_kind!, _range!),
            onCancel: _onCancel,
          );
        }
        return Stack(
          children: [
            Positioned(
              right: rightInset,
              bottom: safeBottom + (controlsUp ? 48 : 28),
              child: AnimatedSwitcher(
                duration: Duration(milliseconds: reduceMotion ? 0 : 220),
                reverseDuration: Duration(milliseconds: reduceMotion ? 0 : 160),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                // 纯渐显渐隐，不滑动。
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: pill,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 跳过 X · 圆环倒数（环内 5..1）· 跳过 · 取消。
class _CountdownPill extends StatelessWidget {
  const _CountdownPill({
    super.key,
    required this.kind,
    required this.secondsLeft,
    required this.totalSeconds,
    required this.onSkipNow,
    required this.onCancel,
  });

  final SkipKind kind;
  final int secondsLeft;
  final int totalSeconds;
  final VoidCallback onSkipNow;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    const foreground = Color(0xF2FFFFFF);
    final name = kind == SkipKind.opening ? '片头' : '片尾';
    final titleStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
          color: foreground,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        );
    final primary = Theme.of(context).colorScheme.primary;
    return LiquidGlassContainer(
      shape: KazumiGlass.panelShapeOf(context),
      style: LiquidGlassStyle.clear,
      interactive: false,
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.fast_forward_rounded,
                  size: 16, color: foreground),
              const SizedBox(width: 8),
              Text('即将跳过$name', style: titleStyle),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PillAction(
                label: '跳过',
                filled: true,
                fillColor: primary.withValues(alpha: 0.28),
                onTap: onSkipNow,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: _CountdownRing(
                  secondsLeft: secondsLeft,
                  totalSeconds: totalSeconds,
                ),
              ),
              _PillAction(
                label: '取消',
                filled: true,
                fillColor: foreground.withValues(alpha: 0.12),
                onTap: onCancel,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// ED 结束到集尾很近时的「下一集 / 取消」按钮弹窗：带 5s 圆环倒数，
/// 倒数到 0 用户没点就当「取消」处理（不自动切下一集）。
class _NextEpisodePill extends StatelessWidget {
  const _NextEpisodePill({
    super.key,
    required this.secondsLeft,
    required this.totalSeconds,
    required this.onNextEpisode,
    required this.onCancel,
  });

  final int secondsLeft;
  final int totalSeconds;
  final VoidCallback onNextEpisode;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    const foreground = Color(0xF2FFFFFF);
    final titleStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
          color: foreground,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        );
    final primary = Theme.of(context).colorScheme.primary;
    return LiquidGlassContainer(
      shape: KazumiGlass.panelShapeOf(context),
      style: LiquidGlassStyle.clear,
      interactive: false,
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.skip_next_rounded, size: 16, color: foreground),
              const SizedBox(width: 8),
              Text('即将到结尾', style: titleStyle),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PillAction(
                label: '下一集',
                filled: true,
                fillColor: primary.withValues(alpha: 0.28),
                onTap: onNextEpisode,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: _CountdownRing(
                  secondsLeft: secondsLeft,
                  totalSeconds: totalSeconds,
                ),
              ),
              _PillAction(
                label: '取消',
                filled: true,
                fillColor: foreground.withValues(alpha: 0.12),
                onTap: onCancel,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 跳过后的「撤销」弹窗。
class _UndoPill extends StatelessWidget {
  const _UndoPill({
    super.key,
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const foreground = Color(0xF2FFFFFF);
    final textStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
          color: foreground,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        );
    final primary = Theme.of(context).colorScheme.primary;
    return LiquidGlassContainer(
      shape: KazumiGlass.panelShapeOf(context),
      style: LiquidGlassStyle.clear,
      interactive: false,
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.replay_rounded, size: 16, color: foreground),
              const SizedBox(width: 8),
              Text(label, style: textStyle),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Spacer(),
              _PillAction(
                label: '撤销',
                filled: true,
                fillColor: primary.withValues(alpha: 0.28),
                onTap: onTap,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 圆环里直接显示剩余秒数。
class _CountdownRing extends StatelessWidget {
  const _CountdownRing({
    required this.secondsLeft,
    required this.totalSeconds,
  });

  final int secondsLeft;
  final int totalSeconds;

  @override
  Widget build(BuildContext context) {
    const foreground = Color(0xF2FFFFFF);
    final numStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        );
    return SizedBox(
      width: 22,
      height: 22,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: totalSeconds <= 0
                ? 0
                : (secondsLeft / totalSeconds).clamp(0.0, 1.0),
            strokeWidth: 2,
            backgroundColor: Colors.white24,
            valueColor: const AlwaysStoppedAnimation(foreground),
          ),
          Text('$secondsLeft', style: numStyle),
        ],
      ),
    );
  }
}

/// 弹窗里的动作按钮：浅色填充 + 按下加深。
class _PillAction extends StatefulWidget {
  const _PillAction({
    required this.label,
    required this.filled,
    required this.fillColor,
    required this.onTap,
  });

  final String label;
  final bool filled;
  final Color fillColor;
  final VoidCallback onTap;

  @override
  State<_PillAction> createState() => _PillActionState();
}

class _PillActionState extends State<_PillAction> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (mounted && _pressed != value) {
      setState(() => _pressed = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    const foreground = Color(0xF2FFFFFF);
    final textStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
          color: foreground,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: ShapeDecoration(
          shape: const StadiumBorder(),
          color: _pressed
              ? widget.fillColor.withValues(
                  alpha: (widget.fillColor.a * 255.0 * 1.4).round() / 255.0,
                )
              : widget.fillColor,
        ),
        child: Text(widget.label, style: textStyle),
      ),
    );
  }
}
