# Micdn v0.4.0 Release Notes

**发布日期：** 2026-10-02
**对比基线：** [v0.3.3](https://github.com/beangle/micdn/compare/v0.3.3...v0.4.0)

---

## 概要

v0.4.0 的主题是「正式版与开发版合流」。v0.3.3 的 `/maven`、`/npm` 只服务正式版：maven 没有 SNAPSHOT 支持，npm
没有 packument 交付、也没有本地发布手段。本版把开发版（maven SNAPSHOT / npm dev）与正式版放回**同一个入口、
同一个本地仓库根**，差异只体现在回源上游；同时补上 npm 的本地发布（`micdn install`）与 packument 交付、maven
快照元数据的保鲜与合并。因为入口与配置语义有变化，本版是 **0.4.0**（含 Breaking Change）。

- **合并仓库与入口**：SNAPSHOT / dev 与正式版**共用** `/maven`、`/npm` 和同一个 base，按版本区分回源上游，
  不单设入口。
- **npm 通道（新增）**：`micdn install PKG.tgz` 本地发布（按目录内容生成/刷新 packument）；packument 交付
  （`/npm/{pkg}`）支持 `{origin}` 占位符（不写死主机）；dev 与 release 的上游文档**并入同一份** packument。
- **maven 快照（新增）**：`micdn install ARTIFACT.jar|war|pom` 装入带时间戳构件并写元数据；版本目录元数据按 TTL
  回上游保鲜，别名 302 到最新构建；artifact 级元数据并入本地 `*-SNAPSHOT` 版本。
- **发布端点**：声明 `<publish token="…"/>` 后 `/npm`、`/maven` 接受 PUT 上传（`npm publish` / `mvn deploy`）；
  令牌必需（未声明则不挂 PUT）。
- **配置**：移除 `<repo>` 别名；`<maven>` / `<npm>` 只决定是否挂端点，未声明时仍有默认仓库（provider 与 install
  仍可用），但不再挂 `/maven`、`/npm`。
- 另有仓库根路径 404 修复、CLI 子命令识别、npm 缓存策略细分、版本号改由 git tag 推导等。

详细设计（为什么共用一个根、npm 为什么拆不开）见 [merged_repo.md](merged_repo.md)。

---

## 版本评价

### 正式版与开发版合并为单一入口

- **maven SNAPSHOT（v0.3.3 无此能力）**：快照由 `/maven`（`{maven base}`）提供，按版本目录区分——路径段以
  `-SNAPSHOT` 结尾的走 `<snapshot remote="..."/>`，其余走 `<maven><remote>`，**两者互不回落**；省略 `<snapshot>`
  时快照只发本地已装入的构件。v0.3.3 完全没有 SNAPSHOT 相关配置与代码，因此这是纯新增能力而非入口迁移。
- **npm 开发版上游**：`<npm><dev remote="..."/>` 只配置开发版上游，本地目录同 `<npm base>`；`dev`/预发布版本只走
  `<dev>`，正式版只走 `<npm>` 的 remote，省略 `<dev>` 时开发版只认本地已装入/已缓存的文件。
- **npm packument 并入式落盘**（`mergeUpstreamPackument`）：上游文档先落临时文件，再以本地已有文件为准、只补缺失的
  版本 / `time` / 自定义 tag 与空缺的顶层字段，随后 `refreshPackument` 按「合并版本集 + 本地 tgz」重推 `dist-tags`。
  `/npm` 交付路径（`NpmRepo.allUpstreams`）会把正式版与 `<dev>` 两个上游的文档都取回来合成一份——否则「开发版上游
  只有 dev tag、正式版上游只有 latest」会互相覆盖，客户端可能只看到 dev 版本。
- **开发版判定收窄**（`isDevVersionSpec`）：只认预发布**标识**（dev / snapshot / local / nightly / test）或通道 tag
  （dev / next / beta / rc / alpha / canary）。`1.2.0-rc.1`、`19.0.0-beta.2` 这类正式 registry 上正常发布的预发布版
  不再被误路由到 `<dev>`；取 tgz 时沿用**原始规格**选出的上游，tag `next` 解析成 `1.0.0-next.1` 后不会换错来源。

### npm：本地发布与交付

- **`micdn install PKG.tgz`**：按 npm 目录规范装入 `<npm base>`（`{scope|_}/{name}/{version}/`），从 tarball 内的
  `package/package.json` 生成/刷新 `{npm base}/{包名}` 的 packument：`dist.integrity`/`shasum` 由 tgz 字节算出，
  `latest` 取最高正式版，预发布自动打通道 tag，`--tag` 可再挂一个自定义 tag。纯 D 实现，不再依赖宿主 `node`/`tar`。
- **packument 交付**：`/npm/{pkg}` 发送本地文件，缺失时按同一相对路径从上游拉取；交付前把 `{origin}` 占位符替换成
  请求 origin（`X-Forwarded-Proto` / `X-Forwarded-Host` / `X-Forwarded-Port`，再退 `Host`），本地发布不必配置对外地址。
- **缓存策略按路径细分**：正式版 tgz 仍 `public, max-age=31536000, immutable`；预发布/开发版 tgz 与 packument、目录列表
  改 `public, no-cache`；`SNAPSHOT` 版本 `no-store`。

### maven：SNAPSHOT（新增）

- **`micdn install ARTIFACT.jar|war|pom`**：坐标取自 `META-INF/maven/**/pom.properties`（war 在 `WEB-INF/classes/` 下）
  → 退 `MANIFEST.MF` 的 `Implementation-*`（`.pom` 直接解析 XML）；写出 `.sha1` 并扫描版本目录重写 `maven-metadata.xml`。
  **只接受带时间戳的文件名**（`mvn deploy` 的产物），`--tag` 仅对 npm 有效。
- **快照元数据保鲜**：版本目录的 `maven-metadata.xml` 按 TTL（`GavRepo.snapshotMetadataTtl`，默认 60 秒）从
  `<snapshot remote>` 重新探测，失败保留本地旧副本；别名（不带时间戳）取「元数据声明的最新构建」与「本地最新时间戳
  文件」中更新者，元数据刚指向上游新构建、文件尚未落本地时直接 302，`HEAD` 以 `latest` 头返回实际文件名。
- **artifact 级元数据合并**：本地有 `*-SNAPSHOT` 版本目录时，把本地快照版本并进 `{group}/{artifact}/maven-metadata.xml`
  的 `<versions>` 并重算 `<latest>`；上游顺序保留、`<release>` 沿用上游；已并入过则不重写。没有本地快照的 artifact
  仍字节级透传上游元数据。

### 发布端点（`<publish>`，令牌授权）

- **PUT 上传端点**：`/npm`、`/maven` 接受上传——`npm publish`、`mvn deploy -DaltDeploymentRepository=…`（或
  `deploy:deploy-file`）即可把产物推入本地仓库。**未声明 `<publish>` 不挂 PUT**（只有 GET/HEAD），服务器上即使
  有反代也不会凭空多出写入口。
- **令牌授权（不限制来源）**：`Authorization: Bearer`（npm `_authToken`）/ `Basic`（Maven `settings.xml` 的
  server 凭据）/ `X-Micdn-Token`；缺失或不符 `401` 并带 `WWW-Authenticate: Basic` 挑战，Maven 收到挑战后会带
  凭据重试（实测客户端本就预置该头）。不按对端地址限制：同机反代（HAProxy 绑 `0.0.0.0` 转发到 `127.0.0.1:8080`，
  TCP 模式）下远端请求的对端同样是环回且报文无可区分标记，令牌才是可靠凭据，也因此可以让开发机带令牌直接推到
  远端实例。令牌等同写权限，发布端点只应经 HTTPS 暴露。
- **npm**：按 publish 协议解出 `_attachments` 内嵌的 Base64 tgz，复用 `installTarball` 落盘并刷新 packument，
  `--tag` 写入 `dist-tags`。**maven**：PUT 请求体原样原子写入 `<maven base>`，客户端自带的带时间戳文件名与
  `maven-metadata.xml` 直接可用。上传体不超过 `<publish maxSize>`（默认 `64M`，超出 `413`），非法请求体 `400`。

### 配置、CLI 与工程

- **`<repo>` 别名移除**：v0.3.3 的 `parseMaven` 会把 `<repo>` 也当成 `<maven>`（`children(micdnDom, "repo")`），
  本版只认 `<maven>`（`<repo>` 是 Maven 客户端 `settings.xml` 的标签，与 micdn 的配置语义无关）。
- **`<maven>` / `<npm>` 只决定是否挂端点**：v0.3.3 未声明时回落到 `MavenRepoConfig.defaultConfig()`
  （`~/maven` + repo1）/`NpmRepoConfig.defaultConfig()`（`~/npm` + npmmirror），并**始终挂载** `/maven`、`/npm`；
  本版未声明则不挂端点，但仓库仍有默认值（base `${micdn.home}/maven`、`${micdn.home}/npm`，上游 repo1 / npmmirror），
  `<jar>`/`<npm>` provider 与 `micdn install` 无需声明该元素。配置查看（`toXml`）只输出声明过的段落。
- **CLI**：子命令改为「第一个非选项参数」（`-f` / `--tag` 的值不参与识别），未知子命令直接报错。
- **版本号来自 git tag**：`dub.json` 去掉 `version` 字段，`scripts/build_*.sh` 用 `git describe --tags --abbrev=0`，
  无 tag 直接失败。
- **修复**：仓库根路径 `/maven`、`/npm`、`/static` 不再 404（`ResourceUri` 用显式 `invalid` 区分「零段」与解析失败），
  缺尾斜杠先 302 补 `/`；`extractRemoteUrl` 只扫描根 `<micdn>` 标签，`<snapshot remote>` / `<dev remote>` 不再被误当成
  配置自身的远程 URL；`manifest.json` 明确为部署快路径的唯一判据。

---

## 升级注意

**必读（Breaking）**

1. **`<repo>` 不再当成 `<maven>`**：写 `<repo>` 的配置不再建库、不再注册 `/maven`，请改成 `<maven>`。
2. **`<maven>` / `<npm>` 未声明不再挂端点**：`/maven`、`/npm` 不会注册（v0.3.3 未声明时会挂一个默认仓库）。仓库本身仍在
   （默认 base `${micdn.home}/maven`、`${micdn.home}/npm`），provider 与 `micdn install` 照常工作；要对外提供
   registry/repository，请显式声明 `<maven/>` 或 `<npm/>`（可带 `base`）。
3. **默认 base 变更**：v0.3.3 未声明时的默认 base 是 `~/maven`、`~/npm`；本版回落到 `${micdn.home}/maven`、
   `${micdn.home}/npm`。依赖旧默认目录（例如沿用 `~/npm` 的缓存）时，请显式声明元素并写 base：`<npm base="~/npm">`
   （显式写 `~` 仍会展开）。要对外提供 repository/registry，也需要显式声明 `<maven/>` / `<npm/>`。
4. **打包脚本要求仓库存在 git tag（`vX.Y.Z`）**：无 tag 时 `scripts/build_*.sh` 直接报错。

**新增能力（v0.3.3 完全没有，纯增量、可不配置）**

- maven SNAPSHOT：`<maven><snapshot remote="https://.../snapshots"/></maven>`，快照与正式版共用 `/maven`；消费方
  POM 里一个 `<repository>` 指向 `/maven` 并同时开启 `<releases>` 与 `<snapshots>` 即可取到两版。
- npm dev 上游：`<npm><dev remote="https://.../dev"/></npm>`，开发版与正式版共用 `/npm`。
- npm 本地发布：`micdn -f CONFIG install PKG.tgz`（预发布自动打通道 tag）。

> `<snapshot>` / `<dev>` 都是本版新增的可选配置，采用属性形式 `remote`、无独立 `base`；v0.3.3 没有对应元素，
> 无需迁移。

**行为变化（不破坏兼容）**

- npm 开发版判定收窄：`1.2.0-rc.1` 这类预发布版现在走正式版上游，需要它们走 dev 上游时应使用 dev 标识版本
  （`1.2.0-dev.1`）或通道 tag（`@pkg@rc`、`@pkg@next`）。
- SNAPSHOT 版本目录的元数据会按 TTL（默认 60 秒）产生周期性回源；反代侧需放行（见 [reverse_proxy.md](reverse_proxy.md)）。
- 容器镜像标签由构建脚本从 git tag 推导（`micdn:0.4.0` / `micdn:0.4.0-scratch`）。

---

## 提交统计

v0.4.0 相对 v0.3.3 共 14 个提交 + 发布提交，其后又补齐发布端点（PUT 上传）2 个提交：

- `f179186` simplify readme（文档精简）
- `0d9a4d3` Derive package version from git tag instead of dub.json（版本号改由 git tag 推导）
- `069d5f2` Document that manifest.json is the sole deploy fast-path criterion
- `c3e5cd6` Deliver npm packument from file, proxy it from upstream when absent
- `a65a74a` Add "micdn install" to publish local npm packages
- `5a5eb25` Parse the subcommand as the first non-option argument
- `6392568` Derive packument tarball urls from the request origin（`getOrigin` + 交付期替换）
- `0aa0704` Serve a local Maven SNAPSHOT repository at /snapshot（`1823161` 改为并入 `/maven`）
- `1823161` Serve dev and SNAPSHOT versions from the shared /maven and /npm entries（合并入口与目录、`<dev>`/`<snapshot>` 属性化、仓库根 404 修复）
- `3d5cef1` Add the merged repository and single-entry design document（`docs/merged_repo.md`）
- `ed28ab4` Merge upstream packuments across the npm release and dev channels（并入式落盘、判定收窄）
- `aa0f713` Refresh and merge maven SNAPSHOT metadata on delivery（TTL 保鲜、artifact 级合并）
- `30d4557` Document merged release/dev channels in README, changelog and proxy notes
- `deb3905` Make <maven>/<npm> sections control endpoint mounting only（未声明元素不再挂端点，但保留默认仓库）
- `e62c4e5` Release 0.4.0（版本号提升至 0.4.0、changelog 与本文档定稿）
- `0e78ab2` Add npm and maven publish (PUT upload) endpoints（发布端点实现）
- `ccbb748` Test the publish endpoints, token gate and upload limits（发布端点测试）
- 本次文档提交：release notes 补记发布端点与提交统计

---

## 测试

`dub test --compiler=ldc2`：**215 passed, 0 failed**（较 v0.3.3 的 151 增加 64 个）。

新增/更新的覆盖：

- npm（`test/micdn/npm/resolve_test.d`、`packument_test.d`）：两个上游各只有一份 packument 时的并入与 `dist-tags`
  推导、dev/rc 判定、按原始规格取 tgz、`{origin}` 占位符替换。
- maven（`test/micdn/maven/snapshot_test.d`）：SNAPSHOT 元数据 TTL 保鲜与失败保留、别名指向上游新构建、
  artifact 级元数据并入与幂等、`-SNAPSHOT` 路径段判定。
- 配置（`test/micdn/config_test.d`）：`<dev>`/`<snapshot>` 属性、`<repo>` 不再解析、未声明 `<maven>`/`<npm>` 时
  仍有默认仓库但不挂端点、`<publish>` 令牌必填与上限解析（含 `toXml` 往返）。
- 端点（`test/micdn/main_test.d`）：未声明元素不注册 `/maven`、`/npm`。
- 发布端点：`test/micdn/npm/publish_test.d`（publish 文档解析、自定义 tag、名不符/坏 Base64 拒绝）、
  `test/micdn/maven/publish_test.d`（上传落盘与覆盖、目录/点段拒绝）、`test/micdn/web/publish_test.d`
  （请求体读取与 413、Bearer/Basic/X-Micdn-Token 判定）、`test/micdn/npm/web_test.d`（PUT 的 401/400：
  缺令牌/错令牌被挡下、令牌正确则放行（来源地址无关）、未声明 `<publish>` 时一律 401）。

本地烟雾验证（`--build=release-nobounds`，配置对照 `resources/micdn.xml`）：

- `/maven` → 302 `/maven/`；快照别名 302 带 `latest` 头；上游独有的快照构件 200；
- packument 合并结果为 `{"dev": "0.0.4-dev.2", "latest": "0.0.4"}`（保留上游绝对 tarball 地址）；dev tgz 200；
- 未声明 `<npm>` 的配置：日志只注册 `/admin, /static, /maven, /blob, /s3, /*`，npm provider 仍能从默认仓库下载。
- 真机 `npm publish`（含 scoped `@scope/name`、`--tag staging`，凭 `.npmrc` 的 `_authToken`）与
  `mvn deploy:deploy-file`（SNAPSHOT，凭 `settings.xml` 的 server 凭据）均成功写入仓库并能被消费方
  `npm install` / `/maven` GET 取回；缺令牌/错令牌 401（带 Basic 挑战）、未声明 `<publish>` 时 PUT 不注册，
  读路径不受影响。抓包核对过双方协议细节：npm 发 `PUT /npm/@scope%2fname` + `authorization: Bearer …`
  + `content-type: application/json`；Maven 发 `Expect: 100-continue` + `Authorization: Basic …`（`javax`/Apache
  HttpClient 预置凭据），vibe 正确回 `100 Continue`，两者都接受 `201 Created`。
