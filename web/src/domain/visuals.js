/**
 * 展示层：状态 → 文案与色调。
 *
 * ## 为什么集中在一个文件
 *
 * 同一个状态如果在列表页、详情页、筛选栏各写一次文案，
 * 迟早会出现三种说法。移动端阶段的教训更严重：服务端下发
 * `success`、客户端枚举期望 `checked_in`，结果**看板上所有
 * 已签到的人都显示成"未知"** —— 不报错，只是安静地显示错的东西。
 *
 * 因此：状态文案与色调只有这一处定义。
 *
 * ## 色调规则（重要）
 *
 * 颜色**不能单独承载含义** —— 色盲用户看不出红绿差异。
 * 所以每个状态都同时给出「图标 + 文案 + 色调」三者。
 *
 * 另外有一条业务规则必须守住：
 * **「证据不足」不是「缺席」。** 它不能渲染成危险色。
 * 方案 §13-A5 自己就承认抽查可能误判（"通知没到"会被记成"人不在"），
 * 把不确定的东西显示成红色的"缺席"，等于替系统给人定了性。
 * 因此 `insufficient` 用中性色、`absent` 才用危险色。
 */

import {
  ACTIVITY_STATUS,
  CHECKIN_STATUS,
  ATTENDANCE_TASK_STATUS,
  ATTENDANCE_SUMMARY,
  SIGNUP_STATUS,
  PARTICIPANT_CHECKIN_STATUS,
} from '@contract/constants.js';

/** 活动状态。 */
export const ACTIVITY_VISUALS = Object.freeze({
  [ACTIVITY_STATUS.DRAFT]: {
    label: '草稿',
    tone: 'neutral',
    icon: 'edit',
    // 草稿对读者没有意义（它还没发布），因此列表里根本不显示草稿；
    // 这里的文案只在管理端出现。
    description: '尚未发布，仅发布者可见',
  },
  [ACTIVITY_STATUS.PUBLISHED]: {
    label: '报名中',
    tone: 'info',
    icon: 'megaphone',
    description: '已发布，等待开始',
  },
  [ACTIVITY_STATUS.ONGOING]: {
    label: '进行中',
    tone: 'success',
    icon: 'play',
    description: '活动正在进行',
  },
  [ACTIVITY_STATUS.FINISHED]: {
    label: '已结束',
    tone: 'neutral',
    icon: 'check',
    description: '活动已结束',
  },
  [ACTIVITY_STATUS.CANCELLED]: {
    label: '已取消',
    tone: 'danger',
    icon: 'ban',
    description: '活动已取消',
  },
});

/**
 * 签到结果。
 *
 * ⚠️ 「待人工确认」用 warning 而不是 danger ——
 * 它表示"还不能下结论"，不是"做错了"。
 */
export const CHECKIN_VISUALS = Object.freeze({
  [CHECKIN_STATUS.SUCCESS]: {
    label: '已签到',
    tone: 'success',
    icon: 'check',
    description: '定位证据充分，已自动通过',
  },
  [CHECKIN_STATUS.PENDING_REVIEW]: {
    label: '待确认',
    tone: 'warning',
    icon: 'clock',
    description: '证据不足或存在疑点，等待发布者确认',
  },
  [CHECKIN_STATUS.REJECTED]: {
    label: '未通过',
    tone: 'danger',
    icon: 'x',
    description: '不在签到范围内或证据不成立',
  },
});

/** 名单行的签到状态（看板四态）。 */
export const PARTICIPANT_CHECKIN_VISUALS = Object.freeze({
  [PARTICIPANT_CHECKIN_STATUS.CHECKED_IN]: CHECKIN_VISUALS[CHECKIN_STATUS.SUCCESS],
  [PARTICIPANT_CHECKIN_STATUS.PENDING_REVIEW]: CHECKIN_VISUALS[CHECKIN_STATUS.PENDING_REVIEW],
  [PARTICIPANT_CHECKIN_STATUS.NONE]: {
    label: '尚未签到',
    tone: 'neutral',
    icon: 'minus',
    // 明确区分"没有记录"与"判定为未签到"。
    description: '还没有签到记录',
  },
});

/** 在岗抽查任务。 */
export const ATTENDANCE_TASK_VISUALS = Object.freeze({
  [ATTENDANCE_TASK_STATUS.PENDING]: {
    label: '待响应',
    tone: 'info',
    icon: 'clock',
    description: '已发出确认请求，等待响应',
  },
  [ATTENDANCE_TASK_STATUS.DONE]: {
    label: '已确认',
    tone: 'success',
    icon: 'check',
    description: '在岗已确认',
  },
  [ATTENDANCE_TASK_STATUS.MISSED]: {
    label: '未响应',
    tone: 'warning',
    icon: 'alert',
    /*
      用 warning 而不是 danger：方案 §13-A5 承认这个判定可能误伤
      （通知没送达也会被记成未响应）。把可疑的结果渲染成红色
      "缺席"，会让发布者据此做不该做的决定。
    */
    description: '超时未响应，可人工补录',
  },
  [ATTENDANCE_TASK_STATUS.EXCUSED]: {
    label: '已豁免',
    tone: 'neutral',
    icon: 'minus',
    // 豁免的记录**不计入分母**，这一点必须让人看得见。
    description: '已豁免，不计入完成率',
  },
});

/**
 * 考勤汇总等级。
 *
 * ⚠️ 这个映射里有本项目最重要的一条呈现规则：
 * **`insufficient`（证据不足）绝不能用 danger 色，也不能叫"缺席"。**
 */
export const ATTENDANCE_SUMMARY_VISUALS = Object.freeze({
  [ATTENDANCE_SUMMARY.FULL]: {
    label: '全勤',
    tone: 'success',
    icon: 'check',
    description: '全部抽查均已确认',
  },
  [ATTENDANCE_SUMMARY.PARTIAL]: {
    label: '部分完成',
    tone: 'warning',
    icon: 'alert',
    description: '有抽查未响应，完成率未达全勤',
  },
  [ATTENDANCE_SUMMARY.INSUFFICIENT]: {
    label: '证据不足',
    tone: 'neutral',
    icon: 'question',
    // 这句话本身就是给发布者看的免责说明。
    description: '抽查数据不足以判断，不作为缺席处理',
  },
  [ATTENDANCE_SUMMARY.ABSENT]: {
    label: '缺席',
    tone: 'danger',
    icon: 'x',
    description: '参与者在抽查时段内被确认不在场',
  },
});

/** 名单报名状态。 */
export const SIGNUP_VISUALS = Object.freeze({
  [SIGNUP_STATUS.REGISTERED]: { label: '在名单中', tone: 'success', icon: 'check' },
  [SIGNUP_STATUS.CANCELLED]: {
    label: '已移出',
    tone: 'neutral',
    icon: 'minus',
    description: '已从名单移出，历史记录保留',
  },
});

/**
 * 取状态展示信息。
 *
 * 未知值**不抛异常**：服务端将来可能新增状态，前端遇到不认识的
 * 值时应当退化显示而不是整页崩掉。这条在移动端阶段救过一次 ——
 * 服务端加了 `pending_review`，客户端没有对应分支，
 * 结果是整列显示成空白。
 */
export function visualOf(map, value, fallbackLabel = '未知') {
  return (
    map[value] ?? {
      label: fallbackLabel,
      tone: 'neutral',
      icon: 'question',
      description: null,
    }
  );
}

export function activityVisual(status) {
  return visualOf(ACTIVITY_VISUALS, status);
}

export function checkinVisual(status) {
  return visualOf(CHECKIN_VISUALS, status);
}

export function attendanceSummaryVisual(v) {
  return visualOf(ATTENDANCE_SUMMARY_VISUALS, v);
}
