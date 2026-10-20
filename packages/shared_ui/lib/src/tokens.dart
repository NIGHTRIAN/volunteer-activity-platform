/// 设计令牌：颜色、间距、圆角、动效时长。
///
/// ## 为什么要有令牌层
///
/// 两端 App 由同一批人写，但界面差别很大（志愿者端是一屏一事的极简流，
/// 管理端是信息密集的工作台）。如果各处直接写 `Color(0xFF...)` 与 `16`，
/// 结果必然是：两端的"同一种灰"其实不是一个灰，"同一种间距"从 8 到 24 都有。
///
/// 令牌层把"哪些值是被设计过的"这件事固定下来。**组件里不应出现魔法数字。**
library;

import 'package:flutter/material.dart';

/// 间距刻度。4 的倍数，覆盖 4~40。
abstract final class Spacing {
  /// 4 —— 图标与文字之间。
  static const double xxs = 4;

  /// 8 —— 紧凑元素之间。
  static const double xs = 8;

  /// 12 —— 列表项内部。
  static const double sm = 12;

  /// 16 —— 默认间距，页面左右留白。
  static const double md = 16;

  /// 20 —— 卡片之间。
  static const double lg = 20;

  /// 24 —— 区块之间。
  static const double xl = 24;

  /// 32 —— 大区块分隔。
  static const double xxl = 32;

  /// 40 —— 页面顶部/底部呼吸区。
  static const double xxxl = 40;

  /// 页面左右统一留白。
  static const double pageGutter = md;
}

/// 圆角刻度。
abstract final class Radii {
  /// 8 —— 小控件（标签、输入框内元素）。
  static const double sm = 8;

  /// 12 —— 按钮。
  static const double md = 12;

  /// 16 —— 卡片。
  static const double lg = 16;

  /// 999 —— 胶囊形（状态标签、头像）。
  static const double pill = 999;

  static const BorderRadius cardRadius = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius buttonRadius = BorderRadius.all(Radius.circular(md));
  static const BorderRadius pillRadius = BorderRadius.all(Radius.circular(pill));
}

/// 动效时长。
///
/// 刻意的克制：本项目面向校园志愿场景，用户里有不少中老年教职工与
/// 只求"快点签上"的学生。**动效要短、要可预期**，不要让人等动画。
abstract final class Motion {
  /// 100ms —— 颜色/阴影的即时反馈。
  static const Duration instant = Duration(milliseconds: 100);

  /// 180ms —— 默认过渡。
  static const Duration fast = Duration(milliseconds: 180);

  /// 280ms —— 页面切换、展开。
  static const Duration normal = Duration(milliseconds: 280);

  /// 标准缓动。
  static const Curve ease = Curves.easeOutCubic;

  /// 进出对称的缓动（用于尺寸变化）。
  static const Curve emphasized = Curves.easeInOutCubic;
}

/// 颜色令牌。
///
/// ## 设计取向
///
/// 主色取**青绿**（teal）：既是"志愿/公益"的常见语义色，
/// 也在户外屏幕（活动多在白天室外签到）下比蓝紫更清晰。
///
/// 状态色与 `shared_core` 的领域枚举一一对应，**不要在页面里自造颜色**：
/// 签到的四种结果、活动的五种状态、在岗的四种结果都必须用这里的映射，
/// 否则两端会出现"同一个『已结束』是两种灰"。
abstract final class AppColors {
  /// 品牌主色（种子色）。
  static const Color seed = Color(0xFF0E7C6B);

  // ── 语义色 ────────────────────────────────────────────────────────────

  /// 成功 / 已签到 / 全勤。
  static const Color success = Color(0xFF1B873F);
  static const Color successContainer = Color(0xFFDCF5E3);
  static const Color onSuccessContainer = Color(0xFF08331A);

  /// 警告 / 待确认 / 部分完成。**不是错误**，是"需要人看一眼"。
  static const Color warning = Color(0xFFB26A00);
  static const Color warningContainer = Color(0xFFFFEFD6);
  static const Color onWarningContainer = Color(0xFF3D2400);

  /// 错误 / 被驳回 / 缺席。
  static const Color danger = Color(0xFFBA1A1A);
  static const Color dangerContainer = Color(0xFFFFDAD6);
  static const Color onDangerContainer = Color(0xFF410002);

  /// 信息 / 进行中 / 提示。
  static const Color info = Color(0xFF00639B);
  static const Color infoContainer = Color(0xFFCDE5FF);
  static const Color onInfoContainer = Color(0xFF001D33);

  /// 中性 / 未开始 / 无数据。
  static const Color neutral = Color(0xFF5F6368);
  static const Color neutralContainer = Color(0xFFE8EAED);
  static const Color onNeutralContainer = Color(0xFF1F1F1F);

  // ── 表面与描边（浅色主题）──────────────────────────────────────────────

  /// 页面底色。**略灰于纯白**，好让白色卡片浮起来。
  static const Color surface = Color(0xFFF7F9F8);

  /// 卡片底色。
  static const Color surfaceCard = Color(0xFFFFFFFF);

  /// 描边（弱）。用于卡片边界与分隔。
  static const Color outline = Color(0xFFDDE3E0);

  /// 描边（强）。用于输入框聚焦前的边界。
  static const Color outlineStrong = Color(0xFFBCC7C2);

  /// 主文本。
  static const Color textPrimary = Color(0xFF1A1C1B);

  /// 次要文本（说明、时间戳）。
  static const Color textSecondary = Color(0xFF5C6360);

  /// 弱文本（占位、禁用）。
  static const Color textTertiary = Color(0xFF8A918E);

  // ── 场地感知 ──────────────────────────────────────────────────────────

  /// 围栏内（签到页地图/距离指示）。
  static const Color insideFence = success;

  /// 围栏外但接近（还有希望走到）。
  static const Color nearFence = warning;

  /// 明显在外。
  static const Color outsideFence = danger;
}

/// 尺寸令牌。
abstract final class Sizes {
  /// 主要按钮高度。**不小于 48**：方案 §7 要求触控目标足够大。
  static const double buttonHeight = 52;

  /// 次要按钮高度。
  static const double buttonHeightCompact = 44;

  /// 输入框高度。
  static const double inputHeight = 52;

  /// 触控目标最小边长（无障碍要求）。
  static const double minTouchTarget = 48;

  /// 卡片最小高度。
  static const double cardMinHeight = 96;

  /// 底栏高度。
  static const double bottomBarHeight = 64;

  /// 图标尺寸。
  static const double iconSm = 16;
  static const double iconMd = 20;
  static const double iconLg = 24;
  static const double iconXl = 32;

  /// 页面最大内容宽度。
  ///
  /// 手机上是全宽；但在平板/折叠屏上无限拉伸会让一行文字过长而难读。
  /// 600 是中文正文在舒适阅读区内的上限附近。
  static const double maxContentWidth = 600;

  /// 管理端在平板上的最大内容宽度（信息密集，可以更宽）。
  static const double maxAdminContentWidth = 840;
}
