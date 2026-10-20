<script setup>
/**
 * 统计图区（方案 §7.1：统计图区；§1.2：平台以图表呈现汇总统计）。
 *
 * ## 用 ECharts 但**不用它的默认主题**
 *
 * ECharts 的默认配色是一组高饱和的彩虹色。在这个页面里，
 * 读者要对比的是"进行中 / 报名中 / 已结束 / 已取消"，
 * 而颜色的语义必须与状态徽标**保持一致** ——
 * 否则同一件事在图里是蓝色、在列表里是绿色，读者要重新学一遍。
 *
 * 所以这里显式指定每个状态的颜色，并且**做成横向条形图**而不是饼图：
 *   * 条形图的长度差异比扇形角度更容易比较；
 *   * 状态名可以直接写在条上，不必配图例；
 *   * 数量为 0 的状态不会像饼图那样消失得无影无踪。
 *
 * ## 无障碍
 *
 * 图表对视障用户不可用，因此每张图都配一段等价文字（`aria-label`
 * 与可见的数字列表）。ECharts 生成的 canvas 本身没有语义。
 */

import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import * as echarts from 'echarts/core';
import { BarChart } from 'echarts/charts';
import { GridComponent, TooltipComponent } from 'echarts/components';
import { CanvasRenderer } from 'echarts/renderers';
import { ACTIVITY_STATUS_OPTIONS } from '../domain/statusOptions.js';

// 按需注册：只引入用到的图表与组件，产物体积小很多。
echarts.use([BarChart, GridComponent, TooltipComponent, CanvasRenderer]);

const props = defineProps({
  /** `{ status: count }` */
  byStatus: { type: Object, default: () => ({}) },
  total: { type: Number, default: 0 },
  loading: { type: Boolean, default: false },
});

const el = ref(null);
let chart = null;

/**
 * 状态色。
 *
 * ⚠️ 这些值必须与 tokens.css / StatusChip.vue 的色调一致。
 * 之所以在这里重复写死，是因为 ECharts 画在 canvas 上，
 * 拿不到 CSS 变量 —— 这是本文件唯一需要"重复定义"的地方，
 * 因此在下面加了注释说明来源。
 */
const STATUS_COLOR = {
  ongoing: '#0f8a4f',    // --c-success
  published: '#1a6ae0',  // --c-primary
  finished: '#98a2b3',   // --c-text-disabled（已结束是"归档"，降到背景层）
  cancelled: '#c0362c',  // --c-danger
};

/** 图表数据：按固定顺序，且**包含数量为 0 的状态**（见文件头说明）。 */
const chartRows = computed(() =>
  ACTIVITY_STATUS_OPTIONS.map((o) => ({
    value: o.value,
    label: o.label,
    count: Number(props.byStatus?.[o.value] ?? 0),
  })),
);

/** 图表高度根据条目数算，避免空白过多。 */
const chartHeight = computed(() => `${Math.max(140, chartRows.value.length * 38 + 24)}px`);

/** 等价文字（无障碍用）。 */
const ariaText = computed(() => {
  const parts = chartRows.value
    .filter((r) => r.count > 0)
    .map((r) => `${r.label} ${r.count} 个`);
  return parts.length ? `活动状态分布：${parts.join('，')}。` : '暂无活动数据。';
});

function renderChart() {
  if (!el.value) {
    return;
  }
  if (!chart) {
    chart = echarts.init(el.value, null, { renderer: 'canvas' });
  }

  chart.setOption({
    // 不用动画：数据是随筛选变化的，动画会让"变化了多少"更难判断。
    animation: false,
    /*
      ⚠️ `containLabel: true` + `left: 0` 是这里的关键，实测踩过一次。

      最初的写法是 `left: 0, right: 8`。问题在于 ECharts 的
      `containLabel` 会把坐标轴标签的宽度算进去，而数值标签
      （`label.position: 'right'`）画在**绘图区之外** ——
      它不算在 grid 里。于是"报名中 3"这个数字被裁在了卡片右边缘外面，
      看起来像布局溢出的 bug。

      修法：给 grid 右侧留出足够的空间容纳最大数值标签
      （这里按 3 位数字 + 一点余量给 34px），并让 ECharts
      自己算左侧标签宽度。
    */
    grid: { left: 0, right: 34, top: 4, bottom: 4, containLabel: true },
    tooltip: {
      trigger: 'item',
      formatter: (p) => `${p.name}：${p.value} 个`,
      textStyle: { fontSize: 13 },
      // 提示框别超出卡片，否则在窄屏上会被裁掉。
      confine: true,
    },
    xAxis: {
      type: 'value',
      // 不显示坐标轴与网格线：数字已经标在条上了，轴线只是噪声。
      show: false,
      minInterval: 1,
      /*
        上限留出余量，否则"最大值"那根条会顶到最右边，
        与数值标签挤在一起。
      */
      max: (v) => (v.max <= 0 ? 1 : Math.ceil(v.max * 1.15)),
    },
    yAxis: {
      type: 'category',
      // 逆序，让第一个状态（进行中）显示在最上面。
      data: chartRows.value.map((r) => r.label).reverse(),
      axisLine: { show: false },
      axisTick: { show: false },
      axisLabel: {
        fontSize: 13,
        color: '#475467', // --c-text-secondary
      },
    },
    series: [
      {
        type: 'bar',
        data: chartRows.value
          .map((r) => ({
            value: r.count,
            itemStyle: { color: STATUS_COLOR[r.value] ?? '#98a2b3' },
          }))
          .reverse(),
        barWidth: 14,
        // 圆角让条形看起来更轻；右侧圆角与背景形成"增长"的方向感。
        itemStyle: { borderRadius: [0, 4, 4, 0] },
        label: {
          show: true,
          position: 'right',
          fontSize: 13,
          // 用次要色而不是与条同色：条已经很显眼，数字要克制。
          color: '#475467',
          formatter: '{c}',
        },
        // 静默高亮，避免鼠标划过时颜色突变。
        emphasis: { disabled: true },
      },
    ],
  });
}

function handleResize() {
  chart?.resize();
}

onMounted(() => {
  renderChart();
  window.addEventListener('resize', handleResize);
});

watch(chartRows, () => {
  renderChart();
});

onBeforeUnmount(() => {
  window.removeEventListener('resize', handleResize);
  chart?.dispose();
  chart = null;
});
</script>

<template>
  <section class="stats" aria-labelledby="stats-title">
    <h2 id="stats-title" class="stats__title">按状态汇总</h2>

    <!--
      图表给屏幕阅读器一段等价文字。
      canvas 对辅助技术是不可见的，没有这段文字，图表等于不存在。
    -->
    <p class="sr-only">{{ ariaText }}</p>

    <div
      ref="el"
      class="stats__chart"
      :style="{ height: chartHeight }"
      role="img"
      :aria-label="ariaText"
    />

    <!--
      可见的数字列表：图表的直接替代。
      不只是为了无障碍 —— 精确数值在条形图上读不出来，
      而"已结束 1 个"这种信息需要精确。
    -->
    <ul class="stats__list">
      <li v-for="r in chartRows" :key="r.value" class="stats__item">
        <span class="stats__dot" :style="{ background: STATUS_COLOR[r.value] }" aria-hidden="true" />
        <span class="stats__label">{{ r.label }}</span>
        <span class="stats__count tnum">{{ r.count }}</span>
      </li>
    </ul>

    <p class="stats__foot tnum">当前筛选条件下共 {{ total }} 个活动</p>
  </section>
</template>

<style scoped>
.stats {
  display: flex;
  flex-direction: column;
  gap: var(--sp-3);
  padding: var(--sp-4);
  background: var(--c-surface);
  border-radius: var(--r-lg);
  box-shadow: var(--shadow-sm);
}

.stats__title {
  font-size: var(--fs-caption);
  font-weight: var(--fw-semibold);
  color: var(--c-text-tertiary);
  letter-spacing: 0.04em;
}

.stats__chart {
  width: 100%;
}

.stats__list {
  display: flex;
  flex-wrap: wrap;
  gap: var(--sp-1) var(--sp-4);
  margin: 0;
  padding: var(--sp-3) 0 0;
  list-style: none;
  border-top: 1px solid var(--c-divider);
}

.stats__item {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-1);
  font-size: var(--fs-caption);
  color: var(--c-text-secondary);
}

.stats__dot {
  width: 8px;
  height: 8px;
  border-radius: var(--r-full);
  flex-shrink: 0;
}

.stats__label {
  color: var(--c-text-tertiary);
}

.stats__count {
  font-weight: var(--fw-medium);
  color: var(--c-text-primary);
}

.stats__foot {
  font-size: var(--fs-caption);
  color: var(--c-text-tertiary);
}
</style>
