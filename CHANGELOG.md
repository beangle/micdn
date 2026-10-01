# Changelog

## v0.4.0 (2026-10-02)

概要：正式版与开发版（maven SNAPSHOT / npm dev）合并为**一个入口、一个本地仓库根**，本地发布（`micdn install`）与上游代理共用同一份元数据；同时有一批修复、打包与文档更新。**Breaking**：`<repo>` 别名移除、未声明 `<maven>` / `<npm>` 不再挂载端点（v0.3.3 未声明时会挂默认仓库）、默认 base 由 `~/maven`、`~/npm` 改为 `${micdn.home}/maven`、`${micdn.home}/npm`。**新增（v0.3.3 没有）**：maven SNAPSHOT 支持（`<snapshot remote="..."/>`，与正式版共用 `/maven`）、npm dev 上游（`<dev remote="..."/>`）、npm packument 交付与本地发布、PUT 发布端点（`npm publish` / `mvn deploy`，需声明 `<publish token="..."/>`）。

### 配置

- **移除 `<repo>` 别名**：maven 配置只认 `<maven>`（此前 `<repo>` 也能被当成 `<maven>` 解析）。写 `<repo>` 的旧配置不再建库、不再注册 `/maven`，请改成 `<maven>`；`<repo>` 是 Maven 客户端 `settings.xml` 的标签，与 micdn 的配置语义无关，保留别名只会让两种格式混淆
- **新增开发版通道配置（纯增量）**：`<dev>` / `<snapshot>` 是本版新增的可选元素，采用**属性** `remote`（`<dev remote="..."/>` / `<snapshot remote="..."/>`），没有独立 `base`——两个通道与正式版共用同一个仓库根。v0.3.3 没有对应元素，无需迁移
- **`<maven>` / `<npm>` 元素只决定是否挂载端点**：未声明时不再挂载 `/maven`、`/npm`（Breaking：v0.3.3 未声明时会回落到 `MavenRepoConfig.defaultConfig()` / `NpmRepoConfig.defaultConfig()` 并始终挂载端点），但仓库本身仍在——base 回落到 `${micdn.home}/maven`、`${micdn.home}/npm`（v0.3.3 的默认 base 是 `~/maven`、`~/npm`，依赖旧目录时请显式声明并写 base），上游回落到 `https://repo1.maven.org/maven2`、`https://registry.npmmirror.com`，`<jar>` / `<npm>` provider 与 `micdn install` 无需声明该元素。`MicdnConfig.maven` / `npm` 不再为 null，改由新增的 `mavenDeclared` / `npmDeclared` 决定是否挂端点（配置查看 `toXml` 也只输出声明过的段落）。`resources/micdn.xml` 与 `resources/micdn.xsd` 同步更新；`snapshotBase` / `devRemotes` 一并移除

### npm

- **npm 开发版上游**：`<npm>` 新增可选子元素 **`<dev remote="..."/>`**（属性形式，无 `base`）。开发版与正式版**共用** `/npm` 入口与 `<npm base>` 目录树，只在回源时按版本选上游（`NpmRepo.upstreamsFor`）：**dev/预发布版本只走 `<dev>` 的 remote，不再回落正式版 remote；正式版只走 `<npm>` 的 remote**。开发版判定见下条（预发布标识 / 通道 tag），并支持 dist-tag 版本（`@xurp/manual@dev`）——先取 packument 的 `dist-tags` 解析成具体版本再取 tgz，部署目录名仍用配置里写的版本。省略 `<dev>` 时**开发版不代理上游**，只认本地已装入/已缓存的文件（`micdn install` 的产物无需外部 registry 即可被 `resolve` 与 `/npm` 找到）
- **packument 合并（并入式落盘）**：一个包在本地只有**一份** packument（`{npm base}/{pkg}`），客户端只读我们发的这一份。上游文档先下到临时文件，再由 `micdn.npm.packument.mergeUpstreamPackument` **并入**已有文件：已有条目为准，上游只补缺失的版本/`time`/自定义 tag 与空缺的顶层摘要字段，随后 `refreshPackument` 按「合并版本集 + 本地 tgz」重推 `dist-tags`（`latest` = 最高的正式版、通道 tag 同理、仍指向现存版本的自定义 tag 保留，本地 tgz 覆盖同名条目的 `dist`）。`/npm` 交付路径（`NpmRepo.allUpstreams`：正式版 remote + `<dev>` remote，去重）因此会把两个上游的文档都取回来合成一份——否则「开发版上游只有 dev tag、正式版上游只有 latest」会互相覆盖，`npm install <pkg>` 可能只看到 dev 版本；`resolve` 按 tag 取对应上游、`micdn install` 也从这份文件读出上游版本条目再合并。上游文档不是 JSON 时退回「原样落盘」，绝不丢掉刚拿到的 packument
- **npm 开发版判定收窄**：`isDevVersionSpec` 不再「版本里含 `-` 就是开发版」，而是看预发布**标识**（`1.0.0-dev.2` 的 `dev`，见 `developmentIds` = dev/snapshot/local/nightly/test）或规格本身是预发布通道 tag（dev/next/beta/rc/alpha/canary）。`1.2.0-rc.1`、`19.0.0-beta.2` 这类正式 registry 上正常发布的预发布版仍走正式版上游——按旧判定会被路由到 `<dev>`，未配置 `<dev>` 时直接 404。`resolve` 取 tgz 沿用**原始规格**选出的上游（`fetchNpmTarball` 传 `NpmRepo.upstreamsFor(versionSpec)`），tag `next` 解析成 `1.0.0-next.1` 后不会因为标识不在 `developmentIds` 而错配到正式版上游
- **npm 发布**：新增 `micdn -f CONFIG install PKG.tgz` 子命令——把本地 npm 包装入配置里的 `<npm base>`（`{scope|_}/{name}/{version}/`），并从 tarball 内的 `package/package.json` 生成/刷新 `{npm base}/{包名}` 的 packument：`dist.integrity`/`shasum` 由 tgz 字节算出，`dist-tags.latest` 取最高正式版，预发布按 `dev`/`next`/`beta`/`rc`/`alpha`/`canary` 自动打通道 tag，`--tag` 可再加一个自定义 tag（已有自定义 tag 在版本仍存在时保留）。`dist.tarball` 写 origin 占位符 `{origin}/npm/...`（不写死主机，交付时替换，见下条）。纯 D 实现（复用 `fs.tar.readTgzEntry` 内存内读单个 tar 条目），不再依赖宿主 `node`/`tar`
- **npm 交付**：packument 由发布方产出、micdn 只负责交付——`/npm/{pkg}` 发送 `{npm base}/{pkg}` 文件（包名路径标注 `application/json`）；本地没有该文件时按同一相对路径从上游 registry 拉取后发送（与 maven 侧 `GavRepo.fetch` 同口径，正式版 remote 优先、再 `<npm><dev>` 的 remote），micdn 不自行拼装元数据。交付前把 `{origin}` 占位符替换成请求 origin（见下条）；上游代理来的 packument 是绝对地址、不含占位符，原样发送。缓存头与 304 条件响应仍走 `handleCacheFile`（ETag/Last-Modified 与 `sendFile` 同口径）
- **npm 缓存策略按路径细分**（`npmArtifactCachePolicy(uri)`）：正式版 tarball 仍 `public, max-age=31536000, immutable`；预发布/开发版 tarball（版本号含 `-`）与 packument、目录列表改 `public, no-cache`（同名版本可能被覆盖重发、元数据随时变）；`SNAPSHOT` 版本 `no-store`（与 maven 侧同口径）。用于非文件响应（目录列表）的 `applyCachePolicy` 一并补齐 `Cache-Control`/`Expires`

### maven

- **maven SNAPSHOT（新增，v0.3.3 无此能力）**：正式版与 SNAPSHOT **共用** `/maven` 与 `<maven base>`（`{base}/{group 路径}/{artifact}/{version}/`），不设独立入口。`<maven><snapshot remote="..."/></maven>` 配置 SNAPSHOT 专用上游：**路径段以 `-SNAPSHOT` 结尾**（`GavRepo.isSnapshotUri`，而非全文包含 `SNAPSHOT`，artifactId 含 `SNAPSHOT` 的正式版不会被误判）的本地缺失构件与 `maven-metadata.xml` 按该上游回源（先 `.sha1` 再构件并校验，校验不过删除并 404），其余走 `<maven><remote>`，**两者互不回落**；省略 `<snapshot>` 时快照只发本地已装入的构件。`install` 子命令按扩展名分派：`.jar`/`.war`/`.pom` 装入 `<maven base>`，坐标取自 `META-INF/maven/**/pom.properties`（war 在 `WEB-INF/classes/` 下）→ 退 `MANIFEST.MF` 的 `Implementation-*`（`.pom` 直接解析 XML），写出 `.sha1` 并扫描版本目录重写 `maven-metadata.xml`；**只接受带时间戳的文件名**（`xxx-1.0.0-SNAPSHOT.jar` 这类未经 `mvn deploy` 的裸名拒绝），`--tag` 仅对 npm 有效
- **maven SNAPSHOT 元数据保鲜**：版本目录的 `maven-metadata.xml` 按 TTL（`GavRepo.snapshotMetadataTtl`，默认 60 秒）从 `<snapshot remote>` 重新探测，上游新 deploy 的构建才能被客户端解析到；探测/校验失败保留本地旧副本（不因上游抖动删缓存）。不带时间戳的别名（`{artifact}-{version}-SNAPSHOT.{ext}[.sha1]`）取「元数据声明的最新构建」与「本地目录里最新的时间戳文件」中更新者：元数据刚指向上游新构建、文件尚未落入本地时，别名直接 `302` 到该时间戳路径，后续请求再回源；`HEAD` 以 `latest` 头返回实际文件名（对标 sashub `SnapshotWS`）
- **maven artifact 级元数据合并**：本地有 `*-SNAPSHOT` 版本目录时，`{group}/{artifact}/maven-metadata.xml`（`SnapshotRepo.mergeArtifactMetadata`）把本地快照版本并进 `<versions>` 并重算 `<latest>`，让 `LATEST` / 版本范围也能看到 `micdn install` 装入的开发版；上游顺序保留、本地快照按版本序追加，`<release>` 沿用上游（缺失时取最大正式版），已经并入过则不重写以保持文件稳定。没有本地快照版本的 artifact 仍字节级透传上游元数据；上游也拿不到、但本地有快照目录时，可据此生成一份最小可用元数据

### 发布端点（publish）

- **发布端点（需显式声明 `<publish>`）**：声明 `<publish token="…"/>` 后 `/npm`、`/maven` 接受 HTTP PUT（`registerEndpointGetHeadPut`）——`npm publish` 与 `mvn deploy`（`-DaltDeploymentRepository` / `deploy:deploy-file`）可直接把产物推入仓库；**不声明则完全不挂 PUT**（只有 GET/HEAD），服务器上即便有反代也不会凭空多出写入口
- **令牌是唯一写权限凭据**：`Authorization: Bearer`（npm `_authToken`）、`Authorization: Basic`（Maven `settings.xml` server 凭据；实测客户端直接预置该头）或 `X-Micdn-Token`；缺失/不符 401 并带 `WWW-Authenticate: Basic` 挑战供 Maven 重试。**不限制来源地址**：本机反代（HAProxy 绑 `0.0.0.0` → `127.0.0.1:8080`，TCP 模式）下「对端环回」根本区分不出远端请求，而令牌与来源无关，前端开发机可带令牌直接推到远端实例。令牌等同写权限，故发布端点只应经 HTTPS 暴露
- **npm publish 协议**：`micdn.npm.publish.installPublishedPackument` 解析 npm 的 publish 文档（`_attachments` 内嵌 Base64 tgz），复用 `installTarball` 落盘并刷新 packument；`npm publish --tag` 的自定义 tag 写入 `dist-tags`，`latest` 与通道 tag 仍由 `refreshPackument` 推导。包名与 URI 不一致、非 JSON、缺附件、坏 Base64 一律 400
- **maven 上传**：`micdn.maven.publish.storeUpload` 把 PUT 请求体原子写入 `<maven base>`（临时文件 + rename），**不解析内容**——客户端自带的带时间戳文件名与 `maven-metadata.xml` 原样落盘，`/maven` 读路径的快照别名 302 与 artifact 级元数据合并照常生效；目录路径/点段 400
- **请求体上限**：上传体不超过 `<publish maxSize>`（默认 `64M`，`PublishConfig.maxSize`），非法请求体 400、超出 413；未配置 `<blob>` 时它同时作为服务器 `maxRequestSize`（vibe 默认 2 MiB 不够），配置了 `<blob>` 则沿用其 `maxSize`

### CLI 与交付

- **CLI**：子命令改为「第一个非选项参数」（`-f` / `--tag` 的值不参与识别，与 `-f` 的先后顺序无关），`-f` 指向的路径里含 `deploy`/`clean`/`install` 字样不再被误判；未知子命令直接报错退出，不再当成启动 HTTP 服务
- **请求 origin 推导**：新增 `micdn.web.origin.getOrigin`（对标 Beangle `RequestUtils.getOrigin`，反向代理场景取浏览器看到的那一侧——协议优先 `X-Forwarded-Proto`、主机优先 `X-Forwarded-Host`、端口优先 Host 自带值再退 `X-Forwarded-Port`，默认端口省略，IPv6 方括号保留）。本地发布与交付都不需要配置对外地址：`install` 只写 `{origin}` 占位符，交付时按访问请求推导

### 修复

- **修复**：仓库根路径 `/maven`、`/npm`、`/static` 一律 404——`ResourceUri` 用「段数组为 null」表示解析失败，而 D 的空数组字面量本身指针为 null，导致「零段」（仓库根）与「点段越界」被同等当成失败。改为显式 `invalid` 标志区分二者后，根路径回落到目录列表分支；缺尾斜杠（如 `/maven`）先 302 补 `/`（`micdn.web.directoryUri`，此前 `/static` 无尾斜杠时还会把目标拼成 `/static//`），保证列表页相对链接正确。尾斜杠改以原始请求为准（`decodeRepositoryUri` 会把空串补成 `/`，否则 `/maven` 会被当成 `/maven/` 直接列表）
- **修复：配置自身的 `remote` 属性不再被上游 remote 误读**：`extractRemoteUrl` 只扫描根 `<micdn ...>` 起始标签，`<snapshot remote="..."/>` / `<dev remote="..."/>` 不会被当成配置的远程配置 URL（此前会把上游地址当成配置来源去下载）

### 打包与工程

- **打包：版本号改为从 git tag 推导**：`dub.json` 去掉 `version` 字段（dub 从 tag `vX.Y.Z` / 分支 `~branch` 取版本，字段存在会让 registry 拒绝分支版本），`scripts/build_*.sh` 改用 `git describe --tags --abbrev=0`（去 `v` 前缀）并在无 tag 时报错；`docs/build_linux.md` / `container_build.md` / `build_aur.md` 的版本来源说明同步

### 文档

- 文档：明确 `manifest.json` 是部署快路径的**唯一判据**（只比对源文件 `inner` / `size` / `mtime` / `artifact`，不看部署产物本身），以及部署产物被外部改动后不自愈的现象与手工恢复方式（`deploy … --force` + reload）。曾评估过“校验部署目录”（文件计数 / 目录指纹 / 目录 mtime）以自动重新部署，因复杂度和收益不成比例而放弃，详见 `docs/maintenance.md`
- 文档：新增 [docs/merged_repo.md](docs/merged_repo.md)——正式版/开发版合并仓库与单一入口的设计（通道与配置、本地布局与冲突、npm packument 并入式落盘、maven 版本目录 TTL 保鲜与 artifact 级元数据合并、回源路由与缓存策略，以及 npm 为什么不能按目录拆分）。README 的功能/端点段落给出简要说明，`GavRepo` / `NpmRepo` / `SnapshotRepo` / `MavenService` / `NpmService` 的模块注释均指向该文

完整说明见 docs/release-v0.4.0.md

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
