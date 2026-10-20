/**
 * 把筛选条件与 URL 查询串双向同步。
 *
 * ## 为什么要单独抽出来
 *
 * "筛选状态 ↔ URL" 的同步看着简单，但实际有四个容易出错的点：
 *
 *   1. **回环**：读 URL → 改本地 → 写回 URL → 又触发读 URL，
 *      如果不做判断会无限循环（实测会卡死页面）；
 *   2. **默认值**：默认条件不应写进 URL，否则分享出去的链接
 *      又长又难读（`?page=1&size=20&sortBy=startTime&sortDesc=true`
 *      全是废话）；
 *   3. **类型**：URL 里全是字符串，页码要转数字，布尔要转真值；
 *   4. **替换而非压栈**：见 router/index.js 的说明。
 *
 * 这四点各写一遍必然出错，所以集中在这里，并配单测。
 */

import { computed, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { PAGING } from '@contract/constants.js';

/** 默认条件。与它们相同的值不会被写进 URL。 */
export const DEFAULT_QUERY = Object.freeze({
  keyword: '',
  organizer: '',
  status: [],          // 多选
  startFrom: '',
  startTo: '',
  sortBy: 'startTime',
  sortDesc: true,
  page: 1,
  size: PAGING.defaultSize,
});

/** URL 查询串 → 筛选条件对象。 */
export function parseQuery(query) {
  const out = { ...DEFAULT_QUERY };
  if (query.keyword) {
    out.keyword = String(query.keyword);
  }
  if (query.organizer) {
    out.organizer = String(query.organizer);
  }
  if (query.status) {
    out.status = String(query.status)
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
  }
  if (query.startFrom) {
    out.startFrom = String(query.startFrom);
  }
  if (query.startTo) {
    out.startTo = String(query.startTo);
  }
  if (query.sortBy) {
    out.sortBy = String(query.sortBy);
  }
  if (query.sortDesc !== undefined) {
    out.sortDesc = String(query.sortDesc) !== 'false';
  }
  const page = Number.parseInt(query.page ?? '', 10);
  if (Number.isFinite(page) && page > 0) {
    out.page = page;
  }
  const size = Number.parseInt(query.size ?? '', 10);
  if (Number.isFinite(size) && size > 0) {
    out.size = Math.min(PAGING.maxSize, size);
  }
  return out;
}

/**
 * 筛选条件 → URL 查询串。
 *
 * **只写非默认值** —— 这是让分享链接保持简短的关键。
 * 数组序列化成逗号分隔（与服务端契约一致）。
 */
export function toQuery(state) {
  const q = {};
  if (state.keyword) {
    q.keyword = state.keyword;
  }
  if (state.organizer) {
    q.organizer = state.organizer;
  }
  if (state.status && state.status.length > 0) {
    q.status = [...state.status].sort().join(',');
  }
  if (state.startFrom) {
    q.startFrom = state.startFrom;
  }
  if (state.startTo) {
    q.startTo = state.startTo;
  }
  if (state.sortBy !== DEFAULT_QUERY.sortBy) {
    q.sortBy = state.sortBy;
  }
  if (state.sortDesc !== DEFAULT_QUERY.sortDesc) {
    q.sortDesc = String(state.sortDesc);
  }
  if (state.page !== DEFAULT_QUERY.page) {
    q.page = String(state.page);
  }
  if (state.size !== DEFAULT_QUERY.size) {
    q.size = String(state.size);
  }
  return q;
}

/** 两个条件对象是否等价（用于避免回环写回）。 */
export function sameQuery(a, b) {
  return JSON.stringify(toQuery(a)) === JSON.stringify(toQuery(b));
}

/**
 * 使用与 URL 同步的筛选条件。
 *
 * @returns {{filters: import('vue').Ref, route: object, router: object}}
 */
export function useActivityQuery() {
  const route = useRoute();
  const router = useRouter();

  // 本地状态是**唯一真值**，URL 是它的持久化形式。
  const filters = ref(parseQuery(route.query));

  // 用户用浏览器前进/后退时，URL 变了但本地状态没变 —— 需要同步回来。
  watch(
    () => route.query,
    (q) => {
      const next = parseQuery(q);
      // ⚠️ 这个判断就是防回环的关键：只有当 URL 真的与本地状态
      // 不同才更新，否则我们自己写 URL 的动作又会触发这里。
      if (!sameQuery(next, filters.value)) {
        filters.value = next;
      }
    },
  );

  // 本地状态变化 → 写回 URL。
  watch(
    filters,
    (state) => {
      const next = toQuery(state);
      if (JSON.stringify(next) === JSON.stringify(route.query)) {
        return;
      }
      // `replace` 而非 `push`：见 router/index.js 的说明。
      router.replace({ query: next });
    },
    { deep: true },
  );

  /** 改筛选条件时**回到第 1 页**（否则会停在一个空页上）。 */
  function update(patch, { resetPage = true } = {}) {
    filters.value = {
      ...filters.value,
      ...patch,
      ...(resetPage ? { page: 1 } : {}),
    };
  }

  /** 重置为默认条件。 */
  function reset() {
    filters.value = { ...DEFAULT_QUERY, status: [] };
  }

  /** 当前是否有任何筛选（用于决定要不要显示"清除筛选"）。 */
  const hasActiveFilters = computed(() => {
    const q = toQuery(filters.value);
    // 分页与排序不算"筛选" —— 清除筛选不该把页码也重置，
    // 那会让用户以为点了没反应。
    delete q.page;
    delete q.size;
    delete q.sortBy;
    delete q.sortDesc;
    return Object.keys(q).length > 0;
  });

  return { filters, update, reset, hasActiveFilters };
}
