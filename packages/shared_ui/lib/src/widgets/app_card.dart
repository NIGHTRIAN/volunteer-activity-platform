import 'package:flutter/material.dart';

import 'package:shared_ui/src/tokens.dart';

/// 通用卡片容器。
///
/// 用**描边**而不是阴影划分层次（理由见 `app_theme.dart`）。
class AppCard extends StatelessWidget {
  const AppCard({
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(Spacing.md),
    this.highlight = false,
    this.semanticLabel,
    super.key,
  });

  final Widget child;

  /// 可点击时整卡响应点击，并显示按下反馈。
  final VoidCallback? onTap;

  final EdgeInsetsGeometry padding;

  /// 强调态：主色描边。用于"当前进行中的活动"这类需要一眼看到的卡片。
  final bool highlight;

  /// 无障碍标签。整卡可点时**必须**给，否则读屏只会读出一堆散文字。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: Radii.cardRadius,
        border: Border.all(
          color: highlight ? scheme.primary : AppColors.outline,
          width: highlight ? 1.5 : 1,
        ),
      ),
      child: child,
    );

    if (onTap != null) {
      content = Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: Radii.cardRadius,
          // 水波纹限制在卡片圆角内，否则会溢出成方块。
          customBorder: const RoundedRectangleBorder(borderRadius: Radii.cardRadius),
          child: content,
        ),
      );
    }

    if (semanticLabel != null) {
      content = Semantics(
        label: semanticLabel,
        button: onTap != null,
        container: true,
        child: content,
      );
    }

    return content;
  }
}

/// 带标题的区块。
///
/// 用于把表单或信息分组，附带可选的右上角操作（"全部"、"编辑"）。
class AppSection extends StatelessWidget {
  const AppSection({
    required this.title,
    required this.child,
    this.action,
    this.subtitle,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? action;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: text.titleMedium),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: Spacing.xxs),
                    Text(subtitle!, style: text.bodySmall),
                  ],
                ],
              ),
            ),
            ?action,
          ],
        ),
        const SizedBox(height: Spacing.sm),
        child,
      ],
    );
  }
}

/// 信息行：左标签、右值。用于详情页的字段罗列。
class InfoRow extends StatelessWidget {
  const InfoRow({
    required this.label,
    required this.value,
    this.valueWidget,
    this.icon,
    this.emphasize = false,
    super.key,
  });

  final String label;
  final String value;
  final Widget? valueWidget;
  final IconData? icon;

  /// 强调值（例如"志愿时长 3.0 小时"）。
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xxs + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: Sizes.iconSm, color: AppColors.textTertiary),
            ),
            const SizedBox(width: Spacing.xs),
          ],
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(width: Spacing.xs),
          Expanded(
            child: valueWidget ??
                Text(
                  value,
                  style: emphasize
                      ? text.titleMedium
                      : text.bodyMedium,
                ),
          ),
        ],
      ),
    );
  }
}
