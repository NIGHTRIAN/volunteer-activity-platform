import 'package:flutter/material.dart';

import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/shared_ui.dart';

/// 签到入口的可用性与提示（界面层判定）。
///
/// ## 为什么单独抽出来
///
/// 这段判断原本内联在 `HomePage` 的 builder 里，只看 `status`：
///
/// ```dart
/// if (a.status == ActivityStatus.ongoing) 显示"去签到"
/// else if (a.status == ActivityStatus.published) 显示"活动尚未开始"
/// ```
///
/// 真机测试暴露出这是错的：服务端**不会自动把 `published` 转成 `ongoing`**
/// （见 `docs/open-issues-app.md` O-3），所以活动到了开始时刻状态仍是
/// `published` —— 界面于是永远显示"活动尚未开始"，
/// **签到按钮永远不出现，志愿者根本没法签到**。
///
/// 内联在 builder 里既难测也容易再写错，所以抽成纯函数：
/// 输入（活动 + 当前时刻）→ 输出（能不能签 + 该说什么），
/// 这样每条分支都能被单测覆盖。
///
/// ## 口径：按签到时间窗，不按状态
///
/// 判断依据是 `Activity.isWithinCheckinWindow(now)`，
/// 与方案 §6.1 的服务端口径一致（开始前 N 分钟 ~ 结束后 M 分钟）。
/// `status` 只用来排除**已终结**的活动（结束/取消）。
///
/// ⚠️ 这不违反"服务端是判定权威"（方案 §2）：本函数只决定
/// **界面显示什么**，真正的签到判定仍在服务端，窗口外提交会被拒。
@immutable
class CheckinAvailability {
  const CheckinAvailability({
    required this.canCheckin,
    required this.icon,
    required this.message,
    required this.tone,
  });

  /// 是否显示「去签到」按钮。
  final bool canCheckin;

  /// 不可签到时使用的图标。
  final IconData icon;

  /// 不可签到时给用户看的原因（含具体时刻）。
  final String message;

  /// 提示色调。已取消用 danger，窗口已关闭用 warning，其余用 info/neutral。
  final StatusTone tone;
}

/// 判定某活动在 [now] 时刻的签到入口状态。
CheckinAvailability checkinAvailability(Activity a, DateTime now) {
  final bool ended = a.status == ActivityStatus.finished;
  final bool cancelled = a.status == ActivityStatus.cancelled;

  if (cancelled) {
    return const CheckinAvailability(
      canCheckin: false,
      icon: Icons.cancel_outlined,
      // 明确"已到场的记录不受影响"，否则到场的人会担心白干。
      message: '活动已取消，无需签到。已到场的记录不受影响。',
      tone: StatusTone.danger,
    );
  }

  if (ended) {
    return const CheckinAvailability(
      canCheckin: false,
      icon: Icons.flag_outlined,
      // 顺带告知留存期，这是方案 §9.3 的真实约束。
      message: '活动已结束。你可以在 7 天内查看并导出自己的记录。',
      tone: StatusTone.neutral,
    );
  }

  if (a.isWithinCheckinWindow(now)) {
    return const CheckinAvailability(
      canCheckin: true,
      icon: Icons.my_location,
      message: '',
      tone: StatusTone.info,
    );
  }

  if (now.isBefore(a.checkinOpensAt)) {
    // 给出**具体开放时刻**，而不是"暂不可用"。
    return CheckinAvailability(
      canCheckin: false,
      icon: Icons.schedule,
      message: '签到将于 ${TimeFormat.format(a.checkinOpensAt)} 开放。',
      tone: StatusTone.info,
    );
  }

  // 已过窗口关闭时刻，但活动状态还没被标为结束
  // （服务端不自动流转的另一种表现）。
  //
  // 这里必须指出**下一步**：找发布者现场核实。否则志愿者会以为
  // 自己漏了什么，却不知道该做什么。
  return CheckinAvailability(
    canCheckin: false,
    icon: Icons.lock_clock,
    message: '签到时段已于 ${TimeFormat.format(a.checkinClosesAt)} 关闭。'
        '如需补录，请联系发布者现场核实。',
    tone: StatusTone.warning,
  );
}
