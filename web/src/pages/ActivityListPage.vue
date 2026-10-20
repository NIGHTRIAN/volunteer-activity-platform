<script setup>
/**
 * 活动列表页（方案 §7.1）。
 *
 * 组成：筛选栏 + 统计图 + 列表分页（+ 响应式：窄屏卡片化）。
 *
 * ## 请求竞态的处理
 *
 * 用户快速改筛选条件时会发出多个请求，而**响应不一定按序返回**。
 * 如果不管，先发的慢请求后到达，会用旧数据覆盖新结果 ——
 * 表现为"筛选了但列表没变"。这里用 `AbortController`：
 * 每次新请求先取消上一个，从根上避免乱序。
 *
 * ## 统计与列表用同一次响应
 *
 * 服务端在列表响应里一并给了 `stats`，**且统计基于筛选后的全量**
 * （见 server 的 listActivities）。这样翻页时数字不会跳动 ——
 * 自己在前端按当前页统计是最常见的错误做法。
 */

import { computed, defineAsyncComponent, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRouter } from 'vue-router';

import ActivityFilters from '../components/ActivityFilters.vue';
import ActivityCard from '../components/ActivityCard.vue';
import StateBlock from '../components/StateBlock.vue';
import ActivityDetailDrawer from '../components/ActivityDetailDrawer.vue';
// 占位组件是**静态**导入的：它很小，且异步组件加载期间就要立刻显示它。
import StatsChartSkeleton from '../components/StatsChartSkeleton.vue';

/*
  ⚠️ 统计图**异步加载**，这是为了首屏体积。

  实测：把 StatsChart 静态导入时，承载它的 chunk 是
  724.79 kB（gzip 237.78 kB）—— 因为 ECharts 被一并打包进来，
  而方案 §8.4 给首屏的预算只有约 400 KB。

  两个理由支持把它延后：
    1. 统计图在页面上位于**列表下方**（宽屏时在右侧栏），
       首屏视口里往往还看不到它 —— 用户先要的是活动列表；
    2. 它依赖查询结果，列表数据到达后才有内容可画，
       早加载也只是空等。

  异步化之后，ECharts 只在浏览器空闲时按需拉取，
  首屏关键路径不再包含它。

  ⚠️ 占位组件必须是一个**真正的 .vue 组件**，不能写成
  `loadingComponent: { template: '...' }` —— 生产构建用不含模板
  编译器的 Vue 版本，字符串模板会在运行时报错（且开发期看不到）。
  见 StatsChartSkeleton.vue 的说明。
*/
const StatsChart = defineAsyncComponent({
  loader: () => import('../components/StatsChart.vue'),
  loadingComponent: StatsChartSkeleton,
  // 图表加载失败不该拖垮整页 —— 列表才是主内容。
  onError: (_err, _retry, fail) => {
    // eslint-disable-next-line no-console
    console.warn('[统计图] 加载失败，已跳过统计区');
    fail();
  },
});

import { fetchActivities, fetchActivity, fetchOrganizers } from '../api/client.js';
import { useActivityQuery } from '../composables/useActivityQuery.js';
import { useFavorites } from '../composables/useFavorites.js';

/*
  ⚠️ 这里**没有** `import { ElMessage } from 'element-plus'`，是刻意的。

  ElMessage 是以函数形式使用的 API，没有模板标签可供解析，
  最初我手写从 `element-plus` 主入口导入它。结果是：主入口的
  barrel 文件被拉进产物，**整个组件库一起被打包** ——
  实测 element chunk 1,022 kB（gzip 334 kB），按需引入完全失效。

  正确做法是让 `unplugin-auto-import` 的 ElementPlusResolver
  处理它：写 `ElMessage(...)` 直接用，编译期由插件补上
  **指向具体模块**的导入（`element-plus/es/components/message/...`），
  而不是主入口。见 vite.config.js 的 AutoImport 配置。
*/

const router = useRouter();
const { filters, update, reset, hasActiveFilters } = useActivityQuery();
const { isFavorite, toggle } = useFavorites();

const items = ref([]);
const total = ref(0);
const stats = ref({ byStatus: {} });
const organizers = ref([]);
const disclaimer = ref('');
const loading = ref(true);
const error = ref(null);

// 详情抽屉。
const drawerOpen = ref(false);
const detail = ref(null);
const detailLoading = ref(false);

/** 请求取消：避免快速切换筛选时的响应乱序。 */
let inflight = null;

async function load() {
  // 取消上一次仍在飞的请求。
  if (inflight) {
    inflight.abort();
  }
  const controller = new AbortController();
  inflight = controller;

  loading.value = true;
  error.value = null;
  try {
    const data = await fetchActivities(
      {
        keyword: filters.value.keyword,
        organizer: filters.value.organizer,
        status: filters.value.status,
        startFrom: filters.value.startFrom,
        startTo: filters.value.startTo,
        sortBy: filters.value.sortBy,
        sortDesc: filters.value.sortDesc,
        page: filters.value.page,
        size: filters.value.size,
      },
      { signal: controller.signal },
    );
    // 请求已被更新的一次取代 → 丢弃这次结果。
    if (controller.signal.aborted) {
      return;
    }
    items.value = data.items ?? [];
    total.value = data.total ?? 0;
    stats.value = data.stats ?? { byStatus: {} };
  } catch (e) {
    if (controller.signal.aborted || e?.name === 'AbortError') {
      return;
    }
    error.value = e;
    items.value = [];
    total.value = 0;
  } finally {
    if (inflight === controller) {
      inflight = null;
      loading.value = false;
    }
  }
}

/** 部门字典只需加载一次。 */
async function loadOrganizers() {
  try {
    const data = await fetchOrganizers();
    organizers.value = data.items ?? [];
  } catch {
    // 字典加载失败不该阻断主流程 —— 筛选栏少一个下拉而已。
  }
}

onMounted(() => {
  load();
  loadOrganizers();
});

// 筛选条件（含页码）变化 → 重新查询。
// `deep` 是因为 status 是数组。
watch(filters, () => load(), { deep: true });

onBeforeUnmount(() => {
  inflight?.abort();
});

// ── 交互 ──────────────────────────────────────────────────────────────

/**
 * 打开详情。
 *
 * ⚠️ 这里**再查一次详情接口**，而不是直接用列表项的数据。
 *
 * 理由：列表响应可能为了体积省略字段（这里是全量返回，但契约允许
 * 服务端将来裁剪），而且**详情接口会下发 `disclaimer`**。
 * 直接复用列表项会让"从列表点开"和"直接打开链接"两种路径
 * 显示不同内容 —— 那类不一致最难排查。
 */
async function openDetail(activity) {
  drawerOpen.value = true;
  detail.value = activity;      // 先显示列表里已有的数据，避免空白
  detailLoading.value = true;
  try {
    const data = await fetchActivity(activity.id);
    detail.value = data.activity;
    disclaimer.value = data.disclaimer ?? '';
  } catch (e) {
    ElMessage.error(e?.userMessage ?? '无法加载活动详情');
  } finally {
    detailLoading.value = false;
  }
}

function onToggleFavorite(activity) {
  const now = toggle(activity);
  ElMessage({
    message: now ? '已收藏（仅保存在本机浏览器）' : '已取消收藏',
    // 收藏是本机行为，提示里说清这一点，避免用户以为换台电脑也能看到。
    type: 'success',
    duration: 1800,
  });
}

function onExport(activity) {
  // 导出走服务端接口（方案 §7.3：三端共用同一个导出接口）。
  const url = `/api/activities/${encodeURIComponent(activity.id)}/export?kind=activities`;
  window.open(url, '_blank', 'noopener');
}

/** 页码或每页条数变化。 */
function onPageChange(page) {
  update({ page }, { resetPage: false });
}

function onSizeChange(size) {
  // 改每页条数时回到第 1 页：否则可能停在一个超出范围的空页上。
  update({ size, page: 1 }, { resetPage: false });
}

/** 空态时区分"没有活动"与"筛选太严" —— 后者要给出退出方式。 */
const emptyState = computed(() => {
  if (hasActiveFilters.value) {
    return {
      title: '没有符合条件的活动',
      description: '试试放宽筛选条件，或清除筛选查看全部活动。',
      actionText: '清除筛选',
    };
  }
  return {
    title: '暂时没有已发布的活动',
    description: '活动由各组织部门发布后会显示在这里。请稍后再来看看。',
    actionText: '',
  };
});

const errorDetail = computed(() => {
  if (!error.value) {
    return '';
  }
  const parts = [];
  if (error.value.code !== undefined) {
    parts.push(`code=${error.value.code}`);
  }
  if (error.value.httpStatus) {
    parts.push(`HTTP ${error.value.httpStatus}`);
  }
  if (error.value.traceId) {
    parts.push(`traceId=${error.value.traceId}`);
  }
  return parts.join('  ');
});
</script>

<template>
  <div class="list-page">
    <ActivityFilters
      :filters="filters"
      :organizers="organizers"
      :total="total"
      :loading="loading"
      :has-active-filters="hasActiveFilters"
      @update="update"
      @reset="reset"
    />

    <div class="list-page__body">
      <!-- 结果区 -->
      <section class="list-page__results" aria-labelledby="results-title">
        <h2 id="results-title" class="sr-only">活动列表</h2>

        <StateBlock
          v-if="loading && items.length === 0"
          variant="skeleton"
          :rows="4"
        />

        <StateBlock
          v-else-if="error"
          variant="error"
          :error-message="error.userMessage"
          :error-detail="errorDetail"
          @retry="load"
        />

        <StateBlock
          v-else-if="items.length === 0"
          variant="empty"
          :title="emptyState.title"
          :description="emptyState.description"
          :action-text="emptyState.actionText"
          @action="reset"
        />

        <template v-else>
          <div class="list-page__cards" :class="{ 'is-refreshing': loading }">
            <ActivityCard
              v-for="a in items"
              :key="a.id"
              :activity="a"
              :favorite="isFavorite(a.id)"
              @open="openDetail"
              @toggle-favorite="onToggleFavorite"
            />
          </div>

          <div v-if="total > filters.size" class="list-page__pager">
            <el-pagination
              :current-page="filters.page"
              :page-size="filters.size"
              :total="total"
              :page-sizes="[10, 20, 50]"
              layout="total, sizes, prev, pager, next"
              background
              @current-change="onPageChange"
              @size-change="onSizeChange"
            />
          </div>
        </template>
      </section>

      <!-- 统计区：宽屏时放右侧栏，窄屏时落到列表下方 -->
      <aside class="list-page__aside">
        <StatsChart
          :by-status="stats.byStatus"
          :total="total"
          :loading="loading"
        />
      </aside>
    </div>

    <ActivityDetailDrawer
      v-model="drawerOpen"
      :activity="detail"
      :favorite="detail ? isFavorite(detail.id) : false"
      :disclaimer="disclaimer"
      :loading="detailLoading"
      @toggle-favorite="onToggleFavorite"
      @export="onExport"
    />
  </div>
</template>

<style scoped>
.list-page {
  display: flex;
  flex-direction: column;
  gap: var(--sp-5);
}

.list-page__body {
  display: grid;
  /* 结果区自适应，统计栏固定 —— 统计栏太宽会让列表变窄。 */
  grid-template-columns: minmax(0, 1fr) 260px;
  gap: var(--sp-5);
  align-items: start;
}

.list-page__results {
  display: flex;
  flex-direction: column;
  gap: var(--sp-3);
  min-width: 0;
}

.list-page__cards {
  display: flex;
  flex-direction: column;
  gap: var(--sp-3);
  transition: opacity var(--dur-fast) var(--ease-out);
}

/*
  刷新时轻微降透明度，而不是加遮罩层或转圈：
  读者知道"内容在更新"，但仍能继续读现有内容。
  遮盖整块区域会让页面看起来像卡住了。
*/
.list-page__cards.is-refreshing {
  opacity: 0.6;
}

.list-page__pager {
  display: flex;
  justify-content: center;
  padding-top: var(--sp-3);
}

/* 统计栏跟随滚动：列表很长时它始终可见。 */
.list-page__aside {
  position: sticky;
  top: 88px;
}

/* 中屏：统计栏收窄。 */
@media (max-width: 1199px) {
  .list-page__body {
    grid-template-columns: minmax(0, 1fr) 220px;
    gap: var(--sp-4);
  }
}

/* 窄屏：统计栏落到列表下方（移动端卡片化，方案 §7.4）。
   放在下方而不是上方：读者来这里是看活动的，统计是次要信息。 */
@media (max-width: 900px) {
  .list-page__body {
    grid-template-columns: minmax(0, 1fr);
  }

  .list-page__aside {
    position: static;
    /* 顺序放到结果之后。 */
    order: 1;
  }

  .list-page__results {
    order: 0;
  }
}
</style>
