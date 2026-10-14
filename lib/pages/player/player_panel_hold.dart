import 'package:flutter/material.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/bean/widget/collect_button.dart';
import 'package:kazumi/bean/widget/kazumi_menu.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';

/// A one-shot lease that keeps the player panel visible until released.
class PlayerPanelHold {
  PlayerPanelHold({required VoidCallback onRelease}) : _onRelease = onRelease;

  VoidCallback? _onRelease;

  bool get isReleased => _onRelease == null;

  void release() {
    final onRelease = _onRelease;
    if (onRelease == null) {
      return;
    }
    _onRelease = null;
    onRelease();
  }

  void releaseSilently() {
    _onRelease = null;
  }
}

/// Release focus holds when resizing removes the input but preserves its panel.
class PlayerPanelHoldFocusRegion extends StatefulWidget {
  const PlayerPanelHoldFocusRegion({
    super.key,
    required this.acquirePlayerPanelHold,
    required this.child,
  });

  final PlayerPanelHold Function() acquirePlayerPanelHold;
  final Widget child;

  @override
  State<PlayerPanelHoldFocusRegion> createState() =>
      _PlayerPanelHoldFocusRegionState();
}

class _PlayerPanelHoldFocusRegionState
    extends State<PlayerPanelHoldFocusRegion> {
  PlayerPanelHold? _hold;

  void _onFocusChange(bool focused) {
    if (focused) {
      _hold ??= widget.acquirePlayerPanelHold();
    } else {
      _hold?.release();
      _hold = null;
    }
  }

  @override
  void dispose() {
    _hold?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        onFocusChange: _onFocusChange,
        child: widget.child,
      );
}

/// Release hover holds when their controls unmount.
class PlayerPanelHoldMouseRegion extends StatefulWidget {
  const PlayerPanelHoldMouseRegion({
    super.key,
    required this.acquirePlayerPanelHold,
    required this.child,
    this.cursor = MouseCursor.defer,
  });

  final PlayerPanelHold Function() acquirePlayerPanelHold;
  final Widget child;
  final MouseCursor cursor;

  @override
  State<PlayerPanelHoldMouseRegion> createState() =>
      _PlayerPanelHoldMouseRegionState();
}

class _PlayerPanelHoldMouseRegionState
    extends State<PlayerPanelHoldMouseRegion> {
  PlayerPanelHold? _hold;

  @override
  void dispose() {
    _releaseHold();
    super.dispose();
  }

  void _acquireHold() {
    if (_hold?.isReleased == false) {
      return;
    }
    _hold = widget.acquirePlayerPanelHold();
  }

  void _releaseHold() {
    _hold?.release();
    _hold = null;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => _acquireHold(),
      onExit: (_) => _releaseHold(),
      child: widget.child,
    );
  }
}

/// 只在横屏返回偏移，竖屏返回 null（保持框架默认位置）。
///
/// 播放器竖屏时按钮不在屏幕最底部，菜单照框架默认位置开就好；之前把竖屏也
/// 一起挪过，结果竖屏菜单跑到按钮顶上去了。横屏按钮贴着底边，菜单往下开会
/// 顶出屏幕，才需要用偏移把它顶回来 —— 每个调用方给的偏移量原样传进来。
Offset? playerLandscapeOffset(BuildContext context, Offset offset) {
  final Size size = MediaQuery.sizeOf(context);
  return size.width > size.height ? offset : null;
}

class PlayerPanelHoldMenuAnchor extends StatefulWidget {
  const PlayerPanelHoldMenuAnchor({
    super.key,
    required this.acquirePlayerPanelHold,
    required this.onVisibilityChanged,
    required this.builder,
    required this.menuChildren,
    this.style,
    this.alignmentOffset,
  });

  final PlayerPanelHold Function() acquirePlayerPanelHold;
  final ValueChanged<bool> onVisibilityChanged;
  final KazumiMenuBuilder builder;
  final List<Widget> menuChildren;

  /// 菜单面板的样式，需要指定宽高（例如倍速菜单）时传进来。
  final MenuStyle? style;

  /// 菜单相对锚点的偏移；一般传 [playerLandscapeOffset] 的结果。
  final Offset? alignmentOffset;

  @override
  State<PlayerPanelHoldMenuAnchor> createState() =>
      _PlayerPanelHoldMenuAnchorState();
}

class _PlayerPanelHoldMenuAnchorState extends State<PlayerPanelHoldMenuAnchor> {
  PlayerPanelHold? _hold;
  bool _isOpen = false;

  @override
  void dispose() {
    _handleClose();
    super.dispose();
  }

  void _handleOpen() {
    if (_isOpen) {
      return;
    }
    _isOpen = true;
    widget.onVisibilityChanged(true);
    _hold = widget.acquirePlayerPanelHold();
  }

  void _handleClose() {
    if (_isOpen) {
      _isOpen = false;
      widget.onVisibilityChanged(false);
    }
    _hold?.release();
    _hold = null;
  }

  @override
  Widget build(BuildContext context) {
    // 播放器的菜单要的是「一整块真玻璃」：框架的菜单面板自己画 Material，铺不了
    // 玻璃，所以先把面板整块变透明（下面的 style），再把 menuChildren 包进一块
    // KazumiGlass.glassSurface 顶上去 —— 和收藏状态菜单同一个做法。
    // 条目本身仍交给上游的 KazumiMenuItem / SubmenuButton 渲染，靠 kazumi_menu.dart
    // 里统一的 MenuButtonTheme 拿到同心圆高亮，按下深色和别的玻璃菜单一致。
    return KazumiMenuButton(
      animated: false,
      onOpen: _handleOpen,
      onClose: _handleClose,
      // 横屏时把面板顶回按钮上方；竖屏为 null，保持框架默认位置
      alignmentOffset: widget.alignmentOffset,
      style: (widget.style ?? const MenuStyle()).merge(
        MenuStyle(
          // 面板透明：真玻璃画在 menuChildren 里，这里不能再压一层底色
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(0),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.all(
                Radius.circular(KazumiGlass.panelRadiusOf(context)),
              ),
            ),
          ),
        ),
      ),
      builder: widget.builder,
      menuChildren: [
        KazumiGlass.glassSurface(
          shape: KazumiGlass.panelShapeOf(context),
          // 上下留空 = 面板圆角 − 条目圆角，两个圆角同心
          padding: KazumiGlass.menuPanelPadding,
          // 倍速那种长列表会把滚动条压在圆角上，藏掉
          child: ScrollbarTheme(
            data: const ScrollbarThemeData(
              thickness: WidgetStatePropertyAll(0),
              thumbVisibility: WidgetStatePropertyAll(false),
              trackVisibility: WidgetStatePropertyAll(false),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.menuChildren,
            ),
          ),
        ),
      ],
    );
  }
}

class PlayerPanelHoldCollectButton extends StatefulWidget {
  const PlayerPanelHoldCollectButton({
    super.key,
    required this.acquirePlayerPanelHold,
    required this.bangumiItem,
    this.color = Colors.white,
  });

  final PlayerPanelHold Function() acquirePlayerPanelHold;
  final BangumiItem bangumiItem;
  final Color color;

  @override
  State<PlayerPanelHoldCollectButton> createState() =>
      _PlayerPanelHoldCollectButtonState();
}

class _PlayerPanelHoldCollectButtonState
    extends State<PlayerPanelHoldCollectButton> {
  PlayerPanelHold? _hold;

  @override
  void dispose() {
    _releaseHold();
    super.dispose();
  }

  void _acquireHold() {
    if (_hold?.isReleased == false) {
      return;
    }
    _hold = widget.acquirePlayerPanelHold();
  }

  void _releaseHold() {
    _hold?.release();
    _hold = null;
  }

  @override
  Widget build(BuildContext context) {
    return CollectButton(
      bangumiItem: widget.bangumiItem,
      color: widget.color,
      onOpen: _acquireHold,
      onClose: _releaseHold,
    );
  }
}
