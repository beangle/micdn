# 读写访问控制（`<auth>`）

本文介绍 micdn 对 `/maven`、`/npm`、`/native` 三个端点的**读写访问控制**：谁来读、谁来写、用什么凭据、
哪些请求不设限，以及各客户端（npm / maven / jstart / boot / sas / beangle-build）怎么带这个凭据。
配置项总览见 [README](../README.md)，端点各自的语义见 [native.md](native.md) 与 [merged_repo.md](merged_repo.md)。

---

## 它是唯一的鉴权来源

```xml
<!-- 读开放、只锁写：与引入 <auth> 之前（<publish token="…"/>）完全等价 -->
<auth publish-key="写令牌" max-size="64M" />

<!-- 读写都锁 -->
<auth publish-key="写令牌" download-key="读令牌" max-size="128M" />

<!-- 只锁读（不挂 PUT）：适合只对外提供下载的实例 -->
<auth download-key="读令牌" />
```

| 属性 | 必填 | 说明 |
|---|---|---|
| `publish-key` | 否 | 上传令牌。非空才挂载 PUT（`npm publish` / `mvn deploy` / native 发行包与补丁），每次上传都必须携带 |
| `download-key` | 否 | 下载令牌。不写 = 读不认证（默认）；写了则「文件型 GET」必须携带（见下表） |
| `max-size` | 否 | 单次上传体上限（默认 `64M`），**仅在 `publish-key` 非空时生效**；未配置 `<blob>` 时同时作为服务器 `maxRequestSize` |

- 两个 key 都可与对方取同值（不额外约束），但都应是足够长的随机串。
- **至少一个非空**，否则配置期报错；属性写了但只有空白同样报错——避免 `publishkey=` 这类手误写成了
  「以为受控其实全开」。旧写法（驼峰 `publishKey`、以及 v0.4.0 早期的 `<publish token="…"/>`）不会被识别，
  按「两个 key 都为空」报错，不会静默降级。
- 凭据与来源地址无关：本机反代（如 HAProxy 绑 `0.0.0.0:80`，TCP 模式转发到 `127.0.0.1:8080`）会把远端请求
  以环回源地址转给 micdn，报文里没有可区分的标记，所以不提供「仅本机」这种退化判断。

## 哪些请求需要凭据

| 请求 | `download-key` 未配置 | 配置了 `download-key` |
|---|---|---|
| `PUT` | 不挂载（405），只看 `publish-key` | 同左 |
| `GET` 文件型 URI（构件、`.sha1`、`maven-metadata.xml`、packument、`.tgz`、`.tar.gz`/`.diff`） | 放行 | **要求凭据** |
| `GET` 目录型 URI（以 `/` 结尾，如 `/maven/`、`/npm/@xurp/`、`/native/org/`） | 放行（目录列表） | 放行（目录列表） |
| `GET` 不带尾斜杠的目录路径（如 `/maven/org/beangle/ems/4.20.14`） | 302 补 `/` | **要求凭据**（按文件型 URI 判定，授权后才 302） |
| `HEAD`（含快照/补丁别名，带 `latest` 响应头） | 放行 | 放行 |
| 302（补尾斜杠、快照/补丁别名） | 放行 | 放行（但触发它的那次 GET 可能已要求凭据） |

判定只依赖**方法 + URI 形状**，不 stat、不回源：

- `HEAD` 必须放行，否则 boot 的 `Repo.Remote.exists`（`HttpUtils.isAlive` 走 HEAD）选不了镜像、
  sas 的 `Resolver.access`（读 `latest` 头判断快照是否有更新）与 jstart 的 `curl -I -L` 探测全部失效；
- 目录列表放行是为了可浏览，代价是仓库内容（包名、版本、文件名、大小）对未授权者可见，
  `download-key` 保护的是构件字节本身；
- 未授权的 401 在触碰文件系统与上游**之前**产生，因此既不会为未授权请求抓取/落盘上游内容，
  也不会因为 404 与 401 的差异暴露某个路径是否存在；
- 不带尾斜杠的目录路径被判为「文件型」而要求凭据——这是保持判定简单、无存在性泄露的代价，
  浏览器手输时补一个 `/` 即可（或带上凭据）。

## 凭据怎么带

`Authorization: Bearer <key>`、`Authorization: Basic <base64>`（用户名或口令任一等于 key 即可，
兼容 Maven 的 `user:password` 习惯）或 `X-Micdn-Token: <key>`；缺失/不符返回 `401` 并带
`WWW-Authenticate: Basic realm="micdn"` 挑战（Maven 收到挑战后才会用 `settings.xml` 的凭据重试），
401 响应带 `Cache-Control: no-store`。读与写用同一套解析与比较（定长时间比较，避免泄漏前缀长度）。

### npm

`.npmrc` 里为这个 registry 配 `_authToken`（npm 对匹配的 registry **预置**发送该头，GET/PUT 都覆盖）：

```ini
registry=http://127.0.0.1:8888/npm/
//127.0.0.1:8888/npm/:_authToken=读或写的令牌
```

读用的 key 与写用的 key 不同时，本机开发可以备两个 `.npmrc`（例如项目内一份带 `publish-key`、
用户级一份带 `download-key`），或在 `npm publish` 时用 `--//127.0.0.1:8888/npm/:_authToken=写令牌` 临时覆盖。

npm 端点只接受 **publish**（`PUT /npm/{包名}` 带 `_attachments` 的发布文档）；`unpublish`/`dist-tag`/`login`/
`deprecate` 等管理接口一律不实现，因此 `_authToken` 在这里只用于「读受 `download-key` 限制」与「publish 校验
`publish-key`」两种用途，不涉及 npmjs 的账号体系。

### maven

`settings.xml` 的 `<server><id>` 与 `<repository>`/部署参数的 `id` 必须同名：

```xml
<server>
  <id>micdn</id>
  <username>micdn</username>   <!-- 任一侧等于令牌即可 -->
  <password>读或写的令牌</password>
</server>
```

Maven 首次拿到的必然是 401（wagon 先不带凭据请求），收到 `WWW-Authenticate: Basic` 后用上面的凭据重试，
所以读与写的配置形态一致。想省掉一次往返，可在 `<server>` 里用
`<configuration><httpHeaders><property name="Authorization" value="Bearer 令牌"/></property></httpHeaders></configuration>`
直接预置。

### jstart（native 与 sas 的 maven 构件下载）

jstart 用环境变量 `micdn_token` 携带令牌：`--remote` / `--snapshot-remote` 指向的仓库若要求
`download-key`，`fetch`、`resolve` 在下载构件与增量补丁时自动带 `Authorization: Bearer $micdn_token`
（`source/jstart/http.d`）；HEAD 探测不设限，所以「别名是否存在」的判断在无令牌时也能工作。
sas 的 maven 快照下载正是走这条路（见下节）。

### sas（maven SNAPSHOT 下载，经 jstart）

sas 自己不再下载构件：`conf/server.xml` 的 `<Repository>` / `<SnapshotRepo>` 把 `local` / `remote` / `token`
原样翻译成 jstart 的参数（`org.beangle.sas.tool.Jstart`），由本机 `jstart` 解析下载。token 一路这样传：

- `token` 属性取值建议写 `${sas_remote_token}` 占位，解析期由 `org.beangle.sas.config.Container.resolveToken`
  用实例本地环境变量展开——集中分发的配置里不出现明文，与既有的 `${sas_remote_url}` 互不影响；
  未设置该环境变量时不报错，只把令牌置空（受保护仓库随后 401）。
- `Jstart` 把令牌放进**子进程环境变量 `micdn_token`**，与 `--local` / `--remote` / `--snapshot-remote`
  一起交给 jstart；正式版与开发版上游是两条独立参数（SNAPSHOT 只走 `--snapshot-remote`）。
- 实际请求头由 jstart 侧加上（见上节）：GET 带 `Authorization: Bearer`，HEAD 探测保持匿名。

boot 无需改动：它照旧读本地仓库；快照的解析与下载由 sas 调 jstart 完成。

### beangle-build（上传 / 解析快照）

- 上传：`nativeDistUpload` / `nativeDeltaUpload` / `snapshotUpload` 用 `~/.sbt/snapshot_credentials`
  的 `token` 属性，以 `Authorization: Bearer` 发出（见 [NativeImagePlugin](https://github.com/beangle/build)）。
- 从受限的 `/maven` **解析**快照需要在项目侧给 sbt 配凭据：
  `credentials += Credentials("micdn", "<host>", "token", "<publish-key 或 download-key>")`
  （sbt/Ivy 会按 401 挑战重试）。

### micdn 自己

`micdn install`、`<jar>`/`<npm>` 等 provider 读的是**本地 base**，不经 HTTP，因此与 `<auth>` 无关；
`/static`、`/blob`、`/s3`、`/www` 也不受 `<auth>` 约束（blob 有自己的 bucket key）。

## 缓存

未配置 `download-key` 时，响应策略与以前完全一致（构件 `public, max-age=31536000, immutable` 等）。

配置了 `download-key` 后，**受保护的响应降级为 `private`，其余不变**（`no-store` 之类没有 `public` 前缀的
策略原样保留）：共享缓存按 URL 命中后会把响应交给未授权的请求者，`private` 让内容只进请求方自己的缓存
（RFC 9111 §3.2）。`max-age` 与 `Expires` 保持不变，客户端缓存仍然有效。反代/共享缓存层要做的配合
（nginx 默认不会因请求带 `Authorization` 就跳过缓存）见 [reverse_proxy.md](reverse_proxy.md)。

## 与发布端点（PUT）的关系

写路径的行为没有变化：`publish-key` 非空才挂 PUT，未声明即 405/未注册（见 README「上传（publish-key）」）。
`download-key` **不授予任何写权限**，`publish-key` 也不影响读（除非把它同时写进 `download-key`）。

## 从 `<publish token="…"/>` 迁移（v0.4.0）

v0.4.0 未发布时的早期写法是 `<publish token="…" maxSize="…"/>`，现已改为 `<auth publish-key="…" max-size="…"/>`，
属性名统一用连字符（与 `log-file` / `auto-gzip` 等一致）。同时 `<blob>` 的 `maxSize` 也改名为 `max-size`。
迁移就是改名 + 按需增加 `download-key`：

```diff
-<publish token="s3cret" maxSize="128M" />
+<auth publish-key="s3cret" download-key="read-only" max-size="128M" />
-<blob base="${micdn.home}/blob" maxSize="50M">
+<blob base="${micdn.home}/blob" max-size="50M">
```

## 实现

| 关注点 | 位置 |
|---|---|
| 配置解析与回写 | `src/micdn/config.d`（`parseAuth` / `parseAuthKey`），模型 `src/micdn/model.d`（`AuthConfig`、`MicdnConfig.publishEnabled/downloadGated`） |
| 令牌校验与读门禁 | `src/micdn/web/publish.d`（`authorizeWrite` / `authorizeRead` / `readNeedsToken` / `tokenAccepted`） |
| 端点挂载 | `src/micdn/main.d`（`publishEnabled` 决定是否 `registerEndpointGetHeadPut`；只配 `download-key` 不抬高 `maxRequestSize`） |
| 缓存降级 | `src/micdn/web/cache.d`（`gatedPolicy`），三个 service 的 `sendFile` / `sendPackument` 调用点 |
| 各端点的门禁位置 | `src/micdn/maven/web.d`、`src/micdn/npm/web.d`、`src/micdn/native/web.d`（PUT 分支之后、任何 fs/上游动作之前） |
