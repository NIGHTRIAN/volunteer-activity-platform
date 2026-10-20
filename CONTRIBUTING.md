# 参与贡献

先谢过。这个项目的定位是"**能在真实场景里跑起来的小系统**"，
所以下面这些比新功能更有价值：

- 在**别的机型 / 浏览器 / Windows 版本**上跑不起来，附上截图与报错
- 部署时卡住的步骤（尤其是防火墙、手机连不上）
- 判定逻辑被你找到的边界情况（比如定位漂移导致误判）
- 文档里说不清、看不懂的地方

## 环境

| 要改什么 | 需要 |
|---|---|
| 服务端 / Mock | Node.js ≥ 22.5（服务端零依赖，直接 `node src/server.js`） |
| 两个 App / 三个包 | Flutter 3.47.x、JDK 17、Android SDK 35+ |
| 网页 | Node.js ≥ 20.19、pnpm 或 npm |

Windows 上可以用 `tools\` 里的脚本省事：`flutter.cmd`、`dart.cmd`、`web.cmd`、`run-stack.cmd`。

## 跑起来

```bash
# 服务端
cp .env.example .env
cd server && npm start                      # http://127.0.0.1:8080

# 网页
cd web && npm install && npm run dev         # http://127.0.0.1:5173

# 两个 App（见 README「方式三」）
```

首次启动会写入 2 个演示活动；想清空重来：`node server/scripts/reset-demo.mjs`（破坏性，会删数据）。

## 提交前请自测

```bash
cd server               && npm test          # 152 项
cd mock_server          && node test/smoke.js  # 172 项
cd packages/shared_core && flutter test       # 228 项
cd packages/shared_ui   && flutter test       # 45 项
cd packages/shared_platform && flutter test   # 58 项
cd apps/user_app        && flutter test       # 23 项
cd apps/admin_app       && flutter test       # 29 项
```

外加每个包跑一次 `flutter analyze --fatal-infos`（要求零告警）。

## 几条约定

1. **契约先行**：错误码、状态、路径、评分权重只在 `contract/constants.js` 定义，
   不要在业务代码里写字面量。改了契约，服务端 / 两个 App / Mock 一起改，
   `server/test/routes.test.mjs` 会检查"客户端声明的路径服务端是否真的实现"。
2. **注释写"为什么"**：这个仓库的注释偏多是有意的——解释踩过的坑、被否掉的方案。
   改代码时如果推翻了某个决定，请把原因留在注释里，而不是删掉。
3. **测试写在 bug 旁边**：修一个 bug 就补一条能复现它的测试。
4. **不要提交**：`.env`、数据库文件、`dist/` 与 `build/` 产物、APK、日志。
   `.gitignore` 已经覆盖，但提交前扫一眼 `git status` 比较稳。

## PR

- 一个 PR 做一件事，标题说清"改了什么 + 为什么"
- 涉及界面改动的，附一张截图
- 说明你跑过哪些测试

## 行为准则

技术讨论可以激烈，对人不可以。不做人身攻击、不歧视、不骚扰。
