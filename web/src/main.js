/**
 * 应用入口。
 *
 * ## Element Plus 是**按需引入**的
 *
 * 组件由 `unplugin-vue-components` 在编译期解析（见 vite.config.js），
 * 因此这里**看不到** `app.use(ElementPlus)`，模板里也直接写
 * `<el-button>` 而无需 import —— 这是刻意的。
 *
 * 原因见 vite.config.js 的详细说明：全量引入时 element chunk 是
 * gzip 335 KB，而方案 §8.4 给整个首屏的预算是约 400 KB。
 * 一个组件库吃掉整个预算，按方案采购的带宽就不够用了。
 *
 * ⚠️ 样式也要按需。**不要**在这里 `import 'element-plus/dist/index.css'`
 * —— 那是全量样式（实测 gzip 50 KB），会让按需引入的收益打掉一半。
 * 组件样式由 resolver 自动带上；全局变量覆盖在
 * `styles/element-overrides.css` 里单独处理。
 */

import { createApp } from 'vue';
import zhCn from 'element-plus/es/locale/lang/zh-cn';

// 样式顺序很重要：
//   1. 本项目令牌（提供 --c-* 等变量）
//   2. 把令牌映射到 Element Plus 变量
//   3. 基础样式与全局排版
// 顺序反了会导致令牌被组件库默认值覆盖 —— 那是"改了没生效"的常见原因。
//
// Element Plus 的组件样式由按需插件自动注入，位置在这些之后，
// 因此本项目的变量覆盖仍然生效（它作用于 `:root` 层级，不受顺序影响）。
import './styles/tokens.css';
import './styles/element-overrides.css';
import './styles/base.css';

import App from './App.vue';
import { router } from './router/index.js';

const app = createApp(App);

app.use(router);

/**
 * 语言包。
 *
 * 按需引入时不能靠 `app.use(ElementPlus, { locale })` 传语言，
 * 因为根本没有那个 plugin 实例。Element Plus 支持用 ConfigProvider
 * 或全局注入来设置 —— 这里用最简单可靠的做法：
 * 挂在全局属性上，由 App.vue 的 el-config-provider 消费。
 *
 * 不设置的话分页器与日期选择器会出现 "Go to" / "January" 这类英文，
 * 在一个中文界面里很扎眼。
 */
app.provide('elLocale', zhCn);

/**
 * 全局错误处理。
 *
 * 目的不是"吞掉错误"，而是**让失败可见**：未处理的组件异常
 * 默认只在控制台输出，用户看到的是一个空白页面，
 * 而我们会以为是网络问题。
 */
app.config.errorHandler = (err, _instance, info) => {
  // eslint-disable-next-line no-console
  console.error('[未捕获的组件错误]', info, err);
};

app.mount('#app');
