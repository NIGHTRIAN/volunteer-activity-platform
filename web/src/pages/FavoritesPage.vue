<script setup>
/**
 * 我的收藏（方案 §7.3）。
 *
 * ## 方案对收藏的边界划得很清楚
 *
 * > | 本机收藏 | `localStorage`（键 `fav.activities`）；UI 明示"仅保存在本机浏览器" |
 * > **明确不做**：账号级收藏、跨设备同步、服务端保存浏览记录。
 *
 * 所以这个页面：
 *   * **只读 localStorage**，不发任何"保存收藏"的请求；
 *   * 界面上**必须**说清"仅保存在本机"，否则用户会以为
 *     换台电脑还能看到 —— 那时他会以为收藏功能坏了。
 *
 * ## 为什么只存 id，这一页却要查服务端
 *
 * `useFavorites` 只存 id + 收藏时间，不存活动快照。理由：
 * 活动信息会变（改期、取消），存快照会让收藏列表显示**过期信息**。
 *
 * 因此这一页按 id 去查当前状态。代价是要多发几个请求，
 * 换来的是"收藏列表里看到的一定是当前真实状态"。
 *
 * ## 收藏的活动可能已经不存在了
 *
 * 活动有 7 天留存期（方案 §9.3 / §12.1-5），过期后不可访问；
 * 也可能被取消。所以查不到是**正常情况**，必须优雅处理：
 * 说明原因并提示可以清理，而不是显示一个错误或空白。
 */

import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';

import ActivityCard from '../components/ActivityCard.vue';
import StateBlock from '../components/StateBlock.vue';
import { fetchActivity } from '../api/client.js';
import { useFavorites } from '../composables/useFavorites.js';

const router = useRouter();
const { ids, count, isFavorite, toggle, clear, reload } = useFavorites();

/** 每条：`{ id, activity | null, reason }`。 */
const entries = ref([]);
const loading = ref(true);

async function load() {
  loading.value = true;
  /*
    ⚠️ 先 reload 再读 ids。

    模块级的收藏状态在首次 import 时读一次 localStorage，之后只由
    本模块的写入更新。因此直接读 `ids.value` 会在两种情况下拿到旧数据：
      * 用户在**另一个标签页**收藏了活动；
      * 页面从 bfcache 恢复。
    表现是"收藏了但这一页是空的"，而 localStorage 里其实有数据。
  */
  reload();
  const current = ids.value;
  const results = await Promise.all(
    current.map(async (id) => {
      try {
        const data = await fetchActivity(id);
        return { id, activity: data.activity, reason: null };
      } catch (e) {
        /*
          查不到的原因要区分开，因为它们对用户的含义不同：

            * 404 → 活动已过留存期（按隐私设计销毁），或活动已被删除
            * 其他 → 网络/服务端问题，可以重试

          都显示成"加载失败"会误导：前者重试一辈子也不会成功。
        */
        return {
          id,
          activity: null,
          reason: e?.isNotFound
            ? '活动已不存在（可能已超过 7 天留存期，按隐私设计销毁）'
            : '暂时无法加载，请稍后重试',
          notFound: e?.isNotFound === true,
        };
      }
    }),
  );
  entries.value = results;
  loading.value = false;
}

onMounted(load);

/** 有效条目（能查到活动）。 */
const validEntries = computed(() => entries.value.filter((e) => e.activity));
/** 失效条目（查不到）。 */
const staleEntries = computed(() => entries.value.filter((e) => !e.activity));

/** 清掉所有查不到的收藏。 */
function removeStale() {
  for (const e of staleEntries.value) {
    // toggle 需要 activity 对象；失效条目没有，因此这里直接用 id 删。
    // 用假对象承载 id 即可 —— toggle 只读 id 与 title。
    toggle({ id: e.id, title: '' });
  }
  load();
}

function onOpen(activity) {
  // 打开详情用独立页面：收藏页没有列表的滚动位置需要保留。
  router.push({ name: 'activity', params: { id: activity.id } });
}

function onToggleFavorite(activity) {
  toggle(activity);
  // 取消收藏后从本页移除。
  load();
}

function clearAll() {
  clear();
  entries.value = [];
}
</script>

<template>
  <div class="fav">
    <header class="fav__head">
      <div>
        <h1 class="fav__title">我的收藏</h1>
        <!--
          ⚠️ 这句说明是方案明确要求的（"UI 明示仅保存在本机浏览器"）。
          不是客套话：不说清的话，用户换设备后找不到收藏会报 bug。
        -->
        <p class="fav__note">收藏仅保存在本机浏览器，不会上传，也不跨设备同步。</p>
      </div>
      <el-button v-if="count > 0" text type="danger" @click="clearAll">
        清空收藏
      </el-button>
    </header>

    <StateBlock v-if="loading" variant="skeleton" :rows="2" />

    <StateBlock
      v-else-if="count === 0"
      variant="empty"
      title="还没有收藏任何活动"
      description="在活动列表点右侧的星标即可收藏，方便之后回来查看。"
      action-text="浏览活动列表"
      @action="router.push({ name: 'list' })"
    />

    <template v-else>
      <!-- 有效收藏 -->
      <div v-if="validEntries.length" class="fav__list">
        <ActivityCard
          v-for="e in validEntries"
          :key="e.id"
          :activity="e.activity"
          :favorite="isFavorite(e.id)"
          @open="onOpen"
          @toggle-favorite="onToggleFavorite"
        />
      </div>

      <!--
        失效收藏单独成组，并说明**为什么**失效。
        直接把它们混在列表里会让用户困惑（"这个活动怎么点不开"）。
      -->
      <section v-if="staleEntries.length" class="fav__stale" aria-labelledby="stale-title">
        <div class="fav__stale-head">
          <h2 id="stale-title" class="fav__stale-title">
            已失效的收藏（{{ staleEntries.length }}）
          </h2>
          <el-button text type="primary" @click="removeStale">全部移除</el-button>
        </div>
        <ul class="fav__stale-list">
          <li v-for="e in staleEntries" :key="e.id" class="fav__stale-item">
            <span class="fav__stale-reason">{{ e.reason }}</span>
            <el-button text @click="toggle({ id: e.id, title: '' }); load()">
              移除
            </el-button>
          </li>
        </ul>
      </section>
    </template>
  </div>
</template>

<style scoped>
.fav {
  display: flex;
  flex-direction: column;
  gap: var(--sp-5);
}

.fav__head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--sp-4);
}

.fav__title {
  font-size: var(--fs-title-lg);
  font-weight: var(--fw-semibold);
  color: var(--c-text-primary);
}

.fav__note {
  margin-top: var(--sp-1);
  font-size: var(--fs-caption);
  color: var(--c-text-tertiary);
  max-width: var(--measure);
}

.fav__list {
  display: flex;
  flex-direction: column;
  gap: var(--sp-3);
}

.fav__stale {
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
  padding: var(--sp-4);
  background: var(--c-surface-sunken);
  border-radius: var(--r-lg);
}

.fav__stale-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-3);
}

.fav__stale-title {
  font-size: var(--fs-body-sm);
  font-weight: var(--fw-semibold);
  color: var(--c-text-secondary);
}

.fav__stale-list {
  margin: 0;
  padding: 0;
  list-style: none;
  display: flex;
  flex-direction: column;
}

.fav__stale-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-3);
  padding: var(--sp-2) 0;
  /* 用间距而不是分隔线来分组（better-layout 第 1 条）。 */
  font-size: var(--fs-caption);
  color: var(--c-text-tertiary);
}

.fav__stale-reason {
  line-height: var(--lh-snug);
}

@media (max-width: 767px) {
  .fav__head {
    flex-direction: column;
    gap: var(--sp-2);
  }
}
</style>
