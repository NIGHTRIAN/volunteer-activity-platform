<script setup>
/**
 * 筛选栏（方案 §7.1：部门 / 状态 / 时间范围 / 关键词）。
 *
 * ## 关键词输入做防抖，其余立即生效
 *
 * 输入框每敲一个字母都发请求会很浪费（中文输入法还会在拼音阶段
 * 就触发）。下拉与日期是离散选择，没有这个问题，立即生效更跟手。
 *
 * ## 不把筛选项堆成一行
 *
 * 窄屏上一行放不下四个控件，硬塞会挤压成看不清的窄条。
 * 这里用 flex-wrap 让它自然换行，并在窄屏把每个控件拉满宽度 ——
 * 比横向滚动好（横向滚动里的控件容易被忽略）。
 */

import { computed, ref, watch } from 'vue';
import { ACTIVITY_STATUS_OPTIONS } from '../domain/statusOptions.js';

const props = defineProps({
  filters: { type: Object, required: true },
  organizers: { type: Array, default: () => [] },
  total: { type: Number, default: 0 },
  loading: { type: Boolean, default: false },
  hasActiveFilters: { type: Boolean, default: false },
});

const emit = defineEmits(['update', 'reset']);

/** 关键词本地副本（防抖后再向上报）。 */
const keywordInput = ref(props.filters.keyword ?? '');

// 外部（例如点"清除筛选"或浏览器后退）改了关键词时同步回输入框。
watch(
  () => props.filters.keyword,
  (v) => {
    if ((v ?? '') !== keywordInput.value) {
      keywordInput.value = v ?? '';
    }
  },
);

let debounceTimer = null;
function onKeywordInput(value) {
  keywordInput.value = value;
  if (debounceTimer) {
    clearTimeout(debounceTimer);
  }
  // 300ms：短于中文输入法的候选阶段，长于人的连续击键间隔。
  debounceTimer = setTimeout(() => {
    emit('update', { keyword: value.trim() });
  }, 300);
}

/** 状态多选：值为数组。 */
const statusModel = computed({
  get: () => props.filters.status ?? [],
  set: (v) => emit('update', { status: v }),
});

/** 日期范围：Element Plus 给的是数组或 null。 */
const dateRange = computed({
  get: () => {
    const { startFrom, startTo } = props.filters;
    if (!startFrom && !startTo) {
      return null;
    }
    // 只用日期部分：时间范围筛选按天就够，精确到秒没人会用。
    return [startFrom ? startFrom.slice(0, 10) : null, startTo ? startTo.slice(0, 10) : null];
  },
  set: (v) => {
    if (!v || !v[0]) {
      emit('update', { startFrom: '', startTo: '' });
      return;
    }
    emit('update', {
      // 起始取当天 00:00，结束取当天 23:59 ——
      // 否则选"今天到今天"会因为结束时间早于活动开始时间而查不到任何东西。
      startFrom: `${v[0]}T00:00:00+08:00`,
      startTo: `${v[1] ?? v[0]}T23:59:59+08:00`,
    });
  },
});

const organizerModel = computed({
  get: () => props.filters.organizer,
  set: (v) => emit('update', { organizer: v ?? '' }),
});

/** 结果计数文案：明确说"共几条"，而不是只给个数字。 */
const resultText = computed(() =>
  props.loading ? '正在加载…' : `共 ${props.total} 个活动`,
);
</script>

<template>
  <section class="filters" aria-label="活动筛选">
    <div class="filters__row">
      <!-- 关键词：占最宽，因为它是最高频的入口 -->
      <div class="filters__field filters__field--grow">
        <label class="filters__label" for="f-keyword">搜索活动</label>
        <el-input
          id="f-keyword"
          :model-value="keywordInput"
          placeholder="活动名称、简介或组织部门"
          clearable
          @update:model-value="onKeywordInput"
          @clear="onKeywordInput('')"
        >
          <template #prefix>
            <svg
              class="filters__icon"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
              aria-hidden="true"
            >
              <circle cx="11" cy="11" r="6.5" />
              <path d="m16 16 4.5 4.5" />
            </svg>
          </template>
        </el-input>
      </div>

      <div class="filters__field">
        <label class="filters__label" for="f-organizer">组织部门</label>
        <el-select
          id="f-organizer"
          v-model="organizerModel"
          placeholder="全部部门"
          clearable
        >
          <el-option
            v-for="o in organizers"
            :key="o"
            :label="o"
            :value="o"
          />
        </el-select>
      </div>

      <div class="filters__field">
        <label class="filters__label" for="f-range">活动时间</label>
        <el-date-picker
          id="f-range"
          v-model="dateRange"
          type="daterange"
          value-format="YYYY-MM-DD"
          range-separator="至"
          start-placeholder="开始日期"
          end-placeholder="结束日期"
          unlink-panels
        />
      </div>
    </div>

    <div class="filters__row filters__row--status">
      <div class="filters__field filters__field--grow">
        <!--
          状态用 checkbox 组而不是多选下拉：
          只有 4 个选项、且"当前筛了哪些"必须一眼可见 ——
          下拉会把已选状态藏起来，用户会忘记自己筛过什么，
          然后以为"活动怎么这么少"。
        -->
        <span class="filters__label" id="f-status-label">活动状态</span>
        <el-checkbox-group
          v-model="statusModel"
          class="filters__status"
          aria-labelledby="f-status-label"
        >
          <el-checkbox
            v-for="opt in ACTIVITY_STATUS_OPTIONS"
            :key="opt.value"
            :value="opt.value"
          >
            {{ opt.label }}
          </el-checkbox>
        </el-checkbox-group>
      </div>

      <div class="filters__actions">
        <span class="filters__count tnum">{{ resultText }}</span>
        <el-button
          v-if="hasActiveFilters"
          text
          type="primary"
          @click="emit('reset')"
        >
          清除筛选
        </el-button>
      </div>
    </div>
  </section>
</template>

<style scoped>
.filters {
  display: flex;
  flex-direction: column;
  /* 两组之间 16px（组间至少是组内的 2 倍）。 */
  gap: var(--gap-inter);
  padding: var(--sp-4);
  background: var(--c-surface);
  border-radius: var(--r-lg);
  box-shadow: var(--shadow-sm);
}

.filters__row {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-end;
  gap: var(--sp-3);
}

.filters__row--status {
  /* 状态组与计数之间用一条浅分隔线会太吵；
     用间距区分即可（better-layout 第 1 条）。 */
  align-items: center;
  justify-content: space-between;
}

.filters__field {
  display: flex;
  flex-direction: column;
  gap: var(--sp-1);
  min-width: 0;
}

.filters__field--grow {
  flex: 1 1 260px;
}

/**
 * ⚠️ Element Plus 的日期范围选择器与下拉框都有**自己的默认宽度**，
 * 直接放进 flex 容器会在右侧留出一段参差不齐的空白 ——
 * 实测截图里"活动时间"比上方"组织部门"短了约 70px，
 * 看起来像没对齐，而这种"差一点点"的错位最容易被当成粗糙。
 *
 * 做法：让这两个控件撑满各自的列，使它们的左右边缘与容器
 * 形成稳定的对齐边（better-layout 第 3 条）。
 */
.filters__field :deep(.el-select),
.filters__field :deep(.el-date-editor) {
  width: 100%;
}

/* 部门与时间两列给固定下限，避免长部门名把关键词挤没。 */
.filters__field:not(.filters__field--grow) {
  flex: 0 1 220px;
  min-width: 180px;
}

/* 日期范围需要更宽：两个日期 + 分隔符。 */
.filters__field:has(.el-date-editor) {
  flex: 0 1 300px;
  min-width: 240px;
}

/* 标签始终可见，不用 placeholder 充当标签
   （better-writing 第 12 条：placeholder 一输入就消失）。 */
.filters__label {
  font-size: var(--fs-caption);
  font-weight: var(--fw-medium);
  color: var(--c-text-secondary);
}

.filters__status {
  display: flex;
  flex-wrap: wrap;
  gap: var(--sp-1) var(--sp-4);
}

.filters__actions {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  /* 让它靠右，与筛选控件形成稳定的对齐边。 */
  margin-inline-start: auto;
}

.filters__count {
  font-size: var(--fs-caption);
  color: var(--c-text-tertiary);
  white-space: nowrap;
}

.filters__icon {
  width: 16px;
  height: 16px;
  color: var(--c-text-tertiary);
}

/* 窄屏：每个控件拉满宽度，纵向堆叠。 */
@media (max-width: 767px) {
  .filters__row {
    flex-direction: column;
    align-items: stretch;
  }

  /*
    ⚠️ `flex: 1 1 100%` 而不是 `flex: 1 1 auto`，这是实测踩出来的。

    原来的写法是 `flex: 1 1 auto; width: 100%`。在 `flex-direction: column`
    的容器里，纵轴尺寸由 `flex-basis` 决定，而 `auto` 会回落到内容高度 ——
    对日期范围选择器来说那就失控了：实测它被渲染成约 250px 高的巨块，
    把整页撑变形。改成 `100%` 后纵轴按容器宽度分配，高度自然收紧。
  */
  .filters__field,
  .filters__field--grow,
  .filters__field:not(.filters__field--grow),
  .filters__field:has(.el-date-editor) {
    flex: 1 1 100%;
    width: 100%;
    min-width: 0;
  }

  /* Element Plus 的日期范围选择器默认有固定宽度，窄屏要放开。 */
  .filters__field :deep(.el-date-editor) {
    width: 100%;
  }

  /*
    ⚠️ 状态复选框的间距必须收窄。

    实测：`gap: var(--sp-1) var(--sp-4)`（横向 16px）在 390px 宽的屏幕上
    会把第 4 个选项「已取消」挤出容器右边缘 —— 它是**点不到**的，
    因为外层没有横向滚动。这类"内容超出且无法到达"是必须修的，
    不是外观问题。

    收窄到 8px，并允许换行，四项就能在窄屏上排下。
  */
  .filters__status {
    gap: var(--sp-1) var(--sp-2);
  }

  .filters__row--status {
    align-items: stretch;
    /* 让状态组与计数各占一行，避免计数被挤到边上。 */
    flex-direction: column;
    gap: var(--sp-3);
  }

  .filters__actions {
    margin-inline-start: 0;
    justify-content: space-between;
  }
}
</style>
