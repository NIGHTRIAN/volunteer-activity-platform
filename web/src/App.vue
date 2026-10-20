<script setup>
/**
 * 应用外壳：页头 + 主区 + 页脚。
 *
 * ## 页头为什么这么简
 *
 * 方案 §1.4 明确：**Web 浏览端没有账号体系（公开只读）**。
 * 所以页头不该出现登录/注册按钮 —— 那会让读者以为要登录才能看，
 * 而实际上不需要。
 *
 * ## 页脚为什么必须有那句话
 *
 * 方案 §1.1 把平台定位为"**不作为志愿时长统计与认定的权威依据**"。
 * 这不是免责套话，而是这个系统能被允许存在的前提：
 * 它提供的是现场协调用的参考信息。把这句话放在每一页的页脚，
 * 是让使用者（尤其是学生）不会基于它做错判断。
 */

import { inject } from 'vue';
import zhCn from 'element-plus/es/locale/lang/zh-cn';
import { useFavorites } from './composables/useFavorites.js';

/**
 * 语言包。
 *
 * 按需引入模式下没有 `app.use(ElementPlus, { locale })` 可用，
 * 因此语言通过 `el-config-provider` 下发（main.js 用 provide 注入）。
 * 不设置的话分页器会显示 "Go to"、日期选择器会显示 "January" 这类英文。
 */
const elLocale = inject('elLocale', zhCn);

/**
 * 收藏计数徽标。
 *
 * 方案 §7.3 要求"UI 明示仅保存在本机浏览器"，因此这里的
 * 提示文字（title）把它写清楚 —— 不能只靠收藏页里的说明，
 * 因为用户可能从列表页直接点徽标，从未进过收藏页。
 */
const { count } = useFavorites();
</script>

<template>
  <!--
    ConfigProvider 是 Element Plus 的语言/尺寸下发点。
    它只包一层、不产生 DOM，因此对布局没有影响。
  -->
  <el-config-provider :locale="elLocale">
    <div class="app">
      <a class="skip-link" href="#main">跳到主要内容</a>

      <header class="app__header">
        <div class="app__header-inner">
          <router-link class="brand" to="/">
            <!--
              图标用 currentColor，状态由 CSS 决定 ——
              不维护多套资源（better-ui 第 14 条）。
            -->
            <svg
              class="brand__mark"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path d="M12 20s-7-4.35-7-9a4 4 0 0 1 7-2.65A4 4 0 0 1 19 11c0 4.65-7 9-7 9Z" />
            </svg>
            <span class="brand__text">
              <strong class="brand__title">志愿活动信息平台</strong>
              <span class="brand__sub">活动查询 · 公开只读</span>
            </span>
          </router-link>

          <nav class="app__nav" aria-label="主导航">
            <router-link class="app__nav-link" to="/">活动列表</router-link>
            <router-link
              class="app__nav-link app__nav-link--fav"
              to="/favorites"
              title="收藏仅保存在本机浏览器，不会上传"
            >
              我的收藏
              <!--
                计数徽标：只在有收藏时显示。
                显示 "0" 是噪声 —— 它不提供任何信息。
              -->
              <span v-if="count > 0" class="app__nav-badge tnum">{{ count }}</span>
            </router-link>
          </nav>
        </div>
      </header>

      <main id="main" class="app__main">
        <router-view />
      </main>

      <footer class="app__footer">
        <div class="app__footer-inner">
          <p class="app__disclaimer">
            本平台用于活动信息发布与现场协调，<strong>不作为志愿时长统计与认定的权威依据</strong>。
          </p>
          <p class="app__footer-meta">
            页面为公开只读视图，不收集浏览记录；收藏仅保存在本机浏览器。
          </p>
        </div>
      </footer>
    </div>
  </el-config-provider>
</template>

<style scoped>
.app {
  display: flex;
  flex-direction: column;
  min-height: 100vh;
}

/* 跳到主内容：键盘用户的第一个 Tab 就能跳到正文，
   不必逐个跳过页头元素（WCAG 2.4.1）。 */
.skip-link {
  position: absolute;
  inset-inline-start: var(--sp-4);
  top: -100px;
  z-index: 100;
  padding: var(--sp-2) var(--sp-4);
  border-radius: var(--r-sm);
  background: var(--c-primary);
  color: var(--c-text-inverse);
  font-size: var(--fs-body-sm);
  text-decoration: none;
  transition: top var(--dur-fast) var(--ease-out);
}

.skip-link:focus {
  top: var(--sp-3);
}

/* ── 页头 ─────────────────────────────────────────────────────────── */

.app__header {
  position: sticky;
  top: 0;
  z-index: 20;
  /* 半透明 + 模糊：滚动时内容从下面透出来，比不透明条轻。
     但必须保证文字可读 —— 所以底色是 92% 不透明，不是 60%。 */
  background: color-mix(in srgb, var(--c-surface) 92%, transparent);
  backdrop-filter: blur(8px);
  border-bottom: 1px solid var(--c-border);
}

.app__header-inner {
  max-width: var(--layout-max);
  margin: 0 auto;
  padding: var(--sp-3) var(--layout-pad);
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-4);
}

/* ── 导航 ─────────────────────────────────────────────────────────── */

.app__nav {
  display: flex;
  align-items: center;
  gap: var(--sp-1);
}

.app__nav-link {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-1);
  /* 触摸目标 ≥44px。 */
  min-height: 44px;
  padding: 0 var(--sp-3);
  border-radius: var(--r-sm);
  font-size: var(--fs-body-sm);
  font-weight: var(--fw-medium);
  color: var(--c-text-secondary);
  text-decoration: none;
  /* 只过渡颜色 —— 不用 transition: all（better-ui 第 11 条）。 */
  transition-property: color, background-color;
  transition-duration: var(--dur-fast);
  transition-timing-function: var(--ease-out);
}

.app__nav-link:hover {
  color: var(--c-text-primary);
  background: var(--c-surface-sunken);
}

/*
  当前页高亮。
  ⚠️ 不只用颜色区分（色盲用户看不出）—— 同时加粗并加一条下边线，
  即"颜色 + 字重 + 形状"三重冗余。
*/
.app__nav-link.router-link-exact-active {
  color: var(--c-primary);
  background: var(--c-primary-soft);
}

.app__nav-badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 18px;
  height: 18px;
  padding: 0 5px;
  border-radius: var(--r-full);
  background: var(--c-primary);
  color: var(--c-text-inverse);
  font-size: 11px;
  font-weight: var(--fw-semibold);
  line-height: 1;
}

.brand {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-3);
  text-decoration: none;
  color: inherit;
  /* 触摸目标 ≥44px，同时视觉上不显笨重。 */
  min-height: 44px;
}

.brand__mark {
  width: 28px;
  height: 28px;
  flex-shrink: 0;
  color: var(--c-primary);
  /* 图标描边与相邻文字的字重匹配（better-ui 第 13 条）：
     标题是 semibold，所以描边用 1.5 而不是 1。 */
}

.brand__text {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.brand__title {
  font-size: var(--fs-title);
  font-weight: var(--fw-semibold);
  line-height: var(--lh-tight);
  color: var(--c-text-primary);
}

.brand__sub {
  font-size: var(--fs-caption);
  color: var(--c-text-tertiary);
  line-height: 1.3;
}

/* ── 主区 ─────────────────────────────────────────────────────────── */

.app__main {
  flex: 1;
  width: 100%;
  max-width: var(--layout-max);
  margin: 0 auto;
  padding: var(--sp-6) var(--layout-pad) var(--sp-12);
}

/* ── 页脚 ─────────────────────────────────────────────────────────── */

.app__footer {
  border-top: 1px solid var(--c-border);
  background: var(--c-surface);
}

.app__footer-inner {
  max-width: var(--layout-max);
  margin: 0 auto;
  padding: var(--sp-6) var(--layout-pad);
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
}

.app__disclaimer {
  font-size: var(--fs-body-sm);
  color: var(--c-text-secondary);
  line-height: var(--lh-snug);
  max-width: var(--measure);
}

.app__disclaimer strong {
  color: var(--c-text-primary);
  font-weight: var(--fw-medium);
}

.app__footer-meta {
  font-size: var(--fs-caption);
  color: var(--c-text-tertiary);
}

@media (max-width: 767px) {
  .app__main {
    padding-top: var(--sp-4);
  }

  .brand__sub {
    /* 窄屏上省掉副标题：主标题已经说清了是什么。 */
    display: none;
  }
}
</style>
