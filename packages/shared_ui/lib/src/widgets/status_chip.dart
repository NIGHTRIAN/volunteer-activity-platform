import 'package:flutter/material.dart';
import 'package:shared_ui/src/status_visuals.dart';
import 'package:shared_ui/src/tokens.dart';

/// 状态标签。
///
/// 两种密度：
///   * [StatusChip] —— 只出文字与色块，用于列表行尾；
///   * [StatusChip.detailed] —— 带图标、可附一行说明，用于详情页头部。
///
/// ⚠️ 文案与颜色**一律来自** [StatusVisuals]，页面不得自造
/// （理由见 `status_visuals.dart` 的说明）。
class StatusChip extends StatelessWidget {
  const StatusChip({
    required this.visual,
    this.compact = false,
    this.showIcon = false,
    super.key,
  }) : _detailed = false;

  /// 带说明文字的详细形态。
  const StatusChip.detailed({
    required this.visual,
    super.key,
  })  : compact = false,
        showIcon = true,
        _detailed = true;

  final StatusVisual visual;
  final bool compact;
  final bool showIcon;
  final bool _detailed;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    if (_detailed) {
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xs,
        ),
        decoration: BoxDecoration(
          color: visual.background,
          borderRadius: Radii.buttonRadius,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                visual.icon ?? Icons.info_outline,
                size: Sizes.iconMd,
                color: visual.foreground,
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    visual.label,
                    style: text.titleSmall?.copyWith(color: visual.onBackground),
                  ),
                  if (visual.description != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      visual.description!,
                      style: text.bodySmall?.copyWith(
                        color: visual.onBackground.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? Spacing.xs : Spacing.sm,
        vertical: compact ? 2 : Spacing.xxs,
      ),
      decoration: BoxDecoration(
        color: visual.background,
        borderRadius: Radii.pillRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (showIcon) ...<Widget>[
            Icon(visual.icon ?? Icons.circle, size: Sizes.iconSm, color: visual.foreground),
            const SizedBox(width: Spacing.xxs),
          ],
          Text(
            visual.label,
            style: (compact ? text.labelSmall : text.labelMedium)
                ?.copyWith(color: visual.onBackground),
          ),
        ],
      ),
    );
  }
}

/// 带数字的计数徽标（名额、待办数）。
class CountBadge extends StatelessWidget {
  const CountBadge({
    required this.count,
    this.max = 99,
    this.tone,
    super.key,
  });

  final int count;
  final int max;
  final StatusTone? tone;

  @override
  Widget build(BuildContext context) {
    final Color bg = tone == null
        ? AppColors.neutralContainer
        : StatusVisual(label: '', tone: tone!).background;
    final Color fg = tone == null
        ? AppColors.onNeutralContainer
        : StatusVisual(label: '', tone: tone!).onBackground;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: Radii.pillRadius),
      child: Text(
        count > max ? '$max+' : '$count',
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}
