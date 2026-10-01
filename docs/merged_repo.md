# micdn 合并仓库与单一入口设计（正式版 / 开发版）

本文说明 micdn 为什么让「正式版」与「开发版（maven SNAPSHOT / npm dev）」**共用一个 URL 入口、一个本地仓库根**，
两个通道的元数据如何合并，以及 npm 为什么不能像 maven 那样按目录拆分。使用方式与配置见
[README](../README.md)，与反向代理/缓存的协作见 [reverse_proxy.md](reverse_proxy.md)。

---

## 设计目标

- **消费方只配一个地址**：Maven 一个 `<repository>`、npm 一个 `--registry`，开发版不需要另加 endpoint。
- **本地只存一份**：备份、清理、容量统计、`/maven/` 与 `/npm/` 目录列表都只有一处。
- **差异只在回源上游**：正式版走 `<remote>`，开发版走 `<snapshot remote>` / `<dev remote>`；本地文件系统是唯一真相，
  交付路径不按通道分叉。
- **上游没配就不代理那个通道**：只发本地已装入/已缓存的文件，缺失即 404，绝不悄悄回落到另一个通道。

## 两个通道，一组配置

| 服务 | 正式版上游 | 开发版上游 | HTTP 入口 | 本地根 |
|------|-----------|-----------|-----------|--------|
| maven | `<maven><remote url>` | `<maven><snapshot remote>` | `/maven` | `<maven base>` |
| npm | `<npm><remote url>` | `<npm><dev remote>` | `/npm` | `<npm base>` |

```xml
<maven base="${micdn.home}/maven">
  <remote url="https://repo1.maven.org/maven2/" />
  <snapshot remote="https://oss.sonatype.org/content/repositories/snapshots/" />
</maven>
<npm base="${micdn.home}/npm">
  <remote url="https://registry.npmmirror.com" />
  <dev remote="https://registry.example.com/dev" />
</npm>
```

- `<snapshot>` / `<dev>` **只有 `remote` 属性、没有 `base`**：开发版不拥有独立目录树，和 `<maven base>` /
  `<npm base>` 共用。
- **`<maven>` / `<npm>` 元素只决定是否挂载端点**：未声明时不挂 `/maven`、`/npm`，但仓库仍有默认值（base `${micdn.home}/maven`、`${micdn.home}/npm`，上游 repo1 / npmmirror），`<jar>` / `<npm>` provider 与 `micdn install` 照常可用。
- 仓库前缀的根路径也是目录列表：缺尾斜杠（如 `/maven`）先 302 补 `/`。

## 本地布局与冲突分析

### maven：目录名天然区分

`{base}/{group 路径}/{artifact}/{version}/`。正式版 `.../1.0.0/`、快照 `.../1.0.0-SNAPSHOT/`，路径互不相交，
单根不会冲突。唯一跨版本共享的是 artifact 级 `maven-metadata.xml`（位于版本目录**之上**），这正是需要合并的地方。

### npm：一份 packument 承载全部通道

- packument：`{base}/{name}` 或 `{base}/@scope/{name}`——**URL 里没有版本**；
- tgz：`{base}/{scope|_}/{name}/{version}/{name}-{version}.tgz`；
- `versions` / `dist-tags` / `time` 全在同一份 packument 里，`dist.tarball` 也回到同一个 `/npm` 命名空间。

因此 npm 的两个通道**必须**写进同一份文档，无法按目录拆分（原因见「为什么 npm 拆不开」）。

## 元数据合并规则

总原则：**元数据由写入方产出、由交付方合并，文件系统是唯一真相。** 本地已有内容优先，上游只补空缺。

### npm packument：并入式落盘

`NpmRepo.fetchPackument` → `mergeUpstreamPackument`：

1. 新拉取的上游文档先落临时文件（`.<name>.incoming`），确认是合法 JSON 后才动本地文件，失败不影响已有副本；
2. 以**本地已有 packument 为准**：`versions` / `time` / `dist-tags` 只补入本地缺失的条目，顶层摘要字段
   （description、license、homepage、repository、bugs、keywords、readme、maintainers、author）只补空缺；
3. 随后 `refreshPackument` 按「合并后的版本集 + 本地 tgz 目录」重推 `dist-tags`：`latest` = 最高**正式**版；
   `dev` / `next` / `beta` / `rc` / `alpha` / `canary` 等通道 tag 指向对应通道的最高版本；仍指向现存版本的自定义
   tag 保留；同时把本地 tgz 的 `dist`（integrity / shasum / tarball）并回去；
4. 上游返回的不是合法 JSON 时退回「原样落盘」，绝不丢文档。

同名版本条目以先到的为准，它 `dist.tarball` 指向的 registry（正式版或 dev）因此是稳定的。

### maven 版本目录元数据：TTL 保鲜 + 别名

- `micdn install` 装入快照构件时扫描版本目录，写 `maven-metadata.xml`（`<snapshot><timestamp>` / `<buildNumber>`、
  `<snapshotVersions>`）与 `.sha1`——元数据与构件一样由写入方产出。
- 交付前 `GavRepo.refreshSnapshotMetadata`：路径位于 `*-SNAPSHOT` 版本目录时，按 TTL（`snapshotMetadataTtl`，
  默认 60 秒）从 `<snapshot remote>` 重取该 `maven-metadata.xml` 并尽力校验 `.sha1`；下载/校验失败**保留本地旧副本**。
- 别名请求（不带时间戳）由 `SnapshotRepo.latestAlias` 解析：取「元数据声明的最新构建」与「本地最新时间戳文件」中
  较新者；元数据刚刷新到上游新构建、文件尚未落入本地时直接 302 到该时间戳路径，后续请求再回源。响应带 `latest` 头。

### maven artifact 级元数据：本地快照并入

`{group}/{artifact}/maven-metadata.xml` 由正式版上游提供，`<versions>` 里只有正式版。本地若有 `*-SNAPSHOT` 版本目录，
`SnapshotRepo.mergeArtifactMetadata`：

- 追加缺失的本地快照版本（上游顺序保留，本地快照按 Maven 版本序升序）；
- `<latest>` 重算为全部版本的最大者（快照参与），让 `LATEST` / 版本范围能看到本地装入的开发版；
- `<release>` 沿用上游，上游没有则取最大非快照版本；
- `<lastUpdated>` 重写为当前 UTC；
- 版本集与 `<latest>` 都没变时**不重写**（幂等，避免每个请求刷新 sha1）；
- 没有本地快照版本 → 不改动，**字节级透传**上游元数据；上游也拿不到但本地有快照目录时，生成一份最小可用元数据。

## 回源路由（上游选择）

| 请求 | 分类器 | 上游 |
|------|--------|------|
| maven 构件 | `GavRepo.isSnapshotUri`（存在以 `-SNAPSHOT` 结尾的路径段） | 快照 → `<snapshot remote>`；其余 → `<maven><remote>` |
| npm tgz | `isDevVersionSpec`（原始规格） | 开发版 → `<dev remote>`；其余 → `<npm><remote>` |
| npm packument | 无法分类（URL 不含版本） | `allUpstreams()`：正式版优先、再 dev、去重，全部并入同一份 |

- **只认「段以 `-SNAPSHOT` 结尾」**而不是全文包含 `SNAPSHOT`：artifactId 里含 `SNAPSHOT` 的正式版（如
  `SNAPSHOTter-1.0.jar`）不会被误判成快照、走错上游。
- **开发版判定只认预发布标识**（dev / snapshot / local / nightly / test）或通道 tag（dev / next / beta / rc /
  alpha / canary）。`1.0.0-rc.1`、`19.0.0-beta.2` 是正式 registry 上正常发布的预发布版，不算开发版——若按「版本
  里有没有 `-`」路由，未配 `<dev>` 时会被判 404，比只代理正式版还差。
- **tgz 沿用原始规格选出的上游**（`upstreamsFor(spec)`）：tag `next` 解析成 `1.0.0-next.1` 后，版本标识已不属于
  开发标识，若在第二步重新判定就会「packument 取自 dev、tgz 去正式版找」。
- **packument 是唯一例外**：客户端只读我们发的那一份文档，dev 与 latest 两个 tag 必须同时齐全，因此交付路径
  把两个上游的文档都取回来并入同一份（`resolve` 侧则按 tag 所属上游按需拉取）。

## 省略配置的行为矩阵

| 通道 | 是否配 `<snapshot>` / `<dev>` | 本地有文件 | 结果 |
|------|------------------------------|-----------|------|
| 正式版 | —（`<remote>` 服务） | 有 | 直接发本地 |
| 正式版 | — | 无 | 按 `<remote>` 回源；仍无 → 404 |
| 开发版 | 配了 | 有 | 直接发本地（不回源） |
| 开发版 | 配了 | 无 | 按 `<snapshot remote>` / `<dev remote>` 回源；仍无 → 404 |
| 开发版 | 未配 | 有 | 直接发本地（`micdn install` 的产物无需外部 registry） |
| 开发版 | 未配 | 无 | **404**（不回落正式版上游） |

`<dev>` 未配置只影响「回源」，本地仓库与默认 base 始终可用（见上）。

两套上游互不回落：混着试会让「这个版本到底从哪来」不可预期。

## 缓存策略

| 内容 | `Cache-Control` | 原因 |
|------|-----------------|------|
| maven release 构件、npm release tgz | `public, max-age=31536000, immutable` | 版本号与内容一一对应 |
| `maven-metadata.xml*` | `public, no-cache` | 每次回源校验 |
| npm packument、npm 预发布 tgz（版本号含 `-`）、目录列表 | `public, no-cache` | 元数据随时变；开发版同版本号可能被覆盖重发 |
| maven SNAPSHOT 路径、`*.lastUpdated`、`resolver-status.properties` | `no-store` | 同一路径可能被重新发布覆盖 |

分别由 `mavenArtifactCachePolicy` / `npmArtifactCachePolicy` 判定；反代侧注意事项见
[reverse_proxy.md](reverse_proxy.md)。

## 为什么 npm 不能像 maven 那样按目录拆

| | maven | npm |
|---|---|---|
| 通道区分依据 | 版本目录名（`1.0.0` / `1.0.0-SNAPSHOT`） | 无版本路径（packument URL 不含版本） |
| 能否拆成两个根 | 构件路径互不相交，可行 | 不可行（一个包名只对应一个 URL） |
| 拆分代价 | artifact 级 `maven-metadata.xml` 需跨根合并 | 每次请求都要合并两份文档（虚拟 packument） |
| POM 的 `<releases>` / `<snapshots>` | 与目录布局无关，由客户端开关决定 | — |

- **maven** 若真拆两目录：构件没问题，但 artifact 级元数据只会落在其中一个根里，`<versions>` / `<latest>` /
  `<release>` 需要请求时跨两个根重算。
- **npm** 若 dev 另用一个 base：客户端请求 `/npm/foo` 只能命中其中一份文档；要同时看到 `latest` 与 `dev`，就得在
  请求期读两份文档再合并，等于把落盘时的合并搬进请求路径，成本更高且与 ETag / 304 冲突。

所以选择「一个根 + 落盘时合并」：合并只在拉取/发布时发生一次，交付路径就是发文件。

## 相关实现

- 入口：`src/micdn/routes.d`（`mountMaven` / `mountNpm`）
- maven：`src/micdn/maven/package.d`（`GavRepo.isSnapshotUri` / `upstreamsFor` / `refreshSnapshotMetadata`）、
  `src/micdn/maven/snapshot.d`（`SnapshotRepo.installSnapshot` / `latestAlias` / `mergeArtifactMetadata`）、
  `src/micdn/maven/web.d`（`MavenService`）
- npm：`src/micdn/npm/package.d`（`NpmRepo.upstreamsFor` / `allUpstreams` / `resolveVersion` / `fetchNpmTarball`）、
  `src/micdn/npm/packument.d`（`installTarball` / `mergeUpstreamPackument` / `refreshPackument`）
- 发布端点：`src/micdn/web/publish.d`（令牌校验）、`src/micdn/npm/publish.d`（`npm publish` 请求体）、
  `src/micdn/maven/publish.d`（原样落盘）——上传与 CLI 走同一套落盘/合并逻辑；未声明 `<publish>` 不挂 PUT，
  见 README「发布端点」
- CLI：`micdn install`
