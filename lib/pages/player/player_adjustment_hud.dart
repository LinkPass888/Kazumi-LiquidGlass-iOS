import 'package:flutter/material.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/utils/format.dart';
import 'package:real_liquid_glass/real_liquid_glass.dart';

enum PlayerAdjustmentHudType {
  brightness,
  volume,
}

class PlayerAdjustmentHud extends StatefulWidget {
  const PlayerAdjustmentHud({
    super.key,
    required this.visible,
    required this.type,
    required this.value,
    this.disableAnimations = false,
  });

  final bool visible;
  final PlayerAdjustmentHudType type;
  final double value;
  final bool disableAnimations;

  @override
  State<PlayerAdjustmentHud> createState() => _PlayerAdjustmentHudState();
}

class _PlayerAdjustmentHudState extends State<PlayerAdjustmentHud> {
  late PlayerAdjustmentHudType _displayType;
  late double _displayValue;
  bool _snapProgressOnNextBuild = false;

  @override
  void initState() {
    super.initState();
    _displayType = widget.type;
    _displayValue = widget.value;
  }

  @override
  void didUpdateWidget(covariant PlayerAdjustmentHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible) {
      _displayType = widget.type;
      _displayValue = widget.value;
      if (!oldWidget.visible) {
        _snapProgressOnNextBuild = true;
      }
    }
  }

  double get _progress {
    return switch (_displayType) {
      PlayerAdjustmentHudType.brightness =>
        _displayValue.clamp(0.0, 1.0).toDouble(),
      PlayerAdjustmentHudType.volume =>
        (_displayValue / 100).clamp(0.0, 1.0).toDouble(),
    };
  }

  int get _percent => (_progress * 100).round();

  IconData get _icon {
    if (_displayType == PlayerAdjustmentHudType.brightness) {
      if (_percent <= 8) {
        return Icons.brightness_low_rounded;
      }
      if (_percent < 55) {
        return Icons.brightness_medium_rounded;
      }
      return Icons.brightness_high_rounded;
    }
    if (_percent <= 0) {
      return Icons.volume_off_rounded;
    }
    if (_percent < 45) {
      return Icons.volume_down_rounded;
    }
    return Icons.volume_up_rounded;
  }

  Color _container(ColorScheme colorScheme) {
    return switch (_displayType) {
      PlayerAdjustmentHudType.brightness => colorScheme.tertiary,
      PlayerAdjustmentHudType.volume => colorScheme.primary,
    };
  }

  // 亮度/音量走 iOS 音量条观感：轨道活动段用主题色、非活动段用对应
  // container 色，中间（滑块处）收窄成细腰（见 _HudSliderTrackShape）。
  Color _activeTraker(ColorScheme colorScheme) {
    return switch (_displayType) {
      PlayerAdjustmentHudType.brightness => colorScheme.tertiary,
      PlayerAdjustmentHudType.volume => colorScheme.primary,
    };
  }

  Color _inactiveTraker(ColorScheme colorScheme) {
    return switch (_displayType) {
      PlayerAdjustmentHudType.brightness => colorScheme.tertiaryContainer,
      PlayerAdjustmentHudType.volume => colorScheme.secondaryContainer,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final duration = widget.disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final snapProgress = _snapProgressOnNextBuild;
    if (snapProgress) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        setState(() {
          _snapProgressOnNextBuild = false;
        });
      });
    }

    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: widget.visible ? 1 : 0,
        duration: duration,
        curve: Curves.easeOutCubic,
        child: AnimatedSlide(
          offset: widget.visible ? Offset.zero : const Offset(0, -0.18),
          duration: duration,
          curve: Curves.easeOutCubic,
          child: AnimatedScale(
            scale: widget.visible ? 1 : 0.92,
            duration: duration,
            curve: Curves.easeOutBack,
            // 给玻璃加一层很淡的黑色 tint，减弱视频帧的穿透干扰；同时让
            // 玻璃表面形状与原 clip 的圆角一致。
            child: LiquidGlassContainer(
              shape: KazumiGlass.panelShapeOf(context),
              style: LiquidGlassStyle.clear,
              tint: const Color(0x14000000),
              interactive: false,
              child: AnimatedContainer(
                duration: duration,
                curve: Curves.easeOutCubic,
                width: 200,
                padding:
                    const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 玻璃上不再叠一块深色填充盒：图标直接画在玻璃上，
                    // 玻璃形状被盖住的观感才一致。
                    AnimatedSwitcher(
                      duration: duration,
                      switchInCurve: Curves.easeOutBack,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) {
                        return ScaleTransition(
                          scale: animation,
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        );
                      },
                      child: Icon(
                        _icon,
                        key: ValueKey(_icon),
                        color: _container(colorScheme),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 6,
                          activeTrackColor:
                              _activeTraker(colorScheme).withValues(alpha: 0.8),
                          inactiveTrackColor: _inactiveTraker(colorScheme)
                              .withValues(alpha: 0.4),
                          thumbColor: Colors.transparent,
                          overlayShape: SliderComponentShape.noOverlay,
                          // 前后一样细的轨道；无滑块竖条，活动/非活动两色
                          // 在滑块处直接拼接。
                          trackShape: const _HudSliderTrackShape(edgeInset: 6),
                          thumbShape: const _NoThumbShape(),
                          tickMarkShape: SliderTickMarkShape.noTickMark,
                          padding: EdgeInsets.zero,
                        ),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(end: _progress),
                          duration: widget.disableAnimations || snapProgress
                              ? Duration.zero
                              : const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          builder: (context, animatedProgress, child) {
                            return Slider(
                              value: animatedProgress,
                              onChanged: (_) {},
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 均匀细的轨道（iOS 播放器音量条观感）：整条前后一样细、两端圆角，活动
/// 段与非活动段两种颜色在滑块处直接拼接，不画中间的滑块竖条。
class _HudSliderTrackShape extends SliderTrackShape {
  const _HudSliderTrackShape({this.edgeInset = 6});

  /// 轨道两端相对可用宽度的内缩。
  final double edgeInset;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final thumbWidth =
        sliderTheme.thumbShape?.getPreferredSize(isEnabled, isDiscrete).width ??
            0;
    final trackHeight = sliderTheme.trackHeight ?? 0;
    final trackLeft = offset.dx + thumbWidth / 2;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final trackWidth = parentBox.size.width - thumbWidth;
    final base = Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
    final safeInset = edgeInset.clamp(0.0, base.width / 2).toDouble();
    return Rect.fromLTRB(
      base.left + safeInset,
      base.top,
      base.right - safeInset,
      base.bottom,
    );
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final canvas = context.canvas;
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.width <= 0 || rect.height <= 0) {
      return;
    }

    final activeColor = ColorTween(
          begin: sliderTheme.disabledActiveTrackColor,
          end: sliderTheme.activeTrackColor,
        ).evaluate(enableAnimation) ??
        Colors.transparent;
    final inactiveColor = ColorTween(
          begin: sliderTheme.disabledInactiveTrackColor,
          end: sliderTheme.inactiveTrackColor,
        ).evaluate(enableAnimation) ??
        Colors.transparent;

    final mid = thumbCenter.dx.clamp(rect.left, rect.right);
    final leftColor =
        textDirection == TextDirection.ltr ? activeColor : inactiveColor;
    final rightColor =
        textDirection == TextDirection.ltr ? inactiveColor : activeColor;

    // 整条是两端圆角的细条，高度前后一致；两种颜色在滑块处直接拼接。
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
    );
    canvas.drawRect(
      Rect.fromLTRB(rect.left, rect.top, mid, rect.bottom),
      Paint()
        ..isAntiAlias = true
        ..color = leftColor,
    );
    canvas.drawRect(
      Rect.fromLTRB(mid, rect.top, rect.right, rect.bottom),
      Paint()
        ..isAntiAlias = true
        ..color = rightColor,
    );
    canvas.restore();
  }
}

/// 不绘制任何东西的滑块：轨道两端已自带圆头，中间的竖条要去掉，让活动段
/// 与非活动段两种颜色直接拼接。
class _NoThumbShape extends SliderComponentShape {
  const _NoThumbShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size.zero;

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {}
}

class PlayerSeekHud extends StatefulWidget {
  const PlayerSeekHud({
    super.key,
    required this.visible,
    required this.currentPosition,
    required this.playerPosition,
    required this.duration,
    required this.direction,
    this.cancelPending = false,
    this.disableAnimations = false,
  });

  final bool visible;
  final Duration currentPosition;
  final Duration playerPosition;
  final Duration duration;
  final int direction;
  final bool cancelPending;
  final bool disableAnimations;

  @override
  State<PlayerSeekHud> createState() => _PlayerSeekHudState();
}

class _PlayerSeekHudState extends State<PlayerSeekHud> {
  late Duration _displayCurrentPosition;
  late Duration _displayPlayerPosition;
  late Duration _displayDuration;
  late int _displayDirection;
  late bool _displayCancelPending;
  bool _snapProgressOnNextBuild = false;

  @override
  void initState() {
    super.initState();
    _displayCurrentPosition = widget.currentPosition;
    _displayPlayerPosition = widget.playerPosition;
    _displayDuration = widget.duration;
    _displayDirection = widget.direction;
    _displayCancelPending = widget.cancelPending;
  }

  @override
  void didUpdateWidget(covariant PlayerSeekHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible) {
      _displayCurrentPosition = widget.currentPosition;
      _displayPlayerPosition = widget.playerPosition;
      _displayDuration = widget.duration;
      _displayDirection = widget.direction;
      _displayCancelPending = widget.cancelPending;
      if (!oldWidget.visible) {
        _snapProgressOnNextBuild = true;
      }
    }
  }

  int get _effectiveDirection {
    final positionDirection =
        _displayCurrentPosition.compareTo(_displayPlayerPosition);
    if (positionDirection != 0) {
      return positionDirection;
    }
    return _displayDirection;
  }

  bool get _isForward => _effectiveDirection >= 0;

  String get _offsetText {
    final offsetMs = (_displayCurrentPosition.inMilliseconds -
            _displayPlayerPosition.inMilliseconds)
        .abs();
    final sign = _isForward ? '+' : '-';
    return '$sign${durationToString(Duration(milliseconds: offsetMs))}';
  }

  double get _progress {
    final durationMs = _displayDuration.inMilliseconds;
    if (durationMs <= 0) {
      return 0;
    }
    return (_displayCurrentPosition.inMilliseconds / durationMs)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final duration = widget.disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final snapProgress = _snapProgressOnNextBuild;
    final colorScheme = Theme.of(context).colorScheme;
    final icon = _displayCancelPending
        ? Icons.close_rounded
        : _isForward
            ? Icons.fast_forward_rounded
            : Icons.fast_rewind_rounded;

    if (snapProgress) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        setState(() {
          _snapProgressOnNextBuild = false;
        });
      });
    }

    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: widget.visible ? 1 : 0,
        duration: duration,
        curve: Curves.easeOutCubic,
        child: AnimatedSlide(
          offset: widget.visible ? Offset.zero : const Offset(0, -0.18),
          duration: duration,
          curve: Curves.easeOutCubic,
          child: AnimatedScale(
            scale: widget.visible ? 1 : 0.92,
            duration: duration,
            curve: Curves.easeOutBack,
            // 玻璃上不叠深色盒；进度填充用主题 container 色并裁成玻璃圆角；
            // 加一点黑色 tint 减弱视频穿透。两行文字统一纯白，不用主题色。
            child: LiquidGlassContainer(
              shape: KazumiGlass.panelShapeOf(context),
              style: LiquidGlassStyle.clear,
              tint: const Color(0x14000000),
              interactive: false,
              child: AnimatedContainer(
                duration: duration,
                curve: Curves.easeOutCubic,
                width: 248,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(end: _progress),
                        duration: widget.disableAnimations || snapProgress
                            ? Duration.zero
                            : const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        builder: (context, animatedProgress, child) {
                          return _SeekProgressBackground(
                            progress: animatedProgress,
                            color: colorScheme.secondaryContainer,
                          );
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 8,
                        horizontal: 10,
                      ),
                      child: Row(
                        children: [
                          AnimatedSwitcher(
                            duration: duration,
                            switchInCurve: Curves.easeOutBack,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) {
                              return ScaleTransition(
                                scale: animation,
                                child: FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                              );
                            },
                            child: Icon(
                              icon,
                              key: ValueKey(icon),
                              color: colorScheme.secondary,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _displayCancelPending ? '松开取消' : _offsetText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelLarge
                                      ?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        shadows: const [
                                          Shadow(
                                            color: Color(0xA6000000),
                                            blurRadius: 6,
                                            offset: Offset(0, 1),
                                          ),
                                          Shadow(
                                            color: Color(0x73000000),
                                            blurRadius: 2,
                                            offset: Offset(0, 1),
                                          ),
                                        ],
                                      ),
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  _displayCancelPending
                                      ? '移回画面继续调整'
                                      : '${durationToString(_displayCurrentPosition)} / ${durationToString(_displayDuration)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        shadows: const [
                                          Shadow(
                                            color: Color(0xA6000000),
                                            blurRadius: 6,
                                            offset: Offset(0, 1),
                                          ),
                                          Shadow(
                                            color: Color(0x73000000),
                                            blurRadius: 2,
                                            offset: Offset(0, 1),
                                          ),
                                        ],
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SeekProgressBackground extends StatelessWidget {
  const _SeekProgressBackground({
    required this.progress,
    required this.color,
  });

  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth * progress.clamp(0.0, 1.0);
        // 裁成玻璃圆角：否则进度填充是直角矩形，四角会顶出玻璃边框。
        return ClipRRect(
          borderRadius: BorderRadius.circular(KazumiGlass.radiusOf(context)),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: width,
              color: color,
            ),
          ),
        );
      },
    );
  }
}

class PlayerSpeedHud extends StatefulWidget {
  const PlayerSpeedHud({
    super.key,
    required this.visible,
    required this.speed,
    this.disableAnimations = false,
  });

  final bool visible;
  final double speed;
  final bool disableAnimations;

  @override
  State<PlayerSpeedHud> createState() => _PlayerSpeedHudState();
}

class _PlayerSpeedHudState extends State<PlayerSpeedHud> {
  late double _displaySpeed;

  @override
  void initState() {
    super.initState();
    _displaySpeed = widget.speed;
  }

  @override
  void didUpdateWidget(covariant PlayerSpeedHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible) {
      _displaySpeed = widget.speed;
    }
  }

  String get _speedText => '${_displaySpeed.toStringAsFixed(1)}x';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final duration = widget.disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 160);

    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: widget.visible ? 1 : 0,
        duration: duration,
        curve: Curves.easeOutCubic,
        child: AnimatedSlide(
          offset: widget.visible ? Offset.zero : const Offset(0, -0.12),
          duration: duration,
          curve: Curves.easeOutCubic,
          child: AnimatedScale(
            scale: widget.visible ? 1 : 0.96,
            duration: duration,
            curve: Curves.easeOutCubic,
            // 倍速 HUD：图标恢复主题色，数字保持纯白；玻璃加黑色 tint 减弱视频穿透。
            child: LiquidGlassContainer(
              shape: KazumiGlass.panelShapeOf(context),
              style: LiquidGlassStyle.clear,
              tint: const Color(0x14000000),
              interactive: false,
              child: AnimatedContainer(
                duration: duration,
                curve: Curves.easeOutCubic,
                width: 94,
                padding:
                    const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.speed_rounded,
                      color: colorScheme.inverseSurface,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _speedText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            Theme.of(context).textTheme.labelMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  shadows: const [
                                    Shadow(
                                      color: Color(0x66000000),
                                      blurRadius: 4,
                                      offset: Offset(0, 1),
                                    ),
                                  ],
                                ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
