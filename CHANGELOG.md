# Changelog

## 未发布

- **移除 `<repo>` 别名**：maven 配置只认 `<maven>`（此前 `<repo>` 也能被当成 `<maven>` 解析）。写 `<repo>` 的旧配置不再建库、不再注册 `/maven`，请改成 `<maven>`；`<repo>` 是 Maven 客户端 `settings.xml` 的标签，与 micdn 的配置语义无关，保留别名只会让两种格式混淆
- **修复**：仓库根路径 `/maven`、`/npm`、`/static` 一律 404——`ResourceUri` 用「段数组为 null」表示解析失败，而 D 的空数组字面量本身指针为 null，导致「零段」（仓库根）与「点段越界」被同等当成失败。改为显式 `invalid` 标志区分二者后，根路径回落到目录列表分支；缺尾斜杠（如 `/maven`）先 302 补 `/`（`micdn.web.directoryUri`，此前 `/static` 无尾斜杠时还会把目标拼成 `/static//`），保证列表页相对链接正确。尾斜杠改以原始请求为准（`decodeRepositoryUri` 会把空串补成 `/`，否则 `/maven` 会被当成 `/maven/` 直接列表）
- **npm 开发版上游**：`<npm>` 新增可选子元素 **`<dev remote="..."/>`**（属性形式，无 `base`）。开发版与正式版**共用** `/npm` 入口与 `<npm base>` 目录树，只在回源时按版本选上游（`NpmRepo.upstreamsFor`）：**dev/预发布版本只走 `<dev>` 的 remote，不再回落正式版 remote；正式版只走 `<npm>` 的 remote**。开发版判定为语义化预发布（含 `-`，如 `0.0.3-dev.2`）或预发布通道 tag（dev/next/beta/rc/alpha/canary），并支持 dist-tag 版本（`@xurp/manual@dev`）——先取 packument 的 `dist-tags` 解析成具体版本再取 tgz，部署目录名仍用配置里写的版本。省略 `<dev>` 时**开发版不代理上游**，只认本地已装入/已缓存的文件（`micdn install` 的产物无需外部 registry 即可被 `resolve` 与 `/npm` 找到）；packument 的 URL 不带版本，代理时按正式版 remote、再 `<dev>` 顺序探测（正式版优先、结果确定）
- **packument 合并**：一个包在本地只有**一份** packument（`{npm base}/{pkg}`），正式版与开发版共用。上游拉取（`NpmRepo.fetchPackumentFrom`，含覆盖式重取）与 `micdn install` 落盘后都会调用 `micdn.npm.packument.mergeLocalVersions`：以上游/已有 packument 为基础（保留其版本条目、绝对 tarball 地址与顶层字段），把本地 tgz 目录里的版本重算 `dist` 后覆盖同名条目，再按合并后的版本集重推 `dist-tags`（`latest` = 最高的正式版、通道 tag 同理、仍指向现存版本的自定义 tag 保留）。因此「开发版上游只有 dev tag、正式版上游只有 latest」不再互相遮蔽；本地一个 tgz 都没有时不重写上游 packument
- **maven SNAPSHOT 并入 `/maven`**：删除只读入口 **`/snapshot`**（`micdn.routes.mountSnapshot`），正式版与 SNAPSHOT **共用** `/maven` 与 `<maven base>`（`{base}/{group 路径}/{artifact}/{version}/`）。`<maven><snapshot remote="..."/></maven>` 配置 SNAPSHOT 专用上游：路径含 `SNAPSHOT` 的本地缺失构件与 `maven-metadata.xml` 按该上游回源（先 `.sha1` 再构件并校验，校验不过删除并 404），其余走 `<maven><remote>`，**两者互不回落**；省略 `<snapshot>` 时快照只发本地已装入的构件。不带时间戳的别名请求（`{artifact}-{version}-SNAPSHOT.{ext}[.sha1]`）`302` 到本地最新时间戳文件，`HEAD` 以 `latest` 头返回实际文件名（对标 sashub `SnapshotWS`），别名只在本地目录解析、不为此探测上游。`install` 子命令按扩展名分派：`.jar`/`.war`/`.pom` 装入 `<maven base>`，坐标取自 `META-INF/maven/**/pom.properties`（war 在 `WEB-INF/classes/` 下）→ 退 `MANIFEST.MF` 的 `Implementation-*`（`.pom` 直接解析 XML），写出 `.sha1` 并扫描版本目录重写 `maven-metadata.xml`；**只接受带时间戳的文件名**（`xxx-1.0.0-SNAPSHOT.jar` 这类未经 `mvn deploy` 的裸名拒绝），`--tag` 仅对 npm 有效
- **配置简化**：`<dev>` / `<snapshot>` 由子元素 `<remote>` 改为**属性** `remote`（`<dev remote="..."/>` / `<snapshot remote="..."/>`）；**未声明 `<maven>` / `<npm>` 元素就不挂载对应端点**（`MicdnConfig.maven` / `npm` 为 null，`MavenRepoConfig.defaultConfig()` / `NpmRepoConfig.defaultConfig()`、`snapshotBase`、`devRemotes` 一并移除，`resolve` 会提示 npm provider 需要 `<npm>`、jar provider 需要 `<maven>`）。`resources/micdn.xml` 与 `resources/micdn.xsd` 同步更新
- **npm 发布**：新增 `micdn -f CONFIG install PKG.tgz` 子命令——把本地 npm 包装入配置里的 `<npm base>`（`{scope|_}/{name}/{version}/`），并从 tarball 内的 `package/package.json` 生成/刷新 `{npm base}/{包名}` 的 packument：`dist.integrity`/`shasum` 由 tgz 字节算出，`dist-tags.latest` 取最高正式版，预发布按 `dev`/`next`/`beta`/`rc`/`alpha`/`canary` 自动打通道 tag，`--tag` 可再加一个自定义 tag（已有自定义 tag 在版本仍存在时保留）。`dist.tarball` 写 origin 占位符 `{origin}/npm/...`（不写死主机，交付时替换，见下条）。纯 D 实现（复用 `fs.tar.readTgzEntry` 内存内读单个 tar 条目），不再依赖宿主 `node`/`tar`，替换掉原先的 `scripts/npm_add.sh`
- **npm 交付**：packument 由发布方产出、micdn 只负责交付——`/npm/{pkg}` 发送 `{npm base}/{pkg}` 文件（包名路径标注 `application/json`）；本地没有该文件时按同一相对路径从上游 registry 拉取后发送（与 maven 侧 `GavRepo.fetch` 同口径，正式版 remote 优先、再 `<npm><dev>` 的 remote），micdn 不自行拼装元数据。交付前把 `{origin}` 占位符替换成请求 origin（见下条）；上游代理来的 packument 是绝对地址、不含占位符，原样发送。缓存头与 304 条件响应仍走 `handleCacheFile`（ETag/Last-Modified 与 `sendFile` 同口径）
- **请求 origin 推导**：新增 `micdn.web.origin.getOrigin`（对标 Beangle `RequestUtils.getOrigin`，反向代理场景取浏览器看到的那一侧——协议优先 `X-Forwarded-Proto`、主机优先 `X-Forwarded-Host`、端口优先 Host 自带值再退 `X-Forwarded-Port`，默认端口省略，IPv6 方括号保留）。本地发布与交付都不需要配置对外地址：`install` 只写 `{origin}` 占位符，交付时按访问请求推导
- **npm 缓存策略按路径细分**（`npmArtifactCachePolicy(uri)`）：正式版 tarball 仍 `public, max-age=31536000, immutable`；预发布/开发版 tarball（版本号含 `-`）与 packument、目录列表改 `public, no-cache`（同名版本可能被覆盖重发、元数据随时变）；`SNAPSHOT` 版本 `no-store`（与 maven 侧同口径）。用于非文件响应（目录列表）的 `applyCachePolicy` 一并补齐 `Cache-Control`/`Expires`
- **CLI**：子命令改为「第一个非选项参数」（`-f` / `--tag` 的值不参与识别，与 `-f` 的先后顺序无关），`-f` 指向的路径里含 `deploy`/`clean`/`install` 字样不再被误判；未知子命令直接报错退出，不再当成启动 HTTP 服务
- 文档：明确 `manifest.json` 是部署快路径的**唯一判据**（只比对源文件 `inner` / `size` / `mtime` / `artifact`，不看部署产物本身），以及部署产物被外部改动后不自愈的现象与手工恢复方式（`deploy … --force` + reload）。曾评估过“校验部署目录”（文件计数 / 目录指纹 / 目录 mtime）以自动重新部署，因复杂度和收益不成比例而放弃，详见 `docs/maintenance.md`

## v0.3.3 (2026-08-26)

- 修复：SIGHUP 热加载只生效一次——eventcore 事件回调为一次性消费（触发后即移除），`startSighupReloadThread` 改为在回调内重新挂载事件，`systemctl reload` 可持续触发（已本地连发两次 SIGHUP 冒烟验证）
- 修复：默认 maven/npm 仓库 base（`~/maven` / `~/npm`）改用 `expandTilde` 展开——配置未显式给 `base` 时不再在工作目录创建字面 `~` 目录
- 改进：www doc 未配置 `try-file` 时默认 `index.html`，SPA 深链接回退开箱即用；路径属性展开与 try-file 默认值均有单测覆盖

完整说明见 docs/release-v0.3.3.md

## v0.3.2 (2026-08-14)

- **解压**：tgz 解压改为纯 D 实现（新模块 `src/micdn/fs/tar.d`，`std.zlib` 流式解 gzip + 自实现 tar 解析），不再依赖宿主 `tar` 命令；支持 ustar / GNU longname（`L`）/ pax（`x`）扩展头、prefix 拼接、symlink/hardlink、mode 保留；防护与 zip 侧同口径——gzip 魔数、解压总量 ≤2GiB、条目 ≤2 万、绝对路径/`..`/超深超长拒绝、防经包内 symlink 写穿
- **下载**：`src/micdn/web/curl.d` 下载双后端，函数签名不变——默认调用宿主 `curl` 命令；`dub build -c executable-static` 走 `version(MicdnUseLibcurl)` 静态链接 libcurl（`etc.c.curl` 绑定，非 dlopen），不依赖宿主 curl/openssl
- **镜像**：scratch 静态镜像 `Dockerfile.scratch` + `scripts/build_scratch.sh` 改为**自编最小静态 libcurl**（builder 内 `autoreconf` + `./configure` 仅保留 openssl/zlib，规避 Alpine 预编译 `libcurl.a` 的 lld 链接问题；curl 源码需自备 `.curl-src/`）：产物全静态、**无任何动态依赖（连 musl loader 都不带）**，可拷到任意 x86_64 Linux 直接运行；镜像约 21.2MB（`/micdn` 全静态 + CA 证书），无 shell / apk / 调试工具
- 修复：`xi:include` 展开前先剥离 XML 注释，注释里的示例 include 不再误当真实指令导致配置加载失败
- 镜像：容器默认配置监听 `0.0.0.0:8888`（admin 仍 localhost-only），创建并 `chown` `/var/log/micdn`，默认配置可直接写日志
- 文档：README「运行时系统命令依赖」收敛为仅 `curl` 一个（静态构建则为零）；新增 `docs/build_static_portable.md` 静态构建与可移植性说明；`docs/build_linux.md` 补充交付前 `ldd` / RPATH / `libgcc_s` 依赖体检

完整说明见 docs/release-v0.3.2.md

## v0.3.1 (2026-08-14)

- 内存：文件响应改为 `FileStream` 流式写出（`maxWholeFileMemSend=0`），大文件不再整读入 GC 堆，降低堆峰值与分配抖动
- 内存：内置主动回收 `runGcMinimize`（`GC.collect` + minimize + glibc `malloc_trim`，musl 下 dlsym 探测自动跳过）：启动期重活后回收一次 + 每 10 分钟周期回收；内存快照与回收逻辑集中于 `micdn.runtime`
- 内存：reload 成功后立即 `runGcMinimize` 回收（与启动期重活后回收一致），旧路由/索引垃圾占用的 RSS 回落；reload 入口与结果打日志（`Config reload started` / `Config reload (SIGHUP|HTTP): ok` / `Reload GC reclaim`）
- 内存：GC `maxPoolSize` 调至 4M（同日 A/B：RSS 各阶段较 8M 低 5–8MB，四场景吞吐无回退）
- 运维：新增 `/admin/reclaim`（仅 localhost）按需回收，返回回收前后 RSS/HWM、GC used/free 与 `mallocTrim`
- 修复：`version (Linux)` 守卫改为 `version (linux)`，inotify watch、www auto-deploy、SIGHUP reload 在 Linux 真正编译启用；SIGHUP 经 eventcore 跨线程事件派发到事件循环执行
- 修复：`clean` 后重启不再为自建空目录输出 `Removing` 日志（部署可写性探测不创建目标目录）
- 文档：新增 `docs/reload.md` 配置热加载备忘（触发方式、工作流程、生效边界），`docs/maintenance.md` 补充链接
- 工程：压测脚本化——`scripts/stress_bench.sh`（四场景吞吐：目录/文件/404/gzip，预热 + 多轮取中位，记录 CPU 频率与 load）、`scripts/stress_mem.sh`（多文件内存，可选 `/admin/reclaim`）；移除旧 `scripts/stress_http.sh`

完整说明见 docs/release-v0.3.1.md

## v0.3.0 (2026-08-13)

- **Breaking**：www 移除 `<dir>` 挂载；`www.base` 下未挂 `<doc>` 的物理文件不再对外服务（404）；重复 doc name 配置报错
- **Breaking**：asset 移除逗号拼接 URI（`/a/b,c.js`）与 `sendFiles`；`AssetRepo.get` 返回 `AssetFile { bundle, path, info, isDir }`（非 `<dir>` bundle 走索引，dyna `<dir>` 走 stat）
- **Breaking**：`try-file` 收窄为单个文件名（不能含路径分隔符）；doc 路径段预计算到 `WwwDocConfig.segments`
- 新增：gzip 预压缩 sidecar 改为**部署期预压缩**（www doc `auto-gzip`、asset 非 `<dir>` bundle 强制，`path.gz` 原子落盘；移除后台压缩线程；`Accept-Encoding` 简化判定）
- 新增：`clean` 命令清除 www/static 部署目录（交互终端逐项 `y/N` 确认、`--yes` 跳过；maven/npm 下载缓存与 blob 数据不清理）
- WWW：doc 匹配改为 `WwwDocTree` 前缀树（O(段数) 查找，断链回退最长 doc 前缀）；`WwwRepo.get` 返回 `WwwFile { path, doc, info }`
- WWW：`<doc auto-gzip="false">` 按 doc 关闭 gzip（不发送已有 `.gz` 也不生成）
- **性能**：共享发布期文件索引（`FileIndex` 段树，www/asset 复用）：请求期存在性 / 目录折叠 / try-file 回退 0 stat；同一趟构建把 `path.gz` 大小挂到源文件节点（`gzSize`，gzip 请求期 0 stat）；autodeploy 重建；跳过 `*.gz`；索引构建汇总日志
- 内部：`sendFile` 改收 `IndexedFileInfo`（引用传递，含 `gzSize`）；新增 `IndexedFileInfo.fromFileInfo` 供 blob/npm/maven 等非索引调用方转换
- 内部：HTTP 入口统一解析为 `ResourceUri{segs, slashEnded}`（`getPath` → `getResourceUri`；`segmentPath`/`repositoryUri`/`repositoryPath` 收敛）；`WwwRepo.get`/`AssetRepo.get` 引用接收（另设值重载供测试直构）；防穿越收敛到入口，移除 `resolveRepositoryPath`
- 配置：仓库 base 解析即归一（`parseRepoBase`：空 base 报错，blob 补齐绝对路径）；`<bundle>`/`<bucket>` 名称校验（非空、无路径分隔符、非 `.`/`..`）
- 工程：压测复测指南与对比报告（`docs/stress_test.md` / `docs/stress_report.md`）
- 工程：移除 `vibe-d:web` 依赖（Diet 模板渲染由 `vibe-http` 提供 `render`）；清理 `dub.selections.json` 陈旧条目（`vibe-d`/`derelict-util`/`money`）
- 内部：gzip 模块并入 `micdn.web`
- 内部：gzip 预压缩是实际解压部署的一环——www `auto-gzip` 与 asset 非 `<dir>` bundle 在 manifest 快路径跳过解压时同样跳过预压缩（重复启动不扫描/补齐 sidecar）

完整说明见 docs/release-v0.3.0.md

## v0.2.6 (2026-07-12)

- CLI：`mount` 子命令更名为 `deploy`；manifest 字段 `deployedAt`（新写入；旧 `manifest.json` 快路径仍兼容）
- CLI：`deploy` / `resolve` 固定输出到控制台（info），不读 `micdn.xml` 的 `log-file` / `log-level`
- WWW：zip doc 支持 `auto-deploy="true"`，Linux 下 HTTP 服务运行期 inotify 监听源 zip 变更并自动 deploy
- 部署：源 zip/tgz 已更新但进程不可读时保留已有解压目录，避免 auto-deploy 失败导致 404
- 内存：内置 `maxPoolSize=8M`、`heapSizeFactor=1.2`；移除 v0.2.5 的 idle 定时 `GC.minimize`；metrics 显示 `gcCollections`、`gcMaxPoolSize`
- 运维：`scripts/stress_http.sh`（ApacheBench 压测脚本）
- 打包：`build_rpm.sh` / `build_deb.sh` / `build_srpm.sh` 默认 `dub clean` 并清空 `target/` 后全量构建（`build_common.sh`）；移除 `-f` 跳过逻辑

完整说明见 docs/release-v0.2.6.md

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
