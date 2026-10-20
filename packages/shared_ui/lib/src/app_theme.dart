import 'package:flutter/material.dart';

import 'tokens.dart';

/// 主题构建。
///
/// 两端共用同一套令牌与排版，只在**信息密度**上分叉：
///   * 用户端 `compact: false` —— 一屏一事，字号偏大、留白充足；
///   * 管理端 `compact: true` —— 信息密集，行高与内边距收紧，
///     但**不缩小触控目标**（现场戴手套点屏幕的人不止一个）。
///
/// 使用 Material 3（`useMaterial3: true`）。
abstract final class AppTheme {
  /// 把"期望的最终高度"换算成 `minimumSize` 的高度。
  ///
  /// ## 为什么需要换算（实测踩到过）
  ///
  /// `ButtonStyleButton` 会这样算最终高度：
  /// ```
  /// max(minimumSize.height - density.vertical * 4, 0)
  /// ```
  /// 也就是说 `visualDensity` 是在 `minimumSize` **之后**被减掉的。
  ///
  /// 管理端主题用 `VisualDensity.compact`（vertical = −2），
  /// 于是"写了 52"的按钮实际渲染成 **44** —— 而 44 恰好还在
  /// 无障碍最小值附近，看起来"没坏"，只是悄悄变矮了。
  ///
  /// 直接量尺寸的测试才会发现这一点：主题里读到的 `minimumSize` 仍是 52。
  static double _minHeightFor(double desired, VisualDensity density) {
    // `clamp` 的返回类型是 `num`，直接 `as int` 会在 double 上炸；
    // `round()` 更稳（VisualDensity 的取值本就是整数语义）。
    final int v = density.vertical.clamp(-4, 4).round();
    return desired - v * 4;
  }

  /// 构建主题。
  ///
  /// [compact] 为 `true` 时收紧垂直节奏，供管理端使用。
  static ThemeData build({bool compact = false}) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: AppColors.seed,
      brightness: Brightness.light,
    ).copyWith(
      // 覆盖为我们的语义色，避免 Material 自动生成的色与令牌表不一致。
      surface: AppColors.surface,
      outline: AppColors.outline,
      outlineVariant: AppColors.outlineStrong,
      error: AppColors.danger,
      onError: Colors.white,
      errorContainer: AppColors.dangerContainer,
      onErrorContainer: AppColors.onDangerContainer,
    );

    final TextTheme text = _textTheme(compact: compact);
    final VisualDensity density =
        compact ? VisualDensity.compact : VisualDensity.standard;

    // 补偿 visualDensity 后的实际最小高度（见 _minHeightFor 的说明）。
    final Size buttonMin = Size(
      64,
      _minHeightFor(Sizes.buttonHeight, density),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.surface,
      textTheme: text,
      // ── 排版与密度 ───────────────────────────────────────────────────
      visualDensity: density,
      // ── AppBar：扁平、无阴影 ─────────────────────────────────────────
      //
      // 刻意不用 Material 3 默认的"滚动时染色"。本项目的页面多为
      // 单一任务型（签到/看板），顶栏变色只会分散注意力。
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
        toolbarHeight: compact ? 56 : 60,
      ),
      // ── 卡片 ─────────────────────────────────────────────────────────
      //
      // 用**描边**而不是阴影来划分层次：阴影在廉价屏上容易糊成灰块，
      // 而户外强光下几乎看不见。1px 描边更可靠。
      cardTheme: const CardThemeData(
        color: AppColors.surfaceCard,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.cardRadius,
          side: BorderSide(color: AppColors.outline),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.outline,
        thickness: 1,
        space: 1,
      ),
      // ── 按钮 ─────────────────────────────────────────────────────────
      //
      // ⚠️ 这里**不能**用 `Size.fromHeight(...)`。
      //
      // `Size.fromHeight(52)` 实际是 `Size(double.infinity, 52)`，
      // 而 `ButtonStyleButton` 在合并默认样式时会断言尺寸必须是有限的，
      // 于是整个 ButtonStyle 被判定为非法并**静默退回** Material 默认
      // （最小高度 40）。症状是"主题里明明写了 52，按钮却是 40 高"，
      // 而且不会报任何错——实测踩到过。
      //
      // 宽度用 64（Material 的常规值），实际宽度由子组件内容撑开；
      // 需要全宽的场景靠外层拉伸，不靠 minimumSize。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: buttonMin,
          shape: const RoundedRectangleBorder(borderRadius: Radii.buttonRadius),
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: buttonMin,
          side: const BorderSide(color: AppColors.outlineStrong),
          foregroundColor: AppColors.textPrimary,
          shape: const RoundedRectangleBorder(borderRadius: Radii.buttonRadius),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(Sizes.minTouchTarget, Sizes.minTouchTarget),
          foregroundColor: scheme.primary,
          textStyle: text.labelLarge,
        ),
      ),
      // ── 输入 ─────────────────────────────────────────────────────────
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceCard,
        isDense: compact,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm,
        ),
        border: const OutlineInputBorder(
          borderRadius: Radii.buttonRadius,
          borderSide: BorderSide(color: AppColors.outlineStrong),
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: Radii.buttonRadius,
          borderSide: BorderSide(color: AppColors.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: Radii.buttonRadius,
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: const OutlineInputBorder(
          borderRadius: Radii.buttonRadius,
          borderSide: BorderSide(color: AppColors.danger),
        ),
        hintStyle: text.bodyMedium?.copyWith(color: AppColors.textTertiary),
        helperStyle: text.bodySmall,
        errorStyle: text.bodySmall?.copyWith(color: AppColors.danger),
      ),
      // ── 其他 ─────────────────────────────────────────────────────────
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.textPrimary,
        contentTextStyle: text.bodyMedium?.copyWith(color: Colors.white),
        shape: const RoundedRectangleBorder(borderRadius: Radii.buttonRadius),
        insetPadding: const EdgeInsets.all(Spacing.md),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surfaceCard,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: Radii.cardRadius),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surfaceCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
        ),
        showDragHandle: true,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.neutralContainer,
        labelStyle: text.labelMedium,
        side: BorderSide.none,
        shape: const RoundedRectangleBorder(borderRadius: Radii.pillRadius),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: 2),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surfaceCard,
        elevation: 0,
        height: Spacing.xxxl + Spacing.lg,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStatePropertyAll<TextStyle?>(text.labelSmall),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.xxs,
        ),
        titleTextStyle: text.bodyLarge,
        subtitleTextStyle: text.bodySmall,
        shape: const RoundedRectangleBorder(borderRadius: Radii.buttonRadius),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearMinHeight: 4,
      ),
    );
  }

  /// 排版。
  ///
  /// ## 中文字体的处理
  ///
  /// **不打包中文字体文件**：一个思源黑体子集动辄 3~8MB，
  /// 而本 App 的安装包目标要能"扫码即下"。因此依赖系统字体，
  /// Android 上落到 `Noto Sans CJK`（各厂商 ROM 都内置），效果稳定。
  ///
  /// 行高刻意给到 1.5~1.6：中文没有西文的 x-height 缓冲，
  /// 行距过密会显著降低可读性（管理端的名单、明细尤其明显）。
  static TextTheme _textTheme({required bool compact}) {
    // 中文行高倍率。
    const double h = 1.55;
    const double hTight = 1.4;

    return TextTheme(
      // 页面大标题（用户端首页活动名）
      headlineMedium: TextStyle(
        fontSize: compact ? 22 : 24,
        height: hTight,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      // 区块标题 / 对话框标题
      titleLarge: TextStyle(
        fontSize: compact ? 17 : 18,
        height: hTight,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      // 卡片标题 / 列表主行
      titleMedium: const TextStyle(
        fontSize: 16,
        height: hTight,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      titleSmall: const TextStyle(
        fontSize: 14,
        height: hTight,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      // 正文
      // ⚠️ 这一项**不能** const：字号依赖运行时的 `compact`。
      bodyLarge: TextStyle(
        fontSize: compact ? 15 : 16,
        height: h,
        color: AppColors.textPrimary,
      ),
      bodyMedium: const TextStyle(
        fontSize: 14,
        height: h,
        color: AppColors.textPrimary,
      ),
      // 说明文字 / 时间戳
      bodySmall: const TextStyle(
        fontSize: 12.5,
        height: h,
        color: AppColors.textSecondary,
      ),
      // 按钮
      labelLarge: const TextStyle(
        fontSize: 16,
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      labelMedium: const TextStyle(
        fontSize: 12.5,
        height: 1.3,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      ),
      labelSmall: const TextStyle(
        fontSize: 11,
        height: 1.3,
        fontWeight: FontWeight.w500,
        color: AppColors.textSecondary,
      ),
    );
  }
}
