/**
 * 路由。
 *
 * ## 为什么筛选条件放在**查询串**里（而不是组件本地状态）
 *
 * 方案 §7.3 要求"复制分享链接"，形如 `/#/activity/1001`。
 * 如果筛选条件只存在内存里，那么"把筛选后的列表发给同学"
 * 这件事就做不到 —— 对方打开只会看到默认列表。
 *
 * 放进 URL 之后：
 *   * 链接可分享、可收藏；
 *   * 浏览器前进/后退符合直觉；
 *   * 刷新不丢筛选。
 *
 * 代价是每次筛选要写一次 URL。用 `router.replace` 而不是 `push`：
 * 否则连续勾选三个筛选条件会往历史里塞三条记录，
 * 用户按一次返回只退掉一个勾选 —— 那不是他期望的。
 *
 * ## 用 hash 模式
 *
 * 方案 §7.3 给的分享链接示例是 `/#/activity/1001`，即 hash 模式。
 * 好处是**部署不需要服务端配合重写规则** —— history 模式下
 * 直接访问 `/activity/1001` 会 404，除非 Nginx 配 try_files
 * （那又是一个部署步骤，且很容易忘）。hash 模式没有这个问题。
 */

import { createRouter, createWebHashHistory } from 'vue-router';

const ActivityList = () => import('../pages/ActivityListPage.vue');
const ActivityDetail = () => import('../pages/ActivityDetailPage.vue');
const Favorites = () => import('../pages/FavoritesPage.vue');
const NotFound = () => import('../pages/NotFoundPage.vue');

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    {
      path: '/',
      name: 'list',
      component: ActivityList,
      meta: { title: '活动列表' },
    },
    {
      path: '/activity/:id',
      name: 'activity',
      component: ActivityDetail,
      meta: { title: '活动详情' },
    },
    {
      path: '/favorites',
      name: 'favorites',
      component: Favorites,
      meta: { title: '我的收藏' },
    },
    {
      // 兜底：用户可能粘贴了一个失效的分享链接。
      // 给出明确说明与回列表的入口，而不是空白页。
      path: '/:pathMatch(.*)*',
      name: 'not-found',
      component: NotFound,
      meta: { title: '页面不存在' },
    },
  ],
  scrollBehavior(to, from, saved) {
    // 浏览器前进/后退时恢复原来的滚动位置（用户期望回到原处）；
    // 新导航则回到顶部。
    if (saved) {
      return saved;
    }
    return { top: 0 };
  },
});

/** 路由变化时同步页面标题 —— 多标签页时能区分是哪一页。 */
router.afterEach((to) => {
  const base = '志愿活动信息平台';
  const t = to.meta?.title;
  document.title = t ? `${t} · ${base}` : base;
});
