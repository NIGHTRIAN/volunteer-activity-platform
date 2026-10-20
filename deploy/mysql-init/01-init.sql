-- MySQL 初始化脚本。
--
-- `docker-entrypoint-initdb.d/` 下的脚本只会在**数据目录为空时**执行一次
-- （即首次启动）。所以这里只做"一次性初始化"，不做幂等的迁移 ——
-- 建表由服务端的 `scripts/migrate.mjs` 在每次启动时幂等执行。
--
-- 方案 §3：MySQL 5.7/8.0，**utf8mb4**（要存 emoji 与生僻字）。
-- 官方镜像的 MYSQL_DATABASE 已经会建库，这里补上字符集与权限，
-- 因为镜像默认建库时用的是 server 的默认字符集，
-- 而"默认字符集"在不同版本/镜像间并不一致。

-- 显式建库并锁定字符集（幂等）。
CREATE DATABASE IF NOT EXISTS `volunteer`
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_unicode_ci;

-- 授权。
-- 镜像启动时会用 MYSQL_USER/MYSQL_PASSWORD 建用户并授权到 MYSQL_DATABASE，
-- 但那是在执行本目录脚本**之前**完成的，且只授权到那一个库。
-- 这里再显式确认一次，避免库名与 MYSQL_DATABASE 不一致时连不上。
--
-- ⚠️ 不要在这里写死密码。用 % 允许容器网络内任意主机连接 ——
-- 该网络是 compose 创建的内部 bridge 网络，不对外暴露。
GRANT ALL PRIVILEGES ON `volunteer`.* TO 'volunteer'@'%';
FLUSH PRIVILEGES;

-- 说明：表结构不在这里创建。
-- 由 `node scripts/migrate.mjs` 在服务启动时建立（幂等，可重复执行）。
-- 这样做的好处是**只有一处** DDL 定义（server/src/db/schema.js），
-- SQLite 与 MySQL 共用同一份 schema 生成逻辑，不会两边漂移。
