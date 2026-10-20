import 'package:flutter/material.dart';
import 'package:shared_ui/src/tokens.dart';

/// 页面路由名。
///
/// ## 为什么集中成常量
///
/// 路由名散落成字符串字面量时，`pushNamed('/activty-detail')` 这样的拼写错误
/// 在编译期完全无法发现，运行时才抛 "Could not find a generator for route" ——
/// 而这通常发生在最不该出问题的路径上（例如用户刚扫完码要点签到）。
abstract final class Routes {
  // ── 用户端 ────────────────────────────────────────────────────────────
  /// 主页（活动列表 / 我的记录）。
  static const String userHome = '/';

  /// 绑定（学号 + 一次性邀请码）。
  static const String userBind = '/bind';

  /// 活动详情。
  static const String userActivity = '/activity';

  /// 签到页。
  static const String userCheckin = '/checkin';

  /// 我的记录（含待同步队列）。
  static const String userRecords = '/records';

  // ── 管理端 ────────────────────────────────────────────────────────────
  /// 活动列表。
  static const String adminHome = '/';

  /// 登录（邀请码）。
  static const String adminLogin = '/login';

  /// 活动编辑 / 上报。
  static const String adminActivityEdit = '/activity/edit';

  /// 活动详情（含名单、看板、考勤、导出的分页）。
  static const String adminActivity = '/activity';

  /// 设置（导出审计、隐私说明）。
  static const String adminSettings = '/settings';

  // ── 共用 ──────────────────────────────────────────────────────────────
  /// 隐私与权限说明。
  static const String privacy = '/privacy';

  /// 数据同步详情（离线队列逐条状态）。
  static const String syncDetails = '/sync';
}

/// 路由参数键。
///
/// 与 [Routes] 同理：用常量而不是字符串字面量。
abstract final class RouteArgs {
  /// 活动 ID。
  static const String activityId = 'activityId';

  /// 在岗任务 ID。
  static const String taskId = 'taskId';

  /// 学号 / 工号。
  static const String userNo = 'userNo';
}

/// 页面切换动画。
///
/// ## 为什么统一用一个偏"快"的曲线
///
/// 本项目面向校园志愿场景，用户里有不少中老年教职工，
/// 也有只想"快点签上"的学生。**动效要短、要可预期**。
/// 默认的 Material 转场在低端机上会拖到 300ms 以上，叠加网络等待后
/// 会让人以为卡住了。
///
/// 因此统一用 280ms + `easeOutCubic`（见 [Motion]），并且：
/// * 不自定义花哨的转场（共享轴、淡入淡出组合等），
///   它们在低端机上的掉帧率明显高于默认转场；
/// * 保持系统默认的返回手势与物理返回键行为。
Route<T> appRoute<T>(Widget page, {String? name, Object? arguments}) {
  return MaterialPageRoute<T>(
    builder: (_) => page,
    settings: RouteSettings(name: name, arguments: arguments),
  );
}

/// 便捷：带淡入上滑的页面（用于"下一层级"的导航）。
///
/// 只在明确需要"层级推进"的语义时使用（例如进入签到页），
/// 普通页面用 [appRoute] 即可。
Route<T> appSlideRoute<T>(Widget page, {String? name, Object? arguments}) {
  return PageRouteBuilder<T>(
    settings: RouteSettings(name: name, arguments: arguments),
    transitionDuration: Motion.normal,
    reverseTransitionDuration: Motion.fast,
    pageBuilder: (_, _, _) => page,
    transitionsBuilder: (
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondary,
      Widget child,
    ) {
      final Animation<double> curved = CurvedAnimation(
        parent: animation,
        curve: Motion.ease,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// 从任意 context 安全地取路由参数。
///
/// 参数的读取方式容易写错（`ModalRoute.of(context)!.settings.arguments as Map`），
/// 而写错会得到难以定位的运行时类型错误。这里统一处理：
/// 类型不对时返回 `null` 而不是抛异常，调用方按"缺少参数"处理即可。
String? routeArgString(BuildContext context, String key) {
  final Object? args = ModalRoute.of(context)?.settings.arguments;
  if (args is Map) {
    final Object? v = args[key];
    return v?.toString();
  }
  return null;
}

/// 取整个参数表。
Map<String, Object?> routeArgs(BuildContext context) {
  final Object? args = ModalRoute.of(context)?.settings.arguments;
  if (args is Map) {
    return args.map(
      (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
    );
  }
  return const <String, Object?>{};
}
