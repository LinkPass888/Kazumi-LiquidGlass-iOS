import 'package:flutter/material.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:flutter_modular/flutter_modular.dart';

class CollectButton extends StatefulWidget {
  CollectButton({
    super.key,
    required this.bangumiItem,
    this.color = Colors.white,
    this.onOpen,
    this.onClose,
    this.menuAlignment,
    this.menuAlignmentOffset = Offset.zero,
  }) {
    isExtended = false;
  }

  CollectButton.extend({
    super.key,
    required this.bangumiItem,
    this.color = Colors.white,
    this.onOpen,
    this.onClose,
    this.menuAlignment,
    this.menuAlignmentOffset = Offset.zero,
  }) {
    isExtended = true;
  }

  final BangumiItem bangumiItem;
  final Color color;
  late final bool isExtended;
  final void Function()? onOpen;
  final void Function()? onClose;

  /// 菜单相对按钮的对齐方式。留空就是框架默认（右对齐时菜单会贴着屏幕边）。
  final AlignmentGeometry? menuAlignment;

  /// 菜单在 [menuAlignment] 基础上的偏移：往下一点、往里一点都靠它。
  final Offset menuAlignmentOffset;

  @override
  State<CollectButton> createState() => _CollectButtonState();
}

class _CollectButtonState extends State<CollectButton> {
  /// 量一下按钮自己的宽度，菜单面板跟它对齐。
  final GlobalKey _anchorKey = GlobalKey();
  // 1. 在看
  // 2. 想看
  // 3. 搁置
  // 4. 看过
  // 5. 抛弃
  late int collectType;
  final CollectController collectController = inject<CollectController>();
  // menuChildren 是在 build 里构造的，拿不到 builder 的 controller 参数，
  // 所以自己建一个交给 MenuAnchor 用
  final MenuController menuController = MenuController();

  @override
  void initState() {
    super.initState();
  }

  String getTypeStringByInt(int collectType) {
    switch (collectType) {
      case 1:
        return "在看";
      case 2:
        return "想看";
      case 3:
        return "搁置";
      case 4:
        return "看过";
      case 5:
        return "抛弃";
      default:
        return "未追";
    }
  }

  IconData getIconByInt(int collectType) {
    switch (collectType) {
      case 1:
        return Icons.favorite;
      case 2:
        return Icons.star_rounded;
      case 3:
        return Icons.pending_actions;
      case 4:
        return Icons.done;
      case 5:
        return Icons.heart_broken;
      default:
        return Icons.favorite_border;
    }
  }

  @override
  Widget build(BuildContext context) {
    collectType = collectController.getCollectType(widget.bangumiItem);
    return MenuAnchor(
      controller: menuController,
      consumeOutsideTap: true,
      onClose: widget.onClose,
      onOpen: widget.onOpen,
      crossAxisUnconstrained: false,
      // 默认摆法会「贴着按钮、贴着屏幕边」，给个偏移挪开一点
      alignmentOffset: widget.menuAlignmentOffset,
      // 面板本身画不了玻璃（框架自己画 Material），所以把它整块变透明，
      // 再在 menuChildren 里放一块玻璃顶上去。
      style: MenuStyle(
        alignment: widget.menuAlignment,
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
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
      builder: (_, MenuController controller, __) {
        if (widget.isExtended) {
          return KeyedSubtree(
            key: _anchorKey,
            child: FilledButton.icon(
            style: FilledButton.styleFrom(
              // 和外层玻璃、各菜单统一同一个圆角
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(
                  Radius.circular(KazumiGlass.panelRadiusOf(context)),
                ),
              ),
            ),
            onPressed: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
            icon: Icon(getIconByInt(collectType)),
              label: Text(getTypeStringByInt(collectType)),
            ),
          );
        } else {
          return IconButton(
            onPressed: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
            tooltip: getTypeStringByInt(collectType),
            icon: Icon(
              getIconByInt(collectType),
              color: widget.color,
            ),
          );
        }
      },
      // 面板整块用玻璃画：框架的菜单面板本身画不了玻璃，所以先把它的背景
      // 变透明，再把这一块玻璃当作唯一的面板内容顶上去。
      menuChildren: [
        KazumiGlass.glassSurface(
          shape: KazumiGlass.panelShapeOf(context),
          // 上下留空，和热门番组的菜单一致：条目高亮的圆角才和面板平行
          // 和条目高亮圆角配套的内边距，两个圆角是同心圆
          padding: KazumiGlass.menuPanelPadding,
          child: SizedBox(
            // 和详情页那个收藏按钮一样宽
            width: _anchorKey.currentContext?.size?.width ?? 120,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: List<Widget>.generate(
                6,
                (int index) => KazumiGlass.menuItem(
                    context: context,
                    selected: index == collectType,
                    onTap: () async {
                      menuController.close();
                      if (index != collectType && mounted) {
                        await collectController.addCollect(widget.bangumiItem,
                            type: index);
                        // 防止状态错误刷新
                        if (!mounted) {
                          return;
                        }
                        setState(() {});
                      }
                    },
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          getIconByInt(index),
                          size: 20,
                          color: index == collectType
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        const SizedBox(width: 6),
                        Text(getTypeStringByInt(index)),
                      ],
                    ),
                  ),
              ),
            ),
          ),
        ),
      ],
    );
  }

}
