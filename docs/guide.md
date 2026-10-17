# micdn 完整说明

> 这是 micdn 的详细文档（配置项、各端点语义、本地发布、gzip、下载与打包）。简洁英文版见 [README](../README.md)。

轻量 CDN / 静态资源服务：Maven、npm、WebJar/本地静态包、WWW 文档站点与 Blob 存储（含可选 S3 兼容 API）。配置驱动，单进程 HTTP。

**License:** GPLv3 · **Version:** 0.4.0

## 功能

| 服务 | 说明 |
|------|------|
| **static** | 从 Maven GAV（WebJar）、npm 包或本地目录部署前端资源，按 bundle 提供 |
| **www** | SPA/文档站：npm / zip；支持 `try-file`；zip 可 `auto-deploy`（Linux inotify） |
| **maven** | 本地缓存 + 上游 remote 拉取；正式版与 SNAPSHOT 共用 `/maven`，SNAPSHOT 可选独立上游（`<snapshot remote="..."/>`） |
| **npm** | 本地缓存 + 上游 registry 拉取；开发版（dev/预发布）可选独立上游（`<dev remote="..."/>`），与正式版共用 `/npm` |
| **native** | 原生发行包（native-image tar.gz）与增量补丁仓库；单根、无上游，`PUT /native` 发布、GET/HEAD 取件 |
| **blob** | 对象存储；可选 S3 兼容接口 |
| **admin** | localhost 只读指标 `/admin/metrics`、配置查看与 reload |

路径属性支持 `${micdn.home}` 与 `~` 展开。

## HTTP 端点

| 前缀 | 说明 |
|------|------|
| `/maven` | maven：本地缓存 + 上游 remote 拉取；SNAPSHOT 路径本地优先、缺失时按 `<snapshot remote>` 回源（版本元数据按 TTL 刷新），别名请求 302 到最新时间戳文件，本地快照版本并入 artifact 级元数据；`<auth publish-key>` 非空后可 PUT 上传（`mvn deploy`，见「上传（publish-key）」）。声明了 `<maven>` 才挂载；未声明时仍有默认仓库，见下 |
| `/npm` | npm registry（正式版与开发版共用）：packument（交付时替换 `{origin}` 占位符）与 tgz；`<auth publish-key>` 非空后可 PUT 上传（`npm publish`，见「上传（publish-key）」）。npm 侧**只实现发布**，不提供 unpublish / dist-tag / login / deprecate 等 npmjs 管理接口。声明了 `<npm>` 才挂载；未声明时仍有默认仓库，见下 |
| `/native` | native 发行包（tar.gz）与增量补丁（`.diff`）：单根、无上游，GET/HEAD 取件、目录可列出，不带时间戳的补丁别名 302 到最新的时间戳文件；`<auth publish-key>` 非空后可 PUT 上传（见「上传（publish-key）」）。声明了 `<native>` 才挂载；未声明时仍有默认仓库，见下 |
| `/static` | 静态资源（配置了 `<static>` 时） |
| `/blob`、`/s3` | 对象存储与 S3 兼容接口（配置了 `<blob>` 时） |
| `/admin` | 本机只读指标 `/admin/metrics`、配置查看与 reload |
| `/*` | www 兜底（配置了 `<www>` 时，按各 `<doc>` 名匹配） |

**`<maven>` / `<npm>` / `<native>` 元素只决定是否挂载对应端点**：未声明时 `/maven`、`/npm`、`/native` 不挂载，但仓库仍在——base 回落到 `${micdn.home}/maven`、`${micdn.home}/npm`、`${micdn.home}/native`，上游回落到 repo1 / npmmirror（native 没有上游），因此 `<jar>` / `<npm>` provider 与 `micdn install` 无需声明该元素（`config.mavenDeclared` / `config.npmDeclared` / `config.nativeDeclared`）。
`<native>` 目前没有 provider 与 `install` 入口，`/native` 是它唯一的消费者，所以要对外提供 native 下载/上传就显式声明 `<native/>`（或 `<native base="…"/>` 换本地根）。
仓库前缀的根路径也是目录列表：缺尾斜杠（如 `/maven`）先 302 补 `/`，避免列表页的相对链接从站点根解析；
`/maven/`、`/npm/`、`/native/` 直接列出本地仓库内容，便于核对缓存与本地装入（`micdn install`）的结果。

## 快速开始

```bash
# 依赖：ldc、dub（见 build_linux.md）
dub build --build=release-nobounds --compiler=ldc2

./target/micdn -f resources/micdn.xml          # 启动 HTTP
./target/micdn -f /etc/micdn/micdn.xml resolve # 解析并部署全部 www/static（不启动 HTTP）
./target/micdn -f /etc/micdn/micdn.xml deploy www manual
./target/micdn -f /etc/micdn/micdn.xml deploy static bootstrap --force
./target/micdn -f /etc/micdn/micdn.xml clean --yes # 清除 www/static 部署目录（交互终端下会逐项确认；maven/npm 缓存与 blob 数据不清理）
./target/micdn -f /etc/micdn/micdn.xml install build/xxx-0.0.2.tgz # 本地 npm 包入库并生成 packument
./target/micdn -f /etc/micdn/micdn.xml install target/x-1.0.0-20250803.132600-31.jar # 本地 maven SNAPSHOT 入库
```

`-f` 可为本地文件、目录（使用 `DIR/micdn.xml`）或 URL（下载到 `~/micdn.xml`）。

## 本地发布 npm 包

开发版/内网包不必发到公网 registry：把 `npm pack` 产出的 tgz 交给 **`micdn install`**，它按 npm 目录规范
装入配置里的 `<npm base>`（`{scope|_}/{name}/{version}/`），并在 `{npm base}/{包名}` 写出 packument 元数据。
**`install` 定位就是「本地仓库的安装」**：只读本机的构件文件（tgz / jar / war / pom）、只写本机的
`<npm base>` / `<maven base>`，不访问任何 registry 或远端仓库，也没有 `--registry` 之类的取远端参数；
要把包放到另一台机器，先 `install` 到本机仓库再随 `<npm base>` 目录一起同步过去。

```bash
npm pack                                                        # 产出 xxx-0.0.3-dev.1.tgz
micdn -f /etc/micdn/micdn.xml install xxx-0.0.3-dev.1.tgz --tag dev

# 消费方（registry 指向 micdn 的 /npm，见 reverse_proxy.md）
npm install @scope/xxx@dev --registry http://micdn:8888/npm/
```

本地版本的元数据全部由目录内容推导：`dist.integrity` / `dist.shasum` 由 tgz 字节算出，`dist-tags.latest` 取最高**正式**版
（预发布不会顶替 latest），预发布版本按 `dev` / `next` / `beta` / `rc` / `alpha` / `canary` 自动打通道 tag，
`--tag` 可再挂一个自定义 tag。若 `{npm base}/{包名}` 已有 packument（例如上游代理来的正式版），install 会**合并**
而不是覆盖：上游版本条目原样保留，本地版本覆盖同名条目。删掉 `{npm base}/{包名}` 后再 `install` 一次即可重建元数据。

`dist.tarball` 不写死主机，而是写成占位符 `{origin}/npm/@scope/xxx/-/xxx-0.0.3-dev.1.tgz`，由 npm 服务在**交付时**
替换成访问方看到的 origin，按请求推导（`Host` 与反代的 `X-Forwarded-Proto` / `X-Forwarded-Host` / `X-Forwarded-Port`）。
因此同一个 packument 对 `http://micdn:8888`、`https://cdn.example.com` 都能给出可用地址，不需要在配置里写死对外地址。
从上游 registry 代理来的 packument（含 `https://registry.npmmirror.com/...` 绝对地址）不做替换，原样发送。

## 开发版 npm 与上游（`<npm><dev remote="..."/>`）

正式版与开发版**共用** `/npm` 与 `<npm base>` 目录树，区别只在回源：`<dev>` 只配置开发版（dev/预发布）的上游 registry。
整个 `<npm>` 元素可省略，省略就不挂载 `/npm`。

```xml
<npm base="${micdn.home}/npm">
  <remote url="https://registry.npmmirror.com" />
  <dev remote="https://registry.example.com/dev" />
</npm>
```

- 回源按版本选上游（`NpmRepo.upstreamsFor`）：**开发版只走 `<dev>` 的 remote，不再回落正式版 remote**；正式版只走
  `<npm>` 的 remote。开发版 = 预发布**标识**是开发标识的版本（`0.0.3-dev.2`、`1.0-SNAPSHOT.1`，
  标识为 `dev`/`snapshot`/`local`/`nightly`/`test`，见 `developmentIds`）或预发布通道 tag
  （`dev`/`next`/`beta`/`rc`/`alpha`/`canary`），见 `isDevVersionSpec`。
  `1.2.0-rc.1`、`19.0.0-beta.2` 这类**正式 registry 上正常发布的预发布版**不算开发版（仍走正式版上游）——
  只按「版本里有没有 `-`」判定会把它们错误地路由到 `<dev>`，未配置 `<dev>` 时直接 404。
- `<dev>` 可省略：此时开发版**不代理上游**，只认本地已装入/已缓存的文件，缺失即 404。
  这也意味着开发版不必依赖外部 registry——`micdn install` 装入的包照样能被 `resolve` 与 `/npm` 找到。
- packument 的 URL 不带版本、无法判定开发版还是正式版，代理时按正式版 remote、再 `<dev>` remote 顺序探测
  （正式版优先，结果确定；同一 URL 重复配置只试一次）。
- 一个包在本地只有**一份** packument（`{npm base}/{包名}`），客户端只读我们发的这一份。`/npm` 的交付路径
  不带版本、判定不了来源，因此**把正式版与 `<dev>` 两个上游的文档都取回来并入同一份**
  （`NpmRepo.allUpstreams` + `mergeUpstreamPackument`：已有文件为准，上游文档只补缺失的版本/`time`/tag，
  再按合并后的版本集重推 `dist-tags`）——否则「开发版上游只有 `dev`、正式版上游只有 `latest`」会互相覆盖，
  `npm install <pkg>` 可能只看到 dev 版本。`resolve` 解析 dist-tag 时先读本地这份，本地没有该 tag 才按
  tag 所属的上游重新拉取（也是并入式落盘）；`micdn install` 落盘同样只合并不覆盖。
- 消费方把它当 registry 用即可：`npm install @xurp/manual@dev --registry http://micdn:8888/npm/`。
- 版本可以写具体版本，也可以写 dist-tag（`@xurp/manual@dev`、`@xurp/manual@latest`）：tag 先取 packument 的
  `dist-tags` 解析成具体版本，再按 npm 目录规范取 tgz（`{pkg}/-/{name}-{version}.tgz`）。
- 部署目录名仍是配置里写的版本（tag `dev` → `{static base}/{bundle}/dev/`），内容随 tag 指向的版本更新；
  是否重新解压仍按 tgz 的 mtime 判断（`manifest.json` 快路径）。

正式版与开发版为什么共用一个入口与一份 packument、上游文档如何并入，见
[merged_repo.md](merged_repo.md)。

## maven SNAPSHOT（同一个 `/maven`）

正式版与 SNAPSHOT **共用一个入口 `/maven`**，也共用 `<maven base>` 目录树（`{base}/{group 路径}/{artifact}/{version}/`），
按版本目录区分：路径段以 `-SNAPSHOT` 结尾（如 `.../1.0.0-SNAPSHOT/...`）的回源只走 `<snapshot remote="..."/>`，
其余只走 `<maven><remote>`，两者互不回落。只认「段以 `-SNAPSHOT` 结尾」而不是全文包含 `SNAPSHOT`，
artifactId 里含 `SNAPSHOT` 的正式版构件不会被误判成快照。
**省略 `<snapshot>`** 时快照不代理上游，只发本地已装入的构件（缺失即 404）：

```xml
<maven base="${micdn.home}/maven">
  <remote url="https://repo1.maven.org/maven2/" />
  <snapshot remote="https://oss.sonatype.org/content/repositories/snapshots/" />
</maven>
```

把 `mvn deploy` 产出的带时间戳构件交给 **`micdn install`**：

```bash
micdn -f /etc/micdn/micdn.xml install target/beangle-commons-5.0.0-20250803.132600-31.jar
```

坐标（groupId / artifactId / version）取自工件内部：`META-INF/maven/{group}/{artifact}/pom.properties`（war 在
`WEB-INF/classes/` 下），没有则退回 `MANIFEST.MF` 的 `Implementation-Vendor-Id` / `-Title` / `-Version`；`.pom`
直接解析 XML。install 会复制构件、写 `.sha1`，并扫描版本目录重写 `maven-metadata.xml`（`<snapshot>` 取最新时间戳，
`<snapshotVersions>` 列出最新构建的 jar/pom/classifier 等文件），元数据与构件一样由**写入方产出**，HTTP 侧只负责
发文件、解析别名，并在本地缺失且配了 `<snapshot remote>` 时回源。

快照元数据要跟着上游走，否则新 deploy 的构建永远不可见，因此：

- 版本目录的 `maven-metadata.xml` 按 TTL（`GavRepo.snapshotMetadataTtl`，默认 60 秒）从 `<snapshot remote>`
  重新探测；探测失败保留本地旧副本。别名（不带时间戳）取「元数据声明的最新构建」与「本地目录里最新的时间戳文件」
  中更新者——元数据刚刷新到上游新构建、文件还没落入本地时，别名直接 `302` 到该时间戳路径，后续请求再回源。
- artifact 级 `maven-metadata.xml`（`{group}/{artifact}/maven-metadata.xml`）如果本地有 `*-SNAPSHOT` 版本目录，
  会把这些本地快照版本并进 `<versions>` 并更新 `<latest>`，让 `LATEST` / 版本范围也能看到本地装入的开发版；
  没有本地快照版本时，该文件保持上游原样（字节级透传）。

消费方在 POM 里声明这个仓库即可：

```xml
<repositories>
  <repository>
    <id>micdn</id>
    <url>http://micdn:8888/maven</url>
    <snapshots><enabled>true</enabled></snapshots>
    <releases><enabled>true</enabled></releases>
  </repository>
</repositories>
```

别名（不带时间戳）请求 `...-1.0.0-SNAPSHOT.jar` 会 `302` 到同目录最新的时间戳文件，`HEAD` 则以 `latest` 头返回实际
文件名；`.sha1` 请求同样支持。快照构件的响应头为 `no-store`（同一路径可能被重新发布覆盖），
`maven-metadata.xml` 为 `public, no-cache`。

正式版与 SNAPSHOT 为什么共用一个 `/maven` 与一个仓库根、artifact 级元数据如何合并，见
[merged_repo.md](merged_repo.md)。

## native 发行包仓库（`/native`）

GraalVM native-image 的发行包（`tar.gz`）与 bsdiff 增量补丁（`.diff`）放在 **`/native`**（声明 `<native>` 才挂载，
承接 sashub 时代的 `/repo/native`）：**单根**，正式版与开发版共用同一个 base
（`{group 点转斜杠}/{artifact}/{version}/{文件名}`），靠版本目录名里的 `-SNAPSHOT` 区分，与 `/maven` 同口径。
native 构件没有 pom、也没有 `maven-metadata.xml`，坐标完全由路径决定，因此 micdn 在这里**不做任何元数据与
上游代理**（迁移期由上传或运维同步补齐）：

- 上传：`PUT /native/{仓库内相对路径}`——**全路径 URL**，不用 query string 传 path；需声明 `<auth>` 带令牌，
  约定**先传构件、再传 `.sha1`**（micdn 只做原子落盘，不做 sashub 时代的 `.pending` 配对校验）；
- 下载：`GET|HEAD /native/{仓库内相对路径}`；目录（含仓库根 `/native`）可列出；
- 不带时间戳的 `-SNAPSHOT` 补丁别名解析到同目录时间戳最新的同名文件（`HEAD` 用 `latest` 响应头返回实际文件名
  并给出 `Last-Modified`，`GET` 302 到该文件）；构建号按**数字**比较（`…-9` 早于 `…-10`）。

客户端（jstart 的 `--remote`，默认 `https://sas.openurp.net/native`）按 maven 布局取件；构建侧由
[sbt-native-image 插件](https://github.com/beangle/build) 的 `nativeDistUpload` / `nativeDeltaUpload` 上传。

```xml
<!-- /native 的开关；base 可省略（= ${micdn.home}/native），发行包几十 MB 起步，需要挪到大盘时写 base -->
<native base="${micdn.home}/native" />
```

路径含 `SNAPSHOT` 的构件响应 `no-store`（同名会被重新发布覆盖），其余为
`public, max-age=31536000, immutable`。**注意**：单次上传体上限由 `<auth max-size>` 决定（默认 `64M`），
而 native 发行包常有几十 MB（实测 ems-portal / otk-ws 约 53–62MB），部署时请把它调到 128M 以上。

单根布局、别名解析规则、与构建/客户端的对接、从 sashub 迁移等完整说明见 [native.md](native.md)。

## 读写访问控制（auth）

`<auth>` 是 `/maven`、`/npm`、`/native` 三个端点的**唯一鉴权来源**，接管它们的 GET/HEAD/PUT：

```xml
<!-- 读开放、只锁写（默认口径；只写 publish-key 与引入 <auth> 之前完全等价） -->
<auth publish-key="写令牌" max-size="64M" />

<!-- 读写都锁：download-key 非空后，「会写出文件体的 GET」必须带凭据 -->
<auth publish-key="写令牌" download-key="读令牌" max-size="128M" />
```

- `publish-key`：非空才挂载 **PUT** 上传（`npm publish` / `mvn deploy` / native 发行包）；不写就不挂 PUT，
  服务器上即使有反代也不会凭空多出写入口。
- `download-key`：**可选**。不写 = 读不认证（默认，与引入 `<auth>` 之前一致）；写了则构件、`.sha1`、
  `maven-metadata.xml`、npm packument 与 `.tgz` 等「文件型 GET」必须带同一凭据。
  **`HEAD` 与以 `/` 结尾的目录列表始终不设限**：`HEAD` 是 boot（`HttpUtils.isAlive`）与 jstart
  （`curl -I -L`）探测存在性/增量补丁的常规手段，目录列表只暴露「有什么」而不交出字节。快照/补丁别名
  与「补尾斜杠」的 302 都在鉴权之后才发出，因此别名 GET、以及不带尾斜杠的目录路径仍按文件型 URI 判定、
  需要凭据（只有它们的 HEAD 例外）。代价是仓库内容（包名、版本、文件名、大小）对未授权者可见，
  `download-key` 保护的是构件字节本身。
- `max-size`：单次上传体上限，**仅在 `publish-key` 非空时生效**，同时作为未配置 `<blob>` 时服务器的
  `maxRequestSize`（只配 `download-key` 不会抬高全局上限）。

两个 key 都只应经 HTTPS（或反代的 HTTPS 终止）暴露，并选用足够长的随机串；只写一个也合法，两个都空则配置期报错
（防 `publishkey=` 这类手误导致的「以为受控其实全开」）。完整说明与各客户端接法见 [auth.md](auth.md)。

### 上传（publish-key）

不必先 `npm pack` 再手动入库、也不必复制 maven 构件：声明 `publish-key` 后，`/npm`、`/maven`、`/native` 同时
接受 **HTTP PUT** 上传，把 `npm publish` / `mvn deploy` 指向 micdn 即可（本地开发、或带令牌推到远端实例）。
上传以**令牌**为唯一凭据：

- `Authorization: Bearer <token>`（npm 的 `_authToken`）、`Authorization: Basic <base64>`
  （用户名或口令任一与令牌相同，Maven 的 `settings.xml` server 凭据走这条）或 `X-Micdn-Token: <token>`；
- 缺失/不符返回 `401`，并带 `WWW-Authenticate: Basic` 挑战——Maven 收到挑战后会用 `settings.xml` 的凭据重试；
- **不限制来源地址**：令牌本来就与来源无关，前端开发机可以带令牌直接推给远端 micdn，反之本机发布也不用额外配置。

为什么不用「只接受本机」来兜底：本机反代（如 HAProxy 绑 `0.0.0.0:80` 转发到 `127.0.0.1:8080`，TCP 模式）会把
远端请求以环回源地址转给 micdn，报文里没有任何可区分的标记，那种判断等于没锁。代价是**密钥等同权限**
（`publish-key` 就是写权限、`download-key` 就是读权限）：这些端点只应经 HTTPS（或反向代理的 HTTPS 终止）暴露，
并选用足够长的随机串，避免 Bearer 凭据在明文链路上被读走。

npm——把令牌写进项目 `.npmrc`（或用 `--registry`/`--//…:_authToken` 临时给）：

```bash
# .npmrc
registry=http://127.0.0.1:8888/npm/
//127.0.0.1:8888/npm/:_authToken=s3cret
```
```bash
npm publish --tag dev        # PUT /npm/{pkg}
```

服务端按 npm publish 协议解析请求体（`_attachments` 内嵌 Base64 的 tgz），落盘并刷新 packument，逻辑与
`micdn install` 完全一致：`dist.integrity`/`shasum` 由 tgz 字节算出，`latest` 与通道 tag 自动推导，`--tag` 的
自定义 tag 写入 `dist-tags`，`dist.tarball` 写 `{origin}` 占位符、交付时替换。

npm 侧**只实现这一条写协议**：`PUT /npm/{包名}` 的 publish 文档（必须带 `_attachments`）。`npm unpublish`
（DELETE）、`npm dist-tag add/rm`、`npm login`/`adduser` 与 `npm deprecate` 等 npmjs 管理接口都不提供——
micdn 是发布/分发入口，不做包管理；发错了版本就重新发布或直接改本地 `<npm base>`。

maven——`~/.m2/settings.xml` 里配一个 server（`id` 与部署参数一致），再用 `mvn deploy` / `deploy:deploy-file`：

```xml
<server>
  <id>local</id>
  <username>micdn</username>
  <password>s3cret</password>
</server>
```
```bash
mvn deploy -DaltDeploymentRepository=local::default::http://127.0.0.1:8888/maven
mvn deploy:deploy-file -Durl=http://127.0.0.1:8888/maven -DrepositoryId=local \
  -Dfile=target/x-1.0.0-SNAPSHOT.jar -DgroupId=org.example -DartifactId=x \
  -Dversion=1.0.0-SNAPSHOT -Dpackaging=jar -DgeneratePom=true
```

服务端不解析内容：客户端自行生成带时间戳的文件名与 `maven-metadata.xml`，原样写入 `<maven base>`，随后
`/maven` 的读路径（快照别名 302、artifact 级元数据合并）即可照常服务。注意为某 SNAPSHOT 版本目录配置了
`<snapshot remote>` 时，写入的 `maven-metadata.xml` 会在 TTL 到期后被上游刷新覆盖（本地发布场景通常不配上游客）。

上限与状态码：单次上传体不超过 `<auth max-size>`（默认 `64M`，同时也是未配置 `<blob>` 时服务器的
`maxRequestSize`；配置了 `<blob>` 则沿用其 `max-size`），超出 `413`，请求体不合法 `400`，未授权 `401`。
PUT 只在声明了 `<maven>` / `<npm>` / `<native>` 的端点上注册。

配置就一段：

```xml
<auth publish-key="s3cret" max-size="64M" />
```

## 配置示例

```xml
<micdn home="/var/lib/micdn" listen="127.0.0.1:8080">
  <maven base="${micdn.home}/maven">
    <remote url="https://repo1.maven.org/maven2/" />
    <snapshot remote="https://oss.sonatype.org/content/repositories/snapshots/" />
  </maven>
  <npm base="${micdn.home}/npm">
    <remote url="https://registry.npmmirror.com" />
    <dev remote="https://registry.example.com/dev" />
  </npm>
  <static base="/var/cache/micdn/asset">
    <bundle name="bootstrap">
      <jar gav="org.webjars:bootstrap:4.6.1" />
    </bundle>
    <bundle name="local">
      <dir location="/srv/static/local" />
    </bundle>
  </static>
  <www base="/var/cache/micdn/www">
    <doc name="manual" zip="${micdn.home}/releases/manual.zip"
         inner="dist" try-file="index.html" auto-deploy="true" />
  </www>
  <blob base="${micdn.home}/blob" max-size="50M">
    <bucket name="local" key="..." />
  </blob>
  <!-- 读写访问控制：publish-key 非空才挂 PUT；download-key 可选，非空则构件 GET 需要凭据 -->
  <auth publish-key="s3cret" max-size="64M" />
</micdn>
```

bundle 支持两类 provider：`<jar>`/`<npm>` 解压部署并构建发布期索引；`<dir>` 以符号链接挂载源目录、不构建索引（也不参与 gzip 预压缩）。更完整的样例见 [`resources/micdn.xml`](../resources/micdn.xml)。

## gzip 预压缩

static / www 的文本类资源（js/css/html/svg/json 等）在**部署期**预压缩为 `path.gz` sidecar，请求期命中即直接发送（`Content-Encoding: gzip`、`Vary: Accept-Encoding`），无需请求期压缩：

- www doc 默认参与，可按 doc 设 `auto-gzip="false"` 关闭；asset 的 `<dir>` bundle 不参与（不生成也不发送，避免误用源目录自带的 `.gz`）。
- 小于 1KB 或超过 8MB 的文件，以及图片/字体等已压缩格式不生成 sidecar；`Range` 请求不返回 gzip。
- 与上游中间件（nginx / varnish / haproxy）的缓存、压缩协作部署见 [reverse_proxy.md](reverse_proxy.md)。

## 下载与 curl

远端下载（maven/npm/asset 与远程配置）统一由 `curlDownload` 完成，按编译开关选择实现（`src/micdn/web/curl.d`）：

| 构建方式 | 开关 | 下载实现 | 运行时依赖 |
|----------|------|----------|------------|
| `dub build` | 无 | 调用宿主 `curl` 命令 | 宿主需安装 curl |
| `dub build -c executable-static` | `version(MicdnUseLibcurl)` | 静态链接 libcurl | 不依赖宿主 curl/OpenSSL |

默认构建的运行时外部命令依赖**仅 `curl` 一个**（tgz 解压已内置，见 `src/micdn/fs/tar.d`），rpm/deb/AUR 打包相应声明 `Depends: curl`；静态构建产物适合容器与离线环境。下载先写 `.part` 临时文件、成功才改名，失败按 curl 退出码记日志。

## 安装与运维

| 文档 | 内容 |
|------|------|
| [build_linux.md](build_linux.md) | Linux 编译、RPM / deb / SRPM 打包 |
| [build_on_fedora.md](build_on_fedora.md) | Fedora 本地 RPM / SRPM 与 COPR 发布 |
| [build_container.md](build_container.md) | Podman / OCI 镜像 |
| [build_static_portable.md](build_static_portable.md) | 全静态构建与可移植性说明 |
| [build_aur.md](build_aur.md) | Arch AUR |
| [maintenance.md](maintenance.md) | systemd、`micdn`/`beangle` 权限、resolve/deploy、auto-deploy |
| [reverse_proxy.md](reverse_proxy.md) | nginx / varnish 缓存、haproxy 压缩等协作部署 |
| [merged_repo.md](merged_repo.md) | 正式版/开发版合并仓库与单一入口设计（元数据合并、回源路由、缓存策略） |
| [auth.md](auth.md) | 读写访问控制 `<auth>`：publish-key/download-key 语义、各客户端凭据接法、缓存降级与迁移 |
| [native.md](native.md) | native 发行包仓库 `/native`：单根布局、上传/下载与补丁别名、缓存、与构建/客户端对接 |
| [reload.md](reload.md) | 配置热加载 |
| [stress_test.md](stress_test.md) | 压测复测指南：环境、样例、场景与结果比较 |
| [release-v0.4.0.md](release-v0.4.0.md) | 当前版本说明 |

打包脚本（每次默认 `dub clean` + 清空 `target/` 后全量构建）：

```bash
./scripts/build_rpm.sh
./scripts/build_deb.sh
./scripts/build_image.sh
```

## 开发

```bash
dub test
```

要求：dub ≥ 1.34、LDC ≥ 1.32（见 `dub.json`）。Blob 元数据依赖 Linux `user.*` 扩展属性，完整功能请在 Linux 上验证。
