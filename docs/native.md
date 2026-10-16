# native 发行包仓库（`/native`）

本文介绍 micdn 的 **native 发行包仓库**：GraalVM native-image 的发行包（`tar.gz`）与 bsdiff 增量补丁
（`.diff`）的存放、上传与下载。它是 v0.4.0 新增的端点，承接 sashub 时代的 `/repo/native`
（`NativeWS` / `NativeHelper`）。配置项与端点总览见 [guide.md](guide.md)，与正式版/开发版合流的设计见
[merged_repo.md](merged_repo.md)，与反向代理、缓存的协作见 [reverse_proxy.md](reverse_proxy.md)。

---

## 它是什么，不是什么

| | 说明 |
|---|---|
| 存什么 | native-image 发行包 `<name>-<version>[-<classifier>].tar.gz`，bsdiff 增量补丁 `<name>-<旧版本>_<版本>[-<时间戳>-<构建号>][-<classifier>].tar.gz.diff`，以及它们的 `.sha1`（`.sha256` 也照原样存） |
| 谁在用 | 客户端 [jstart](https://github.com/beangle/jstart) 的 `--remote`（默认 `https://sas.openurp.net/native`）；上传侧是 [beangle/build](https://github.com/beangle/build) 的 `NativeImagePlugin.nativeDistUpload` / `nativeDeltaUpload` |
| 怎么区分正式版/开发版 | 只按**版本目录名**（`{version}` 以 `-SNAPSHOT` 结尾即为开发版），**共用一个根** |
| 不是什么 | 没有 pom、没有 `maven-metadata.xml`、没有上游代理、没有 `.pending` 配对校验。native 构件是 tar.gz 而非 war/jar，没有 `MANIFEST.MF` 可解析坐标，**坐标完全由路径决定** |

因为「坐标 = 路径」，micdn 在 native 侧不做任何解析与改写：落盘路径就是请求路径，读路径只做目录列表与
「不带时间戳的补丁别名 → 最新时间戳文件」的解析。

---

## 本地布局

单根，maven2 布局 `{group 点转斜杠}/{artifact}/{version}/{文件名}`：

```text
${micdn.home}/native/
  org/beangle/ems/portal/4.20.13/
    portal-4.20.13-linux-amd64.tar.gz                 # 正式发行包（文件名不带时间戳）
    portal-4.20.13-linux-amd64.tar.gz.sha1
  org/beangle/ems/portal/4.20.14-SNAPSHOT/            # 开发版：同一个根，靠目录名区分
    portal-4.20.14-SNAPSHOT-linux-amd64.tar.gz        # 发行包同名覆盖（每次构建覆盖上一份）
    portal-4.20.14-SNAPSHOT-linux-amd64.tar.gz.sha1
    portal-4.20.13_4.20.14-SNAPSHOT-20260913.101500-1-linux-amd64.tar.gz.diff   # 补丁带时间戳
    portal-4.20.13_4.20.14-SNAPSHOT-20260913.101500-1-linux-amd64.tar.gz.diff.sha1
```

- **单根**：不像 sashub 的 `NativeHelper` 那样把正式版放 `~/.m2/repository`、开发版放 `~/.m2/snapshots`。
  两个根会让上传侧「先判版本再选根」、下载侧「两个根里找同一个构件」；单根后这些都退化成按路径读写。
  构建机的本地暂存仍可保持两库（`NativeImagePlugin.nativeRepoHome`），但**上传路径统一**为上面的形式。
- 发行包**不带时间戳**，同一版本反复构建就同名覆盖（与 Maven 的 SNAPSHOT 时间戳构件不同）；只有增量补丁
  在文件名里带 UTC 构建号，供同一 SNAPSHOT 版本多次构建并存。

---

## HTTP 端点

### 上传：`PUT /native/{仓库内相对路径}`

**全路径 URL**，不用 query string 传 `path`，也没有 sashub 的 `/upload` 一段；路径即坐标：

```bash
# 先传构件、再传它的 .sha1（顺序是约定，见下）
curl -T portal-4.20.14-SNAPSHOT-linux-amd64.tar.gz \
  -H "Authorization: Bearer $TOKEN" \
  http://micdn:8888/native/org/beangle/ems/portal/4.20.14-SNAPSHOT/portal-4.20.14-SNAPSHOT-linux-amd64.tar.gz
curl -T portal-4.20.14-SNAPSHOT-linux-amd64.tar.gz.sha1 \
  -H "Authorization: Bearer $TOKEN" \
  http://micdn:8888/native/org/beangle/ems/portal/4.20.14-SNAPSHOT/portal-4.20.14-SNAPSHOT-linux-amd64.tar.gz.sha1
```

- **需声明 `<auth publish-key="…"/>` 才挂 PUT**；令牌是唯一写权限凭据，可用 `Authorization: Bearer` /
  `Authorization: Basic`（用户名或口令任一同令牌）或 `X-Micdn-Token`，缺失/不符 `401` 并返回 Basic 挑战；
  与来源地址无关（本机反代下「对端为环回」区分不出远端请求）。只应经 HTTPS 暴露。
- **只做原子落盘**：先写同目录 `.incoming` 临时文件再 rename，同名覆盖；不解析内容、**不做构件与校验文件的
  配对校验**（sashub 的 `.pending` 暂存已取消），因此约定客户端**先传构件、再传 `.sha1`**——
  校验文件先到也不会被暂存，只是先落一个文件而已。
- 目录路径（尾斜杠）、含 `.`/`..` 的路径 `400`；超过 `<auth max-size>` 的请求体 `413`。

### 下载：`GET|HEAD /native/{仓库内相对路径}`

- 命中则发文件（`Content-Type` 按扩展名；`HEAD` 同路径无体）；缺失 `404`。
- 目录（含仓库根 `/native`）列出内容；缺尾斜杠先 `302` 补 `/`（列表页相对链接才正确）；目录的 `HEAD` 是
  `405`（与 `/maven` 同口径）。
- 没有回源：native 仓库不在 micdn 里做任何上游镜像，未同步到的构件就是 `404`（迁移期用上传或运维拷贝补齐）。

### 补丁别名：不带时间戳 → 最新时间戳文件

增量补丁的名字里带时间戳/构建号（`…-20260913.101500-1-linux-amd64.tar.gz.diff`），客户端不该先列目录再挑
最新，而是直接请求**不带时间戳**的别名 `…_4.20.14-SNAPSHOT-linux-amd64.tar.gz.diff`：

| 请求 | 响应 |
|---|---|
| `HEAD` 别名 | `200` + `latest: <实际文件名>` + `Last-Modified`（GMT，取该文件 mtime） |
| `GET` 别名 | `302` 到实际文件名（客户端跟随即可） |
| `HEAD` / `GET` 别名的 `.sha1` | 同一规则，匹配带 `.sha1` 的同名文件 |
| 无任何候选（如发行包本身、或该版本还没生成补丁） | 按普通文件处理：存在即发，不存在 `404` |

解析规则（`micdn.native.NativeRepo.latestAlias`）：

- 以**文件名里最后一个** `-SNAPSHOT` 为锚点切出前缀/后缀，中间必须形如 `yyyyMMdd.HHmmss-N`（`N` 为构建号）；
  为什么是「最后一个」：补丁名里时间戳前面还有**基准版本**（`portal-4.20.13_4.20.14-SNAPSHOT-…`）。
- 取时间戳最大者；时间戳相同则**构建号按数字比**（`…-9` 早于 `…-10`，不能按字典序）。
- 「发行包本身不带时间戳、不触发别名」是这一规则的自然结果（同目录没有能被前缀/后缀圈住的候选）。

`HEAD` 返回 `latest` 而不是直接给文件，是为了让 `curl -I -L` 这类探测（jstart 判断补丁是否存在，要求最终
`200`）既能拿到状态码，又能知道实际文件名。

---

## 配置

```xml
<!-- /native 的开关：与 <maven> / <npm> 同一套「元素即端点开关」规则，不写就不挂载 /native -->
<native base="${micdn.home}/native" />

<!-- 上传另需声明 <auth>；native 发行包常有几十 MB，max-size 要调到 128M 以上 -->
<auth publish-key="…" max-size="128M" />
```

| 配置 | 默认 | 说明 |
|---|---|---|
| `<native>` | 不声明 | 端点开关。未声明时不挂 `/native`，但默认仓库配置仍在（base `${micdn.home}/native`）；native 没有 provider 与 `install` 入口，`/native` 是它唯一的消费者 |
| `base` | `${micdn.home}/native` | 本地仓库根（单根，正式版与开发版共用）。发行包几十 MB 起，要挪到大盘时写这里 |
| `<auth publish-key>` | — | 挂 PUT 的开关与令牌；同 `/maven`、`/npm` |
| `<auth max-size>` | `64M` | 单次上传体上限，也是未配置 `<blob>` 时服务器的 `maxRequestSize`。**默认值装不下 native 发行包**（实测 ems-portal 约 53MB、otk-ws 约 62MB），要调到 `128M` 以上 |

`micdn install` 子命令只处理 npm 的 `tgz` 与 maven 的 `jar|war|pom`，**不处理 native 构件**；native 入仓只有
`PUT`（构建插件）或运维按布局拷贝两条路。

### 缓存策略

`micdn.web.cache` 的 `nativeArtifactCachePolicy`：路径含 `SNAPSHOT` → `no-store`（同名会被重新发布覆盖），
其余 → `public, max-age=31536000, immutable`（文件名即版本）。反代侧注意事项见
[reverse_proxy.md](reverse_proxy.md#native-发行包native与缓存)。

---

## 与构建 / 客户端集成

| 侧 | 用法 |
|---|---|
| 构建（beangle/build） | `nativePublishUrl := "https://sas.openurp.net/native"`（**基地址**，不是 sashub 的 `{path}`/`{fileName}` 模板），上传 URL = 基地址 + 仓库内相对路径 + 文件名，方法 `PUT`、认证 `Authorization: Bearer`（`~/.sbt/snapshot_credentials` 的 `token`）。`nativeDistUpload` 传归档 + `.sha1` + `.sha256`，`nativeDeltaUpload` 传最新补丁 + 其 `.sha1`，都是**先构件后校验**。详见其 `docs/native.md` |
| 客户端（jstart） | `--remote=https://sas.openurp.net/native`（即 `defaultDistRemote`），按 maven 布局取件；有本地基线时只下增量补丁（`HEAD` 探测别名 → 下载补丁 → bspatch → 用整包 `.sha1` 复核） |
| 迁移（sashub） | `/repo/native` 的 `NativeWS`（`POST /repo/native/upload/{path}` + Basic）与 `NativeHelper`（两库布局）已被本端点取代，可退役；两边存储互不影响，保留也不会冲突 |

---

## 实现

- 端点注册：`src/micdn/routes.d`（`mountNative`）、`src/micdn/main.d`（`<native>` 声明才挂，`<auth>` 声明才挂 PUT）
- 布局与别名：`src/micdn/native/package.d`（`NativeRepo` / `latestAlias`）
- HTTP：`src/micdn/native/web.d`（`NativeService`）
- 上传公共实现（maven 与 native 共用）：`src/micdn/web/publish.d`（`authorizeWrite` / `readUploadBody` / `storeUpload`；读门禁见 `authorizeRead` / `readNeedsToken`）
- 缓存策略：`src/micdn/web/cache.d`（`nativeArtifactCachePolicy`）
- 测试：`test/micdn/native/web_test.d`（上传令牌与全路径落盘、目录/404/405、补丁别名与构建号比较）
