<script setup>
/**
 * 状态徽标。
 *
 * ## 三条硬规则
 *
 * 1. **颜色不单独承载含义**：每个徽标都带图标 + 文字。
 *    只看颜色的状态对色盲用户等于没有信息。
 *
 * 2. **色调只有四档**（neutral / info / success / warning / danger），
 *    不用自定义色。多一档就会有人开始挑"这个该用哪个"，
 *    然后同一种状态在两个页面用不同颜色。
 *
 * 3. **不显示未知状态为"错误"**：服务端新增状态时，
 *    前端退化显示为中性色 + 原文，而不是红色 ——
 *    我们没有资格把不认识的东西判为异常。
 */

import { computed } from 'vue';
import { visualOf } from '../domain/visuals.js';

const props = defineProps({
  /** 展示信息对象：`{ label, tone, icon, description }` */
  visual: { type: Object, default: null },
  /** 或者直接给状态字符串 + 映射表 */
  status: { type: String, default: '' },
  map: { type: Object, default: null },
  /** 尺寸：sm 用于列表项，md 用于详情 */
  size: { type: String, default: 'sm' },
  /** 是否显示说明文字（详情页用 tooltip 承载） */
  title: { type: String, default: '' },
});

const info = computed(() => {
  if (props.visual) {
    return props.visual;
  }
  if (props.map) {
    return visualOf(props.map, props.status, props.status || '未知');
  }
  return { label: props.status || '未知', tone: 'neutral', icon: 'question' };
});

/**
 * 图标。
 *
 * 全部用同一套线性图标、同样的 1.5px 描边（与 13–14px 文字匹配），
 * 且只用 `currentColor` —— 不维护多套资源。
 */
const ICONS = {
  check: 'M4 12.5 9 17.5 20 6.5',
  x: 'M6 6l12 12M18 6 6 18',
  clock: 'M12 7v5l3 2M12 21a9 9 0 1 1 0-18 9 9 0 0 1 0 18Z',
  alert: 'M12 8v5M12 16.5h.01M10.3 3.9 2.8 17a2 2 0 0 0 1.7 3h15a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z',
  ban: 'M12 21a9 9 0 1 1 0-18 9 9 0 0 1 0 18ZM5.6 5.6l12.8 12.8',
  play: 'M8 5.5v13l11-6.5-11-6.5Z',
  megaphone: 'M4 10v4a1 1 0 0 0 1 1h2l4 4V5L7 9H5a1 1 0 0 0-1 1Zm12-3a6 6 0 0 1 0 10',
  edit: 'M4 20h4L20 8l-4-4L4 16v4Z',
  minus: 'M6 12h12',
  question: 'M12 21a9 9 0 1 1 0-18 9 9 0 0 1 0 18ZM9.2 9.3a2.8 2.8 0 0 1 5.5.7c0 1.8-2.7 2.2-2.7 4M12 17h.01',
};

const iconPath = computed(() => ICONS[info.value.icon] ?? ICONS.question);
</script>

<template>
  <span
    class="chip"
    :class="[`chip--${info.tone}`, `chip--${size}`]"
    :title="title || info.description || undefined"
  >
    <svg
      class="chip__icon"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path :d="iconPath" />
    </svg>
    <span class="chip__label">{{ info.label }}</span>
  </span>
</template>

<style scoped>
.chip {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-1);
  /* 徽标是"短标签"，不该折行 —— 折行会让徽标变成一个小方块。 */
  white-space: nowrap;
  border-radius: var(--r-full);
  font-weight: var(--fw-medium);
  line-height: 1;
  /* 徽标文字不参与选中：拖选一段文字时把徽标也带进去很烦。 */
  user-select: none;
}

.chip--sm {
  padding: 3px var(--sp-2) 3px 6px;
  font-size: var(--fs-micro);
}

.chip--md {
  padding: var(--sp-1) var(--sp-3) var(--sp-1) var(--sp-2);
  font-size: var(--fs-caption);
}

.chip__icon {
  width: 1em;
  height: 1em;
  flex-shrink: 0;
  /* 图标与文字在视觉上居中对齐（几何居中往往偏上）。 */
  margin-top: -0.5px;
}

/* ── 色调 ───────────────────────────────────────────────────────────
   每一档都是"浅底 + 深字"：浅底让徽标在地图般的列表里能被扫到，
   深字保证对比度。不用纯色块 + 白字 —— 那在浅色页面上太重。
   ──────────────────────────────────────────────────────────────────── */

.chip--neutral {
  background: var(--c-info-soft);
  color: var(--c-text-secondary);
}

.chip--info {
  background: var(--c-primary-soft);
  color: var(--c-primary-active);
}

.chip--success {
  background: var(--c-success-soft);
  color: var(--c-success);
}

.chip--warning {
  background: var(--c-warning-soft);
  color: var(--c-warning);
}

.chip--danger {
  background: var(--c-danger-soft);
  color: var(--c-danger);
}
</style>
