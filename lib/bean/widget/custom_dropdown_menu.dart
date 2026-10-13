import 'package:flutter/material.dart';
import 'package:kazumi/bean/liquid_glass/kazumi_glass.dart';

/// A custom dropdown menu widget that provides smooth animations without flickering.
///
/// This widget was created to solve the visual flickering issue in Flutter's built-in
/// [PopupMenuButton] where menu items are rendered before the animation completes,
/// causing an uncoordinated visual effect.
class CustomDropdownMenu extends StatelessWidget {
  final Offset offset;
  final Size buttonSize;
  final Animation<double> animation;
  final List<String> items;
  final String Function(String) itemBuilder;
  final double? maxHeight;

  /// Minimum width constraint for the menu. Defaults to 140.
  /// Note: If [maxWidth] is less than [minWidth], [minWidth] will be used as both min and max.
  final double? minWidth;

  /// Maximum width constraint for the menu. Defaults to 200.
  /// Note: If this value is less than [minWidth], it will be adjusted to equal [minWidth].
  final double? maxWidth;
  final double gap;

  const CustomDropdownMenu({
    super.key,
    required this.offset,
    required this.buttonSize,
    required this.animation,
    required this.items,
    required this.itemBuilder,
    this.maxHeight,
    this.minWidth,
    this.maxWidth,
    this.gap = 4,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Ensure width constraints are valid (minWidth <= maxWidth)
    final computedMinWidth = minWidth ?? 140;
    final computedMaxWidth = maxWidth ?? 200;
    final normalizedMinWidth = computedMinWidth;
    final normalizedMaxWidth = computedMaxWidth < computedMinWidth
        ? computedMinWidth
        : computedMaxWidth;

    return GestureDetector(
      onTap: () => Navigator.pop(context),
      behavior: HitTestBehavior.opaque,
      child: Stack(
        children: [
          Positioned(
            left: offset.dx,
            top: offset.dy + buttonSize.height + gap,
            child: KazumiGlass.glassSurface(shape: KazumiGlass.panelShapeOf(context), child: Material(
                elevation: 0,
                clipBehavior: Clip.antiAlias,
                borderRadius:
                    BorderRadius.circular(KazumiGlass.panelRadiusOf(context)),
                color: KazumiGlass.enabled
                    ? Colors.transparent
                    : theme.colorScheme.surface,
                surfaceTintColor: Colors.transparent,
                shadowColor: Colors.transparent,
                child: AnimatedBuilder(
                  animation: animation,
                  builder: (context, child) {
                    final curvedValue =
                        Curves.easeOutCubic.transform(animation.value);
                    return ClipRect(
                      child: Align(
                        alignment: Alignment.topCenter,
                        heightFactor: curvedValue,
                        child: Opacity(
                          opacity: curvedValue,
                          child: child,
                        ),
                      ),
                    );
                  },
                  child: Container(
                    constraints: BoxConstraints(
                      maxHeight: maxHeight ?? 350,
                      minWidth: normalizedMinWidth,
                      maxWidth: normalizedMaxWidth,
                    ),
                    child: ListView.builder(
                      padding: KazumiGlass.menuPanelPadding,
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final itemValue = items[index];
                        final displayText = itemBuilder(itemValue);
                        // 整块菜单是一块大玻璃，条目只做按下时的圆角高亮
                        return KazumiGlass.menuItem(
                          context: context,
                          onTap: () => Navigator.pop(context, itemValue),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              displayText,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
