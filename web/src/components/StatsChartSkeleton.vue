<script setup>
/**
 * 统计图的加载占位。
 *
 * ## 为什么要单独一个文件，而不是用 `template` 字符串
 *
 * 最初我在 `defineAsyncComponent` 里写 `loadingComponent: { template: '...' }`。
 * 那在**运行时编译**模式下能跑，但 Vite 的生产构建默认用
 * 「运行时 + 预编译」版本，**不含模板编译器** —— 字符串模板
 * 在构建后会在运行时报错（而且只在生产构建里报，开发时看不出来，
 * 因为 dev server 走的是完整版）。
 *
 * 所以：任何组件都用 `.vue` 文件定义，不要用模板字符串。
 *
 * ## 为什么高度要接近真图表
 *
 * 占位块的唯一职责是**避免布局跳动**。如果占位比真图表矮，
 * 图表到达时下面的内容会被推下去，用户正在读的东西会突然位移 ——
 * 那比空着更糟。这里按统计图的最小高度（4 行 × 38 + 24 ≈ 176px）取值。
 */
</script>

<template>
  <!-- 纯装饰：屏幕阅读器不需要念它（真实图表有自己的 aria-label）。 -->
  <div class="stats-skeleton" aria-hidden="true">
    <div class="stats-skeleton__title"></div>
    <div class="stats-skeleton__rows">
      <div v-for="i in 4" :key="i" class="stats-skeleton__row">
        <span class="stats-skeleton__label"></span>
        <span class="stats-skeleton__bar" :style="{ width: `${62 - i * 12}%` }"></span>
      </div>
    </div>
  </div>
</template>

<style scoped>
.stats-skeleton {
  display: flex;
  flex-direction: column;
  gap: var(--sp-3);
  padding: var(--sp-4);
  background: var(--c-surface);
  border-radius: var(--r-lg);
  box-shadow: var(--shadow-sm);
  min-height: 220px;
}

.stats-skeleton__title {
  height: 12px;
  width: 30%;
  border-radius: var(--r-xs);
  background: var(--c-surface-sunken);
}

.stats-skeleton__rows {
  display: flex;
  flex-direction: column;
  gap: var(--sp-3);
}

.stats-skeleton__row {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
}

.stats-skeleton__label {
  width: 44px;
  height: 12px;
  border-radius: var(--r-xs);
  background: var(--c-surface-sunken);
  flex-shrink: 0;
}

.stats-skeleton__bar {
  height: 14px;
  border-radius: var(--r-xs);
  background: var(--c-surface-sunken);
}

@media (prefers-reduced-motion: no-preference) {
  .stats-skeleton__bar,
  .stats-skeleton__label,
  .stats-skeleton__title {
    animation: stats-skeleton-pulse 1.4s var(--ease-out) infinite;
  }
}

@keyframes stats-skeleton-pulse {
  0%,
  100% {
    opacity: 1;
  }
  50% {
    opacity: 0.55;
  }
}
</style>
