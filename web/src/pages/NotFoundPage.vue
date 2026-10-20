<script setup>
/**
 * 404 页面。
 *
 * ## 为什么会走到这里
 *
 * 分享链接是 `/#/activity/1001`。用户可能：
 *   * 手工改了地址栏；
 *   * 粘贴了一个被截断的链接；
 *   * 用了旧版本的路由（例如将来把 `/activity` 改成 `/a`）。
 *
 * ## 为什么要认真做这一页
 *
 * 说"页面不存在"然后留一个空白是最常见的做法，但那对用户没有帮助 ——
 * 他不知道是自己错了、还是网站坏了、还是要去别的地方找。
 * 所以这里说清"可能是链接不完整"，并给一个明确的去处。
 *
 * 同时**不要**自动跳回首页：用户会以为链接其实有效，
 * 只是被弹走了 —— 那比看到 404 更让人困惑。
 */

import { useRouter } from 'vue-router';

const router = useRouter();
</script>

<template>
  <div class="nf">
    <svg
      class="nf__icon"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <circle cx="11" cy="11" r="6.5" />
      <path d="m16 16 4.5 4.5" />
      <path d="M9 11h4" />
    </svg>

    <h1 class="nf__title">这个页面不存在</h1>

    <p class="nf__desc">
      链接可能不完整，或者已经失效。活动链接的格式是
      <code class="nf__code">/#/activity/活动编号</code>。
    </p>

    <el-button type="primary" class="nf__action" @click="router.push({ name: 'list' })">
      浏览活动列表
    </el-button>
  </div>
</template>

<style scoped>
.nf {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: var(--sp-3);
  padding: var(--sp-12) var(--sp-6);
  text-align: center;
  background: var(--c-surface);
  border-radius: var(--r-lg);
  box-shadow: var(--shadow-sm);
}

.nf__icon {
  width: 44px;
  height: 44px;
  color: var(--c-text-disabled);
  margin-bottom: var(--sp-1);
}

.nf__title {
  font-size: var(--fs-title-lg);
  font-weight: var(--fw-semibold);
  color: var(--c-text-primary);
}

.nf__desc {
  font-size: var(--fs-body-sm);
  color: var(--c-text-tertiary);
  line-height: var(--lh-body);
  max-width: 46ch;
}

.nf__code {
  padding: 2px var(--sp-1);
  border-radius: var(--r-xs);
  background: var(--c-surface-sunken);
  font-family: ui-monospace, 'SFMono-Regular', Menlo, Consolas, monospace;
  font-size: var(--fs-caption);
  color: var(--c-text-secondary);
  /* 代码片段不折行，否则斜杠位置会变得难认。 */
  white-space: nowrap;
}

.nf__action {
  margin-top: var(--sp-3);
}
</style>
