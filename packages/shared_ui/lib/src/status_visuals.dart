import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';

import 'tokens.dart';

/// 状态 → 视觉的**唯一映射**。
///
/// ## 为什么必须集中
///
/// 同一份领域状态会出现在三端（用户端、管理端、将来的网页端）。
/// 如果各页面自己写 `switch (status) { case ...: return Colors.green; }`，
/// 必然出现"用户端说『已签到』是绿的，管理端说『已签到』是蓝的"这类不一致——
/// 而这类不一致在争议场景下会变成"到底以哪个为准"的扯皮。
///
/// 因此：**页面里不允许为业务状态自造颜色与文案**，一律查这里。
///
/// ## 语义取向（重要）
///
/// * [AppColors.success] 只给"确定的好结果"，不给"暂无问题"；
/// * [AppColors.warning] 表示**需要人看一眼**，不是错误。
///   在岗抽查的 `pending_review`、考勤的 `partial` 都属此类：
///   把它们画成红色会让志愿者以为自己被处罚了，而实际上什么都没发生；
/// * [AppColors.neutral] 给"未开始 / 无数据"，**不给"未签到"**——
///   "未签到"在活动进行中是需要行动的状态，用中性灰会被忽略。
enum StatusTone {
  /// 确定的好结果（已签到、全勤、已完成）。
  success,

  /// 需要人看一眼（待确认、部分完成、待同步）。
  warning,

  /// 明确的坏结果（被驳回、缺席、超时未响应）。
  danger,

  /// 进行中 / 已通知（已发布、进行中）。
  info,

  /// 未开始 / 无数据 / 已归档。
  neutral,
}

/// 一个状态的完整视觉定义。
@immutable
class StatusVisual {
  const StatusVisual({
    required this.label,
    required this.tone,
    this.icon,
    this.description,
  });

  /// 界面文案。
  final String label;

  /// 语义色调。
  final StatusTone tone;

  /// 可选图标。
  final IconData? icon;

  /// 可选补充说明（用于管理端把"这意味着什么"讲清楚）。
  final String? description;

  /// 前景色。
  Color get foreground => switch (tone) {
        StatusTone.success => AppColors.success,
        StatusTone.warning => AppColors.warning,
        StatusTone.danger => AppColors.danger,
        StatusTone.info => AppColors.info,
        StatusTone.neutral => AppColors.neutral,
      };

  /// 背景色。
  Color get background => switch (tone) {
        StatusTone.success => AppColors.successContainer,
        StatusTone.warning => AppColors.warningContainer,
        StatusTone.danger => AppColors.dangerContainer,
        StatusTone.info => AppColors.infoContainer,
        StatusTone.neutral => AppColors.neutralContainer,
      };

  /// 背景上的文字色（保证对比度）。
  Color get onBackground => switch (tone) {
        StatusTone.success => AppColors.onSuccessContainer,
        StatusTone.warning => AppColors.onWarningContainer,
        StatusTone.danger => AppColors.onDangerContainer,
        StatusTone.info => AppColors.onInfoContainer,
        StatusTone.neutral => AppColors.onNeutralContainer,
      };
}

/// 状态视觉映射表。
abstract final class StatusVisuals {
  // ── 活动状态（方案 §5.1）────────────────────────────────────────────

  static const Map<ActivityStatus, StatusVisual> activity =
      <ActivityStatus, StatusVisual>{
    ActivityStatus.draft: StatusVisual(
      label: '草稿',
      tone: StatusTone.neutral,
      icon: Icons.edit_note_outlined,
      description: '仅你自己可见，尚未对志愿者开放',
    ),
    ActivityStatus.published: StatusVisual(
      label: '已发布',
      tone: StatusTone.info,
      icon: Icons.campaign_outlined,
      description: '名单与规则已冻结，等待开始',
    ),
    ActivityStatus.ongoing: StatusVisual(
      label: '进行中',
      tone: StatusTone.success,
      icon: Icons.play_circle_outline,
      description: '可以签到，正在按间隔进行在岗抽查',
    ),
    ActivityStatus.finished: StatusVisual(
      label: '已结束',
      tone: StatusTone.neutral,
      icon: Icons.flag_outlined,
      description: '已生成考勤汇总，7 天后数据不可访问',
    ),
    ActivityStatus.cancelled: StatusVisual(
      label: '已取消',
      tone: StatusTone.danger,
      icon: Icons.cancel_outlined,
      description: '不可撤销；未发生的抽查已豁免，不影响到场者记录',
    ),
    ActivityStatus.unknown: StatusVisual(
      label: '未知状态',
      tone: StatusTone.neutral,
      icon: Icons.help_outline,
    ),
  };

  // ── 报名状态（方案 §4.3）────────────────────────────────────────────

  static const Map<SignupStatus, StatusVisual> signup =
      <SignupStatus, StatusVisual>{
    SignupStatus.signed: StatusVisual(
      label: '已报名',
      tone: StatusTone.info,
      icon: Icons.how_to_reg_outlined,
    ),
    SignupStatus.pendingConfirm: StatusVisual(
      label: '待确认',
      tone: StatusTone.warning,
      icon: Icons.help_center_outlined,
      description: '姓名或手机号后四位不匹配，需人工核对',
    ),
    SignupStatus.cancelled: StatusVisual(
      label: '已移出',
      tone: StatusTone.neutral,
      icon: Icons.person_remove_outlined,
      description: '已移出名单，但其历史记录仍保留',
    ),
    SignupStatus.unknown: StatusVisual(label: '未知', tone: StatusTone.neutral),
  };

  // ── 名单行的签到状态（方案 §4.8 看板四态）──────────────────────────

  static const Map<ParticipantCheckinStatus, StatusVisual> participantCheckin =
      <ParticipantCheckinStatus, StatusVisual>{
    ParticipantCheckinStatus.checkedIn: StatusVisual(
      label: '已签到',
      tone: StatusTone.success,
      icon: Icons.check_circle_outline,
    ),
    ParticipantCheckinStatus.pendingReview: StatusVisual(
      label: '待确认',
      tone: StatusTone.warning,
      icon: Icons.visibility_outlined,
      description: '证据不足，需现场核实或人工补录',
    ),
    ParticipantCheckinStatus.notCheckedIn: StatusVisual(
      // 措辞是"尚未签到"而不是"未签到"：活动还没开始时所有人都是这个状态，
      // 说成"未签到"会让人以为出问题了。发布者看板上这一列的措辞尤其重要。
      label: '尚未签到',
      tone: StatusTone.danger,
      icon: Icons.radio_button_unchecked,
      description: '还没有签到记录。活动开始后可由本人签到，或由你现场核实。',
    ),
    ParticipantCheckinStatus.absent: StatusVisual(
      label: '缺席',
      tone: StatusTone.danger,
      icon: Icons.person_off_outlined,
    ),
    ParticipantCheckinStatus.unknown: StatusVisual(
      label: '未知',
      tone: StatusTone.neutral,
    ),
  };

  // ── 签到结果（方案 §5.3）────────────────────────────────────────────

  static const Map<CheckinStatus, StatusVisual> checkin =
      <CheckinStatus, StatusVisual>{
    CheckinStatus.submitting: StatusVisual(
      label: '提交中',
      tone: StatusTone.info,
      icon: Icons.sync,
      description: '正在等待服务端判定，请勿关闭页面',
    ),
    CheckinStatus.success: StatusVisual(
      label: '已签到',
      tone: StatusTone.success,
      icon: Icons.check_circle,
    ),
    CheckinStatus.pendingReview: StatusVisual(
      label: '待确认',
      tone: StatusTone.warning,
      icon: Icons.hourglass_top,
      description: '已记录，由发布者核实；不影响你先参加活动',
    ),
    CheckinStatus.rejected: StatusVisual(
      label: '未通过',
      tone: StatusTone.danger,
      icon: Icons.cancel,
    ),
    CheckinStatus.offlineQueued: StatusVisual(
      label: '待同步',
      tone: StatusTone.warning,
      icon: Icons.cloud_off_outlined,
      description: '已存在本机，联网后自动上传',
    ),
    CheckinStatus.unknown: StatusVisual(label: '未知', tone: StatusTone.neutral),
  };

  // ── 在岗抽查任务（方案 §6.2）────────────────────────────────────────

  static const Map<AttendanceTaskStatus, StatusVisual> attendanceTask =
      <AttendanceTaskStatus, StatusVisual>{
    AttendanceTaskStatus.pending: StatusVisual(
      label: '待确认',
      tone: StatusTone.warning,
      icon: Icons.touch_app_outlined,
      description: '请在响应截止前点一下确认',
    ),
    AttendanceTaskStatus.done: StatusVisual(
      label: '已完成',
      tone: StatusTone.success,
      icon: Icons.check_circle_outline,
    ),
    AttendanceTaskStatus.missed: StatusVisual(
      label: '已超时',
      tone: StatusTone.danger,
      icon: Icons.timer_off_outlined,
      // ⚠️ 这句说明很重要：方案 §4.8 要求明确"不自动扣减"，
      // 否则志愿者会以为自己被罚了时长。
      description: '未在窗口内响应。仅作现场管理参考，不自动扣减时长',
    ),
    AttendanceTaskStatus.excused: StatusVisual(
      label: '已豁免',
      tone: StatusTone.neutral,
      icon: Icons.remove_circle_outline,
      description: '该时段不计入考勤（活动取消或临时调整）',
    ),
    AttendanceTaskStatus.unknown: StatusVisual(
      label: '未知',
      tone: StatusTone.neutral,
    ),
  };

  // ── 考勤汇总（方案 §6.4.7，决策 D-7）────────────────────────────────

  static const Map<AttendanceSummary, StatusVisual> attendanceSummary =
      <AttendanceSummary, StatusVisual>{
    AttendanceSummary.full: StatusVisual(
      label: '全勤',
      tone: StatusTone.success,
      icon: Icons.verified_outlined,
      description: '所有抽查均按时响应',
    ),
    AttendanceSummary.partial: StatusVisual(
      label: '部分完成',
      tone: StatusTone.warning,
      icon: Icons.rule_outlined,
      description: '完成率达标（≥70%），但有超时记录',
    ),
    AttendanceSummary.insufficient: StatusVisual(
      label: '证据不足',
      tone: StatusTone.warning,
      icon: Icons.help_outline,
      description: '完成率不足或无已定案抽查；不定性为缺席',
    ),
    AttendanceSummary.absent: StatusVisual(
      label: '缺席',
      tone: StatusTone.danger,
      icon: Icons.person_off_outlined,
    ),
    AttendanceSummary.unknown: StatusVisual(label: '未知', tone: StatusTone.neutral),
  };

  // ── 同步状态（方案 §9）──────────────────────────────────────────────

  static const Map<SyncState, StatusVisual> sync = <SyncState, StatusVisual>{
    SyncState.pending: StatusVisual(
      label: '待同步',
      tone: StatusTone.warning,
      icon: Icons.cloud_queue,
    ),
    SyncState.syncing: StatusVisual(
      label: '同步中',
      tone: StatusTone.info,
      icon: Icons.cloud_sync_outlined,
    ),
    SyncState.synced: StatusVisual(
      label: '已同步',
      tone: StatusTone.success,
      icon: Icons.cloud_done_outlined,
    ),
    SyncState.failed: StatusVisual(
      label: '同步失败',
      tone: StatusTone.danger,
      icon: Icons.cloud_off,
      description: '数据仍在本机，不会丢失；可手动重试',
    ),
  };

  // ── 便捷查询（未知一律退回对应的 unknown 项）────────────────────────

  static StatusVisual ofActivity(ActivityStatus s) =>
      activity[s] ?? activity[ActivityStatus.unknown]!;

  static StatusVisual ofSignup(SignupStatus s) =>
      signup[s] ?? signup[SignupStatus.unknown]!;

  static StatusVisual ofParticipantCheckin(ParticipantCheckinStatus s) =>
      participantCheckin[s] ?? participantCheckin[ParticipantCheckinStatus.unknown]!;

  static StatusVisual ofCheckin(CheckinStatus s) =>
      checkin[s] ?? checkin[CheckinStatus.unknown]!;

  static StatusVisual ofAttendanceTask(AttendanceTaskStatus s) =>
      attendanceTask[s] ?? attendanceTask[AttendanceTaskStatus.unknown]!;

  static StatusVisual ofAttendanceSummary(AttendanceSummary s) =>
      attendanceSummary[s] ?? attendanceSummary[AttendanceSummary.unknown]!;

  static StatusVisual ofSync(SyncState s) => sync[s] ?? sync[SyncState.pending]!;
}
