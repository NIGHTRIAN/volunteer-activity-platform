/**
 * 活动状态的筛选选项。
 *
 * ## 为什么这里**不包含草稿**
 *
 * 方案 §1.4：Web 浏览端公开只读、没有账号体系。
 * 草稿是发布者尚未发布的内部数据，对公开读者不存在。
 * 把它放进筛选项会造成两个问题：
 *   1. 读者会勾选它，然后发现永远没有结果（困惑）；
 *   2. 暗示"平台里有看不到的东西"（不必要的信息泄露）。
 *
 * ## 顺序按读者关心的程度，不按状态机的顺序
 *
 * 读者最想知道"现在能参加的"，所以进行中/报名中在前。
 */

import { ACTIVITY_STATUS } from '@contract/constants.js';

export const ACTIVITY_STATUS_OPTIONS = Object.freeze([
  { value: ACTIVITY_STATUS.ONGOING, label: '进行中' },
  { value: ACTIVITY_STATUS.PUBLISHED, label: '报名中' },
  { value: ACTIVITY_STATUS.FINISHED, label: '已结束' },
  { value: ACTIVITY_STATUS.CANCELLED, label: '已取消' },
]);

/** 便捷映射：状态值 → 中文名。 */
export const ACTIVITY_STATUS_LABELS = Object.freeze(
  Object.fromEntries(ACTIVITY_STATUS_OPTIONS.map((o) => [o.value, o.label])),
);

/**
 * 默认勾选的状态。
 *
 * 默认**全选**（等价于不筛状态），让读者第一眼看到全部。
 * 如果把"已结束"默认排除，读者会以为平台里没有历史活动 ——
 * 而历史活动恰恰是判断"这个组织靠不靠谱"的依据。
 */
export const DEFAULT_STATUSES = Object.freeze([]);

export { ACTIVITY_STATUS };
