<script setup>
/**
 * 加载 / 空 / 错误 三种状态。
 *
 * ## 为什么放一个文件
 *
 * 这三个状态几乎总是一起出现，而且**最容易被做漏**：
 * 开发者只写"有数据"的分支，加载中是白屏、空列表是白屏、
 * 出错还是白屏 —— 用户无法区分"在加载"和"坏了"。
 *
 * 方案 §7.4 明确要求：加载骨架屏、空态、错误态（含重试）。
 *
 * ## 空态必须"指向下一步"（better-writing 第 11 条）
 *
 * 只说"没有结果"是个死路。空态要说清"这里是什么"以及
 * "怎么让它有内容" —— 搜索无结果时还要给出**退出方式**（清除筛选），
 * 否则用户会以为平台里真的没有活动。
 */

const props = defineProps({
  /** skeleton | empty | error */
  variant: { type: String, required: true },
  /** 骨架屏行数 */
  rows: { type: Number, default: 3 },
  /** 空态标题 */
  title: { type: String, default: '这里还没有内容' },
  /** 空态说明（告诉用户这是什么、怎么填满它） */
  description: { type: String, default: '' },
  /** 错误信息 */
  errorMessage: { type: String, default: '' },
  /** 错误详情（traceId 之类，折叠显示） */
  errorDetail: { type: String, default: '' },
  /** 重试按钮文案 */
  retryText: { type: String, default: '重试' },
  /** 主操作（空态用） */
  actionText: { type: String, default: '' },
});

const emit = defineEmits(['retry', 'action']);
</script>

<template>
  <!-- ── 骨架屏 ─────────────────────────────────────────────────────
       骨架屏的高度与真实卡片接近，避免数据到达时页面跳动。
       ─────────────────────────────────────────────────────────────── -->
  <div v-if="variant === 'skeleton'" class="skeleton" aria-hidden="true">
    <div v-for="i in rows" :key="i" class="skeleton__card">
      <div class="skeleton__line skeleton__line--title"></div>
      <div class="skeleton__line skeleton__line--meta"></div>
      <div class="skeleton__line"></div>
      <div class="skeleton__line skeleton__line--short"></div>
    </div>
    <!-- 屏幕阅读器提示：骨架屏本身是装饰，但要告诉辅助技术"在加载"。 -->
    <p class="sr-only" role="status">正在加载活动列表</p>
  </div>

  <!-- ── 空态 ─────────────────────────────────────────────────────── -->
  <div v-else-if="variant === 'empty'" class="state" role="status">
    <svg
      class="state__icon"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M4 7.5A2.5 2.5 0 0 1 6.5 5h4l2 2.5h5A2.5 2.5 0 0 1 20 10v6.5A2.5 2.5 0 0 1 17.5 19h-11A2.5 2.5 0 0 1 4 16.5v-9Z" />
      <path d="M9 13.5h6" />
    </svg>
    <p class="state__title">{{ title }}</p>
    <p v-if="description" class="state__desc">{{ description }}</p>
    <el-button v-if="actionText" type="primary" class="state__action" @click="emit('action')">
      {{ actionText }}
    </el-button>
  </div>

  <!-- ── 错误态 ───────────────────────────────────────────────────── -->
  <div v-else-if="variant === 'error'" class="state state--error" role="alert">
    <svg
      class="state__icon state__icon--error"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M12 8.5v4.5M12 16.5h.01" />
      <circle cx="12" cy="12" r="9" />
    </svg>
    <!--
      错误信息说清"怎么了 + 怎么办"（better-writing 第 10 条）。
      不用"哎呀出错了"这类话：它既没说明原因，也没给出下一步。
    -->
    <p class="state__title">无法加载活动列表</p>
    <p class="state__desc">{{ errorMessage || '请检查网络连接后重试。' }}</p>
    <el-button type="primary" class="state__action" @click="emit('retry')">
      {{ retryText }}
    </el-button>
    <details v-if="errorDetail" class="state__detail">
      <summary>技术信息</summary>
      <p class="state__detail-body break-anywhere">{{ errorDetail }}</p>
    </details>
  </div>
</template>

<style scoped>
/* ── 骨架屏 ───────────────────────────────────────────────────────── */

.skeleton {
  display: flex;
  flex-direction: column;
  gap: var(--sp-3);
}

.skeleton__card {
  padding: var(--sp-4);
  background: var(--c-surface);
  border-radius: var(--r-lg);
  box-shadow: var(--shadow-sm);
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
}

.skeleton__line {
  height: 12px;
  border-radius: var(--r-xs);
  background: var(--c-surface-sunken);
  width: 100%;
}

.skeleton__line--title {
  height: 18px;
  width: 46%;
  margin-bottom: var(--sp-1);
}

.skeleton__line--meta {
  width: 30%;
}

.skeleton__line--short {
  width: 62%;
}

/* 呼吸动画让"在加载"这件事可见。系统开了减少动态效果时不做。 */
@media (prefers-reduced-motion: no-preference) {
  .skeleton__line {
    animation: skeleton-pulse 1.4s var(--ease-out) infinite;
  }

  /* 错开起始时间，避免整页同步闪烁（那样像在抽搐）。
     用 nth-child 而不是逐元素写 delay —— 行数是可变的。 */
  .skeleton__line:nth-child(2) {
    animation-delay: 0.12s;
  }

  .skeleton__line:nth-child(3) {
    animation-delay: 0.24s;
  }

  .skeleton__line:nth-child(4) {
    animation-delay: 0.36s;
  }
}

@keyframes skeleton-pulse {
  0%,
  100% {
    opacity: 1;
  }
  50% {
    opacity: 0.5;
  }
}

/* ── 空 / 错误态 ──────────────────────────────────────────────────── */

.state {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: var(--sp-2);
  padding: var(--sp-12) var(--sp-6);
  text-align: center;
  background: var(--c-surface);
  border-radius: var(--r-lg);
  box-shadow: var(--shadow-sm);
}

.state__icon {
  width: 40px;
  height: 40px;
  margin-bottom: var(--sp-2);
  /* 空态图标用三级色：它不该抢注意力。 */
  color: var(--c-text-disabled);
}

.state__icon--error {
  color: var(--c-danger);
}

.state__title {
  font-size: var(--fs-title-sm);
  font-weight: var(--fw-semibold);
  color: var(--c-text-primary);
}

.state__desc {
  font-size: var(--fs-body-sm);
  color: var(--c-text-tertiary);
  line-height: var(--lh-snug);
  max-width: 42ch;
}

.state__action {
  margin-top: var(--sp-3);
}

.state__detail {
  margin-top: var(--sp-4);
  font-size: var(--fs-caption);
  color: var(--c-text-tertiary);
  /* 技术细节默认折叠：普通读者不需要看，但排查问题时要有。 */
  text-align: start;
  max-width: 100%;
}

.state__detail summary {
  cursor: pointer;
  color: var(--c-text-tertiary);
}

.state__detail-body {
  margin-top: var(--sp-2);
  padding: var(--sp-2);
  border-radius: var(--r-sm);
  background: var(--c-surface-sunken);
  font-family: ui-monospace, 'SFMono-Regular', Menlo, Consolas, monospace;
  font-size: var(--fs-micro);
  line-height: var(--lh-snug);
}
</style>
