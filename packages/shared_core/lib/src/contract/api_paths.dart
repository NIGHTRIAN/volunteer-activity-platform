/// API 路径常量。
///
/// ## 来源：《网页开发方案》§6.2 / §6.4（权威）
///
/// 路径风格遵循该方案：
///   * 统一前缀 `/api`（由 `ApiConfig.baseUrl` 承担，因此这里写相对路径）；
///   * 动作后缀用 `:verb`（Google AIP 风格），例如 `:upsert` / `:transition` / `:confirm`；
///   * 在岗确认是**全局资源**路径 `/attendances/{taskId}:confirm`，
///     不挂在活动下 —— 确认动作的主体是"某次抽查任务"，不是"某活动"；
///   * 导出是 `GET .../export?format=csv` **直接下载**，不做"建任务→轮询"。
///
/// ## 为什么要集中在这里
///
/// 路径散落在各个调用点时会有一个典型故障：后端调整了一个路径，
/// 前端漏改一处，而那处往往正好是低频路径（例如"人工补录"），
/// 于是它只在现场真正需要时才报 404 —— 也就是最不该出问题的时候。
/// 集中成常量后，改路径是一次 grep 能查完的事。
library;

/// 认证与身份。
abstract final class AuthPaths {
  /// 管理端邀请码登录。
  static const String adminLogin = '/auth/admin/login';

  /// 管理端身份与令牌状态。
  static const String adminMe = '/auth/admin/me';

  /// 登录审计（时间/设备/IP）。
  static const String adminAudits = '/auth/admin/audits';

  /// 敏感导出审计（含完整联系方式的导出）。
  static const String exportAudits = '/auth/admin/export-audits';

  /// 志愿者绑定（学号 + 一次性邀请码）。
  static const String bind = '/auth/bind';

  /// 志愿者身份与授权状态。
  static const String me = '/auth/me';
}

/// 活动。
abstract final class ActivityPaths {
  /// 列表（筛选 + 分页 + 统计）。
  static const String list = '/activities';

  /// 批量上报（`batch[]`，幂等键 `externalId`）。
  ///
  /// ⚠️ 是 `:upsert` 动作后缀，不是 `POST /activities`。
  static const String upsert = '/activities:upsert';

  /// 详情。
  static String detail(String id) => '/activities/$id';

  /// 状态流转（`{from,to,reason}`）。
  static String transition(String id) => '/activities/$id:transition';

  /// 非关键字段的自由编辑（简介/详情/联系方式）。
  static String patch(String id) => '/activities/$id';

  /// 规则变更记录（管理者的争议证据）。
  static String changes(String id) => '/activities/$id/changes';

  /// 签到与在岗看板。
  static String board(String id) => '/activities/$id/board';

  /// 考勤汇总（**参考信息**，不产生扣减）。
  static String attendance(String id) => '/activities/$id/attendance';

  /// 导出（直接下载 CSV，带 UTF-8 BOM）。
  static String export(String id) => '/activities/$id/export';
}

/// 名单与邀请码。
abstract final class ParticipantPaths {
  /// 名单查询（支持 `filter`）。
  static String list(String activityId) => '/activities/$activityId/participants';

  /// 单个添加。
  static String add(String activityId) => '/activities/$activityId/participants';

  /// 批量导入（逐行返回结果）。
  ///
  /// ⚠️ 是 `:import` 动作后缀。
  static String import(String activityId) => '/activities/$activityId/participants:import';

  /// 软删（`pid` 为活动内唯一的学号/工号）。
  static String remove(String activityId, String pid) =>
      '/activities/$activityId/participants/$pid';

  /// 生成一次性邀请码（明文仅返回一次）。
  static String issueInviteCodes(String activityId) => '/activities/$activityId/invite-codes';

  /// 邀请码状态（**不返回明文**）。
  static String listInviteCodes(String activityId) => '/activities/$activityId/invite-codes';
}

/// 签到。
abstract final class CheckinPaths {
  /// 提交签到证据（**服务端判定**）。
  static String submit(String activityId) => '/activities/$activityId/checkins';

  /// 签到列表（管理端）。
  static String list(String activityId) => '/activities/$activityId/checkins';

  /// 本人签到记录。
  static String mine(String activityId) => '/activities/$activityId/checkins/mine';

  /// 人工复核（通过 / 驳回，驳回必填备注）。
  static String review(String checkinId) => '/checkins/$checkinId/review';

  /// 现场点名补录 / 发布者现场核实（**拒定位权限时的唯一降级路径**）。
  ///
  /// 本平台不启用动态签到码（决策 D-2），因此这条路径必须一直可用。
  static String manual(String activityId) => '/activities/$activityId/checkins/manual';
}

/// 在岗确认（防脱岗）。
abstract final class AttendancePaths {
  /// 在岗任务列表（App 前台轮询入口）。
  static String tasks(String activityId) => '/activities/$activityId/attendance/tasks';

  /// 确认在岗。**点一下就完成，零输入**。
  ///
  /// ⚠️ 全局资源路径，不挂在活动下。
  static String confirm(String taskId) => '/attendances/$taskId:confirm';

  /// 催办（记录用；本平台不启用推送，实际靠现场口头提醒）。
  static String remind(String taskId) => '/attendances/$taskId:remind';

  /// 人工补录。
  static String manual(String activityId) => '/activities/$activityId/attendance/manual';
}

/// 增量同步与导出。
abstract final class SyncPaths {
  /// 增量变更（游标 7 天幂等窗口）。
  static const String changes = '/changes';

  /// 按时间段批量导出活动汇总。
  static const String exportActivities = '/export/activities';
}
