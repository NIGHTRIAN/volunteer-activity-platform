<script setup>
/**
 * 活动列表项。
 *
 * 结构按方案 §7.2 的示意图：
 *
 *   ┌────────────────────────────────────────────────────┐
 *   │ 社区图书馆整理志愿服务            [published]      │
 *   │ 校青年志愿者协会 · 4.0 小时                        │
 *   │ 2025-03-01 09:00 ~ 13:00                           │
 *   │ 整理馆藏图书并协助读者检索…                        │
 *   │ [图书整理] [校内]                  ▼ 查看详情  ☆   │
 *   └────────────────────────────────────────────────────┘
 *
 * ## 几个刻意的决定
 *
 * 1. **整卡可点**，而不是只有"查看详情"可点。列表项的点击目标越大越好，
 *    但那会带来一个无障碍问题：卡片里有收藏按钮，整卡可点会让
 *    "点收藏结果打开了详情"。做法是卡片用 `role="button"` + 键盘可达，
 *    收藏按钮 `@click.stop` 并保持独立的 Tab 焦点。
 *
 * 2. **收藏按钮不改变卡片高度**。它用绝对定位放在右下角，
 *    否则有无收藏的卡片高度会差几像素，列表看起来歪斜。
 *
 * 3. **时间用 `formatRange`**，同一天时合并日期 —— 重复的日期
 *    每天都在浪费注意力。
 */

import { computed } from 'vue';
import StatusChip from './StatusChip.vue';
import { ACTIVITY_VISUALS } from '../domain/visuals.js';
import {
  formatDuration,
  formatRange,
  formatRelative,
  toPlainSummary,
} from '../domain/format.js';

const props = defineProps({
  activity: { type: Object, required: true },
  favorite: { type: Boolean, default: false },
});

const emit = defineEmits(['open', 'toggle-favorite']);

const timeText = computed(() =>
  formatRange(props.activity.startTime, props.activity.endTime),
);

const durationText = computed(() => formatDuration(props.activity.durationHours));

const summaryText = computed(() => toPlainSummary(props.activity.summary, 96));

/**
 * 相对时间提示。
 *
 * 只在"进行中"与"即将开始（24 小时内）"时显示 ——
 * 这两个时刻读者最关心"现在能不能参与"。
 * 其余情况不显示，避免每一行都挂一个相对时间造成噪声。
 */
const relativeHint = computed(() => {
  const a = props.activity;
  if (a.status === 'ongoing') {
    return '正在进行';
  }
  if (a.status === 'published') {
    const start = new Date(a.startTime).getTime();
    const diffH = (start - Date.now()) / 3600_000;
    if (diffH > 0 && diffH <= 24) {
      return formatRelative(a.startTime);
    }
  }
  return '';
});

/** 徽标用的展示信息。 */
const statusVisual = computed(() => ACTIVITY_VISUALS[props.activity.status] ?? null);
</script>

<template>
  <article class="card" :class="{ 'card--cancelled': activity.status === 'cancelled' }">
    <!--
      主点击区。用 <button> 而不是 <div @click>：
      浏览器原生的键盘可达性（Enter/Space）、焦点语义、
      屏幕阅读器识别全都免费得到，而自己实现总要漏点什么。
    -->
    <button class="card__main" type="button" @click="emit('open', activity)">
      <div class="card__head">
        <h3 class="card__title">{{ activity.title }}</h3>
        <StatusChip :visual="statusVisual" :status="activity.status" size="sm" />
      </div>

      <p class="card__org">
        <span>{{ activity.organizer }}</span>
        <template v-if="durationText">
          <span class="card__dot" aria-hidden="true">·</span>
          <span class="tnum">{{ durationText }}</span>
        </template>
        <template v-if="relativeHint">
          <span class="card__dot" aria-hidden="true">·</span>
          <span class="card__hint">{{ relativeHint }}</span>
        </template>
      </p>

      <p class="card__time tnum">
        <svg
          class="card__icon"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M12 7v5l3 2M12 21a9 9 0 1 1 0-18 9 9 0 0 1 0 18Z" />
        </svg>
        {{ timeText }}
      </p>

      <p v-if="activity.location" class="card__place">
        <svg
          class="card__icon"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M12 21s-6-5.1-6-9a6 6 0 1 1 12 0c0 3.9-6 9-6 9Z" />
          <circle cx="12" cy="12" r="2.2" />
        </svg>
        {{ activity.location }}
      </p>

      <p v-if="summaryText" class="card__summary">{{ summaryText }}</p>

      <div v-if="activity.tags?.length" class="card__tags">
        <span v-for="t in activity.tags" :key="t" class="card__tag">{{ t }}</span>
      </div>

      <!-- 展开提示：方案 §7.2 的"▼ 查看详情"。
           用文字而不是纯箭头 —— 纯箭头读者不知道点了会发生什么。 -->
      <span class="card__disclosure">
        查看详情
        <svg
          class="card__chevron"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="m6 9 6 6 6-6" />
        </svg>
      </span>
    </button>

    <!--
      收藏按钮独立于主点击区。
      `@click.stop` 阻止冒泡，否则点收藏会同时打开详情。
    -->
    <button
      class="card__fav"
      type="button"
      :aria-pressed="favorite"
      :title="favorite ? '取消收藏（仅保存在本机浏览器）' : '收藏（仅保存在本机浏览器）'"
      @click.stop="emit('toggle-favorite', activity)"
    >
      <span class="sr-only">{{ favorite ? '取消收藏' : '收藏' }}</span>
      <svg
        class="card__fav-icon"
        :class="{ 'is-on': favorite }"
        viewBox="0 0 24 24"
        :fill="favorite ? 'currentColor' : 'none'"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path d="m12 3.6 2.6 5.3 5.9.9-4.3 4.1 1 5.8-5.2-2.7-5.2 2.7 1-5.8L3.5 9.8l5.9-.9L12 3.6Z" />
      </svg>
    </button>
  </article>
</template>

<style scoped>
.card {
  position: relative;
  display: flex;
  background: var(--c-surface);
  border-radius: var(--r-lg);
  /*
    阴影表达"浮起"，边框表达"结构"。这里两者都不要多余：
    用一层很浅的分层阴影即可（better-ui 第 3 条）。
    不加 border —— 列表里每张卡都画边框会形成网格噪声。
  */
  box-shadow: var(--shadow-sm);
  transition-property: box-shadow, transform;
  transition-duration: var(--dur-fast);
  transition-timing-function: var(--ease-out);
}

.card:hover {
  box-shadow: var(--shadow-md);
}

/* 已取消的活动降低视觉权重，但仍完全可读 ——
   读者需要知道"有这个活动但取消了"，而不是看不到。 */
.card--cancelled {
  background: var(--c-surface-sunken);
}

.card--cancelled .card__title {
  color: var(--c-text-secondary);
}

/* ── 主点击区 ─────────────────────────────────────────────────────── */

.card__main {
  flex: 1;
  display: block;
  /* 按钮重置：去掉浏览器默认外观，但保留语义。 */
  appearance: none;
  border: 0;
  background: none;
  text-align: start;
  font: inherit;
  color: inherit;
  cursor: pointer;
  /* 内边距给足，让内容不贴边；右侧留给收藏按钮。 */
  padding: var(--sp-4);
  padding-inline-end: 52px;
  border-radius: var(--r-lg);
  /* 组内间距：元数据行之间 8px，与描述之间 12px。 */
  display: flex;
  flex-direction: column;
  gap: var(--gap-intra);
}

.card__main:focus-visible {
  outline: 2px solid var(--c-primary);
  outline-offset: -2px;
}

.card__head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--sp-3);
}

.card__title {
  font-size: var(--fs-title-sm);
  font-weight: var(--fw-semibold);
  line-height: var(--lh-snug);
  color: var(--c-text-primary);
  /* 长标题最多两行，避免一条活动把整屏占掉。 */
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.card__org,
.card__time,
.card__place {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--sp-1);
  font-size: var(--fs-caption);
  color: var(--c-text-tertiary);
  line-height: var(--lh-snug);
}

.card__icon {
  width: 14px;
  height: 14px;
  flex-shrink: 0;
  /* 图标与 13px 文字视觉对齐。 */
  margin-top: -1px;
}

.card__dot {
  color: var(--c-border-strong);
}

/* 时长用次要色而不是三级色：它是读者判断"值不值得去"的关键信息。 */
.card__org > span:first-child {
  color: var(--c-text-secondary);
}

.card__hint {
  color: var(--c-primary);
  font-weight: var(--fw-medium);
}

.card__summary {
  font-size: var(--fs-body-sm);
  color: var(--c-text-secondary);
  line-height: var(--lh-snug);
  /* 简介最多两行。 */
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.card__tags {
  display: flex;
  flex-wrap: wrap;
  gap: var(--sp-1);
  margin-top: var(--sp-1);
}

.card__tag {
  padding: 2px var(--sp-2);
  border-radius: var(--r-xs);
  background: var(--c-surface-sunken);
  color: var(--c-text-tertiary);
  font-size: var(--fs-micro);
  line-height: 1.6;
  white-space: nowrap;
}

.card__disclosure {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-1);
  margin-top: var(--sp-1);
  font-size: var(--fs-caption);
  color: var(--c-primary);
  font-weight: var(--fw-medium);
}

.card__chevron {
  width: 14px;
  height: 14px;
  transition: transform var(--dur-fast) var(--ease-out);
}

.card__main:hover .card__chevron {
  transform: translateY(2px);
}

/* ── 收藏按钮 ─────────────────────────────────────────────────────── */

.card__fav {
  position: absolute;
  inset-block-start: var(--sp-3);
  inset-inline-end: var(--sp-3);
  appearance: none;
  border: 0;
  background: none;
  cursor: pointer;
  /* 触摸目标 44×44，但视觉只有 20px 图标 —— 用 padding 撑开命中区。 */
  width: 44px;
  height: 44px;
  display: grid;
  place-items: center;
  border-radius: var(--r-full);
  color: var(--c-text-disabled);
  transition-property: color, background-color;
  transition-duration: var(--dur-fast);
  transition-timing-function: var(--ease-out);
}

.card__fav:hover {
  color: var(--c-warning);
  background: var(--c-surface-sunken);
}

.card__fav-icon {
  width: 20px;
  height: 20px;
}

.card__fav-icon.is-on {
  color: var(--c-warning);
}

.card__fav:focus-visible {
  outline: 2px solid var(--c-primary);
  outline-offset: -4px;
}
</style>
