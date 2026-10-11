import 'package:flutter/material.dart';

const EdgeInsets materialBottomSheetContentPadding =
    EdgeInsets.fromLTRB(24, 0, 24, 24);

const EdgeInsets materialBottomSheetTabsPadding =
    EdgeInsets.fromLTRB(24, 0, 24, 16);

class MaterialBottomSheetHeader extends StatelessWidget {
  const MaterialBottomSheetHeader({
    super.key,
    required this.title,
    this.description,
    this.leading,
    this.onClose,
    this.trailing,
    this.compact = false,
  });

  final String title;
  final String? description;
  final Widget? leading;
  final VoidCallback? onClose;
  final Widget? trailing;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, compact ? 8 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ] else if (onClose != null) ...[
                const SizedBox(width: 12),
                // 这里不铺原生液态玻璃：弹窗里放原生玻璃视图会渲染成一大块
                // 遮挡，退回 Material 的圆形按钮，尺寸仍是 40（和顶栏玻璃按钮
                // 一致，视觉上是一套）。
                SizedBox.square(
                  dimension: 40,
                  child: IconButton(
                    onPressed: onClose,
                    tooltip: '关闭',
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.close_rounded, size: 22),
                  ),
                ),
              ],
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: 4),
            Text(
              description!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
