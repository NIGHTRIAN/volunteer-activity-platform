# 同步服务镜像。
#
# ## 为什么用 Node 22 而不是更小的 alpine
#
# `node:sqlite`（本服务的默认存储驱动）是 Node 22+ 内置的。
# 用更老的版本会在启动时直接报错。alpine 变体也可以，但
# `node:sqlite` 依赖的 SQLite 在 musl 上需要额外验证 ——
# 这里选**更保守但一定能跑**的 debian 变体，
# 代价只是几十 MB 镜像体积，而一次"部署起来才发现跑不了"的代价更大。
#
# 若确认 alpine 可用，可换成 node:22-alpine 以减小体积。
FROM node:22-bookworm-slim

# 时区必须正确。
#
# 方案 §8.3 把时区列为硬要求，并注明原因：
#   "时间漂移会导致签到窗口与判定集体偏移"
# 而容器默认是 UTC。不设的话，签到窗口会整体偏 8 小时 ——
# 现场表现是"明明到点了却签不上"，且极难排查。
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

WORKDIR /app

# 先装依赖再拷源码：源码改动不会让依赖层失效，重建更快。
#
# 本项目**没有运行时依赖**（只用 Node 内置模块），
# 因此这一步在 sqlite 模式下几乎是空的。
# mysql2 是 optionalDependency，只有 DB_DRIVER=mysql 时才需要。
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund || true

COPY src ./src
COPY scripts ./scripts

# 数据目录：sqlite 模式下持久化到这里。
# 由 compose 挂载卷，容器重建不丢数据。
RUN mkdir -p /app/data
VOLUME ["/app/data"]

# 以非 root 运行。容器里用 root 是不必要的风险。
RUN useradd --system --uid 10001 --create-home appuser \
    && chown -R appuser:appuser /app
USER appuser

EXPOSE 8080

# 健康检查用 /api/health —— 它刻意不查库，因此不会把健康检查
# 变成数据库的压力源。
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# 启动前先建表（幂等），避免"忘了跑迁移"导致第一次请求 500。
CMD ["sh", "-c", "node scripts/migrate.mjs && node src/server.js"]
