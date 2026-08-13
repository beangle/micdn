# Micdn v0.3.0 Release Notes

**发布日期：** 2026-08-13  
**对比基线：** [v0.2.6](https://github.com/beangle/micdn/compare/v0.2.6...v0.3.0)

---

## 概要

v0.3.0 在 v0.2.6 基础上：新增 **gzip 预压缩 sidecar**（**部署期预压缩**：www doc `auto-gzip`、asset 非 `<dir>` bundle 强制），www 的 doc 匹配重构为 **`WwwDocTree` 前缀树**（更快、更严），并按 doc 提供 **`auto-gzip` 开关**。www 与 asset 引入共享的 **发布期文件索引**：deploy 后构建段树索引，请求期存在性判定 0 stat，且同一趟构建把 `path.gz` 大小挂到源文件节点（gzip 请求期 0 stat）。同时移除了 www 的 `<dir>` 挂载与 asset 的逗号拼接 URI，收紧了服务范围，并统一了仓库 base 的绝对路径语义。

**`micdn.xml` 存在 Breaking Change**（见下方升级注意）：www `<dir>` 不再支持；重复 doc name 报错；`www.base` 下未挂 `<doc>` 的文件不再被服务；`try-file` 不再接受含 `/` 的路径。

共 **16 个提交**，**38 个文件**变更（+2252 / −286 行）。

---

## 亮点总结

| 类别 | 改进 |
|------|------|
| **性能** | gzip 预压缩改为部署期执行（www auto-gzip / asset 非 `<dir>` 强制），移除后台压缩线程；sidecar 大小随索引同趟登记（`gzSize`），请求期 gzip 0 stat |
| **性能** | 共享发布期文件索引（www/asset 复用）：请求期存在性 / 目录折叠 / try-file 回退 0 stat，四场景 RPS +10.8% ~ +87.5%（vs 基线 `490a455`） |
| **WWW** | doc 匹配改为 `WwwDocTree` 前缀树，O(路径段数) 查找，断链回退最长 doc 前缀 |
| **WWW** | `<doc auto-gzip="false">` 按 doc 关闭 gzip（不发送已有 `.gz` 也不生成） |
| **WWW** | `try-file` 收窄为单个文件名（不能含路径分隔符），解析期报错 |
| **Breaking** | asset 移除逗号拼接 URI（`/a/b,c.js`）与 `sendFiles`；`AssetRepo.get` 返回 `AssetFile { bundle, path, info, isDir }` |
| **可观测** | 索引构建输出汇总日志（文件/目录/符号链接数 + 耗时） |
| **安全** | `www.base` 下未挂 `<doc>` 的物理文件不再服务（404，且不读盘）；重复 doc name 配置报错；URI 防穿越收敛到 HTTP 入口（`getResourceUri`/`segmentPath`，返回 `ResourceUri{segs, slashEnded}`），移除 `resolveRepositoryPath` |
| **内部** | 仓库 base 统一绝对路径语义（config 解析归一校验 + 构造非空校验）；`<bundle>`/`<bucket>` 名称校验；gzip 模块并入 `micdn.web` |
| **工程** | 压测基建：`scripts/stress_http.sh` + 复测指南与对比报告 |

---

## 新功能

### gzip 预压缩 sidecar

static / www 部署的文本类静态资源（`js`、`css`、`html`、`svg`、`json`、`xml`、`txt`、`map` 等）采用「**部署期预压缩**」模式：

- 压缩只发生在部署期：www doc 默认参与（`auto-gzip` 开关），asset 非 `<dir>` bundle 强制启用；`precompressDir` 遍历目录生成 `path.gz`（写 `tmp` 后原子 `rename`，sidecar 已存在则跳过），无请求期竞争，也移除了后台压缩线程。
- 请求线程只读：`sendFile` 按调用方预取的 `IndexedFileInfo.gzSize` 判定——非 0 且客户端接受 gzip、无 `Range` 时发送 `path.gz`（`Content-Encoding: gzip`、`Vary: Accept-Encoding`）；`modified`/`flags` 复用源文件（gz 是源文件的编码表示，缓存元数据随源文件稳定）。
- `Accept-Encoding` 判定为简化实现：面向现代浏览器，仅按子串识别 `gzip`（大小写不敏感），不处理 `q=0` 拒绝与 `*` 通配等完备语义。
- 仅当压缩后确实更小才落盘；小于 1KB 或超过 8MB 的文件不压缩（保护性区间，避免无收益生成与大内存分配）。
- 已压缩格式（图片、字体、`.gz`/`.br` 等）不生成 sidecar；`Range` 请求不返回 gzip。
- asset 的 `<dir>` dyna bundle 完全忽略 gzip（不发送也不生成）。

详见 README「gzip 预压缩」。

### www doc 前缀树匹配与 per-doc `auto-gzip`

```xml
<www base="/var/lib/micdn/www">
  <doc name="manual" zip="/srv/releases/manual.zip" />
  <doc name="spa" zip="/srv/releases/spa.zip" try-file="index.html" auto-gzip="false" />
</www>
```

- doc 挂靠到 `WwwDocTree`（每节点一个单词段，每节点至多一个 doc）；请求按 URI 段逐级匹配，断链时回退到最后一个挂 doc 的节点。
- 未匹配到任何 doc 的请求**不访问文件系统**直接 404；`www.base` 下未挂 doc 的物理文件不再服务。
- `auto-gzip="false"` 时该 doc 完全忽略 gzip（不发送已有 `.gz` 也不生成），默认参与。
- `WwwRepo.get` 返回 `WwwFile { path, doc }`：doc 匹配但文件缺失时 `path` 为 null 且保留 `doc`，为 doc 粒度兜底（如自定义 404）预留。

### 发布期文件索引（共享 `FileIndex`，0 stat 存在性判定）

- 新增共享索引模块 `micdn.fs.index`：www 各 doc、asset 非 `<dir>` bundle 复用同一 `FileIndex` 段树；条目为轻量快照 `IndexedFileInfo`（类型标志 + size + mtime + gzSize）。
- **gz 信息随索引同趟登记**：构建时只读扫描目录，`.gz` 不建独立节点（不可寻址），仅把 `path.gz` 的**大小**挂到源文件节点（`gzSize`）；请求期一次 `find` 同时取得源文件与预压缩信息，gzip 命中 0 stat。
- www：请求期存在性、目录折叠 `index.html`、SPA `try-file` 回退全部查表（0 stat）；断链即 404，带静态扩展名的未命中不参与 try-file 回退。
- asset：`AssetRepo.get` 返回 `AssetFile { bundle, path, info, isDir }`，非 `<dir>` bundle 走索引（强制 gzip），`<dir>` dyna bundle 走单次 stat（忽略 gzip）。
- `sendFile` 改收 `ref const(IndexedFileInfo) info`（含 `gzSize`），blob/npm/maven 等非索引调用方经 `IndexedFileInfo.fromFileInfo` 转换。
- autodeploy 重新部署后经 `WwwService.invalidateDoc` 重建对应 doc 索引；运行期重建索引为纯只读扫描，不触发 gz 生成。
- 非 `build()` 构造的仓库（直接 `new WwwRepo`）仍走 stat 兜底路径（`resolveByStat`），解析语义一致。
- 启动日志输出**汇总**（非逐 doc/bundle）：`Built www file indexes: 1 docs, 6 files, 2 dirs, 0 symlinks in 0 ms`；asset 对应 `Built asset bundle indexes: 1 bundles, 6 files, 2 dirs, 0 symlinks in 0 ms`（autodeploy 单 doc 重建仍打单条 `Rebuilt www file index for doc 'xxx'`）。

### `try-file` 单文件约束

- `try-file` 只能是 doc 根下的单个文件名（如 `index.html`），不能含路径分隔符；含 `/` 的配置在解析期报错，构造期亦有断言。
- XSD 文档同步更新说明。

### 压测基建

- `scripts/stress_http.sh`：ab 包装（keep-alive，并发/总数参数）。
- `docs/stress_test.md`：复测指南（构建、样例、四场景命令、记录模板、方法论注意——跨场景命令口径不同，绝对 QPS 不可直接比较，需记录 CPU 频率）。
- `docs/stress_report.md`：三次演进（`490a455` → `8ddfd47` → 索引版）四场景吞吐对比。

### 性能数据（vs 基线 `490a455`，performance 调速器负载核 ~4.4 GHz）

| 场景 | 基线 | 索引版 | 提升 |
|------|------|--------|------|
| `/manual/` 最坏路径 | 19 991 | **37 491** | +87.5% |
| `/manual/app.js` 文件命中 | 10 278 | **16 588** | +61.4% |
| `/manual/nope.js` 404 | 13 626 | **15 101** | +10.8% |
| `/manual/app.js` gzip 命中 | 16 736 | **24 844** | +48.5% |

本轮已将 gz 信息并入索引（部署期预压缩 + `gzSize` 同趟登记，gzip 命中 0 stat）；表中数字为索引版数据，最新改动未重测。

---

## 行为变更

### www 移除 `<dir>` 挂载（Breaking）

`<doc … dir="…">` 不再支持，解析期直接报错；请改用 `npm` 或 `zip`。

### 服务范围收紧（Breaking）

`www.base` 下未挂载为 `<doc>` 的物理文件（含历史遗留内容）不再对外服务，请求返回 404。

### 重复 doc name 报错（Breaking）

同名（归一化后）doc 在 XML 解析期与树构造期都会报错，不再静默覆盖。

### `try-file` 不再接受路径（Breaking）

`try-file="fallback/index.html"` 这类带分隔符的配置此前可用，现在解析期报错；改为仅单个文件名。若需要回退到子目录文件，请调整部署结构（将回退文件放到 doc 根）。

### asset 移除逗号拼接 URI（Breaking）

`/a/b,c.js` 这类逗号合并多文件的写法不再支持（`AssetRepo.resolve` 与 `sendFiles` 已移除），请求按普通路径处理（含逗号的 URI 将 404）。`AssetRepo.get` 返回 `AssetFile`（含 `bundle`/`info`/`isDir`），语义与 `WwwRepo.get` 对齐。

### 其它

- 仓库 base（maven / npm / asset / blob / www）统一为绝对路径语义：`config.*.base` 解析即归一（`parseRepoBase`：展开 `${micdn.home}`/`~`、消解 `.`/`..`、显式空 base 报错），repo 构造时校验非空；blob base 一并补齐绝对路径归一（此前仅 `expandTilde`）。
- 配置校验：static `<bundle name>` 与 blob `<bucket name>` 要求非空、不含 `/` 或 `\`、不得为 `.`/`..`（与 www `<doc name>` 同档）。
- URI 防穿越收敛到 HTTP 入口：`getPath` 升级为 `getResourceUri`（切段 + 点段消解），返回 `ResourceUri{segs, slashEnded}`（段数组不再含尾斜杠空段，`slashEnded` 显式标记），读盘一律经 `repositoryPath` 构造物理路径；`resolveRepositoryPath` 已移除。
- gzip 模块由 `micdn.gzip` 移入 `micdn.web.gzip`（纯内部重构，无配置影响）。
- `WwwDocConfig` 新增预计算字段 `segments`（内部优化，无配置影响）。
- `sendFile` 签名变更：`FileInfo + gzFileInfo` 合并为 `IndexedFileInfo`（引用传递）；非索引调用方（blob/npm/maven）以 `fromFileInfo` 转换，行为不变。

---

## 升级注意

1. www 配置若使用 `dir`，需先改为 `npm` 或 `zip` 再升级。
2. 检查 `www.base` 下是否有未挂 doc 的历史文件——升级后这些路径将 404。
3. 检查配置中是否有重复 doc name（此前会静默后者覆盖前者）。
4. 检查 `try-file` 是否含 `/`，升级前改为单个文件名。
5. 检查 asset 请求是否依赖逗号拼接（`/a/b,c.js`），升级后需拆分请求或改用 bundle 内单文件。
6. 非必需：无需为 gzip 预压缩做任何配置；需要按 doc 关闭时使用 `auto-gzip="false"`。

---

## 测试

`dub test --compiler=ldc2`：**137 passed, 0 failed**。

新增/更新的覆盖：

- gzip：eligibility（白名单、大小区间、符号链接）、`precompressDir` 递归生成 / 跳过已存在 / 忽略不可压缩、sidecar 发送与回退、`gzSize` 语义（无 sidecar 不发）
- www：`WwwDocTree` 最长前缀 / 断链回退 / 空树 / 重复 endpoint；doc-only 服务（未挂 doc 文件 404）；try-file 与静态资源回退
- www：发布期索引服务（文件 / 目录折叠 / SPA / 404 0 stat）、索引先验直至 `rebuildIndex` 刷新、索引把 sidecar 大小挂到源文件节点（`a.js.gz` 不可寻址）、deploy 预压缩与 `auto-gzip=false` 跳过
- asset：`AssetFile` 索引命中（`gzSize` 挂载 / 小文件 0 / `.gz` 不可寻址 / 目录 / stale path 语义）、dyna `<dir>` stat 语义（忽略 gzip）、路径穿越防护
- config：`auto-gzip` 默认值、解析与 `parse → toXml → parse` round-trip；重复 doc name 拒绝
- config：`try-file` 含路径分隔符拒绝
- config：仓库 base 解析归一与空 base 拒绝；`<bundle>`/`<bucket>` 名称校验（非空、无路径分隔符、非 `.`/`..`）
