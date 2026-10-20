/**
 * API 处理器注册表。
 *
 * 拆成多个文件是为了让「认证与身份」「活动」「名单与考勤」「看板与导出」各自独立，
 * 与本方案的功能分区（§4 管理端、§5 用户端）保持一致，便于逐块对照验收用例。
 */

export {
  health,
  contractSelfDescription,
  authenticate,
  adminLogin,
  adminMe,
  adminAudits,
  exportAudits,
  volunteerBind,
  volunteerMe,
  devReset,
  devTimeTravelExample,
  // 导出它是为了让验收 A22（默认邀请码 1111，且可被 ADMIN_INVITE_CODE 覆盖）
  // 能直接断言"当前实际生效的码是什么"，而不必只测登录成功与否。
  adminInviteCode,
} from './api_auth.js';

export {
  listActivities,
  listOrganizers,
  getActivity,
  upsertActivities,
  transitionActivity,
  updateActivity,
  startActivity,
  finishActivity,
  cancelActivity,
  activityChanges,
} from './api_activities.js';

export {
  listParticipants,
  addParticipant,
  importParticipants,
  removeParticipant,
  issueInviteCodes,
  listInviteCodes,
  activityBoard,
} from './api_participants.js';

export {
  submitCheckin,
  listCheckins,
  myCheckin,
  reviewCheckin,
  manualCheckin,
  listAttendanceTasks,
  respondAttendance,
  remindAttendance,
  manualAttendance,
  attendanceSummaryReport,
  exportActivity,
  exportActivities,
  downloadExport,
} from './api_checkin.js';

export { changes } from './api_changes.js';
