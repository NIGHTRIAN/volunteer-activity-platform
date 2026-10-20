<script setup>
/**
 * 活动详情（抽屉）。
 *
 * ## 方案 §7.2 的两条硬要求
 *
 * 1. **`contact` 脱敏**（`138****0000`）
 * 2. **`description` 必须经白名单过滤，禁止直出未过滤 HTML**
 *
 * 第 2 条是这个文件里最值得说清楚的地方 —— 见下方 `safeParagraphs`。
 *
 * ## 为什么用抽屉而不是新页面
 *
 * 列表 → 详情 → 返回列表是高频动作。抽屉保留了列表的滚动位置与
 * 筛选状态（"返回"是关闭抽屉，不必重新查询），比跳转页面更省事。
 * 但**详情也有独立路由**（`/#/activity/:id`），因为方案 §7.3
 * 要求可分享链接 —— 直接打开链接时用独立页面承载。
 */

import { computed, ref, watch } from 'vue';
import StatusChip from './StatusChip.vue';
import { ACTIVITY_VISUALS } from '../domain/visuals.js';
import {
  DETAIL_GROUPS,
  groupHasContent,
  visibleFields,
} from '../domain/detailFields.js';
import { formatDateTime, formatRange } from '../domain/format.js';

const props = defineProps({
  modelValue: { type: Boolean, default: false },
  activity: { type: Object, default: null },
  favorite: { type: Boolean, default: false },
  /** 详情接口返回的免责声明（服务端下发，不在前端硬编码）。 */
  disclaimer: { type: String, default: '' },
  loading: { type: Boolean, default: false },
});

const emit = defineEmits(['update:modelValue', 'toggle-favorite', 'copy-link', 'export']);

const visible = computed({
  get: () => props.modelValue,
  set: (v) => emit('update:modelValue', v),
});

const statusVisual = computed(() =>
  props.activity ? ACTIVITY_VISUALS[props.activity.status] ?? null : null,
);

/** 只渲染有事内容的分组。 */
const groups = computed(() => {
  if (!props.activity) {
    return [];
  }
  return DETAIL_GROUPS.filter((g) => groupHasContent(g, props.activity)).map((g) => ({
    title: g.title,
    fields: visibleFields(g, props.activity).map((f) => ({
      key: f.key,
      label: f.label,
      text: f.value(props.activity),
      wide: Boolean(f.wide),
      multiline: Boolean(f.multiline),
      mono: Boolean(f.mono),
    })),
  }));
});

/**
 * ⚠️ 把 `description` 拆成纯文本段落。
 *
 * ## 为什么绝不使用 v-html
 *
 * 方案 §7.2 明确要求"**必须经白名单过滤，禁止直出未过滤 HTML**"。
 * 这条要求的背景很实际：活动说明由**管理端 App 的发布者**填写，
 * 而发布者是普通用户。如果直接 `v-html` 渲染，一个发布者就能在
 * 活动说明里写入 `<script>` 或 `<img onerror=...>`，
 * 从而在**所有浏览者的浏览器里执行任意脚本** —— 这类漏洞
 * （存储型 XSS）在公网只读页面上尤其危险，因为浏览者无需登录。
 *
 * ## 这里的做法：根本不让 HTML 进来
 *
 * 不去做"HTML 白名单过滤"，而是用 Vue 的文本插值，
 * 让 Vue 自己转义所有内容。这样：
 *   * `<script>` 会**原样显示成文字**，不会执行；
 *   * 不存在"白名单漏了一个标签"的风险；
 *   * 不需要引入 sanitizer 依赖（少一个依赖就少一份风险）。
 *
 * 代价是发布者无法用富文本排版。对"活动说明"这种场景，
 * 纯文本 + 换行分段完全够用，而这个代价换来的是**结构上不可能被 XSS**。
 *
 * 如果将来确实需要富文本，必须在**服务端**做白名单过滤后再下发，
 * 并在这里配 `v-html` + 明确的信任边界说明 —— 不要在前端做过滤，
 * 因为过滤代码本身也可能被绕过。
 */
const safeParagraphs = computed(() => {
  const raw = String(props.activity?.description ?? '');
  if (!raw.trim()) {
    return [];
  }
  return raw
    .split(/\n{2,}|\r\n\r\n/)
    .map((p) => p.trim())
    .filter(Boolean);
});

/** 复制分享链接。 */
const copied = ref(false);
async function copyLink() {
  const url = `${window.location.origin}${window.location.pathname}#/activity/${props.activity.id}`;
  try {
    await navigator.clipboard.writeText(url);
    copied.value = true;
    setTimeout(() => {
      copied.value = false;
    }, 2000);
  } catch {
    // 剪贴板 API 在非 HTTPS 或未授权时会失败。
    // 退化为让用户手工复制（用 prompt 展示完整链接）。
    window.prompt('复制下面的链接分享：', url);
  }
}

// 抽屉关闭时清掉"已复制"状态，否则下次打开会看到残留提示。
watch(visible, (v) => {
  if (!v) {
    copied.value = false;
  }
});
</script>

<template>
  <el-drawer
    v-model="visible"
    direction="rtl"
    size="min(560px, 100%)"
    :with-header="false"
    class="detail-drawer"
  >
    <div v-if="loading" class="detail__loading">正在加载活动详情…</div>

    <div v-else-if="activity" class="detail">
      <!-- ── 头部 ─────────────────────────────────────────────────── -->
      <header class="detail__head">
        <div class="detail__head-top">
          <StatusChip :visual="statusVisual" :status="activity.status" size="md" />
          <button
            class="detail__close"
            type="button"
            aria-label="关闭详情"
            @click="visible = false"
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
              aria-hidden="true"
            >
              <path d="M6 6l12 12M18 6 6 18" />
            </svg>
          </button>
        </div>

        <h2 class="detail__title">{{ activity.title }}</h2>

        <p class="detail__time tnum">
          {{ formatRange(activity.startTime, activity.endTime) }}
        </p>

        <!-- 免责声明：由服务端下发。放在头部而不是页脚，
             因为读者可能只截屏这一块。 -->
        <p v-if="disclaimer" class="detail__disclaimer">{{ disclaimer }}</p>
      </header>

      <!-- ── 字段分组 ─────────────────────────────────────────────── -->
      <div class="detail__body">
        <section
          v-for="g in groups"
          :key="g.title"
          class="detail__group"
          :aria-labelledby="`group-${g.title}`"
        >
          <h3 :id="`group-${g.title}`" class="detail__group-title">{{ g.title }}</h3>

          <dl class="detail__fields">
            <template v-for="f in g.fields" :key="f.key">
              <!--
                字段为空的项已在 visibleFields 里滤掉，
                所以这里不必再判断 —— 空行是详情页最常见的噪声来源。
              -->
              <div class="detail__field" :class="{ 'detail__field--wide': f.wide }">
                <dt class="detail__label">{{ f.label }}</dt>
                <dd class="detail__value" :class="{ tnum: f.mono, 'break-anywhere': f.mono }">
                  <!--
                    ⚠️ 长文本用段落渲染（见 safeParagraphs 的说明）。
                    这里用的是**文本插值**，不是 v-html ——
                    发布者写入的任何 HTML 都会被原样显示成文字，不会执行。
                  -->
                  <template v-if="f.multiline">
                    <p
                      v-for="(p, i) in safeParagraphs"
                      :key="i"
                      class="detail__para"
                    >
                      {{ p }}
                    </p>
                  </template>
                  <template v-else>{{ f.text }}</template>
                </dd>
              </div>
            </template>
          </dl>
        </section>
      </div>

      <!-- ── 底部操作 ─────────────────────────────────────────────── -->
      <footer class="detail__foot no-print">
        <el-button @click="emit('toggle-favorite', activity)">
          {{ favorite ? '取消收藏' : '收藏' }}
        </el-button>
        <el-button @click="copyLink">
          {{ copied ? '链接已复制' : '复制分享链接' }}
        </el-button>
        <el-button type="primary" @click="emit('export', activity)">
          导出为 CSV
        </el-button>
      </footer>
    </div>

    <div v-else class="detail__loading">没有可显示的活动</div>
  </el-drawer>
</template>

<style scoped>
.detail {
  display: flex;
  flex-direction: column;
  gap: var(--sp-6);
}

.detail__loading {
  padding: var(--sp-8) var(--sp-4);
  text-align: center;
  color: var(--c-text-tertiary);
  font-size: var(--fs-body-sm);
}

/* ── 头部 ─────────────────────────────────────────────────────────── */

.detail__head {
  display: flex;
  flex-direction: column;
  gap: var(--sp-3);
  padding: var(--sp-5) var(--sp-5) var(--sp-4);
  border-bottom: 1px solid var(--c-divider);
}

.detail__head-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-3);
}

.detail__close {
  appearance: none;
  border: 0;
  background: none;
  cursor: pointer;
  width: 40px;
  height: 40px;
  display: grid;
  place-items: center;
  border-radius: var(--r-full);
  color: var(--c-text-tertiary);
  transition-property: color, background-color;
  transition-duration: var(--dur-fast);
  transition-timing-function: var(--ease-out);
}

.detail__close:hover {
  color: var(--c-text-primary);
  background: var(--c-surface-sunken);
}

.detail__close svg {
  width: 20px;
  height: 20px;
}

.detail__title {
  font-size: var(--fs-title-lg);
  font-weight: var(--fw-semibold);
  line-height: var(--lh-tight);
  color: var(--c-text-primary);
}

.detail__time {
  font-size: var(--fs-body-sm);
  color: var(--c-text-secondary);
}

.detail__disclaimer {
  padding: var(--sp-2) var(--sp-3);
  border-radius: var(--r-sm);
  background: var(--c-info-soft);
  font-size: var(--fs-caption);
  color: var(--c-text-secondary);
  line-height: var(--lh-snug);
}

/* ── 字段 ─────────────────────────────────────────────────────────── */

.detail__body {
  display: flex;
  flex-direction: column;
  /* 分组之间 24px，明显大于组内的 8px —— 分组才读得出来。 */
  gap: var(--sp-6);
  padding: 0 var(--sp-5);
}

.detail__group {
  display: flex;
  flex-direction: column;
  gap: var(--sp-3);
}

.detail__group-title {
  font-size: var(--fs-caption);
  font-weight: var(--fw-semibold);
  color: var(--c-text-tertiary);
  /* 小号全大写标签需要一点正字距，否则字母挤在一起。
     中文没有大小写，这里靠字距拉开层次。 */
  letter-spacing: 0.04em;
}

.detail__fields {
  margin: 0;
  display: grid;
  /* 两列：标签窄、值宽。窄屏退化成单列。 */
  grid-template-columns: 6.5em 1fr;
  gap: var(--sp-3) var(--sp-3);
}

.detail__field {
  display: contents;
}

/*
  ⚠️ 长文本字段（简介、活动说明）的排版，实测踩过一次。

  `display: contents` 让 dt/dd 直接成为 grid 的子项，于是标签落在
  第一列、值落在第二列。但对**要占满整行**的长文本，最初我写成
  `display: block; grid-column: 1 / -1` —— 结果 `dd` 虽然跨了整行，
  它的**起点仍被放在第二列的位置**（因为父级两列网格的列定位还在），
  于是长说明文字整体向右缩进了 6.5em，与它上方的标签对不齐，
  左侧还空出一条没人用的白边。

  正确做法：宽字段显式用**单列**网格（`grid-column: 1 / -1` 配合
  重置 `padding`/`margin`），让标签与正文共享同一条左边线
  （better-layout 第 3 条：对齐到共同的边）。
*/
.detail__field--wide {
  display: block;
  grid-column: 1 / -1;
  /* 清掉 grid 列定位带来的隐式缩进。 */
  margin: 0;
  padding: 0;
  min-width: 0;
}

.detail__field--wide .detail__label {
  margin: 0 0 var(--sp-1);
}

.detail__field--wide .detail__value {
  /* 长文本不受网格列宽限制，但仍保留可读的宽度上限。 */
  max-width: var(--measure);
}

.detail__label {
  margin: 0;
  font-size: var(--fs-caption);
  color: var(--c-text-tertiary);
  line-height: var(--lh-snug);
}

.detail__value {
  margin: 0;
  font-size: var(--fs-body-sm);
  color: var(--c-text-primary);
  line-height: var(--lh-body);
  /* 长文本宽度上限（60–75 字符）。 */
  max-width: var(--measure);
}

.detail__para {
  margin: 0 0 var(--sp-2);
}

.detail__para:last-child {
  margin-bottom: 0;
}

/* ── 底部操作 ─────────────────────────────────────────────────────── */

.detail__foot {
  display: flex;
  flex-wrap: wrap;
  gap: var(--sp-2);
  padding: var(--sp-4) var(--sp-5);
  border-top: 1px solid var(--c-divider);
  /* 操作固定在底部，滚长说明时也能随时点到。 */
  position: sticky;
  bottom: 0;
  background: var(--c-surface);
}

@media (max-width: 480px) {
  .detail__fields {
    grid-template-columns: 1fr;
    gap: var(--sp-2);
  }

  .detail__label {
    /* 单列时标签在上、值在下，需要一点视觉区分。 */
    font-weight: var(--fw-medium);
  }

  .detail__foot :deep(.el-button) {
    flex: 1 1 auto;
  }
}
</style>
