/**
 * 折叠详情里展示字段的清单（**唯一来源**）。
 *
 * ## 为什么抽成数据而不是写在模板里
 *
 * 方案 §7.2 要求"详情展开展示全部详情字段"，而 §4.1 的字段字典
 * 有 20 多个字段、分「列表项 / 折叠详情」两类可见性。
 * 如果字段散落在模板里：
 *
 *   * 增删字段要改模板结构，容易漏；
 *   * "哪些字段对公开视图可见"这条规则会被埋进 HTML；
 *   * 无法对它写测试。
 *
 * 变成数据之后，「字段是否可见」「怎么格式化」「要不要脱敏」
 * 三个问题各自有明确答案，且可被测。
 *
 * ## 分组的重要性
 *
 * 20 多个字段平铺是一面墙。按"读者关心什么"分组：
 * 时间地点 → 参与要求 → 联系与说明 → 系统信息。
 * 阅读顺序遵循 better-layout 的"按重要性排序"。
 */

import { ACTIVITY_STATUS } from '@contract/constants.js';
import {
  formatDateTime,
  formatDuration,
  formatRange,
  maskContact,
  toPlainSummary,
} from './format.js';
import { activityVisual } from './visuals.js';

/**
 * 详情字段组。
 *
 * 每项：
 *   key    取值字段
 *   label  中文标签（与方案 §4.1 的中文名一致）
 *   format 值格式化函数
 *   hide   何时隐藏（返回 true 则不展示）
 *   wide   是否占满整行（长文本）
 *   mono   是否用等宽/表格数字（坐标这类）
 */
export const DETAIL_GROUPS = Object.freeze([
  {
    title: '时间与地点',
    fields: [
      {
        key: 'startTime',
        label: '活动时间',
        // 起止时间合成一条，比并列两行更好读。
        value: (a) => formatRange(a.startTime, a.endTime),
      },
      {
        key: 'durationHours',
        label: '志愿时长',
        value: (a) => formatDuration(a.durationHours),
      },
      {
        key: 'signupDeadline',
        label: '报名截止',
        value: (a) => formatDateTime(a.signupDeadline),
        hide: (a) => !a.signupDeadline,
      },
      {
        key: 'location',
        label: '活动地点',
        value: (a) => a.location,
        hide: (a) => !a.location,
      },
      {
        key: 'geo',
        label: '活动坐标',
        // ⚠️ 明确标注 WGS-84：地图上如果用的是 GCJ-02（国内地图偏移），
        // 同一串数字会偏几十到几百米。不写清楚，别人拿去用就会对不上。
        value: (a) =>
          a.geoLat != null && a.geoLng != null
            ? `${Number(a.geoLat).toFixed(6)}, ${Number(a.geoLng).toFixed(6)}（WGS-84）`
            : '',
        hide: (a) => a.geoLat == null || a.geoLng == null,
        mono: true,
      },
    ],
  },
  {
    title: '参与要求',
    fields: [
      {
        key: 'quota',
        label: '招募人数',
        value: (a) => (a.quota != null ? `${a.quota} 人` : '不限'),
      },
      {
        key: 'enrolled',
        label: '已报名人数',
        // 只读派生值（方案 §4.1 第 12 项：由名单派生）。
        value: (a) => `${a.enrolled ?? 0} 人`,
      },
      {
        key: 'checkinRadius',
        label: '签到范围',
        value: (a) => (a.checkinRadius != null ? `半径 ${a.checkinRadius} 米` : ''),
        hide: (a) => a.checkinRadius == null,
      },
      {
        key: 'checkinWindow',
        label: '签到时段',
        // 由服务端算好的派生值，前端不自己推算 ——
        // 两端各算一遍必然会在边界上出现分歧。
        value: (a) =>
          a.checkinOpensAt && a.checkinClosesAt
            ? `${formatDateTime(a.checkinOpensAt)} ~ ${formatDateTime(a.checkinClosesAt)}`
            : '',
        hide: (a) => !a.checkinOpensAt,
      },
    ],
  },
  {
    title: '说明与联系',
    fields: [
      {
        key: 'summary',
        label: '一句话简介',
        value: (a) => toPlainSummary(a.summary, 200),
        hide: (a) => !a.summary,
        wide: true,
      },
      {
        key: 'description',
        label: '活动说明',
        // 保留换行：说明里的分段是有意的（工作内容 / 注意事项）。
        value: (a) => String(a.description ?? '').trim(),
        hide: (a) => !a.description,
        wide: true,
        // 长文本要按段落渲染，见 ActivityDetailDrawer。
        multiline: true,
      },
      {
        key: 'contact',
        label: '联系方式',
        // ⚠️ 脱敏：公开只读页面不能出现完整手机号。
        value: (a) => maskContact(a.contact),
        hide: (a) => !a.contact,
      },
    ],
  },
  {
    title: '活动信息',
    fields: [
      {
        key: 'organizer',
        label: '组织部门',
        value: (a) => a.organizer,
      },
      {
        key: 'externalId',
        label: '活动编号',
        // 发布者的内部编号，用于与线下表格对照。
        value: (a) => a.externalId,
        mono: true,
      },
      {
        key: 'status',
        label: '当前状态',
        value: (a) => activityVisual(a.status).label,
      },
      {
        key: 'tags',
        label: '标签',
        value: (a) => (a.tags ?? []).join('、'),
        hide: (a) => !(a.tags ?? []).length,
      },
      {
        key: 'dataDestroyAt',
        label: '数据留存至',
        /*
          方案 §9.3 / §12.1-5：统一 7 天留存期（活动终态 + 7 天）。
          把"什么时候数据会被销毁"直接告诉读者，
          比藏在隐私政策里更符合"合理即可"的保密取向 ——
          而且到期前 48 小时要提醒导出，使用者需要知道这个时间点。
        */
        value: (a) => formatDateTime(a.dataDestroyAt),
        hide: (a) => !a.dataDestroyAt,
      },
    ],
  },
]);

/** 该活动的详情是否整体隐藏（草稿对公开视图不可见）。 */
export function isPubliclyVisible(activity) {
  return activity && activity.status !== ACTIVITY_STATUS.DRAFT;
}

/** 过滤出实际要显示的字段。 */
export function visibleFields(group, activity) {
  return group.fields.filter((f) => !(f.hide?.(activity) ?? false));
}

/** 该分组是否有任何可见字段（避免出现空标题）。 */
export function groupHasContent(group, activity) {
  return visibleFields(group, activity).length > 0;
}
