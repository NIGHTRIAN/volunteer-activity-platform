<script setup>
/**
 * 活动详情独立页面（分享链接的落地页）。
 *
 * ## 为什么详情既在抽屉里、又有独立页面
 *
 *   * 抽屉：列表 → 详情 → 返回，保留筛选与滚动位置，适合浏览；
 *   * 独立页：`/#/activity/1001` 可以直接分享（方案 §7.3），
 *     收到链接的人可能从没见过列表。
 *
 * 两者共用同一个展示组件（`ActivityDetailDrawer` 里的字段渲染逻辑
 * 通过 `detailFields.js` 共享），但**不共用同一份容器** ——
 * 抽屉与页面的滚动、宽度、收起方式都不同，硬套一个容器
 * 会让两边都别扭。
 *
 * ## 直接打开链接时要处理的三件事
 *
 * 1. 活动可能**不存在**（链接过期、数据已过留存期）→ 要有明确说明；
 * 2. 活动可能是**草稿**（服务端对非发布者返回"不存在"）→ 同上；
 * 3. 页面需要**可返回列表**的入口 → 否则用户只能改地址栏。
 */

import { computed, onMounted, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';

import StatusChip from '../components/StatusChip.vue';
import StateBlock from '../components/StateBlock.vue';
import { fetchActivity } from '../api/client.js';
import { ACTIVITY_VISUALS } from '../domain/visuals.js';
import {
  DETAIL_GROUPS,
  groupHasContent,
  visibleFields,
} from '../domain/detailFields.js';
import { formatDuration, formatRange } from '../domain/format.js';
import { useFavorites } from '../composables/useFavorites.js';

const route = useRoute();
const router = useRouter();
const { isFavorite, toggle } = useFavorites();

const activity = ref(null);
const disclaimer = ref('');
const loading = ref(true);
const error = ref(null);

const statusVisual = computed(() =>
  activity.value ? ACTIVITY_VISUALS[activity.value.status] ?? null : null,
);

const groups = computed(() => {
  if (!activity.value) {
    return [];
  }
  return DETAIL_GROUPS.filter((g) => groupHasContent(g, activity.value)).map((g) => ({
    title: g.title,
    fields: visibleFields(g, activity.value).map((f) => ({
      key: f.key,
      label: f.label,
      text: f.value(activity.value),
      wide: Boolean(f.wide),
      multiline: Boolean(f.multiline),
      mono: Boolean(f.mono),
    })),
  }));
});

/** 说明文本按空行分段，用文本插值渲染（绝不 v-html，理由见详情抽屉）。 */
const paragraphs = computed(() =>
  String(activity.value?.description ?? '')
    .split(/\n{2,}/)
    .map((p) => p.trim())
    .filter(Boolean),
);

async function load() {
  loading.value = true;
  error.value = null;
  try {
    const data = await fetchActivity(route.params.id);
    activity.value = data.activity;
    disclaimer.value = data.disclaimer ?? '';
  } catch (e) {
    error.value = e;
    activity.value = null;
  } finally {
    loading.value = false;
  }
}

onMounted(load);

function goList() {
  router.push({ name: 'list' });
}

function onToggleFavorite() {
  if (!activity.value) {
    return;
  }
  const now = toggle(activity.value);
  ElMessage({
    message: now ? '已收藏（仅保存在本机浏览器）' : '已取消收藏',
    type: 'success',
    duration: 1800,
  });
}

function onExport() {
  window.open(
    `/api/activities/${encodeURIComponent(activity.value.id)}/export?kind=activities`,
    '_blank',
    'noopener',
  );
}

/** 活动不存在时的说明：区分"链接失效"与"服务出问题"。 */
const notFound = computed(() => error.value?.isNotFound === true);
</script>

<template>
  <div class="detail-page">
    <!-- 返回入口始终可见，即使加载失败 —— 否则用户会困在这一页。 -->
    <nav class="detail-page__nav no-print">
      <el-button text @click="goList">
        <svg
          class="detail-page__back"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="m14 6-6 6 6 6" />
        </svg>
        返回活动列表
      </el-button>
    </nav>

    <StateBlock v-if="loading" variant="skeleton" :rows="3" />

    <!--
      活动不存在 vs 加载失败：这两种情况的处置完全不同。
      不存在 → 说明链接可能已失效（数据有 7 天留存期，这是设计如此），
               并引导去列表；
      加载失败 → 可重试。
    -->
    <StateBlock
      v-else-if="error && notFound"
      variant="empty"
      title="这个活动找不到了"
      description="链接可能已失效，或活动的数据已超过留存期（活动结束后 7 天，按隐私设计销毁）。你可以回到列表看看其他活动。"
      action-text="浏览活动列表"
      @action="goList"
    />

    <StateBlock
      v-else-if="error"
      variant="error"
      :error-message="error.userMessage"
      @retry="load"
    />

    <article v-else-if="activity" class="sheet avoid-break">
      <header class="sheet__head">
        <StatusChip :visual="statusVisual" :status="activity.status" size="md" />
        <h1 class="sheet__title">{{ activity.title }}</h1>
        <p class="sheet__org">
          {{ activity.organizer }}
          <template v-if="activity.durationHours">
            <span class="sheet__dot" aria-hidden="true">·</span>
            <span class="tnum">{{ formatDuration(activity.durationHours) }}</span>
          </template>
        </p>
        <p class="sheet__time tnum">
          {{ formatRange(activity.startTime, activity.endTime) }}
        </p>
        <p v-if="disclaimer" class="sheet__disclaimer">{{ disclaimer }}</p>
      </header>

      <section
        v-for="g in groups"
        :key="g.title"
        class="sheet__group avoid-break"
        :aria-labelledby="`g-${g.title}`"
      >
        <h2 :id="`g-${g.title}`" class="sheet__group-title">{{ g.title }}</h2>
        <dl class="sheet__fields">
          <template v-for="f in g.fields" :key="f.key">
            <div class="sheet__field" :class="{ 'sheet__field--wide': f.wide }">
              <dt class="sheet__label">{{ f.label }}</dt>
              <dd class="sheet__value" :class="{ tnum: f.mono, 'break-anywhere': f.mono }">
                <template v-if="f.multiline">
                  <p v-for="(p, i) in paragraphs" :key="i" class="sheet__para">{{ p }}</p>
                </template>
                <template v-else>{{ f.text }}</template>
              </dd>
            </div>
          </template>
        </dl>
      </section>

      <footer class="sheet__foot no-print">
        <el-button @click="onToggleFavorite">
          {{ isFavorite(activity.id) ? '取消收藏' : '收藏' }}
        </el-button>
        <el-button @click="onExport">导出为 CSV</el-button>
        <el-button @click="goList">返回列表</el-button>
      </footer>
    </article>
  </div>
</template>

<style scoped>
.detail-page {
  display: flex;
  flex-direction: column;
  gap: var(--sp-4);
}

.detail-page__back {
  width: 16px;
  height: 16px;
  margin-inline-end: var(--sp-1);
}

.sheet {
  display: flex;
  flex-direction: column;
  gap: var(--sp-8);
  padding: var(--sp-8) var(--sp-6);
  background: var(--c-surface);
  border-radius: var(--r-lg);
  box-shadow: var(--shadow-sm);
}

.sheet__head {
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
  align-items: flex-start;
}

.sheet__title {
  font-size: var(--fs-display);
  font-weight: var(--fw-semibold);
  line-height: var(--lh-tight);
  color: var(--c-text-primary);
  max-width: 30ch;
}

.sheet__org {
  font-size: var(--fs-body);
  color: var(--c-text-secondary);
}

.sheet__dot {
  color: var(--c-border-strong);
  margin: 0 var(--sp-1);
}

.sheet__time {
  font-size: var(--fs-body);
  color: var(--c-text-primary);
}

.sheet__disclaimer {
  margin-top: var(--sp-2);
  padding: var(--sp-2) var(--sp-3);
  border-radius: var(--r-sm);
  background: var(--c-info-soft);
  font-size: var(--fs-caption);
  color: var(--c-text-secondary);
  line-height: var(--lh-snug);
  max-width: var(--measure);
}

.sheet__group {
  display: flex;
  flex-direction: column;
  gap: var(--sp-3);
}

.sheet__group-title {
  font-size: var(--fs-caption);
  font-weight: var(--fw-semibold);
  color: var(--c-text-tertiary);
  letter-spacing: 0.04em;
}

.sheet__fields {
  margin: 0;
  display: grid;
  grid-template-columns: 7.5em 1fr;
  gap: var(--sp-3);
}

.sheet__field {
  display: contents;
}

/*
  宽字段（长简介、活动说明）用单列排布，并且**清掉 grid 列定位带来的缩进**。
  详见 ActivityDetailDrawer.vue 里同一处的说明：只写
  `grid-column: 1 / -1` 会让正文起点仍在第二列，与标签对不齐。
*/
.sheet__field--wide {
  display: block;
  grid-column: 1 / -1;
  margin: 0;
  padding: 0;
  min-width: 0;
}

.sheet__label {
  margin: 0;
  font-size: var(--fs-body-sm);
  color: var(--c-text-tertiary);
  line-height: var(--lh-body);
}

.sheet__value {
  margin: 0;
  font-size: var(--fs-body);
  color: var(--c-text-primary);
  line-height: var(--lh-body);
  max-width: var(--measure);
}

.sheet__field--wide .sheet__label {
  margin-bottom: var(--sp-1);
  font-size: var(--fs-caption);
  font-weight: var(--fw-medium);
}

.sheet__para {
  margin: 0 0 var(--sp-3);
}

.sheet__para:last-child {
  margin-bottom: 0;
}

.sheet__foot {
  display: flex;
  flex-wrap: wrap;
  gap: var(--sp-2);
  padding-top: var(--sp-4);
  border-top: 1px solid var(--c-divider);
}

@media (max-width: 767px) {
  .sheet {
    padding: var(--sp-5) var(--sp-4);
    gap: var(--sp-6);
  }

  .sheet__title {
    font-size: var(--fs-title-lg);
  }

  .sheet__fields {
    grid-template-columns: 1fr;
    gap: var(--sp-2) 0;
  }

  .sheet__foot :deep(.el-button) {
    flex: 1 1 auto;
  }
}
</style>
