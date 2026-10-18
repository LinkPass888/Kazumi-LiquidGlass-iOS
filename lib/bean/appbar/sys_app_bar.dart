import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/bean/widget/embedded_native_control_area.dart';

/// 顶栏大标题的样式：字号与字重和推荐页的「热门番组」保持一致。
TextStyle appBarTitleStyle(BuildContext context) =>
    Theme.of(context).textTheme.headlineMedium!.copyWith(
          fontSize: 28,
          fontWeight: FontWeight.w700,
        );

/// 顶栏里的「宽动作」：图标 + 文字的自带玻璃药丸。
///
/// [SysAppBar] 会把每个 action 统一套进一层 40×40 的圆玻璃（图标居中）。
/// 带文字的按钮塞不进那个圆，所以用这个包一层放进 `actions`：SysAppBar 见到它会
/// 原样透传（不再套圆玻璃、也不再量成 40×40），玻璃由调用方自己用
/// [KazumiGlass.barPill] 出。
class SysAppBarWideAction extends StatelessWidget {
  const SysAppBarWideAction({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class SysAppBar extends StatelessWidget implements PreferredSizeWidget {
  final double? toolbarHeight;

  final Widget? title;

  final Color? backgroundColor;

  final double? elevation;

  final ShapeBorder? shape;

  final List<Widget>? actions;

  final Widget? leading;

  final double? leadingWidth;

  final PreferredSizeWidget? bottom;

  final bool needTopOffset;

  const SysAppBar(
      {super.key,
      this.toolbarHeight,
      this.title,
      this.backgroundColor,
      this.elevation,
      this.shape,
      this.actions,
      this.leading,
      this.leadingWidth,
      this.bottom,
      this.needTopOffset = true});

  @override
  Widget build(BuildContext context) {
    List<Widget> acs = [];
    if (actions != null) {
      acs.addAll(actions!);
    }
    // 顶栏不再整条铺玻璃（那会在别的页面盖过来时透出一道光边），改成
    // iOS 26 的软渐进模糊，按钮各自带一层玻璃。
    // 返回键与右侧按钮统一成同样大小的圆形玻璃，图标居中，离边缘留白
    Widget? leadingWidget;
    if (leading != null) {
      leadingWidget = Center(
        child: KazumiGlass.buttonGlass(
          child: SizedBox(
            width: KazumiGlass.barButtonSize,
            height: KazumiGlass.barButtonSize,
            child: EmbeddedNativeControlArea(
              requireOffset: needTopOffset,
              child: leading!,
            ),
          ),
        ),
      );
    } else if (ModalRoute.of(context)?.impliesAppBarDismissal ?? false) {
      leadingWidget = Center(
        child: KazumiGlass.iconButton(
          context: context,
          icon: const Icon(Icons.arrow_back, size: 22),
          onPressed: () => context.maybePop(),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        ),
      );
    }
    final List<Widget> actionWidgets = <Widget>[];
    for (final Widget action in acs) {
      // 宽动作（图标 + 文字的自带玻璃药丸）原样透传：它的高度已经和圆玻璃一致
      // （KazumiGlass.barButtonSize），再套一层 40×40 会把文字压扁。
      if (action is SysAppBarWideAction || action is SizedBox) {
        actionWidgets.add(action);
        continue;
      }
      if (actionWidgets.isNotEmpty) {
        actionWidgets.add(const SizedBox(width: KazumiGlass.barButtonGap));
      }
      actionWidgets.add(
        KazumiGlass.buttonGlass(
          child: SizedBox(
            width: KazumiGlass.barButtonSize,
            height: KazumiGlass.barButtonSize,
            child: EmbeddedNativeControlArea(
              requireOffset: needTopOffset,
              child: action,
            ),
          ),
        ),
      );
    }
    if (actionWidgets.isNotEmpty) {
      actionWidgets.add(const SizedBox(width: KazumiGlass.barEdgeInset));
    }
    return AppBar(
      toolbarHeight: preferredSize.height,
      scrolledUnderElevation: 0.0,
      title: title != null
          ? EmbeddedNativeControlArea(
              requireOffset: needTopOffset,
              child: title!,
            )
          : null,
      centerTitle: false,
      actions: actionWidgets,
      leading: leadingWidget,
      leadingWidth: leadingWidth ?? KazumiGlass.barLeadingWidth,
      backgroundColor: backgroundColor,
      elevation: elevation,
      shape: shape,
      bottom: bottom,
      automaticallyImplyLeading: false,
      systemOverlayStyle: KazumiGlass.overlayStyle(context),
    );
  }

  @override
  Size get preferredSize {
    return Size.fromHeight(toolbarHeight ?? kToolbarHeight);
  }
}
