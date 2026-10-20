import 'package:flutter/material.dart';

import 'package:shared_ui/src/tokens.dart';

/// 平台主按钮。
///
/// ## 为什么要包一层而不是直接用 `FilledButton`
///
/// 三个必须统一的行为，散在各页面里一定会漏：
///
/// 1. **加载态必须禁用重复点击**。签到与在岗确认这类动作，
///    重复提交会造成"到底算一次还是两次"的疑问（虽然服务端有幂等键兜底，
///    但界面上不该出现两个并行的"提交中"）。
/// 2. **加载态要占位而不改变尺寸**。按钮文字换成转圈后如果宽度跳动，
///    用户的手指会落在错误的位置——连续点两次会点到别的东西。
/// 3. **禁用时要有可见的禁用样式**，而不是看起来还能点。
enum AppButtonVariant {
  /// 主操作：填充。
  primary,

  /// 次操作：描边。
  secondary,

  /// 第三级：纯文字。
  text,

  /// 破坏性操作（取消活动、移出名单）。用危险色。
  danger,
}

class AppButton extends StatelessWidget {
  const AppButton({
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.icon,
    this.loading = false,
    this.loadingLabel,
    this.expand = true,
    this.compact = false,
    super.key,
  });

  final String label;

  /// 为 `null` 时禁用。
  final VoidCallback? onPressed;

  final AppButtonVariant variant;
  final IconData? icon;

  /// 加载中：显示进度并**禁止点击**。
  final bool loading;

  /// 加载中的文字（例如"提交中…"）。为 `null` 时沿用 [label]。
  final String? loadingLabel;

  /// 是否占满宽度。默认占满——本项目的按钮多数是全宽主操作。
  final bool expand;

  /// 紧凑高度（用于列表行内的小按钮）。
  final bool compact;

  /// 是否可点击。
  bool get _enabled => onPressed != null && !loading;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final VisualDensity density = Theme.of(context).visualDensity;

    // 显示的文字：加载时换成 loadingLabel（若提供）。
    final String effectiveLabel = loading ? (loadingLabel ?? label) : label;

    final Widget child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        // ⚠️ 加载时**保留**图标位（换成转圈），保证按钮宽度基本不变。
        if (loading) ...<Widget>[
          SizedBox(
            width: Sizes.iconMd,
            height: Sizes.iconMd,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: _spinnerColor(scheme),
            ),
          ),
          const SizedBox(width: Spacing.xs),
        ] else if (icon != null) ...<Widget>[
          Icon(icon, size: Sizes.iconMd),
          const SizedBox(width: Spacing.xs),
        ],
        Flexible(
          child: Text(
            effectiveLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );

    final ButtonStyle? style = compact
        ? _compactStyle(variant, scheme, density)
        : null; // 非紧凑时用主题里的统一样式

    return switch (variant) {
      AppButtonVariant.primary => FilledButton(
          onPressed: _enabled ? onPressed : null,
          style: style,
          child: child,
        ),
      AppButtonVariant.secondary => OutlinedButton(
          onPressed: _enabled ? onPressed : null,
          style: style,
          child: child,
        ),
      AppButtonVariant.text => TextButton(
          onPressed: _enabled ? onPressed : null,
          style: style,
          child: child,
        ),
      AppButtonVariant.danger => FilledButton(
          onPressed: _enabled ? onPressed : null,
          style: (style ?? FilledButton.styleFrom()).copyWith(
            backgroundColor: const WidgetStatePropertyAll<Color?>(AppColors.danger),
            foregroundColor: const WidgetStatePropertyAll<Color?>(Colors.white),
          ),
          child: child,
        ),
    };
  }

  Color _spinnerColor(ColorScheme scheme) {
    return switch (variant) {
      // 填充按钮上转圈用前景色（白）。
      AppButtonVariant.primary ||
      AppButtonVariant.danger =>
        Colors.white,
      AppButtonVariant.secondary || AppButtonVariant.text => scheme.primary,
    };
  }

  /// 紧凑按钮：覆盖主题里的全高设置。
  ///
  /// ⚠️ 这里必须**补偿 `visualDensity`**。
  ///
  /// `ButtonStyleButton` 的最终高度是
  /// `minimumSize.height - density.vertical * 4`。
  /// 管理端主题开了 `VisualDensity.compact`（vertical = −2），
  /// 于是"写 44"实际渲染成 36 —— 已经低于无障碍最小触控目标。
  ///
  /// 详见 `app_theme.dart` 里 `_minHeightFor` 的说明（同一个坑）。
  ButtonStyle _compactStyle(
    AppButtonVariant variant,
    ColorScheme scheme,
    VisualDensity density,
  ) {
    // 先加回被密度吃掉的高度，再交给 Flutter 去减。
    final double height = Sizes.buttonHeightCompact - density.vertical * 4;
    final Size minSize = Size(64, height < 1 ? 1 : height);
    return switch (variant) {
      AppButtonVariant.primary =>
        FilledButton.styleFrom(minimumSize: minSize),
      AppButtonVariant.danger => FilledButton.styleFrom(minimumSize: minSize),
      AppButtonVariant.secondary => OutlinedButton.styleFrom(
          minimumSize: minSize,
          side: const BorderSide(color: AppColors.outlineStrong),
          foregroundColor: AppColors.textPrimary,
        ),
      AppButtonVariant.text => TextButton.styleFrom(
          minimumSize: minSize,
          foregroundColor: scheme.primary,
        ),
    };
  }
}
