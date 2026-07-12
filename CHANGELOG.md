# Changelog

## Unreleased

- CLI：`mount` 子命令更名为 `deploy`；相关函数与 manifest 字段 `deployedAt` 同步更名
- CLI：`deploy` / `resolve` 固定输出到控制台（info），不读 `micdn.xml` 的 `log-file` / `log-level`
- WWW：zip doc 支持 `auto-deploy="true"`，Linux 下 HTTP 服务运行期监听源 zip 变更并自动 deploy
- 部署：源 zip/tgz 已更新但进程不可读时保留已有解压目录，避免 auto-deploy 失败导致 404
- 内存：内置 `maxPoolSize=8M`、`heapSizeFactor=1.2`；移除 idle 定时 `GC.minimize`；metrics 显示 `gcCollections`

## v0.2.5 (2026-06-28)

- CLI：`micdn -f CONFIG resolve` 解析并安装全部 www/static（下载 jar/npm、解压 zip/tgz、校验 inner dir 与挂载目录）；不启动 HTTP
- 修复：`sendFiles` 小文件合并响应改用内存读出再写出，避免 `FileStream` 与 `bodyWriter` 组合触发 GC 句柄泄漏告警（静态资源逗号合并 URI）
- 运维：`/admin/metrics.json`（JSON）与 `/admin/metrics`（HTML 仪表盘，`views/metrics.dt`）只读指标，仅 localhost；指标逻辑合并于 `metrics.d`（含 idle GC、RSS/GC）
- 内存：内置 idle `GC.minimize`（每 15 分钟 tick；RSS ≥ 50MB 且在途请求 ≤ 200 时触发）；无 micdn.xml 配置、无 per-request `/proc` 钩子
- 依赖：vibe-http **1.5.1**、vibe-inet **1.3.1**、vibe-stream **1.4.1**、vibe-serialization **1.2.0**（`notls` 不变）

完整说明见 docs/release-v0.2.5.md

## v0.2.4 (2026-06-06)

- 挂载：manifest.json 快路径跳过未变更 jar/npm/zip；无效时删目录全量解压；`mount --force` 强制重装
- 可靠：挂载前目录可写探测；单 doc/bundle 失败不阻断 HTTP 启动
- 运维：systemd 启动限流兼容 el7/el8/Fedora；curl 下载单条日志
- 打包：AUR 文档；RPM/DEB 增加 home/vendor

完整说明见 docs/release-v0.2.4.md

## v0.2.3 (2026-06-05)

- WWW/SPA：www doc 改为 name 加 npm/dir/zip 属性；新增 try-file 深链接回退；缺失 JS/CSS 等静态资源不再被 HTML 顶替
- CLI：micdn mount www 或 static 可离线安装 doc 与 static bundle
- 启动：配置错误写 stderr，启动失败退出码 2，systemd 不再反复重启坏配置
- 安全：Maven/NPM/Blob/S3 路径校验，Zip 解压防穿越与 zip bomb，S3 SigV4 加固
- 其它：micdn.web.ext 统一扩展名判断，目录权限与 www 缓存策略简化

完整说明见 docs/release-v0.2.3.md

## v0.2.2 (2026-05-17)

- 去除重复的 CORS 响应头
- 修正 blob token 与时间校验
- 修正 blob 上传目录
- 支持 CRC32 比较文件（zip 增量解压）

## v0.2.1 (2026-04-14)

- 上传日志增加文件名
- blob 图片 Referer 同站匿名下载（publicImages）
- 按路径区分 HTTP 缓存策略（Maven、npm、static、blob、www）

## v0.2.0 (2026-01-28)

- 整合为一个整体的 micdn
- 添加了 S3 存储协议支持

## v0.1.5 (2026-01-19)

- 修正下载 https 资源
