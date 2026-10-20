import { fileURLToPath, URL } from 'node:url';
import { defineConfig, loadEnv } from 'vite';
import vue from '@vitejs/plugin-vue';
import AutoImport from 'unplugin-auto-import/vite';
import Components from 'unplugin-vue-components/vite';
import { ElementPlusResolver } from 'unplugin-vue-components/resolvers';

/**
 * Vite 配置。
 *
 * ## 为什么开发期要 proxy 而不是直连服务端
 *
 * 服务端地址走环境变量（方案 §8.1），开发时它是 `http://127.0.0.1:8080`。
 * 如果前端直接请求那个地址，浏览器会拦跨域 —— 而服务端**不该**为了
 * 开发方便就放开 CORS（生产环境放开 CORS 是真实风险）。
 *
 * 用 Vite 的 proxy 让浏览器只看到同源的 `/api`，
 * 由开发服务器转发。好处：
 *   * 开发与生产**同域**，前端代码不必区分环境（方案 §8.2：前后端同域）；
 *   * 服务端可以保持严格 CORS；
 *   * 不需要在开发期给前端配任何绝对地址。
 *
 * 生产由 Nginx 做同样的事（`/api` → 同步服务），见 deploy/nginx.conf。
 */
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  // 仅开发期使用；生产由 Nginx 转发，前端产物里不含这个地址。
  const apiTarget = env.VITE_API_PROXY_TARGET || 'http://127.0.0.1:8080';

  return {
    plugins: [
      vue(),
      /*
        Element Plus **按需引入**。

        ## 为什么改掉了全量引入

        最初是全量引入（`app.use(ElementPlus)`），因为它简单、
        不用担心"某个组件忘了注册"。做完一次生产构建后发现实测数字：

          element chunk   1,024.71 kB（gzip 335.18 kB）

        而方案 §8.4 明确写了两条红线：

          * **首屏静态资源约 400 KB**，1 Mbps 带宽下数人同时打开即打满
          * 「1 Mbps 不足（首屏静态资源约 400 KB…）」

        也就是说**单是 Element Plus 一个库就吃掉了整个首屏预算**，
        还没算 ECharts（gzip 152 KB）与业务代码（gzip 14 KB）。
        这不只是"警告一下"的程度 —— 方案把带宽写成了采购与容量的
        依据，超出预算意味着按方案采购的服务器会不够用。

        按需引入后只有实际用到的十余个组件与其样式进入产物。

        ## 保留的风险与对策

        按需引入的经典坑是"组件名写错 → 编译通过 → 运行时才报错"。
        对策：本项目所有 Element Plus 组件都集中在少数几个页面里，
        且每次构建后都用无头浏览器做一次真实渲染验证
        （见 docs/web-server.md 的验证步骤），
        而不是只跑 `vite build` 看它成功就完事。
      */
      AutoImport({
        // 自动导入 Element Plus 的 ElMessage / ElMessageBox 等以函数形式
        // 使用的 API —— 它们不能靠模板标签解析，必须显式导入。
        resolvers: [ElementPlusResolver()],
        dts: false,
      }),
      Components({
        resolvers: [ElementPlusResolver()],
        dts: false,
      }),
    ],
    resolve: {
      alias: {
        '@': fileURLToPath(new URL('./src', import.meta.url)),
        // 契约层：与 server/ 共用同一份常量，避免词表漂移。
        '@contract': fileURLToPath(new URL('../contract', import.meta.url)),
      },
    },
    server: {
      host: '0.0.0.0',
      // 端口走环境变量，便于与其他项目并存（方案 §8.2：端口可配置）。
      port: Number(env.VITE_PORT || 5173),
      /*
        ⚠️ 这一段是为了让 dev server 在 Windows 上不崩，理由值得写清楚。

        ## 症状

        编辑源码后 dev server 直接以 exit 1 退出：

          Error: EBUSY: resource busy or locked, watch
            '...\src\components\.StatsChart.vue.19224.<uuid>.tmpdir\StatsChart.vue.tmp'

        ## 原因

        编辑工具用「写临时文件 → 原子重命名」的方式改文件，
        临时目录是**源码目录下**的 `.<name>.<pid>.<uuid>.tmpdir`。
        Vite 用 chokidar 监听源码目录，会尝试 watch 这个瞬时目录；
        而 Windows 上该文件正被写进程独占，`fs.watch` 抛 EBUSY。
        关键点是**这个错误没有被捕获** —— chokidar 的 error 事件
        直接冒泡成未捕获异常，进程退出。

        ## 两处防护

        1. `ignored`：把这类临时路径排除，从源头减少触发机会；
        2. `usePolling`：改用轮询（stat）而不是 OS 级监听句柄。
           轮询**不会**因为文件被独占而失败 —— 它只是读元数据。
           代价是一点 CPU 与最多 `interval` 的延迟，对一个开发服务器
           完全可以接受，换来的是"改代码不会把服务器搞挂"。

        用 `awaitWriteFinish` 让变更在文件写完后再上报，
        HMR 不会读到写了一半的文件。
      */
      watch: {
        usePolling: true,
        interval: 300,
        awaitWriteFinish: { stabilityThreshold: 200, pollInterval: 100 },
        ignored: [
          '**/.*.tmpdir/**',
          '**/*.tmp',
          '**/.edge-profile/**',
          '**/.chrome-profile/**',
          '**/.probe-*',
          '**/*.log',
          '**/dist/**',
        ],
      },
      proxy: {
        '/api': {
          target: apiTarget,
          changeOrigin: true,
        },
      },
    },
    build: {
      // 产物目录交给部署脚本处理；sourcemap 关掉（生产不需要，也会泄露源码结构）。
      sourcemap: false,
      rollupOptions: {
        output: {
          /*
            ⚠️ 这里**不要**用 `manualChunks: { element: ['element-plus'] }`。

            我最初就是这么写的，本意是"把大库拆成独立 chunk，业务改动
            不让用户重下"。但实测它把按需引入的收益**完全废掉**：

              element chunk  1,022.09 kB（gzip 333.95 kB）

            原因：`manualChunks` 的数组写法会把 `'element-plus'` 当作
            模块入口解析，于是那个 barrel 文件（它 re-export 了
            **全部**组件）被整个纳入 chunk，并连带其全部依赖。
            Rollup 的 tree-shaking 在这个 chunk 里无从下手 ——
            入口模块导出的东西都算"被用到"。

            而去掉它之后，按需插件生成的 `element-plus/es/components/*`
            子路径导入就能被正常摇树，体积降一个数量级。

            教训：**分包配置会与 tree-shaking 相互作用**，
            不能假设"拆包只有好处"。分包前先看构建产物的实际大小。
          */
          manualChunks: undefined,
        },
      },
    },
  };
});
